//
//  JackMoebiusManager.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Drives the JackMoebius daemon (jackmoebiusd) as a *soft trigger*: locates the
//  `jackmoebius` control CLI, starts/stops the autonomous daemon, and mirrors its
//  live state. The daemon runs iff JACK is up and self-stops on JACK-away, so this
//  manager only triggers activation and reflects the resulting state — it never
//  owns or kills the daemon process.
//

import Foundation
import Combine
import AppKit

// MARK: - JackMoebiusState

/// Live state of the JackMoebius daemon as seen by JackMate.
enum JackMoebiusState: Equatable {
    /// The `jackmoebius` control CLI is not installed.
    case unavailable
    /// CLI present, daemon not running.
    case inactive
    /// A start request is in flight.
    case activating
    /// Daemon running.
    case active
    /// The last start/stop attempt failed (with a human-readable reason).
    case failed(String)
}

/// Trial / purchased-license state of JackMoebius, read from `jackmoebius license --json`
/// (works with the daemon down). See `refreshLicense()`.
enum LicenseState: Equatable {
    /// A perpetual license is active on this Mac. `email`/`usage`/`limit`/`keyHint` may be absent.
    /// `keyHint` is a display-only masked key (last 4 shown) — never the full activation secret.
    case licensed(email: String?, usage: Int?, limit: Int?, keyHint: String?)
    /// Free trial running — `daysRemaining` = whole days left before it ends.
    case trial(daysRemaining: Int)
    /// Trial over, no valid license.
    case expired
}

/// A JackMoebius license command failed — carries the CLI's human message (shown to the user) and,
/// when the CLI provides one, a stable machine-readable `code` (e.g. `activation_limit_reached`).
struct LicenseCLIError: LocalizedError, Equatable {
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }
}

// MARK: - Backings

/// How one direction of an app reaches JackMoebius (`apps[].in_backing` / `out_backing`).
nonisolated enum JMBacking: String, Equatable, Codable, Sendable {
    /// The common `JackMoebius` device: the shared default input, or the app's own stereo stem on the
    /// default output. No device of its own, always 2 channels.
    case shared
    /// A dedicated virtual device, `JackMoebius for <App>`, with 1…64 channels (wire value `private`).
    case dedicated = "private"
}

/// The backing and channel count requested for one direction of an app. For `shared` the count is
/// always 2 (the daemon ignores it).
nonisolated struct JMSide: Equatable, Codable, Sendable {
    var backing: JMBacking
    var channels: Int

    /// Shared stereo side — the daemon's default for outputs.
    static let sharedStereo = JMSide(backing: .shared, channels: 2)

    /// Dedicated card of `n` channels, clamped to the daemon's 1…64 range.
    static func dedicated(_ n: Int) -> JMSide { JMSide(backing: .dedicated, channels: min(max(n, 1), 64)) }

    /// The `{backing, n?}` object of `jack_apply` / `jack_add*`. `backing` is always explicit.
    var requestObject: [String: Any] {
        backing == .shared ? ["backing": backing.rawValue]
                           : ["backing": backing.rawValue, "n": channels]
    }
}

/// The last choice made for an app, per direction (JackMate-side memory; the daemon stores none).
nonisolated struct JMExposureChoice: Codable, Equatable, Sendable {
    var input:  JMSide? = nil
    var output: JMSide? = nil
}

// MARK: - JackMoebiusApp

/// One CoreAudio app in the JackMoebius selector, from the enriched `apps` call
/// (both directions). Identified by its stable `key` (bundle ID, or `path:<exec>`).
struct JackMoebiusApp: Identifiable, Equatable {
    let key: String
    let name: String
    let pid: Int
    var outExposed: Bool       // out exposure intent (true between add and remove/clear)
    var inExposed: Bool        // in exposure intent
    var outBacking: JMBacking  // shared stereo stem, or a dedicated card
    var inBacking: JMBacking   // shared default input, or a dedicated card
    var outWidth: Int          // persistent output reservation width in channels (0 if none)
    var inWidth: Int           // persistent input reservation width in channels (0 if none)
    var canCapture: Bool       // input-eligible (includes apps that already hold a card)
    var id: String { key }

    /// The In switch is actionable when the app is capture-eligible, already reserved,
    /// or currently exposed.
    var inActionable: Bool { canCapture || inWidth > 0 || inExposed }
    /// Output channel count: always 2 when shared, else the reservation width (default 2).
    /// `nonisolated`: pure function of stored Sendable data, read off-main when snapshotting.
    nonisolated var outChannelCount: Int { outBacking == .shared ? 2 : (outWidth > 0 ? outWidth : 2) }
    /// Input channel count: always 2 when shared, else the reservation width (default 2).
    nonisolated var inChannelCount: Int { inBacking == .shared ? 2 : (inWidth > 0 ? inWidth : 2) }
    /// The output as the daemon currently has it (backing + channels).
    nonisolated var currentOut: JMSide { JMSide(backing: outBacking, channels: outChannelCount) }
    /// The input as the daemon currently has it (backing + channels).
    nonisolated var currentIn: JMSide { JMSide(backing: inBacking, channels: inChannelCount) }
}

/// One entry of the user blacklist (from `blacklist_show`), shown in the advanced panel.
struct JackMoebiusBlacklistEntry: Identifiable, Equatable {
    let key: String
    let name: String
    var id: String { key }
    /// Shipped defaults — filtered out of the advanced sheet (not user-removable).
    /// `nonisolated` so `isDefault` is readable from the background fetch.
    nonisolated static let defaultKeys: Set<String> = [
        "com.apple.audio.AudioMIDISetup",
        "io.github.zinc75.JackMate",
    ]
    nonisolated var isDefault: Bool { Self.defaultKeys.contains(key) }
}

/// A persistent channel reservation for an app (out and/or in), shown in the advanced
/// panel so the user can free stale reservations. Includes non-running apps.
struct JackMoebiusReservation: Identifiable, Equatable {
    let key: String
    let name: String
    let outBacking: JMBacking // shared stem pair, or the lanes of a dedicated card
    let outChannels: [Int]   // out reservation bus-channel indices ([] when none)
    let inChannels: [Int]    // in reservation bus-channel indices ([] when none)
    var outHeld: [Int] = []  // channels a card keeps for a dropped output stream (reserved but unused)
    var inHeld: [Int] = []   // same for a dropped input stream
    /// The app reads the shared default input: it reserves no channel (the two shared ones belong to
    /// everybody and are not counted in the capacity), but it is listed so the picture is complete.
    var inShared = false
    var id: String { key }
    /// Number of reserved-but-unused channels of this app (counted in the capacity, not in the lists above).
    var heldCount: Int { outHeld.count + inHeld.count }
}

/// Live routing coherence of a JackMoebius per-app box, per direction, reported by
/// `jack_list` (`out_status`) / `jack_list_in` (`in_status`). `ok` is the normal case
/// and shows nothing; only `mismatch` and `idle` surface on the canvas — and only on a
/// wired box. `absent` (app not running) never reaches the canvas: there is no node to
/// mark, so it is dropped at parse time (maps to `nil`).
enum JMRoutingStatus: String, Equatable {
    case ok            // reads/writes the right JackMoebius device
    case mismatch      // the app opened another device → wrong picker choice
    case idle          // opened no device of this direction (pre-wiring / paused)
}

/// Per-box routing status, one value per direction (`nil` when the box has no port of
/// that direction, or the daemon reported `absent`/an unknown value). On a `mismatch`
/// the daemon also names the wrong device the app is currently using (`current_device`)
/// → carried here per direction to build a specific alert message.
struct JMBoxStatus: Equatable {
    var out: JMRoutingStatus?
    var input: JMRoutingStatus?   // `in` is a Swift keyword → `input`
    var outDevice: String?        // wrong device name (present only when out == .mismatch)
    var inDevice: String?         // wrong device name (present only when input == .mismatch)

    /// Explicit `nonisolated` init so instances can be built from the background status
    /// fetch. Without it the project's default `@MainActor` isolation would isolate the
    /// synthesized initializer (all stored properties carry an implicit `nil` default).
    nonisolated init(out: JMRoutingStatus? = nil, input: JMRoutingStatus? = nil,
                     outDevice: String? = nil, inDevice: String? = nil) {
        self.out = out
        self.input = input
        self.outDevice = outDevice
        self.inDevice = inDevice
    }
}

/// One misconfigured JackMoebius box: an exposed, wired app whose audio device for this
/// direction is not the JackMoebius one (`mismatch`). Drives the panel alert banner.
struct JMMismatch: Identifiable, Equatable {
    let key: String            // app bundle ID
    let name: String           // app display name (JACK client name)
    let isInput: Bool          // true = captures from the wrong device; false = wrong output
    let currentDevice: String? // wrong device name (nil on older daemons → generic message)
    var id: String { key + (isInput ? ":in" : ":out") }
}

/// Why the shared-memory transport is not up (`status.transport_problem`): while it waits, no box
/// exists and the system device stays hidden. `code` is a stable identifier JackMate localises from;
/// `message` and `remedy` are the daemon's English sentences, kept as a fallback for an unknown code.
nonisolated struct JMTransportProblem: Equatable {
    let code: String
    let message: String
    let remedy: String
}

/// One structured message of `jackmoebius doctor --json`. `code` is a stable identifier JackMate
/// localises from; `text` and `remedy` are the daemon's English sentences, kept as a fallback.
nonisolated struct JMDoctorMessage: Equatable {
    let code: String
    let isError: Bool
    let text: String
    let remedy: String
}

/// A running app whose input is the shared default input: it has no JACK port of its own, so the
/// patchbay draws a virtual box for it (with `shared_input_1/2` as mirrored ports).
nonisolated struct JMSharedBox: Equatable {
    let key: String    // bundle ID
    let name: String   // display name (= the JACK client name its box would have)
}

/// Per-app output-volume lock state (from `set_volume`): `locked` = follows the
/// JackMoebius master volume; unlocked = independent `gain` (0…1). One per out-exposed app.
struct JMAppVolume: Equatable {
    var locked: Bool
    var gain: Double
}

// MARK: - JackMoebiusManager

/// Observable manager for the JackMoebius daemon lifecycle.
///
/// Activation (re)starts the daemon **via launchd** (`launchctl kickstart` on its
/// LaunchAgent); deactivation and liveness go through the native
/// IPC client (`JackMoebiusIPC`).
/// A persistent `subscribe` event stream keeps `state` in sync with the
/// real daemon while JACK runs — so an external `jackmoebius stop` (or a crash) is
/// detected, not just JackMate's own actions.
@MainActor
final class JackMoebiusManager: ObservableObject {

    /// Live daemon state. Drives the toolbar button, the panel toggle and the status chip.
    @Published private(set) var state: JackMoebiusState = .unavailable

    /// Whether the slide-in JackMoebius control panel is shown (toggled from the toolbar).
    @Published var showPanel: Bool = false

    /// When true, a studio load is driving JackMoebius, so the `observeJackState` auto-launch
    /// on jack-up is suppressed — the loaded studio decides whether JackMoebius runs, not the
    /// global `exposeJackMoebius` preference.
    var suppressAutoActivate = false

    /// JackMoebius daemon version, from the `status` reply's `version` field (nil on daemons
    /// that don't expose it yet — the indicator then simply doesn't show).
    @Published private(set) var installedVersion: String? = nil
    /// Latest published version (releases feed; nil = none / offline / 404 → no update shown).
    @Published private(set) var latestVersion: String? = nil
    /// True when `latestVersion` is strictly newer than `installedVersion`.
    @Published private(set) var updateAvailable: Bool = false

    /// Trial / license state, from `jackmoebius license --json` (source of truth — works with the
    /// daemon down). `nil` = CLI absent or not yet read → no license UI shown.
    @Published private(set) var license: LicenseState? = nil

    /// Set when the daemon refuses a new exposure because the licence lapsed mid-session
    /// (enforcement on). Drives the purchase/activation sheet; cleared when it's dismissed.
    @Published var showLicensingRefusal = false

    /// Set by the `jackmate://activate` deep link to open the licence sheet with the key
    /// pre-filled. The sheet reads it once and clears it on appear; activation still goes through
    /// the user pressing Activate (shell-out to the CLI) — a deep link never reads or writes
    /// licence storage.
    @Published var pendingActivationKey: String? = nil

    /// Drives the licence sheet from a deep link — a manager-level trigger the top-level view
    /// observes, mirroring `showLicensingRefusal`.
    @Published var showLicenseSheet = false

    /// `true` while the JackMoebius installer DMG is being fetched/mounted for the "not installed"
    /// path of the licence sheet — drives a spinner in place of the install button.
    @Published var isFetchingInstaller = false

    /// `true` when the licence is installed but the trial has expired (no active licence) —
    /// JackMoebius can't run, so callers treat the "expose" intent like "not installed".
    var isLicenseExpired: Bool {
        if case .expired? = license { return true }
        return false
    }

    /// CoreAudio apps for the selector — refreshed while the panel is open.
    @Published private(set) var apps: [JackMoebiusApp] = []
    private var appsInFlight = false

    /// Per-app output-volume state (key = bundle ID), queried for out-exposed apps.
    @Published private(set) var appVolumes: [String: JMAppVolume] = [:]
    /// Locked apps whose volume preview (state ②) the user has expanded — UI only.
    @Published var volumePreviewExpanded: Set<String> = []

    /// Live routing status per JackMoebius per-app box (key = bundle ID), fetched from
    /// `jack_list`/`jack_list_in` on status refreshes. Drives the canvas markers.
    @Published private(set) var boxStatus: [String: JMBoxStatus] = [:]
    /// Why the daemon does not answer, from `jackmoebius doctor --json` (which works without the daemon):
    /// empty while the daemon is active or the CLI is absent. `daemon_not_running` itself is not a reason
    /// worth showing when the user simply has not started it, so the panel only uses the other codes.
    @Published private(set) var daemonReasons: [JMDoctorMessage] = []
    private var lastDoctorRun = Date.distantPast
    private var doctorInFlight = false

    /// Why the transport is down (`nil` when it is up or the daemon is not active).
    @Published private(set) var transportProblem: JMTransportProblem? = nil
    /// The macOS default input/output devices (event-driven), to tell when they are not JackMoebius.
    let systemDefaults = SystemDefaultsMonitor()
    /// Running apps whose output is the shared stereo stem (they play to the Mac's default output).
    @Published private(set) var sharedOutputApps: [String] = []
    /// How full the two channel buses are (`status.capacity`); `nil` while the daemon is not active.
    @Published private(set) var capacity: JMCapacity? = nil
    /// Running apps in shared input mode (from `jack_list_in`), for the patchbay's virtual boxes.
    @Published private(set) var sharedInputBoxes: [JMSharedBox] = [] {
        didSet { patchbayManager?.sharedInputBoxes = sharedInputBoxes }
    }
    /// The patchbay, to read the cables before a backing change and restore them afterwards
    /// (wired by the view that owns both managers).
    weak var patchbayManager: PatchbayManager? {
        didSet {
            patchbayManager?.sharedInputBoxes = sharedInputBoxes
            patchbayManager?.showSystemNode = showSystemNode
        }
    }

    /// Debug setting (advanced configuration): always show the JackMoebius system node in the
    /// patchbay. Off by default: the node is hidden while boxes show the shared-input ports, and
    /// reappears on its own when cables remain on it with no such box.
    @Published var showSystemNode: Bool =
        UserDefaults.standard.bool(forKey: "JM.showSystemNode") {
        didSet {
            UserDefaults.standard.set(showSystemNode, forKey: "JM.showSystemNode")
            patchbayManager?.showSystemNode = showSystemNode
        }
    }

    /// An `apply` held back because it would take an input back to the shared default input that other
    /// apps also hear, with cables that the user may want to reconnect there: the change is only sent
    /// once the user decides (apply and reconnect / apply without / cancel). Drives the panel alert.
    @Published var pendingApply: PendingApply? = nil

    struct PendingApply: Equatable {
        let app: JackMoebiusApp
        let inSide: JMSide?
        let outSide: JMSide?
        let plan: JMRewire.Plan
    }

    /// A removal of a shared input held back until the user confirms: the app keeps hearing the Mac's
    /// default input as long as other apps stay in shared mode (JackMoebius stays the default input).
    @Published var pendingSharedInputRemoval: PendingSharedInputRemoval? = nil

    struct PendingSharedInputRemoval: Equatable {
        let app: JackMoebiusApp
        let otherApps: [String]
    }

    /// The daemon's refusal of the last change asked for an app (key = bundle ID), shown under its row
    /// until the user closes it or tries again. Worded from its `code` and `details` (see `JMApplyError`).
    @Published private(set) var applyErrors: [String: JMApplyError] = [:]

    func dismissApplyError(_ key: String) { applyErrors[key] = nil }

    /// An `apply` held back because it takes an input out of the shared input while cables on it were
    /// drawn only for this app: the user chooses to cut them or keep them (before anything changes).
    @Published var pendingCleanup: PendingCleanup? = nil

    struct PendingCleanup: Equatable {
        let app: JackMoebiusApp
        let inSide: JMSide
        let wires: [JMWire]
        let otherApps: [String]   // apps that still read the shared input (they would lose the cables)
    }

    enum CleanupChoice { case ask, remove, keep }

    /// What to do with the cables that would join the shared input other apps also hear.
    enum RewireChoice { case ask, reconnect, skip }

    /// Directions (`"<bundle id>:in"` / `":out"`) the user configured in this session (switched on or
    /// applied). A routing mismatch on such a direction is flagged under the app's row right away,
    /// even before it is wired; it is forgotten once the direction reads the right device again or
    /// is switched off. (Wired mismatches always show, in the panel banner and on the canvas.)
    @Published private(set) var configuredSides: Set<String> = []

    /// `true` when `key`'s direction was configured in this session (see `configuredSides`).
    func isConfigured(_ key: String, input: Bool) -> Bool {
        configuredSides.contains(Self.sideID(key, input))
    }

    private static func sideID(_ key: String, _ input: Bool) -> String { key + (input ? ":in" : ":out") }

    /// > 0 while user mutations are in flight — status refreshes pause so a stale fetch
    /// can't overwrite the freshly mutated state (and revert a toggle).
    private var pendingMutations = 0

    /// JackMoebius website (presentation + DMG download). Used by the info-sheet download button.
    static let downloadURL = URL(string: "https://jackmoebius.io/")!
    /// JackMoebius website / documentation. Used by the docs button and the What's New "learn more" link.
    static let docsURL     = URL(string: "https://jackmoebius.io/")!
    /// JackMoebius latest GitHub release (the installer package). Used to send a user straight to the
    /// download when they try to activate a licence without JackMoebius installed.
    static let releasesURL = URL(string: "https://github.com/zinc75/JackMoebius/releases/latest")!
    /// JackMoebius Discussions "licensing" category — the help channel offered on the "activation
    /// limit reached" hint (asking there to free a seat).
    static let licenseSupportURL = URL(string: "https://github.com/zinc75/JackMoebius/discussions/categories/licensing")!
    /// JackMoebius site "buy" deep link → replays the site's Buy button (correct
    /// Lemon Squeezy product + embed overlay). Routed through the site so the
    /// checkout URL can change without shipping a new JackMate build.
    static let purchaseURL       = URL(string: "https://jackmoebius.io/#buy")!

    /// Oldest JackMoebius that this JackMate drives. 1.1.0 introduced the shared/private backings,
    /// the `shared_input_*` ports and `jack_apply`; an older daemon would silently ignore those
    /// parameters, so the control panel is blocked below this version.
    nonisolated static let minimumDaemonVersion = "1.1.0"

    /// `true` when the installed JackMoebius is older than `minimumDaemonVersion`. `false` while the
    /// version is unknown (no bundle plist yet), so nothing is blocked on a guess.
    var daemonTooOld: Bool {
        guard let v = installedVersion else { return false }
        return Self.isVersion(Self.minimumDaemonVersion, newerThan: v)
    }

    /// Absolute path to the located `jackmoebius` control CLI, or `nil` if not installed.
    @Published private(set) var executableURL: URL? = nil

    /// `true` when the `jackmoebius` CLI is installed and usable.
    var installed: Bool { executableURL != nil }

    private var jackStateCancellable: AnyCancellable?
    private weak var jackManager: JackManager?
    private var pollInFlight = false

    // Event stream (daemon push; replaces the fixed-rate poll).
    private var eventStreamTask: Task<Void, Never>?
    /// Set during a controlled batch (studio load/stop) so the batch's own mutations, echoed
    /// back as events, don't trigger a re-fetch storm — the batch does its own final fetch.
    var suppressEventRefetch = false

    init() {
        executableURL = Self.findExecutable()
        state = installed ? .inactive : .unavailable
        readInstalledVersion()             // plist-based, instant — show the version even if the daemon is down
        refreshStatus()   // detect a daemon already running (e.g. LaunchAgent / prior session)
        if installed { fetchLatestVersion() }
        refreshLicense()  // trial/license state (offline CLI, daemon-independent)
    }

    // MARK: - Executable detection

    /// Searches the standard install locations for the `jackmoebius` control CLI.
    private static func findExecutable() -> URL? {
        let candidates = [
            "/usr/local/bin/jackmoebius",
            "/opt/homebrew/bin/jackmoebius",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Re-checks whether the CLI is installed (e.g. after the app regains focus).
    func recheckInstallation() {
        executableURL = Self.findExecutable()
        if !installed {
            state = .unavailable
        } else if state == .unavailable {
            state = .inactive
            refreshStatus()
        }
        readInstalledVersion()               // daemon-independent (plist), works even inactive
        if installed { fetchLatestVersion() }
        refreshLicense()                     // CLI may have been (un)installed / state changed
    }

    // MARK: - Lifecycle wiring

    /// Wires the manager to JACK's running state. Mirrors `StudioManager.observeJackState`.
    /// - JACK becomes running **and** the user armed `exposeJackMoebius` → auto-activate.
    /// - JACK stops → the daemon self-stops on JACK-away, so reflect `.inactive`
    ///   (never call `stop` ourselves).
    func observeJackState(jackManager: JackManager) {
        self.jackManager = jackManager
        jackStateCancellable = jackManager.$isRunning
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak jackManager] running in
                guard let self, let jackManager else { return }
                if running {
                    if jackManager.prefs.exposeJackMoebius, self.installed, !self.isLicenseExpired, !self.suppressAutoActivate {
                        self.activate()
                    }
                    self.startEventStream()
                } else {
                    // JACK is down: the daemon self-stops and the control panel is no
                    // longer relevant — close it and reflect the inactive state.
                    self.stopEventStream()
                    self.showPanel = false
                    if self.installed { self.state = .inactive }
                }
            }
        // JACK may already be running when this wiring happens (app relaunched while
        // JACK is up): the publisher's initial value is dropped, so start the stream now.
        if jackManager.isRunning { startEventStream() }
    }

    // MARK: - Daemon control (start via CLI, stop/status via IPC)

    /// Starts the daemon **via launchd** (`launchctl kickstart` on its LaunchAgent) so it
    /// is parented by launchd — under its own TCC / audio identity — instead of spawned as
    /// JackMate's child. A child of JackMate inherits JackMate's TCC responsibility, which
    /// stops `jackmoebiusd` from writing the HAL control-properties it needs to drive its
    /// device; the resulting stream-config change crashes JACK's CoreAudio backend. (JACK
    /// only *consumes* the device and survives; the daemon must *drive* it.)
    func activate() {
        guard installed else { state = .unavailable; return }
        guard state != .activating else { return }
        state = .activating
        Task.detached { [weak self] in
            let result = Self.startViaLaunchd()
            await self?.applyActivation(result)
        }
    }

    /// Applies the launchd start result on the main actor.
    private func applyActivation(_ result: CLIResult) {
        switch result {
        case .success:          state = .active
        case .failure(let msg):
            state = .failed(msg)
            refreshDaemonReasons(force: true)
        }
    }

    /// Stops the daemon via the IPC `stop` command.
    func deactivate() {
        guard installed else { state = .unavailable; return }
        Task.detached {
            _ = JackMoebiusIPC.request("stop")
            await MainActor.run {
                self.state = self.installed ? .inactive : .unavailable
            }
        }
    }

    /// Fetches the daemon's real state over IPC (`status`) and mirrors it into `state`
    /// Detects an external start/stop — not just JackMate's own actions.
    func refreshStatus() {
        guard installed else { state = .unavailable; return }
        guard state != .activating else { return }   // don't clobber an in-flight start
        guard !pollInFlight else { return }           // no overlapping status fetches
        pollInFlight = true
        Task.detached {
            // Reduce the reply to Sendable values before hopping to the main actor.
            let running: Bool
            var exposedOut = 0
            var exposedIn: Int? = nil
            var capacity: JMCapacity? = nil
            var transportProblem: JMTransportProblem? = nil
            let version: String?
            switch JackMoebiusIPC.request("status") {
            case .success(let data):
                running = true
                let dict = data as? [String: Any]
                version = dict?["version"] as? String   // nil on daemons that don't expose it
                // `exposed_out`/`exposed_in` mirror jack_list / jack_list_in exactly.
                // Older daemons only ship `exposed_boxes` (an out-only alias) → use it as
                // the out fallback; `exposed_in` may be missing there → fetch the in list
                // unconditionally in that case (safe: empty list → no markers).
                exposedOut = (dict?["exposed_out"] as? Int) ?? (dict?["exposed_boxes"] as? Int) ?? 0
                exposedIn  = dict?["exposed_in"] as? Int
                capacity   = Self.parseCapacity(dict?["capacity"])
                transportProblem = Self.parseTransportProblem(dict?["transport_problem"])
            case .failure:
                running = false
                version = nil
            }
            // Canvas routing markers: fetch each direction's list only when it has an
            // exposed box, keeping the fetch light. No box → empty map → no markers.
            let fetched = running
                ? Self.fetchBoxStatus(fetchOut: exposedOut > 0,
                                      fetchIn: exposedIn.map { $0 > 0 } ?? true)
                : (status: [String: JMBoxStatus](), shared: [JMSharedBox](), sharedOut: [String]())
            let boxStatus = fetched.status
            let shared    = fetched.shared
            let sharedOut = fetched.sharedOut
            let capacityNow = capacity   // immutable snapshots for the main-actor hop
            let transportNow = transportProblem
            await MainActor.run {
                self.pollInFlight = false
                guard self.state != .activating else { return }
                if running {
                    self.state = .active
                    self.daemonReasons = []
                    self.boxStatus = boxStatus
                    self.capacity = capacityNow
                    self.transportProblem = transportNow
                    self.sharedInputBoxes = shared
                    self.sharedOutputApps = sharedOut
                    // A direction that reads the right device again is no longer "to watch".
                    self.configuredSides = self.configuredSides.filter { id in
                        let input = id.hasSuffix(":in")
                        let key = String(id.dropLast(input ? 3 : 4))
                        let status = input ? boxStatus[key]?.input : boxStatus[key]?.out
                        return status != .ok
                    }
                    if let version { self.installedVersion = version }
                    self.updateVersionComparison()
                } else {
                    self.state = self.installed ? .inactive : .unavailable
                    self.refreshDaemonReasons()
                    self.boxStatus = [:]
                    self.capacity = nil
                    self.transportProblem = nil
                    self.sharedInputBoxes = []
                    self.sharedOutputApps = []
                }
            }
        }
    }

    /// Parses `status.capacity` = `{forward:{used,total}, reverse:{used,total}}` (channels). `nil` when
    /// absent (older daemon) or malformed. `static` so it is testable with a mocked payload.
    nonisolated static func parseCapacity(_ value: Any?) -> JMCapacity? {
        guard let dict = value as? [String: Any],
              let fwd = dict["forward"] as? [String: Any], let rev = dict["reverse"] as? [String: Any],
              let fu = fwd["used"] as? Int, let ft = fwd["total"] as? Int,
              let ru = rev["used"] as? Int, let rt = rev["total"] as? Int else { return nil }
        // `held` / `held_by` (channels reserved by a dead stream) are absent on a daemon without them.
        func holders(_ any: Any?) -> [JMHolder] {
            (any as? [[String: Any]] ?? []).compactMap { h in
                guard let app = h["app"] as? String, let n = h["channels"] as? Int else { return nil }
                return JMHolder(app: app, channels: n)
            }
        }
        return JMCapacity(forwardUsed: fu, forwardTotal: ft, reverseUsed: ru, reverseTotal: rt,
                          forwardHeld: fwd["held"] as? Int ?? 0, reverseHeld: rev["held"] as? Int ?? 0,
                          forwardHeldBy: holders(fwd["held_by"]), reverseHeldBy: holders(rev["held_by"]))
    }

    // MARK: - Why the daemon does not answer (`doctor`)

    /// Asks the CLI why there is no daemon (no daemon, no network, no root needed): another account
    /// running JackMoebius, a missing driver or broker… At most once every 3 s unless `force`.
    func refreshDaemonReasons(force: Bool = false) {
        guard let cli = executableURL, !doctorInFlight else { return }
        if !force, Date().timeIntervalSince(lastDoctorRun) < 3 { return }
        doctorInFlight = true
        lastDoctorRun = Date()
        Task.detached {
            let result = Self.runCLI(cli, ["doctor", "--json"])
            let messages = result.flatMap { Self.parseDoctor($0.stdout) } ?? []
            await MainActor.run {
                self.doctorInFlight = false
                // A daemon that came up meanwhile makes the answer obsolete.
                self.daemonReasons = self.state == .active ? [] : messages
            }
        }
    }

    /// Parses the `messages` of `doctor --json`. `nil` when the output is not that object. `static`
    /// so it is testable with a mocked payload.
    nonisolated static func parseDoctor(_ stdout: String) -> [JMDoctorMessage]? {
        guard let data = stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["messages"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let code = row["code"] as? String else { return nil }
            return JMDoctorMessage(code: code, isError: (row["severity"] as? String) == "error",
                                   text: row["text"] as? String ?? "",
                                   remedy: row["remedy"] as? String ?? "")
        }
    }

    /// Parses `status.transport_problem` = `{code, message, remedy}`; `nil` when absent (transport up)
    /// or malformed. `static` so it is testable with a mocked payload.
    nonisolated static func parseTransportProblem(_ value: Any?) -> JMTransportProblem? {
        guard let dict = value as? [String: Any], let code = dict["code"] as? String else { return nil }
        return JMTransportProblem(code: code,
                                  message: dict["message"] as? String ?? "",
                                  remedy: dict["remedy"] as? String ?? "")
    }

    // MARK: - Version check (daemon version + update detection)

    /// Fixed install location of the JackMoebius daemon bundle (guaranteed by its pkg).
    nonisolated static let daemonBundlePath = "/usr/local/libexec/JackMoebius.app"

    /// Reads the installed daemon version from its bundle Info.plist — **daemon-independent, no
    /// subprocess, doesn't touch JACK** (the plist is bumped each release). `nil` if the bundle is
    /// absent. The live `status.version` refreshes this when the daemon is actually running.
    func readInstalledVersion() {
        let plist = Self.daemonBundlePath + "/Contents/Info.plist"
        installedVersion = NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String
        updateVersionComparison()
    }

    /// Fetches the latest published JackMoebius version (cached 24 h) from its GitHub releases. On
    /// no release / 404 / offline, `latestVersion` stays nil → no update is shown (graceful while the
    /// JackMoebius repository has no public release yet).
    func fetchLatestVersion() {
        let cacheVersionKey = "JM.jmLatestVersion"
        let cacheDateKey    = "JM.jmLatestVersionDate"
        let d = UserDefaults.standard
        if let cached = d.string(forKey: cacheVersionKey),
           let date   = d.object(forKey: cacheDateKey) as? Date,
           Date().timeIntervalSince(date) < 86400 {
            latestVersion = cached
            updateVersionComparison()
            return
        }
        Task.detached {
            // GitHub releases feed. The repo is public with releases from the 2.0.0 launch on;
            // until then this 404s and no update is shown (graceful).
            guard let url = URL(string: "https://api.github.com/repos/zinc75/JackMoebius/releases/latest") else { return }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }   // no release → nil (graceful)
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            d.set(version, forKey: cacheVersionKey)
            d.set(Date(),  forKey: cacheDateKey)
            await MainActor.run {
                self.latestVersion = version
                self.updateVersionComparison()
            }
        }
    }

    // MARK: - Install JackMoebius (download DMG + open its installer)

    private enum InstallerError: Error { case noAsset, mount, noPkg }

    /// Downloads the latest JackMoebius release DMG, mounts it, extracts the bundled `.pkg` installer
    /// and opens it (macOS Installer) — for a user who tries to activate a licence while only JackMate
    /// (the free entry point) is installed. The asset name carries the version, so the DMG URL is
    /// resolved via the GitHub releases API. The pkg is copied out of the volume before it is
    /// detached, so Installer keeps working after the volume unmounts. On any failure it falls back to
    /// opening the releases page in the browser.
    func downloadAndOpenInstaller() {
        guard !isFetchingInstaller else { return }
        isFetchingInstaller = true
        Task.detached {
            let dmg = URL(fileURLWithPath: "/private/tmp/JackMoebiusInstaller.dmg")
            var mountPoint: String? = nil
            do {
                let assetURL = try await Self.resolveInstallerDMGURL()
                let (tmp, response) = try await URLSession.shared.download(from: assetURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallerError.noAsset }
                try? FileManager.default.removeItem(at: dmg)
                try FileManager.default.moveItem(at: tmp, to: dmg)
                let mount = try Self.mountDMG(at: dmg)
                mountPoint = mount
                let pkg = try Self.extractInstallerPkg(fromMount: mount)
                Self.detachDMG(at: mount); mountPoint = nil
                try? FileManager.default.removeItem(at: dmg)
                await MainActor.run {
                    NSWorkspace.shared.open(pkg)
                    self.isFetchingInstaller = false
                }
            } catch {
                if let m = mountPoint { Self.detachDMG(at: m) }
                try? FileManager.default.removeItem(at: dmg)
                await MainActor.run {
                    // Fall back to the releases page so the user still gets somewhere.
                    NSWorkspace.shared.open(Self.releasesURL)
                    self.isFetchingInstaller = false
                }
            }
        }
    }

    /// Resolves the latest release's `JackMoebius-<version>.dmg` download URL via the GitHub API.
    nonisolated private static func resolveInstallerDMGURL() async throws -> URL {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/zinc75/JackMoebius/releases/latest")!)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { throw InstallerError.noAsset }
        let dmg = assets.compactMap { $0["browser_download_url"] as? String }
                        .first { $0.range(of: "/JackMoebius-[^/]*\\.dmg$", options: .regularExpression) != nil }
        guard let dmg, let url = URL(string: dmg) else { throw InstallerError.noAsset }
        return url
    }

    /// Mounts a DMG with `hdiutil` and returns its `/Volumes/...` mount point.
    nonisolated private static func mountDMG(at url: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", url.path, "-nobrowse", "-noautoopen"]
        let pipe = Pipe(); proc.standardOutput = pipe
        try proc.run(); proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // hdiutil tab-separated output; mount point is the last field of the last non-empty line.
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let last  = lines.last,
              let mount = last.components(separatedBy: "\t").last?
                              .trimmingCharacters(in: .whitespacesAndNewlines),
              mount.hasPrefix("/Volumes/") else { throw InstallerError.mount }
        return mount
    }

    /// Copies the bundled `*.pkg` out of a mounted volume to a stable temp path, so it can be opened
    /// after the DMG is detached.
    nonisolated private static func extractInstallerPkg(fromMount mount: String) throws -> URL {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: mount)) ?? []
        guard let pkgName = files.first(where: { $0.hasSuffix(".pkg") }) else { throw InstallerError.noPkg }
        let src  = URL(fileURLWithPath: mount).appendingPathComponent(pkgName)
        let dest = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(pkgName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    /// Detaches a mounted DMG volume (best-effort).
    nonisolated private static func detachDMG(at mount: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mount, "-quiet"]
        try? proc.run(); proc.waitUntilExit()
    }

    private func updateVersionComparison() {
        guard let installed = installedVersion, let latest = latestVersion else {
            updateAvailable = false
            return
        }
        updateAvailable = Self.isVersion(latest, newerThan: installed)
    }

    /// True if `v1` is strictly newer than `v2` (numeric dotted-version comparison).
    private nonisolated static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let c1 = v1.split(separator: ".").compactMap { Int($0) }
        let c2 = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(c1.count, c2.count) {
            let a = i < c1.count ? c1[i] : 0
            let b = i < c2.count ? c2[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - License (JackMoebius)

    /// Re-reads the trial/license state via `jackmoebius license --json` — offline, instant, works
    /// with the daemon down. The live `status.licensing` / `licensing_changed` only *trigger* this
    /// re-read; this CLI call is authoritative. `nil` when the CLI is absent or unreadable → no license UI.
    func refreshLicense() {
        guard let cli = executableURL else { license = nil; return }
        Task.detached {
            let parsed = Self.runLicenseJSON(cli)
            await MainActor.run { self.license = parsed }
        }
    }

    /// Runs `jackmoebius license --json` off-main and parses it. `nil` on launch failure /
    /// non-zero exit / unparseable output.
    nonisolated private static func runLicenseJSON(_ cli: URL) -> LicenseState? {
        guard let r = runCLI(cli, ["license", "--json"]), r.exit == 0,
              let data = r.stdout.data(using: .utf8) else { return nil }
        return parseLicense(data)
    }

    /// Parses the `license --json` payload into a `LicenseState`. Unknown / malformed → `nil`.
    /// `static` (not private) so it's unit-testable with mocked payloads.
    nonisolated static func parseLicense(_ data: Data) -> LicenseState? {
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? String else { return nil }
        switch state {
        case "licensed":
            return .licensed(email: json["email"] as? String,
                             usage: json["activation_usage"] as? Int,
                             limit: json["activation_limit"] as? Int,
                             keyHint: json["key_hint"] as? String)
        case "trial":
            return .trial(daysRemaining: json["days_remaining"] as? Int ?? 0)
        case "expired":
            return .expired
        default:
            return nil
        }
    }

    /// Runs the `jackmoebius` CLI, capturing stdout + stderr + exit code (`nil` if it can't launch).
    /// Off-main. Inherits the process environment (not overridden). Reused by the license commands.
    nonisolated static func runCLI(_ cli: URL, _ args: [String]) -> (stdout: String, stderr: String, exit: Int32)? {
        let process = Process()
        process.executableURL = cli
        process.arguments     = args
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe
        do {
            try process.run()
            // Drain before waiting (small payloads; avoids a full-pipe stall).
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? "",
                    process.terminationStatus)
        } catch {
            return nil
        }
    }

    /// Activates a license key on this Mac. **Network, up to ~15 s → call inside a `Task`.**
    /// Needs an internet connection. Throws `LicenseCLIError` (message + `code`) on failure;
    /// refreshes `license` on success.
    func activateLicense(_ key: String) async throws { try await runLicenseCommand(["license", "activate", key]) }

    /// Re-validates the license with the server: refreshes the seat counter and catches a
    /// revocation made elsewhere promptly (the daemon only re-checks while JACK is running).
    /// **Network → call inside a `Task`.** Throws on failure; best-effort at call sites.
    func refreshLicenseOnline() async throws { try await runLicenseCommand(["license", "refresh"]) }

    /// Runs a license command with `--json` off-main. On failure throws a `LicenseCLIError` carrying
    /// the CLI's `message` + machine-readable `code`; on success re-reads the offline state so
    /// `license` reflects the change immediately.
    private func runLicenseCommand(_ args: [String]) async throws {
        guard let cli = executableURL else { throw LicenseCLIError(message: "JackMoebius is not installed.") }
        let result = await Task.detached { Self.runCLI(cli, args + ["--json"]) }.value
        guard let r = result else { throw LicenseCLIError(message: "Couldn't run jackmoebius.") }
        if r.exit != 0 {
            // A failed activate/refresh prints {"error":"<code>","message":"<human>"} to stdout.
            let (code, message) = Self.parseCommandError(r.stdout)
            let human = message ?? r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LicenseCLIError(message: human.isEmpty ? "The command failed (exit \(r.exit))." : human,
                                  code: code)
        }
        refreshLicense()
    }

    /// Extracts `{"error":"<code>","message":"<human>"}` from a failed activate/refresh `--json`
    /// payload; returns `(nil, nil)` when the output isn't the expected JSON object.
    nonisolated static func parseCommandError(_ stdout: String) -> (code: String?, message: String?) {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        return (json["error"] as? String, json["message"] as? String)
    }

    // MARK: - Deep link (jackmate://)

    /// Handles a `jackmate://activate?key=<KEY>` deep link by opening the licence sheet with the
    /// key pre-filled. It only routes to the existing GUI activation flow: the user still presses
    /// Activate, which shells out to the closed CLI. A deep link never reads or writes licence
    /// storage.
    ///
    /// The `activate` host always opens the sheet, so a link with a missing or malformed key still
    /// lands the user on the activation screen (blank field) rather than a silent focus. The key
    /// comes from an external URL and is therefore untrusted: it is URL-decoded by `URLComponents`,
    /// format-checked by `isValidLicenseKey`, and used to pre-fill the field only when well-formed
    /// — an invalid key is never carried into the sheet or the CLI. The method is written to also
    /// serve a future Universal Link (an `https` URL restricted to the official site), which would
    /// branch here on `scheme`/`host` and reuse the same validation and shell-out.
    ///
    /// - Returns: `true` when the URL was a recognised activation request, so the caller can tell
    ///   it apart from any other `jackmate://` link (which just brings the app forward).
    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "jackmate" else { return false }
        // Only react to known hosts; a bare `jackmate://` just brings the app forward.
        guard url.host?.lowercased() == "activate" else { return false }
        // Pre-fill only a well-formed key; a missing/malformed one still opens the sheet blank.
        if let rawKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "key" })?.value,
           Self.isValidLicenseKey(rawKey) {
            pendingActivationKey = rawKey
        }
        showLicenseSheet = true
        return true
    }

    /// Validates a licence key that arrived from an untrusted URL before it reaches the CLI.
    /// Accepts only ASCII letters, digits and dashes (min 8 chars) — enough for the UUID-shaped
    /// keys, and safe to pass as a standalone process argument.
    nonisolated static func isValidLicenseKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z0-9-]{8,}$", options: .regularExpression) != nil
    }

    // MARK: - App selector

    /// Refreshes the app list via a single `apps` call (symmetric, both directions).
    /// No-op (clears the list) unless the daemon is active; called while the panel is open.
    func refreshApps() {
        guard state == .active else { apps = []; return }
        guard !appsInFlight, pendingMutations == 0 else { return }
        appsInFlight = true
        Task.detached {
            let merged = Self.fetchApps()
            await MainActor.run {
                self.appsInFlight = false
                // A mutation may have started while this fetch was in flight —
                // don't let its (now stale) result overwrite the mutated state.
                if self.pendingMutations == 0 {
                    self.apps = merged
                    self.refreshAppVolumes()
                }
            }
        }
    }

    // MARK: - Studio snapshot

    /// Captures a fresh JackMoebius exposure + volume snapshot for saving into a studio.
    ///
    /// Returns `nil` when the daemon isn't active, so the studio then carries no
    /// JackMoebius state and behaves like a pre-JackMoebius one. Performs its own IPC
    /// fetch rather than reading the cache, staying correct even when the panel was never
    /// opened (the app/volume cache is only refreshed while the panel is visible).
    func snapshotForStudio() async -> StudioJackMoebius? {
        guard state == .active else { return nil }
        let apps = await Task.detached { () -> [StudioJMApp] in
            Self.fetchApps().compactMap { app -> StudioJMApp? in
                guard app.outExposed || app.inExposed else { return nil }
                let vol = app.outExposed ? Self.fetchAppVolume(name: app.name) : nil
                return Self.studioEntry(for: app, volume: vol)
            }
        }.value
        return StudioJackMoebius(apps: apps)
    }

    /// The studio entry of one exposed app: its backing and channel count per exposed direction,
    /// plus its volume state. `static`, pure and `nonisolated` so both snapshots (and tests) share it.
    nonisolated static func studioEntry(for app: JackMoebiusApp, volume vol: JMAppVolume?) -> StudioJMApp {
        let locked = vol?.locked ?? false
        return StudioJMApp(
            key:         app.key,
            name:        app.name,
            outChannels: app.outExposed ? app.outChannelCount : nil,
            inChannels:  app.inExposed ? app.inChannelCount : nil,
            outBacking:  app.outExposed ? app.outBacking.rawValue : nil,
            inBacking:   app.inExposed ? app.inBacking.rawValue : nil,
            locked:      locked,
            gain:        locked ? nil : (vol?.gain ?? 1.0))
    }

    /// What it takes to bring one running app to the state a studio saved for it.
    nonisolated struct RestoreStep: Equatable {
        var inSide:    JMSide? = nil   // side to apply (nil = leave the input as it is)
        var outSide:   JMSide? = nil
        var removeIn:  Bool = false    // hide the input (`jack_remove_in`)
        var removeOut: Bool = false
        var isEmpty: Bool { inSide == nil && outSide == nil && !removeIn && !removeOut }
    }

    /// Diffs one app against its saved studio entry (`nil` = the studio does not list the app, so
    /// anything exposed is hidden). A direction already in the saved state is left alone — which
    /// avoids a needless card rebuild. `static` and pure so it is unit-testable.
    nonisolated static func restoreStep(for app: JackMoebiusApp, saved: StudioJMApp?) -> RestoreStep {
        var step = RestoreStep()
        if let wantOut = saved?.outSide {
            if !app.outExposed || app.currentOut != wantOut { step.outSide = wantOut }
        } else if app.outExposed {
            step.removeOut = true
        }
        if let wantIn = saved?.inSide {
            if !app.inExposed || app.currentIn != wantIn { step.inSide = wantIn }
        } else if app.inExposed {
            step.removeIn = true
        }
        return step
    }

    /// Synchronous mirror of `snapshotForStudio`, built from the live cache (`apps`,
    /// `appVolumes`) with **no IPC**, so `isModified` can detect JackMoebius
    /// changes during a view update. `nil` when the daemon isn't active. Per-app changes are
    /// reflected instantly thanks to the optimistic cache updates of `apply`/`hide`/`setAppLocked`/…
    func currentStudioSnapshot() -> StudioJackMoebius? {
        guard state == .active else { return nil }
        let snapshot = apps.compactMap { app -> StudioJMApp? in
            guard app.outExposed || app.inExposed else { return nil }
            return Self.studioEntry(for: app, volume: appVolumes[app.key])
        }
        return StudioJackMoebius(apps: snapshot)
    }

    /// Restores a studio's JackMoebius state at load time: (re)starts the daemon, launches the
    /// exposed CoreAudio apps, diffs exposures to match the studio, then restores the
    /// per-app volumes. Best-effort with timeouts; a `path:` app (no bundle ID) can't be
    /// relaunched and is skipped. The IPC mutations run off-main in one batch to avoid the
    /// per-click fetch storm of the interactive setters.
    @discardableResult
    func restoreForStudio(_ saved: StudioJackMoebius) async -> [String] {
        guard installed, !daemonTooOld else { return [] }
        suppressEventRefetch = true
        defer { suppressEventRefetch = false }

        // 1. Ensure the daemon is active (the studio decides — auto-launch is suppressed).
        if state != .active {
            activate()
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline && state != .active {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        guard state == .active else { return [] }

        // 2. Fresh app list (the panel-gated app refresh doesn't run during a load).
        apps = await Task.detached { Self.fetchApps() }.value

        // 3. Launch the studio's CoreAudio apps that aren't registered yet; wait for them.
        let present = Set(apps.map { $0.key })
        var launched: Set<String> = []
        for s in saved.apps where !present.contains(s.key) && !s.key.hasPrefix("path:") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.key) {
                do {
                    try await NSWorkspace.shared.openApplication(
                        at: url, configuration: NSWorkspace.OpenConfiguration())
                    launched.insert(s.key)
                } catch { }
            }
        }
        if !launched.isEmpty {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                let current = await Task.detached { Self.fetchApps() }.value
                apps = current
                if launched.isSubset(of: Set(current.map { $0.key })) { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // 4. Apply exposures → per-app volumes in one off-main batch, then re-fetch. Each app gets
        //    at most one `jack_apply` carrying only the directions that differ from the studio.
        let savedApps  = saved.apps
        let (refreshed, failed) = await Task.detached { () -> ([JackMoebiusApp], [String]) in
            let current = Self.fetchApps()
            let wanted  = Dictionary(savedApps.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            var failedNames: [String] = []

            // Exposures — the studio is the full desired state (add/keep its apps, remove others).
            for app in current {
                let step = Self.restoreStep(for: app, saved: wanted[app.key])
                if step.removeOut { _ = JackMoebiusIPC.request("jack_remove", ["app": app.key]) }
                if step.removeIn  { _ = JackMoebiusIPC.request("jack_remove_in", ["app": app.key]) }
                if step.inSide != nil || step.outSide != nil {
                    var params: [String: Any] = ["app": app.key]
                    if let s = step.inSide  { params["in"]  = s.requestObject }
                    if let s = step.outSide { params["out"] = s.requestObject }
                    if case .failure = JackMoebiusIPC.request("jack_apply", params) {
                        failedNames.append(app.name)
                    }
                }
            }
            // Studio apps that are not running (and could not be launched): no box will appear.
            let runningKeys = Set(current.map { $0.key })
            for s in savedApps where !runningKeys.contains(s.key) { failedNames.append(s.name) }

            // Per-app volumes (set_volume is keyed by app NAME). Locked apps follow master
            // (no gain sent); unlocked apps get their independent gain.
            for s in savedApps where !failedNames.contains(s.name) {
                if s.locked {
                    _ = JackMoebiusIPC.request("set_volume", ["app": s.name, "locked": true])
                } else if let g = s.gain {
                    _ = JackMoebiusIPC.request("set_volume", ["app": s.name, "locked": false, "gain": g])
                }
            }
            return (Self.fetchApps(), failedNames)
        }.value

        apps = refreshed
        refreshStatus()
        refreshAppVolumes()
        return failed
    }

    /// Un-exposes every currently exposed app (`jack_remove`/`jack_remove_in`), keeping their
    /// bus-channel reservations (freeing those is a user action via the advanced panel). Used
    /// when stopping a studio so the JackMoebius boxes disappear from the patchbay cleanly, and
    /// a later restart doesn't re-expose the previous studio's apps.
    func removeAllExposures() async {
        guard state == .active else { return }
        suppressEventRefetch = true
        defer { suppressEventRefetch = false }
        let refreshed = await Task.detached { () -> [JackMoebiusApp] in
            let current = Self.fetchApps()
            for app in current {
                if app.outExposed { _ = JackMoebiusIPC.request("jack_remove", ["app": app.key]) }
                if app.inExposed  { _ = JackMoebiusIPC.request("jack_remove_in", ["app": app.key]) }
            }
            return Self.fetchApps()
        }.value
        apps = refreshed
    }

    // MARK: - Per-app volume (lock)

    /// Queries the output-volume state of out-exposed apps that aren't cached yet, and
    /// prunes entries for apps no longer out-exposed. Lazy: the per-app gain only changes
    /// through JackMate, so cached entries are never re-queried.
    func refreshAppVolumes() {
        guard state == .active else { appVolumes = [:]; volumePreviewExpanded = []; return }
        let outExposed = Set(apps.filter { $0.outExposed }.map { $0.key })
        appVolumes = appVolumes.filter { outExposed.contains($0.key) }
        volumePreviewExpanded = volumePreviewExpanded.filter { outExposed.contains($0) }
        let needed = apps.filter { $0.outExposed && appVolumes[$0.key] == nil }
                         .map { (key: $0.key, name: $0.name) }
        guard !needed.isEmpty else { return }
        Task.detached {
            var fetched: [String: JMAppVolume] = [:]
            for app in needed {
                if let v = Self.fetchAppVolume(name: app.name) { fetched[app.key] = v }
            }
            let result = fetched   // immutable snapshot for the main-actor hop
            await MainActor.run {
                for (k, v) in result where self.appVolumes[k] == nil { self.appVolumes[k] = v }
            }
        }
    }

    /// Off-main: `set_volume {app}` with no `locked`/`gain` = query → `{locked, gain}`.
    nonisolated private static func fetchAppVolume(name: String) -> JMAppVolume? {
        guard case .success(let d) = JackMoebiusIPC.request("set_volume", ["app": name]),
              let dict = d as? [String: Any] else { return nil }
        return JMAppVolume(locked: dict["locked"] as? Bool ?? true,
                           gain: dict["gain"] as? Double ?? 1.0)
    }

    /// Locks (follow master) or unlocks (independent) an app's output volume. Unlocking
    /// omits `gain` → the daemon opens at the current master (no level jump).
    func setAppLocked(_ app: JackMoebiusApp, _ locked: Bool, master: Double?) {
        // Optimistic; re-locking re-shows the preview (state ②).
        var v = appVolumes[app.key] ?? JMAppVolume(locked: locked, gain: 1.0)
        v.locked = locked
        // Unlocking opens at the current master (no jump) → mirror that optimistically so
        // the slider doesn't flash the old cached gain before the daemon replies. `master`
        // is a scalar (position) → convert to the daemon's linear gain via the taper.
        if !locked, let master { v.gain = VolumeTaper.scalarToGain(master) }
        appVolumes[app.key] = v
        if locked { volumePreviewExpanded.insert(app.key) }
        // Capture only Sendable values; build the params dict inside the task.
        let name = app.name, key = app.key, fallbackGain = v.gain
        Task.detached {
            // Unlocking omits `gain` → the daemon opens at the current master (no jump).
            let params: [String: Any] = ["app": name, "locked": locked]
            if case .success(let d) = JackMoebiusIPC.request("set_volume", params),
               let dict = d as? [String: Any] {
                let result = JMAppVolume(locked: dict["locked"] as? Bool ?? locked,
                                         gain: dict["gain"] as? Double ?? fallbackGain)
                await MainActor.run { self.appVolumes[key] = result }
            }
        }
    }

    /// Sets an unlocked app's independent output gain.
    func setAppGain(_ app: JackMoebiusApp, _ gain: Double) {
        let g = min(max(gain, 0), 1)
        appVolumes[app.key] = JMAppVolume(locked: false, gain: g)
        let name = app.name
        Task.detached {
            _ = JackMoebiusIPC.request("set_volume", ["app": name, "locked": false, "gain": g])
        }
    }

    /// UI: expand (state ①→②) / collapse (②→①) a locked app's volume preview.
    func expandVolumePreview(_ key: String)   { volumePreviewExpanded.insert(key) }
    func collapseVolumePreview(_ key: String) { volumePreviewExpanded.remove(key) }

    /// Off-main: the enriched `apps` call carries both directions per app (IPC v2):
    /// `out_exposed`/`in_exposed` (intent), `out_backing`/`in_backing` (shared or dedicated),
    /// `out_channels`/`in_channels` (reservation lists) + `can_capture`. One call replaces the
    /// old apps_in/jack_list_in/assignments merge.
    nonisolated private static func fetchApps() -> [JackMoebiusApp] {
        guard case .success(let d) = JackMoebiusIPC.request("apps"),
              let rows = d as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> JackMoebiusApp? in
            // Running apps only — closed-but-reserved apps (pid 0) are hidden; the next
            // refresh brings them back when they relaunch (pid reappears). Blacklisted apps
            // are hidden from the selector (the daemon also refuses jack_add on them).
            guard let app = parseApp(row), app.pid > 0,
                  !(row["blacklisted"] as? Bool ?? false) else { return nil }
            return app
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parses one entry of the `apps` reply. `nil` when `key`/`name` are missing. Missing
    /// backing fields (older daemons) read as the model's historical defaults.
    /// `static` (not private) so it is unit-testable with mocked rows.
    nonisolated static func parseApp(_ row: [String: Any]) -> JackMoebiusApp? {
        guard let key = row["key"] as? String, let name = row["name"] as? String else { return nil }
        return JackMoebiusApp(
            key: key, name: name, pid: row["pid"] as? Int ?? 0,
            outExposed: row["out_exposed"] as? Bool ?? false,
            inExposed:  row["in_exposed"] as? Bool ?? false,
            outBacking: JMBacking(rawValue: row["out_backing"] as? String ?? "") ?? .shared,
            inBacking:  JMBacking(rawValue: row["in_backing"] as? String ?? "") ?? .dedicated,
            outWidth:   (row["out_channels"] as? [Any])?.count ?? 0,
            inWidth:    (row["in_channels"] as? [Any])?.count ?? 0,
            canCapture: row["can_capture"] as? Bool ?? false)
    }

    /// Off-main: merges `jack_list` (`out_status`) and `jack_list_in` (`in_status`) into
    /// a per-box status map keyed by bundle ID. Each list is queried only when its
    /// direction has an exposed box (`fetchOut`/`fetchIn`), so an idle direction costs
    /// no round-trip. `absent`/unknown values decode to `nil` (dropped), so the map only
    /// carries the states the canvas can render.
    nonisolated private static func fetchBoxStatus(fetchOut: Bool, fetchIn: Bool)
        -> (status: [String: JMBoxStatus], shared: [JMSharedBox], sharedOut: [String]) {
        var result: [String: JMBoxStatus] = [:]
        var shared: [JMSharedBox] = []
        var sharedOut: [String] = []
        if fetchOut, case .success(let d) = JackMoebiusIPC.request("jack_list"),
           let rows = d as? [[String: Any]] {
            for row in rows {
                guard let key = row["key"] as? String else { continue }
                result[key, default: JMBoxStatus()].out =
                    JMRoutingStatus(rawValue: row["out_status"] as? String ?? "")
                // Present only on mismatch; nil otherwise (and on older daemons).
                result[key, default: JMBoxStatus()].outDevice = row["current_device"] as? String
                // A live output that is not a dedicated card is the shared stereo stem: that app plays to
                // the Mac's default output.
                if row["backing"] as? String != "private", let name = row["name"] as? String {
                    sharedOut.append(name)
                }
            }
        }
        if fetchIn, case .success(let d) = JackMoebiusIPC.request("jack_list_in"),
           let rows = d as? [[String: Any]] {
            for row in rows {
                guard let key = row["key"] as? String else { continue }
                result[key, default: JMBoxStatus()].input =
                    JMRoutingStatus(rawValue: row["in_status"] as? String ?? "")
                result[key, default: JMBoxStatus()].inDevice = row["current_device"] as? String
                // Apps in shared input mode have no JACK port: list the running ones (an app that
                // is not running reports `absent`) so the patchbay can draw their virtual box.
                if row["backing"] as? String == "shared", row["in_status"] as? String != "absent",
                   let name = row["name"] as? String {
                    shared.append(JMSharedBox(key: key, name: name))
                }
            }
        }
        return (result, shared, sharedOut)
    }

    // MARK: - Exposure mutations

    /// Hides one direction of an app (`jack_remove` / `jack_remove_in`): immediate, and it never
    /// rebuilds a card. Exposing a direction goes through the exposure panel and `apply`.
    /// Same as `hide`, but asks first when it removes a **shared input** while other apps stay in
    /// shared mode: the app would still hear the Mac's default input (which JackMoebius keeps), so
    /// "removed" would be misleading. Nothing is sent until the user confirms.
    func requestHide(_ app: JackMoebiusApp, input: Bool) {
        let others = apps.filter { $0.key != app.key && $0.inExposed && $0.inBacking == .shared }.map(\.name)
        if input, app.inExposed, app.inBacking == .shared, !others.isEmpty {
            pendingSharedInputRemoval = PendingSharedInputRemoval(app: app, otherApps: others)
        } else {
            hide(app, input: input)
        }
    }

    func confirmSharedInputRemoval(_ pending: PendingSharedInputRemoval) {
        pendingSharedInputRemoval = nil
        hide(pending.app, input: true)
    }

    func cancelSharedInputRemoval() {
        if pendingSharedInputRemoval != nil { pendingSharedInputRemoval = nil }
    }

    func hide(_ app: JackMoebiusApp, input: Bool) {
        optimistically(app.key) { if input { $0.inExposed = false } else { $0.outExposed = false } }
        configuredSides.remove(Self.sideID(app.key, input))
        sendRemove(input ? "jack_remove_in" : "jack_remove", appKey: app.key)
    }

    /// Applies the requested side(s) of one app in a **single** `jack_apply` call: all-or-nothing,
    /// and the app's card is created, rebuilt, kept or deleted at most once even when both
    /// directions change. A direction left `nil` is untouched. The post-call fetch is authoritative.
    ///
    /// The app's cables are noted first and restored once its ports are back (see `JMRewire`). When
    /// that would put sources on a shared input other apps hear, nothing is sent until the user
    /// chooses (`pendingApply`), unless `rewire` already says what to do.
    func apply(_ app: JackMoebiusApp, in inSide: JMSide? = nil, out outSide: JMSide? = nil,
               rewire choice: RewireChoice = .ask, cleanup cleanupChoice: CleanupChoice = .ask) {
        guard inSide != nil || outSide != nil else { return }
        // Leaving the shared input for a dedicated card: the cables drawn only for this app no longer
        // serve anyone — offer to cut them, before anything changes.
        var cleanupWires: [JMWire] = []
        let leavesSharedInput = (inSide?.backing == .dedicated) && app.inExposed && app.inBacking == .shared
        if leavesSharedInput {
            cleanupWires = patchbayManager?.originCleanupCandidates(forApp: app.key) ?? []
            if cleanupChoice == .ask, !cleanupWires.isEmpty, let side = inSide {
                let others = apps.filter { $0.key != app.key && $0.inExposed && $0.inBacking == .shared }.map(\.name)
                pendingCleanup = PendingCleanup(app: app, inSide: side, wires: cleanupWires, otherApps: others)
                return
            }
        }
        let cutWires = cleanupChoice == .remove ? cleanupWires : []
        let otherSharers = apps.filter { $0.key != app.key && $0.inExposed && $0.inBacking == .shared }.map(\.name)
        let plan = JMRewire.plan(client: app.name, app: app, inSide: inSide, outSide: outSide,
                                 connections: patchbayManager?.connections ?? [],
                                 otherSharedInputApps: otherSharers)
        if choice == .ask && !plan.needsConfirmation.isEmpty {
            pendingApply = PendingApply(app: app, inSide: inSide, outSide: outSide, plan: plan)
            return
        }
        var wires = plan.automatic
        if choice == .reconnect { wires += plan.needsConfirmation }

        if inSide  != nil { configuredSides.insert(Self.sideID(app.key, true)) }
        if outSide != nil { configuredSides.insert(Self.sideID(app.key, false)) }
        optimistically(app.key) { a in
            if let s = inSide {
                a.inExposed = true
                a.inBacking = s.backing
                if s.backing == .dedicated { a.inWidth = s.channels }
            }
            if let s = outSide {
                a.outExposed = true
                a.outBacking = s.backing
                a.outWidth = s.channels
            }
        }
        let key = app.key
        runMutation(appKey: key, isExposure: true,
                    onSuccess: { [weak self] in
                        self?.remember(key, input: inSide, output: outSide)
                        if !wires.isEmpty { self?.reconnect(wires) }
                        // The app left the shared input: forget it as a cable's origin and cut the
                        // cables the user chose to remove.
                        if leavesSharedInput { self?.patchbayManager?.forgetOrigin(ofApp: key, removing: cutWires) }
                    }) {
            var params: [String: Any] = ["app": key]
            if let s = inSide  { params["in"]  = s.requestObject }
            if let s = outSide { params["out"] = s.requestObject }
            return JackMoebiusIPC.request("jack_apply", params)
        }
    }

    /// The user decided on the clean-up of the shared-input cables drawn for the app: apply, cutting
    /// them or keeping them.
    func confirmCleanup(_ pending: PendingCleanup, remove: Bool) {
        pendingCleanup = nil
        apply(pending.app, in: pending.inSide, cleanup: remove ? .remove : .keep)
    }

    func cancelCleanup() { if pendingCleanup != nil { pendingCleanup = nil } }

    /// The user decided on a held-back apply: send it, reconnecting the cables or not.
    func confirmPendingApply(_ pending: PendingApply, reconnect: Bool) {
        pendingApply = nil
        apply(pending.app, in: pending.inSide, out: pending.outSide, rewire: reconnect ? .reconnect : .skip)
    }

    /// The user cancelled: nothing was sent, nothing changes.
    func cancelPendingApply() {
        if pendingApply != nil { pendingApply = nil }
    }

    /// Well-known apps that have no input selector (they can only follow the default input of the
    /// Mac): their input defaults to the shared default JackMoebius input. Only a default — the
    /// user can change it, and a routing mismatch still catches a wrong guess.
    nonisolated static let sharedInputByDefault: Set<String> = ["com.apple.Safari"]

    /// The side the exposure panel proposes when a direction is switched on: what the daemon already
    /// holds for the app (an existing reservation), else the last choice made for it, else the
    /// model's default (input: a dedicated card of 2, shared for the apps above; output: the shared
    /// stereo stem).
    func suggestedSide(for app: JackMoebiusApp, input: Bool) -> JMSide {
        if input {
            if app.inWidth > 0 || app.inExposed { return app.currentIn }
            if let side = rememberedChoices[app.key]?.input { return side }
            return Self.sharedInputByDefault.contains(app.key) ? .sharedStereo : .dedicated(2)
        } else {
            if app.outExposed || (app.outBacking == .dedicated && app.outWidth > 0) { return app.currentOut }
            return rememberedChoices[app.key]?.output ?? .sharedStereo
        }
    }

    // MARK: - Cables kept across a backing change

    /// Reconnects `wires` as soon as both ends exist in the patchbay (the daemon rebuilds the
    /// box asynchronously), for up to a few seconds. Cables already present are left alone.
    private func reconnect(_ wires: [JMWire]) {
        guard let patchbay = patchbayManager else { return }
        Task { @MainActor in
            var remaining = wires
            let deadline = Date().addingTimeInterval(6)
            while !remaining.isEmpty && Date() < deadline {
                let ports = patchbay.nodes.flatMap { $0.inputs + $0.outputs }
                let byID = Dictionary(ports.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let ready = remaining.filter { byID[$0.from] != nil && byID[$0.to] != nil }
                if !ready.isEmpty {
                    // Re-read the real cables first: the rebuild may have dropped some silently.
                    patchbay.syncConnections()
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    for w in ready {
                        if let from = byID[w.from], let to = byID[w.to] {
                            patchbay.connectPorts(from: from, to: to)
                        }
                    }
                    remaining.removeAll { w in ready.contains(w) }
                }
                if !remaining.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
        }
    }

    // MARK: - Remembered choices

    private static let choicesKey = "JM.exposureChoices"

    /// Last choice per app key and direction, kept by JackMate (the daemon stores no UI default)
    /// and used to prefill the exposure panel at the next exposure.
    @Published private(set) var rememberedChoices: [String: JMExposureChoice] =
        JackMoebiusManager.loadChoices()

    private static func loadChoices() -> [String: JMExposureChoice] {
        guard let data = UserDefaults.standard.data(forKey: choicesKey),
              let decoded = try? JSONDecoder().decode([String: JMExposureChoice].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Stores the sides that were just applied for an app (a direction left `nil` keeps its entry).
    private func remember(_ key: String, input: JMSide?, output: JMSide?) {
        var choice = rememberedChoices[key] ?? JMExposureChoice()
        if let input  { choice.input  = input }
        if let output { choice.output = output }
        rememberedChoices[key] = choice
        if let data = try? JSONEncoder().encode(rememberedChoices) {
            UserDefaults.standard.set(data, forKey: Self.choicesKey)
        }
    }

    // MARK: - Blacklist

    /// The app awaiting blacklist confirmation (an exposed app must be removed first).
    @Published var blacklistConfirmApp: JackMoebiusApp? = nil

    /// Entry point from the eye.slash button: blacklist directly when the app isn't
    /// exposed, else ask for confirmation (the daemon refuses blacklisting an exposed app).
    func requestBlacklist(_ app: JackMoebiusApp) {
        if app.outExposed || app.inExposed {
            blacklistConfirmApp = app
        } else {
            performBlacklist(app, removeFirst: false)
        }
    }

    /// Blacklists `app`. When `removeFirst`, unexposes it (out + in) first, then adds it
    /// to the blacklist. Optimistically drops it from the selector.
    func performBlacklist(_ app: JackMoebiusApp, removeFirst: Bool) {
        blacklistConfirmApp = nil
        apps.removeAll { $0.key == app.key }
        guard state == .active else { return }
        let key       = app.key
        let removeOut = removeFirst && app.outExposed
        let removeIn  = removeFirst && app.inExposed
        pendingMutations += 1
        Task.detached {
            if removeOut { _ = JackMoebiusIPC.request("jack_remove", ["app": key]) }
            if removeIn  { _ = JackMoebiusIPC.request("jack_remove_in", ["app": key]) }
            _ = JackMoebiusIPC.request("blacklist_add", ["app": key])
            let merged = Self.fetchApps()
            await MainActor.run {
                self.apps = merged
                self.pendingMutations -= 1
            }
        }
    }

    // MARK: - Advanced config (blacklist management)

    /// Whether the advanced configuration sheet is presented.
    @Published var showAdvanced = false
    /// The current user blacklist (refreshed when the advanced sheet opens / mutates).
    @Published private(set) var blacklist: [JackMoebiusBlacklistEntry] = []

    /// Set by `openAdvanced(reservations: true)`: the sheet opens on its Reservations tab, once.
    var advancedOpensOnReservations = false

    /// Opens the advanced configuration, on the blacklist tab or (`reservations: true`) on the
    /// channel reservations (e.g. from the capacity notice).
    func openAdvanced(reservations: Bool = false) {
        advancedOpensOnReservations = reservations
        showAdvanced = true
        refreshBlacklist()
        refreshReservations()
    }

    nonisolated private static func fetchBlacklist() -> [JackMoebiusBlacklistEntry] {
        guard case .success(let d) = JackMoebiusIPC.request("blacklist_show"),
              let rows = d as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> JackMoebiusBlacklistEntry? in
            guard let key = row["key"] as? String else { return nil }
            let raw = row["name"] as? String ?? key
            return JackMoebiusBlacklistEntry(key: key, name: displayName(forKey: key, fallback: raw))
        }
        .filter { !$0.isDefault }   // hide the shipped defaults — not user-removable
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A friendly app name. The daemon's `blacklist_show` name is best-effort; when it
    /// fell back to the bundle ID, resolve the localized app name via Launch Services.
    nonisolated private static func displayName(forKey key: String, fallback: String) -> String {
        guard fallback == key,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else {
            return fallback
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    func refreshBlacklist() {
        guard state == .active else { blacklist = []; return }
        Task.detached {
            let entries = Self.fetchBlacklist()
            await MainActor.run { self.blacklist = entries }
        }
    }

    /// Un-blacklists an app (defaults are protected). Refreshes the blacklist + selector.
    func unblacklist(_ entry: JackMoebiusBlacklistEntry) {
        guard !entry.isDefault, state == .active else { return }
        blacklist.removeAll { $0.key == entry.key }   // optimistic
        let key = entry.key
        Task.detached {
            _ = JackMoebiusIPC.request("blacklist_remove", ["app": key])
            let entries = Self.fetchBlacklist()
            let merged  = Self.fetchApps()
            await MainActor.run { self.blacklist = entries; self.apps = merged }
        }
    }

    /// Restores the shipped default blacklist.
    func resetBlacklist() {
        guard state == .active else { return }
        Task.detached {
            _ = JackMoebiusIPC.request("blacklist_reset")
            let entries = Self.fetchBlacklist()
            let merged  = Self.fetchApps()
            await MainActor.run { self.blacklist = entries; self.apps = merged }
        }
    }

    // MARK: - Channel reservations

    /// Persistent channel reservations (out and/or in), incl. non-running apps.
    @Published private(set) var reservations: [JackMoebiusReservation] = []

    /// Reservations are derived from the `apps` rows, which carry the real backing and the channel
    /// lists (dormant apps included): the old `jack_assignments` only gave an output offset.
    nonisolated private static func fetchReservations() -> [JackMoebiusReservation] {
        guard case .success(let d) = JackMoebiusIPC.request("apps"),
              let rows = d as? [[String: Any]] else { return [] }
        func lanes(_ row: [String: Any], _ field: String) -> [Int] {
            (row[field] as? [Any])?.compactMap { $0 as? Int } ?? []
        }
        return rows.compactMap { row -> JackMoebiusReservation? in
            guard let key = row["key"] as? String else { return nil }
            let out = lanes(row, "out_channels"), inn = lanes(row, "in_channels")
            let outHeld = lanes(row, "out_held_channels"), inHeld = lanes(row, "in_held_channels")
            let inShared = (row["in_exposed"] as? Bool ?? false) && (row["in_backing"] as? String) == "shared"
            guard !out.isEmpty || !inn.isEmpty || !outHeld.isEmpty || !inHeld.isEmpty || inShared else { return nil }
            let name = displayName(forKey: key, fallback: row["name"] as? String ?? key)
            return JackMoebiusReservation(
                key: key, name: name,
                outBacking: JMBacking(rawValue: row["out_backing"] as? String ?? "") ?? .shared,
                outChannels: out, inChannels: inn, outHeld: outHeld, inHeld: inHeld, inShared: inShared)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refreshReservations() {
        guard state == .active else { reservations = []; return }
        Task.detached {
            let entries = Self.fetchReservations()
            await MainActor.run { self.reservations = entries }
        }
    }

    /// Frees the app's output reservation (`jack_clear_assignment` — chains an implicit
    /// remove first if the app is currently exposed).
    func clearOutReservation(_ entry: JackMoebiusReservation) {
        clearReservation("jack_clear_assignment", app: entry.key)
    }

    /// Destroys the app's input card and frees its input reservation (`jack_clear_in`).
    func clearInReservation(_ entry: JackMoebiusReservation) {
        clearReservation("jack_clear_in", app: entry.key)
    }

    // MARK: Free the unused channels of a card (`jack_rebuild`)

    /// A rebuild waiting for the user's yes: the app sees its device disappear for a moment.
    @Published var pendingRebuild: PendingRebuild? = nil

    struct PendingRebuild: Equatable {
        let key: String
        let name: String
        let heldCount: Int
    }

    func requestRebuild(_ entry: JackMoebiusReservation) {
        guard entry.heldCount > 0 else { return }
        pendingRebuild = PendingRebuild(key: entry.key, name: entry.name, heldCount: entry.heldCount)
    }

    func cancelRebuild() { if pendingRebuild != nil { pendingRebuild = nil } }

    /// Rebuilds the app's card as it is (same sides, widths and ports) in one call, which frees the channels
    /// a dead stream still holds. The card's JACK ports are unregistered then registered again, which drops
    /// their cables: JackMate notes them first and restores them once the ports are back.
    func confirmRebuild(_ pending: PendingRebuild) {
        pendingRebuild = nil
        guard state == .active else { return }
        let key = pending.key
        // The cables of the app's box (`<name>:out_k` / `<name>:in_k`), as they are now.
        let boxName = apps.first(where: { $0.key == key })?.name ?? pending.name
        let prefix = boxName + ":"
        let wires = (patchbayManager?.connections ?? [])
            .filter { $0.from.hasPrefix(prefix) || $0.to.hasPrefix(prefix) }
            .map { JMWire(from: $0.from, to: $0.to) }
        applyErrors[key] = nil
        Task.detached {
            let result = JackMoebiusIPC.request("jack_rebuild", ["app": key])
            var rebuilt = false
            var refusal: JMApplyError? = nil
            switch result {
            case .success(let data):
                rebuilt = (data as? [String: Any])?["rebuilt"] as? Bool ?? false
            case .failure(.daemonError(let message, let code, let details)):
                refusal = JMApplyError(code: code, message: message, details: details)
            case .failure:
                break
            }
            let entries = Self.fetchReservations()
            let merged  = Self.fetchApps()
            let didRebuild = rebuilt, failure = refusal   // immutable snapshots for the main-actor hop
            await MainActor.run {
                self.reservations = entries
                self.apps = merged
                self.applyErrors[key] = failure
                if didRebuild, !wires.isEmpty { self.reconnect(wires) }
                self.refreshStatus()   // the capacity gauges change
            }
        }
    }

    private func clearReservation(_ command: String, app key: String) {
        guard state == .active else { return }
        Task.detached {
            _ = JackMoebiusIPC.request(command, ["app": key])
            let entries = Self.fetchReservations()
            let merged  = Self.fetchApps()
            await MainActor.run { self.reservations = entries; self.apps = merged }
        }
    }

    /// Instant local change so the toggle reflects the click immediately; the
    /// post-mutation fetch then confirms (or corrects if the daemon rejects it).
    private func optimistically(_ key: String, _ change: (inout JackMoebiusApp) -> Void) {
        if let i = apps.firstIndex(where: { $0.key == key }) { change(&apps[i]) }
    }

    /// Hides one side of an app (`jack_remove` / `jack_remove_in`: never recreates a card).
    private func sendRemove(_ command: String, appKey: String) {
        runMutation(appKey: appKey, isExposure: false) {
            JackMoebiusIPC.request(command, ["app": appKey])
        }
    }

    /// Runs a JACK-first mutation off-main, then re-fetches the authoritative state.
    /// Concurrent refreshes pause (`pendingMutations`) so a stale fetch can't revert the toggle.
    /// `isExposure` marks the calls that can be refused by the licensing check.
    private func runMutation(appKey: String, isExposure: Bool,
                             onSuccess: (@MainActor () -> Void)? = nil,
                             send: @escaping @Sendable () -> Result<Any?, JackMoebiusIPCError>) {
        guard state == .active else { return }
        pendingMutations += 1
        let cli = executableURL   // captured for the off-main licensing re-check
        Task.detached {
            let result = send()
            // A new exposure can be refused when the licence lapses mid-session (enforcement
            // on): the daemon answers `code:"licensing"`, or it has already self-stopped
            // (unreachable) while `license --json` reports expired. The toggle reverts on its
            // own via the authoritative re-fetch below; here we just surface the
            // purchase/activation sheet.
            let refused: Bool = {
                guard isExposure else { return false }
                switch result {
                case .failure(.daemonError(_, let code, _)) where code == "licensing":
                    return true
                case .failure(.notRunning):
                    if let cli, case .expired? = Self.runLicenseJSON(cli) { return true }
                    return false
                default:
                    return false
                }
            }()
            let succeeded: Bool = { if case .success = result { return true }; return false }()
            // A refusal worth telling (not the licensing one, which has its own sheet): the daemon's sentence.
            let refusal: JMApplyError? = {
                guard isExposure, case .failure(.daemonError(let message, let code, let details)) = result,
                      code != "licensing", !message.isEmpty else { return nil }
                return JMApplyError(code: code, message: message, details: details)
            }()
            let merged = Self.fetchApps()
            await MainActor.run {
                self.apps = merged
                self.pendingMutations -= 1
                if isExposure { self.applyErrors[appKey] = refusal }   // cleared by a success or a new try
                if succeeded { onSuccess?() }
                if refused {
                    self.refreshLicense()
                    self.showLicensingRefusal = true
                }
            }
        }
    }

    // MARK: - Event stream (daemon push; replaces the fixed-rate poll)

    /// Opens the persistent `subscribe` connection and keeps it alive while JACK runs: each
    /// invalidation event re-fetches the matching query, and the connection state IS the daemon
    /// liveness (EOF = stop/crash). Reconnects with a backoff (the daemon may not be listening
    /// yet just after `activate()`).
    private func startEventStream() {
        guard eventStreamTask == nil else { return }
        eventStreamTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                // Immutable snapshot for the subscribe callbacks: the outer captured `self`
                // can't be referenced from the concurrently-run event closures (Swift 6).
                let manager = self
                let outcome = JackMoebiusIPC.subscribe(
                    isCancelled: { Task.isCancelled },
                    onOpened:    { Task { @MainActor in manager?.onEventStreamOpened() } },
                    onEvent:     { event in Task { @MainActor in manager?.handleEvent(event) } })
                if Task.isCancelled { break }
                if case .closed(let clean) = outcome {
                    await manager?.handleStreamClosed(clean: clean)
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // backoff before reconnect
            }
        }
    }

    /// Tears down the event stream (JACK down / teardown), clearing the daemon-derived state.
    private func stopEventStream() {
        eventStreamTask?.cancel()
        eventStreamTask = nil
        pollInFlight = false
        appsInFlight = false
        apps = []
        boxStatus = [:]
        capacity = nil
        transportProblem = nil
        sharedInputBoxes = []
        sharedOutputApps = []
    }

    /// First fetch right after subscribing — `subscribe`-before-snapshot: any change in the gap
    /// arrives as an event *after* this fetch, so nothing is missed.
    private func onEventStreamOpened() {
        refreshStatus()
        if showPanel { refreshApps() }
    }

    /// Maps an invalidation event to the existing re-fetch (single source of truth = the query
    /// handler). Ignored during a controlled batch (studio load/stop) whose own mutations echo
    /// back as events — that batch does its own final fetch.
    private func handleEvent(_ event: String) {
        guard !suppressEventRefetch else { return }
        switch event {
        case "exposure_changed", "routing_changed", "transport_changed":
            refreshStatus()
        case "shared_input_changed":
            // An app entered/left shared input mode: its backing changed, so the app list too.
            refreshStatus()
            if showPanel { refreshApps() }
        case "apps_changed":
            if showPanel { refreshApps() }
        case "jack_changed":
            refreshStatus()
            if showPanel { refreshApps() }
        case "licensing_changed":
            refreshLicense()   // trial/license state changed (expiry, activation, revocation, day tick)
        default:
            break   // "stopping" is handled at stream close
        }
    }

    /// The subscribe stream ended. `clean` (a `stopping` event) = graceful shutdown; a bare EOF
    /// = crash → relaunch via launchd, but only while JACK is up (else the daemon self-stops
    /// again — the KeepAlive=false lifecycle). The reconnect loop then resubscribes.
    private func handleStreamClosed(clean: Bool) {
        pollInFlight = false
        if !clean, jackManager?.isRunning == true, installed {
            activate()   // crash while JACK is up → bring the daemon back
        } else {
            state = installed ? .inactive : .unavailable
            boxStatus = [:]
            capacity = nil
            transportProblem = nil
            sharedInputBoxes = []
            sharedOutputApps = []
        }
    }

    // MARK: - Process helper

    private enum CLIResult { case success; case failure(String) }

    /// The JackMoebius LaunchAgent label (plist: `~/Library/LaunchAgents/<label>.plist`).
    /// `nonisolated` so `startViaLaunchd` (background) can read it.
    nonisolated private static let launchdLabel = "io.github.zinc75.jackmoebius"

    /// `launchctl kickstart -k` (re)starts the agent (idempotent — `-k` restarts a running
    /// one). If the agent isn't bootstrapped yet (fresh install without re-login), bootstrap
    /// it first, then retry. Runs off the main thread; returns the trimmed stderr on failure.
    nonisolated private static func startViaLaunchd() -> CLIResult {
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(launchdLabel)"
        var result = runLaunchctl(["kickstart", "-k", target])
        if case .failure(let msg) = result,
           msg.localizedCaseInsensitiveContains("could not find service") {
            let plist = ("~/Library/LaunchAgents/\(launchdLabel).plist" as NSString).expandingTildeInPath
            _ = runLaunchctl(["bootstrap", domain, plist])
            result = runLaunchctl(["kickstart", "-k", target])
        }
        return result
    }

    /// Runs `/bin/launchctl` with `args` and waits for it (a fast, ephemeral helper).
    nonisolated private static func runLaunchctl(_ args: [String]) -> CLIResult {
        let process = Process()
        process.executableURL  = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments      = args
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError  = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .success }
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg  = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(msg?.isEmpty == false ? msg! : "launchctl exit \(process.terminationStatus)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
