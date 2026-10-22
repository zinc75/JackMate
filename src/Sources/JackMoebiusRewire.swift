//
//  JackMoebiusRewire.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Keeps an app's JACK cables when its input or output changes backing (shared ↔ dedicated) or
//  channel count: the daemon rebuilds the app's box, so the cables are lost, but the user's intent
//  — "this source feeds that app" — has not changed. The plan is computed from the connections
//  known before the change; the manager reconnects them once the ports are back.
//

import Foundation

/// One JACK cable to restore, by port name (`"client:port"`).
struct JMWire: Equatable {
    let from: String
    let to: String
}

/// The cables to restore after applying a change to an app's sides.
enum JMRewire {

    struct Plan: Equatable {
        /// Restored without asking.
        var automatic: [JMWire] = []
        /// Would add sources to the shared input other apps also hear: only after confirmation.
        var needsConfirmation: [JMWire] = []
        /// The other apps that read the shared input (names, for the confirmation text).
        var otherSharedInputApps: [String] = []
        var isEmpty: Bool { automatic.isEmpty && needsConfirmation.isEmpty }
    }

    /// The JACK client of the shared input node (it carries `shared_input_1/2`).
    static let systemClient = "JackMoebius"

    /// Cables to restore when `app` moves its input to `inSide` and/or its output to `outSide`.
    ///
    /// - Output, any change of the exposed output: `out_k` keeps its cables (same port names).
    /// - Input, dedicated → dedicated of another width: `in_k` keeps its cables.
    /// - Input, shared → dedicated: the sources cabled on `shared_input_k` are copied onto the
    ///   card's `in_k` — nothing changes for the other apps, the shared cables stay.
    /// - Input, dedicated → shared: the sources of `in_k` go to `shared_input_k`. Automatic when
    ///   no other app reads the shared input, else it needs confirmation (they would hear them).
    static func plan(client: String, app: JackMoebiusApp, inSide: JMSide?, outSide: JMSide?,
                     connections: [JackConnection], otherSharedInputApps: [String]) -> Plan {
        var plan = Plan(otherSharedInputApps: otherSharedInputApps)

        // Output: identical port names before and after.
        if let new = outSide, app.outExposed, new != app.currentOut {
            let prefix = client + ":out_"
            for c in connections where c.from.hasPrefix(prefix) {
                if let k = index(c.from, prefix: prefix), k <= new.channels {
                    plan.automatic.append(JMWire(from: c.from, to: c.to))
                }
            }
        }

        // Input.
        if let new = inSide, app.inExposed, new != app.currentIn {
            let cardPrefix = client + ":in_"
            switch (app.inBacking, new.backing) {
            case (.dedicated, .dedicated):
                for c in connections where c.to.hasPrefix(cardPrefix) {
                    if let k = index(c.to, prefix: cardPrefix), k <= new.channels {
                        plan.automatic.append(JMWire(from: c.from, to: c.to))
                    }
                }
            case (.shared, .dedicated):
                for c in connections {
                    if let k = sharedIndex(c.to), k <= new.channels {
                        plan.automatic.append(JMWire(from: c.from, to: "\(cardPrefix)\(k)"))
                    }
                }
            case (.dedicated, .shared):
                for c in connections where c.to.hasPrefix(cardPrefix) {
                    guard let k = index(c.to, prefix: cardPrefix), k <= 2 else { continue }
                    let wire = JMWire(from: c.from, to: "\(systemClient):shared_input_\(k)")
                    if otherSharedInputApps.isEmpty { plan.automatic.append(wire) }
                    else { plan.needsConfirmation.append(wire) }
                }
            case (.shared, .shared):
                break
            }
        }
        return plan
    }

    /// `"client:in_3"` with prefix `"client:in_"` → 3.
    private static func index(_ port: String, prefix: String) -> Int? {
        port.hasPrefix(prefix) ? Int(port.dropFirst(prefix.count)) : nil
    }

    /// `"JackMoebius:shared_input_2"` (or its 1.0 alias `input_default_2`) → 2.
    private static func sharedIndex(_ port: String) -> Int? {
        for name in ["shared_input_", "input_default_"] {
            if let k = index(port, prefix: "\(systemClient):\(name)") { return k }
        }
        return nil
    }
}
