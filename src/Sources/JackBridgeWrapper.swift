//
//  JackBridgeWrapper.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  High-level Swift wrapper around the JackBridge C layer.
//  Handles client lifecycle, port/connection introspection,
//  transport control, and xrun counting.
//
//  v2 — use-after-free fix:
//  - Swift callbacks are nullified BEFORE calling close()
//  - Extra isOpen guards on all callbacks
//

import Foundation

// MARK: - Port direction and type

/// The signal flow direction of a Jack port.
public enum JackPortDirection {
    case input, output
}

/// The data type carried by a Jack port.
public enum JackPortType {
    case audio, midi, cv, other

    /// Human-readable lowercase label for the port type.
    var displayName: String {
        switch self {
        case .audio: return "audio"
        case .midi:  return "midi"
        case .cv:    return "cv"
        case .other: return "other"
        }
    }
}

// MARK: - JackPort

/// A snapshot of a single Jack port as seen by the patchbay.
public struct JackPort: Identifiable, Hashable {
    /// Full port identifier in `"client:port"` form.
    public let id:         String
    /// The owning Jack client name.
    public let clientName: String
    /// The short port name (without the client prefix).
    public let portName:   String
    /// Whether the port receives or sends signal.
    public let direction:  JackPortDirection
    /// The data type carried by this port.
    public let type:       JackPortType

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: JackPort, rhs: JackPort) -> Bool { lhs.id == rhs.id }
}

// MARK: - JackConnection

/// A directed connection between two Jack ports.
public struct JackConnection: Identifiable, Hashable, Equatable {
    /// Stable identifier composed of the source and destination port names.
    public var id: String { "\(from)→\(to)" }
    /// The output (source) port name.
    public let from: String
    /// The input (destination) port name.
    public let to:   String

    public func hash(into hasher: inout Hasher) { hasher.combine(from); hasher.combine(to) }
    public static func == (lhs: JackConnection, rhs: JackConnection) -> Bool {
        lhs.from == rhs.from && lhs.to == rhs.to
    }
}

// MARK: - Transport types (top-level to avoid @MainActor isolation of the wrapper)

/// A snapshot of the current Jack transport position.
///
/// `bbtValid` is `false` when no timebase master is active and BBT
/// fields (bar, beat, tick, bpm) should not be displayed.
public struct JackTransportPosition: Sendable {
    /// Current position in samples.
    public let frame:        UInt32
    /// Server sample rate in Hz.
    public let sampleRate:   UInt32
    /// Current bar number (1-based). Valid only when `bbtValid` is `true`.
    public let bar:          Int32
    /// Current beat within the bar (1-based). Valid only when `bbtValid` is `true`.
    public let beat:         Int32
    /// Current tick within the beat. Valid only when `bbtValid` is `true`.
    public let tick:         Int32
    /// Tempo in beats per minute. Valid only when `bbtValid` is `true`.
    public let bpm:          Double
    /// Number of beats per bar (time signature numerator).
    public let beatsPerBar:  Float
    /// Beat unit (time signature denominator, e.g. 4 for a quarter note).
    public let beatType:     Float
    /// `true` if a timebase master is active and BBT fields are meaningful.
    public let bbtValid:     Bool

    /// Elapsed time in seconds from frame 0.
    public var seconds: Double {
        sampleRate > 0 ? Double(frame) / Double(sampleRate) : 0
    }

    /// A zeroed-out position with no timebase master (safe default / fallback value).
    public nonisolated static var zero: JackTransportPosition {
        JackTransportPosition(frame: 0, sampleRate: 44100,
                              bar: 1, beat: 1, tick: 0,
                              bpm: 0, beatsPerBar: 4, beatType: 4,
                              bbtValid: false)
    }
}

/// The current state of the Jack transport engine.
public enum JackTransportState: Sendable, Equatable {
    case stopped, rolling, starting
}

// MARK: - JackBridgeWrapper

/// High-level Swift wrapper around the JackBridge C client (`JMClient`).
///
/// Manages a single Jack client connection and exposes:
/// - Port and connection enumeration
/// - Port registration and connection change callbacks (delivered on the main thread)
/// - Transport control (start / pause / stop / locate)
/// - Timebase master registration
/// - Xrun counting
///
/// All public methods are safe to call from the main thread. Methods marked
/// `nonisolated` may be called from background threads.
public final class JackBridgeWrapper {

    // MARK: Private state
    // nonisolated(unsafe): these properties are accessed from background threads.

    nonisolated(unsafe) private var client: OpaquePointer?  // JMClient*
    nonisolated(unsafe) private var isOpen = false
    nonisolated(unsafe) private var isClosing = false  // Prevents callbacks during teardown

    // MARK: Callbacks (delivered on the main thread)

    /// Called when a Jack port is registered or unregistered.
    ///
    /// The `Bool` parameter is `true` on registration, `false` on unregistration.
    public var onPortRegistration: ((JackPort, Bool) -> Void)?

    /// Called when a connection between two Jack ports is created or destroyed.
    ///
    /// The `Bool` parameter is `true` on connect, `false` on disconnect.
    public var onPortConnect: ((JackConnection, Bool) -> Void)?

    /// Called when the Jack server shuts down.
    public var onShutdown: (() -> Void)?

    // MARK: Init / Deinit

    public init() {}

    deinit {
        close()
    }

    // MARK: - Lifecycle

    /// Opens a Jack client connection. Jack must be running.
    ///
    /// - Parameters:
    ///   - clientName: Desired Jack client name (may be suffixed by Jack if taken).
    ///   - libPath:    Optional path to `libjack.dylib`; `nil` uses the default search path.
    /// - Throws: `JackBridgeError.openFailed` or `JackBridgeError.activateFailed`.
    public func open(clientName: String = "JackMate-Patchbay",
                     libPath: String? = nil) throws {

        guard !isOpen && !isClosing else { return }

        let cLibPath = libPath.map { ($0 as NSString).utf8String }
        let flatLibPath: UnsafePointer<CChar>? = cLibPath.flatMap { $0 }

        client = jm_client_open(clientName, flatLibPath)

        guard let client else {
            throw JackBridgeError.openFailed("Allocation mémoire échouée")
        }

        if let errPtr = jm_last_error(client) {
            let msg = String(cString: errPtr)
            // Clean up before throwing
            jm_client_close(client)
            self.client = nil
            throw JackBridgeError.openFailed(msg)
        }

        // Register C callbacks with an Unmanaged pointer to self
        let rawSelf = Unmanaged.passUnretained(self).toOpaque()

        jm_set_port_registration_callback(client, { portName, registered, ctx in
            guard let portName, let ctx else { return }
            let wrapper = Unmanaged<JackBridgeWrapper>.fromOpaque(ctx).takeUnretainedValue()
            guard !wrapper.isClosing, wrapper.isOpen else { return }

            let portId = String(cString: portName)
            DispatchQueue.main.async { [weak wrapper] in
                guard let wrapper, !wrapper.isClosing else { return }
                wrapper.onPortRegistration?(
                    JackPort(id: portId,
                             clientName: portId.components(separatedBy: ":").first ?? portId,
                             portName:   portId.components(separatedBy: ":").last  ?? portId,
                             direction:  .output,
                             type:       .audio),
                    registered
                )
            }
        }, rawSelf)

        jm_set_port_connect_callback(client, { portA, portB, connected, ctx in
            guard let portA, let portB, let ctx else { return }
            let wrapper = Unmanaged<JackBridgeWrapper>.fromOpaque(ctx).takeUnretainedValue()
            guard !wrapper.isClosing, wrapper.isOpen else { return }

            let conn = JackConnection(from: String(cString: portA),
                                      to:   String(cString: portB))
            DispatchQueue.main.async { [weak wrapper] in
                guard let wrapper, !wrapper.isClosing else { return }
                wrapper.onPortConnect?(conn, connected)
            }
        }, rawSelf)

        jm_set_shutdown_callback(client, { ctx in
            guard let ctx else { return }
            let wrapper = Unmanaged<JackBridgeWrapper>.fromOpaque(ctx).takeUnretainedValue()
            guard !wrapper.isClosing else { return }

            DispatchQueue.main.async { [weak wrapper] in
                guard let wrapper, !wrapper.isClosing else { return }
                wrapper.onShutdown?()
            }
        }, rawSelf)

        // Activate the client
        let result = jm_client_activate(client)
        guard result == 0 else {
            jm_client_close(client)
            self.client = nil
            throw JackBridgeError.activateFailed(result)
        }

        isOpen = true
    }

    /// Closes the Jack client gracefully.
    ///
    /// Swift callbacks are nullified first to prevent use-after-free. The
    /// underlying C teardown runs on a background thread to avoid blocking the UI
    /// if the Jack server is already gone.
    public func close() {
        guard isOpen, !isClosing, let client else { return }

        isClosing = true

        // CRITICAL: nullify Swift callbacks BEFORE any C teardown
        onPortRegistration = nil
        onPortConnect = nil
        onShutdown = nil

        // Capture the C pointer before clearing it on the Swift side
        let capturedClient = client
        self.client = nil
        isOpen = false

        // jack_deactivate() + jack_client_close() may block if the server is
        // already stopped — run on a background thread to keep the UI responsive.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            jm_client_close(capturedClient)
            DispatchQueue.main.async { self?.isClosing = false }
        }
    }

    /// The effective client name assigned by Jack (may differ from the requested name).
    public var clientName: String? {
        guard let client, isOpen, !isClosing else { return nil }
        guard let ptr = jm_client_name(client) else { return nil }
        return String(cString: ptr)
    }

    /// `true` when the client is open, activated, and not in the process of closing.
    public var isConnected: Bool { isOpen && client != nil && !isClosing }

    // MARK: - Port and connection queries

    /// Returns all ports visible on the Jack graph.
    ///
    /// Safe to call from a background thread.
    public nonisolated func getPorts() -> [JackPort] {
        guard let client, isOpen, !isClosing else { return [] }
        var count: Int32 = 0
        guard let raw = jm_get_ports(client, &count), count > 0 else { return [] }
        defer { jm_free_ports(raw) }

        return (0..<Int(count)).map { i in
            let p = raw[i]
            return JackPort(
                id:         String(cString: withUnsafeBytes(of: p.name)       { $0.baseAddress!.assumingMemoryBound(to: CChar.self) }),
                clientName: String(cString: withUnsafeBytes(of: p.client_name) { $0.baseAddress!.assumingMemoryBound(to: CChar.self) }),
                portName:   String(cString: withUnsafeBytes(of: p.port_name)   { $0.baseAddress!.assumingMemoryBound(to: CChar.self) }),
                direction:  p.direction == JMPortDirectionInput ? .input : .output,
                type:       jackPortType(from: p.type)
            )
        }
    }

    /// Returns all active connections on the Jack graph.
    ///
    /// Safe to call from a background thread.
    public nonisolated func getConnections() -> [JackConnection] {
        guard let client, isOpen, !isClosing else { return [] }
        var count: Int32 = 0
        guard let raw = jm_get_connections(client, &count), count > 0 else { return [] }
        defer { jm_free_connections(raw) }

        return (0..<Int(count)).map { i in
            let c = raw[i]
            return JackConnection(
                from: String(cString: withUnsafeBytes(of: c.from) { $0.baseAddress!.assumingMemoryBound(to: CChar.self) }),
                to:   String(cString: withUnsafeBytes(of: c.to)   { $0.baseAddress!.assumingMemoryBound(to: CChar.self) })
            )
        }
    }

    // MARK: - Connection management

    /// Connects two Jack ports.
    ///
    /// - Parameters:
    ///   - from:     Full name of the output (source) port.
    ///   - to:       Full name of the input (destination) port.
    ///   - fromType: Data type of the source port.
    ///   - toType:   Data type of the destination port.
    /// - Throws: `JackBridgeError.typeMismatch` if types differ,
    ///           `JackBridgeError.notConnected` if the client is not open,
    ///           `JackBridgeError.connectFailed` on Jack error.
    public func connect(from: String, to: String,
                        fromType: JackPortType, toType: JackPortType) throws {
        guard fromType == toType else {
            throw JackBridgeError.typeMismatch(fromType, toType)
        }
        guard let client, isOpen, !isClosing else { throw JackBridgeError.notConnected }
        let result = jm_connect(client, from, to)
        if result != 0 {
            throw JackBridgeError.connectFailed(from: from, to: to, code: Int(result))
        }
    }

    /// Disconnects two Jack ports.
    ///
    /// - Parameters:
    ///   - from: Full name of the output port.
    ///   - to:   Full name of the input port.
    /// - Throws: `JackBridgeError.notConnected` or `JackBridgeError.disconnectFailed`.
    public func disconnect(from: String, to: String) throws {
        guard let client, isOpen, !isClosing else { throw JackBridgeError.notConnected }
        let result = jm_disconnect(client, from, to)
        if result != 0 {
            throw JackBridgeError.disconnectFailed(from: from, to: to, code: Int(result))
        }
    }

    // MARK: - Xrun counter (thread-safe, lock-free)

    /// The number of xruns accumulated since the last reset.
    ///
    /// Incremented directly by the Jack process callback — no dispatch overhead.
    public var xrunCount: UInt32 {
        guard let client, isOpen, !isClosing else { return 0 }
        return jm_get_xrun_count(client)
    }

    /// Resets the xrun counter to zero.
    public func resetXrunCount() {
        guard let client, isOpen, !isClosing else { return }
        jm_reset_xrun_count(client)
    }

    // MARK: - Transport

    /// Queries the Jack transport state and position via IPC.
    ///
    /// Thread-safe; overhead is approximately one microsecond.
    /// Prefer `transportQueryAtomic()` for UI polling to avoid IPC.
    public nonisolated func transportQuery() -> (state: JackTransportState, pos: JackTransportPosition) {
        guard let client, isOpen, !isClosing else {
            return (.stopped, .zero)
        }
        var raw = JMTransportPosition()
        let rawState = jm_transport_query(client, &raw)
        return (mapState(rawState), mapPosition(raw))
    }

    /// Reads the transport state from the lock-free cache updated by the process callback.
    ///
    /// Zero IPC, zero server overhead — the preferred method for UI polling timers.
    public nonisolated func transportQueryAtomic() -> (state: JackTransportState, pos: JackTransportPosition) {
        guard let client, isOpen, !isClosing else {
            return (.stopped, .zero)
        }
        var raw = JMTransportPosition()
        let rawState = jm_get_transport_atomic(client, &raw)
        return (mapState(rawState), mapPosition(raw))
    }

    /// Maps a C `JMTransportState` value to its Swift equivalent.
    nonisolated private func mapState(_ rawState: JMTransportState) -> JackTransportState {
        switch rawState {
        case JMTransportRolling:  return .rolling
        case JMTransportStarting: return .starting
        default:                  return .stopped
        }
    }

    /// Maps a C `JMTransportPosition` struct to a `JackTransportPosition` value type.
    nonisolated private func mapPosition(_ raw: JMTransportPosition) -> JackTransportPosition {
        JackTransportPosition(
            frame:       raw.frame,
            sampleRate:  raw.sample_rate,
            bar:         raw.bar,
            beat:        raw.beat,
            tick:        raw.tick,
            bpm:         raw.bpm,
            beatsPerBar: raw.beats_per_bar,
            beatType:    raw.beat_type,
            bbtValid:    raw.bbt_valid
        )
    }

    /// Starts rolling the Jack transport.
    public func transportStart() {
        guard let client, isOpen, !isClosing else { return }
        jm_transport_start(client)
    }

    /// Pauses the Jack transport at its current position.
    public func transportPause() {
        guard let client, isOpen, !isClosing else { return }
        jm_transport_stop(client)
    }

    /// Stops the Jack transport and rewinds to frame 0.
    public func transportStop() {
        guard let client, isOpen, !isClosing else { return }
        jm_transport_stop(client)
        jm_transport_locate(client, 0)
    }

    /// Repositions the Jack transport to an absolute frame offset.
    ///
    /// - Parameter frame: Target position in samples.
    public func transportLocate(frame: UInt32) {
        guard let client, isOpen, !isClosing else { return }
        jm_transport_locate(client, frame)
    }

    /// The server's sample rate in Hz.
    public var sampleRate: UInt32 {
        guard let client, isOpen, !isClosing else { return 44100 }
        return jm_get_sample_rate(client)
    }

    // MARK: - Timebase master

    /// Attempts to become the Jack timebase master.
    ///
    /// - Parameters:
    ///   - bpm:          Initial tempo in beats per minute.
    ///   - beatsPerBar:  Time signature numerator (e.g. `4`).
    ///   - beatType:     Time signature denominator (e.g. `4` for a quarter note).
    ///   - conditional:  If `true`, fails silently when another master is already active.
    /// - Returns: `true` if JackMate is now the timebase master.
    @discardableResult
    public func becomeTimebaseMaster(bpm: Double = 120,
                                     beatsPerBar: Float = 4,
                                     beatType: Float = 4,
                                     conditional: Bool = true) -> Bool {
        guard let client, isOpen, !isClosing else { return false }
        return jm_set_timebase_master(client, bpm, beatsPerBar, beatType, conditional)
    }

    /// Updates the tempo while JackMate holds the timebase master role.
    ///
    /// - Parameter bpm: New tempo in beats per minute.
    public func updateTimebaseBPM(_ bpm: Double) {
        guard let client, isOpen, !isClosing else { return }
        jm_update_timebase_bpm(client, bpm)
    }

    /// Releases the timebase master role.
    public func releaseTimebase() {
        guard let client, isOpen, !isClosing else { return }
        jm_release_timebase(client)
    }

    /// `true` if JackMate is currently the active timebase master.
    public var isTimebaseMaster: Bool {
        guard let client, isOpen, !isClosing else { return false }
        return jm_is_timebase_master(client)
    }

    // MARK: - Client introspection

    /// Returns the OS process ID of a Jack client by its client name, or `nil` if unavailable.
    ///
    /// Requires `jack_get_client_pid`, which is an optional weak export in Jack 2.
    public func getClientPID(name: String) -> pid_t? {
        guard let client, isOpen, !isClosing else { return nil }
        let pid = jm_get_client_pid(client, name)
        return pid > 0 ? pid_t(pid) : nil
    }

    // MARK: - Private helpers

    /// Maps a C `JMPortType` value to its Swift `JackPortType` equivalent.
    nonisolated private func jackPortType(from cType: JMPortType) -> JackPortType {
        switch cType {
        case JMPortTypeAudio: return .audio
        case JMPortTypeMIDI:  return .midi
        case JMPortTypeCV:    return .cv
        default:              return .other
        }
    }
}

// MARK: - JackBridgeError

/// Errors thrown by `JackBridgeWrapper`.
public enum JackBridgeError: LocalizedError {
    /// The Jack client could not be opened.
    case openFailed(String)
    /// The Jack client was opened but activation failed.
    case activateFailed(Int32)
    /// An operation was attempted while the client is not connected.
    case notConnected
    /// A connection was attempted between ports of incompatible types.
    case typeMismatch(JackPortType, JackPortType)
    /// Jack refused a port connection request.
    case connectFailed(from: String, to: String, code: Int)
    /// Jack refused a port disconnection request.
    case disconnectFailed(from: String, to: String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg):
            return "Connexion Jack échouée : \(msg)"
        case .activateFailed(let code):
            return "Activation Jack échouée (code \(code))"
        case .notConnected:
            return "Client Jack non connecté"
        case .typeMismatch(let a, let b):
            return "Types incompatibles : \(a.displayName) → \(b.displayName)"
        case .connectFailed(let from, let to, let code):
            return "Connexion \(from) → \(to) refusée (code \(code))"
        case .disconnectFailed(let from, let to, let code):
            return "Déconnexion \(from) → \(to) refusée (code \(code))"
        }
    }
}
