//
//  PatchbayView.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Zero-timer canvas: redraws only on Jack callbacks (port registration,
//  connect/disconnect) or mouse interaction (pan, zoom, drag node, drag cable).
//  Static cables (no dashed animation) = 0% CPU at rest.
//

import SwiftUI
import AppKit

// MARK: - Port color

extension JackPortType {
    /// SwiftUI colour used to draw cables and port indicators for this port type.
    var patchbayColor: Color {
        switch self {
        case .audio: return Color(hex: "#4ade80")
        case .midi:  return Color(hex: "#c084fc")
        case .cv:    return Color(hex: "#fb923c")
        case .other: return Color.white.opacity(0.35)
        }
    }
}

// MARK: - Badge utilities (shared between the canvas and the connect-all sheet)

/// Static helpers for computing node badge abbreviations and deterministic hue colours.
struct BadgeUtils {
    /// Returns a 1–2 letter abbreviation for a Jack client name (strips system suffixes).
    static func abbrev(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: " (capture)", with: "")
            .replacingOccurrences(of: " (playback)", with: "")
        let letters = cleaned.filter { $0.isLetter }
        guard let first = letters.first else { return "?" }
        let upper = String(first).uppercased()
        let second = letters.dropFirst().first.map { String($0).lowercased() } ?? ""
        return upper + second
    }

    /// Returns a deterministic `NSColor` derived from the abbreviation and full client name.
    static func nsColor(_ abbr: String, fullName: String) -> NSColor {
        let scalars = Array(abbr.unicodeScalars)
        let v1   = scalars.count > 0 ? Int(scalars[0].value) : 65
        let v2   = scalars.count > 1 ? Int(scalars[1].value) : 97
        let hash = fullName.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue  = Double((v1 * 47 + v2 * 23 + hash * 7) % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.55, brightness: 0.80, alpha: 1)
    }

    /// Returns a deterministic SwiftUI `Color` derived from the abbreviation and full client name.
    static func color(_ abbr: String, fullName: String) -> Color {
        Color(nsColor(abbr, fullName: fullName))
    }
}

// MARK: - SystemNodeSegment

/// Describes a hardware device segment within a Jack `system` card.
///
/// A system card may have one segment (single device) or two (Jack aggregate).
/// Used to label the free zone of the card with the device name and role icon.
struct SystemNodeSegment: Equatable {
    /// Short CoreAudio device name (e.g. `"RØDE AI-Micro"`).
    let deviceName: String
    /// `true` → mic icon (input role), `false` → speaker icon (output role).
    let isMic: Bool
    /// Number of Jack ports contributed by this device in this card.
    let portCount: Int
}

// MARK: - PatchbayView

/// Root patchbay view: wraps the AppKit canvas and overlays the SwiftUI context menu.
/// Owns the context menu state and delegates badge taps, connect-all, and studio capture sheets.
struct PatchbayView: View {
    @Binding var vpScale:    CGFloat
    @Binding var vpOffset:   CGSize
    @Binding var canvasSize: CGSize
    @EnvironmentObject var jackManager:  JackManager
    @EnvironmentObject var audioManager: CoreAudioManager
    @EnvironmentObject private var patchbay: PatchbayManager
    @EnvironmentObject private var studioManager: StudioManager

    // Context menu
    @State private var ctxPort:      JackPort?     = nil
    @State private var ctxNode:      PatchbayNode? = nil
    @State private var ctxNodeSide:  Bool?         = nil  // true=output side, false=input side, nil=general
    @State private var ctxCanvasPos: CGPoint       = .zero // canvas-space position, follows pan/zoom
    @State private var showCtx:      Bool          = false

    /// Screen-space position of the context menu, recomputed whenever vpOffset or vpScale changes.
    private var ctxScreenPos: CGPoint {
        CGPoint(x: ctxCanvasPos.x * vpScale + vpOffset.width,
                y: ctxCanvasPos.y * vpScale + vpOffset.height)
    }

    // Badge inspect
    @State private var tappedBadgeNode: PatchbayNode? = nil

    // Connect All modal
    @State private var connectAllRequest: ConnectAllRequest? = nil

    var body: some View {
        canvasArea
            .background(JM.bgBase)
            .sheet(item: $tappedBadgeNode) { node in
                NodeBadgeSheet(node: node, segments: systemNodeInfo[node.id] ?? [])
            }
            .sheet(item: $connectAllRequest) { req in
                ConnectAllSheet(request: req) { updatedPlans in
                    var r = req; r.typePlans = updatedPlans
                    patchbay.executeConnectAll(r)
                }
            }
            .sheet(isPresented: $patchbay.showSaveStudioDialog) {
                CaptureStudioSheet()
                    .environmentObject(jackManager)
                    .environmentObject(patchbay)
                    .environmentObject(studioManager)
            }
            .overlay(alignment: .topLeading) {
                if showCtx { contextMenu }
            }
    }

    // MARK: - Canvas

    var canvasArea: some View {
        PatchbayCanvasView(
            nodes:            patchbay.nodes,
            connections:      patchbay.connections,
            selectedNodeIds:  patchbay.selectedNodeIds,
            vpOffset:         $vpOffset,
            vpScale:          $vpScale,
            canvasSize:       $canvasSize,
            showCtx:          $showCtx,
            ctxPort:          $ctxPort,
            ctxNode:          $ctxNode,
            ctxNodeSide:      $ctxNodeSide,
            ctxCanvasPos:     $ctxCanvasPos,
            tappedBadgeNode:  $tappedBadgeNode,
            patchbay:         patchbay,
            systemNodeInfo:   systemNodeInfo
        )
    }

    // MARK: - System device info

    /// Computes device segment labels for the two `system` Jack cards.
    ///
    /// Only populated when JackMate launched Jack (device config is known).
    /// Applies the deterministic Jack aggregate channel ordering:
    /// - `system (capture)` : `-C` device inputs first, then `-P` device inputs (if duplex)
    /// - `system (playback)`: `-P` device outputs first, then `-C` device outputs (if duplex)
    private var systemNodeInfo: [String: [SystemNodeSegment]] {
        guard jackManager.launchedByUs, jackManager.isRunning else { return [:] }
        let inUID  = jackManager.prefs.inputDeviceUID
        let outUID = jackManager.prefs.outputDeviceUID
        guard !inUID.isEmpty || !outUID.isEmpty else { return [:] }

        let inDev  = audioManager.allDevices.first { $0.uid == inUID  }
        let outDev = audioManager.allDevices.first { $0.uid == outUID }

        var capture:  [SystemNodeSegment] = []
        var playback: [SystemNodeSegment] = []

        if inUID == outUID || outUID.isEmpty {
            // Single device (-d) or input only
            let dev = inDev ?? outDev
            if let dev {
                if dev.inputChannels  > 0 { capture.append(.init(deviceName: dev.name, isMic: true,  portCount: dev.inputChannels))  }
                if dev.outputChannels > 0 { playback.append(.init(deviceName: dev.name, isMic: false, portCount: dev.outputChannels)) }
            }
        } else if inUID.isEmpty {
            // Output only
            if let dev = outDev {
                if dev.inputChannels  > 0 { capture.append(.init(deviceName: dev.name, isMic: true,  portCount: dev.inputChannels))  }
                if dev.outputChannels > 0 { playback.append(.init(deviceName: dev.name, isMic: false, portCount: dev.outputChannels)) }
            }
        } else {
            // Two different devices (-C inUID -P outUID) → potential aggregate
            // capture: inDev inputs first, then outDev inputs (if duplex)
            if let dev = inDev,  dev.inputChannels  > 0 { capture.append(.init(deviceName: dev.name, isMic: true, portCount: dev.inputChannels))  }
            if let dev = outDev, dev.inputChannels  > 0 { capture.append(.init(deviceName: dev.name, isMic: true, portCount: dev.inputChannels))  }
            // playback: outDev outputs first, then inDev outputs (if duplex)
            if let dev = outDev, dev.outputChannels > 0 { playback.append(.init(deviceName: dev.name, isMic: false, portCount: dev.outputChannels)) }
            if let dev = inDev,  dev.outputChannels > 0 { playback.append(.init(deviceName: dev.name, isMic: false, portCount: dev.outputChannels)) }
        }

        var result: [String: [SystemNodeSegment]] = [:]
        if !capture.isEmpty  { result["system (capture)"]  = capture  }
        if !playback.isEmpty { result["system (playback)"] = playback }
        return result
    }

    // MARK: - Context menu

    var contextMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let port = ctxPort {
                ctxLabel(port.id)
                ctxDanger(String(localized: "patchbay.ctx.disconnect_port")) {
                    patchbay.disconnectPort(port.id); showCtx = false
                }
                Divider().background(JM.borderFaint).padding(.vertical, 2)
                let nid = String(port.id.split(separator: ":").first ?? "")
                ctxDanger(String(localized: "patchbay.ctx.disconnect_all_inputs")) {
                    patchbay.disconnectAllInputs(of: nid); showCtx = false
                }
                ctxDanger(String(localized: "patchbay.ctx.disconnect_all_outputs")) {
                    patchbay.disconnectAllOutputs(of: nid); showCtx = false
                }
                ctxDanger(String(localized: "patchbay.ctx.disconnect_client")) {
                    patchbay.disconnectAll(of: nid); showCtx = false
                }
            } else if let node = ctxNode {
                // ── Header with badge ────────────────────────────────────────
                ctxNodeHeader(node)
                Divider().background(JM.borderFaint).padding(.vertical, 2)
                // ── Connect All (scoped to the clicked side) ─────────────────
                if let side = ctxNodeSide {
                    connectAllSection(node: node, isOutputSide: side)
                    Divider().background(JM.borderFaint).padding(.vertical, 2)
                }
                // ── Scoped disconnects, greyed out when nothing is connected ──
                let outIds = Set(node.outputs.map { $0.id })
                let inIds  = Set(node.inputs.map  { $0.id })
                let connectedOuts = patchbay.connections.contains { outIds.contains($0.from) }
                let connectedIns  = patchbay.connections.contains { inIds.contains($0.to)   }
                let showOuts = (ctxNodeSide == true  || ctxNodeSide == nil) && !node.outputs.isEmpty
                let showIns  = (ctxNodeSide == false || ctxNodeSide == nil) && !node.inputs.isEmpty
                let hasAny   = connectedOuts || connectedIns

                if showOuts {
                    if connectedOuts {
                        ctxDanger(String(localized: "patchbay.ctx.disconnect_all_outputs")) {
                            patchbay.disconnectAllOutputs(of: node.id); showCtx = false
                        }
                    } else { ctxGrayed(String(localized: "patchbay.ctx.disconnect_all_outputs")) }
                }
                if showIns {
                    if connectedIns {
                        ctxDanger(String(localized: "patchbay.ctx.disconnect_all_inputs")) {
                            patchbay.disconnectAllInputs(of: node.id); showCtx = false
                        }
                    } else { ctxGrayed(String(localized: "patchbay.ctx.disconnect_all_inputs")) }
                }
                if hasAny {
                    ctxDanger(String(localized: "patchbay.ctx.disconnect_all")) {
                        patchbay.disconnectAll(of: node.id); showCtx = false
                    }
                }
            }
        }
        .padding(4)
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: "#232325"))
                .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
        )
        .gradientBorder(cornerRadius: 10)
        .offset(x: ctxScreenPos.x, y: ctxScreenPos.y)
        .zIndex(100)
    }

    @ViewBuilder func ctxNodeHeader(_ node: PatchbayNode) -> some View {
        HStack(spacing: 7) {
            NodeBadgeView(node: node, size: 20)
            Text(node.id)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder func ctxLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.28))
            .padding(.horizontal, 11).padding(.top, 6).padding(.bottom, 2)
    }

    @ViewBuilder func ctxDanger(_ label: String, action: @escaping () -> Void) -> some View {
        CtxButton(label: label, color: JM.accentRed, action: action)
    }

    @ViewBuilder func ctxItem(_ label: String, action: @escaping () -> Void) -> some View {
        CtxButton(label: label, color: .white.opacity(0.85), action: action)
    }

    @ViewBuilder func ctxGrayed(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 5)
    }

    @ViewBuilder func ctxDisabledItem(_ label: String) -> some View {
        Text("\(label) — déjà connecté")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 4)
    }

    @ViewBuilder func miniNodeBadge(_ node: PatchbayNode, size: CGFloat = 18) -> some View {
        NodeBadgeView(node: node, size: size)
    }

    // MARK: - Connect All helpers

    /// Builds the "Connect All To" and "Disconnect From" sections of the context menu
    /// for a given node and side (output or input).
    @ViewBuilder
    func connectAllSection(node: PatchbayNode, isOutputSide: Bool) -> some View {
        let targets   = compatibleTargets(for: node, isOutputSide: isOutputSide)
        let connected = connectedTargets(for: node, isOutputSide: isOutputSide)

        if !targets.isEmpty {
            ctxLabel(String(localized: "patchbay.ctx.section.connect_to"))
            ForEach(targets) { target in
                let outNode    = isOutputSide ? node : target
                let inNode     = isOutputSide ? target : node
                let alreadyAll = patchbay.buildConnectAllRequest(outNode: outNode, inNode: inNode)
                    .map { $0.isFullyAlreadyConnected } ?? true
                if alreadyAll {
                    CtxNodeButton(node: target, color: .white.opacity(0.22), disabled: true) { }
                } else {
                    CtxNodeButton(node: target, color: .white.opacity(0.85), disabled: false) {
                        handleConnectAll(source: node, target: target, isOutputSide: isOutputSide)
                    }
                }
            }
        }

        if !connected.isEmpty {
            Divider().background(JM.borderFaint).padding(.vertical, 2)
            ctxLabel(String(localized: "patchbay.ctx.section.disconnect_from"))
            ForEach(connected) { other in
                CtxNodeButton(node: other, color: JM.accentRed, disabled: false) {
                    let outNode = isOutputSide ? node : other
                    let inNode  = isOutputSide ? other : node
                    patchbay.disconnectAllBetween(outNode: outNode, inNode: inNode)
                    showCtx = false
                }
            }
        }
    }

    /// Returns nodes that share at least one compatible port type with the given side of `node`.
    func compatibleTargets(for node: PatchbayNode, isOutputSide: Bool) -> [PatchbayNode] {
        let sourceTypes = Set(isOutputSide ? node.outputs.map { $0.type }
                                           : node.inputs.map  { $0.type })
        return patchbay.nodes.filter { other in
            guard other.id != node.id else { return false }
            let targetPorts = isOutputSide ? other.inputs : other.outputs
            return !sourceTypes.intersection(Set(targetPorts.map { $0.type })).isEmpty
        }
    }

    /// Returns nodes that are currently connected to the given side of `node`.
    func connectedTargets(for node: PatchbayNode, isOutputSide: Bool) -> [PatchbayNode] {
        if isOutputSide {
            let portIds       = Set(node.outputs.map { $0.id })
            let targetPortIds = Set(patchbay.connections.filter { portIds.contains($0.from) }.map { $0.to })
            return patchbay.nodes.filter { $0.id != node.id
                && $0.inputs.contains { targetPortIds.contains($0.id) } }
        } else {
            let portIds    = Set(node.inputs.map { $0.id })
            let srcPortIds = Set(patchbay.connections.filter { portIds.contains($0.to) }.map { $0.from })
            return patchbay.nodes.filter { $0.id != node.id
                && $0.outputs.contains { srcPortIds.contains($0.id) } }
        }
    }

    /// Builds a connect-all request between `source` and `target` and presents the confirmation modal.
    func handleConnectAll(source: PatchbayNode, target: PatchbayNode, isOutputSide: Bool) {
        let outNode = isOutputSide ? source : target
        let inNode  = isOutputSide ? target : source
        guard let request = patchbay.buildConnectAllRequest(outNode: outNode, inNode: inNode) else { return }
        showCtx = false
        connectAllRequest = request   // always show the modal — explicit confirmation required
    }

    // MARK: - Studio sheet

}

// MARK: - Node badge SwiftUI (shared between context menus and modals)

/// Rounded badge showing a client abbreviation or a system SF Symbol icon.
/// Used in the context menu header and in the node-inspect modal.
struct NodeBadgeView: View {
    let node: PatchbayNode
    var size: CGFloat = 20

    private var isSystem:  Bool { node.id.hasPrefix("system") }
    private var isCapture: Bool { node.id.hasSuffix("(capture)") }

    var body: some View {
        let r = size * 0.28
        ZStack {
            RoundedRectangle(cornerRadius: r)
                .fill(bgColor)
                .frame(width: size, height: size)
            if isSystem {
                Image(systemName: isCapture ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(iconColor)
            } else {
                Text(BadgeUtils.abbrev(node.id))
                    .font(.system(size: size * 0.50, weight: .bold))
                    .foregroundStyle(.black.opacity(0.55))
            }
        }
    }

    private var bgColor: Color {
        if isSystem {
            return isCapture
                ? Color(hue: 0.524, saturation: 0.70, brightness: 0.78)
                : Color(hue: 0.78,  saturation: 0.50, brightness: 0.82)
        }
        let abbr = BadgeUtils.abbrev(node.id)
        return BadgeUtils.color(abbr, fullName: node.id)
    }

    private var iconColor: Color {
        isCapture
            ? Color(hue: 0.524, saturation: 0.65, brightness: 0.22)
            : Color(hue: 0.78,  saturation: 0.65, brightness: 0.22)
    }
}

// MARK: - Context menu buttons with hover

/// Plain context menu item with a hover highlight.
private struct CtxButton: View {
    let label:  String
    let color:  Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovered ? Color.white.opacity(0.07) : Color.clear))
        .padding(.horizontal, 4)
        .onHover { hovered = $0 }
    }
}

/// Context menu item showing a node badge and label, with optional disabled state.
private struct CtxNodeButton: View {
    let node:     PatchbayNode
    let color:    Color
    let disabled: Bool
    let action:   () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            HStack(spacing: 7) {
                NodeBadgeView(node: node, size: 17)
                    .opacity(disabled ? 0.4 : 1)
                Text(node.id)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovered && !disabled ? Color.white.opacity(0.07) : Color.clear))
        .padding(.horizontal, 4)
        .onHover { if !disabled { hovered = $0 } }
    }
}

// MARK: - PatchbayCanvasView (NSViewRepresentable)

/// `NSViewRepresentable` bridge that hosts `PatchbayCanvasNSView` inside SwiftUI.
/// Passes nodes, connections, viewport state, and context-menu bindings to the underlying AppKit view.
struct PatchbayCanvasView: NSViewRepresentable {
    let nodes:           [PatchbayNode]
    let connections:     [JackConnection]
    let selectedNodeIds: Set<String>
    @Binding var vpOffset:         CGSize
    @Binding var vpScale:          CGFloat
    @Binding var canvasSize:       CGSize
    @Binding var showCtx:          Bool
    @Binding var ctxPort:          JackPort?
    @Binding var ctxNode:          PatchbayNode?
    @Binding var ctxNodeSide:      Bool?
    @Binding var ctxCanvasPos:     CGPoint
    @Binding var tappedBadgeNode:  PatchbayNode?
    let patchbay:       PatchbayManager
    let systemNodeInfo: [String: [SystemNodeSegment]]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PatchbayCanvasNSView {
        let v = PatchbayCanvasNSView()
        v.coordinator      = context.coordinator
        v.nodes            = nodes
        v.connections      = connections
        v.selectedNodeIds  = selectedNodeIds
        v.patchbay         = patchbay
        v.vpOffset         = vpOffset
        v.vpScale          = vpScale
        v.systemNodeInfo   = systemNodeInfo
        // No timer — redraws only on Jack callbacks or user interaction
        return v
    }

    func updateNSView(_ nsView: PatchbayCanvasNSView, context: Context) {
        // Compare before assigning to avoid unnecessary redraws
        let nodesChanged  = nsView.nodes.map(\.id) != nodes.map(\.id) ||
                            nsView.nodes.map(\.position) != nodes.map(\.position) ||
                            nsView.nodes.map(\.isCollapsed) != nodes.map(\.isCollapsed)
        let connsChanged  = nsView.connections != connections
        let vpChanged     = nsView.vpOffset != vpOffset || nsView.vpScale != vpScale
        let selChanged    = nsView.selectedNodeIds != selectedNodeIds
        let sysInfoChanged = nsView.systemNodeInfo != systemNodeInfo

        if nodesChanged || connsChanged || vpChanged || selChanged || sysInfoChanged {
            nsView.nodes           = nodes
            nsView.connections     = connections
            nsView.selectedNodeIds = selectedNodeIds
            nsView.patchbay        = patchbay
            nsView.vpOffset        = vpOffset
            nsView.vpScale         = vpScale
            nsView.systemNodeInfo  = systemNodeInfo
            // Deferred by one cycle to avoid recursive layout
            // (updateNSView runs during SwiftUI's layout pass;
            //  a synchronous needsDisplay would trigger a recursive layoutSubtreeIfNeeded)
            DispatchQueue.main.async { nsView.needsDisplay = true }
        }
    }

    /// Holds a back-reference to the `PatchbayCanvasView` so the `NSView` can update SwiftUI bindings.
    class Coordinator {
        var parent: PatchbayCanvasView
        init(_ p: PatchbayCanvasView) { parent = p }
    }
}

// MARK: - PatchbayCanvasNSView

/// AppKit canvas that draws the Jack patchbay using Core Graphics.
/// Zero timers: redraws only on data changes (nodes, connections, viewport) or mouse interaction.
/// Handles pan, pinch-zoom, node drag, group drag, wire drag, collapse toggle, and right-click context.
class PatchbayCanvasNSView: NSView {
    var coordinator:     PatchbayCanvasView.Coordinator?
    var patchbay:        PatchbayManager?
    var nodes:           [PatchbayNode]   = []
    var connections:     [JackConnection] = []
    var selectedNodeIds: Set<String>      = []
    var vpOffset:    CGSize  = .zero
    var vpScale:     CGFloat = 1.0
    var systemNodeInfo: [String: [SystemNodeSegment]] = [:]

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { patchbay?.clearSelection(); return } // Escape
        if event.modifierFlags.contains(.command),
           event.characters?.lowercased() == "a" {
            patchbay?.selectAll(); return                              // CMD+A
        }
        super.keyDown(with: event)
    }

    private let nodeW:     CGFloat = 200
    private let headerH:   CGFloat = 46
    private let rowH:      CGFloat = 21
    private let snapR:     CGFloat = 12
    private let typeOrder: [JackPortType] = [.audio, .midi, .cv, .other]

    private var draggingNodeId:      String?   = nil
    private var dragNodeOffset:      CGSize    = .zero
    private var isGroupDragging:     Bool             = false
    private var groupDragOffsets:    [String: CGSize] = [:]  // nodeId → cursor offset in canvas space
    private var wireSrcPort:         JackPort? = nil
    private var wireSrcPos:          NSPoint   = .zero
    private var wireCurrent:         NSPoint   = .zero
    private var isDraggingWire:      Bool      = false
    private var hoveredPort:         JackPort? = nil
    private var hoveredCollapseNode: String?   = nil  // id of the node whose collapse arrow is hovered
    private var hoveredBadgeNode:    String?   = nil  // id of the node whose badge is hovered
    private var isShowingBadgeCursor: Bool     = false // whether pointingHand cursor is currently pushed

    private struct HoveredPill: Equatable {
        let nodeId: String; let isOutput: Bool; let portType: JackPortType
    }
    private var hoveredPill: HoveredPill? = nil

    // ── Haptic state ─────────────────────────────────────────────────────────
    private var isNodeAtEdge:        Bool      = false  // node clamped at a viewport edge
    private var isDraggingOverlap:   Bool      = false  // dragged node overlaps another node
    private var lastHoveredPortId:   String?   = nil    // last port hovered during wire drag

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Propagates the view size to SwiftUI here (not in `updateNSView`) to avoid recursive SwiftUI/AppKit layout.
    override func layout() {
        super.layout()
        let sz = bounds.size
        guard sz.width > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator?.parent.canvasSize = self.bounds.size
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let pt        = convert(event.locationInWindow, from: nil)
        let port      = hitTestPort(at: pt)
        let colNode   = hitTestCollapseArrow(at: pt)
        let pill      = hitTestPill(at: pt)
        let badgeNode = hitTestBadgeNode(at: pt)?.id
        if port?.id != hoveredPort?.id || colNode != hoveredCollapseNode
            || pill != hoveredPill || badgeNode != hoveredBadgeNode {
            hoveredPort         = port
            hoveredCollapseNode = colNode
            hoveredPill         = pill
            hoveredBadgeNode    = badgeNode
            needsDisplay        = true
            // Push/pop pointing-hand cursor when entering or leaving a badge
            if badgeNode != nil && !isShowingBadgeCursor {
                NSCursor.pointingHand.push()
                isShowingBadgeCursor = true
            } else if badgeNode == nil && isShowingBadgeCursor {
                NSCursor.pop()
                isShowingBadgeCursor = false
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredPort != nil || hoveredCollapseNode != nil
            || hoveredPill != nil || hoveredBadgeNode != nil {
            hoveredPort         = nil
            hoveredCollapseNode = nil
            hoveredPill         = nil
            hoveredBadgeNode    = nil
            needsDisplay        = true
        }
        if isShowingBadgeCursor {
            NSCursor.pop()
            isShowingBadgeCursor = false
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        // Background
        NSColor(calibratedRed: 0.091, green: 0.091, blue: 0.091, alpha: 1).setFill()
        bounds.fill()

        // Grid
        drawGrid(ctx: ctx)

        // Connected cables (static — no animation)
        let connectedPorts = Set(connections.flatMap { [$0.from, $0.to] })
        for conn in connections {
            guard let p1 = portCenter(conn.from, dir: .output),
                  let p2 = portCenter(conn.to,   dir: .input) else { continue }
            let fromNode = nodes.first { $0.outputs.contains(where: { $0.id == conn.from }) }
            let toNode   = nodes.first { $0.inputs.contains(where:  { $0.id == conn.to   }) }
            let port     = fromNode?.outputs.first { $0.id == conn.from }
            let col      = port?.type.patchbayColor ?? Color(hex: "#4ade80")
            drawCable(ctx: ctx, p1: p1, p2: p2, color: col, isPreview: false,
                      p1IsMeta: fromNode?.isCollapsed ?? false,
                      p2IsMeta: toNode?.isCollapsed   ?? false)
        }

        // Wire preview during drag — p1 recomputed each frame from portCenter()
        // so it tracks pan/zoom without detaching from the source port
        if isDraggingWire, let srcPort = wireSrcPort,
           let srcPos = portCenter(srcPort.id, dir: srcPort.direction) {
            let col = srcPort.type.patchbayColor
            drawCable(ctx: ctx,
                      p1: srcPos,
                      p2: CGPoint(x: wireCurrent.x, y: wireCurrent.y),
                      color: col, isPreview: true,
                      p1IsOutput: srcPort.direction == .output)
        }

        // Nodes
        for node in nodes {
            drawNode(ctx: ctx, node: node, connectedPorts: connectedPorts)
        }

        // ── Connection indicators for collapsed nodes ─────────────────────
        // Visual sequence per port type:
        //   OUTPUT : (node →) pill → trapezoid (transparent→colour) → cables
        //   INPUT  : cables → trapezoid (colour→transparent) → pill (→ node)
        // The n/m label floats in the transparent region of the trapezoid.
        for node in nodes where node.isCollapsed {
            let nx = node.position.x * vpScale + vpOffset.width
            let ny = node.position.y * vpScale + vpOffset.height
            let nw = nodeW * vpScale
            let hh = headerH * vpScale

            // Shared dimensions (consistent with bundleOffsetX and portCenter)
            let pillW   = max(3, 3.5 * vpScale)
            let pillGap = max(2, 2   * vpScale)
            let strokeW = max(1, 1.5 * vpScale)

            for isOutput in [false, true] {
                let allPorts  = isOutput ? node.outputs : node.inputs
                guard !allPorts.isEmpty else { continue }
                let connPorts = allPorts.filter { p in
                    isOutput ? connections.contains { $0.from == p.id }
                             : connections.contains { $0.to   == p.id }
                }

                // ── Unconnected pill: node has no cable on this side ─────────
                if connPorts.isEmpty {
                    let types  = typeOrder.filter { t in allPorts.contains { $0.type == t } }
                    let pillH  = (hh * 0.75 - pillGap * CGFloat(max(0, types.count - 1)))
                               / CGFloat(max(1, types.count))
                    let stackH = pillH * CGFloat(types.count)
                               + pillGap * CGFloat(max(0, types.count - 1))
                    var pillY  = ny + (hh - stackH) / 2
                    for portType in types {
                        let isHov   = hoveredPill == HoveredPill(nodeId: node.id, isOutput: isOutput, portType: portType)
                        let pw      = isHov ? pillW * 1.6 : pillW
                        let pillX   = isOutput ? nx + nw - pw / 2 : nx - pw / 2
                        let pillRect = CGRect(x: pillX, y: pillY, width: pw, height: pillH)
                        let pillPath = CGPath(roundedRect: pillRect,
                                             cornerWidth: pw / 2, cornerHeight: pw / 2,
                                             transform: nil)
                        let alpha    = isHov ? 0.75 : 0.35
                        let dimColor = nsColor(portType.patchbayColor, alpha: alpha).cgColor
                        ctx.saveGState()
                        if isHov {
                            ctx.setShadow(offset: .zero, blur: max(3, 6 * vpScale), color: dimColor)
                        }
                        ctx.addPath(pillPath)
                        ctx.setStrokeColor(dimColor)
                        ctx.setLineWidth(strokeW)
                        ctx.strokePath()
                        ctx.restoreGState()
                        pillY += pillH + pillGap
                    }
                    continue
                }

                let byType = Dictionary(grouping: connPorts, by: \.type)
                let types  = typeOrder.filter { byType[$0] != nil }
                let pillH  = (hh * 0.75 - pillGap * CGFloat(max(0, types.count - 1)))
                           / CGFloat(max(1, types.count))
                let stackH = pillH * CGFloat(types.count)
                           + pillGap * CGFloat(max(0, types.count - 1))

                // Pill centred vertically, straddling the node edge (pX computed per portType for hover)
                var pillY  = ny + (hh - stackH) / 2

                for portType in types {
                    guard let cy = pillCenterY(for: portType, types: types, ny: ny, hh: hh) else {
                        pillY += pillH + pillGap; continue
                    }

                    let isHov  = hoveredPill == HoveredPill(nodeId: node.id, isOutput: isOutput, portType: portType)
                    let pw     = isHov ? pillW * 1.6 : pillW
                    let pX     = isOutput ? nx + nw - pw / 2 : nx - pw / 2
                    let typeNS = nsColor(portType.patchbayColor, alpha: 0.90)
                    let typeCG = typeNS.cgColor

                    // ── Pill (stroke outline + glow) ─────────────────────
                    let pillRect = CGRect(x: pX, y: pillY, width: pw, height: pillH)
                    let pillPath = CGPath(roundedRect: pillRect,
                                         cornerWidth: pw / 2, cornerHeight: pw / 2,
                                         transform: nil)
                    ctx.saveGState()
                    ctx.setShadow(offset: .zero,
                                  blur: isHov ? max(8, 16 * vpScale) : max(4, 8 * vpScale),
                                  color: typeCG)
                    ctx.addPath(pillPath)
                    ctx.setStrokeColor(typeCG)
                    ctx.setLineWidth(strokeW)
                    ctx.strokePath()
                    ctx.restoreGState()

                    // ── Compute label n/m first (needed for wideH) ───────────────
                    let connOfType  = byType[portType]!.count
                    let totalOfType = allPorts.filter { $0.type == portType }.count
                    let labelStr    = "\(connOfType)/\(totalOfType)"
                    let fontSize    = max(9, 10 * vpScale)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font:            NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
                        .foregroundColor: typeNS.withAlphaComponent(0.85)
                    ]
                    let attrStr = NSAttributedString(string: labelStr, attributes: attrs)
                    let strSize = attrStr.size()

                    // ── Taper geometry ───────────────────────────────────────────
                    // pillEdgeX : outer edge of the pill (opposite side from the node)
                    // bundleX   : cable attachment point (= portCenter)
                    // taperLen  = bundleOffsetX - pillHalf (consistent with portCenter)
                    let pillEdgeX = isOutput ? nx + nw + pillW / 2 : nx - pillW / 2
                    let bundleX   = isOutput ? pillEdgeX + taperLen : pillEdgeX - taperLen
                    let wideH     = max(strSize.height * 3.0, max(18, 22 * vpScale))
                    let narrowH   = max(1.4, 1.8 * vpScale)

                    // ── Static stub beneath the trapezoid ───────────────────────
                    // Runs from the narrow side (bundleX) inward toward the label.
                    // Drawn first (below the gradient): the cable/trapezoid junction is
                    // covered by the opaque region; the stub is visible in the transparent zone.
                    // Stops just before the label edge (3 px gap).
                    let labelCenterX = isOutput ? pillEdgeX + taperLen * 0.38
                                                : pillEdgeX - taperLen * 0.38
                    let labelGap     = max(2, 3 * vpScale)
                    let stubEndX     = isOutput ? labelCenterX + strSize.width / 2 + labelGap
                                                : labelCenterX - strSize.width / 2 - labelGap
                    let stubPath = CGMutablePath()
                    stubPath.move(to:    CGPoint(x: bundleX,  y: cy))
                    stubPath.addLine(to: CGPoint(x: stubEndX, y: cy))
                    ctx.saveGState()
                    ctx.addPath(stubPath)
                    ctx.setStrokeColor(typeNS.withAlphaComponent(0.70).cgColor)
                    ctx.setLineWidth(max(1.4, 1.8 * vpScale))
                    ctx.setLineCap(.round)
                    ctx.strokePath()
                    ctx.restoreGState()

                    // Trapezoid: wide (wideH) on the pill side, narrow (narrowH) on the cable side
                    let trap = CGMutablePath()
                    trap.move(to:    CGPoint(x: pillEdgeX, y: cy - wideH   / 2))
                    trap.addLine(to: CGPoint(x: bundleX,   y: cy - narrowH / 2))
                    trap.addLine(to: CGPoint(x: bundleX,   y: cy + narrowH / 2))
                    trap.addLine(to: CGPoint(x: pillEdgeX, y: cy + wideH   / 2))
                    trap.closeSubpath()

                    // Gradient: transparent at the pill end → opaque port-type colour at the bundle end
                    if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                       let ns   = typeNS.usingColorSpace(.sRGB) {
                        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
                        let clearCol  = CGColor(colorSpace: srgb, components: [r, g, b, 0.00])!
                        let opaqueCol = CGColor(colorSpace: srgb, components: [r, g, b, 0.85])!
                        let locs: [CGFloat] = [0, 1]
                        if let grad = CGGradient(colorsSpace: srgb,
                                                 colors: [clearCol, opaqueCol] as CFArray,
                                                 locations: locs) {
                            // Fill the trapezoid
                            ctx.saveGState()
                            ctx.addPath(trap)
                            ctx.clip()
                            ctx.drawLinearGradient(grad,
                                start: CGPoint(x: pillEdgeX, y: cy),
                                end:   CGPoint(x: bundleX,   y: cy),
                                options: [])
                            ctx.restoreGState()

                            // Top and bottom trapezoid edges (port-type colour, alpha ~0.20)
                            let edgeCol  = CGColor(colorSpace: srgb, components: [r, g, b, 0.22])!
                            let edgePath = CGMutablePath()
                            edgePath.move(to:    CGPoint(x: pillEdgeX, y: cy - wideH   / 2))
                            edgePath.addLine(to: CGPoint(x: bundleX,   y: cy - narrowH / 2))
                            edgePath.move(to:    CGPoint(x: pillEdgeX, y: cy + wideH   / 2))
                            edgePath.addLine(to: CGPoint(x: bundleX,   y: cy + narrowH / 2))
                            ctx.saveGState()
                            ctx.addPath(edgePath)
                            ctx.setStrokeColor(edgeCol)
                            ctx.setLineWidth(max(0.5, 0.7 * vpScale))
                            ctx.strokePath()
                            ctx.restoreGState()
                        }
                    }

                    // ── n/m label — floats in the transparent region (pill side) ──
                    attrStr.draw(at: CGPoint(x: labelCenterX - strSize.width  / 2,
                                            y: cy            - strSize.height / 2))

                    pillY += pillH + pillGap
                }
            }
        }
    }

    private func drawGrid(ctx: CGContext) {
        let gs = 22.0 * vpScale
        let ox = vpOffset.width.truncatingRemainder(dividingBy: gs)
        let oy = vpOffset.height.truncatingRemainder(dividingBy: gs)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.150))
        var x = ox; while x < bounds.width {
            var y = oy; while y < bounds.height {
                ctx.fillEllipse(in: CGRect(x: x-1, y: y-1, width: 2, height: 2))
                y += gs }
            x += gs }
    }

    private func drawCable(ctx: CGContext, p1: CGPoint, p2: CGPoint,
                            color: Color, isPreview: Bool,
                            p1IsOutput: Bool = true,
                            p1IsMeta: Bool = false, p2IsMeta: Bool = false) {
        // Base dx; capped at taperLen on the meta-port side so the cable arrives
        // horizontally and connects cleanly to the narrow end of the trapezoid.
        let rawDx = max(60, abs(p2.x - p1.x) * 0.48)
        let dx1: CGFloat = p1IsMeta ? min(rawDx, taperLen) : rawDx
        let dx2: CGFloat = p2IsMeta ? min(rawDx, taperLen) : rawDx
        let sgn: CGFloat = p1IsOutput ? 1 : -1
        let c1 = CGPoint(x: p1.x + sgn * dx1, y: p1.y)
        let c2 = CGPoint(x: p2.x - sgn * dx2, y: p2.y)
        let path = CGMutablePath()
        path.move(to: p1)
        path.addCurve(to: p2, control1: c1, control2: c2)

        // Glow pass
        ctx.addPath(path)
        ctx.setStrokeColor(nsColor(color, alpha: 0.25).cgColor)
        ctx.setLineWidth(4); ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.strokePath()

        // Main stroke
        ctx.addPath(path)
        if isPreview {
            ctx.setStrokeColor(nsColor(color, alpha: 0.9).cgColor)
            ctx.setLineWidth(2.2)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
        } else {
            ctx.setStrokeColor(nsColor(color, alpha: 0.85).cgColor)
            ctx.setLineWidth(1.8)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Note: the pill trapezoid handles the visual transition on the meta-port side.
        // No colour override here — the cable terminates cleanly at bundleX.
    }



    private func drawNode(ctx: CGContext, node: PatchbayNode,
                           connectedPorts: Set<String>) {
        let nx   = node.position.x * vpScale + vpOffset.width
        let ny   = node.position.y * vpScale + vpOffset.height
        let nw   = nodeW * vpScale
        let hh   = headerH * vpScale
        let rows = max(node.inputCount, node.outputCount)
        let bodyH = node.isCollapsed ? 0.0 : CGFloat(rows) * rowH * vpScale + 6 * vpScale
        let totalH = hh + bodyH + 1

        // Background — dark gradient, Linear-app style
        let nodeRect = CGRect(x: nx, y: ny, width: nw, height: totalH)
        let cr = 12 * vpScale
        let nodePath = CGPath(roundedRect: nodeRect, cornerWidth: cr, cornerHeight: cr, transform: nil)
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            // Vertical gradient fill: slightly lighter at the top
            ctx.saveGState()
            ctx.addPath(nodePath); ctx.clip()
            let nodeTop = CGColor(colorSpace: srgb, components: [0.07, 0.07, 0.08, 1])!
            let nodeBot = CGColor(colorSpace: srgb, components: [0.10, 0.10, 0.11, 1])!
            if let grad = CGGradient(colorsSpace: srgb, colors: [nodeTop, nodeBot] as CFArray, locations: nil) {
                ctx.drawLinearGradient(grad,
                    start: CGPoint(x: nx + nw / 2, y: ny),
                    end:   CGPoint(x: nx + nw / 2, y: ny + totalH), options: [])
            }
            ctx.restoreGState()
            // Diagonal gradient border: topLeading → bottomTrailing (same logic as gradientBorder SwiftUI extension)
            let brdDark = CGColor(colorSpace: srgb, components: [1, 1, 1, 0.08])!
            let brdPeak = CGColor(colorSpace: srgb, components: [1, 1, 1, 0.28])!
            if let brdGrad = CGGradient(colorsSpace: srgb,
                                        colors: [brdDark, brdPeak, brdDark] as CFArray,
                                        locations: [0, 0.5, 1.0]) {
                ctx.saveGState()
                ctx.addPath(nodePath)
                ctx.setLineWidth(1.0)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                ctx.drawLinearGradient(brdGrad,
                    start: CGPoint(x: nx,      y: ny),
                    end:   CGPoint(x: nx + nw, y: ny + totalH), options: [])
                ctx.restoreGState()
            }
        } else {
            ctx.addPath(nodePath)
            ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)); ctx.fillPath()
            ctx.addPath(nodePath)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
            ctx.setLineWidth(1); ctx.strokePath()
        }

        // Selection outline — blue accent border drawn outside the node rect
        if selectedNodeIds.contains(node.id) {
            ctx.saveGState()
            let selInset = -max(1.5, 2.0 * vpScale)
            let selRect  = nodeRect.insetBy(dx: selInset, dy: selInset)
            let selCR    = cr - selInset
            let selPath  = CGPath(roundedRect: selRect,
                                  cornerWidth: selCR, cornerHeight: selCR, transform: nil)
            ctx.addPath(selPath)
            ctx.setStrokeColor(CGColor(red: 0.25, green: 0.60, blue: 1.0, alpha: 0.88))
            ctx.setLineWidth(max(1.5, 2.0 * vpScale))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Header/body separator — edge-to-centre gradient (modern rimlight style)
        if !node.isCollapsed {
            let sepY    = ny + hh
            let sepH    = max(1.0, vpScale)
            let sepRect = CGRect(x: nx, y: sepY - sepH / 2, width: nw, height: sepH)
            if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
                ctx.saveGState()
                ctx.clip(to: sepRect)
                let edge   = CGColor(colorSpace: srgb, components: [1, 1, 1, 0.00])!
                let center = CGColor(colorSpace: srgb, components: [1, 1, 1, 0.18])!
                if let grad = CGGradient(colorsSpace: srgb,
                                         colors: [edge, center, edge] as CFArray,
                                         locations: [0, 0.5, 1.0]) {
                    ctx.drawLinearGradient(grad,
                        start: CGPoint(x: nx,      y: sepY),
                        end:   CGPoint(x: nx + nw, y: sepY), options: [])
                }
                ctx.restoreGState()
            }
        }

        // Coloured badge
        let abbr          = BadgeUtils.abbrev(node.id)
        let isSystemNode  = node.id.hasPrefix("system")
        let isCaptureNode = node.id.hasSuffix("(capture)")
        let isBadgeHovered = hoveredBadgeNode == node.id
        let badgeSzBase = max(18.0, 26.0 * vpScale)
        // Scale up 15% on hover, keeping the badge centred on its resting position
        let badgeScale  = isBadgeHovered ? 1.15 : 1.0
        let badgeSz     = badgeSzBase * badgeScale
        let badgeXBase  = nx + 8 * vpScale
        let badgeYBase  = ny + (hh - badgeSzBase) / 2
        let badgeX      = badgeXBase - (badgeSz - badgeSzBase) / 2
        let badgeY      = badgeYBase - (badgeSz - badgeSzBase) / 2
        let badgeRect  = CGRect(x: badgeX, y: badgeY, width: badgeSz, height: badgeSz)
        let cornerR    = badgeSz * 0.28
        let badgePath  = CGPath(roundedRect: badgeRect,
                                cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)

        // Base colour: fixed for system nodes, deterministic hash for app nodes
        let baseColor: CGColor = isSystemNode
            ? (isCaptureNode
                ? NSColor(hue: 0.524, saturation: 0.70, brightness: 0.78, alpha: 1).cgColor  // cyan
                : NSColor(hue: 0.78,  saturation: 0.50, brightness: 0.82, alpha: 1).cgColor)  // violet
            : BadgeUtils.nsColor(abbr, fullName: node.id).cgColor

        // Glow on hover: draw the badge shape as a shadow behind the fill
        if isBadgeHovered {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10, color: baseColor.copy(alpha: 0.65))
            ctx.setFillColor(baseColor)
            ctx.addPath(badgePath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Gradient fill for the badge
        ctx.saveGState()
        ctx.addPath(badgePath); ctx.clip()
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let c = baseColor.converted(to: srgb, intent: .defaultIntent, options: nil),
           let comps = c.components, comps.count >= 3 {
            let r = comps[0], g = comps[1], b = comps[2]
            let top = CGColor(colorSpace: srgb, components: [min(r+0.18,1), min(g+0.18,1), min(b+0.18,1), 1])!
            let bot = CGColor(colorSpace: srgb, components: [max(r-0.08,0), max(g-0.08,0), max(b-0.08,0), 1])!
            if let grad = CGGradient(colorsSpace: srgb, colors: [top, bot] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(grad,
                    start: CGPoint(x: badgeX + badgeSz/2, y: badgeY),
                    end:   CGPoint(x: badgeX + badgeSz/2, y: badgeY + badgeSz),
                    options: [])
            }
        } else {
            ctx.setFillColor(baseColor); ctx.fillPath()
        }
        ctx.restoreGState()

        // Badge content: SF Symbol icon for system nodes, letter abbreviation for app nodes
        if isSystemNode {
            let symName  = isCaptureNode ? "mic.fill" : "speaker.wave.2.fill"
            let symHue: CGFloat = isCaptureNode ? 0.524 : 0.78
            let symColor = NSColor(hue: symHue, saturation: 0.65, brightness: 0.22, alpha: 1)
            let symFS    = max(8.0, 11.0 * vpScale)
            if let img = NSImage(systemSymbolName: symName, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: symFS, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [symColor]))
                if let tinted = img.withSymbolConfiguration(cfg),
                   let cgImg  = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let isz  = tinted.size
                    let drawRect = CGRect(x: badgeX + (badgeSz - isz.width) / 2,
                                         y: badgeY + (badgeSz - isz.height) / 2,
                                         width: isz.width, height: isz.height)
                    // Context is flipped (y-down); flip it back before drawing the CGImage
                    ctx.saveGState()
                    ctx.translateBy(x: drawRect.minX, y: drawRect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(cgImg, in: CGRect(origin: .zero, size: drawRect.size))
                    ctx.restoreGState()
                }
            }
        } else {
            let badgeFS   = max(9.5, 13.0 * vpScale)
            var textColor = NSColor(white: 0.15, alpha: 1)
            if let ns = NSColor(cgColor: baseColor) {
                var h: CGFloat = 0, s: CGFloat = 0, bv: CGFloat = 0, a: CGFloat = 0
                ns.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &bv, alpha: &a)
                textColor = NSColor(hue: h, saturation: 0.65, brightness: 0.22, alpha: 1)
            }
            let badgeStr = NSAttributedString(string: abbr, attributes: [
                .font: NSFont.boldSystemFont(ofSize: badgeFS),
                .foregroundColor: textColor
            ])
            let bsz = badgeStr.size()
            badgeStr.draw(at: CGPoint(x: badgeX + (badgeSz - bsz.width) / 2,
                                      y: badgeY + (badgeSz - bsz.height) / 2))
        }

        // Client name + in/out subtitle
        let textX      = badgeX + badgeSz + 7 * vpScale
        let fs         = max(9.0, 10.5 * vpScale)
        let subFS      = max(7.5, 8.5 * vpScale)
        let totalTextH = fs * 1.25 + 2 * vpScale + subFS * 1.25
        let textStartY = ny + (hh - totalTextH) / 2

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fs, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        NSAttributedString(string: node.id, attributes: nameAttrs)
            .draw(at: CGPoint(x: textX, y: textStartY))

        let subText  = "\(node.inputs.count)in · \(node.outputs.count)out"
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: subFS, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35)
        ]
        NSAttributedString(string: subText, attributes: subAttrs)
            .draw(at: CGPoint(x: textX, y: textStartY + fs * 1.25 + 2 * vpScale))

        // Collapse arrow — hidden if the node cannot be collapsed
        if canCollapse(node) {
            let isArrowHovered = hoveredCollapseNode == node.id
            // Hovered: slight enlargement + increased opacity (no background fill)
            let arrowFS   = max(7, (isArrowHovered ? 10.5 : 8.0) * vpScale)
            let colChar   = node.isCollapsed ? "▶" : "▼"
            let colAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: arrowFS, weight: isArrowHovered ? .semibold : .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(isArrowHovered ? 0.90 : 0.35)
            ]
            let colStr = NSAttributedString(string: colChar, attributes: colAttrs)
            let strW = colStr.size().width
            colStr.draw(at: CGPoint(x: nx + nw - 13 * vpScale - strW / 2,
                                    y: ny + (hh - arrowFS * 1.2) / 2))
        }

        // Port rows
        guard !node.isCollapsed else { return }
        for i in 0..<rows {
            let rowY = ny + hh + 3 * vpScale + CGFloat(i) * rowH * vpScale
            let midY = rowY + rowH * vpScale / 2

            // Vertical centre divider
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.05))
            ctx.fill(CGRect(x: nx + nw / 2 - 0.5, y: rowY, width: 1, height: rowH * vpScale))

            let labelFS   = max(8.0, 9.0 * vpScale)
            let labelFont = NSFont.systemFont(ofSize: labelFS)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.42)
            ]
            // draw(at:) places the top-left of the text bounding box at that point.
            // To optically centre lowercase letters (xHeight) on midY:
            //   top = midY - ascender + xHeight/2
            let labelY = midY - labelFont.ascender + labelFont.xHeight / 2

            if i < node.inputs.count {
                let port     = node.inputs[i]
                let isConn   = connectedPorts.contains(port.id)
                let isHover  = hoveredPort?.id == port.id
                let col      = port.type.patchbayColor
                drawGem(ctx: ctx, at: CGPoint(x: nx - 1, y: midY), color: col,
                        connected: isConn, hovered: isHover)
                let label = NSAttributedString(string: port.portName, attributes: labelAttrs)
                label.draw(at: CGPoint(x: nx + 15 * vpScale, y: labelY))
            }

            if i < node.outputs.count {
                let port     = node.outputs[i]
                let isConn   = connectedPorts.contains(port.id)
                let isHover  = hoveredPort?.id == port.id
                let col      = port.type.patchbayColor
                drawGem(ctx: ctx, at: CGPoint(x: nx + nw + 1, y: midY), color: col,
                        connected: isConn, hovered: isHover)
                let label = NSAttributedString(string: port.portName, attributes: labelAttrs)
                let labelW = label.size().width
                label.draw(at: CGPoint(x: nx + nw - labelW - 15 * vpScale, y: labelY))
            }
        }

        // System device labels — drawn in the free zone of system cards
        // Pass the actual rendered port count so labels never overflow the card height
        if isSystemNode, let segments = systemNodeInfo[node.id], !segments.isEmpty {
            let renderedPorts = isCaptureNode ? node.outputs.count : node.inputs.count
            drawSystemDeviceLabels(ctx: ctx, nx: nx, ny: ny, nw: nw, hh: hh,
                                   segments: segments, isCaptureCard: isCaptureNode,
                                   renderedPorts: renderedPorts)
        }
    }

    /// Draws device name labels (with mic/speaker icon) in the free zone of a `system` card.
    ///
    /// Free zone:
    /// - `system (capture)` : left half  (`nx` → `nx + nw/2`) — outputs are on the right
    /// - `system (playback)`: right half  (`nx + nw/2` → `nx + nw`) — inputs are on the left
    ///
    /// A vertical bracket bar is drawn flush against the centre divider, spanning the full
    /// height of each segment's ports. This groups ports by hardware device without moving them.
    /// Text is truncated with ellipsis if the available width is too narrow.
    private func drawSystemDeviceLabels(ctx: CGContext,
                                        nx: CGFloat, ny: CGFloat,
                                        nw: CGFloat, hh: CGFloat,
                                        segments: [SystemNodeSegment],
                                        isCaptureCard: Bool,
                                        renderedPorts: Int) {
        // capture card: outputs on right → free zone = left half
        // playback card: inputs on left  → free zone = right half
        let zoneX   = isCaptureCard ? nx : nx + nw / 2
        let zoneW   = nw / 2
        let centerX = nx + nw / 2   // existing centre divider x position
        let bodyTop = ny + hh + 3 * vpScale

        let labelFS   = max(8.0, 9.0 * vpScale)
        let textColor = NSColor.white.withAlphaComponent(0.72)

        // Bracket bar: superimposed on the centre divider
        let barW: CGFloat = max(1.0, 1.0 * vpScale)
        let barX  = centerX - barW / 2

        // Text content area: between zone edge and centre
        let contentPad: CGFloat = max(5.0, 6.0 * vpScale)
        let contentX    = isCaptureCard ? zoneX + contentPad : centerX + barW + contentPad
        let contentMaxX = isCaptureCard ? centerX - contentPad : zoneX + zoneW - contentPad

        ctx.saveGState()

        var portOffset = 0
        var portsRemaining = renderedPorts
        for segment in segments {
            guard portsRemaining > 0 else { break }
            // Clamp segment port count to what's actually rendered
            let visiblePorts = min(segment.portCount, portsRemaining)
            let segTop    = bodyTop + CGFloat(portOffset) * rowH * vpScale
            let segHeight = CGFloat(visiblePorts) * rowH * vpScale
            let segMidY   = segTop + segHeight / 2

            // Bracket bar spanning the segment height minus vertical margins
            // so adjacent bars never touch (preserving visual separation between segments)
            let barVMargin: CGFloat = max(3.0, 4.0 * vpScale)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            ctx.fill(CGRect(x: barX, y: segTop + barVMargin,
                            width: barW, height: segHeight - barVMargin * 2))

            // Device name — right-aligned for capture (text hugs centre bar), left for playback
            // Multi-line word wrap when the segment has ≥ 2 ports (enough vertical room)
            let availableW = contentMaxX - contentX
            if availableW > 4 {
                let multiLine = visiblePorts >= 2
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.alignment    = isCaptureCard ? .right : .left
                paraStyle.lineSpacing  = multiLine ? 1.0 : 0
                paraStyle.lineBreakMode = multiLine ? .byWordWrapping : .byTruncatingTail

                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font:            NSFont.systemFont(ofSize: labelFS, weight: .medium),
                    .foregroundColor: textColor,
                    .paragraphStyle:  paraStyle
                ]

                let maxH = segHeight - barVMargin * 2
                let labelFont = NSFont.systemFont(ofSize: labelFS, weight: .medium)
                let textH: CGFloat
                if multiLine {
                    let bounds = NSAttributedString(string: segment.deviceName, attributes: nameAttrs)
                        .boundingRect(with: CGSize(width: availableW, height: maxH),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
                    textH = min(ceil(bounds.height), maxH)
                } else {
                    // Single line: use xHeight for optical vertical centering (same principle as port labels).
                    // The rect origin is the baseline in CoreGraphics, so we offset by ascender-xHeight
                    // to place the optical centre of lowercase letters at segMidY.
                    textH = ceil(labelFont.ascender - labelFont.descender)
                }

                // draw(in:) also uses top-left origin.
                // Single line: top = segMidY - ascender + xHeight/2
                // Multi-line: top = segMidY - textH/2
                let textOriginY: CGFloat = multiLine
                    ? segMidY - textH / 2
                    : segMidY - labelFont.ascender + labelFont.xHeight / 2
                let textRect = CGRect(x: contentX,
                                     y: textOriginY,
                                     width: availableW,
                                     height: textH)
                (segment.deviceName as NSString).draw(in: textRect, withAttributes: nameAttrs)
            }

            portOffset += visiblePorts
            portsRemaining -= visiblePorts
        }
        ctx.restoreGState()
    }

    private func drawGem(ctx: CGContext, at pt: CGPoint, color: Color,
                          connected: Bool, hovered: Bool = false) {
        let r: CGFloat = hovered ? 7 : (connected ? 5 : 4)
        let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
        ctx.addEllipse(in: rect)
        ctx.setFillColor(nsColor(color, alpha: connected ? 1.0 : 0.5).cgColor)
        ctx.fillPath()
        if hovered {
            ctx.addEllipse(in: rect.insetBy(dx: -3, dy: -3))
            ctx.setStrokeColor(nsColor(color, alpha: 0.4).cgColor)
            ctx.setLineWidth(2); ctx.strokePath()
        }
    }

    // MARK: - Hit testing

    private func portCenter(_ portId: String, dir: JackPortDirection) -> CGPoint? {
        for node in nodes {
            let nx  = node.position.x * vpScale + vpOffset.width
            let ny  = node.position.y * vpScale + vpOffset.height
            let nw  = nodeW * vpScale
            let hh  = headerH * vpScale
            let hcY = ny + hh / 2

            if node.isCollapsed {
                let isOutput = dir == .output
                let allPorts = isOutput ? node.outputs : node.inputs
                guard let port = allPorts.first(where: { $0.id == portId }) else { continue }
                let conns = patchbay?.connections ?? []
                let types = connectedTypes(ports: allPorts, isOutput: isOutput, connections: conns)
                if let cy = pillCenterY(for: port.type, types: types, ny: ny, hh: hh) {
                    // bundleX = narrow end of the trapezoid (narrowH ≈ cable thickness).
                    // The cable/trapezoid junction is hidden under the opaque region of the gradient.
                    let bundleX = isOutput ? nx + nw + bundleOffsetX : nx - bundleOffsetX
                    return CGPoint(x: bundleX, y: cy)
                }
                return CGPoint(x: isOutput ? nx + nw + 6 : nx - 6, y: hcY)
            }

            if dir == .input {
                for (i, port) in node.inputs.enumerated() where port.id == portId {
                    let rowY = ny + hh + 3 * vpScale + CGFloat(i) * rowH * vpScale
                    return CGPoint(x: nx - 1, y: rowY + rowH * vpScale / 2)
                }
            } else {
                for (i, port) in node.outputs.enumerated() where port.id == portId {
                    let rowY = ny + hh + 3 * vpScale + CGFloat(i) * rowH * vpScale
                    return CGPoint(x: nx + nw + 1, y: rowY + rowH * vpScale / 2)
                }
            }
        }
        return nil
    }

    private func hitTestPort(at point: NSPoint) -> JackPort? {
        for node in nodes {
            guard !node.isCollapsed else { continue }
            let nx = node.position.x * vpScale + vpOffset.width
            let ny = node.position.y * vpScale + vpOffset.height
            let nw = nodeW * vpScale
            let hh = headerH * vpScale

            for (i, port) in node.inputs.enumerated() {
                let rowY = ny + hh + 3 * vpScale + CGFloat(i) * rowH * vpScale
                let center = CGPoint(x: nx - 1, y: rowY + rowH * vpScale / 2)
                if hypot(point.x - center.x, point.y - center.y) < snapR * vpScale {
                    return port
                }
            }
            for (i, port) in node.outputs.enumerated() {
                let rowY = ny + hh + 3 * vpScale + CGFloat(i) * rowH * vpScale
                let center = CGPoint(x: nx + nw + 1, y: rowY + rowH * vpScale / 2)
                if hypot(point.x - center.x, point.y - center.y) < snapR * vpScale {
                    return port
                }
            }
        }
        return nil
    }

    private func hitTestBadgeNode(at point: NSPoint) -> PatchbayNode? {
        for node in nodes {
            let nx      = node.position.x * vpScale + vpOffset.width
            let ny      = node.position.y * vpScale + vpOffset.height
            let hh      = headerH * vpScale
            let badgeSz = max(18.0, 26.0 * vpScale)
            let badgeX  = nx + 8 * vpScale
            let badgeY  = ny + (hh - badgeSz) / 2
            let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeSz, height: badgeSz)
            if badgeRect.contains(CGPoint(x: point.x, y: point.y)) { return node }
        }
        return nil
    }

    private func hitTestNode(at point: NSPoint) -> String? {
        for node in nodes {
            let nx    = node.position.x * vpScale + vpOffset.width
            let ny    = node.position.y * vpScale + vpOffset.height
            let nw    = nodeW * vpScale
            let rows  = max(node.inputCount, node.outputCount)
            let bodyH = node.isCollapsed ? 0.0 : CGFloat(rows) * rowH * vpScale + 6 * vpScale
            let rect  = CGRect(x: nx, y: ny, width: nw, height: headerH * vpScale + bodyH)
            if rect.contains(CGPoint(x: point.x, y: point.y)) { return node.id }
        }
        return nil
    }

    /// Returns the node id if the point falls within the collapse-arrow hit zone,
    /// only when the node is collapsable (more than one input or more than one output).
    private func hitTestCollapseArrow(at point: NSPoint) -> String? {
        for node in nodes where canCollapse(node) {
            let nx = node.position.x * vpScale + vpOffset.width
            let ny = node.position.y * vpScale + vpOffset.height
            let nw = nodeW * vpScale
            let hh = headerH * vpScale
            let arrowRect = CGRect(x: nx + nw - 22 * vpScale, y: ny,
                                   width: 22 * vpScale, height: hh)
            if arrowRect.contains(CGPoint(x: point.x, y: point.y)) {
                return node.id
            }
        }
        return nil
    }

    private func hitTestPill(at point: NSPoint) -> HoveredPill? {
        let hitMargin: CGFloat = max(6, 8 * vpScale)
        for node in nodes where node.isCollapsed {
            let nx  = node.position.x * vpScale + vpOffset.width
            let ny  = node.position.y * vpScale + vpOffset.height
            let nw  = nodeW * vpScale
            let hh  = headerH * vpScale
            let pw  = max(3, 3.5 * vpScale)
            let gap = max(2, 2   * vpScale)
            for isOutput in [false, true] {
                let allPorts = isOutput ? node.outputs : node.inputs
                let types    = typeOrder.filter { t in allPorts.contains { $0.type == t } }
                guard !types.isEmpty else { continue }
                let pillH  = (hh * 0.75 - gap * CGFloat(max(0, types.count - 1)))
                           / CGFloat(max(1, types.count))
                let stackH = pillH * CGFloat(types.count) + gap * CGFloat(max(0, types.count - 1))
                let pillX  = isOutput ? nx + nw - pw / 2 : nx - pw / 2
                var pillY  = ny + (hh - stackH) / 2
                for portType in types {
                    let hitRect = CGRect(x: pillX - hitMargin, y: pillY - hitMargin,
                                        width: pw + hitMargin * 2, height: pillH + hitMargin * 2)
                    if hitRect.contains(CGPoint(x: point.x, y: point.y)) {
                        return HoveredPill(nodeId: node.id, isOutput: isOutput, portType: portType)
                    }
                    pillY += pillH + gap
                }
            }
        }
        return nil
    }

    /// Returns true when the node has more than one input or more than one output.
    private func canCollapse(_ node: PatchbayNode) -> Bool {
        node.inputs.count > 1 || node.outputs.count > 1
    }

    private func isInHeader(at point: NSPoint, nodeId: String) -> Bool {
        guard let node = nodes.first(where: { $0.id == nodeId }) else { return false }
        let nx = node.position.x * vpScale + vpOffset.width
        let ny = node.position.y * vpScale + vpOffset.height
        let hdrRect = CGRect(x: nx, y: ny, width: nodeW * vpScale, height: headerH * vpScale)
        return hdrRect.contains(CGPoint(x: point.x, y: point.y))
    }

    // MARK: - Mouse events

    private let panMargin:          CGFloat = 120
    private var isPanningBackground = false
    private var panStartMouse:  NSPoint = .zero
    private var panStartOffset: CGSize  = .zero

    // ── Bundle geometry (collapsed nodes) ────────────────────────────────────
    /// Offset from the node edge to the cable attachment point.
    /// Cables extend to the outer edge of the pill (pillEdgeX).
    /// The trapezoid spans from pillEdgeX (transparent) to pillEdgeX ± taperLen (opaque).
    private var bundleOffsetX: CGFloat { max(3, 3.5 * vpScale) / 2 + taperLen }  // pillHalf + taperLen
    private var taperLen: CGFloat      { max(36, 42 * vpScale) }

    // ── Pill geometry (collapsed nodes) ──────────────────────────────────────
    /// Returns the port types present among the connected ports, in `typeOrder` order.
    private func connectedTypes(ports: [JackPort], isOutput: Bool,
                                connections: [JackConnection]) -> [JackPortType] {
        let connPorts = ports.filter { p in
            isOutput ? connections.contains { $0.from == p.id }
                     : connections.contains { $0.to   == p.id }
        }
        return typeOrder.filter { t in connPorts.contains { $0.type == t } }
    }

    /// Returns the vertical centre of the pill for a given port type within a collapsed node's header.
    private func pillCenterY(for portType: JackPortType, types: [JackPortType],
                              ny: CGFloat, hh: CGFloat) -> CGFloat? {
        guard let idx = types.firstIndex(of: portType) else { return nil }
        let pillGap = max(2, 2 * vpScale)
        let pillH   = (hh * 0.75 - pillGap * CGFloat(max(0, types.count - 1))) / CGFloat(max(1, types.count))
        let stackH  = pillH * CGFloat(types.count) + pillGap * CGFloat(max(0, types.count - 1))
        let stackTopY = ny + (hh - stackH) / 2
        return stackTopY + (pillH + pillGap) * CGFloat(idx) + pillH / 2
    }

    // ── Haptic helpers ────────────────────────────────────────────────────────
    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    private func isCompatiblePort(_ candidate: JackPort, with source: JackPort) -> Bool {
        candidate.id != source.id
            && candidate.direction != source.direction
            && candidate.type == source.type
    }

    private func nodeHeight(for node: PatchbayNode) -> CGFloat {
        let rows = CGFloat(max(node.inputCount, node.outputCount))
        return node.isCollapsed ? headerH : headerH + rows * rowH + 6
    }

    private func overlapsAnotherNode(nodeId: String) -> Bool {
        guard let moving = nodes.first(where: { $0.id == nodeId }) else { return false }
        let mRect = CGRect(x: moving.position.x, y: moving.position.y,
                           width: nodeW, height: nodeHeight(for: moving))
        for node in nodes where node.id != nodeId {
            let nRect = CGRect(x: node.position.x, y: node.position.y,
                               width: nodeW, height: nodeHeight(for: node))
            if mRect.intersects(nRect) { return true }
        }
        return false
    }

    private func clampedNodePosition(_ pos: CGPoint, nodeId: String) -> CGPoint {
        let W = bounds.width, H = bounds.height
        // Viewport edges: hard stop symmetrically in all 4 directions
        let canvasMinX = -vpOffset.width  / vpScale
        let canvasMinY = -vpOffset.height / vpScale
        let canvasMaxX = (-vpOffset.width  + W) / vpScale
        let canvasMaxY = (-vpOffset.height + H) / vpScale

        let node = nodes.first { $0.id == nodeId }
        let rows = CGFloat(max(node?.inputCount ?? 0, node?.outputCount ?? 0))
        let isCollapsed = node?.isCollapsed ?? false
        let nodeH: CGFloat = isCollapsed
            ? headerH
            : headerH + rows * rowH + 6
        let nodeW: CGFloat = 210

        let x = max(canvasMinX, min(canvasMaxX - nodeW, pos.x))
        let y = max(canvasMinY, min(canvasMaxY - nodeH, pos.y))
        return CGPoint(x: x, y: y)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        coordinator?.parent.showCtx = false

        // Single click on the collapse arrow (top-right corner of the header)
        if event.clickCount == 1, let nodeId = hitTestCollapseArrow(at: pt) {
            patchbay?.toggleCollapse(nodeId)
            return
        }

        // Single click on the badge (coloured pill) — opens the inspect modal
        if event.clickCount == 1, let node = hitTestBadgeNode(at: pt) {
            DispatchQueue.main.async { self.coordinator?.parent.tappedBadgeNode = node }
            return
        }

        // Double-click on the header — also toggles collapse (only when collapsable)
        if event.clickCount == 2 {
            if let nodeId = hitTestNode(at: pt),
               isInHeader(at: pt, nodeId: nodeId),
               let node = nodes.first(where: { $0.id == nodeId }),
               canCollapse(node) {
                patchbay?.toggleCollapse(nodeId)
                return
            }
        }

        // Shift+click → toggle node selection (without starting a drag)
        if event.modifierFlags.contains(.shift) {
            if let nodeId = hitTestNode(at: pt) {
                patchbay?.toggleSelection(nodeId)
                _ = self.window?.makeFirstResponder(self)
            }
            return
        }

        if let port = hitTestPort(at: pt) {
            wireSrcPort    = port
            isDraggingWire = true
            // Use the exact port centre (not the raw click) so the preview wire
            // starts at the correct position, even for ports at row > 0
            wireSrcPos     = portCenter(port.id, dir: port.direction).map { NSPoint(x: $0.x, y: $0.y) } ?? pt
            wireCurrent    = pt
            return
        }

        if let nodeId = hitTestNode(at: pt) {
            let mouseCanvasX = (pt.x - vpOffset.width)  / vpScale
            let mouseCanvasY = (pt.y - vpOffset.height) / vpScale
            let sel = patchbay?.selectedNodeIds ?? []
            if sel.contains(nodeId) && sel.count > 1 {
                // Group drag: all selected nodes move together
                isGroupDragging  = true
                groupDragOffsets = Dictionary(uniqueKeysWithValues:
                    nodes.filter { sel.contains($0.id) }.map { node in
                        (node.id, CGSize(width:  node.position.x - mouseCanvasX,
                                         height: node.position.y - mouseCanvasY))
                    }
                )
            } else {
                // Solo drag (existing behaviour)
                draggingNodeId = nodeId
                if let node = nodes.first(where: { $0.id == nodeId }) {
                    dragNodeOffset = CGSize(
                        width:  node.position.x - mouseCanvasX,
                        height: node.position.y - mouseCanvasY
                    )
                }
            }
            return
        }

        isPanningBackground = true
        panStartMouse  = pt
        panStartOffset = vpOffset
        patchbay?.clearSelection()
        NSCursor.openHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        if isDraggingWire {
            wireCurrent = pt
            let candidate = hitTestPort(at: pt)
            // Highlight only compatible ports (opposite direction, same type)
            let compatible = candidate.flatMap { c in
                wireSrcPort.flatMap { src in isCompatiblePort(c, with: src) ? c : nil }
            }
            hoveredPort = compatible
            // Haptic feedback each time the cursor enters a compatible port
            let newPortId = hoveredPort?.id
            if newPortId != lastHoveredPortId {
                if newPortId != nil { haptic(.alignment) }
                lastHoveredPortId = newPortId
            }
            needsDisplay = true
            return
        }

        if isPanningBackground {
            coordinator?.parent.vpOffset = CGSize(
                width:  panStartOffset.width  + pt.x - panStartMouse.x,
                height: panStartOffset.height + pt.y - panStartMouse.y
            )
            needsDisplay = true
            return
        }

        hoveredPort = nil

        if isGroupDragging {
            let mouseCanvasX = (pt.x - vpOffset.width)  / vpScale
            let mouseCanvasY = (pt.y - vpOffset.height) / vpScale
            let W = bounds.width, H = bounds.height
            let minX = -vpOffset.width  / vpScale
            let minY = -vpOffset.height / vpScale
            let maxX = (-vpOffset.width  + W) / vpScale
            let maxY = (-vpOffset.height + H) / vpScale

            // Allowed cursor range so the entire group stays within the viewport
            var cursorMinX = -CGFloat.infinity, cursorMaxX = CGFloat.infinity
            var cursorMinY = -CGFloat.infinity, cursorMaxY = CGFloat.infinity
            for (nid, offset) in groupDragOffsets {
                guard let node = nodes.first(where: { $0.id == nid }) else { continue }
                let nH = nodeHeight(for: node)
                cursorMinX = max(cursorMinX, minX - offset.width)
                cursorMaxX = min(cursorMaxX, maxX - nodeW - offset.width)
                cursorMinY = max(cursorMinY, minY - offset.height)
                cursorMaxY = min(cursorMaxY, maxY - nH - offset.height)
            }
            let cx = max(cursorMinX, min(cursorMaxX, mouseCanvasX))
            let cy = max(cursorMinY, min(cursorMaxY, mouseCanvasY))

            for (nid, offset) in groupDragOffsets {
                if let idx = patchbay?.nodes.firstIndex(where: { $0.id == nid }) {
                    patchbay?.nodes[idx].position = CGPoint(x: cx + offset.width,
                                                            y: cy + offset.height)
                }
            }
            let atEdge = (cx != mouseCanvasX || cy != mouseCanvasY)
            if atEdge && !isNodeAtEdge { haptic(.generic) }
            isNodeAtEdge = atEdge
            needsDisplay = true
            return
        }

        if let nodeId = draggingNodeId {
            // dragNodeOffset in canvas coordinates → formula stays correct after pan/zoom
            let rawX = (pt.x - vpOffset.width)  / vpScale + dragNodeOffset.width
            let rawY = (pt.y - vpOffset.height) / vpScale + dragNodeOffset.height
            let raw     = CGPoint(x: rawX, y: rawY)
            let clamped = clampedNodePosition(raw, nodeId: nodeId)

            // Edge haptic: free → clamped transition
            let atEdge = (clamped.x != raw.x || clamped.y != raw.y)
            if atEdge && !isNodeAtEdge { haptic(.generic) }
            isNodeAtEdge = atEdge

            if let idx = patchbay?.nodes.firstIndex(where: { $0.id == nodeId }) {
                patchbay?.nodes[idx].position = clamped
            }

            // Overlap haptic: fired on enter/exit overlap state
            let overlapping = overlapsAnotherNode(nodeId: nodeId)
            if overlapping != isDraggingOverlap { haptic(.alignment) }
            isDraggingOverlap = overlapping

            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if isDraggingWire, let src = wireSrcPort {
            if let dst = hitTestPort(at: pt), dst.id != src.id {
                if src.direction == .output && dst.direction == .input && src.type == dst.type {
                    patchbay?.connectPorts(from: src, to: dst)
                } else if src.direction == .input && dst.direction == .output && src.type == dst.type {
                    patchbay?.connectPorts(from: dst, to: src)
                }
            }
        }
        if isPanningBackground {
            NSCursor.pop()
            isPanningBackground = false
        }
        if let nodeId = draggingNodeId,
           let idx = patchbay?.nodes.firstIndex(where: { $0.id == nodeId }) {
            // Clamp using the same vpOffset-aware formula as clampedNodePosition
            // (without vpOffset the clamp is wrong after panning during a drag)
            let W = bounds.width, H = bounds.height
            let margin: CGFloat = 20
            let minX = -vpOffset.width  / vpScale                   // left viewport edge
            let minY = -vpOffset.height / vpScale                   // top viewport edge
            let maxX = (-vpOffset.width  + W - margin) / vpScale   // right viewport edge
            let maxY = (-vpOffset.height + H - margin) / vpScale   // bottom viewport edge
            let cur  = patchbay!.nodes[idx].position
            let clamped = CGPoint(x: max(minX, min(maxX, cur.x)),
                                  y: max(minY, min(maxY, cur.y)))
            let vpRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let final = patchbay?.resolveDropCollision(for: nodeId, at: clamped, within: vpRect) ?? clamped
            patchbay?.nodes[idx].position = final
            if final != clamped { patchbay?.triggerRepositionToast() }
        }
        // ── Group drop: resolve overlaps for nodes that were NOT moved ───────────
        if isGroupDragging {
            let W = bounds.width, H = bounds.height
            let margin: CGFloat = 20
            let minX = -vpOffset.width  / vpScale
            let minY = -vpOffset.height / vpScale
            let maxX = (-vpOffset.width  + W - margin) / vpScale
            let maxY = (-vpOffset.height + H - margin) / vpScale
            let vpRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            patchbay?.resolveGroupDropCollisions(movedIds: Set(groupDragOffsets.keys),
                                                 within: vpRect)
        }
        isDraggingWire    = false; wireSrcPort = nil
        draggingNodeId    = nil
        isGroupDragging   = false
        groupDragOffsets  = [:]
        hoveredPort       = nil
        isNodeAtEdge      = false
        isDraggingOverlap = false
        lastHoveredPortId = nil
        needsDisplay      = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let coord = coordinator else { return }
        // Convert the screen point to canvas coordinates so the menu follows pan/zoom
        let canvasPos = CGPoint(x: (pt.x - vpOffset.width)  / vpScale,
                                y: (pt.y - vpOffset.height) / vpScale)
        if let port = hitTestPort(at: pt) {
            coord.parent.ctxPort      = port; coord.parent.ctxNode = nil
            coord.parent.ctxNodeSide  = nil
            coord.parent.ctxCanvasPos = canvasPos
            coord.parent.showCtx      = true
        } else if let (node, side) = hitTestNodeWithSide(at: pt) {
            coord.parent.ctxNode      = node; coord.parent.ctxPort = nil
            coord.parent.ctxNodeSide  = side
            coord.parent.ctxCanvasPos = canvasPos
            coord.parent.showCtx      = true
        }
    }

    /// Returns `(node, isOutputSide?)` for a right-click hit test.
    /// Collapsed: pill zones (± margin) determine the side; central header gives `nil`.
    /// Expanded: side is determined by whether the click is left (input) or right (output) of centre.
    private func hitTestNodeWithSide(at point: NSPoint) -> (PatchbayNode, Bool?)? {
        let pt = CGPoint(x: point.x, y: point.y)
        for node in nodes {
            let nx = node.position.x * vpScale + vpOffset.width
            let ny = node.position.y * vpScale + vpOffset.height
            let nw = nodeW * vpScale
            let hh = headerH * vpScale

            if node.isCollapsed {
                let pillW  = max(3.0, 3.5 * vpScale)
                let margin = max(12.0, 16 * vpScale)
                guard pt.y >= ny && pt.y <= ny + hh else { continue }

                // Output pill zone (right, outside the node)
                if pt.x >= nx + nw - 2 && pt.x <= nx + nw + pillW + margin && !node.outputs.isEmpty {
                    return (node, true)
                }
                // Input pill zone (left, outside the node)
                if pt.x <= nx + 2 && pt.x >= nx - pillW - margin && !node.inputs.isEmpty {
                    return (node, false)
                }
                // Central header → general menu (no connect-all)
                if pt.x >= nx && pt.x <= nx + nw { return (node, nil) }

            } else {
                let rows  = max(node.inputCount, node.outputCount)
                let bodyH = CGFloat(rows) * rowH * vpScale + 6 * vpScale
                let rect  = CGRect(x: nx, y: ny, width: nw, height: hh + bodyH)
                if rect.contains(pt) {
                    let isRight = pt.x >= nx + nw / 2
                    let side: Bool? = isRight
                        ? (node.outputs.isEmpty ? nil : true)
                        : (node.inputs.isEmpty  ? nil : false)
                    return (node, side)
                }
            }
        }
        return nil
    }

    override func magnify(with event: NSEvent) {
        guard let coord = coordinator else { return }
        let newScale = max(0.5, min(1.5, vpScale * (1.0 + event.magnification)))
        let pt = convert(event.locationInWindow, from: nil)
        let nx = pt.x - (pt.x - vpOffset.width)  * (newScale / vpScale)
        let ny = pt.y - (pt.y - vpOffset.height) * (newScale / vpScale)
        let newOffset = CGSize(width: nx, height: ny)
        // Immediate local update — required when a node drag is in progress
        vpScale  = newScale
        vpOffset = newOffset
        coord.parent.vpScale  = newScale
        coord.parent.vpOffset = newOffset
        needsDisplay = true
    }

    /// Two-finger double-tap: resets zoom to 100 % centred on the gesture point.
    override func smartMagnify(with event: NSEvent) {
        guard let coord = coordinator else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let nx = pt.x - (pt.x - vpOffset.width)  * (1.0 / vpScale)
        let ny = pt.y - (pt.y - vpOffset.height) * (1.0 / vpScale)
        let newOffset = CGSize(width: nx, height: ny)
        vpScale  = 1.0
        vpOffset = newOffset
        coord.parent.vpScale  = 1.0
        coord.parent.vpOffset = newOffset
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coord = coordinator else { return }
        if event.hasPreciseScrollingDeltas {
            let newOffset = CGSize(
                width:  vpOffset.width  + event.scrollingDeltaX,
                height: vpOffset.height + event.scrollingDeltaY
            )
            vpOffset = newOffset                        // immediate local update
            coord.parent.vpOffset = newOffset
        } else {
            let factor   = 1.0 + (-event.deltaY * 0.1)
            let newScale = max(0.5, min(1.5, vpScale * CGFloat(factor)))
            let pt = convert(event.locationInWindow, from: nil)
            let nx = pt.x - (pt.x - vpOffset.width)  * (newScale / vpScale)
            let ny = pt.y - (pt.y - vpOffset.height) * (newScale / vpScale)
            let newOffset = CGSize(width: nx, height: ny)
            vpScale  = newScale                         // immediate local update
            vpOffset = newOffset
            coord.parent.vpScale  = newScale
            coord.parent.vpOffset = newOffset
        }
        needsDisplay = true
    }

    // MARK: - Helpers

    private func nsColor(_ color: Color, alpha: CGFloat) -> NSColor {
        NSColor(color).withAlphaComponent(alpha)
    }
}
