//
//  ProcessHelper.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Utilities for macOS process introspection: executable path,
//  full command line, and signal-based termination from a PID.
//

import Foundation
import Darwin

// MARK: - ProcessHelper

enum ProcessHelper {

    /// PROC_PIDPATHINFO_MAXSIZE from <libproc.h> (4 * MAXPATHLEN = 4096)
    private static let pidPathMaxSize = 4 * Int(MAXPATHLEN)

    /// Returns the executable path for a given PID, or nil on failure.
    /// Uses proc_pidpath() — works for any process visible to the current user.
    static func executablePath(for pid: pid_t) -> String? {
        let bufSize = pidPathMaxSize
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        let len = proc_pidpath(pid, buf, UInt32(bufSize))
        guard len > 0 else { return nil }
        return String(cString: buf)
    }

    /// Returns the full command-line arguments for a given PID, or nil on failure.
    /// Uses sysctl KERN_PROCARGS2 which gives: argc (int32) + exec_path + argv strings.
    static func commandLine(for pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0

        // First call: get buffer size
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer { buffer.deallocate() }

        // Second call: fill buffer
        guard sysctl(&mib, 3, buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: int32 argc | exec_path\0 | padding\0* | argv[0]\0 argv[1]\0 ... argv[argc-1]\0
        let argc = buffer.load(as: Int32.self)
        guard argc > 0 else { return nil }

        var offset = MemoryLayout<Int32>.size

        // Skip exec_path (null-terminated)
        while offset < size && buffer.load(fromByteOffset: offset, as: UInt8.self) != 0 {
            offset += 1
        }
        // Skip trailing null bytes (padding between exec_path and argv[0])
        while offset < size && buffer.load(fromByteOffset: offset, as: UInt8.self) == 0 {
            offset += 1
        }

        // Read argc strings
        var args: [String] = []
        for _ in 0..<argc {
            guard offset < size else { break }
            let start = buffer.advanced(by: offset).assumingMemoryBound(to: CChar.self)
            let arg = String(cString: start)
            args.append(arg)
            offset += arg.utf8.count + 1 // +1 for null terminator
        }

        return args.isEmpty ? nil : args
    }

    /// Scans the process table for a process matching a Jack client name.
    /// Matches executable basename against: exact name, "jack_" + name (e.g. "metro" → "jack_metro").
    /// Returns the PID if found, nil otherwise.
    static func findPID(forJackClient clientName: String) -> pid_t? {
        // Get total PID count
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }

        var pids = [pid_t](repeating: 0, count: Int(count))
        let actual = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard actual > 0 else { return nil }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let lowered = clientName.lowercased()

        for i in 0..<Int(actual) {
            let pid = pids[i]
            guard pid > 0, pid != myPID else { continue }
            guard let path = executablePath(for: pid) else { continue }
            let basename = (path as NSString).lastPathComponent.lowercased()
            if basename == lowered || basename == "jack_\(lowered)" {
                return pid
            }
        }
        return nil
    }

    /// Sends SIGTERM to a process. Returns true if the signal was sent successfully.
    @discardableResult
    static func terminate(pid: pid_t) -> Bool {
        kill(pid, SIGTERM) == 0
    }

    /// Sends SIGKILL to a process. Returns true if the signal was sent successfully.
    @discardableResult
    static func forceKill(pid: pid_t) -> Bool {
        kill(pid, SIGKILL) == 0
    }
}
