//
//  ContentView.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Main window UI: sidebar navigation (Configuration / Patchbay), status bar,
//  device pickers, Jack configuration controls, studio sidebar, and all
//  associated sheets and sub-components.
//

import SwiftUI
import AppKit
import Combine

// MARK: - VisualEffectView

/// Thin SwiftUI wrapper around `NSVisualEffectView` for blurred backgrounds.
struct VisualEffectView: NSViewRepresentable {
    var material:     NSVisualEffectView.Material     = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = blendingMode
        view.state = .active; view.wantsLayer = true
        return view
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material; v.blendingMode = blendingMode
    }
}

// MARK: - JMPopUpButton

/// `NSPopUpButton` wrapper that handles duplicate option labels correctly.
/// Uses tagged `NSMenuItem` items instead of `addItem(withTitle:)`, which
/// silently merges items with identical titles.
struct JMPopUpButton<T: Hashable & CustomStringConvertible>: NSViewRepresentable {
    let options: [(label: String, value: T)]
    @Binding var selection: T

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        populate(button)
        styleButton(button)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        // Repopulate if the option list has changed
        let currentTags = button.itemArray.map { $0.tag }
        let expectedTags = Array(0..<options.count)

        if currentTags != expectedTags || button.numberOfItems != options.count {
            populate(button)
        }

        // Select the item matching the current binding value
        for (i, opt) in options.enumerated() {
            if opt.value == selection {
                button.selectItem(withTag: i)
                break
            }
        }
        styleButton(button)
    }

    private func populate(_ button: NSPopUpButton) {
        // IMPORTANT: Use NSMenuItem with explicit tags instead of addItem(withTitle:),
        // because addItem(withTitle:) silently merges items that share the same title.
        button.removeAllItems()

        let menu = NSMenu()
        for (index, opt) in options.enumerated() {
            let item = NSMenuItem(title: opt.label, action: nil, keyEquivalent: "")
            item.tag = index  // tag == index into the options array
            menu.addItem(item)
        }
        button.menu = menu

        // Select the item corresponding to the current binding value
        for (i, opt) in options.enumerated() {
            if opt.value == selection {
                button.selectItem(withTag: i)
                break
            }
        }
    }

    private func styleButton(_ button: NSPopUpButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1).cgColor
        button.layer?.cornerRadius    = 6
        button.layer?.borderWidth     = 1
        button.layer?.borderColor     = NSColor.white.withAlphaComponent(0.12).cgColor
        if let cell = button.cell as? NSPopUpButtonCell {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                .font: NSFont.systemFont(ofSize: 11)
            ]
            cell.attributedTitle = NSAttributedString(
                string: button.titleOfSelectedItem ?? "", attributes: attrs)
        }
    }

    class Coordinator: NSObject {
        var parent: JMPopUpButton
        init(_ p: JMPopUpButton) { parent = p }
        
        @objc func selectionChanged(_ sender: NSPopUpButton) {
            // Use the item tag rather than indexOfSelectedItem to survive duplicate titles
            guard let selectedItem = sender.selectedItem else { return }
            let idx = selectedItem.tag
            guard idx >= 0, idx < parent.options.count else { return }
            parent.selection = parent.options[idx].value
        }
    }
}

// MARK: - Additional colours

extension JM {
    static let accentViolet = Color(hex: "#9333ea")
    static let tintViolet   = Color(hex: "#9333ea").opacity(0.35)

    static let groupDevices = Color(hex: "#ef4444")
    static let tintDevices  = Color(hex: "#ef4444").opacity(0.35)
    static let groupAudio   = Color(hex: "#e879f9")
    static let tintAudio    = Color(hex: "#e879f9").opacity(0.32)
    static let groupOptions = Color(hex: "#f97316")
    static let tintOptions  = Color(hex: "#f97316").opacity(0.35)

    // Group section titles — white at 65% (more legible than textTertiary at 40%)
    static let groupTitle   = Color.white.opacity(0.65)
}

// MARK: - Navigation

/// Top-level navigation destinations shown in the sidebar.
enum SidebarNavItem: String, CaseIterable {
    case configuration = "Configuration"
    case patchbay      = "Patchbay"
    var icon: String {
        switch self {
        case .configuration: return "gearshape.fill"
        case .patchbay:      return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - ContentView

/// Root view: sidebar + header + body (Configuration or Patchbay canvas).
/// Owns `PatchbayManager` and `StudioManager` as `@StateObject` instances.
struct ContentView: View {
    @EnvironmentObject var jackManager:  JackManager
    @EnvironmentObject var audioManager: CoreAudioManager
    @ObservedObject private var notifications = NotificationManager.shared
    @State private var selection: SidebarNavItem = .configuration
    @StateObject private var patchbayManager = PatchbayManager()
    @StateObject private var studioManager   = StudioManager()
    @State private var patchbayScale:  CGFloat = 1.0
    @State private var patchbayOffset: CGSize  = .zero
    @State private var canvasSize:     CGSize  = CGSize(width: 900, height: 480)
    @State private var showZoomOverlay  = false
    @State private var zoomHideWork: DispatchWorkItem? = nil
    @State private var hoveredSelAction: String? = nil
    @State private var showJackNotInstalled = false

    // MARK: - Off-screen helpers

    /// The currently visible canvas rectangle in world (unscaled) coordinates.
    private var visibleRectWorld: CGRect {
        CGRect(x: -patchbayOffset.width  / patchbayScale,
               y: -patchbayOffset.height / patchbayScale,
               width:  canvasSize.width  / patchbayScale,
               height: canvasSize.height / patchbayScale)
    }

    /// Off-screen nodes with 8-sector directional classification.
    /// A corner node produces a single diagonal arrow symbol.
    private var offScreenInfo: (count: Int, dirs: [(symbol: String, count: Int)]) {
        let vis = visibleRectWorld
        var dirCounts: [String: Int] = [:]
        var total = 0
        for node in patchbayManager.nodes {
            let rows = CGFloat(max(node.inputCount, node.outputCount))
            let h    = node.isCollapsed ? 46.0 : 46.0 + rows * 21.0 + 6.0
            let rect = CGRect(x: node.position.x, y: node.position.y, width: 200, height: h)
            guard !vis.intersects(rect) else { continue }
            total += 1
            let outL = rect.maxX < vis.minX
            let outR = rect.minX > vis.maxX
            let outU = rect.maxY < vis.minY
            let outD = rect.minY > vis.maxY
            let sym: String
            switch (outL, outR, outU, outD) {
            case (true,  false, true,  false): sym = "arrow.up.left"
            case (false, true,  true,  false): sym = "arrow.up.right"
            case (true,  false, false, true ): sym = "arrow.down.left"
            case (false, true,  false, true ): sym = "arrow.down.right"
            case (true,  false, false, false): sym = "arrow.left"
            case (false, true,  false, false): sym = "arrow.right"
            case (false, false, true,  false): sym = "arrow.up"
            default:                           sym = "arrow.down"
            }
            dirCounts[sym, default: 0] += 1
        }
        // Clockwise order: ↑ ↗ → ↘ ↓ ↙ ← ↖
        let order = ["arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right",
                     "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left"]
        let dirs = order.compactMap { sym -> (symbol: String, count: Int)? in
            guard let c = dirCounts[sym], c > 0 else { return nil }
            return (sym, c)
        }
        return (total, dirs)
    }

    /// Handles a tap on the off-screen node indicator.
    /// Either fits all nodes into view (if zoom allows) or moves distant nodes back into the current viewport.
    private func handleOffScreenTap() {
        guard !patchbayManager.nodes.isEmpty else { return }
        let padding: CGFloat = 60
        let minX = patchbayManager.nodes.map { $0.position.x }.min()!
        let minY = patchbayManager.nodes.map { $0.position.y }.min()!
        let maxX = patchbayManager.nodes.map { $0.position.x + 200 }.max()!
        let maxY = patchbayManager.nodes.map {
            $0.position.y + ($0.isCollapsed ? 46 : 46 + CGFloat(max($0.inputCount, $0.outputCount)) * 21 + 6)
        }.max()!
        let contentW = maxX - minX
        let contentH = maxY - minY
        guard contentW > 0, contentH > 0 else { return }
        let scaleX   = (canvasSize.width  - padding * 2) / contentW
        let scaleY   = (canvasSize.height - padding * 2) / contentH
        let fitScale = min(scaleX, scaleY, 1.5)

        if fitScale >= 0.5 {
            // Enough zoom-out to fit everything — centre on content
            let cx = (minX + maxX) / 2
            let cy = (minY + maxY) / 2
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                patchbayScale  = fitScale
                patchbayOffset = CGSize(width:  canvasSize.width  / 2 - cx * fitScale,
                                        height: canvasSize.height / 2 - cy * fitScale)
            }
        } else {
            // Nodes too far away — bring them back into the current viewport
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                patchbayManager.bringOffScreenNodes(visibleRect: visibleRectWorld)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
                .environmentObject(jackManager)
                .environmentObject(audioManager)
                .environmentObject(patchbayManager)
                .environmentObject(studioManager)
                .zIndex(10)

            Rectangle().fill(JM.border).frame(width: 1)
                .zIndex(10)

            VStack(spacing: 0) {
                ConfigHeaderView(selection: selection, vpScale: patchbayScale,
                                 vpOffset: $patchbayOffset, vpScaleBinding: $patchbayScale,
                                 canvasSize: canvasSize)
                    .environmentObject(jackManager)
                    .environmentObject(patchbayManager)
                    .environmentObject(studioManager)
                    .zIndex(10)
                Rectangle().fill(JM.borderFaint).frame(height: 1)
                    .zIndex(10)

                // ── Transport bar (slides in when Jack is running and visible) ─
                if patchbayManager.transportBarVisible {
                    TransportBarView(observer: patchbayManager.transportObserver)
                        .environmentObject(patchbayManager)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Rectangle().fill(JM.borderFaint).frame(height: 1)
                }

                ZStack(alignment: .trailing) {
                    Group {
                        switch selection {
                        case .configuration:
                            ConfigBodyView()
                                .environmentObject(jackManager)
                                .environmentObject(audioManager)
                        case .patchbay:
                            PatchbayView(vpScale: $patchbayScale, vpOffset: $patchbayOffset,
                                         canvasSize: $canvasSize)
                                .environmentObject(jackManager)
                                .environmentObject(audioManager)
                                .environmentObject(patchbayManager)
                                .environmentObject(studioManager)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()  // prevent the canvas from overflowing into the header/sidebar

                    // ── Transient zoom level overlay ─────────────────────────
                    if showZoomOverlay && selection == .patchbay {
                        Text(String(format: "%.0f%%", patchbayScale * 100))
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(JM.textPrimary)
                            .padding(.horizontal, 28).padding(.vertical, 16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(JM.border, lineWidth: 1))
                            .transition(.opacity)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .zIndex(20)
                    }

                    // ── Off-screen node indicator ────────────────────────────
                    Group {
                        if selection == .patchbay && offScreenInfo.count > 0 {
                            let info     = offScreenInfo
                            let multiDir = info.dirs.count > 1
                            Button(action: handleOffScreenTap) {
                                HStack(spacing: 5) {
                                    Text("\(info.count) hors vue")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                    Rectangle()
                                        .fill(JM.border)
                                        .frame(width: 0.5, height: 11)
                                    HStack(spacing: multiDir ? 5 : 0) {
                                        ForEach(info.dirs.indices, id: \.self) { i in
                                            HStack(spacing: 2) {
                                                Image(systemName: info.dirs[i].symbol)
                                                    .font(.system(size: 9, weight: .medium))
                                                if multiDir {
                                                    Text("\(info.dirs[i].count)")
                                                        .font(.system(size: 10, weight: .semibold,
                                                                      design: .rounded))
                                                }
                                            }
                                        }
                                    }
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(JM.border, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomTrailing)
                            .padding(.trailing, 12).padding(.bottom, 12)
                            .transition(.opacity)
                            .zIndex(15)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25),
                               value: selection == .patchbay && offScreenInfo.count > 0)

                    // ── Bottom-left overlays (selection bar + reposition toast) ──
                    let selCount = patchbayManager.selectedNodeIds.count
                    Group {
                        VStack(alignment: .leading, spacing: 6) {
                            // Reposition toast (transient)
                            if patchbayManager.showRepositionToast {
                                Text("canvas.tooltip.repositioned")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(JM.border, lineWidth: 0.5))
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: 4)),
                                        removal:   .opacity))
                            }
                            // Selection info bar (persistent while nodes are selected)
                            if selection == .patchbay && selCount > 0 {
                                let selNodes     = patchbayManager.nodes.filter { patchbayManager.selectedNodeIds.contains($0.id) }
                                let collCount    = selNodes.filter { $0.isCollapsed }.count
                                let willCollapse = (selNodes.count - collCount) >= collCount
                                HStack(spacing: 0) {
                                    Text("\(selCount) client\(selCount > 1 ? "s" : "") sélectionné\(selCount > 1 ? "s" : "")")
                                        .padding(.trailing, 8)
                                    Rectangle().fill(JM.border).frame(width: 0.5, height: 12)
                                        .padding(.horizontal, 8)
                                    // ── Collapse / Expand toggle ────────────
                                    Button {
                                        patchbayManager.toggleCollapseSelected()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: willCollapse
                                                  ? "rectangle.compress.vertical"
                                                  : "rectangle.expand.vertical")
                                            Text(willCollapse ? "collapser" : "décollapser")
                                        }
                                        .opacity(hoveredSelAction == "collapse" ? 1.0 : 0.75)
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hoveredSelAction = $0 ? "collapse" : nil }
                                    Rectangle().fill(JM.border).frame(width: 0.5, height: 12)
                                        .padding(.horizontal, 8)
                                    // ── Tidy selected nodes ──────────────────
                                    Button {
                                        let ids = Array(patchbayManager.selectedNodeIds)
                                        let vp  = patchbayManager.tidy(nodeIds: ids,
                                                                        canvasSize: canvasSize,
                                                                        currentScale: patchbayScale)
                                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                            patchbayScale  = vp.scale
                                            patchbayOffset = vp.offset
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                                            Text("organiser")
                                        }
                                        .opacity(hoveredSelAction == "tidy" ? 1.0 : 0.75)
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hoveredSelAction = $0 ? "tidy" : nil }
                                }
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(JM.border, lineWidth: 0.5))
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 4)),
                                    removal:   .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 12).padding(.bottom, 12)
                        .zIndex(15)
                    }
                    .animation(.easeInOut(duration: 0.25),
                               value: patchbayManager.showRepositionToast)
                    .animation(.easeInOut(duration: 0.2), value: selCount)

                    if jackManager.showLogPanel {
                        LogPanelView()
                            .environmentObject(jackManager)
                            .transition(.move(edge: .trailing))
                            .zIndex(10)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85),
                           value: jackManager.showLogPanel)
                .onChange(of: patchbayScale) {
                    zoomHideWork?.cancel()
                    withAnimation(.easeIn(duration: 0.15)) { showZoomOverlay = true }
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.4)) { showZoomOverlay = false }
                    }
                    zoomHideWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
                }

                Rectangle().fill(JM.borderFaint).frame(height: 1)
                StatusBarView()
                    .environmentObject(jackManager)
                    .environmentObject(patchbayManager)
                    .environmentObject(studioManager)
            }
            .frame(minWidth: 480)
        }
        .frame(minWidth: selection == .configuration ? 880 : 1100,
               minHeight: selection == .configuration ? 800 : 780)
        .background(JM.bgBase)
        .sheet(isPresented: $showJackNotInstalled) {
            JackNotInstalledView()
                .environmentObject(jackManager)
        }
        .onAppear {
            patchbayManager.configure(with: jackManager)
            patchbayManager.configureStudio(studioManager)
            studioManager.observeJackState(jackManager: jackManager, patchbayManager: patchbayManager)
            if !jackManager.jackInstalled { showJackNotInstalled = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            jackManager.recheckInstallation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainWindowDidOpen)) { _ in
            if !jackManager.jackInstalled { showJackNotInstalled = true }
        }
        .onChange(of: jackManager.jackInstalled) { _, installed in
            if !installed { showJackNotInstalled = true }
        }
        .onChange(of: jackManager.isRunning) { _, running in
            if running {
                selection = .patchbay
            } else {
                selection = .configuration
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToConfiguration)) { _ in
            selection = .configuration
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPatchbay)) { _ in
            selection = .patchbay
        }
    }

}

// MARK: - SidebarView

/// Fixed-width left sidebar: logo, navigation, device lists, studios, and Jack status footer.
struct SidebarView: View {
    @Binding var selection: SidebarNavItem
    @EnvironmentObject var jackManager:     JackManager
    @EnvironmentObject var audioManager:    CoreAudioManager
    @EnvironmentObject var patchbayManager: PatchbayManager
    @EnvironmentObject var studioManager:   StudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Logo — opaque, fixed height aligned with ConfigHeaderView
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(JM.bgElevated)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(JM.border, lineWidth: 1))
                        .frame(width: 26, height: 26)
                    Image(systemName: "waveform.path")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(JM.accentRed)
                }
                Text("JackMate")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JM.textPrimary)
            }
            // Padding matches ConfigHeaderView (.vertical, 13)
            // + content height ~30 px → total ~56 px on both sides
            .padding(.horizontal, 14)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(JM.bgBase)

            Rectangle().fill(JM.borderFaint).frame(height: 1)

            // ScrollView — frosted glass effect (sidebar material) only here
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 6)

                    SidebarSectionLabel("Jack")
                    SidebarNavRow(
                        icon: "gearshape.fill",
                        iconBg: JM.tintIndigo, iconColor: JM.accentIndigo,
                        title: "Configuration",
                        isSelected: selection == .configuration, isEnabled: true
                    ) { selection = .configuration }
                    SidebarNavRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        iconBg: JM.tintPurple, iconColor: JM.accentPurple,
                        title: "Patchbay",
                        isSelected: selection == .patchbay, isEnabled: true
                    ) { selection = .patchbay }

                    SidebarSectionLabel(String(format: String(localized: "sidebar.inputs.title"), audioManager.inputDevices.count))
                    if audioManager.inputDevices.isEmpty {
                        SidebarEmptyRow(text: String(localized: "sidebar.inputs.empty"))
                    } else {
                        ForEach(audioManager.inputDevices) { d in
                            SidebarPlainDeviceRow(icon: "mic.fill", iconColor: JM.accentCyan,
                                                  name: d.name, sub: "\(d.inputChannels) ch.")
                        }
                    }

                    SidebarSectionLabel(String(format: String(localized: "sidebar.outputs.title"), audioManager.outputDevices.count))
                    if audioManager.outputDevices.isEmpty {
                        SidebarEmptyRow(text: String(localized: "sidebar.inputs.empty"))
                    } else {
                        ForEach(audioManager.outputDevices) { d in
                            SidebarPlainDeviceRow(icon: "speaker.wave.2.fill", iconColor: JM.accentViolet,
                                                  name: d.name, sub: "\(d.outputChannels) ch.")
                        }
                    }
                }
            }
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))

            LinearGradient(
                colors: [Color.clear, Color.white.opacity(0.18), Color.clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)
            SidebarStudiosSection(selection: $selection)
                .environmentObject(jackManager)
                .environmentObject(patchbayManager)
                .environmentObject(studioManager)

            Rectangle().fill(JM.borderFaint).frame(height: 1)

            // Footer — opaque, tri-colour LED status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(jackFooterColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: jackFooterColor.opacity(0.6), radius: 4)
                Text(jackFooterText)
                    .font(.system(size: 11))
                    .foregroundStyle(JM.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(JM.bgBase)
        }
        .frame(width: 210)
        .background(JM.bgBase)
    }

    /// LED colour: green when running, amber while starting, red when stopped.
    var jackFooterColor: Color {
        if jackManager.isRunning { return JM.accentGreen }
        let msg = jackManager.statusMessage
        // Starting indicator: only shown while Jack is not yet running
        if msg.contains("💈") { return JM.accentAmber }
        return JM.accentRed
    }

    /// Short status label displayed next to the footer LED.
    var jackFooterText: String {
        if jackManager.isRunning { return String(localized: "common.jack_running") }
        let msg = jackManager.statusMessage
        if msg.contains("💈") { return String(localized: "common.jack_starting") }
        return String(localized: "common.jack_stopped")
    }
}

// MARK: - Sidebar sub-components

/// Small all-caps section header used inside the sidebar.
struct SidebarSectionLabel: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(JM.textTertiary).tracking(0.8)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 3)
    }
}

/// Tappable navigation row with a coloured icon badge and selection highlight.
struct SidebarNavRow: View {
    let icon: String; let iconBg: Color; let iconColor: Color
    let title: String; let isSelected: Bool; let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(iconBg).frame(width: 18, height: 18)
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? JM.textPrimary : JM.textPrimary.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? iconBg : (isHovered ? iconBg.opacity(0.5) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? iconColor.opacity(0.3) : Color.clear, lineWidth: 1)))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain).disabled(!isEnabled).opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
    }
}

/// Read-only device row (name + channel count) shown in the sidebar device lists.
struct SidebarPlainDeviceRow: View {
    let icon: String; let iconColor: Color
    let name: String; let sub: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 11.5)).foregroundStyle(JM.textSecondary).lineLimit(1)
                Text(sub).font(.system(size: 9.5)).foregroundStyle(JM.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
    }
}

/// Placeholder row displayed when a sidebar device list is empty.
struct SidebarEmptyRow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(JM.textTertiary)
            .padding(.horizontal, 14).padding(.vertical, 4)
    }
}

// MARK: - SidebarStudiosSection

/// Sidebar section that lists saved studios with hover-revealed metadata and action buttons.
struct SidebarStudiosSection: View {
    @Binding var selection: SidebarNavItem
    @EnvironmentObject var jackManager:     JackManager
    @EnvironmentObject var patchbayManager: PatchbayManager
    @EnvironmentObject var studioManager:   StudioManager
    @State private var hoveredStudio: Studio? = nil

    private let rowHeight: CGFloat = 28
    private let maxHeight: CGFloat = 220

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(verbatim: String(format: String(localized: "sidebar.studios.title"), studioManager.studios.count))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(JM.textTertiary)
                    .tracking(0.8)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if studioManager.studios.isEmpty {
                Text("sidebar.studios.empty")
                    .font(.system(size: 11))
                    .foregroundStyle(JM.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                let canScroll = CGFloat(studioManager.studios.count) * rowHeight > maxHeight
                ZStack(alignment: .bottom) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(studioManager.studios) { studio in
                                StudioSidebarRow(studio: studio,
                                                 hoveredStudio: $hoveredStudio,
                                                 selection: $selection)
                                    .environmentObject(studioManager)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: maxHeight)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: canScroll ? 0.90 : 1),
                                .init(color: .clear,  location: canScroll ? 1.0 : 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    if canScroll {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(JM.textPrimary)
                            .padding(.bottom, 3)
                            .allowsHitTesting(false)
                    }
                }

                // Info zone — fixed height to prevent layout shift on hover
                LinearGradient(
                    colors: [Color.clear, Color.white.opacity(0.18), Color.clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1)
                VStack(alignment: .leading, spacing: 3) {
                    if let s = hoveredStudio {
                        infoLine(icon: "calendar.badge.plus",    label: String(localized: "common.created"),    date: s.createdAt)
                        infoLine(icon: "clock.arrow.circlepath", label: String(localized: "common.modified"), date: s.updatedAt)
                        infoLine(icon: "play.circle", label: String(localized: "common.loaded"),
                                 date: s.lastLoadedAt ?? s.createdAt,
                                 faded: s.lastLoadedAt == nil)
                    } else {
                        infoLine(icon: "calendar.badge.plus",    label: String(localized: "common.created"),    date: .distantPast).hidden()
                        infoLine(icon: "clock.arrow.circlepath", label: String(localized: "common.modified"), date: .distantPast).hidden()
                        infoLine(icon: "play.circle",            label: String(localized: "common.loaded"),  date: .distantPast).hidden()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .opacity(hoveredStudio != nil ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: hoveredStudio?.id)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }

    @ViewBuilder
    private func infoLine(icon: String, label: String, date: Date, faded: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(JM.accentAmber)
                .frame(width: 10)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(JM.textSecondary)
                .frame(width: 42, alignment: .leading)
            Text(faded ? "—" : df.string(from: date))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(faded ? JM.textSecondary : JM.textPrimary)
        }
    }
}

// MARK: - MarqueeText

/// Preference key used to propagate the measured text width from a `MarqueeText` subview.
private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Single-line text that scrolls horizontally when `isScrolling` is true and the text overflows.
/// Fades the trailing edge when idle; scrolls from right to left at 50 px/s when active.
struct MarqueeText: View {
    let text:       String
    let font:       Font
    let color:      Color
    var isScrolling: Bool

    @State private var textW:      CGFloat = 0
    @State private var containerW: CGFloat = 0
    @State private var offset:     CGFloat = 0

    private var overflow: CGFloat { max(0, textW - containerW) }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: offset)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: MarqueeTextWidthKey.self, value: g.size.width)
                    })
                    .onPreferenceChange(MarqueeTextWidthKey.self) { textW = $0 }
            }
            .background(GeometryReader { g in
                Color.clear.onAppear { containerW = g.size.width }
                    .onChange(of: g.size.width) { _, new in containerW = new }
            })
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: isScrolling ? 1.0 : 0.77),
                        .init(color: isScrolling ? .white : .clear, location: 1.0)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .animation(.easeInOut(duration: 0.2), value: isScrolling)
            )
            .onChange(of: isScrolling) { _, scrolling in
                if scrolling, overflow > 4 {
                    withAnimation(.linear(duration: Double(overflow) / 50).delay(0.5)) {
                        offset = -overflow
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        offset = 0
                    }
                }
            }
    }
}

/// A single row in the studio list: icon, scrolling name, load/stop/trash buttons.
struct StudioSidebarRow: View {
    let studio: Studio
    @Binding var hoveredStudio: Studio?
    @Binding var selection: SidebarNavItem
    @EnvironmentObject var studioManager:   StudioManager
    @EnvironmentObject var patchbayManager: PatchbayManager
    @EnvironmentObject var jackManager:     JackManager
    @State private var isHovered        = false
    @State private var isStopHovered    = false
    @State private var isTrashHovered   = false
    @State private var isInfoHovered    = false
    @State private var showDeleteSheet  = false
    @State private var showStopSheet    = false
    @State private var showInspectSheet = false
    @State private var showLoadProgress = false
    @State private var loadProgressMessage = ""

    private var isLoading: Bool { studioManager.activeStudio == studio.id }
    private var isLoaded:  Bool { studioManager.loadedStudio?.id == studio.id }
    private var otherBusy: Bool { studioManager.activeStudio != nil && !isLoading }

    var body: some View {
        HStack(spacing: 7) {
            // Studio icon
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(JM.accentAmber.opacity(0.25))
                    .frame(width: 15, height: 15)
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(JM.accentAmber)
            }
            MarqueeText(
                text:        studio.name,
                font:        .system(size: 11.5),
                color:       isLoaded ? JM.textPrimary : JM.textSecondary,
                isScrolling: isHovered
            )
            .onTapGesture { showInspectSheet = true }
            // Stop button (studio loaded) / play button / spinner
            if isLoading {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 18, height: 18)
            } else if isLoaded {
                Button { showStopSheet = true } label: {
                    Image(systemName: isStopHovered ? "stop.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(isStopHovered ? Color(hex: "#f97316") : JM.accentGreen)
                        .frame(width: 18, height: 18)
                        .animation(.easeInOut(duration: 0.15), value: isStopHovered)
                }
                .buttonStyle(.plain)
                .onHover { isStopHovered = $0 }
                .help(isStopHovered ? String(localized: "sidebar.studio.tooltip.stop") : String(localized: "sidebar.studio.tooltip.active"))
            } else {
                Button { doLoad() } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(JM.accentAmber)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.3)
                .disabled(otherBusy || !jackManager.jackInstalled)
                .help(jackManager.jackInstalled ? String(localized: "sidebar.studio.tooltip.load") : String(localized: "sidebar.studio.tooltip.jack_missing"))
            }
            // Info/inspect button — visible on hover only
            Button { showInspectSheet = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isInfoHovered ? JM.textPrimary : JM.textTertiary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .onHover { isInfoHovered = $0 }
            .help(String(localized: "sidebar.studio.tooltip.inspect"))

            // Trash button — visible on hover only, disabled while studio is loaded
            Button { showDeleteSheet = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isLoaded
                        ? JM.textTertiary.opacity(0.3)
                        : isTrashHovered ? JM.textPrimary : JM.textTertiary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .onHover { isTrashHovered = $0 }
            .disabled(isLoaded)
            .help(isLoaded ? String(localized: "sidebar.studio.tooltip.cannot_delete") : String(localized: "sidebar.studio.tooltip.delete"))
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { hovered in
            isHovered = hovered
            hoveredStudio = hovered ? studio : nil
        }
        .sheet(isPresented: $showDeleteSheet) {
            DeleteStudioConfirmView(studio: studio) {
                try? studioManager.delete(studio)
            }
        }
        .sheet(isPresented: $showStopSheet) {
            StopStudioSheet(studio: studio)
                .environmentObject(studioManager)
                .environmentObject(patchbayManager)
        }
        .sheet(isPresented: $showInspectSheet) {
            StudioInspectSheet(studio: studio)
        }
        .sheet(isPresented: $showLoadProgress) {
            LoadStudioProgressView(message: $loadProgressMessage)
        }
    }

    /// Triggers studio loading: switches to the patchbay tab, shows the progress sheet,
    /// then delegates to `StudioManager.loadStudio`.
    private func doLoad() {
        selection = .patchbay
        loadProgressMessage = String(localized: "sidebar.studio.progress.preparing")
        showLoadProgress = true

        studioManager.loadStudio(
            studio,
            bridge: patchbayManager.jackBridge,
            jackManager: jackManager,
            patchbayManager: patchbayManager,
            onProgress: { msg in
                loadProgressMessage = msg
            },
            onComplete: { result in
                let hasFailures = !result.failed.isEmpty || !result.notLaunched.isEmpty
                if !hasFailures {
                    patchbayManager.applyNodePositions(studio.nodePositions)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        patchbayManager.forceRefresh()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        patchbayManager.syncConnections()
                    }
                }
                loadProgressMessage = hasFailures
                    ? String(localized: "sidebar.studio.progress.partial")
                    : String(localized: "sidebar.studio.progress.done")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    showLoadProgress = false
                }
            }
        )
    }
}

// MARK: - DeleteStudioConfirmView

/// Confirmation sheet shown before deleting a studio.
/// Displays studio metadata (name, connections, clients, dates) and a destructive confirm button.
struct DeleteStudioConfirmView: View {
    let studio:    Studio
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var nonSystemClients: [StudioClient] {
        studio.clients.filter { $0.jackName != "system" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Title
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.red.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("delete_studio.title")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    Text("delete_studio.warning")
                        .font(.system(size: 11))
                        .foregroundStyle(JM.textTertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.horizontal, 20)

            // Studio metadata
            VStack(alignment: .leading, spacing: 10) {

                // Name
                infoRow(icon: "square.stack.3d.up", color: JM.accentAmber,
                        label: String(localized: "delete_studio.label.name"), value: studio.name)

                // Connections
                infoRow(icon: "point.3.connected.trianglepath.dotted", color: JM.accentPurple,
                        label: String(localized: "common.connections"), value: "\(studio.connections.count)")

                // Clients
                if !nonSystemClients.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            iconBadge("app.badge", color: JM.accentIndigo)
                            Text("common.clients")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(JM.textTertiary)
                        }
                        ForEach(nonSystemClients) { client in
                            HStack(spacing: 6) {
                                Color.clear.frame(width: 16)
                                Circle()
                                    .fill(JM.accentIndigo.opacity(0.4))
                                    .frame(width: 4, height: 4)
                                Text(client.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(JM.textSecondary)
                                if client.autoLaunch {
                                    Text("auto-launch")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(JM.accentGreen)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(RoundedRectangle(cornerRadius: 3)
                                            .fill(JM.accentGreen.opacity(0.15)))
                                }
                            }
                        }
                    }
                }

                // Dates
                infoRow(icon: "calendar.badge.plus",    color: JM.accentAmber,
                        label: String(localized: "delete_studio.label.created_on"),    value: dateFormatter.string(from: studio.createdAt))
                infoRow(icon: "clock.arrow.circlepath", color: JM.accentAmber,
                        label: String(localized: "delete_studio.label.modified_on"), value: dateFormatter.string(from: studio.updatedAt))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.horizontal, 20)

            // Action buttons
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(JM.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgElevated)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(JM.border, lineWidth: 1)))

                Button("common.delete") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 320)
        .background(JM.bgBase)
    }

    @ViewBuilder
    private func infoRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            iconBadge(icon, color: color)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(JM.textTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(JM.textSecondary)
        }
    }

    @ViewBuilder
    private func iconBadge(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.18))
                .frame(width: 16, height: 16)
            Image(systemName: name)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

// MARK: - StudioInspectSheet

/// Read-only inspector sheet: dates, Jack configuration snapshot, clients, and connections.
struct StudioInspectSheet: View {
    let studio: Studio
    @Environment(\.dismiss) private var dismiss

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var nonSystemClients: [StudioClient] {
        studio.clients.filter { $0.jackName != "system" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Title
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(JM.accentIndigo.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JM.accentIndigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(studio.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    Text(studio.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(JM.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.horizontal, 20)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {

                    // Dates section
                    sectionHeader(String(localized: "studio_inspect.section.dates"))
                    infoRow(icon: "calendar.badge.plus",    color: JM.accentAmber,
                            label: String(localized: "common.created"),    value: df.string(from: studio.createdAt))
                    infoRow(icon: "clock.arrow.circlepath", color: JM.accentAmber,
                            label: String(localized: "common.modified"), value: df.string(from: studio.updatedAt))
                    if let loaded = studio.lastLoadedAt {
                        infoRow(icon: "play.circle", color: JM.accentGreen,
                                label: String(localized: "common.loaded"), value: df.string(from: loaded))
                    }

                    // Jack configuration snapshot
                    if let snap = studio.jackSnapshot {
                        LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 1)
                        sectionHeader(String(localized: "studio_inspect.section.jack_config"))
                        infoRow(icon: "waveform", color: JM.accentCyan,
                                label: String(localized: "common.sample_rate"), value: "\(Int(snap.sampleRate)) Hz")
                        infoRow(icon: "memorychip", color: JM.accentCyan,
                                label: String(localized: "studio_inspect.label.buffer"), value: "\(snap.bufferSize) frames")
                        if let name = snap.inputDeviceName {
                            infoRow(icon: "mic.fill", color: JM.accentCyan,
                                    label: String(localized: "common.input"), value: name)
                        }
                        if let name = snap.outputDeviceName {
                            infoRow(icon: "speaker.wave.2.fill", color: JM.accentCyan,
                                    label: String(localized: "common.output"), value: name)
                        }
                        // Full Jack command
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4).fill(JM.accentCyan.opacity(0.18)).frame(width: 16, height: 16)
                                    Image(systemName: "terminal").font(.system(size: 8, weight: .bold)).foregroundStyle(JM.accentCyan)
                                }
                                Text("studio_inspect.label.command")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(JM.textTertiary)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(snap.command, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 10))
                                        .foregroundStyle(JM.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .help(String(localized: "common.copy_command"))
                            }
                            Text(snap.command)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(JM.textSecondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgElevated)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(JM.border, lineWidth: 1)))
                        }
                    }

                    // Clients section
                    if !nonSystemClients.isEmpty {
                        LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 1)
                        sectionHeader(String(format: String(localized: "studio_inspect.clients.title"), nonSystemClients.count))
                        ForEach(nonSystemClients) { client in
                            clientRow(client)
                        }
                    }

                    // Connections section
                    if !studio.connections.isEmpty {
                        LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 1)
                        sectionHeader(String(format: String(localized: "studio_inspect.connections.title"), studio.connections.count))
                        ForEach(studio.connections) { conn in
                            connectionRow(conn)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: 420)

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.horizontal, 20)

            HStack {
                Spacer()
                Button("common.close") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JM.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgElevated)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(JM.border, lineWidth: 1)))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 360)
        .background(JM.bgBase)
    }

    @ViewBuilder private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(JM.textTertiary)
            .tracking(0.6)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private func infoRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)).frame(width: 16, height: 16)
                Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(JM.textTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(JM.textSecondary)
        }
    }

    @ViewBuilder private func clientRow(_ client: StudioClient) -> some View {
        HStack(spacing: 8) {
            Circle().fill(JM.accentIndigo.opacity(0.4)).frame(width: 4, height: 4)
            Text(client.label)
                .font(.system(size: 11))
                .foregroundStyle(JM.textSecondary)
            Spacer()
            if client.autoLaunch {
                badge("auto-launch", color: JM.accentGreen)
            }
            switch client.launchType {
            case .bundle: badge("app", color: JM.accentIndigo)
            case .cli:    badge("cli", color: JM.accentAmber)
            case .none:   EmptyView()
            }
        }
    }

    @ViewBuilder private func connectionRow(_ conn: StudioConnection) -> some View {
        HStack(spacing: 6) {
            Text(conn.from)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(JM.textTertiary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 8))
                .foregroundStyle(JM.textTertiary.opacity(0.5))
            Text(conn.to)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(JM.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
    }
}

// MARK: - StopStudioSheet

/// Sheet for gracefully stopping a loaded studio: disconnects cables, sends SIGTERM to
/// all Jack clients, then force-kills any that are still alive after a timeout.
struct StopStudioSheet: View {
    let studio: Studio
    @EnvironmentObject var studioManager:   StudioManager
    @EnvironmentObject var patchbayManager: PatchbayManager
    @Environment(\.dismiss) private var dismiss

    /// UI phases of the stop workflow.
    enum Phase { case confirm, stopping, done }

    @State private var phase:          Phase  = .confirm
    @State private var statusMessage:  String = ""
    @State private var clientsToQuit:  [StudioManager.ClientToQuit] = []
    @State private var stuckApps:      [(name: String, pid: Int32)] = []

    private var studioClients: [StudioManager.ClientToQuit] {
        clientsToQuit.filter { $0.isInStudio }
    }
    private var extraClients: [StudioManager.ClientToQuit] {
        clientsToQuit.filter { !$0.isInStudio }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Title
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(JM.accentRed.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.accentRed)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: String(format: String(localized: "stop_studio.title"), studio.name))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    Text("stop_studio.jack_stays")
                        .font(.system(size: 11))
                        .foregroundStyle(JM.textTertiary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.horizontal, 20)

            // Contenu selon la phase
            Group {
                switch phase {
                case .confirm:  confirmBody
                case .stopping: stoppingBody
                case .done:     doneBody
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)

        }
        .frame(width: 340)
        .background(JM.bgBase)
        .onAppear {
            clientsToQuit = studioManager.allClientsToQuit(
                studio: studio,
                bridge: patchbayManager.jackBridge
            )
        }
    }

    // MARK: Phase confirm

    @ViewBuilder private var confirmBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if clientsToQuit.isEmpty {
                Text("stop_studio.no_clients")
                    .font(.system(size: 11))
                    .foregroundStyle(JM.textSecondary)
            } else {
                Text("stop_studio.clients_to_close")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JM.textSecondary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(studioClients) { item in
                        appRow(name: item.displayName, extra: false, isCLI: item.isCLI)
                    }
                    ForEach(extraClients) { item in
                        appRow(name: item.displayName, extra: true, isCLI: item.isCLI)
                    }
                }
            }

            HStack {
                Button("common.cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(JM.textSecondary)
                Spacer()
                Button("stop_studio.button.stop") {
                    Task { await doStop() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(JM.accentRed.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(JM.accentRed.opacity(0.4), lineWidth: 1)))
            }
        }
    }

    // MARK: Phase stopping

    @ViewBuilder private var stoppingBody: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.7)
            Text(statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(JM.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: Phase done

    @ViewBuilder private var doneBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if stuckApps.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(JM.accentGreen)
                    Text("stop_studio.done")
                        .font(.system(size: 12))
                        .foregroundStyle(JM.textSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("stop_studio.unresponsive")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(JM.accentAmber)
                    ForEach(stuckApps, id: \.pid) { stuck in
                        stuckRow(name: stuck.name, pid: stuck.pid)
                    }
                    Text("stop_studio.terminal_hint")
                        .font(.system(size: 10))
                        .foregroundStyle(JM.textTertiary)
                }
            }

            HStack {
                Spacer()
                Button("common.close") {
                    studioManager.loadedStudio = nil
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgElevated)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(JM.border, lineWidth: 1)))
            }
        }
    }

    // MARK: Helpers UI

    @ViewBuilder
    private func appRow(name: String, extra: Bool, isCLI: Bool = false) -> some View {
        HStack(spacing: 6) {
            Circle().fill(extra ? JM.accentAmber.opacity(0.5) : JM.accentIndigo.opacity(0.5))
                .frame(width: 4, height: 4)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(JM.textSecondary)
            if isCLI {
                Text("CLI")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(JM.textTertiary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(JM.textTertiary.opacity(0.12)))
            }
            if extra {
                Text("stop_studio.badge.external")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(JM.accentAmber)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(JM.accentAmber.opacity(0.12)))
            }
        }
    }

    @ViewBuilder
    private func stuckRow(name: String, pid: Int32) -> some View {
        let cmd = "kill -9 \(pid)"
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JM.textSecondary)
                Text(cmd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(JM.accentAmber)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(JM.textTertiary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "common.copy_command"))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgElevated)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(JM.border, lineWidth: 1)))
    }

    // MARK: Stop logic

    /// Executes the full studio stop sequence asynchronously.
    /// 1. Disconnects all Jack cables.
    /// 2. SIGTERMs all Jack clients.
    /// 3. Force-kills any that survive after 3 s.
    /// 4. Waits an additional 2 s, then reports still-running processes.
    private func doStop() async {
        phase = .stopping
        let bridge = patchbayManager.jackBridge

        // Step 0: disconnect all cables
        statusMessage = String(localized: "stop_studio.phase.disconnecting")
        for node in patchbayManager.nodes {
            patchbayManager.disconnectAll(of: node.id)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Step 1: SIGTERM all Jack clients via PID (GUI + CLI, including external)
        statusMessage = String(localized: "stop_studio.phase.closing")
        let targeted = studioManager.terminateAllJackClients(bridge: bridge)

        // Step 2: wait 3 s then force-kill any that are still alive
        statusMessage = String(localized: "stop_studio.phase.waiting")
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        for item in targeted {
            // Still alive? Force-kill
            if kill(item.pid, 0) == 0 {
                ProcessHelper.forceKill(pid: item.pid)
            }
        }

        // Step 3: wait another 2 s then report surviving processes
        if !targeted.isEmpty {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        stuckApps = targeted.compactMap { item in
            guard kill(item.pid, 0) == 0 else { return nil }
            return (name: item.name, pid: item.pid)
        }

        phase = .done
    }
}

// MARK: - LoadStudioProgressView

/// Transient progress modal shown while a studio is loading.
/// Auto-dismissed by the caller once loading completes.
struct LoadStudioProgressView: View {
    @Binding var message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(0.8)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(JM.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 260)
        .background(JM.bgBase)
    }
}

// MARK: - CaptureStudioSheet

/// Sheet for capturing the current patchbay state as a new studio.
/// Prompts for a name, shows the detected Jack command, and allows entering
/// CLI launch commands for clients that could not be auto-detected.
struct CaptureStudioSheet: View {
    @EnvironmentObject var jackManager:     JackManager
    @EnvironmentObject var patchbayManager: PatchbayManager
    @EnvironmentObject var studioManager:   StudioManager
    @Environment(\.dismiss) private var dismiss

    @State private var name:        String         = ""
    @State private var built:       Studio?        = nil
    @State private var needsInput:  [StudioClient] = []
    @State private var cliInputs:   [String: String] = [:]  // jackName → command

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Title
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(JM.accentAmber.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JM.accentAmber)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("capture_studio.title")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    Text("\(patchbayManager.connections.count) connexions · \(clientCount) clients")
                        .font(.system(size: 11))
                        .foregroundStyle(JM.textTertiary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Studio name field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("capture_studio.name.label")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(JM.textTertiary)
                        TextField(String(localized: "capture_studio.name.placeholder"), text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(JM.textPrimary)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgElevated)
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(JM.border, lineWidth: 1)))
                    }

                    // Jack snapshot preview
                    if let snap = built?.jackSnapshot {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("capture_studio.section.command")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(JM.textTertiary)
                            Text(snap.command)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(JM.accentCyan)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(JM.accentCyan.opacity(0.07))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(JM.accentCyan.opacity(0.25), lineWidth: 1)))
                        }
                    }

                    // Unknown CLI clients — ask user for launch commands
                    if !needsInput.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(JM.accentAmber)
                                Text("capture_studio.section.clients")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(JM.textSecondary)
                            }
                            Text("capture_studio.clients.hint")
                                .font(.system(size: 10))
                                .foregroundStyle(JM.textTertiary)

                            ForEach(needsInput) { client in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Circle().fill(JM.accentAmber).frame(width: 5, height: 5)
                                        Text(client.jackName)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(JM.textSecondary)
                                    }
                                    TextField(String(localized: "capture_studio.clients.placeholder"),
                                              text: Binding(
                                                get: { cliInputs[client.jackName] ?? "" },
                                                set: { cliInputs[client.jackName] = $0 }))
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(JM.textPrimary)
                                        .padding(.horizontal, 10).frame(height: 28)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgElevated)
                                            .overlay(RoundedRectangle(cornerRadius: 6)
                                                .stroke(JM.border, lineWidth: 1)))
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(JM.accentAmber.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(JM.accentAmber.opacity(0.18), lineWidth: 1)))
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.horizontal, 20)

            // Action buttons
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(JM.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgElevated)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(JM.border, lineWidth: 1)))

                Button("common.save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(JM.accentAmber.opacity(0.75))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(JM.accentAmber.opacity(0.4), lineWidth: 1)))
                    .disabled(name.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 380)
        .background(JM.bgBase)
        .onAppear { build() }
    }

    private var clientCount: Int {
        let unique = Set(patchbayManager.nodes.map {
            $0.id.replacingOccurrences(of: " (capture)", with: "")
                  .replacingOccurrences(of: " (playback)", with: "")
        })
        return unique.filter { $0 != "system" }.count
    }

    /// Builds the studio from the current patchbay state and identifies clients that
    /// need a manual CLI command entry.
    private func build() {
        name = String(format: String(localized: "capture_studio.default_name"), studioManager.studios.count + 1)
        let (studio, needed) = studioManager.buildStudio(
            name: name,
            nodes: patchbayManager.nodes,
            connections: patchbayManager.connections,
            jackManager: jackManager)
        built      = studio
        needsInput = needed
        for client in needed {
            cliInputs[client.jackName] = client.launchCommand ?? ""
        }
    }

    /// Merges any manually entered CLI commands, saves the studio, marks it as loaded, and dismisses.
    private func save() {
        guard var studio = built else { return }
        studio.name = name
        // Merge manually entered CLI commands into the client list
        var resolved = needsInput
        for i in resolved.indices {
            let cmd = cliInputs[resolved[i].jackName] ?? ""
            if !cmd.isEmpty {
                resolved[i].launchType    = .cli
                resolved[i].launchCommand = cmd
                resolved[i].autoLaunch    = false
            }
        }
        studio.clients += resolved
        try? studioManager.save(studio)
        studioManager.loadedStudio = studio
        dismiss()
    }
}

// MARK: - SaveChoiceSheet

/// Sheet presented when saving a modified studio: offers "update in place" or "save as new studio".
struct SaveChoiceSheet: View {
    let studio:      Studio
    let onOverwrite: () -> Void
    let onSaveAs:    (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saveAsName: String

    init(studio: Studio, onOverwrite: @escaping () -> Void, onSaveAs: @escaping (String) -> Void) {
        self.studio      = studio
        self.onOverwrite = onOverwrite
        self.onSaveAs    = onSaveAs
        self._saveAsName = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(JM.accentAmber.opacity(0.2))
                        .frame(width: 32, height: 32)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JM.accentAmber)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("save_choice.title")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    Text(verbatim: String(format: String(localized: "save_choice.subtitle"), studio.name))
                        .font(.system(size: 11))
                        .foregroundStyle(JM.textSecondary)
                }
            }
            .padding(.bottom, 20)

            // Option 1: update the current studio in place
            VStack(alignment: .leading, spacing: 6) {
                Text("save_choice.section.update").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(JM.textTertiary)
                Button {
                    onOverwrite(); dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 10))
                        Text(verbatim: String(format: String(localized: "save_choice.button.update"), studio.name))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(JM.accentAmber.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(JM.accentAmber.opacity(0.4), lineWidth: 1)))
                    .foregroundStyle(JM.accentAmber)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.bottom, 16)

            // Option 2: save as a new studio
            VStack(alignment: .leading, spacing: 8) {
                Text("save_choice.section.new").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(JM.textTertiary)
                HStack(spacing: 8) {
                    TextField(String(localized: "save_choice.new.placeholder"), text: $saveAsName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(JM.bgField)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(JM.border, lineWidth: 1)))
                    Button {
                        let name = saveAsName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        onSaveAs(name); dismiss()
                    } label: {
                        Text("common.create")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(JM.accentAmber.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(JM.accentAmber.opacity(0.4), lineWidth: 1)))
                            .foregroundStyle(JM.accentAmber)
                    }
                    .buttonStyle(.plain)
                    .disabled(saveAsName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.bottom, 20)

            // Cancel
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(JM.textTertiary)
            }
        }
        .padding(24)
        .frame(width: 390)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
}

// MARK: - ConfigHeaderView

/// Top header bar: contextual title, patchbay toolbar (tidy, collapse, zoom, refresh,
/// transport toggle), "Save as Studio" button, Audio MIDI Setup shortcut, log panel
/// toggle, and the Start/Stop Jack button.
struct ConfigHeaderView: View {
    let selection: SidebarNavItem
    let vpScale:   CGFloat
    @Binding var vpOffset: CGSize
    @Binding var vpScaleBinding: CGFloat
    @EnvironmentObject var jackManager:     JackManager
    @EnvironmentObject var patchbayManager: PatchbayManager
    @EnvironmentObject var studioManager:   StudioManager

    let canvasSize: CGSize

    @State private var showSaveChoiceSheet = false
    @State private var hoveredBtn: String?  = nil

    /// `true` when the loaded studio differs from the current patchbay state
    /// (clients, connections, or node positions changed by more than 2 pt).
    private var isModified: Bool {
        guard let loaded = studioManager.loadedStudio else { return false }
        // Jack clients (app opened / closed)
        let currentClients = Set(patchbayManager.nodes.map {
            $0.id.replacingOccurrences(of: " (capture)", with: "")
               .replacingOccurrences(of: " (playback)", with: "")
        })
        let savedClients = Set(loaded.clients.map { $0.jackName })
        if currentClients != savedClients { return true }
        // Connections
        let currentConns = Set(patchbayManager.connections.map { "\($0.from)→\($0.to)" })
        let savedConns   = Set(loaded.connections.map { "\($0.from)→\($0.to)" })
        if currentConns != savedConns { return true }
        // Node positions (2 pt threshold to absorb floating-point noise)
        for savedPos in loaded.nodePositions {
            if let node = patchbayManager.nodes.first(where: { $0.id == savedPos.id }) {
                if abs(node.position.x - savedPos.x) > 2 || abs(node.position.y - savedPos.y) > 2 {
                    return true
                }
            }
        }
        return false
    }

    /// Fits all patchbay nodes into the visible canvas with padding, animating scale and offset.
    private func recenterCanvas() {
        guard !patchbayManager.nodes.isEmpty else { return }
        let padding: CGFloat = 60

        let minX = patchbayManager.nodes.map { $0.position.x }.min()!
        let minY = patchbayManager.nodes.map { $0.position.y }.min()!
        let maxX = patchbayManager.nodes.map { $0.position.x + 210 }.max()!
        let maxY = patchbayManager.nodes.map {
            $0.position.y + ($0.isCollapsed ? 46 : 46 + CGFloat(max($0.inputCount, $0.outputCount)) * 21 + 6)
        }.max()!

        let contentW = maxX - minX
        let contentH = maxY - minY
        guard contentW > 0, contentH > 0 else { return }

        let scaleX = (canvasSize.width  - padding * 2) / contentW
        let scaleY = (canvasSize.height - padding * 2) / contentH
        let fitScale = min(scaleX, scaleY, 1.5)

        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        let newOffX = canvasSize.width  / 2 - cx * fitScale
        let newOffY = canvasSize.height / 2 - cy * fitScale

        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            vpScaleBinding = fitScale
            vpOffset       = CGSize(width: newOffX, height: newOffY)
        }
    }

    /// Resets the viewport scale to 1.0, keeping the canvas centre fixed on screen.
    private func resetZoom() {
        // Zoom to 1.0 centred on the canvas midpoint
        let pt = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let nx = pt.x - (pt.x - vpOffset.width)  * (1.0 / vpScale)
        let ny = pt.y - (pt.y - vpOffset.height) * (1.0 / vpScale)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            vpScaleBinding = 1.0
            vpOffset       = CGSize(width: nx, height: ny)
        }
    }

    var body: some View {
        HStack(spacing: 8) {

            // Contextual title
            VStack(alignment: .leading, spacing: 2) {
                if selection == .patchbay {
                    Text("common.patchbay")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    HStack(spacing: 8) {
                        Text(verbatim: String(format: String(localized: "header.clients_connections"),
                                             patchbayManager.nodes.count,
                                             patchbayManager.connections.count))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(JM.textTertiary)
                        legendItem(color: Color(hex: "#4ade80"), label: String(localized: "header.filter.audio"))
                        legendItem(color: Color(hex: "#c084fc"), label: String(localized: "header.filter.midi"))
                        legendItem(color: Color(hex: "#fb923c"), label: String(localized: "header.filter.cv"))
                    }
                } else {
                    Text("header.tab.config")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    HStack(spacing: 6) {
                        Text(jackManager.jackExecutableURL?.path ?? String(localized: "header.status.exec_missing"))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(jackManager.jackExecutableURL != nil ? JM.textTertiary : JM.accentRed)

                        if jackManager.jackInstalled,
                           let installed = jackManager.installedJackVersion {
                            Text("·")
                                .font(.system(size: 9.5))
                                .foregroundStyle(JM.textTertiary.opacity(0.4))

                            if jackManager.jackUpdateAvailable,
                               let latest = jackManager.latestJackVersion {
                                Button {
                                    NSWorkspace.shared.open(
                                        URL(string: "https://github.com/jackaudio/jack2-releases/releases")!)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.system(size: 9))
                                        Text("\(installed) → \(latest) ↗")
                                            .font(.system(size: 9.5))
                                    }
                                    .foregroundStyle(JM.accentAmber)
                                }
                                .buttonStyle(.plain)
                                .help("header.status.update_available")
                            } else {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(JM.accentGreen.opacity(0.6))
                                    Text(installed)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(JM.textTertiary)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 18) {

            // ── Patchbay toolbar (patchbay tab only) ─────────────────────────
            if selection == .patchbay {
                HStack(spacing: 8) {
                    Button {
                        let ids = patchbayManager.selectedNodeIds.isEmpty
                            ? nil : Array(patchbayManager.selectedNodeIds)
                        let vp = patchbayManager.tidy(nodeIds: ids,
                                                      canvasSize: canvasSize,
                                                      currentScale: vpScale)
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            vpScaleBinding = vp.scale
                            vpOffset       = vp.offset
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                                .font(.system(size: 14))
                                .foregroundStyle(hoveredBtn == "tidy" ? JM.textPrimary : JM.textTertiary)
                                .frame(width: 24, height: 24)
                            if !patchbayManager.selectedNodeIds.isEmpty {
                                Text("\(patchbayManager.selectedNodeIds.count)")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor))
                                    .offset(x: 7, y: -5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredBtn = $0 ? "tidy" : nil }
                    .help(patchbayManager.selectedNodeIds.isEmpty
                          ? String(localized: "toolbar.tidy.all")
                          : String(format: String(localized: "toolbar.tidy.selected"),
                                   patchbayManager.selectedNodeIds.count)) // TODO: plurals - Étape 6

                    Rectangle().fill(JM.borderFaint).frame(width: 0.5).frame(maxHeight: .infinity)

                    // ── Collapse / Expand selected nodes ─────────────────────
                    let selectedNodes     = patchbayManager.nodes.filter { patchbayManager.selectedNodeIds.contains($0.id) }
                    let collapsedCount    = selectedNodes.filter { $0.isCollapsed }.count
                    let nonCollapsedCount = selectedNodes.count - collapsedCount
                    let willCollapse      = nonCollapsedCount >= collapsedCount
                    Button { patchbayManager.toggleCollapseSelected() } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: willCollapse
                                  ? "rectangle.compress.vertical"
                                  : "rectangle.expand.vertical")
                                .font(.system(size: 14))
                                .foregroundStyle(
                                    patchbayManager.selectedNodeIds.isEmpty
                                        ? JM.textTertiary.opacity(0.35)
                                        : (hoveredBtn == "collapsesel" ? JM.textPrimary : JM.textTertiary)
                                )
                                .frame(width: 24, height: 24)
                            if !patchbayManager.selectedNodeIds.isEmpty {
                                Text("\(patchbayManager.selectedNodeIds.count)")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor))
                                    .offset(x: 7, y: -5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(patchbayManager.selectedNodeIds.isEmpty)
                    .onHover { hoveredBtn = $0 ? "collapsesel" : nil }
                    .help(patchbayManager.selectedNodeIds.isEmpty
                          ? String(localized: "toolbar.collapse.no_selection")
                          : willCollapse
                              ? String(format: String(localized: "toolbar.collapse.action"),
                                       patchbayManager.selectedNodeIds.count) // TODO: plurals - Étape 6
                              : String(format: String(localized: "toolbar.expand.action"),
                                       patchbayManager.selectedNodeIds.count)) // TODO: plurals - Étape 6

                    Rectangle().fill(JM.borderFaint).frame(width: 0.5).frame(maxHeight: .infinity)

                    Button { recenterCanvas() } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 14))
                            .foregroundStyle(hoveredBtn == "center" ? JM.textPrimary : JM.textTertiary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredBtn = $0 ? "center" : nil }
                    .help("toolbar.recenter")

                    Rectangle().fill(JM.borderFaint).frame(width: 0.5).frame(maxHeight: .infinity)

                    Button { resetZoom() } label: {
                        Image(systemName: "1.magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(
                                abs(vpScale - 1.0) < 0.01
                                    ? JM.textTertiary.opacity(0.35)
                                    : (hoveredBtn == "zoom100" ? JM.textPrimary : JM.textTertiary)
                            )
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(abs(vpScale - 1.0) < 0.01)
                    .onHover { hoveredBtn = $0 ? "zoom100" : nil }
                    .help("toolbar.zoom_reset")

                    Rectangle().fill(JM.borderFaint).frame(width: 0.5).frame(maxHeight: .infinity)

                    Button {
                        patchbayManager.forceRefresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            patchbayManager.syncConnections()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundStyle(hoveredBtn == "sync" ? JM.textPrimary : JM.textTertiary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredBtn = $0 ? "sync" : nil }
                    .disabled(!patchbayManager.isConnected)
                    .help("toolbar.refresh")

                    // ── Transport toggle ──────────────────────────────────────
                    if patchbayManager.isConnected {
                        Rectangle().fill(JM.borderFaint).frame(width: 0.5).frame(maxHeight: .infinity)
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                patchbayManager.showTransportBar.toggle()
                            }
                        } label: {
                            Image(systemName: "metronome")
                                .font(.system(size: 14))
                                .foregroundStyle(
                                    patchbayManager.showTransportBar
                                        ? JM.accentTeal
                                        : (hoveredBtn == "transport" ? JM.textPrimary : JM.textTertiary)
                                )
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .onHover { hoveredBtn = $0 ? "transport" : nil }
                        .help(patchbayManager.showTransportBar
                              ? String(localized: "toolbar.transport.hide")
                              : String(localized: "toolbar.transport.show"))
                    }
                }
                .frame(height: 40)
                .padding(.horizontal, 8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(JM.borderFaint, lineWidth: 1))

                // ── Studio button (standalone) ────────────────────────────
                HStack(spacing: 0) {
                    Button {
                        if isModified {
                            showSaveChoiceSheet = true
                        } else {
                            patchbayManager.showSaveStudioDialog = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isModified ? "square.and.arrow.down" : "plus")
                                .font(.system(size: 9))
                            Text("header.button.save_studio")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [JM.accentAmber.opacity(0.42), JM.accentAmber.opacity(0.22)],
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(JM.accentAmber.opacity(0.4), lineWidth: 1)))
                        .foregroundStyle(JM.textPrimary)
                        .brightness(hoveredBtn == "studio" ? 0.1 : 0)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredBtn = $0 ? "studio" : nil }
                    .disabled(!patchbayManager.isConnected ||
                              (studioManager.loadedStudio != nil && !isModified))
                    .opacity(patchbayManager.isConnected &&
                             !(studioManager.loadedStudio != nil && !isModified) ? 1 : 0.35)
                    .sheet(isPresented: $showSaveChoiceSheet) {
                        if let loaded = studioManager.loadedStudio {
                            SaveChoiceSheet(
                                studio: loaded,
                                onOverwrite: {
                                    let (built, _) = studioManager.buildStudio(
                                        name: loaded.name,
                                        nodes: patchbayManager.nodes,
                                        connections: patchbayManager.connections,
                                        jackManager: jackManager)
                                    var updated = loaded
                                    updated.clients = built.clients.map { builtClient in
                                        loaded.clients.first(where: { $0.jackName == builtClient.jackName }) ?? builtClient
                                    }
                                    updated.connections   = built.connections
                                    updated.nodePositions = built.nodePositions
                                    updated.jackSnapshot  = built.jackSnapshot ?? loaded.jackSnapshot
                                    try? studioManager.save(updated)
                                    studioManager.loadedStudio = updated
                                },
                                onSaveAs: { name in
                                    let (built, _) = studioManager.buildStudio(
                                        name: name,
                                        nodes: patchbayManager.nodes,
                                        connections: patchbayManager.connections,
                                        jackManager: jackManager)
                                    var newStudio = built
                                    newStudio.clients = built.clients.map { builtClient in
                                        loaded.clients.first(where: { $0.jackName == builtClient.jackName }) ?? builtClient
                                    }
                                    try? studioManager.save(newStudio)
                                    studioManager.loadedStudio = newStudio
                                }
                            )
                        }
                    }
                }
            }

            // ── Audio MIDI Setup shortcut ───────────────────────────────────
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
            } label: {
                Image(systemName: "pianokeys")
                    .font(.system(size: 14))
                    .foregroundStyle(hoveredBtn == "midi" ? JM.textPrimary : JM.textTertiary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(JM.bgBase))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(JM.borderFaint, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hoveredBtn = $0 ? "midi" : nil }
            .help("header.button.audio_midi")

            // ── Jack log panel toggle ───────────────────────────────────────
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    jackManager.showLogPanel.toggle()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "terminal")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            jackManager.hasWarning   ? JM.accentAmber :
                            jackManager.showLogPanel ? JM.accentIndigo :
                            hoveredBtn == "logs"     ? JM.textPrimary : JM.textTertiary)
                    if jackManager.hasWarning {
                        Circle().fill(JM.accentAmber).frame(width: 5, height: 5).offset(x: 5, y: -5)
                    }
                }
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(JM.bgBase))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(JM.borderFaint, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hoveredBtn = $0 ? "logs" : nil }
            .help("header.button.logs")

            // ── Start / Stop Jack button ────────────────────────────────────
            if jackManager.isRunning {
                Button { if let gs = jackManager.gracefulStop { gs() } else { jackManager.stopJack() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("header.button.stop_jack").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 13).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [JM.accentRed.opacity(0.42), JM.accentRed.opacity(0.22)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(JM.accentRed.opacity(0.5), lineWidth: 1)))
                    .foregroundStyle(JM.textPrimary)
                    .shadow(color: JM.btnStopGlow, radius: 10, y: 2)
                    .brightness(hoveredBtn == "startstop" ? 0.1 : 0)
                }
                .buttonStyle(.plain)
                .onHover { hoveredBtn = $0 ? "startstop" : nil }
            } else {
                Button { jackManager.savePreferences(); jackManager.startJack() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("header.button.start_jack").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 13).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [JM.accentGreen.opacity(0.42), JM.accentGreen.opacity(0.22)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(JM.accentGreen.opacity(0.5), lineWidth: 1)))
                    .foregroundStyle(JM.textPrimary)
                    .shadow(color: JM.btnStartGlow, radius: 10, y: 2)
                    .brightness(hoveredBtn == "startstop" ? 0.1 : 0)
                }
                .buttonStyle(.plain)
                .onHover { hoveredBtn = $0 ? "startstop" : nil }
                .disabled(!jackManager.jackInstalled)
                .opacity(jackManager.jackInstalled ? 1.0 : 0.35)
            }

            } // HStack(spacing: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(JM.bgBase)
    }

    /// Small coloured line + text legend item used in the patchbay title bar.
    @ViewBuilder
    func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 2)
            Text(label).font(.system(size: 9)).foregroundStyle(JM.textTertiary)
        }
    }
}

// MARK: - ConfigBodyView

/// Scrollable body of the Configuration tab: device pickers, audio settings,
/// option toggles, channel limiter, and the generated Jack command preview.
struct ConfigBodyView: View {
    @EnvironmentObject var jackManager:  JackManager
    @EnvironmentObject var audioManager: CoreAudioManager

    @AppStorage("hideAggregateAlert")  var hideAggregateAlert  = false
    @AppStorage("hideClockDriftAlert") var hideClockDriftAlert = false


    let bufferSizes = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096]

    var separatorGradient: some View {
        LinearGradient(colors: [Color.clear, Color.white.opacity(0.12), Color.clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1).padding(.leading, 38)
    }

    var maxInChannels: Int {
        guard !jackManager.prefs.inputDeviceUID.isEmpty else { return 0 }
        return audioManager.inputDevices.first(where: { $0.uid == jackManager.prefs.inputDeviceUID })?.inputChannels ?? 0
    }
    var maxOutChannels: Int {
        guard !jackManager.prefs.outputDeviceUID.isEmpty else { return 0 }
        return audioManager.outputDevices.first(where: { $0.uid == jackManager.prefs.outputDeviceUID })?.outputChannels ?? 0
    }

    var compatibleRates: [Double] {
        audioManager.compatibleSampleRates(
            inputUID:  jackManager.prefs.inputDeviceUID,
            outputUID: jackManager.prefs.outputDeviceUID)
    }

    /// True only when input and output are genuinely different physical hardware.
    /// Built-in mic + built-in speaker count as the same hardware (internal audio codec).
    var areDifferentPhysicalDevices: Bool {
        let inUID  = jackManager.prefs.inputDeviceUID
        let outUID = jackManager.prefs.outputDeviceUID
        guard !inUID.isEmpty, !outUID.isEmpty else { return false }
        if inUID == outUID { return false }
        let inInfo  = audioManager.allDevices.first { $0.uid == inUID }
        let outInfo = audioManager.allDevices.first { $0.uid == outUID }
        if inInfo?.isBuiltIn == true && outInfo?.isBuiltIn == true { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                
                // Lock banner shown while Jack is running
                if jackManager.isRunning {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(JM.accentAmber)
                        Text("config.locked_banner")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(JM.accentAmber)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(JM.accentAmber.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Audio devices — icon without badge square
                JMGroup(icon: "hifispeaker.2.fill",
                        iconColor: JM.groupDevices,
                        title: String(localized: "config.group.devices")) {
                    VStack(spacing: 8) {
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(JM.accentCyan).frame(width: 14)
                                Text("common.input").font(.system(size: 11)).foregroundStyle(JM.textSecondary)
                            }
                            .frame(width: 72, alignment: .leading)
                            JMPopUpButton(
                                options: [(String(localized: "config.input.empty"), "")] +
                                    audioManager.inputDevices.map { ("\($0.name) (\($0.inputChannels) ch.)", $0.uid) },
                                selection: $jackManager.prefs.inputDeviceUID
                            )
                            .frame(height: 26)
                            .onChange(of: jackManager.prefs.inputDeviceUID) { _, v in
                                jackManager.savedInputDeviceName =
                                    audioManager.inputDevices.first { $0.uid == v }?.name ?? ""
                                if let info = audioManager.allDevices.first(where: { $0.uid == v }), info.isAggregate {
                                    // Aggregate input: force output to the same device.
                                    // alreadyForced = true when output was already set to this UID
                                    // (triggered by the output onChange cascading here — skip alert).
                                    let alreadyForced = jackManager.prefs.outputDeviceUID == v
                                    jackManager.prefs.outputDeviceUID = info.outputChannels > 0 ? v : ""
                                    if !alreadyForced && !hideAggregateAlert { presentAggregateAlert() }
                                } else {
                                    // Non-aggregate input: clear output if it was previously set to an aggregate
                                    let outUID = jackManager.prefs.outputDeviceUID
                                    if let outInfo = audioManager.allDevices.first(where: { $0.uid == outUID }), outInfo.isAggregate {
                                        jackManager.prefs.outputDeviceUID = ""
                                    }
                                }
                                adjustSampleRateIfNeeded(); jackManager.savePreferences()
                            }
                        }
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(JM.accentViolet).frame(width: 14)
                                Text("common.output").font(.system(size: 11)).foregroundStyle(JM.textSecondary)
                            }
                            .frame(width: 72, alignment: .leading)
                            JMPopUpButton(
                                options: [(String(localized: "config.output.empty"), "")] +
                                    audioManager.outputDevices.map { ("\($0.name) (\($0.outputChannels) ch.)", $0.uid) },
                                selection: $jackManager.prefs.outputDeviceUID
                            )
                            .frame(height: 26)
                            .onChange(of: jackManager.prefs.outputDeviceUID) { _, v in
                                jackManager.savedOutputDeviceName =
                                    audioManager.outputDevices.first { $0.uid == v }?.name ?? ""
                                if let info = audioManager.allDevices.first(where: { $0.uid == v }), info.isAggregate {
                                    // Aggregate output: force input to the same device.
                                    // alreadyForced = true when input was already set to this UID
                                    // (triggered by the input onChange cascading here — skip alert).
                                    let alreadyForced = jackManager.prefs.inputDeviceUID == v
                                    jackManager.prefs.inputDeviceUID = info.inputChannels > 0 ? v : ""
                                    if !alreadyForced && !hideAggregateAlert { presentAggregateAlert() }
                                } else {
                                    // Non-aggregate output: clear input if it was previously set to an aggregate
                                    let inUID = jackManager.prefs.inputDeviceUID
                                    if let inInfo = audioManager.allDevices.first(where: { $0.uid == inUID }), inInfo.isAggregate {
                                        jackManager.prefs.inputDeviceUID = ""
                                    }
                                }
                                adjustSampleRateIfNeeded(); jackManager.savePreferences()
                            }
                        }
                    }
                }
                .disabled(jackManager.isRunning)
                .opacity(jackManager.isRunning ? 0.5 : 1.0)

                // Audio (sample rate / buffer) — icon without badge square
                JMGroup(icon: "waveform",
                        iconColor: JM.groupAudio,
                        title: String(localized: "config.group.audio")) {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            JMParamCard(label: "Sample rate") {
                                JMPopUpButton(
                                    options: compatibleRates.map { (formatSR($0), $0) },
                                    selection: $jackManager.prefs.sampleRate
                                )
                                .frame(height: 26)
                                .onChange(of: jackManager.prefs.sampleRate) { _, _ in jackManager.savePreferences() }
                            }
                            JMParamCard(label: "Buffer size") {
                                JMPopUpButton(
                                    options: bufferSizes.map { ("\($0) frames", $0) },
                                    selection: $jackManager.prefs.bufferSize
                                )
                                .frame(height: 26)
                                .onChange(of: jackManager.prefs.bufferSize) { _, _ in jackManager.savePreferences() }
                            }
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(JM.textTertiary)
                            Text("config.latency").font(.system(size: 11)).foregroundStyle(JM.textTertiary)
                            Text(String(format: "%.1f ms", jackManager.prefs.theoreticalLatency))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(JM.accentAmber)
                        }
                    }
                }
                .disabled(jackManager.isRunning)
                .opacity(jackManager.isRunning ? 0.5 : 1.0)

                // Options (hog mode, clock drift, MIDI, channel limiter) — icon without badge square
                JMGroup(icon: "slider.horizontal.3",
                        iconColor: JM.groupOptions,
                        title: String(localized: "config.group.options")) {
                    VStack(spacing: 0) {
                        JMToggleRow(icon: "lock.fill",
                                    iconBg: JM.tintRed, iconColor: JM.accentRed,
                                    label: String(localized: "config.hog_mode.label"),
                                    sub: String(localized: "config.hog_mode.description"),
                                    value: $jackManager.prefs.hogMode)
                            .onChange(of: jackManager.prefs.hogMode) { _, _ in jackManager.savePreferences() }
                        separatorGradient
                        JMToggleRow(icon: "clock.arrow.2.circlepath",
                                    iconBg: JM.tintAmber, iconColor: JM.accentAmber,
                                    label: String(localized: "config.clock_drift.label"),
                                    sub: String(localized: "config.clock_drift.description"),
                                    value: $jackManager.prefs.clockDrift)
                            .disabled(!areDifferentPhysicalDevices)
                            .opacity(!areDifferentPhysicalDevices ? 0.4 : 1.0)
                            .onChange(of: jackManager.prefs.clockDrift) { _, on in
                                if on && areDifferentPhysicalDevices && !hideClockDriftAlert {
                                    presentClockDriftAlert()
                                }
                                jackManager.savePreferences()
                            }
                            .onChange(of: areDifferentPhysicalDevices) { _, isDiff in
                                if !isDiff {
                                    jackManager.prefs.clockDrift = false
                                    jackManager.savePreferences()
                                }
                            }
                        separatorGradient
                        JMToggleRow(icon: "pianokeys",
                                    iconBg: JM.tintIndigo, iconColor: JM.accentIndigo,
                                    label: String(localized: "config.midi.label"),
                                    sub: String(localized: "config.midi.description"),
                                    value: $jackManager.prefs.midiEnabled)
                            .disabled(true)
                            .opacity(0.4)
                            .onChange(of: jackManager.prefs.midiEnabled) { _, _ in jackManager.savePreferences() }

                        // ── Channel limiter ─────────────────────────────────
                        separatorGradient
                        ChannelPickerToggleRow(
                            maxIn:  maxInChannels,
                            maxOut: maxOutChannels,
                            selectedIn:  $jackManager.prefs.selectedInChannels,
                            selectedOut: $jackManager.prefs.selectedOutChannels,
                            enabled:     $jackManager.prefs.limitChannels
                        )
                        .onChange(of: jackManager.prefs.limitChannels)       { _, _ in jackManager.savePreferences() }
                        .onChange(of: jackManager.prefs.selectedInChannels)  { _, _ in jackManager.savePreferences() }
                        .onChange(of: jackManager.prefs.selectedOutChannels) { _, _ in jackManager.savePreferences() }

                    }
                }
                .disabled(jackManager.isRunning)
                .opacity(jackManager.isRunning ? 0.5 : 1.0)

                // Generated command — or installation instructions if Jack is not installed
                let cmdTitle: String = {
                    if jackManager.jackInstalled { return String(localized: "config.command_box.generated") }
                    switch jackManager.selectedInstallMethod {
                    case .homebrew: return String(localized: "config.command_box.install_homebrew")
                    case .pkg:      return String(localized: "config.command_box.install_link")
                    case nil:       return String(localized: "config.command_box.install_required")
                    }
                }()

                let cmdString: String = {
                    if jackManager.jackInstalled {
                        return jackManager.prefs.commandPreview(
                            executableName: jackManager.jackExecutableURL?.lastPathComponent ?? "jackdmp",
                            maxInChannels:  maxInChannels,
                            maxOutChannels: maxOutChannels
                        )
                    }
                    switch jackManager.selectedInstallMethod {
                    case .homebrew: return "brew install jack"
                    case .pkg:      return "https://github.com/jackaudio/jack2-releases/releases"
                    case nil:       return String(localized: "config.command_box.select_method")
                    }
                }()

                let cmdGlowColor: Color? = {
                    guard !jackManager.jackInstalled else { return nil }
                    switch jackManager.selectedInstallMethod {
                    case .homebrew: return JM.accentGreen
                    case .pkg:      return Color(hex: "#3b82f6")
                    case nil:       return nil
                    }
                }()

                JMGroup(icon: jackManager.jackInstalled ? "terminal" : "exclamationmark.triangle",
                        iconColor: jackManager.jackInstalled ? JM.accentGreen : JM.accentAmber,
                        title: cmdTitle) {
                    JMCommandBox(command: cmdString)
                }
                .overlay(
                    Group {
                        if let c = cmdGlowColor {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(c, lineWidth: 1.5)
                                .shadow(color: c.opacity(0.55), radius: 10)
                        }
                    }
                )
                .animation(.easeInOut(duration: 0.25), value: jackManager.jackInstalled)
                .animation(.easeInOut(duration: 0.25), value: jackManager.selectedInstallMethod)

            }
            .padding(16)
        }
        .background(JM.bgBase)
    }

    /// Shows an informational alert when the user selects a macOS aggregate device,
    /// suggesting that hardware clock sync be configured in Audio MIDI Setup.
    private func presentAggregateAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.aggregate.title")
        alert.informativeText = String(localized: "alert.aggregate.message")
        alert.addButton(withTitle: String(localized: "alert.aggregate.button.open"))
        alert.addButton(withTitle: String(localized: "common.ok"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "alert.aggregate.suppress")
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { hideAggregateAlert = true }
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        }
    }

    /// Shows an informational alert when the user enables clock drift correction,
    /// suggesting a hardware aggregate device as a more robust alternative.
    private func presentClockDriftAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.clock_drift.title")
        alert.informativeText = String(localized: "alert.clock_drift.message")
        alert.addButton(withTitle: String(localized: "alert.clock_drift.button.open"))
        alert.addButton(withTitle: String(localized: "common.ok"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "alert.clock_drift.suppress")
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { hideClockDriftAlert = true }
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        }
    }

    /// Resets the selected sample rate to a compatible value (preferring 48 kHz, then 44.1 kHz)
    /// when the current rate is no longer supported by the selected device pair.
    func adjustSampleRateIfNeeded() {
        let rates = audioManager.compatibleSampleRates(
            inputUID:  jackManager.prefs.inputDeviceUID,
            outputUID: jackManager.prefs.outputDeviceUID)
        if !rates.contains(jackManager.prefs.sampleRate) {
            jackManager.prefs.sampleRate =
                rates.first { $0 == 48000 } ?? rates.first { $0 == 44100 } ?? rates.first ?? 48000
        }
    }
    /// Formats a sample rate as a human-readable string (e.g. `"48000 Hz"`).
    func formatSR(_ sr: Double) -> String { String(format: "%.0f Hz", sr) }
}

// MARK: - JMGroup

/// Grouped settings card: small icon + all-caps title header, then an arbitrary content view.
/// Uses a subtle gradient background and a `gradientBorder`.
struct JMGroup<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(JM.textTertiary)
                    .tracking(0.6)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)

            LinearGradient(
                colors: [Color.clear, Color.white.opacity(0.18), Color.clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)

            content()
                .padding(12)
        }
        .background(LinearGradient(
            colors: [Color(red: 0.075, green: 0.075, blue: 0.085),
                     Color(red: 0.10, green: 0.10, blue: 0.11)],
            startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .gradientBorder(cornerRadius: 10)
    }
}

/// Card-style container for a single configuration parameter (label on top, control below).
struct JMParamCard<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(JM.textTertiary)
            content()
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color(red: 0.12, green: 0.12, blue: 0.12)))
        .gradientBorder(cornerRadius: 7)
    }
}

/// Toggle row with a coloured icon badge, a main label, a subtitle, and a SwiftUI toggle.
struct JMToggleRow: View {
    let icon: String; let iconBg: Color; let iconColor: Color
    let label: String; let sub: String
    @Binding var value: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(iconBg).frame(width: 26, height: 26)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(JM.textPrimary.opacity(0.88))
                Text(sub).font(.system(size: 10)).foregroundStyle(JM.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $value)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .tint(JM.accentGreen)
        }
        .padding(.vertical, 8).padding(.horizontal, 2)
    }
}

/// Syntax-highlighted monospace box displaying a Jack command.
/// Highlights the executable name, flags (`-*`), and values with distinct colours.
/// Includes a copy-to-clipboard button.
struct JMCommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        let tokens = command.components(separatedBy: " ")
        let text = tokens.reduce(Text("")) { result, token in
            let t: Text
            if token == "jackdmp" || token == "jackd" {
                t = Text(token + " ").font(.system(size: 10, design: .monospaced)).foregroundColor(JM.cmdExec)
            } else if token.hasPrefix("-") {
                t = Text(token + " ").font(.system(size: 10, design: .monospaced)).foregroundColor(JM.cmdFlag)
            } else {
                t = Text(token + " ").font(.system(size: 10, design: .monospaced)).foregroundColor(JM.cmdValue)
            }
            return result + t
        }
        return text
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color(hex: "#111113")))
            .gradientBorder(cornerRadius: 7)
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(copied ? JM.accentGreen : .secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("common.copy_command")
            }
    }
}

// MARK: - LogPanelView

/// Slide-in panel (right edge) displaying Jack process log lines with level-based colouring.
struct LogPanelView: View {
    @EnvironmentObject var jackManager: JackManager

    var accentColor: Color {
        if jackManager.hasWarning { return JM.accentAmber }
        if jackManager.isRunning  { return JM.accentGreen }
        return JM.textTertiary
    }
    var statusIcon: String {
        if jackManager.hasWarning { return "exclamationmark.triangle.fill" }
        if jackManager.isRunning  { return "waveform.path.ecg" }
        return "waveform.path"
    }
    var statusText: String {
        if jackManager.hasWarning { return String(localized: "log.badge.warning") }
        if jackManager.isRunning  { return String(localized: "log.header.running") }
        return String(localized: "log.header.stopped")
    }

    var body: some View {
        HStack(spacing: 0) {
            accentColor.frame(width: 3)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accentColor)
                    Text(statusText)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accentColor)
                    Spacer()
                    if jackManager.isRunning {
                        HStack(spacing: 6) {
                            LogChip(icon: "waveform", color: accentColor,
                                    text: String(format: "%.0f Hz", jackManager.prefs.sampleRate))
                            LogChip(icon: "clock", color: JM.textTertiary,
                                    text: String(format: "%.1f ms", jackManager.prefs.theoreticalLatency))
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(accentColor.opacity(0.23))
                .overlay(alignment: .bottom) { Rectangle().fill(accentColor.opacity(0.3)).frame(height: 1) }

                HStack(spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(JM.textTertiary)
                    Text("log.panel.title").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(JM.textTertiary).tracking(1)
                    Spacer()
                    Button { jackManager.clearLogs() } label: {
                        Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(JM.textTertiary)
                    }.buttonStyle(.plain)
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            jackManager.showLogPanel = false
                        }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(JM.textTertiary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(JM.bgBase.opacity(0.88))
                .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(jackManager.logLines) { line in LogLineView(line: line).id(line.id) }
                            if jackManager.logLines.isEmpty {
                                Text("log.panel.empty")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(JM.textTertiary).padding(12)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollContentBackground(.hidden)
                    .background(JM.bgBase.opacity(0.77))
                    .onChange(of: jackManager.logLines.count) { _, _ in
                        if let last = jackManager.logLines.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .frame(width: 300)
        .overlay(alignment: .leading) { Rectangle().fill(JM.border).frame(width: 1) }
    }
}

/// Single log line rendered with an optional warning/error icon and level-appropriate colour.
struct LogLineView: View {
    let line: JackLogLine
    var textColor: Color {
        switch line.level {
        case .success: return JM.accentGreen
        case .warning: return JM.accentAmber
        case .error:   return JM.accentRed
        case .muted:   return JM.textTertiary
        case .info:    return JM.textSecondary
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if line.level == .warning || line.level == .error {
                Image(systemName: line.level == .warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .font(.system(size: 9)).foregroundStyle(textColor).padding(.top, 2).frame(width: 12)
            } else { Color.clear.frame(width: 12, height: 1) }
            Text(line.text)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(textColor)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background(line.level == .warning ? JM.accentAmber.opacity(0.07) :
                    line.level == .error   ? JM.accentRed.opacity(0.07)   : Color.clear)
    }
}

/// Compact icon + text chip shown in the log panel header.
struct LogChip: View {
    let icon: String; let color: Color; let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8)).foregroundStyle(color)
            Text(text).font(.system(size: 9)).foregroundStyle(JM.textTertiary).lineLimit(1)
        }
    }
}

// MARK: - ChannelPickerToggleRow

/// Composite row that combines a `JMToggleRow` with a "Modifier" button and a
/// `ChannelPickerSheet` for selecting which input/output channels Jack should expose.
struct ChannelPickerToggleRow: View {
    let maxIn:  Int
    let maxOut: Int
    @Binding var selectedIn:  [Int]
    @Binding var selectedOut: [Int]
    @Binding var enabled:     Bool
    @State private var showPicker = false

    private var summary: String {
        let inCount  = selectedIn.isEmpty  ? maxIn  : selectedIn.count
        let outCount = selectedOut.isEmpty ? maxOut : selectedOut.count
        var parts: [String] = []
        if maxIn  > 0 { parts.append("\(inCount) in") }
        if maxOut > 0 { parts.append("\(outCount) out") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        JMToggleRow(icon: "square.split.2x1",
                    iconBg: JM.tintTeal, iconColor: JM.accentTeal,
                    label: String(localized: "config.channels.label"),
                    sub: enabled ? summary : String(localized: "config.channels.description"),
                    value: $enabled)
            .onChange(of: enabled) { _, on in
                if on {
                    // Reset selection to all channels whenever the limiter is first enabled
                    if maxIn  > 0 { selectedIn  = Array(0..<maxIn) }
                    if maxOut > 0 { selectedOut = Array(0..<maxOut) }
                    showPicker = true
                }
            }
            .sheet(isPresented: $showPicker) {
                ChannelPickerSheet(
                    maxIn: maxIn, maxOut: maxOut,
                    selectedIn: $selectedIn, selectedOut: $selectedOut,
                    isPresented: $showPicker
                )
            }
        if enabled {
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Text("config.channels.button")
                        .font(.system(size: 10))
                }
                .foregroundStyle(JM.accentTeal)
                .padding(.leading, 38)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Modal sheet presenting LED-style channel selectors for input and output channels.
struct ChannelPickerSheet: View {
    let maxIn:   Int
    let maxOut:  Int
    @Binding var selectedIn:  [Int]
    @Binding var selectedOut: [Int]
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("channel_picker.title")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JM.textPrimary)
            if maxIn > 0 {
                ChannelLedRow(label: "Input", count: maxIn, selected: $selectedIn)
            }
            if maxOut > 0 {
                ChannelLedRow(label: "Output", count: maxOut, selected: $selectedOut)
            }
            HStack {
                Spacer()
                Button("common.confirm") { isPresented = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JM.accentGreen)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(JM.accentGreen.opacity(0.15)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(JM.accentGreen.opacity(0.3), lineWidth: 1))
            }
        }
        .padding(20)
        .background(JM.bgBase)
    }
}

/// Row of LED-style channel toggles. An empty `selected` array means all channels are active.
struct ChannelLedRow: View {
    let label:   String
    let count:   Int
    @Binding var selected: [Int]
    private let ledSize: CGFloat = 18
    private let ledGap:  CGFloat = 4

    /// Returns `true` when channel `ch` is active (selected or all-channels mode).
    private func isOn(_ ch: Int) -> Bool { selected.isEmpty || selected.contains(ch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(JM.textTertiary)
            HStack(spacing: ledGap) {
                ForEach(0..<count, id: \.self) { ch in
                    LedView(index: ch, isOn: isOn(ch))
                        .onTapGesture { toggle(ch) }
                }
            }
        }
    }

    private func toggle(_ ch: Int) {
        if selected.isEmpty { selected = Array(0..<count) }
        if selected.contains(ch) {
            guard selected.count > 1 else { return }  // minimum 1
            selected.removeAll { $0 == ch }
        } else {
            selected.append(ch)
        }
    }
}

/// Individual LED button: green + glow when active, muted when inactive.
private struct LedView: View {
    let index: Int
    let isOn:  Bool
    private let size: CGFloat = 18

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(isOn ? JM.accentGreen : JM.bgElevated)
                .overlay(Circle().stroke(isOn ? JM.accentGreen.opacity(0.5) : JM.borderFaint, lineWidth: 1))
                .shadow(color: isOn ? JM.accentGreen.opacity(0.55) : .clear, radius: 4)
                .frame(width: size, height: size)
            Text("\(index + 1)")
                .font(.system(size: 8))
                .foregroundStyle(isOn ? JM.accentGreen : JM.textTertiary)
        }
    }
}


// MARK: - StatusBarView

/// Bottom status bar: device names, sample rate, buffer size, latency, channel counts,
/// xrun counter (polled from the bridge every second), and active studio name.
struct StatusBarView: View {
    @EnvironmentObject var jackManager:     JackManager
    @EnvironmentObject var audioManager:    CoreAudioManager
    @EnvironmentObject var patchbayManager: PatchbayManager
    @EnvironmentObject var studioManager:   StudioManager

    @State private var displayedXrunCount: UInt32 = 0

    private var maxInChannels: Int {
        guard !jackManager.prefs.inputDeviceUID.isEmpty else { return 0 }
        return audioManager.inputDevices.first(where: { $0.uid == jackManager.prefs.inputDeviceUID })?.inputChannels ?? 0
    }
    private var maxOutChannels: Int {
        guard !jackManager.prefs.outputDeviceUID.isEmpty else { return 0 }
        return audioManager.outputDevices.first(where: { $0.uid == jackManager.prefs.outputDeviceUID })?.outputChannels ?? 0
    }

    /// Converts a sorted array of 0-based channel indices to a human-readable range string (1-based).
    /// e.g. [0,1,2,4,10] → "1-3, 5, 11"
    private func channelRangeString(_ indices: [Int]) -> String {
        let sorted = indices.sorted()
        var ranges: [String] = []
        var start = sorted.first.map { $0 + 1 } ?? 1
        var end   = start
        for ch in sorted.dropFirst() {
            let n = ch + 1
            if n == end + 1 { end = n }
            else {
                ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
                start = n; end = n
            }
        }
        ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
        return ranges.joined(separator: ", ")
    }

    private func channelChipText(selected: [Int], max: Int) -> String {
        let sel = selected.isEmpty ? Array(0..<max) : selected
        let count = sel.count
        if count == max { return "\(count)/\(max) ch" }
        let ranges = channelRangeString(sel)
        // TODO: plurals - Étape 6
        let label = count == 1 ? "canal" : "canaux"
        return "\(count)/\(max) ch (\(label) \(ranges))"
    }

    /// Mirrors `ConfigHeaderView.isModified` — true when the loaded studio differs from
    /// the current patchbay state (clients, connections, or node positions).
    private var isModified: Bool {
        guard let loaded = studioManager.loadedStudio else { return false }
        // Jack clients (app opened / closed)
        let currentClients = Set(patchbayManager.nodes.map {
            $0.id.replacingOccurrences(of: " (capture)", with: "")
               .replacingOccurrences(of: " (playback)", with: "")
        })
        let savedClients = Set(loaded.clients.map { $0.jackName })
        if currentClients != savedClients { return true }
        // Connections
        let currentConns = Set(patchbayManager.connections.map { "\($0.from)→\($0.to)" })
        let savedConns   = Set(loaded.connections.map { "\($0.from)→\($0.to)" })
        if currentConns != savedConns { return true }
        // Node positions (2 pt threshold to absorb floating-point noise)
        for savedPos in loaded.nodePositions {
            if let node = patchbayManager.nodes.first(where: { $0.id == savedPos.id }) {
                if abs(node.position.x - savedPos.x) > 2 || abs(node.position.y - savedPos.y) > 2 {
                    return true
                }
            }
        }
        return false
    }

    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            if !jackManager.savedInputDeviceName.isEmpty {
                SBChip(icon: "mic.fill", color: JM.accentCyan,
                       text: jackManager.savedInputDeviceName)
            }
            if !jackManager.savedOutputDeviceName.isEmpty {
                SBChip(icon: "speaker.wave.2.fill", color: JM.accentViolet,
                       text: jackManager.savedOutputDeviceName)
            }
            SBChip(icon: "waveform", color: JM.accentOrange,
                   text: String(format: "%.0f Hz", jackManager.prefs.sampleRate))
            SBChip(icon: "square.stack", color: JM.textTertiary,
                   text: "\(jackManager.prefs.bufferSize) buf")
            SBChip(icon: "clock", color: JM.accentAmber,
                   text: String(format: "%.1f ms", jackManager.prefs.theoreticalLatency))
            if maxInChannels > 0 {
                SBChip(icon: "mic.fill", color: JM.accentGreen,
                       text: channelChipText(selected: jackManager.prefs.limitChannels ? jackManager.prefs.selectedInChannels : [], max: maxInChannels) + " in")
            }
            if maxOutChannels > 0 {
                SBChip(icon: "speaker.wave.2.fill", color: JM.accentGreen,
                       text: channelChipText(selected: jackManager.prefs.limitChannels ? jackManager.prefs.selectedOutChannels : [], max: maxOutChannels) + " out")
            }
            
            // Xrun counter read from the bridge (atomic, near-zero overhead)
            if displayedXrunCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("\(displayedXrunCount) xruns")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                
                // Reset xrun counter
                Button {
                    patchbayManager.jackBridge.resetXrunCount()
                    displayedXrunCount = 0
                } label: {
                    Text("Reset")
                        .font(.system(size: 9))
                        .foregroundStyle(JM.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(JM.bgField))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Active studio name — far right
            if let studio = studioManager.loadedStudio {
                HStack(spacing: 5) {
                    if isModified {
                        Circle()
                            .fill(JM.accentCyan)
                            .frame(width: 5, height: 5)
                    }
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 9))
                        .foregroundStyle(isModified ? JM.accentCyan : JM.accentAmber)
                    Text(studio.name)
                        .font(.system(size: 10))
                        .foregroundStyle(isModified ? JM.accentCyan : JM.accentAmber)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(JM.bgBase)
        .onReceive(timer) { _ in
            // Poll xrun count from the bridge (atomic read, negligible overhead)
            if patchbayManager.isConnected {
                displayedXrunCount = patchbayManager.jackBridge.xrunCount
            }
        }
        .onChange(of: jackManager.isRunning) { _, _ in
            patchbayManager.jackBridge.resetXrunCount()
            displayedXrunCount = 0
        }
    }
}

/// Compact icon + text chip shown in the status bar.
struct SBChip: View {
    let icon: String; let color: Color; let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color)
            Text(text).font(.system(size: 10)).foregroundStyle(JM.textTertiary).lineLimit(1)
        }
    }
}

// MARK: - NodeBadgeSheet

/// Detail sheet for a patchbay node: shows system device info or running app metadata
/// (name, bundle path, modification date, PID).
struct NodeBadgeSheet: View {
    let node: PatchbayNode
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var jackManager: JackManager

    private let abbr: String
    private let badgeColor: Color
    private var isSystemNode:  Bool { node.id.hasPrefix("system") }
    private var isCaptureNode: Bool { node.id.hasSuffix("(capture)") }

    init(node: PatchbayNode) {
        self.node = node
        let a = BadgeUtils.abbrev(node.id)
        self.abbr = a
        self.badgeColor = BadgeUtils.color(a, fullName: node.id)
    }

    // MARK: - App node helpers

    /// Returns the running application matching this node's name, if any.
    private var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased() == node.id.lowercased()
        }
    }
    private var bundlePath: String? { runningApp?.bundleURL?.path }
    private var appModDate: Date? {
        guard let path = bundlePath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Node badge header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSystemNode
                              ? (isCaptureNode ? JM.accentCyan.opacity(0.18) : JM.accentPurple.opacity(0.18))
                              : badgeColor.opacity(0.22))
                        .frame(width: 38, height: 38)
                    if isSystemNode {
                        Image(systemName: isCaptureNode ? "mic.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isCaptureNode ? JM.accentCyan : JM.accentPurple)
                    } else {
                        Text(abbr)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(badgeColor)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.id)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    Text(verbatim: isSystemNode
                         ? String(localized: "node_badge.type.system")
                         : String(localized: "node_badge.type.client"))
                        .font(.system(size: 11))
                        .foregroundStyle(JM.textTertiary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(JM.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)

            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 10) {
                if isSystemNode {
                    systemNodeContent
                } else {
                    appNodeContent
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            Spacer(minLength: 0)
        }
        .frame(width: 360)
        .background(JM.bgBase)
        .gradientBorder(cornerRadius: 12)
    }

    // MARK: - System node content

    @ViewBuilder private var systemNodeContent: some View {
        let inputName  = jackManager.savedInputDeviceName.isEmpty
            ? String(localized: "node_badge.default_device") : jackManager.savedInputDeviceName
        let outputName = jackManager.savedOutputDeviceName.isEmpty
            ? String(localized: "node_badge.default_device") : jackManager.savedOutputDeviceName
        // Capture node: outputs → channels going into Jack; playback node: inputs → channels coming from Jack
        let channelCount = isCaptureNode ? node.outputs.count : node.inputs.count
        let channelLabel = isCaptureNode
            ? String(localized: "node_badge.channels.capture")
            : String(localized: "node_badge.channels.playback")
        let channelIcon  = isCaptureNode ? "arrow.right.circle" : "arrow.left.circle"
        let channelColor = isCaptureNode ? JM.accentCyan : JM.accentPurple

        if isCaptureNode {
            infoRow(icon: "mic.fill", color: JM.accentCyan, label: String(localized: "common.input"), value: inputName)
        } else {
            infoRow(icon: "speaker.wave.2.fill", color: JM.accentPurple, label: String(localized: "common.output"), value: outputName)
        }
        Divider()
        infoRow(icon: "waveform",   color: JM.accentAmber, label: "Sample rate",
                value: "\(Int(jackManager.prefs.sampleRate)) Hz")
        infoRow(icon: "memorychip", color: JM.accentAmber, label: "Buffer",
                value: "\(jackManager.prefs.bufferSize) frames")
        Divider()
        infoRow(icon: channelIcon, color: channelColor, label: channelLabel,
                value: "\(channelCount) ch")
    }

    // MARK: - App node content

    @ViewBuilder private var appNodeContent: some View {
        if let app = runningApp {
            // GUI application registered with NSWorkspace
            infoRow(icon: "app.fill", color: badgeColor,
                    label: String(localized: "node_badge.app.label.name"), value: app.localizedName ?? node.id)
            if let path = bundlePath {
                VStack(alignment: .leading, spacing: 4) {
                    rowLabel(icon: "folder", color: JM.accentAmber, label: String(localized: "node_badge.app.label.path"))
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(JM.textSecondary)
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
            if let date = appModDate {
                infoRow(icon: "clock", color: JM.accentTeal,
                        label: String(localized: "common.modified"), value: df.string(from: date))
            }
            if let pid = runningApp?.processIdentifier {
                infoRow(icon: "number", color: JM.textTertiary,
                        label: "PID", value: "\(pid)")
            }
        } else if let pid = ProcessHelper.findPID(forJackClient: node.id) {
            // CLI process — not visible to NSWorkspace, found via process table scan
            infoRow(icon: "terminal", color: badgeColor,
                    label: String(localized: "node_badge.app.label.type"), value: "Client CLI")
            if let path = ProcessHelper.executablePath(for: pid) {
                VStack(alignment: .leading, spacing: 4) {
                    rowLabel(icon: "folder", color: JM.accentAmber, label: String(localized: "node_badge.app.label.path"))
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(JM.textSecondary)
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
            if let args = ProcessHelper.commandLine(for: pid), args.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    rowLabel(icon: "terminal", color: JM.accentTeal, label: String(localized: "node_badge.app.label.command"))
                    Text(args.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(JM.textSecondary)
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
            infoRow(icon: "number", color: JM.textTertiary,
                    label: "PID", value: "\(pid)")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(JM.accentAmber)
                Text("node_badge.app.not_found")
                    .font(.system(size: 11))
                    .foregroundStyle(JM.textSecondary)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            rowLabel(icon: icon, color: color, label: label)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(JM.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func rowLabel(icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)).frame(width: 16, height: 16)
                Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(JM.textTertiary)
        }
    }
}

// MARK: - PatchbayPlaceholderView

/// Fallback view shown when the patchbay canvas is unavailable.
struct PatchbayPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48)).foregroundStyle(JM.textTertiary)
            Text("common.patchbay").font(.title2).foregroundStyle(JM.textSecondary)
            Text("À venir dans la prochaine session").font(.callout).foregroundStyle(JM.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(JM.bgBase)
    }
}

// MARK: - Gradient Border Modifier

extension View {
    /// Overlays a diagonal gradient border: dark corners → bright midpoint → dark corners.
    /// Inspired by the CSS technique: `linear-gradient(71deg, dark, accent, dark)`.
    func gradientBorder(cornerRadius: CGFloat, lineWidth: CGFloat = 1) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.08), location: 0),
                            .init(color: .white.opacity(0.28), location: 0.5),
                            .init(color: .white.opacity(0.08), location: 1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: lineWidth
                )
        )
    }
}

