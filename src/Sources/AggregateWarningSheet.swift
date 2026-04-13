//
//  AggregateWarningSheet.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Warning sheet shown before starting Jack when the device selection will
//  cause Jack to create a silent aggregate device. Displays a patchbay-accurate
//  preview of the resulting channel layout. Jack starts only if the user confirms.
//

import SwiftUI
import AppKit

// MARK: - AggregateLayout

/// Describes the channel layout that Jack will expose when using an implicit aggregate device.
///
/// Each block represents the contribution of one physical device to the aggregate.
struct AggregateLayout: Identifiable {
    /// Stable identity — derived from device block names so `.sheet(item:)` re-presents
    /// correctly when the device pair changes.
    var id: String {
        (captureBlocks + playbackBlocks).map { "\($0.deviceName):\($0.count)" }.joined(separator: "|")
    }

    /// Channel blocks for the `system (capture)` card, in Jack's ordering.
    /// First block = `-C` device inputs; second block (if any) = `-P` device inputs (if duplex).
    let captureBlocks:  [(deviceName: String, count: Int)]
    /// Channel blocks for the `system (playback)` card, in Jack's ordering.
    /// First block = `-P` device outputs; second block (if any) = `-C` device outputs (if duplex).
    let playbackBlocks: [(deviceName: String, count: Int)]
    /// UIDs carried through so the sheet can persist suppression without needing EnvironmentObject.
    let inUID:  String
    let outUID: String

    var totalCaptures:  Int { captureBlocks.reduce(0)  { $0 + $1.count } }
    var totalPlaybacks: Int { playbackBlocks.reduce(0) { $0 + $1.count } }
}

// MARK: - AggregateWarningSheet

/// Modal sheet displayed before Jack starts when the device selection triggers a silent aggregate.
///
/// Shows the resulting `system (capture)` and `system (playback)` cards as they will appear
/// in the patchbay, with a channel-to-device mapping legend.
/// Jack starts only when the user clicks "Start Jack" — closing or cancelling aborts the start.
struct AggregateWarningSheet: View {

    let layout:    AggregateLayout
    /// Called when the user confirms; the caller is responsible for saving prefs and starting Jack.
    let onConfirm: () -> Void
    /// Optional explicit dismiss handler. When nil, falls back to `@Environment(\.dismiss)`.
    /// Used when the sheet is hosted in a floating NSPanel (menu bar path) rather than a SwiftUI sheet.
    var onDismiss: (() -> Void)? = nil
    /// When true the built-in header row is hidden (the NSPanel title bar provides the title instead).
    var hideHeader: Bool = false

    @State private var suppress = false
    @Environment(\.dismiss) private var envDismiss

    private func doDismiss() {
        if let d = onDismiss { d() } else { envDismiss() }
    }

    // MARK: Suppression helpers

    static func suppressionKey(inUID: String, outUID: String) -> String {
        "suppressJackAggregateWarning_\(inUID)+\(outUID)"
    }

    static func isSuppressed(inUID: String, outUID: String) -> Bool {
        UserDefaults.standard.bool(forKey: suppressionKey(inUID: inUID, outUID: outUID))
    }

    private var inUID:  String { layout.inUID }
    private var outUID: String { layout.outUID }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if !hideHeader {
                header
                Divider().background(Color.white.opacity(0.08))
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("aggregate.warning.body")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Preview scrolls when there are many channels, keeping the sheet compact.
                ScrollView(.vertical, showsIndicators: true) {
                    AggregatePreviewCanvas(layout: layout)
                        .padding(6)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .frame(maxHeight: 440)
            }
            .padding(16)
            Divider().background(Color.white.opacity(0.08))
            footer
        }
        .frame(width: 480)
        .background(JM.bgBase)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JM.accentAmber)
            Text("aggregate.warning.title")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $suppress) {
                Text("aggregate.warning.suppress")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button("common.cancel") { doDismiss() }
                .keyboardShortcut(.escape)
                .buttonStyle(.bordered)
            Button {
                if suppress {
                    UserDefaults.standard.set(true,
                        forKey: AggregateWarningSheet.suppressionKey(inUID: inUID, outUID: outUID))
                }
                onConfirm()
                doDismiss()
            } label: {
                Text("aggregate.warning.start")
                    .font(.system(size: 12, weight: .semibold))
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - AggregatePreviewCanvas

/// Pure-SwiftUI preview of the Jack aggregate channel layout.
///
/// Two system node cards side by side. Uses standard SwiftUI view hierarchy
/// (no Canvas, no NSViewRepresentable) so there is no Metal shader warmup delay.
private struct AggregatePreviewCanvas: View {

    let layout: AggregateLayout
    private let rowH: CGFloat = 20

    // Pre-computed per-block data avoids mutable counters inside view builders.
    private struct BlockData: Identifiable {
        let id: Int
        let deviceName: String
        let startIdx: Int   // 1-based
        let count: Int
    }

    private func blockData(_ blocks: [(deviceName: String, count: Int)]) -> [BlockData] {
        var result: [BlockData] = []
        var idx = 1
        for (i, block) in blocks.enumerated() {
            result.append(BlockData(id: i, deviceName: block.deviceName, startIdx: idx, count: block.count))
            idx += block.count
        }
        return result
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            card(isCapture: true)
            card(isCapture: false)
        }
    }

    private func badgeGradient(isCapture: Bool) -> (top: Color, bot: Color) {
        let hue: CGFloat = isCapture ? 0.524 : 0.780
        let sat: CGFloat = isCapture ? 0.70  : 0.50
        let bri: CGFloat = isCapture ? 0.78  : 0.82
        let ns = NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        guard let s = ns.usingColorSpace(.sRGB) else { return (Color(ns), Color(ns)) }
        let r = s.redComponent; let g = s.greenComponent; let b = s.blueComponent
        return (
            Color(.sRGB, red: min(r+0.18,1), green: min(g+0.18,1), blue: min(b+0.18,1), opacity: 1),
            Color(.sRGB, red: max(r-0.08,0), green: max(g-0.08,0), blue: max(b-0.08,0), opacity: 1)
        )
    }

    @ViewBuilder
    private func card(isCapture: Bool) -> some View {
        let blocks   = isCapture ? layout.captureBlocks  : layout.playbackBlocks
        let total    = isCapture ? layout.totalCaptures  : layout.totalPlaybacks
        let maxTotal = max(layout.totalCaptures, layout.totalPlaybacks, 1)
        let hue: CGFloat = isCapture ? 0.524 : 0.780
        let iconCol  = Color(NSColor(hue: hue, saturation: 0.65, brightness: 0.22, alpha: 1))
        let audio    = Color(red: 0.29, green: 0.87, blue: 0.50)
        let bData    = blockData(blocks)
        let padRows  = maxTotal - total
        let sz: CGFloat = 24
        let grad     = badgeGradient(isCapture: isCapture)

        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: sz * 0.28)
                        .fill(LinearGradient(colors: [grad.top, grad.bot], startPoint: .top, endPoint: .bottom))
                    Image(systemName: isCapture ? "mic.fill" : "speaker.wave.2.fill")
                        .font(.system(size: sz * 0.42, weight: .semibold))
                        .foregroundStyle(iconCol)
                }
                .frame(width: sz, height: sz)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isCapture ? "system (capture)" : "system (playback)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.80))
                    Text(isCapture ? "0in · \(total)out" : "\(total)in · 0out")
                        .font(.system(size: 7.5))
                        .foregroundStyle(.white.opacity(0.38))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 44)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            // ── Port body ─────────────────────────────────────────────────
            // Two columns separated by a thin bracket bar at the horizontal midpoint.
            // Capture: free zone (device names) LEFT  | bracket | gems RIGHT
            // Playback: gems LEFT | bracket | free zone (device names) RIGHT
            HStack(alignment: .top, spacing: 0) {
                if isCapture {
                    deviceNamesColumn(bData, padRows: padRows, leading: false)
                    bracketBars(bData, padRows: padRows)
                    gemsColumn(bData, padRows: padRows, isCapture: true, audio: audio)
                } else {
                    gemsColumn(bData, padRows: padRows, isCapture: false, audio: audio)
                    bracketBars(bData, padRows: padRows)
                    deviceNamesColumn(bData, padRows: padRows, leading: true)
                }
            }
        }
        .background(
            LinearGradient(colors: [
                Color(.sRGB, red: 0.07, green: 0.07, blue: 0.08, opacity: 1),
                Color(.sRGB, red: 0.10, green: 0.10, blue: 0.11, opacity: 1)
            ], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .frame(maxWidth: .infinity)
    }

    // Bracket bars column — one bar per block with vertical margins, creating visible gaps between blocks.
    @ViewBuilder
    private func bracketBars(_ bData: [BlockData], padRows: Int) -> some View {
        let barMargin: CGFloat = 4
        VStack(spacing: 0) {
            ForEach(bData) { block in
                VStack(spacing: 0) {
                    Color.clear.frame(height: barMargin)
                    Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1)
                    Color.clear.frame(height: barMargin)
                }
                .frame(height: rowH * CGFloat(block.count))
            }
            if padRows > 0 { Color.clear.frame(height: rowH * CGFloat(padRows)) }
        }
        .frame(width: 1)
    }

    // Device names column — one label per block, vertically centred within the block height.
    @ViewBuilder
    private func deviceNamesColumn(_ bData: [BlockData], padRows: Int, leading: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(bData) { block in
                Text(block.deviceName)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity,
                           minHeight: rowH * CGFloat(block.count),
                           alignment: leading ? .leading : .trailing)
            }
            if padRows > 0 { Color.clear.frame(height: rowH * CGFloat(padRows)) }
        }
        .frame(maxWidth: .infinity)
    }

    // Gems + port label column — one row per port.
    @ViewBuilder
    private func gemsColumn(_ bData: [BlockData], padRows: Int, isCapture: Bool, audio: Color) -> some View {
        VStack(spacing: 0) {
            ForEach(bData) { block in
                ForEach(0 ..< block.count, id: \.self) { i in
                    let label = isCapture ? "capture_\(block.startIdx + i)" : "playback_\(block.startIdx + i)"
                    HStack(spacing: 3) {
                        if isCapture {
                            Spacer(minLength: 0)
                            Text(label)
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(audio.opacity(0.85))
                                .lineLimit(1)
                            Circle().fill(audio).frame(width: 9, height: 9)
                                .padding(.trailing, 1)
                        } else {
                            Circle().fill(audio).frame(width: 9, height: 9)
                                .padding(.leading, 1)
                            Text(label)
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(audio.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: rowH)
                }
            }
            if padRows > 0 { Color.clear.frame(height: rowH * CGFloat(padRows)) }
        }
        .frame(maxWidth: .infinity)
    }
}
