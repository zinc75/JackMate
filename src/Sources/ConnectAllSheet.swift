//
//  ConnectAllSheet.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Confirmation sheet for bulk port connections between two Jack nodes.
//  Displays per-type connection plans, offers mode choices when port
//  counts are asymmetric, and shows a patchbay-accurate preview canvas.
//

import SwiftUI
import AppKit

// MARK: - ConnectAllSheet

/// A modal sheet that previews and confirms bulk connections between two Jack nodes.
///
/// For each port type shared between the two nodes, it presents:
/// - A visual preview matching the patchbay's exact rendering at 0.75× scale
/// - The list of port pairs that will be connected
/// - Mode buttons when port counts are asymmetric (min-abandon vs wrap/fan-out)
///
/// The user must explicitly confirm before any connections are made.
struct ConnectAllSheet: View {

    /// The pending connect-all operation to confirm.
    let request:   ConnectAllRequest
    /// Called with the final plans when the user confirms.
    let onConfirm: ([ConnectAllTypePlan]) -> Void

    @State  private var plans: [ConnectAllTypePlan]
    @Environment(\.dismiss) private var dismiss

    init(request: ConnectAllRequest, onConfirm: @escaping ([ConnectAllTypePlan]) -> Void) {
        self.request   = request
        self.onConfirm = onConfirm
        _plans = State(initialValue: request.typePlans)
    }

    // MARK: - Computed properties

    /// Total number of connections that will be created across all type plans.
    private var totalConnections: Int { plans.reduce(0) { $0 + pairsCount($1) } }

    private func pairsCount(_ plan: ConnectAllTypePlan) -> Int {
        switch plan.mode {
        case .minAbandon: return min(plan.n, plan.m)
        case .wrap, .fanOut:
            var ct = 0
            for i in 0..<plan.n { for j in 0..<plan.m where i % plan.m == j || j % plan.n == i { ct += 1 } }
            return ct
        }
    }

    private func computePairs(_ plan: ConnectAllTypePlan) -> [(String, String)] {
        var result: [(String, String)] = []
        switch plan.mode {
        case .minAbandon:
            for i in 0..<min(plan.n, plan.m) {
                result.append((shortName(plan.outPorts[i].id), shortName(plan.inPorts[i].id)))
            }
        case .wrap, .fanOut:
            for i in 0..<plan.n {
                for j in 0..<plan.m where i % plan.m == j || j % plan.n == i {
                    result.append((shortName(plan.outPorts[i].id), shortName(plan.inPorts[j].id)))
                }
            }
        }
        return result
    }

    private func shortName(_ portId: String) -> String {
        String(portId.split(separator: ":").last ?? Substring(portId))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Visual preview — scrollable if there are many ports
                    ScrollView(.vertical, showsIndicators: true) {
                        ConnectAllPreviewCanvas(outNode: request.outNode,
                                                inNode:  request.inNode,
                                                plans:   plans)
                            .padding(.horizontal, 2)
                    }
                    .frame(maxHeight: 135)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    ForEach($plans) { $plan in typePlanRow(plan: $plan) }
                }
                .padding(16)
            }
            Divider().background(Color.white.opacity(0.08))
            footer
        }
        .frame(width: 460)
        .background(Color(hex: "#1c1c1e"))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            nodePill(request.outNode)
            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
            nodePill(request.inNode)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func nodePill(_ node: PatchbayNode) -> some View {
        HStack(spacing: 7) {
            NodeBadgeView(node: node, size: 20)
            Text(node.id)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    // MARK: - Per-type plan row

    @ViewBuilder
    private func typePlanRow(plan: Binding<ConnectAllTypePlan>) -> some View {
        let p = plan.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            // Type header
            HStack(spacing: 6) {
                Circle().fill(p.portType.patchbayColor).frame(width: 7, height: 7)
                Text(p.portType.displayName.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.portType.patchbayColor)
                Text(verbatim: String(format: String(localized: "connect_all.subtitle"), p.n, p.m))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if p.alreadyMinConnected && p.isSymmetric {
                    Label("connect_all.already_connected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            // Port pair list
            pairsList(p)
            // Mode buttons (only shown for asymmetric port counts)
            if !p.isSymmetric {
                HStack(spacing: 6) {
                    // TODO: plurals - Étape 6
                    modeButton("Connecter \(min(p.n, p.m)) paire\(min(p.n, p.m) > 1 ? "s" : "")",
                               mode: .minAbandon, binding: plan.mode)
                    modeButton(p.altModeLabel, mode: p.altMode, binding: plan.mode)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    private func pairsList(_ plan: ConnectAllTypePlan) -> some View {
        let pairs  = computePairs(plan)
        let shown  = Array(pairs.prefix(8))
        let hidden = pairs.count - shown.count
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 4) {
                    Text(pair.0)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(minWidth: 90, alignment: .trailing)
                    Rectangle()
                        .fill(plan.portType.patchbayColor.opacity(0.4))
                        .frame(width: 14, height: 1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7))
                        .foregroundStyle(plan.portType.patchbayColor.opacity(0.7))
                    Rectangle()
                        .fill(plan.portType.patchbayColor.opacity(0.4))
                        .frame(width: 14, height: 1)
                    Text(pair.1)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            if hidden > 0 {
                // TODO: plurals - Étape 6
                Text("et \(hidden) autre\(hidden > 1 ? "s" : "") connexion\(hidden > 1 ? "s" : "")…")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func modeIcon(_ mode: ConnectAllMode) -> some View {
        if mode == .fanOut {
            // Comb-distributor icon: ●—|—● / |—● / |—●
            Canvas { ctx, size in
                let sx  = size.width  / 20
                let sy  = size.height / 20
                let lw  = max(1.0, 1.4 * sx)
                func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
                func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
                    ctx.fill(Circle().path(in: CGRect(x: (cx-r)*sx, y: (cy-r)*sy,
                                                      width: 2*r*sx, height: 2*r*sy)),
                             with: .foreground)
                }
                func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
                    var p = Path()
                    p.move(to: pt(x0, y0)); p.addLine(to: pt(x1, y1))
                    ctx.stroke(p, with: .foreground,
                               style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }
                dot(3, 10, 2)           // left source
                line(5, 10, 10, 10)     // horizontal connector
                line(10, 4, 10, 16)     // vertical distributor bar
                for cy in [4.0, 10.0, 16.0] as [CGFloat] {
                    line(10, cy, 15, cy) // horizontal branch
                    dot(17, cy, 2)       // destination
                }
            }
            .frame(width: 11, height: 11)
        } else {
            Image(systemName: mode.systemImage)
                .font(.system(size: 9, weight: .semibold))
        }
    }

    @ViewBuilder
    private func modeButton(_ label: String, mode: ConnectAllMode,
                             binding: Binding<ConnectAllMode>) -> some View {
        let sel = binding.wrappedValue == mode
        Button { binding.wrappedValue = mode } label: {
            HStack(spacing: 4) {
                modeIcon(mode)
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundStyle(sel ? .white : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(sel ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.05)))
            .overlay(Capsule().stroke(sel ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("common.cancel") { dismiss() }
                .keyboardShortcut(.escape)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button {
                onConfirm(plans)
                dismiss()
            } label: {
                // TODO: plurals - Étape 6
                Text("Connecter \(totalConnections) connexion\(totalConnections > 1 ? "s" : "")")
                    .font(.system(size: 12, weight: .semibold))
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .disabled(totalConnections == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - ConnectAllPreviewCanvas

/// A scale-accurate (0.75×) canvas preview of the connections to be made.
///
/// Replicates the patchbay rendering style exactly:
/// - Node body gradients and rounded rectangles
/// - Badge gradient using the same colour derivation as `BadgeUtils`
/// - Gems straddling node edges (±1 px) matching the real patchbay layout
/// - Bézier cables with glow (lw 4 / α 0.25) and main stroke (lw 1.8 / α 0.85)
/// - Dynamic node width based on the longest client name
private struct ConnectAllPreviewCanvas: View {

    let outNode: PatchbayNode
    let inNode:  PatchbayNode
    let plans:   [ConnectAllTypePlan]

    // Layout constants scaled to 0.75× (patchbay rowH=21, headerH=46, nodeW=200)
    private let rowH:    CGFloat = 16   // 21 × 0.75
    private let hdrH:    CGFloat = 35   // 46 × 0.75
    private let secGap:  CGFloat = 8
    private let topPad:  CGFloat = 10
    private let botPad:  CGFloat = 10
    private let hPad:    CGFloat = 8
    private let gemR:    CGFloat = 5    // connected gem radius (same as patchbay)
    private let badgeSz: CGFloat = 20

    /// Dynamic node width: adapts to the longest client name, clamped to [120, 180].
    private var nodeW: CGFloat {
        let charW: CGFloat = 6.0
        let left: CGFloat  = 7 + badgeSz + 5
        let right: CGFloat = 10
        let wOut = left + CGFloat(outNode.id.count) * charW + right
        let wIn  = left + CGFloat(inNode.id.count)  * charW + right
        return max(120, min(max(wOut, wIn), 180))
    }

    // Node body gradient colours (exact patchbay values)
    private let nodeTop = Color(.sRGB, red: 0.07, green: 0.07, blue: 0.08, opacity: 1)
    private let nodeBot = Color(.sRGB, red: 0.10, green: 0.10, blue: 0.11, opacity: 1)

    private var canvasH: CGFloat {
        topPad + hdrH
        + plans.reduce(0) { $0 + CGFloat(max($1.n, $1.m)) * rowH }
        + CGFloat(max(0, plans.count - 1)) * secGap
        + botPad
    }

    // MARK: - Badge colour derivation

    private struct BC { let top, bot, txt: Color; let abbr: String }

    private func bc(for node: PatchbayNode) -> BC {
        let abbr     = BadgeUtils.abbrev(node.id)
        let isSystem = node.id.hasPrefix("system")
        let isCap    = node.id.hasSuffix("(capture)")
        let base: NSColor = isSystem
            ? (isCap ? NSColor(hue: 0.524, saturation: 0.70, brightness: 0.78, alpha: 1)
                     : NSColor(hue: 0.780, saturation: 0.50, brightness: 0.82, alpha: 1))
            : BadgeUtils.nsColor(abbr, fullName: node.id)
        guard let s = base.usingColorSpace(.sRGB) else {
            return BC(top: .gray, bot: .gray, txt: .white, abbr: abbr)
        }
        let (r, g, b) = (s.redComponent, s.greenComponent, s.blueComponent)
        let top = Color(.sRGB, red: min(r+0.18,1), green: min(g+0.18,1), blue: min(b+0.18,1), opacity: 1)
        let bot = Color(.sRGB, red: max(r-0.08,0), green: max(g-0.08,0), blue: max(b-0.08,0), opacity: 1)
        var h: CGFloat = 0, sat: CGFloat = 0, bv: CGFloat = 0, a: CGFloat = 0
        s.getHue(&h, saturation: &sat, brightness: &bv, alpha: &a)
        let txt = Color(NSColor(hue: h, saturation: 0.65, brightness: 0.22, alpha: 1))
        return BC(top: top, bot: bot, txt: txt, abbr: abbr)
    }

    // MARK: - Pair index algorithm (mirrors PatchbayManager)

    private func indexPairs(_ plan: ConnectAllTypePlan) -> [(Int, Int)] {
        switch plan.mode {
        case .minAbandon: return (0..<min(plan.n, plan.m)).map { ($0, $0) }
        case .wrap, .fanOut:
            var r: [(Int, Int)] = []
            for i in 0..<plan.n {
                for j in 0..<plan.m where i % plan.m == j || j % plan.n == i { r.append((i, j)) }
            }
            return r
        }
    }

    private func shortName(_ id: String) -> String {
        String(id.split(separator: ":").last ?? Substring(id))
    }

    // MARK: - Canvas drawing

    var body: some View {
        Canvas { ctx, size in
            let nw   = nodeW
            let lx   = hPad
            let rx   = size.width - hPad - nw
            // Gems straddle node edges by 1 pt (as in the real patchbay)
            let outGemX = lx + nw + 1
            let inGemX  = rx - 1
            let pillH   = canvasH - topPad - botPad
            let nodeGrad = Gradient(colors: [nodeTop, nodeBot])

            // ── Node bodies ──────────────────────────────────────────────────
            for px in [lx, rx] {
                let rect = CGRect(x: px, y: topPad, width: nw, height: pillH)
                let path = RoundedRectangle(cornerRadius: 8).path(in: rect)
                ctx.fill(path, with: .linearGradient(nodeGrad,
                    startPoint: CGPoint(x: px + nw/2, y: topPad),
                    endPoint:   CGPoint(x: px + nw/2, y: topPad + pillH),
                    options:    []))
                ctx.stroke(path, with: .color(.white.opacity(0.15)), lineWidth: 1)
            }

            // ── Header / body separator ───────────────────────────────────────
            let hdrY = topPad + hdrH
            for px in [lx, rx] {
                var d = Path()
                d.move(to:    CGPoint(x: px + 5,      y: hdrY))
                d.addLine(to: CGPoint(x: px + nw - 5, y: hdrY))
                ctx.stroke(d, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }

            // ── Badges ────────────────────────────────────────────────────────
            for (node, px) in [(outNode, lx), (inNode, rx)] {
                let b   = bc(for: node)
                let bx  = px + 7
                let by  = topPad + (hdrH - badgeSz) / 2
                let br  = CGRect(x: bx, y: by, width: badgeSz, height: badgeSz)
                let bp  = RoundedRectangle(cornerRadius: badgeSz * 0.28).path(in: br)
                ctx.fill(bp, with: .linearGradient(Gradient(colors: [b.top, b.bot]),
                    startPoint: CGPoint(x: bx + badgeSz/2, y: by),
                    endPoint:   CGPoint(x: bx + badgeSz/2, y: by + badgeSz),
                    options:    []))
                ctx.draw(Text(b.abbr).font(.system(size: 9, weight: .bold)).foregroundStyle(b.txt),
                         at: CGPoint(x: bx + badgeSz/2, y: by + badgeSz/2), anchor: .center)
                ctx.draw(Text(node.id).font(.system(size: 9, weight: .semibold))
                             .foregroundStyle(Color.white.opacity(0.80)),
                         at: CGPoint(x: bx + badgeSz + 5, y: by + badgeSz/2), anchor: .leading)
            }

            // ── Per-type port sections ────────────────────────────────────────
            var secY = topPad + hdrH
            for (pi, plan) in plans.enumerated() {
                let col = plan.portType.patchbayColor
                let sH  = CGFloat(max(plan.n, plan.m)) * rowH

                // Section separator
                if pi > 0 {
                    var d = Path()
                    d.move(to:    CGPoint(x: lx + 4,                y: secY - secGap/2))
                    d.addLine(to: CGPoint(x: size.width - hPad - 4, y: secY - secGap/2))
                    ctx.stroke(d, with: .color(.white.opacity(0.07)), lineWidth: 1)
                }

                // Y-centre of each port row (matches patchbay rowY + rowH/2)
                let outGemYs = (0..<plan.n).map { secY + CGFloat($0) * rowH + rowH / 2 }
                let inGemYs  = (0..<plan.m).map { secY + CGFloat($0) * rowH + rowH / 2 }

                // ── Cables: glow (lw 4 / α 0.25) + main stroke (lw 1.8 / α 0.85)
                for (i, j) in indexPairs(plan) {
                    guard i < outGemYs.count, j < inGemYs.count else { continue }
                    let a  = CGPoint(x: outGemX, y: outGemYs[i])
                    let b  = CGPoint(x: inGemX,  y: inGemYs[j])
                    let dx = abs(b.x - a.x) * 0.48
                    var c  = Path()
                    c.move(to: a)
                    c.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y),
                                      control2: CGPoint(x: b.x - dx, y: b.y))
                    ctx.stroke(c, with: .color(col.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 4,   lineCap: .round))
                    ctx.stroke(c, with: .color(col.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }

                // ── Output gems (right edge of left node, ±1 pt)
                for (i, gy) in outGemYs.enumerated() {
                    ctx.fill(Circle().path(in: CGRect(x: outGemX - gemR, y: gy - gemR,
                                                      width: gemR*2, height: gemR*2)),
                             with: .color(col))
                    if i < plan.outPorts.count {
                        ctx.draw(Text(shortName(plan.outPorts[i].id))
                                     .font(.system(size: 7.5, design: .monospaced))
                                     .foregroundStyle(col.opacity(0.85)),
                                 at: CGPoint(x: outGemX - gemR - 5, y: gy), anchor: .trailing)
                    }
                }

                // ── Input gems (left edge of right node, ±1 pt)
                for (j, gy) in inGemYs.enumerated() {
                    ctx.fill(Circle().path(in: CGRect(x: inGemX - gemR, y: gy - gemR,
                                                      width: gemR*2, height: gemR*2)),
                             with: .color(col))
                    if j < plan.inPorts.count {
                        ctx.draw(Text(shortName(plan.inPorts[j].id))
                                     .font(.system(size: 7.5, design: .monospaced))
                                     .foregroundStyle(col.opacity(0.85)),
                                 at: CGPoint(x: inGemX + gemR + 5, y: gy), anchor: .leading)
                    }
                }

                secY += sH + secGap
            }
        }
        .frame(height: canvasH)
    }
}
