//
//  JackMoebiusNotices.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Small views that tell about the state of JackMoebius outside the app list: the capacity gauges
//  (how full the two channel buses are) and the thin strip above the patchbay that only shows up
//  when there is something to say.
//

import SwiftUI

// MARK: - Capacity

/// How full the two JackMoebius channel buses are (`status.capacity`). « Sorties » are the apps'
/// outputs (forward bus), « Entrées » their inputs (reverse bus). Both buses hold 254 channels,
/// shared by every app.
nonisolated struct JMCapacity: Equatable {
    var forwardUsed: Int, forwardTotal: Int
    var reverseUsed: Int, reverseTotal: Int
    /// Channels reserved but unused: a card whose input or output was removed keeps the lanes of that
    /// dead stream (already counted in `used`) until it is deleted or rebuilt. `…By` names the apps.
    var forwardHeld = 0, reverseHeld = 0
    var forwardHeldBy: [JMHolder] = [], reverseHeldBy: [JMHolder] = []

    /// Amber from 80 %, red when full.
    enum Level { case normal, near, full }

    static func level(used: Int, total: Int) -> Level {
        guard total > 0 else { return .normal }
        if used >= total { return .full }
        return Double(used) / Double(total) >= 0.8 ? .near : .normal
    }

    var inputsLevel:  Level { Self.level(used: reverseUsed, total: reverseTotal) }
    var outputsLevel: Level { Self.level(used: forwardUsed, total: forwardTotal) }

    /// The worst of the two buses.
    var worst: Level {
        if inputsLevel == .full || outputsLevel == .full { return .full }
        if inputsLevel == .near || outputsLevel == .near { return .near }
        return .normal
    }
}

extension JMCapacity.Level {
    var color: Color {
        switch self {
        case .normal: return JM.accentCyan
        case .near:   return JM.accentAmber
        case .full:   return JM.accentRed
        }
    }
}

/// « Entrées n / 254 » with a thin bar, amber from 80 %, red when full.
struct CapacityGauge: View {
    let title: String
    let used: Int
    let total: Int
    var held: Int = 0
    var heldBy: [JMHolder] = []

    private var level: JMCapacity.Level { JMCapacity.level(used: used, total: total) }
    private var fraction: Double { total > 0 ? min(Double(used) / Double(total), 1) : 0 }

    /// The explanation, with the apps that hold the unused channels.
    private var heldHelp: String {
        let who = heldBy.map { "\($0.app) (\($0.channels))" }.joined(separator: ", ")
        let base = String(localized: "jackmoebius.capacity.held.help")
        return who.isEmpty ? base : base + "\n" + who
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(JM.textSecondary)
                Spacer(minLength: 4)
                Text("\(used) / \(total)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(level == .normal ? JM.textPrimary : level.color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(level.color).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            if held > 0 {
                Text(String(format: String(localized: "jackmoebius.capacity.held"), held))
                    .font(.system(size: 10)).foregroundStyle(JM.textTertiary)
                    .help(heldHelp)
            }
        }
    }
}

/// The two capacity gauges side by side.
struct CapacityGauges: View {
    let capacity: JMCapacity

    var body: some View {
        HStack(spacing: 16) {
            CapacityGauge(title: String(localized: "jackmoebius.capacity.inputs"),
                          used: capacity.reverseUsed, total: capacity.reverseTotal,
                          held: capacity.reverseHeld, heldBy: capacity.reverseHeldBy)
            CapacityGauge(title: String(localized: "jackmoebius.capacity.outputs"),
                          used: capacity.forwardUsed, total: capacity.forwardTotal,
                          held: capacity.forwardHeld, heldBy: capacity.forwardHeldBy)
        }
    }
}

// MARK: - Button style

/// A small button for the notice bands: a faint tinted fill, light text and a thin outline in the band's
/// colour, so it reads as a button on the tinted background (a plain bordered one blends into it).
struct NoticeButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(JM.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(configuration.isPressed ? 0.40 : 0.22)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(tint.opacity(0.85), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Notice strip

/// A thin strip above the patchbay that appears only when there is something worth saying about
/// JackMoebius, and otherwise takes no room: a channel bus that is almost full or full, and a Mac
/// default input / output that is not JackMoebius while apps depend on it.
struct JackMoebiusNoticeStrip: View {
    @EnvironmentObject var jackMoebiusManager: JackMoebiusManager
    @EnvironmentObject var patchbayManager: PatchbayManager
    @ObservedObject var defaults: SystemDefaultsMonitor

    /// What the user closed for this session; a notice comes back once its cause clears and returns.
    @State private var dismissed: Set<String> = []
    /// The default-device conditions that held for a few seconds (JackMoebius sets the defaults itself
    /// when it starts, so a momentary gap is normal and must not flash a notice).
    @State private var outputSettled = false
    @State private var inputSettled  = false

    /// An app plays to the Mac's default output through JackMoebius, but that default is elsewhere.
    private var outputCondition: Bool {
        jackMoebiusManager.state == .active && !jackMoebiusManager.sharedOutputApps.isEmpty
            && !defaults.outputIsJackMoebius
    }

    /// An app reads the shared input (or cables remain on it), but the Mac's default input is elsewhere.
    private var inputCondition: Bool {
        guard jackMoebiusManager.state == .active, !defaults.inputIsJackMoebius else { return false }
        if !jackMoebiusManager.sharedInputBoxes.isEmpty { return true }
        return patchbayManager.connections.contains {
            $0.from.hasPrefix("JackMoebius:shared_input_") || $0.to.hasPrefix("JackMoebius:shared_input_")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if jackMoebiusManager.state == .active, let cap = jackMoebiusManager.capacity, cap.worst != .normal {
                capacityNotice(cap)
                Rectangle().fill(JM.borderFaint).frame(height: 1)
            }
            if outputSettled && outputCondition && !dismissed.contains("output") {
                defaultNotice(
                    text: String(format: String(localized: "jackmoebius.defaults.output"), defaults.outputName ?? "?"),
                    key: "output") { defaults.chooseJackMoebiusOutput() }
                Rectangle().fill(JM.borderFaint).frame(height: 1)
            }
            if inputSettled && inputCondition && !dismissed.contains("input") {
                defaultNotice(
                    text: String(format: String(localized: "jackmoebius.defaults.input"), defaults.inputName ?? "?"),
                    key: "input") { defaults.chooseJackMoebiusInput() }
                Rectangle().fill(JM.borderFaint).frame(height: 1)
            }
        }
        .task(id: outputCondition) { await settle(outputCondition, key: "output") { outputSettled = $0 } }
        .task(id: inputCondition)  { await settle(inputCondition,  key: "input")  { inputSettled  = $0 } }
    }

    /// Shows a default-device notice only once its condition has held for 2.5 s; clears it (and any
    /// dismissal) the moment the condition goes away.
    private func settle(_ condition: Bool, key: String, set: @escaping (Bool) -> Void) async {
        if condition {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { set(true) }
        } else {
            set(false)
            dismissed.remove(key)
        }
    }

    private func capacityNotice(_ cap: JMCapacity) -> some View {
        let level = cap.worst
        return HStack(spacing: 10) {
            Image(systemName: level == .full ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(level.color)
            Text(String(format: level == .full ? String(localized: "jackmoebius.capacity.full")
                                               : String(localized: "jackmoebius.capacity.near"),
                        cap.reverseUsed, cap.reverseTotal, cap.forwardUsed, cap.forwardTotal))
                .font(.system(size: 11.5)).foregroundStyle(JM.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(String(localized: "jackmoebius.capacity.view_reservations")) {
                jackMoebiusManager.showPanel = true
                jackMoebiusManager.openAdvanced(reservations: true)
            }
            .buttonStyle(NoticeButtonStyle(tint: level.color))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level.color.opacity(0.14))
    }

    /// An amber notice with an explicit « Choisir JackMoebius » action (never automatic) and a close button.
    private func defaultNotice(text: String, key: String, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.circle.fill")
                .font(.system(size: 13)).foregroundStyle(JM.accentAmber)
            Text(text)
                .font(.system(size: 11.5)).foregroundStyle(JM.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(String(localized: "jackmoebius.defaults.choose"), action: choose)
                .buttonStyle(NoticeButtonStyle(tint: JM.accentAmber))
            Button { dismissed.insert(key) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JM.textTertiary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "jackmoebius.defaults.dismiss"))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JM.accentAmber.opacity(0.14))
    }
}
