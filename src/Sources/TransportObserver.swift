//
//  TransportObserver.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Isolated ObservableObject for transport polling at 120 ms.
//  Only TransportBarView observes it — the Patchbay canvas does not re-render.
//
//  v2 — Uses jm_get_transport_atomic(): reads atomics updated by the Jack
//  process callback (RT thread). Zero IPC, overhead ≈ nanoseconds.
//  The @MainActor annotation eliminates the need for Task { @MainActor }
//  on every timer tick.
//

import SwiftUI
import Combine

/// Polls the Jack transport at a fixed 120 ms interval using the lock-free atomic cache.
///
/// Designed to be observed exclusively by `TransportBarView` so that the
/// Patchbay canvas is not forced to re-render on every transport tick.
///
/// Call `start(bridge:)` when the Jack client opens and `stop()` when it closes.
@MainActor
final class TransportObserver: ObservableObject {

    /// The most recently polled transport position.
    @Published var position: JackTransportPosition = .zero
    /// `true` when JackMate currently holds the timebase master role.
    @Published var isMaster: Bool                  = false

    /// Called on the main actor whenever the rolling state changes.
    ///
    /// Use this to auto-show or auto-hide the transport bar.
    var onRollingChanged: ((Bool) -> Void)?

    private var timer:       Timer?
    private var bridge:      JackBridgeWrapper?
    private var lastRolling: Bool = false

    // MARK: - Lifecycle

    /// Starts the polling timer, using the provided bridge for transport queries.
    ///
    /// The timer is added to `RunLoop.main` in `.common` mode so it keeps firing
    /// during scroll and modal tracking-area events.
    ///
    /// - Parameter bridge: An open `JackBridgeWrapper` instance.
    func start(bridge: JackBridgeWrapper) {
        self.bridge = bridge
        timer?.invalidate()
        // .common mode: the timer continues firing during scroll events
        // (.default alone suspends when a modal trackingArea is active).
        // @MainActor on the class guarantees poll() runs on the main thread
        // without any Task overhead or extra DispatchQueue.
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            // The timer runs on RunLoop.main — we are already on the main thread.
            // assumeIsolated is synchronous (zero Task, zero async allocation).
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops the polling timer and resets all published state.
    func stop() {
        timer?.invalidate()
        timer       = nil
        bridge      = nil
        position    = .zero
        isMaster    = false
        lastRolling = false
    }

    // MARK: - Poll

    private func poll() {
        guard let bridge else { return }

        // Lock-free read from atomics updated by the Jack process callback.
        // No IPC call to the Jack server — overhead ≈ a few nanoseconds.
        let (state, pos) = bridge.transportQueryAtomic()

        // Only publish when values actually change to avoid unnecessary SwiftUI cycles
        if pos.frame != position.frame || pos.bpm != position.bpm || pos.bar != position.bar {
            position = pos
        }

        let master = bridge.isTimebaseMaster
        if master != isMaster { isMaster = master }

        let rolling = (state == .rolling)
        if rolling != lastRolling {
            lastRolling = rolling
            onRollingChanged?(rolling)
        }
    }
}
