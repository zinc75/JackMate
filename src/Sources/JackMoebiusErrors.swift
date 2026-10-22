//
//  JackMoebiusErrors.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  A refused JackMoebius request (`jack_apply`, `jack_add*`, `jack_rebuild`) answers
//  `{"status":"error","message":…,"code":…,"details":…}`. The `code` is a stable identifier JackMate
//  words in the user's language, with the numbers of `details`; the English `message` is only the
//  fallback for a code JackMate does not know.
//

import Foundation

/// One of the biggest holders of a bus, from `details.largest_holders`.
nonisolated struct JMHolder: Equatable, Sendable {
    let app: String
    let channels: Int
}

/// The `details` of a refusal. Every field is optional: each code fills the few that it needs.
nonisolated struct JMErrorDetails: Equatable, Sendable {
    var app: String? = nil
    var given: Int? = nil, min: Int? = nil, max: Int? = nil     // invalid_channel_count
    var needed: Int? = nil, free: Int? = nil, held: Int? = nil  // capacity_*_full
    /// Free stereo pairs on the bus (a shared output is a stereo stem): `free > 0` with `freePairs == 0` is a
    /// fragmented bus. `ownHeld`: output lanes of the app itself that would stay held because its private
    /// input keeps the card (only present when > 0).
    var freePairs: Int? = nil, ownHeld: Int? = nil
    var holders: [JMHolder] = []                                // capacity_*_full
    var portsRegistered: Int? = nil                             // jack_port_limit
    var slotMax: Int? = nil                                     // slot_exhausted (`max`)

    /// Parses a `details` object. `nil` when absent or not an object. `static` so it is testable.
    static func parse(_ value: Any?) -> JMErrorDetails? {
        guard let d = value as? [String: Any] else { return nil }
        var out = JMErrorDetails()
        out.app = d["app"] as? String
        out.given = d["given"] as? Int
        out.min = d["min"] as? Int
        out.max = d["max"] as? Int
        out.needed = d["needed"] as? Int
        out.free = d["free"] as? Int
        out.held = d["held"] as? Int
        out.freePairs = d["free_pairs"] as? Int
        out.ownHeld = d["own_held"] as? Int
        out.portsRegistered = d["ports_registered"] as? Int
        out.slotMax = d["max"] as? Int
        out.holders = (d["largest_holders"] as? [[String: Any]] ?? []).compactMap { h in
            guard let app = h["app"] as? String, let n = h["channels"] as? Int else { return nil }
            return JMHolder(app: app, channels: n)
        }
        return out
    }
}

/// A refusal kept to show under the app's row.
nonisolated struct JMApplyError: Equatable, Sendable {
    let code: String?
    let message: String      // the daemon's English sentence (fallback)
    let details: JMErrorDetails?
}

extension JMApplyError {

    /// The refusal says the app's own private input keeps its card (`own_held` > 0): moving the input to
    /// the shared mode in the same request is the way out.
    var needsInputMovedToo: Bool {
        code == "capacity_forward_full" && (details?.ownHeld ?? 0) > 0
    }

    /// The sentence shown to the user, worded from the code and its numbers; the daemon's English
    /// `message` for a code that is unknown (or internal, like `backing_required`). `appName` is the
    /// display name of the app, used when `details` does not carry one.
    @MainActor
    func text(appName: String) -> String {
        let d = details
        let app = d?.app ?? appName
        switch code {
        case "jack_not_running":
            return String(localized: "jackmoebius.error.jack_not_running")
        case "transport_not_ready":
            return String(localized: "jackmoebius.error.transport_not_ready")
        case "app_not_running":
            return String(format: String(localized: "jackmoebius.error.app_not_running"), app)
        case "no_audio_context":
            return String(format: String(localized: "jackmoebius.error.no_audio_context"), app)
        case "not_capture_capable":
            return String(format: String(localized: "jackmoebius.error.not_capture_capable"), app)
        case "app_blacklisted":
            return String(format: String(localized: "jackmoebius.error.app_blacklisted"), app)
        case "invalid_channel_count":
            guard let given = d?.given, let lo = d?.min, let hi = d?.max else { break }
            return String(format: String(localized: "jackmoebius.error.invalid_channel_count"), given, lo, hi)
        case "capacity_forward_full", "capacity_reverse_full":
            guard let needed = d?.needed, let free = d?.free else { break }
            // The app's own private input keeps its card: moving only the output to the shared mode would
            // leave its output lanes held, so the bus cannot take it. The way out is to move the input too.
            if let own = d?.ownHeld, own > 0, code == "capacity_forward_full" {
                return String(format: String(localized: "jackmoebius.error.own_held"), app, own)
            }
            // Free channels but no free stereo pair: a shared output needs two neighbouring channels.
            if code == "capacity_forward_full", free > 0, d?.freePairs == 0 {
                return String(format: String(localized: "jackmoebius.error.capacity_fragmented"), free)
            }
            var text = String(format: code == "capacity_forward_full"
                                  ? String(localized: "jackmoebius.error.capacity_forward_full")
                                  : String(localized: "jackmoebius.error.capacity_reverse_full"),
                              needed, free)
            if let held = d?.held, held > 0 {
                text += " " + String(format: String(localized: "jackmoebius.error.capacity_held"), held)
            }
            if let holders = d?.holders, !holders.isEmpty {
                let list = holders.prefix(3).map { "\($0.app) (\($0.channels))" }.joined(separator: ", ")
                text += " " + String(format: String(localized: "jackmoebius.error.capacity_holders"), list)
            }
            return text
        case "slot_exhausted":
            guard let max = d?.slotMax else { break }
            return String(format: String(localized: "jackmoebius.error.slot_exhausted"), max)
        case "jack_port_limit":
            guard let n = d?.portsRegistered else { break }
            return String(format: String(localized: "jackmoebius.error.jack_port_limit"), n)
        case "card_not_created":
            return String(localized: "jackmoebius.error.card_not_created")
        case "no_card":
            return String(format: String(localized: "jackmoebius.error.no_card"), app)
        default:
            break
        }
        return message
    }
}
