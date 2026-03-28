//
//  StudioManager.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Studio management: data model, JSON persistence, app detection,
//  capture (save) and load logic.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Data model

/// How a Jack client app can be relaunched when a studio is loaded.
enum ClientLaunchType: String, Codable {
    case bundle  // macOS .app bundle — relaunched via NSWorkspace
    case cli     // CLI binary or script — relaunched via Process
    case none    // No automatic relaunch (e.g. system clients, or user choice)
}

/// A Jack client entry stored inside a studio.
struct StudioClient: Identifiable, Codable {
    var id:            String = UUID().uuidString
    /// Exact Jack client name as it appears on the graph (e.g. `"Ardour6"`).
    var jackName:      String
    var launchType:    ClientLaunchType = .none
    /// `file:///Applications/Ardour6.app` when `launchType == .bundle`.
    var bundleURL:     String?
    /// Shell command when `launchType == .cli`.
    var launchCommand: String?
    /// Whether to relaunch this client automatically when the studio loads.
    var autoLaunch:    Bool    = false
    /// Optional display name; falls back to `jackName` if nil.
    var displayName:   String?

    /// Display-friendly name for this client entry.
    var label: String { displayName ?? jackName }
}

/// The saved position of a patchbay node in the canvas.
struct NodePosition: Codable {
    var id: String
    var x:  Double
    var y:  Double
}

/// A snapshot of the Jack server configuration at the time a studio was saved.
///
/// All fields except `command` use `decodeIfPresent` so that older JSON files
/// without newer fields continue to load successfully (backward compatible).
struct JackSnapshot: Codable {
    /// Full command string for display and diagnostic purposes.
    var command:          String
    /// Input device UID for device-match verification at load time.
    var inputDeviceUID:   String?
    var inputDeviceName:  String?
    var outputDeviceUID:  String?
    var outputDeviceName: String?
    var sampleRate:       Double
    var bufferSize:       Int
    var hogMode:              Bool  = false
    var clockDrift:           Bool  = false
    var midiEnabled:          Bool  = false
    var limitChannels:        Bool  = false
    var selectedInChannels:  [Int]  = []
    var selectedOutChannels: [Int]  = []

    /// Custom decoder — tolerant of JSON saved before any field was added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command          = try c.decode(String.self,  forKey: .command)
        inputDeviceUID   = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        inputDeviceName  = try c.decodeIfPresent(String.self, forKey: .inputDeviceName)
        outputDeviceUID  = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        outputDeviceName = try c.decodeIfPresent(String.self, forKey: .outputDeviceName)
        sampleRate       = try c.decode(Double.self, forKey: .sampleRate)
        bufferSize       = try c.decode(Int.self,    forKey: .bufferSize)
        hogMode               = try c.decodeIfPresent(Bool.self,  forKey: .hogMode)              ?? false
        clockDrift            = try c.decodeIfPresent(Bool.self,  forKey: .clockDrift)           ?? false
        midiEnabled           = try c.decodeIfPresent(Bool.self,  forKey: .midiEnabled)          ?? false
        limitChannels         = try c.decodeIfPresent(Bool.self,  forKey: .limitChannels)        ?? false
        selectedInChannels    = try c.decodeIfPresent([Int].self,  forKey: .selectedInChannels)  ?? []
        selectedOutChannels   = try c.decodeIfPresent([Int].self,  forKey: .selectedOutChannels) ?? []
    }

    /// Memberwise init for programmatic construction.
    init(command: String, inputDeviceUID: String?, inputDeviceName: String?,
         outputDeviceUID: String?, outputDeviceName: String?,
         sampleRate: Double, bufferSize: Int,
         hogMode: Bool = false, clockDrift: Bool = false, midiEnabled: Bool = false,
         limitChannels: Bool = false, selectedInChannels: [Int] = [], selectedOutChannels: [Int] = []) {
        self.command = command
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceName = inputDeviceName
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
        self.hogMode = hogMode
        self.clockDrift = clockDrift
        self.midiEnabled = midiEnabled
        self.limitChannels = limitChannels
        self.selectedInChannels = selectedInChannels
        self.selectedOutChannels = selectedOutChannels
    }

    /// Reconstruct the Jack launch command tokens from snapshot values.
    func buildCommand(executablePath: String) -> [String] {
        var args: [String] = [executablePath]
        if midiEnabled { args += ["-X", "coremidi"] }
        args += ["-d", "coreaudio"]
        args += ["-r", String(Int(sampleRate))]
        args += ["-p", String(bufferSize)]
        if hogMode    { args.append("-H") }
        if clockDrift { args.append("-s") }

        if limitChannels {
            let inList  = selectedInChannels.sorted()
            let outList = selectedOutChannels.sorted()
            // Empty list means all channels — don't pass the option
            if !inList.isEmpty  { args += ["--input-list",  inList.map(String.init).joined(separator: " ")] }
            if !outList.isEmpty { args += ["--output-list", outList.map(String.init).joined(separator: " ")] }
        }

        let inUID  = inputDeviceUID  ?? ""
        let outUID = outputDeviceUID ?? ""
        if !inUID.isEmpty && !outUID.isEmpty && inUID == outUID {
            args += ["-d", "\"\(inUID)\""]
        } else {
            if !inUID.isEmpty  { args += ["-C", "\"\(inUID)\""]  }
            if !outUID.isEmpty { args += ["-P", "\"\(outUID)\""] }
        }
        return args
    }
}

/// A saved Jack port connection between two ports.
struct StudioConnection: Identifiable, Codable {
    var id:   String = UUID().uuidString
    var from: String   // e.g. "system:capture_1"
    var to:   String   // e.g. "Ardour6:audio/in 1"
}

/// A complete saved studio: Jack configuration, client list, connections, and node positions.
struct Studio: Identifiable, Codable {
    var id:            String             = UUID().uuidString
    var name:          String
    var createdAt:     Date               = Date()
    var updatedAt:     Date               = Date()
    var lastLoadedAt:  Date?              = nil
    var jackSnapshot:  JackSnapshot?      = nil
    var nodePositions: [NodePosition]     = []
    var clients:       [StudioClient]     = []
    var connections:   [StudioConnection] = []

    /// Short human-readable summary shown in the studio list.
    var summary: String {
        "\(clients.filter { $0.jackName != "system" }.count) clients · \(connections.count) connexions"
    }
}

// Tolerant decoder: JSON files saved before nodePositions/jackSnapshot were added remain valid
extension Studio {
    init(from decoder: Decoder) throws {
        let c          = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decodeIfPresent(String.self,             forKey: .id)           ?? UUID().uuidString
        name           = try c.decode(String.self,                      forKey: .name)
        createdAt      = try c.decode(Date.self,                        forKey: .createdAt)
        updatedAt      = try c.decode(Date.self,                        forKey: .updatedAt)
        lastLoadedAt   = try c.decodeIfPresent(Date.self,               forKey: .lastLoadedAt)
        jackSnapshot   = try c.decodeIfPresent(JackSnapshot.self,       forKey: .jackSnapshot)
        nodePositions  = try c.decodeIfPresent([NodePosition].self,     forKey: .nodePositions) ?? []
        clients        = try c.decodeIfPresent([StudioClient].self,     forKey: .clients)       ?? []
        connections    = try c.decodeIfPresent([StudioConnection].self, forKey: .connections)   ?? []
    }
}

// MARK: - StudioManager

@MainActor
final class StudioManager: ObservableObject {

    @Published var studios:      [Studio]  = []
    @Published var activeStudio: String?  = nil   // ID of the studio currently being loaded
    @Published var loadedStudio: Studio?  = nil   // studio that is currently active

    /// CLI processes launched by the current studio (jack_metro, etc.)
    private var cliProcesses: [Process] = []

    /// Inhibits observeJackState cleanup when loadStudio handles it internally.
    private var suppressJackStopCleanup = false

    /// Combine subscription for Jack state observation
    private var jackStateCancellable: AnyCancellable?

    // Infra-client suggestions: jackName → last known launch command.
    // Stored in UserDefaults as a suggestion cache only.
    private let suggestionsKey = "JackMate.infraClientSuggestions"

    // JSON storage directory inside ~/Library/Application Support/JackMate/Studios/
    private var studioDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("JackMate/Studios")
        try? FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true)
        return dir
    }

    init() {
        loadAll()
    }

    /// Start observing Jack state to clean up clients when Jack stops.
    /// Call once after all managers are initialized.
    /// Acts as a safety net for crash/external shutdown — suppressed during loadStudio
    /// and stopJackGracefully which handle cleanup themselves.
    func observeJackState(jackManager: JackManager, patchbayManager: PatchbayManager) {
        // Wire up graceful stop on JackManager so any button (menubar, etc.) can use it
        jackManager.gracefulStop = { [weak self, weak jackManager, weak patchbayManager] in
            guard let self, let jackManager, let patchbayManager else { return }
            self.stopJackGracefully(jackManager: jackManager, patchbayManager: patchbayManager)
        }

        jackStateCancellable = jackManager.$isRunning
            .removeDuplicates()
            .dropFirst()   // skip initial value
            .filter { !$0 } // only react to Jack stopping
            .sink { [weak self, weak patchbayManager] _ in
                guard let self, let patchbayManager else { return }
                // Skip if loadStudio or stopJackGracefully already handled cleanup
                guard !self.suppressJackStopCleanup else {

                    return
                }
                let bridge = patchbayManager.jackBridge

                self.terminateCLIProcesses()
                let targeted = self.terminateAllJackClients(bridge: bridge)
                if !targeted.isEmpty {
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        for item in targeted {
                            if kill(item.pid, 0) == 0 {
                                ProcessHelper.forceKill(pid: item.pid)
                            }
                        }
                    }
                }
                self.loadedStudio = nil
            }
    }

    /// Gracefully stop Jack: close all clients first, then stop Jack server.
    /// Used by the "Stop Jack" button for a clean shutdown order.
    func stopJackGracefully(jackManager: JackManager, patchbayManager: PatchbayManager) {
        let bridge = patchbayManager.jackBridge
        suppressJackStopCleanup = true

        Task {
            // 1. SIGTERM all Jack clients
            let targeted = terminateAllJackClients(bridge: bridge)

            // 2. Wait for graceful exit
            if !targeted.isEmpty {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // Force-kill stubborn processes
                for item in targeted {
                    if kill(item.pid, 0) == 0 {
                        ProcessHelper.forceKill(pid: item.pid)
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            // 3. Now stop Jack
            jackManager.stopJack()
            loadedStudio = nil

            // Re-enable the safety net after a short delay
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            suppressJackStopCleanup = false
        }
    }

    // MARK: - Persistence

    /// Loads all studios from disk into `studios`, sorted by `updatedAt` descending.
    func loadAll() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: studioDirectory, includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles)
            studios = files
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> Studio? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(Studio.self, from: data)
                }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            studios = []
        }
    }

    /// Saves a studio to disk as pretty-printed JSON and updates the in-memory list.
    /// - Throws: A file-system or encoding error if the write fails.
    func save(_ studio: Studio) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var s = studio
        s.updatedAt = Date()
        let data = try encoder.encode(s)
        let newURL = studioDirectory.appendingPathComponent(filename(for: s))
        // Remove any existing file for this ID (handles renames)
        removeFiles(withID: s.id, except: newURL)
        try data.write(to: newURL, options: .atomic)
        // Update the in-memory list
        if let idx = studios.firstIndex(where: { $0.id == s.id }) {
            studios[idx] = s
        } else {
            studios.insert(s, at: 0)
        }
        // Cache CLI commands as suggestions for future use
        for client in s.clients where client.launchType == .cli {
            if let cmd = client.launchCommand {
                saveSuggestion(jackName: client.jackName, command: cmd)
            }
        }
    }

    /// Deletes a studio from disk and removes it from the in-memory list.
    func delete(_ studio: Studio) throws {
        removeFiles(withID: studio.id, except: nil)
        studios.removeAll { $0.id == studio.id }
        if activeStudio == studio.id { activeStudio = nil }
        if loadedStudio?.id == studio.id { loadedStudio = nil }
    }

    /// Renames a studio and saves the change to disk.
    func rename(_ studio: Studio, to name: String) throws {
        var s = studio; s.name = name
        try save(s)
    }

    // MARK: - File naming

    /// Returns the JSON filename for a studio: `readable_name_UUID.json`.
    private func filename(for studio: Studio) -> String {
        "\(sanitizeName(studio.name))_\(studio.id).json"
    }

    /// Removes all JSON files for the given studio ID, except `keepURL` if provided.
    /// Handles migration from the legacy format (`UUID.json`) and renames.
    private func removeFiles(withID id: String, except keepURL: URL?) {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: studioDirectory, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles)) ?? []
        for url in all where url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            guard name == id || name.hasSuffix("_\(id)") else { continue }
            guard url != keepURL else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Strips diacritics and replaces spaces with underscores for safe filename use.
    /// Example: `"Batterie électro"` → `"Batterie_electro"`
    private func sanitizeName(_ name: String) -> String {
        let folded = name.folding(options: .diacriticInsensitive, locale: .current)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        let filtered = String(folded.unicodeScalars.filter { allowed.contains($0) }.map { Character($0) })
        let parts = filtered.components(separatedBy: " ").filter { !$0.isEmpty }
        let result = parts.joined(separator: "_")
        return result.isEmpty ? "studio" : result
    }

    // MARK: - Infra-client suggestions

    /// Returns the last known CLI launch command for the given Jack client name, if any.
    func suggestion(for jackName: String) -> String? {
        let dict = UserDefaults.standard.dictionary(forKey: suggestionsKey)
            as? [String: String] ?? [:]
        return dict[jackName]
    }

    private func saveSuggestion(jackName: String, command: String) {
        var dict = UserDefaults.standard.dictionary(forKey: suggestionsKey)
            as? [String: String] ?? [:]
        dict[jackName] = command
        UserDefaults.standard.set(dict, forKey: suggestionsKey)
    }

    // MARK: - Automatic app detection

    /// Attempts to find the macOS app corresponding to a Jack client name.
    /// Searches running applications first, then `/Applications` and `~/Applications`.
    func detectClient(for jackName: String) -> StudioClient {
        var client = StudioClient(jackName: jackName)

        // 1. Search among currently running applications
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: { matches(app: $0, jackName: jackName) }) {
            client.launchType  = .bundle
            // Resolve the canonical URL to avoid Gatekeeper AppTranslocation paths
            client.bundleURL   = canonicalAppURL(for: app)?.absoluteString
            client.displayName = app.localizedName
            client.autoLaunch  = true
            return client
        }

        // 2. Search in /Applications (installed but not currently running)
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
        ]
        for dir in appDirs {
            if let found = findApp(named: jackName, in: dir) {
                client.launchType  = .bundle
                client.bundleURL   = found.absoluteString
                client.displayName = found.deletingPathExtension().lastPathComponent
                client.autoLaunch  = true
                return client
            }
        }

        // 3. Detect CLI process via process table scan (jack_metro → "metro", etc.)
        if let pid = ProcessHelper.findPID(forJackClient: jackName),
           let args = ProcessHelper.commandLine(for: pid), !args.isEmpty {
            // Replace argv[0] with absolute path for reliable relaunch
            var fullArgs = args
            if let absPath = ProcessHelper.executablePath(for: pid) {
                fullArgs[0] = absPath
            }
            let command = fullArgs.joined(separator: " ")
            client.launchType    = .cli
            client.launchCommand = command
            client.autoLaunch    = true
            // Cache the command as suggestion for future use
            saveSuggestion(jackName: jackName, command: command)

            return client
        }

        // 4. Fall back to cached suggestion from UserDefaults
        if let suggestion = suggestion(for: jackName) {
            client.launchType    = .cli
            client.launchCommand = suggestion
            // autoLaunch stays false — user must confirm before launch
        }

        return client
    }

    /// Returns the canonical bundle URL for a running app, bypassing Gatekeeper
    /// AppTranslocation paths.
    /// Priority: Launch Services (bundle ID) → search in /Applications → raw bundleURL.
    private func canonicalAppURL(for app: NSRunningApplication) -> URL? {
        // 1. Launch Services knows the real path via the bundle ID
        if let bundleID = app.bundleIdentifier,
           let canonical = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return canonical
        }
        // 2. Fallback: search by name in the Applications folders
        if let bundleURL = app.bundleURL {
            let appName = bundleURL.deletingPathExtension().lastPathComponent
            let searchDirs = [
                URL(fileURLWithPath: "/Applications"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications")
            ]
            for dir in searchDirs {
                if let found = findApp(named: appName, in: dir) { return found }
            }
        }
        // 3. Last resort: raw URL (may be an AppTranslocation path)
        return app.bundleURL
    }

    /// Returns `true` if `app` is a plausible match for the given Jack client name.
    func matches(app: NSRunningApplication, jackName: String) -> Bool {
        let name = jackName.lowercased()
        if let appName = app.localizedName?.lowercased() {
            if appName == name || appName.hasPrefix(name) || name.hasPrefix(appName) {
                return true
            }
        }
        if let bundle = app.bundleIdentifier?.lowercased() {
            if bundle.contains(name) { return true }
        }
        return false
    }

    /// A Jack client to be closed — either a GUI app or a CLI process.
    struct ClientToQuit: Identifiable {
        let id: pid_t               // PID, unique identifier
        let jackName: String        // Jack client name
        let displayName: String     // Human-readable name
        let isInStudio: Bool        // Part of the loaded studio?
        let app: NSRunningApplication?  // Non-nil for GUI apps
        let isCLI: Bool             // true for CLI processes
    }

    /// Returns all Jack clients to close (GUI + CLI), using both NSWorkspace and PID scan.
    func allClientsToQuit(studio: Studio, bridge: JackBridgeWrapper) -> [ClientToQuit] {
        let studioNames = Set(studio.clients.map { $0.jackName }.filter { $0 != "system" })
        let myPID = ProcessInfo.processInfo.processIdentifier
        var seen = Set<pid_t>()
        var result: [ClientToQuit] = []

        // Collect all Jack client names from ports
        let ports = bridge.getPorts()
        var clientNames = Set<String>()
        for port in ports where port.clientName != "system" {
            clientNames.insert(port.clientName)
        }
        if let bridgeName = bridge.clientName { clientNames.remove(bridgeName) }

        for jackName in clientNames {
            // Try GUI match first
            if let app = NSWorkspace.shared.runningApplications.first(where: { matches(app: $0, jackName: jackName) }) {
                guard !seen.contains(app.processIdentifier) else { continue }
                seen.insert(app.processIdentifier)
                result.append(ClientToQuit(
                    id: app.processIdentifier,
                    jackName: jackName,
                    displayName: app.localizedName ?? jackName,
                    isInStudio: studioNames.contains(jackName),
                    app: app,
                    isCLI: false
                ))
                continue
            }

            // Fallback: CLI process via PID scan
            let pid = bridge.getClientPID(name: jackName)
                      ?? ProcessHelper.findPID(forJackClient: jackName)
            guard let pid, pid != myPID, !seen.contains(pid) else { continue }
            seen.insert(pid)
            let path = ProcessHelper.executablePath(for: pid)
            let baseName = path.map { (($0 as NSString).lastPathComponent) } ?? jackName
            result.append(ClientToQuit(
                id: pid,
                jackName: jackName,
                displayName: baseName,
                isInStudio: studioNames.contains(jackName),
                app: nil,
                isCLI: true
            ))
        }

        return result
    }

    /// Returns running apps to quit for this studio.
    /// Includes both studio clients and any extra clients connected during the session.
    /// Apps already quit by the user are naturally absent from the result.
    func appsToQuit(studio: Studio, currentNodeIds: [String]) -> [(jackName: String, app: NSRunningApplication)] {
        let studioNames = Set(studio.clients.map { $0.jackName }.filter { $0 != "system" })
        let extraNames  = Set(currentNodeIds
            .map { $0
                .replacingOccurrences(of: " (capture)", with: "")
                .replacingOccurrences(of: " (playback)", with: "")
            }
            .filter { $0 != "system" }
        )
        let allNames = studioNames.union(extraNames)

        var seen   = Set<pid_t>()
        var result = [(jackName: String, app: NSRunningApplication)]()
        for jackName in allNames {
            for app in NSWorkspace.shared.runningApplications {
                guard matches(app: app, jackName: jackName) else { continue }
                guard !seen.contains(app.processIdentifier) else { continue }
                seen.insert(app.processIdentifier)
                result.append((jackName: jackName, app: app))
            }
        }
        return result
    }

    private func findApp(named jackName: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        let name = jackName.lowercased()
        return contents.first { url in
            let appName = url.deletingPathExtension().lastPathComponent.lowercased()
            return url.pathExtension == "app" &&
                (appName == name || appName.hasPrefix(name) || name.hasPrefix(appName))
        }
    }

    // MARK: - Building a studio from current Jack state

    /// Builds a `Studio` from the current nodes and connections in `PatchbayManager`.
    /// Clients whose detection is ambiguous are returned separately so the UI
    /// can ask the user for confirmation before saving.
    func buildStudio(
        name: String,
        nodes: [PatchbayNode],
        connections: [JackConnection],
        jackManager: JackManager
    ) -> (studio: Studio, needsInput: [StudioClient]) {

        var clients:    [StudioClient]      = []
        var needsInput: [StudioClient]      = []
        let studioConns: [StudioConnection] = connections.map {
            StudioConnection(from: $0.from, to: $0.to)
        }

        for node in nodes {
            let jackName = node.id
                .replacingOccurrences(of: " (capture)", with: "")
                .replacingOccurrences(of: " (playback)", with: "")

            if clients.contains(where: { $0.jackName == jackName }) { continue }

            if jackName == "system" {
                clients.append(StudioClient(jackName: jackName, launchType: .none, autoLaunch: false))
                continue
            }

            let detected = detectClient(for: jackName)
            if detected.launchType == .bundle || (detected.launchType == .cli && detected.autoLaunch) {
                clients.append(detected)
            } else {
                needsInput.append(detected)
            }
        }

        // Capture current Jack configuration into a snapshot
        let inputUID  = jackManager.prefs.inputDeviceUID.isEmpty  ? nil : jackManager.prefs.inputDeviceUID
        let outputUID = jackManager.prefs.outputDeviceUID.isEmpty ? nil : jackManager.prefs.outputDeviceUID
        let cmdArgs   = jackManager.prefs.buildCommand(
            executablePath: jackManager.jackExecutableURL?.path ?? "jackdmp",
            inputUID:  inputUID,
            outputUID: outputUID)
        let snapshot = JackSnapshot(
            command:          cmdArgs.joined(separator: " "),
            inputDeviceUID:   inputUID,
            inputDeviceName:  jackManager.savedInputDeviceName.isEmpty  ? nil : jackManager.savedInputDeviceName,
            outputDeviceUID:  outputUID,
            outputDeviceName: jackManager.savedOutputDeviceName.isEmpty ? nil : jackManager.savedOutputDeviceName,
            sampleRate:       jackManager.prefs.sampleRate,
            bufferSize:       jackManager.prefs.bufferSize,
            hogMode:              jackManager.prefs.hogMode,
            clockDrift:           jackManager.prefs.clockDrift,
            midiEnabled:          jackManager.prefs.midiEnabled,
            limitChannels:        jackManager.prefs.limitChannels,
            selectedInChannels:   jackManager.prefs.selectedInChannels,
            selectedOutChannels:  jackManager.prefs.selectedOutChannels)

        // Capture current patchbay node positions
        let positions = nodes.map { NodePosition(id: $0.id, x: $0.position.x, y: $0.position.y) }

        var studio = Studio(name: name, clients: clients, connections: studioConns)
        studio.jackSnapshot  = snapshot
        studio.nodePositions = positions

        return (studio, needsInput)
    }

    // MARK: - Loading a studio

    struct LoadResult {
        var connected:    [StudioConnection] = []
        var failed:       [StudioConnection] = []   // port not found after timeout
        var notLaunched:  [StudioClient]     = []   // app failed to launch
    }

    /// Launches autoLaunch apps, waits for their ports to appear, then restores connections.
    /// - Parameters:
    ///   - studio:          The studio to load.
    ///   - bridge:          `JackBridgeWrapper` used to connect ports.
    ///   - jackManager:     Used to start/stop Jack if the configuration differs.
    ///   - patchbayManager: Used to close existing clients before reloading.
    ///   - onProgress:      Called at each step with a human-readable status string.
    ///   - onComplete:      Called on completion with the `LoadResult`.
    func loadStudio(
        _ studio: Studio,
        bridge: JackBridgeWrapper,
        jackManager: JackManager,
        patchbayManager: PatchbayManager,
        onProgress: @escaping (String) -> Void,
        onComplete: @escaping (LoadResult) -> Void
    ) {
        activeStudio = studio.id

        Task {
            var result = LoadResult()

            // 0a. Close ALL existing Jack clients (GUI + CLI, including external ones)
            let hasClients = patchbayManager.nodes.contains { $0.id != "system" }
            if hasClients {
                onProgress("Fermeture des clients Jack…")
                // Disconnect all non-system cables first
                for node in patchbayManager.nodes {
                    patchbayManager.disconnectAll(of: node.id)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                // SIGTERM all Jack clients via PID (covers CLI + GUI)
                let targeted = terminateAllJackClients(bridge: bridge)
                // Give processes time to exit gracefully
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // Force-kill any remaining stubborn processes
                for item in targeted {
                    if kill(item.pid, 0) == 0 {
                        ProcessHelper.forceKill(pid: item.pid)
                    }
                }
                if !targeted.isEmpty {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            // 0b. Determine if Jack needs a restart (full command comparison)
            if let snapshot = studio.jackSnapshot {
                let execPath = jackManager.jackExecutableURL?.path ?? "jackdmp"
                let studioArgs = snapshot.buildCommand(executablePath: execPath)

                let needsRestart: Bool
                if jackManager.isRunning {
                    if let currentCmd = jackManager.runningCommand {
                        // Compare full commands (order-independent)
                        needsRestart = !commandsAreEquivalent(currentCmd, studioArgs)
                    } else {
                        // Jack launched externally — restart to guarantee config
                        needsRestart = true
                    }
                } else {
                    needsRestart = false // Jack not running, will start below
                }

                if needsRestart {
                    suppressJackStopCleanup = true
                    onProgress("Arrêt de Jack pour changement de configuration…")
                    jackManager.stopJack()
                    let stopDeadline = Date().addingTimeInterval(10)
                    while Date() < stopDeadline && jackManager.checkJackRunning() {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                    // Let Jack fully release its resources (sockets, shared memory,
                    // semaphores) before starting a new instance.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    jackManager.isRunning = false
                }

                // Start Jack if not running (either was stopped above, or wasn't running)
                if !jackManager.checkJackRunning() {
                    onProgress("Application des réglages Jack…")
                    jackManager.prefs.sampleRate          = snapshot.sampleRate
                    jackManager.prefs.bufferSize          = snapshot.bufferSize
                    jackManager.prefs.hogMode             = snapshot.hogMode
                    jackManager.prefs.clockDrift          = snapshot.clockDrift
                    jackManager.prefs.midiEnabled         = snapshot.midiEnabled
                    jackManager.prefs.limitChannels       = snapshot.limitChannels
                    jackManager.prefs.selectedInChannels  = snapshot.selectedInChannels
                    jackManager.prefs.selectedOutChannels = snapshot.selectedOutChannels
                    if let uid = snapshot.inputDeviceUID, !uid.isEmpty {
                        jackManager.prefs.inputDeviceUID = uid
                    }
                    if let name = snapshot.inputDeviceName, !name.isEmpty {
                        jackManager.savedInputDeviceName = name
                    }
                    if let uid = snapshot.outputDeviceUID, !uid.isEmpty {
                        jackManager.prefs.outputDeviceUID = uid
                    }
                    if let name = snapshot.outputDeviceName, !name.isEmpty {
                        jackManager.savedOutputDeviceName = name
                    }
                    jackManager.savePreferences()

                    onProgress("Démarrage de Jack…")
                    // Ensure isRunning is false right before startJack() — the monitoring
                    // loop (cooperative Task) may have re-set it to true between our
                    // stopJack() and now if it ran during an await suspension point.
                    jackManager.isRunning = false
                    jackManager.startJack()
                    let startDeadline = Date().addingTimeInterval(15)
                    while Date() < startDeadline && !jackManager.checkJackRunning() {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if !jackManager.checkJackRunning() {
                        onComplete(LoadResult(
                            failed: studio.connections,
                            notLaunched: studio.clients.filter { $0.autoLaunch }
                        ))
                        activeStudio = nil
                        return
                    }
                    // Force isRunning update to trigger bridge connection in PatchbayManager
                    if !jackManager.isRunning { jackManager.isRunning = true }
                    // Wait for bridge connection (max 12s)
                    onProgress("Connexion au bridge Jack…")
                    let bridgeDeadline = Date().addingTimeInterval(12)
                    while Date() < bridgeDeadline && !bridge.isConnected {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                    guard bridge.isConnected else {
                        onComplete(LoadResult(
                            failed: studio.connections,
                            notLaunched: studio.clients.filter { $0.autoLaunch }
                        ))
                        activeStudio = nil
                        return
                    }
                }
            } else if !jackManager.isRunning {
                // No snapshot and Jack stopped → cannot continue
                onComplete(LoadResult(
                    failed: studio.connections,
                    notLaunched: studio.clients.filter { $0.autoLaunch }
                ))
                activeStudio = nil
                return
            }

            // 1. Launch autoLaunch apps
            for client in studio.clients where client.autoLaunch {
                switch client.launchType {
                case .bundle:
                    if let urlStr = client.bundleURL,
                       let url = resolveAppURL(urlStr) {
                        onProgress("Lancement de \(client.label)…")
                        do {
                            try await NSWorkspace.shared.openApplication(
                                at: url,
                                configuration: NSWorkspace.OpenConfiguration())
                        } catch {
                            result.notLaunched.append(client)
                        }
                    } else {
                        result.notLaunched.append(client)
                    }
                case .cli:
                    if let cmd = client.launchCommand {
                        onProgress("Lancement de \(client.label)…")
                        launchCLI(cmd)
                    } else {
                        result.notLaunched.append(client)
                    }
                case .none:
                    break
                }
            }

            // 2. Wait for all required ports to appear (max 30 s)
            onProgress("En attente des ports Jack…")
            let neededClients = Set(studio.connections.flatMap {
                [$0.from.split(separator: ":").first.map(String.init) ?? "",
                 $0.to.split(separator: ":").first.map(String.init) ?? ""]
            })
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let ports = bridge.getPorts()
                let presentClients = Set(ports.map {
                    String($0.id.split(separator: ":").first ?? "")
                })
                if neededClients.isSubset(of: presentClients) { break }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }

            // 3. Disconnect auto-connections made by apps at startup
            // (Faust and other Jack apps connect themselves automatically when launched)
            let studioClientNames = Set(studio.clients.map { $0.jackName })
            for conn in bridge.getConnections() {
                let fromClient = String(conn.from.split(separator: ":").first ?? "")
                let toClient   = String(conn.to.split(separator: ":").first ?? "")
                if studioClientNames.contains(fromClient) || studioClientNames.contains(toClient) {
                    try? bridge.disconnect(from: conn.from, to: conn.to)
                }
            }

            // 4. Reconnect according to the saved state
            onProgress("Restauration des connexions…")
            let ports = bridge.getPorts()
            for conn in studio.connections {
                let fromExists = ports.contains { $0.id == conn.from }
                let toExists   = ports.contains { $0.id == conn.to }
                if fromExists && toExists {
                    let from = ports.first { $0.id == conn.from }!
                    let to   = ports.first { $0.id == conn.to }!
                    do {
                        try bridge.connect(from: from.id, to: to.id,
                                           fromType: from.type, toType: to.type)
                        result.connected.append(conn)
                    } catch {
                        result.failed.append(conn)
                    }
                } else {
                    result.failed.append(conn)
                }
            }

            // Update lastLoadedAt and mark this studio as the active one
            if var updated = studios.first(where: { $0.id == studio.id }) {
                updated.lastLoadedAt = Date()
                try? save(updated)
                loadedStudio = updated
            } else {
                loadedStudio = studio
            }

            onComplete(result)
            activeStudio = nil
            suppressJackStopCleanup = false
        }
    }

    // MARK: - App URL resolution

    /// Resolves a bundle URL string, bypassing Gatekeeper AppTranslocation paths.
    /// If the URL contains "AppTranslocation", searches for the `.app` by name in
    /// `/Applications` and `~/Applications`. For normal URLs, verifies the file exists.
    private func resolveAppURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        if urlString.contains("AppTranslocation") {
            let appName = url.deletingPathExtension().lastPathComponent
            let searchDirs = [
                URL(fileURLWithPath: "/Applications"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications")
            ]
            for dir in searchDirs {
                if let found = findApp(named: appName, in: dir) { return found }
            }
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func launchCLI(_ command: String) {
        let parts = command.components(separatedBy: " ")
        guard !parts.isEmpty else { return }
        let process = Process()
        let executable = parts[0]
        // If not an absolute path, resolve via /usr/bin/env
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(parts.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = parts
        }

        do {
            try process.run()
            cliProcesses.append(process)
        } catch {

        }
    }

    /// Terminate all CLI processes launched by the current studio.
    func terminateCLIProcesses() {
        for process in cliProcesses where process.isRunning {
            process.terminate()
        }
        cliProcesses.removeAll()
    }

    /// Terminate all non-system Jack clients using jack_get_client_pid.
    /// Kills both GUI apps and CLI processes invisible to NSWorkspace.
    /// Skips "system" and JackMate's own bridge client.
    /// Returns the list of (name, pid) targeted for termination.
    @discardableResult
    func terminateAllJackClients(bridge: JackBridgeWrapper) -> [(name: String, pid: pid_t)] {
        let ports = bridge.getPorts()
        let myPID = ProcessInfo.processInfo.processIdentifier

        // Unique client names, excluding "system"
        var clientNames = Set<String>()
        for port in ports {
            if port.clientName != "system" {
                clientNames.insert(port.clientName)
            }
        }

        // Also skip JackMate's own bridge client name
        if let bridgeName = bridge.clientName {
            clientNames.remove(bridgeName)
        }


        var targeted: [(name: String, pid: pid_t)] = []
        for name in clientNames {
            // Try jack_get_client_pid first, fallback to process table scan
            var pid = bridge.getClientPID(name: name)
            if pid == nil {
                pid = ProcessHelper.findPID(forJackClient: name)
            }

            guard let pid, pid != myPID else { continue }
            ProcessHelper.terminate(pid: pid)
            targeted.append((name: name, pid: pid))
        }

        // Also clean up internally tracked CLI processes
        terminateCLIProcesses()
        return targeted
    }
}
