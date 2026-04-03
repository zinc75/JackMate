//
//  JackManager.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Manages the Jack server process lifecycle: start, stop, monitoring,
//  log capture, version detection, and user preferences persistence.
//
//  v2 — xrun optimisations:
//  - Log throttling (100 ms batch instead of one-at-a-time)
//  - recomputeHasWarning() called only when necessary
//  - Automatic animations removed from LogPanel
//

import Foundation
import Combine
import SwiftUI
import Darwin

// MARK: - JackLogLine

/// A single line captured from Jack's stdout / stderr output.
///
/// Uses an integer index as the `Identifiable` key instead of a UUID
/// to save 16 bytes per line (important when hundreds of lines are captured).
struct JackLogLine: Identifiable {
    /// Sequential index used as the list identifier (no UUID allocation).
    let id:    Int
    let text:  String
    let level: JackLogLevel

    /// Severity level inferred by keyword matching on the log text.
    enum JackLogLevel: UInt8 {  // UInt8: 1 byte instead of 8
        case info, success, warning, error, muted

        static func detect(in text: String) -> JackLogLevel {
            let t = text.lowercased()
            if t.contains("error") || t.contains("err:") || t.contains("failed") || t.contains("cannot") {
                return .error
            }
            if t.contains("clock drift") {
                if t.contains("activated") { return .success }
                if t.contains("would be needed") { return .warning }
                return .info
            }
            if t.contains("warning") || t.contains("xrun") {
                return .warning
            }
            if t.contains("running") || t.contains("started") || t.contains("driver is running") {
                return .success
            }
            if t.contains("copyright") || t.contains("comes with") || t.contains("free software")
                || t.contains("under certain") || t.contains("jackdmp ") {
                return .muted
            }
            return .info
        }
    }
}

// MARK: - JackState

/// Represents the lifecycle state of the Jack server.
///
/// Used instead of emoji-pattern matching on the localised `statusMessage` string.
enum JackState: Equatable {
    case ready, starting, running, external, startFailed,
         stopping, stopped, stoppedExternal, alreadyRunning, executableNotFound

    fileprivate var localizationKey: String.LocalizationValue {
        switch self {
        case .ready:              return "jack.status.ready"
        case .starting:           return "jack.status.starting"
        case .running:            return "jack.status.running"
        case .external:           return "jack.status.external"
        case .startFailed:        return "jack.status.start_failed"
        case .stopping:           return "jack.status.stopping"
        case .stopped:            return "jack.status.stopped"
        case .stoppedExternal:    return "jack.status.stopped_external"
        case .alreadyRunning:     return "jack.status.already_running"
        case .executableNotFound: return "jack.status.executable_not_found"
        }
    }
}

// MARK: - JackPreferences

/// Persisted user preferences for the Jack server command line.
///
/// `buildCommand` assembles the actual `jackdmp` / `jackd` argument array
/// from these values. `commandPreview` returns a space-joined string for
/// display in the Configuration panel.
struct JackPreferences {
    var inputDeviceUID:  String = ""
    var outputDeviceUID: String = ""
    var sampleRate:      Double = 48000
    var bufferSize:      Int    = 256
    var hogMode:         Bool   = false
    var clockDrift:      Bool   = false
    var midiEnabled:     Bool   = false
    var limitChannels:        Bool  = false
    var selectedInChannels:  [Int] = []   // empty = all channels
    var selectedOutChannels: [Int] = []   // empty = all channels

    var theoreticalLatency: Double {
        guard sampleRate > 0 else { return 0 }
        return 1000.0 / sampleRate * Double(bufferSize)
    }

    func buildCommand(executablePath: String,
                      inputUID: String?,
                      outputUID: String?,
                      maxInChannels: Int = 0,
                      maxOutChannels: Int = 0) -> [String] {
        // NOTE: No -R (realtime) flag on macOS — CoreAudio manages real-time priority.
        // -R would activate SCHED_FIFO which is unsupported on macOS.
        var args: [String] = [executablePath]
        if midiEnabled { args += ["-X", "coremidi"] }
        args += ["-d", "coreaudio"]
        args += ["-r", String(Int(sampleRate))]
        args += ["-p", String(bufferSize)]
        if hogMode    { args.append("-H") }
        if clockDrift { args.append("-s") }

        // Channel selection — only pass if enabled AND selection is a strict subset of all channels
        if limitChannels {
            let allIn  = maxInChannels  > 0 ? Array(0..<maxInChannels)  : []
            let allOut = maxOutChannels > 0 ? Array(0..<maxOutChannels) : []
            let inList  = selectedInChannels.sorted()
            let outList = selectedOutChannels.sorted()
            if !inList.isEmpty  && inList  != allIn  { args += ["--input-list",  inList.map(String.init).joined(separator: " ")] }
            if !outList.isEmpty && outList != allOut { args += ["--output-list", outList.map(String.init).joined(separator: " ")] }
        }


        if let inUID = inputUID, !inUID.isEmpty,
           let outUID = outputUID, !outUID.isEmpty,
           inUID == outUID {
            args += ["-d", "\"\(inUID)\""]
        } else {
            if let inUID = inputUID, !inUID.isEmpty {
                args += ["-C", "\"\(inUID)\""]
            }
            if let outUID = outputUID, !outUID.isEmpty {
                args += ["-P", "\"\(outUID)\""]
            }
        }
        return args
    }

    /// Command string for display in the Configuration panel.
    func commandPreview(executableName: String = "jackdmp",
                        maxInChannels: Int = 0,
                        maxOutChannels: Int = 0) -> String {
        buildCommand(
            executablePath: executableName,
            inputUID:  inputDeviceUID.isEmpty  ? nil : inputDeviceUID,
            outputUID: outputDeviceUID.isEmpty ? nil : outputDeviceUID,
            maxInChannels:  maxInChannels,
            maxOutChannels: maxOutChannels
        ).joined(separator: " ")
    }
}

// MARK: - Command comparison

/// Compare two Jack command token arrays independently of parameter order.
/// The executable name is compared by basename only (path-insensitive).
func commandsAreEquivalent(_ a: [String], _ b: [String]) -> Bool {
    guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return false }
    let nameA = URL(fileURLWithPath: a[0]).lastPathComponent
    let nameB = URL(fileURLWithPath: b[0]).lastPathComponent
    guard nameA == nameB else { return false }
    return a.dropFirst().sorted() == b.dropFirst().sorted()
}

// MARK: - JackInstallMethod

/// The installation method the user has selected for installing Jack.
///
/// Only relevant in the GitHub (non-App Store) build where the user can
/// choose between Homebrew and the official `.pkg` installer.
enum JackInstallMethod: Equatable {
    case homebrew
    case pkg
}

// MARK: - JackManager

/// The central observable manager for the Jack audio server.
///
/// Responsibilities:
/// - Locating the Jack executable and checking its version
/// - Starting and stopping the `jackdmp` / `jackd` process
/// - Monitoring whether Jack is running (via sysctl, polled every 5 s)
/// - Capturing and throttling Jack log output
/// - Persisting and loading user preferences via `UserDefaults`
@MainActor
final class JackManager: ObservableObject {

    @Published var isRunning:             Bool          = false
    @Published var launchedByUs:          Bool          = false
    @Published var jackExecutableURL:     URL?          = nil
    @Published var jackInstalled:         Bool          = false
    @Published var selectedInstallMethod: JackInstallMethod? = nil
    @Published var installedJackVersion:  String?       = nil
    @Published var latestJackVersion:     String?       = nil
    @Published var jackUpdateAvailable:   Bool          = false
    @Published var jackState:             JackState     = .ready
    @Published var statusMessage:         String        = String(localized: "jack.status.ready")
    @Published var prefs                               = JackPreferences()

    /// Command tokens used to launch the current Jack server (nil if not launched by us or stopped).
    var runningCommand: [String]?

    /// Closure for graceful stop (close clients before stopping Jack).
    /// Set by StudioManager.observeJackState() once managers are wired up.
    var gracefulStop: (() -> Void)?
    @Published var savedInputDeviceName:  String        = UserDefaults.standard.string(forKey: "inputDeviceName")  ?? ""
    @Published var savedOutputDeviceName: String        = UserDefaults.standard.string(forKey: "outputDeviceName") ?? ""

    @Published var logLines:     [JackLogLine] = []
    @Published var showLogPanel: Bool          = false
    @Published var hasWarning:   Bool          = false
    // xrunCount is now tracked in PatchbayManager.jackBridge.xrunCount

    private var monitorTask:      Task<Void, Never>? = nil
    private var previousIsRunning: Bool = false
    private var jackProcess:      Process? = nil
    
    // Log throttling: accumulate lines and flush every 100 ms
    private var pendingLogLines: [String] = []
    private var logFlushTask: DispatchWorkItem? = nil
    private let logFlushDelay: TimeInterval = 0.1  // 100 ms
    private var logIdCounter: Int = 0  // Simple counter instead of UUID
    private let maxLogLines: Int = 150  // Reduced from 500 to 150

    // Log capture is limited to the startup window
    private var startupLogCaptureEnabled: Bool = true
    private var startupTime: Date? = nil
    private let startupLogCaptureDuration: TimeInterval = 10.0  // Capture logs for 10 s after start

    init() {
        jackExecutableURL = findJackExecutable()
        jackInstalled     = jackExecutableURL != nil
        loadPreferences()
        if jackExecutableURL == nil {
            setState(.executableNotFound)
        } else {
            fetchInstalledVersion()
            fetchLatestJackVersion()
        }
        startMonitoring()
    }

    deinit {
        monitorTask?.cancel()
    }

    // MARK: - Preferences persistence

    func loadPreferences() {
        let d = UserDefaults.standard
        prefs.inputDeviceUID  = d.string(forKey: "inputDeviceUID")  ?? ""
        prefs.outputDeviceUID = d.string(forKey: "outputDeviceUID") ?? ""
        prefs.sampleRate      = d.double(forKey: "sampleRate").nonZero  ?? 48000
        prefs.bufferSize      = d.integer(forKey: "bufferSize").nonZero ?? 256
        prefs.hogMode         = d.bool(forKey: "hogMode")
        prefs.clockDrift      = d.bool(forKey: "clockDrift")
        prefs.midiEnabled     = d.bool(forKey: "midiEnabled")
        prefs.limitChannels        = d.bool(forKey: "limitChannels")
        // Channel selection always resets to all channels on launch
        prefs.selectedInChannels  = []
        prefs.selectedOutChannels = []
        savedInputDeviceName  = d.string(forKey: "inputDeviceName")  ?? ""
        savedOutputDeviceName = d.string(forKey: "outputDeviceName") ?? ""
    }

    func savePreferences() {
        let d = UserDefaults.standard
        d.set(prefs.inputDeviceUID,   forKey: "inputDeviceUID")
        d.set(prefs.outputDeviceUID,  forKey: "outputDeviceUID")
        d.set(prefs.sampleRate,       forKey: "sampleRate")
        d.set(prefs.bufferSize,       forKey: "bufferSize")
        d.set(prefs.hogMode,           forKey: "hogMode")
        d.set(prefs.clockDrift,        forKey: "clockDrift")
        d.set(prefs.midiEnabled,       forKey: "midiEnabled")
        d.set(prefs.limitChannels,          forKey: "limitChannels")
        d.set(prefs.selectedInChannels,    forKey: "selectedInChannels")
        d.set(prefs.selectedOutChannels,   forKey: "selectedOutChannels")
        d.set(savedInputDeviceName,   forKey: "inputDeviceName")
        d.set(savedOutputDeviceName,  forKey: "outputDeviceName")
    }

    // MARK: - State transitions

    /// Sets both `jackState` and the matching localised `statusMessage` atomically.
    private func setState(_ state: JackState) {
        jackState     = state
        statusMessage = String(localized: state.localizationKey)
    }

    // MARK: - Executable detection

    /// Re-checks whether the Jack executable is available.
    /// Called on app activation to detect installations that happened while the app was open.
    func recheckInstallation() {
        let url = findJackExecutable()
        jackExecutableURL = url
        let nowInstalled = url != nil
        if nowInstalled && !jackInstalled {
            setState(.ready)
            selectedInstallMethod = nil
            fetchInstalledVersion()
            fetchLatestJackVersion()
        }
        if !nowInstalled {
            installedJackVersion = nil
            jackUpdateAvailable  = false
        }
        jackInstalled = nowInstalled
    }

    // MARK: - Jack version check

    /// Runs the Jack executable with --version and parses the version string.
    func fetchInstalledVersion() {
        guard let execURL = jackExecutableURL else { return }
        Task.detached { [execURL] in
            let process = Process()
            process.executableURL = execURL
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe
            try? process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            let parsed = Self.parseJackVersion(from: output)
            await MainActor.run {
                self.installedJackVersion = parsed
                self.updateVersionComparison()
            }
        }
    }

    /// Fetches the latest Jack release tag from GitHub API (cached for 24 h).
    func fetchLatestJackVersion() {
        let cacheVersionKey = "JM.latestJackVersion"
        let cacheDateKey    = "JM.latestJackVersionDate"
        let d = UserDefaults.standard

        // Use cache if fresh (< 24 h)
        if let cached = d.string(forKey: cacheVersionKey),
           let date   = d.object(forKey: cacheDateKey) as? Date,
           Date().timeIntervalSince(date) < 86400 {
            latestJackVersion = cached
            updateVersionComparison()
            return
        }

        Task.detached {
            guard let url = URL(string: "https://api.github.com/repos/jackaudio/jack2-releases/releases/latest") else { return }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName    = json["tag_name"] as? String else { return }
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            d.set(version, forKey: cacheVersionKey)
            d.set(Date(),   forKey: cacheDateKey)
            await MainActor.run {
                self.latestJackVersion = version
                self.updateVersionComparison()
            }
        }
    }

    private func updateVersionComparison() {
        guard let installed = installedJackVersion,
              let latest    = latestJackVersion else {
            jackUpdateAvailable = false
            return
        }
        jackUpdateAvailable = Self.isVersion(latest, newerThan: installed)
    }

    /// Parses a version string of the form "X.Y.Z" from jackd --version output.
    private nonisolated static func parseJackVersion(from output: String) -> String? {
        let pattern = #"version\s+(\d+\.\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output,
                                           range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    /// Returns true if v1 is strictly newer than v2 (semantic version comparison).
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

    func findJackExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/jackdmp",
            "/usr/local/bin/jackdmp",
            "/opt/homebrew/bin/jackd",
            "/usr/local/bin/jackd",
            "/usr/bin/jackdmp",
            "/usr/bin/jackd",
            "/opt/local/bin/jackdmp",
            "/opt/local/bin/jackd",
            "/usr/local/sbin/jackdmp",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        if let r = try? shellOutput(command: "which", arguments: ["jackdmp"]),
           !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: r.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let r = try? shellOutput(command: "which", arguments: ["jackd"]),
           !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: r.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    // MARK: - Start / Stop

    func startJack() {
        guard let execURL = jackExecutableURL else {
            setState(.executableNotFound)
            return
        }
        guard !isRunning else {
            setState(.alreadyRunning)
            return
        }

        logLines.removeAll()
        pendingLogLines.removeAll()
        hasWarning   = false
        setState(.starting)
        launchedByUs = true
        
        // Enable log capture for the startup window
        startupLogCaptureEnabled = true
        startupTime = Date()

        let inputUID  = prefs.inputDeviceUID.isEmpty  ? nil : prefs.inputDeviceUID
        let outputUID = prefs.outputDeviceUID.isEmpty ? nil : prefs.outputDeviceUID
        let args      = prefs.buildCommand(
            executablePath: execURL.path,
            inputUID: inputUID,
            outputUID: outputUID)
        let shellCmd  = args.joined(separator: " ")

        // Launch the process and capture stdout + stderr
        let process    = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.launchPath     = "/bin/bash"
        process.arguments      = ["-c", shellCmd]
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        // Read stdout/stderr with THROTTLING.
        // Post-startup filtering (ignore logs after 10 s) happens inside queueLogs().
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.queueLogs(lines)
            }
        }

        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.queueLogs(lines)
            }
        }

        jackProcess = process

        // Launch the process in the background
        DispatchQueue.global(qos: .background).async { [weak self] in
            try? process.run()
            process.waitUntilExit()
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.launchedByUs = false
                self?.jackProcess  = nil
            }
        }

        // Deferred running check
        let launchedArgs = args
        Task {
            try? await Task.sleep(for: .seconds(4))
            let running = checkJackRunning()
            if running {
                runningCommand = launchedArgs
                setState(.running)
                NotificationManager.shared.notifyJackStarted(launchedByUs: true)
            } else {
                setState(.startFailed)
                launchedByUs = false
                NotificationManager.shared.notifyJackFailed()
                // Only open the log panel on failure
                showLogPanel = true
            }
        }
    }

    func stopJack() {
        setState(.stopping)
        runningCommand = nil
        jackProcess?.terminate()

        DispatchQueue.global(qos: .background).async { [weak self] in
            let process = Process()
            process.launchPath = "/bin/bash"
            process.arguments  = ["-c",
                "if pgrep jackdmp 2>/dev/null; then pkill jackdmp; fi; " +
                "if pgrep jackd 2>/dev/null; then pkill jackd; fi"]
            try? process.run()
            process.waitUntilExit()
            DispatchQueue.main.async {
                self?.launchedByUs = false
                self?.setState(.stopped)
            }
        }
    }

    // MARK: - Logs (throttled)

    /// Queues log lines and schedules a debounced flush.
    ///
    /// After the startup window expires, all jackdmp log output is discarded —
    /// xruns are counted by the native callback in JackBridge.c instead.
    private func queueLogs(_ lines: [String]) {
        // Check whether we are still within the startup capture window
        let now = Date()
        if let start = startupTime, now.timeIntervalSince(start) > startupLogCaptureDuration {
            startupLogCaptureEnabled = false
        }

        // After startup, ignore ALL jackdmp log output
        guard startupLogCaptureEnabled else { return }

        pendingLogLines.append(contentsOf: lines)
        scheduleLogFlush()
    }

    /// Schedules a log flush 100 ms from now (debounced).
    private func scheduleLogFlush() {
        logFlushTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushLogs()
        }
        logFlushTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + logFlushDelay, execute: work)
    }
    
    /// Flushes all pending log lines in a single `@Published` update.
    private func flushLogs() {
        guard !pendingLogLines.isEmpty else { return }

        let linesToAdd = pendingLogLines
        pendingLogLines.removeAll()

        var newHasWarning = hasWarning
        var newLines: [JackLogLine] = []

        for line in linesToAdd {
            let logLine = JackLogLine(id: logIdCounter, text: line, level: .detect(in: line))
            logIdCounter += 1
            newLines.append(logLine)

            // Update hasWarning incrementally
            if !newHasWarning && (logLine.level == .warning || logLine.level == .error) {
                let t = line.lowercased()
                if !(t.contains("clock drift") && t.contains("activated")) {
                    newHasWarning = true
                }
            }
        }

        // Single @Published update
        logLines.append(contentsOf: newLines)

        // Cap log buffer size
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }

        hasWarning = newHasWarning
    }

    /// Appends internal app-generated log lines, bypassing the startup filter.
    ///
    /// Called by `PatchbayManager` for its own log messages (not from jackdmp).
    func appendLogs(_ lines: [String]) {
        pendingLogLines.append(contentsOf: lines)
        scheduleLogFlush()
    }

    /// Clears all log lines and resets the warning flag.
    func clearLogs() {
        logLines.removeAll()
        pendingLogLines.removeAll()
        logIdCounter = 0
        hasWarning = false
    }

    // MARK: - Monitoring

    func startMonitoring() {
        monitorTask = Task {
            while !Task.isCancelled {
                let running = checkJackRunning()
                if running != previousIsRunning {
                    if running {
                        if !launchedByUs {
                            setState(.external)
                            NotificationManager.shared.notifyJackStarted(launchedByUs: false)
                        }
                    } else if previousIsRunning {
                        runningCommand = nil
                        setState(.stoppedExternal)
                        NotificationManager.shared.notifyJackStopped()
                    }
                    previousIsRunning = running
                }
                // Only publish when the value actually changes —
                // @Published fires on every assignment, so assigning the same
                // value every 5s would needlessly re-trigger all Combine subscribers.
                if running != isRunning {
                    isRunning = running
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Returns `true` if a `jackdmp` or `jackd` process is currently running.
    ///
    /// Uses `sysctl KERN_PROC_ALL` — no fork/exec overhead.
    func checkJackRunning() -> Bool {
        // Read the process list via sysctl — no fork/exec
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return false }
        return procs.prefix(count).contains { p in
            let name = withUnsafeBytes(of: p.kp_proc.p_comm) { bytes in
                String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            }
            return name == "jackdmp" || name == "jackd"
        }
    }

    // MARK: - Shell helper

    func shellOutput(command: String, arguments: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments     = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Numeric helpers

private extension Double {
    /// Returns `nil` when the value is zero, useful for `UserDefaults` fallback chaining.
    var nonZero: Double? { self == 0 ? nil : self }
}

private extension Int {
    /// Returns `nil` when the value is zero, useful for `UserDefaults` fallback chaining.
    var nonZero: Int? { self == 0 ? nil : self }
}
