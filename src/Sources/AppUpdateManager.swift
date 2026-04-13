//
//  AppUpdateManager.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Self-update manager: checks the zinc75/JackMate GitHub releases for a newer
//  version, downloads the DMG, mounts it, replaces the running bundle in-place
//  and relaunches via a temporary shell script.
//
//  Disabled in App Store builds (App Store handles updates).
//

import SwiftUI
import Combine


// MARK: - Notification

extension Notification.Name {
    /// Posted to ask ContentView to present the AppUpdateSheet.
    static let showAppUpdateSheet = Notification.Name("JM.showAppUpdateSheet")
}

// MARK: - AppUpdateManager

/// Manages JackMate self-update: version check, download and in-place installation.
@MainActor
final class AppUpdateManager: ObservableObject {

    // MARK: Published state

    /// True when a newer release is available, network succeeded, and version is not skipped.
    @Published var updateAvailable   = false
    /// The latest version string fetched from GitHub (e.g. `"1.9.7"`).
    @Published var latestVersion:  String? = nil
    /// Download progress 0…1, meaningful only during `.downloading` phase.
    @Published var downloadProgress: Double = 0
    /// Current installation phase.
    @Published var phase: UpdatePhase = .idle

    enum UpdatePhase: Equatable {
        case idle
        case downloading
        case installing
        case error(String)
    }

    // MARK: Private

    private let cacheVersionKey = "JM.latestAppVersion"
    private let cacheDateKey    = "JM.latestAppVersionDate"
    private let skippedKey      = "JM.skippedAppVersion"

    // MARK: - Version check

    /// Checks for a newer JackMate release on GitHub.
    /// - On network failure: `updateAvailable` stays false — no stale-cache display.
    /// - Results are cached 24 h to avoid hitting the API on every launch.
    func checkForUpdates() {
        Task.detached { [self] in
            let d = UserDefaults.standard

            // Use fresh cache if available (< 24 h)
            if let cached = d.string(forKey: self.cacheVersionKey),
               let date   = d.object(forKey: self.cacheDateKey) as? Date,
               Date().timeIntervalSince(date) < 86400 {
                await MainActor.run { self.evaluate(latestTag: cached) }
                return
            }

            // Network fetch — if it fails, do NOT fall back to stale cache
            guard let url = URL(string: "https://api.github.com/repos/zinc75/JackMate/releases/latest")
            else { return }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10

            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag  = json["tag_name"] as? String
            else {
                // Network unavailable or parse error — silently ignore, no modal
                return
            }

            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            d.set(version, forKey: self.cacheVersionKey)
            d.set(Date(),   forKey: self.cacheDateKey)
            await MainActor.run { self.evaluate(latestTag: version) }
        }
    }

    private func evaluate(latestTag: String) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let skipped = UserDefaults.standard.string(forKey: skippedKey)
        latestVersion   = latestTag
        updateAvailable = Self.isVersion(latestTag, newerThan: current) && latestTag != skipped
    }

    /// Stores the latest version as skipped so the sheet is not shown again for it.
    func skipVersion() {
        guard let v = latestVersion else { return }
        UserDefaults.standard.set(v, forKey: skippedKey)
        updateAvailable = false
    }

    /// Resets the phase to idle (e.g. when the sheet is dismissed after an error).
    func resetPhase() { phase = .idle }

    // MARK: - TCC pre-flight

    /// Triggers the TCC "access to folder" prompt synchronously by attempting a
    /// temporary write in the parent directory of the current app bundle.
    /// Must be called on the main thread before starting the download.
    /// Returns true if access is available (or not required).
    @discardableResult
    func requestDestinationAccess() -> Bool {
        let parentDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        let probe     = parentDir.appendingPathComponent(".jm_access_probe")
        do {
            try "probe".write(to: probe, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            // TCC denied or probe failed — osascript fallback will handle it
            return false
        }
    }

    // MARK: - Download & install

    /// Downloads the release DMG, mounts it, atomically replaces the running bundle,
    /// then quits — a bash script relaunches the new version once this process exits.
    func downloadAndInstall() {
        guard let version = latestVersion else { return }
        let dmgName = "JackMate-\(version)-Installer.dmg"
        let urlStr  = "https://github.com/zinc75/JackMate/releases/download/v\(version)/\(dmgName)"
        guard let url = URL(string: urlStr) else { return }

        // Pre-flight: trigger TCC access prompt before the UI enters "downloading" state
        requestDestinationAccess()

        phase = .downloading
        downloadProgress = 0

        Task {
            do {
                // 1. Download DMG to /private/tmp (avoids TCC friction on ~/Documents etc.)
                let tempDMG = try await download(from: url)

                // 2. Mount DMG (with checksum verification — no -noverify)
                phase = .installing
                let mountPoint = try mountDMG(at: tempDMG)

                // 3. Locate .app inside the mounted volume
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? []
                guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    // Clean up before throwing — detach volume and delete DMG
                    let detach = Process()
                    detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    detach.arguments = ["detach", mountPoint, "-quiet"]
                    try? detach.run(); detach.waitUntilExit()
                    try? FileManager.default.removeItem(at: tempDMG)
                    throw UpdateError.appNotFound
                }
                let srcApp  = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)
                let dstApp  = URL(fileURLWithPath: Bundle.main.bundlePath)
                let dmgPath = tempDMG.path

                // 4. Write relaunch script — hands control to bash, then we quit
                let scriptURL = try writeRelaunchScript(
                    pid:    ProcessInfo.processInfo.processIdentifier,
                    src:    srcApp.path,
                    dst:    dstApp.path,
                    volume: mountPoint,
                    dmg:    dmgPath)

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments     = [scriptURL.path]
                try proc.run()

                // Brief pause so bash starts its watch loop, then exit immediately.
                // exit(0) is used instead of NSApp.terminate() to avoid the main actor
                // run-loop deadlock that would keep the app frozen during "Installing…".
                try await Task.sleep(for: .milliseconds(500))
                exit(0)

            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Download with progress

    private func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                onProgress: { [weak self] p in
                    Task { @MainActor in self?.downloadProgress = p }
                },
                onComplete: { tmpURL, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let tmp = tmpURL else {
                        continuation.resume(throwing: UpdateError.downloadFailed); return
                    }
                    // Move to /private/tmp with a fixed name — avoids TCC for ~/Documents etc.
                    let dest = URL(fileURLWithPath: "/private/tmp/JackMateUpdate.dmg")
                    do {
                        try? FileManager.default.removeItem(at: dest) // clean up any previous attempt
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        continuation.resume(returning: dest)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                })
            URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                .downloadTask(with: url).resume()
        }
    }

    // MARK: - DMG mount

    private func mountDMG(at url: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        // No -noverify: let hdiutil verify the DMG checksum for integrity
        proc.arguments = ["attach", url.path, "-nobrowse", "-noautoopen"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // hdiutil tab-separated output; mount point is the last field of the last non-empty line
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let last  = lines.last,
              let mount = last.components(separatedBy: "\t").last?
                              .trimmingCharacters(in: .whitespacesAndNewlines),
              mount.hasPrefix("/Volumes/")
        else { throw UpdateError.mountFailed }
        return mount
    }

    // MARK: - Relaunch script

    /// Writes a self-deleting bash script to /private/tmp that:
    /// 1. Waits for the current JackMate process to exit
    /// 2. Atomically replaces the app bundle (admin fallback if needed)
    /// 3. Detaches the DMG volume
    /// 4. Deletes the downloaded DMG
    /// 5. Relaunches the new version
    /// 6. Self-deletes
    private func writeRelaunchScript(pid: Int32, src: String, dst: String,
                                     volume: String, dmg: String) throws -> URL {
        let esc: (String) -> String = { $0.replacingOccurrences(of: "'", with: "'\\''") }
        let replaceCmd = "rm -rf '\(esc(dst))' && cp -R '\(esc(src))' '\(esc(dst))'"

        let script = """
        #!/bin/bash
        set -e

        # 1. Wait for JackMate (PID \(pid)) to exit
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done

        # 2. Copy new version to a temp location first (atomic swap — never leaves dst empty)
        BACKUP='\(esc(dst)).jm_backup'
        STAGING='\(esc(dst)).jm_new'

        if cp -R '\(esc(src))' "$STAGING" 2>/dev/null; then
            # Direct copy succeeded — swap
            mv -f '\(esc(dst))' "$BACKUP" 2>/dev/null || true
            if mv -f "$STAGING" '\(esc(dst))'; then
                rm -rf "$BACKUP" 2>/dev/null || true
            else
                # Swap failed — restore backup
                mv -f "$BACKUP" '\(esc(dst))' 2>/dev/null || true
                rm -rf "$STAGING" 2>/dev/null || true
            fi
        else
            # Permission denied — ask for admin password
            osascript -e "do shell script \\"\(replaceCmd)\\" with administrator privileges with prompt \\"JackMate needs administrator access to update at: \(esc(dst))\\""
        fi

        # 3. Detach the DMG volume
        /usr/bin/hdiutil detach '\(esc(volume))' -quiet 2>/dev/null || true

        # 4. Delete the downloaded DMG
        rm -f '\(esc(dmg))' 2>/dev/null || true

        # 5. Relaunch the updated app
        open '\(esc(dst))'

        # 6. Self-delete this script
        rm -- "$0"
        """

        let url = URL(fileURLWithPath: "/private/tmp/jackmate_update_\(pid).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Version comparison

    /// Returns true if v1 is strictly newer than v2 (semantic version comparison).
    private nonisolated static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let parse: (String) -> [Int] = { $0.components(separatedBy: ".").compactMap(Int.init) }
        let a = parse(v1), b = parse(v2)
        for i in 0..<max(a.count, b.count) {
            let ai = i < a.count ? a[i] : 0, bi = i < b.count ? b[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case downloadFailed, mountFailed, appNotFound
        var errorDescription: String? {
            switch self {
            case .downloadFailed: return String(localized: "update.error.download")
            case .mountFailed:    return String(localized: "update.error.mount")
            case .appNotFound:    return String(localized: "update.error.app_not_found")
            }
        }
    }
}

// MARK: - Download delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onComplete: (URL?, Error?) -> Void

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress; self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        onComplete(location, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onComplete(nil, error) }
    }
}

// MARK: - AppUpdateSheet

/// Modal sheet shown when a new JackMate release is available.
struct AppUpdateSheet: View {
    @EnvironmentObject var updateManager: AppUpdateManager
    @EnvironmentObject var jackManager:   JackManager
    @Environment(\.dismiss) var dismiss

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// True when we should block install because Jack is running.
    private var jackIsRunning: Bool { jackManager.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "update.available.title"))
                        .font(.headline).foregroundStyle(JM.textPrimary)
                    if let v = updateManager.latestVersion {
                        HStack(spacing: 6) {
                            Text(verbatim: currentVersion)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(JM.textTertiary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9)).foregroundStyle(JM.accentAmber)
                            Text(verbatim: v)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(JM.accentGreen)
                        }
                    }
                }
            }

            // ── Body ──────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "update.available.message"))
                    .font(.system(size: 12))
                    .foregroundStyle(JM.textPrimary.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                // Install path info
                Text(verbatim: Bundle.main.bundlePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(JM.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                // Admin password warning
                Text(String(localized: "update.admin.notice"))
                    .font(.system(size: 10))
                    .foregroundStyle(JM.textTertiary)
                    .lineSpacing(2)
            }

            // ── Jack running warning ───────────────────────────────────────
            if jackIsRunning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(JM.accentAmber)
                        .font(.system(size: 11))
                    Text(String(localized: "update.jack_running.warning"))
                        .font(.system(size: 11))
                        .foregroundStyle(JM.accentAmber)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(JM.tintAmber.opacity(0.15)))
            }

            // ── Progress / status ─────────────────────────────────────────
            switch updateManager.phase {
            case .idle:
                EmptyView()
            case .downloading:
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "update.downloading"))
                        .font(.system(size: 11)).foregroundStyle(JM.textTertiary)
                    ProgressView(value: updateManager.downloadProgress)
                        .progressViewStyle(.linear).tint(JM.accentGreen)
                    Text(verbatim: "\(Int(updateManager.downloadProgress * 100)) %")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(JM.textTertiary)
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "update.installing"))
                        .font(.system(size: 11)).foregroundStyle(JM.textTertiary)
                }
            case .error(let msg):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(JM.accentRed)
                    Text(msg).font(.system(size: 11)).foregroundStyle(JM.accentRed)
                }
            }

            // ── Buttons ───────────────────────────────────────────────────
            let isActive = updateManager.phase == .idle || {
                if case .error = updateManager.phase { return true }
                return false
            }()

            if isActive {
                HStack {
                    Button(String(localized: "update.button.skip")) {
                        updateManager.skipVersion(); dismiss()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button(String(localized: "update.button.later")) {
                        updateManager.resetPhase(); dismiss()
                    }
                    Button(String(localized: "update.button.install")) {
                        updateManager.downloadAndInstall()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(jackIsRunning)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

