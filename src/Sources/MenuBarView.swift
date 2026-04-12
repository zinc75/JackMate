//
//  MenuBarView.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Compact popover attached to the menu bar extra icon.
//  Shows Jack status, key configuration values, and quick Start/Stop actions.
//

import SwiftUI

// MARK: - MenuBarView

/// The root view displayed inside the menu bar extra popover.
///
/// Displays:
/// - App logo, Jack status indicator, and Start/Stop pill
/// - Selected devices, sample rate, buffer size, and theoretical latency
/// - "Show JackMate…" and "Quit" action rows
struct MenuBarView: View {
    @EnvironmentObject var jackManager:  JackManager
    @EnvironmentObject var audioManager: CoreAudioManager
    @State private var hoveredAction: String? = nil

    /// Accent colour reflecting the current Jack state.
    var statusColor: Color {
        if jackManager.isRunning { return JM.accentGreen }
        let state = jackManager.jackState
        if state == .starting || state == .stopping { return JM.accentAmber }
        return JM.accentRed
    }

    /// Short localised string describing the current Jack state.
    var statusText: String {
        if jackManager.isRunning { return String(localized: "common.jack_running") }
        let state = jackManager.jackState
        if state == .starting || state == .stopping { return String(localized: "common.jack_starting") }
        return String(localized: "common.jack_stopped")
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header: logo + status + Start/Stop pill ───────────────────
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(JM.bgElevated)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(JM.border, lineWidth: 1))
                        .frame(width: 28, height: 28)
                    Image(systemName: "waveform.path")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(JM.accentRed)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("JackMate")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JM.textPrimary)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                            .shadow(color: statusColor.opacity(0.7), radius: 3)
                        Text(statusText)
                            .font(.system(size: 10))
                            .foregroundStyle(JM.textTertiary)
                    }
                }
                Spacer()
                // Start / Stop pill
                if jackManager.isRunning {
                    Button {
                        if let gs = jackManager.gracefulStop { gs() } else { jackManager.stopJack() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill").font(.system(size: 8))
                            Text("menubar.action.stop_jack").font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [JM.accentRed.opacity(0.42), JM.accentRed.opacity(0.22)],
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(JM.accentRed.opacity(0.5), lineWidth: 1)))
                        .foregroundStyle(JM.textPrimary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { handleStartJack() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text("menubar.action.start_jack").font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [JM.accentGreen.opacity(0.42), JM.accentGreen.opacity(0.22)],
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(JM.accentGreen.opacity(0.5), lineWidth: 1)))
                        .foregroundStyle(JM.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(jackManager.jackExecutableURL == nil)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            LinearGradient(colors: [.clear, .white.opacity(0.14), .clear],
                           startPoint: .leading, endPoint: .trailing).frame(height: 1)

            // ── Configuration summary ─────────────────────────────────────
            VStack(alignment: .leading, spacing: 5) {
                if !jackManager.savedInputDeviceName.isEmpty {
                    MBInfoRow(icon: "mic.fill", color: JM.textTertiary,
                              text: jackManager.savedInputDeviceName)
                }
                if !jackManager.savedOutputDeviceName.isEmpty {
                    MBInfoRow(icon: "speaker.wave.2.fill", color: JM.textTertiary,
                              text: jackManager.savedOutputDeviceName)
                }
                MBInfoRow(icon: "waveform", color: JM.textTertiary,
                          text: String(format: "%.0f Hz", jackManager.prefs.sampleRate))
                MBInfoRow(icon: "square.stack", color: JM.textTertiary,
                          text: "\(jackManager.prefs.bufferSize) frames")
                MBInfoRow(icon: "clock", color: JM.textTertiary,
                          text: String(format: "%.1f ms", jackManager.prefs.theoreticalLatency))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            LinearGradient(colors: [.clear, .white.opacity(0.10), .clear],
                           startPoint: .leading, endPoint: .trailing).frame(height: 1)

            // ── Actions ───────────────────────────────────────────────────
            VStack(spacing: 0) {
                MBActionRow(id: "open", icon: "macwindow", label: String(localized: "menubar.action.show"),
                            color: JM.textSecondary, hovered: $hoveredAction) {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
                    // Notify ContentView so it can present the install sheet if needed
                    NotificationCenter.default.post(name: .mainWindowDidOpen, object: nil)
                }
                MBActionRow(id: "quit", icon: "power", label: String(localized: "menubar.action.quit"),
                            color: JM.accentRed, hovered: $hoveredAction) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 260)
    }

    // MARK: - Start Jack interception

    private var isJackAggregatePending: Bool {
        let inUID  = jackManager.prefs.inputDeviceUID
        let outUID = jackManager.prefs.outputDeviceUID
        guard !inUID.isEmpty, !outUID.isEmpty, inUID != outUID else { return false }
        let inDev  = audioManager.allDevices.first { $0.uid == inUID }
        let outDev = audioManager.allDevices.first { $0.uid == outUID }
        let inIsDuplex  = (inDev?.inputChannels  ?? 0) > 0 && (inDev?.outputChannels  ?? 0) > 0
        let outIsDuplex = (outDev?.inputChannels ?? 0) > 0 && (outDev?.outputChannels ?? 0) > 0
        return inIsDuplex || outIsDuplex
    }

    /// Floating panel reference — kept alive for the duration of the aggregate warning.
    private static var aggregatePanel: NSPanel?

    private func handleStartJack() {
        let inUID  = jackManager.prefs.inputDeviceUID
        let outUID = jackManager.prefs.outputDeviceUID
        if isJackAggregatePending
            && !AggregateWarningSheet.isSuppressed(inUID: inUID, outUID: outUID) {
            showAggregatePanel()
        } else {
            jackManager.savePreferences()
            jackManager.startJack()
        }
    }

    /// Presents the aggregate warning in a floating NSPanel, independent of the main window.
    private func showAggregatePanel() {
        Self.aggregatePanel?.close()
        Self.aggregatePanel = nil

        let layout = buildAggregateLayout()

        let panel = NSPanel(
            contentRect: .zero,
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        panel.title                = String(localized: "aggregate.warning.title")
        panel.isFloatingPanel      = true
        panel.hidesOnDeactivate    = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor      = NSColor(JM.bgBase)

        let close = {
            Self.aggregatePanel?.close()
            Self.aggregatePanel = nil
        }

        let content = AggregateWarningSheet(
            layout:     layout,
            onConfirm: {
                close()
                jackManager.savePreferences()
                jackManager.startJack()
            },
            onDismiss:  close,
            hideHeader: true          // NSPanel title bar provides the title
        )

        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = .intrinsicContentSize
        panel.contentView     = hosting
        panel.setContentSize(hosting.fittingSize)
        // Centre horizontally, shift downward to clear the MenuBarView popover (~280 pt tall).
        panel.center()
        if let screen = NSScreen.main {
            let sf  = screen.frame
            let pw  = panel.frame.width
            let ph  = panel.frame.height
            let ox  = sf.minX + (sf.width - pw) / 2
            let oy  = sf.midY - ph / 2
            panel.setFrameOrigin(NSPoint(x: ox, y: oy))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        Self.aggregatePanel = panel
    }

    private func buildAggregateLayout() -> AggregateLayout {
        let inUID  = jackManager.prefs.inputDeviceUID
        let outUID = jackManager.prefs.outputDeviceUID
        let inDev  = audioManager.allDevices.first { $0.uid == inUID }
        let outDev = audioManager.allDevices.first { $0.uid == outUID }
        let inName  = inDev?.name  ?? inUID
        let outName = outDev?.name ?? outUID
        var capBlocks: [(deviceName: String, count: Int)] = []
        if let n = inDev?.inputChannels,  n > 0 { capBlocks.append((inName,  n)) }
        if let n = outDev?.inputChannels, n > 0 { capBlocks.append((outName, n)) }
        var pbBlocks: [(deviceName: String, count: Int)] = []
        if let n = outDev?.outputChannels, n > 0 { pbBlocks.append((outName, n)) }
        if let n = inDev?.outputChannels,  n > 0 { pbBlocks.append((inName,  n)) }
        return AggregateLayout(captureBlocks: capBlocks, playbackBlocks: pbBlocks,
                               inUID: inUID, outUID: outUID)
    }
}

// MARK: - MBInfoRow

/// A compact read-only row displaying an SF Symbol icon and a text value.
struct MBInfoRow: View {
    /// SF Symbol name for the leading icon.
    let icon: String
    /// Tint colour applied to the icon.
    let color: Color
    /// The value to display.
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(JM.textSecondary)
                .lineLimit(1)
        }
    }
}

// MARK: - MBActionRow

/// A tappable action row with an icon, label, and hover highlight.
struct MBActionRow: View {
    /// Stable identifier used to track hover state.
    let id: String
    /// SF Symbol name for the leading icon.
    let icon: String
    /// Action label text.
    let label: String
    /// Accent colour applied on hover.
    let color: Color
    /// Binding to the parent view's `hoveredAction` state.
    @Binding var hovered: String?
    /// Closure executed when the row is tapped.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovered == id ? color : JM.textTertiary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(hovered == id ? JM.textPrimary : JM.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(hovered == id ? color.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
    }
}
