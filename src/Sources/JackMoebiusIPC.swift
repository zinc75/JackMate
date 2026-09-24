//
//  JackMoebiusIPC.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Minimal JSON-over-Unix-socket client for jackmoebiusd. One request per
//  connection (connect → write one JSON line → read one JSON line → close),
//  mirroring the daemon's `jackmoebius` control CLI. Blocking by design — every
//  caller runs it off the main thread (e.g. inside `Task.detached`).
//

import Foundation
import Darwin

// MARK: - JackMoebiusIPCError

enum JackMoebiusIPCError: Error {
    /// `connect()` failed — no daemon is listening on the socket.
    case notRunning
    /// A socket syscall failed (socket/write/read).
    case socketFailure
    /// The reply was missing or not valid JSON.
    case badReply
    /// The daemon answered `{"status":"error","message":…,"code":…?}`. `code` is a general
    /// error marker (e.g. `"licensing"` on a refused `jack_add`); absent on older daemons.
    case daemonError(message: String, code: String?)
}

// MARK: - SubscribeOutcome

/// How a `subscribe` streaming session ended.
enum SubscribeOutcome {
    /// `connect()` failed — no daemon is listening (caller retries after a backoff).
    case notRunning
    /// The stream ended. `clean` = a `stopping` event was seen before EOF (graceful shutdown);
    /// otherwise the daemon died (bare EOF = crash) — caller decides whether to re-kickstart.
    case closed(clean: Bool)
}

// MARK: - JackMoebiusIPC

/// Stateless client for the `/tmp/jackmoebius.sock` JSON-over-Unix-socket IPC protocol.
///
/// Marked `nonisolated` throughout: the blocking socket I/O has no main-actor state and
/// must be callable from background tasks (the project defaults to `@MainActor` isolation).
enum JackMoebiusIPC {

    nonisolated static let socketPath = "/tmp/jackmoebius.sock"

    /// Receive/send timeout so a wedged daemon never hangs a polling task.
    nonisolated private static let timeoutSeconds = 2

    /// Sends one command and returns the response `data` field (may be `nil`).
    ///
    /// **Blocking** — call off the main thread. Returns `.failure(.notRunning)` when
    /// no daemon answers, so callers can map that to an inactive UI state.
    nonisolated static func request(_ command: String,
                                    _ params: [String: Any] = [:]) -> Result<Any?, JackMoebiusIPCError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socketFailure) }
        defer { close(fd) }

        // Bound the read so the poll never blocks forever on an unresponsive daemon.
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { path in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) {
                    _ = strlcpy($0, path, 104)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return .failure(.notRunning) }

        // Build {"command":…, ...params} + newline.
        var obj = params
        obj["command"] = command
        guard var line = try? JSONSerialization.data(withJSONObject: obj) else {
            return .failure(.badReply)
        }
        line.append(0x0A)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written > 0 else { return .failure(.socketFailure) }

        // Read until the daemon closes the connection.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard !buffer.isEmpty,
              let reply = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
            return .failure(.badReply)
        }
        if reply["status"] as? String == "ok" {
            return .success(reply["data"])
        }
        return .failure(.daemonError(message: reply["message"] as? String ?? "unknown error",
                                     code: reply["code"] as? String))
    }

    /// Opens a long-lived `subscribe` connection and streams invalidation events until the
    /// daemon closes (EOF) or `isCancelled()` becomes true. **Blocking** — run off the main
    /// thread. `onOpened` fires right after the subscription is registered (do the first fetch
    /// then — subscribe-before-snapshot); `onEvent` fires once per event name (`"apps_changed"`…).
    nonisolated static func subscribe(isCancelled: @escaping () -> Bool,
                                      onOpened: @escaping () -> Void,
                                      onEvent:  @escaping (String) -> Void) -> SubscribeOutcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .notRunning }
        defer { close(fd) }

        // ~1 s read timeout: an idle stream still wakes to re-check `isCancelled` (a timeout is
        // not an error, just a poll of the flag). Events themselves are unbounded in time.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { path in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return .notRunning }

        // Register the subscription, then let the caller run its first fetch.
        guard var line = try? JSONSerialization.data(withJSONObject: ["command": "subscribe"]) else {
            return .closed(clean: false)
        }
        line.append(0x0A)
        guard line.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) > 0 else {
            return .closed(clean: false)
        }
        onOpened()

        // Line-buffered JSON events until EOF / cancel.
        var buffer = Data()
        var chunk  = [UInt8](repeating: 0, count: 4096)
        var sawStopping = false
        while !isCancelled() {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                       let event = obj["event"] as? String {
                        if event == "stopping" { sawStopping = true }
                        onEvent(event)
                    }
                }
            } else if n == 0 {
                break   // EOF — daemon closed the socket
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                continue   // read timeout → re-check cancel
            } else {
                break      // real socket error
            }
        }
        return .closed(clean: sawStopping)
    }
}
