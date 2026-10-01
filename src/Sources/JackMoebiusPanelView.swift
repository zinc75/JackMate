//
//  JackMoebiusPanelView.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Slide-in control panel (left edge) for the JackMoebius integration: the daemon
//  start/stop toggle, the master (system-mix) toggle, the per-app routing selector
//  (Out/In exposure + channel counts) with its blacklist action, and an
//  advanced-configuration sheet.
//

import SwiftUI
import AppKit

// MARK: - JackMoebiusPanelView

/// Slide-in panel toggled from the patchbay toolbar. Mirrors `LogPanelView`'s look,
/// anchored on the leading edge.
struct JackMoebiusPanelView: View {
    @EnvironmentObject var jackMoebiusManager: JackMoebiusManager

    /// Exposed+wired apps set to the wrong audio device (computed in `ContentView`,
    /// which has both the patchbay graph and the routing status). Drives the banner.
    let mismatches: [JMMismatch]

    /// Panel frame (SwiftUI global coords) + click monitor, for light-dismiss on
    /// an outside click (unlike the log panel, which stays open).
    @State private var panelFrame: CGRect = .zero
    @State private var clickMonitor: Any?
    @State private var showLicenseSheet = false

    /// Accent stripe + header tint, following the daemon state.
    private var accent: Color {
        switch jackMoebiusManager.state {
        case .active:  return JM.accentCyan
        case .failed:  return JM.accentRed
        default:       return JM.textTertiary
        }
    }

    /// True when JackMoebius is installed but its trial has expired.
    private var isLicenseExpired: Bool {
        if case .expired? = jackMoebiusManager.license { return true }
        return false
    }

    /// Drives the start/stop switch: on ⇒ activate, off ⇒ deactivate. Turning it on
    /// while the trial has expired opens the License sheet instead of starting the daemon.
    private var runningBinding: Binding<Bool> {
        Binding(
            get: { jackMoebiusManager.state == .active },
            set: { on in
                guard on else { jackMoebiusManager.deactivate(); return }
                if isLicenseExpired { showLicenseSheet = true; return }
                jackMoebiusManager.activate()
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            accent.frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                header
                if case .failed(let message) = jackMoebiusManager.state {
                    failureBanner(message)
                }
                if jackMoebiusManager.installed {
                    masterRow
                    if showMismatchBanner { mismatchBanner }
                    appArea
                    footer
                } else {
                    notInstalled
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(JM.bgBase.opacity(0.96))
        }
        // Width = patchbay area at min window (1200 − 245 sidebar − 1 border = 954)
        // minus the log panel (300), so the two never overlap at minimum width.
        .frame(width: 654)
        .overlay(alignment: .trailing) { Rectangle().fill(JM.border).frame(width: 1) }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { panelFrame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, f in panelFrame = f }
        })
        .onAppear { installClickMonitor(); jackMoebiusManager.refreshApps(); jackMoebiusManager.refreshLicense() }
        .onDisappear { removeClickMonitor() }
        // Confirmation when blacklisting an app that is still exposed in the graph.
        .alert(String(localized: "jackmoebius.blacklist.confirm.title"),
               isPresented: Binding(get: { jackMoebiusManager.blacklistConfirmApp != nil },
                                    set: { if !$0 { jackMoebiusManager.blacklistConfirmApp = nil } }),
               presenting: jackMoebiusManager.blacklistConfirmApp) { app in
            Button(String(localized: "jackmoebius.blacklist.confirm.remove"), role: .destructive) {
                jackMoebiusManager.performBlacklist(app, removeFirst: true)
            }
            Button(String(localized: "common.cancel"), role: .cancel) {
                jackMoebiusManager.blacklistConfirmApp = nil
            }
        } message: { app in
            Text(String(format: String(localized: "jackmoebius.blacklist.confirm.message"), app.name))
        }
        .sheet(isPresented: $jackMoebiusManager.showAdvanced) {
            JackMoebiusAdvancedSheet()
                .environmentObject(jackMoebiusManager)
        }
        .sheet(isPresented: $showLicenseSheet) {
            JackMoebiusLicenseSheet()
                .environmentObject(jackMoebiusManager)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image("JackMoebiusPictoColor")
                .resizable().scaledToFit()
                .frame(width: 34, height: 34)
            Text(String(localized: "jackmoebius.panel.title"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if jackMoebiusManager.state == .activating {
                ProgressView().controlSize(.small)
            } else {
                // Disabled (but visible) when the CLI is not installed.
                Toggle("", isOn: runningBinding)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .tint(JM.accentCyan)
                    .disabled(!jackMoebiusManager.installed)
            }
            Button { jackMoebiusManager.showPanel = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11)).foregroundStyle(JM.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(accent.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(JM.accentRed)
            Text(message)
                .font(.system(size: 10)).foregroundStyle(JM.accentRed)
                .lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JM.accentRed.opacity(0.10))
    }

    // MARK: Routing mismatch banner

    private var showMismatchBanner: Bool { !mismatches.isEmpty }

    /// Alert shown above the selectors when one or more exposed+wired apps are set to
    /// the wrong audio device. Clears on its own when the mismatch resolves (the app
    /// selects the JackMoebius device). The per-app guidance is generic for now; it can
    /// be enriched with the actual wrong-device name once the daemon reports it.
    private var mismatchBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15)).foregroundStyle(JM.accentOrange)
                Text(String(localized: "jackmoebius.mismatch.banner.title"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(JM.accentOrange)
            }
            Text(String(localized: "jackmoebius.mismatch.banner.subtitle"))
                .font(.system(size: 12)).foregroundStyle(JM.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(mismatches) { m in
                    HStack(alignment: .center, spacing: 9) {
                        AppIcon(key: m.key, fallbackName: m.name)
                            .frame(width: 28, height: 28)
                        Text(mismatchLine(m))
                            .font(.system(size: 12)).foregroundStyle(JM.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text(String(localized: "jackmoebius.mismatch.banner.hint"))
                .font(.system(size: 11)).foregroundStyle(JM.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JM.accentOrange.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
    }

    /// Per-app guidance line. When the daemon reports the wrong device (`current_device`)
    /// the line names it ("… sends its output to *X* instead of JackMoebius Out");
    /// otherwise it falls back to the generic instruction (older daemon / unresolved).
    private func mismatchLine(_ m: JMMismatch) -> String {
        if let dev = m.currentDevice, !dev.isEmpty {
            let fmt = m.isInput
                ? String(localized: "jackmoebius.mismatch.banner.in.device")
                : String(localized: "jackmoebius.mismatch.banner.out.device")
            return String(format: fmt, m.name, dev)
        }
        // Generic fallback (no device name available).
        if m.isInput {
            return String(format: String(localized: "jackmoebius.mismatch.banner.in"), m.name, m.name)
        } else {
            return String(format: String(localized: "jackmoebius.mismatch.banner.out"), m.name)
        }
    }

    // MARK: Master monitor box

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { jackMoebiusManager.masterOn },
            set: { jackMoebiusManager.setMaster($0) }
        )
    }

    /// Toggles the JackMoebius "master" monitor box (system mix in the JACK graph).
    /// Disabled unless the daemon is active (jack_master is JACK-first).
    private var masterRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 16))
                .foregroundStyle(jackMoebiusManager.state == .active ? JM.accentCyan : .white.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "jackmoebius.panel.master"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Text(String(localized: "jackmoebius.panel.master.sub"))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            // Same size as the app toggles, framed to the Out column so it sits directly
            // above the apps' Out toggles.
            Toggle("", isOn: masterBinding)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .tint(JM.accentCyan)
                .disabled(jackMoebiusManager.state != .active)
                .frame(width: JMColumn.width)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
    }

    // MARK: App selector

    @ViewBuilder private var appArea: some View {
        Group {
            if jackMoebiusManager.state != .active {
                licenseStatusBlock
            } else if jackMoebiusManager.apps.isEmpty {
                centeredHint(String(localized: "jackmoebius.panel.no_apps"))
            } else {
                VStack(spacing: 0) {
                    columnHeader
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(jackMoebiusManager.apps) { app in
                                AppSelectorRow(app: app)
                                    .environmentObject(jackMoebiusManager)
                                Rectangle().fill(JM.borderFaint).frame(height: 1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func centeredHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    /// Pinned column legend above the app list — "IN" / "OUT" centred over their columns
    /// (the same fixed-width geometry as the app rows), with a descriptive tooltip.
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Spacer()
            HStack(spacing: JMColumn.gap) {
                // Arrows point toward the JACK boxes: ↳ into apps (In), ↱ out of apps (Out).
                headerLabel(String(localized: "jackmoebius.app.in"),
                            systemImage: "square.and.arrow.down", rotation: -90,
                            tip: String(localized: "jackmoebius.app.in.tip"))
                headerLabel(String(localized: "jackmoebius.app.out"),
                            systemImage: "square.and.arrow.up", rotation: 90,
                            tip: String(localized: "jackmoebius.app.out.tip"))
            }
        }
        .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
    }

    private func headerLabel(_ text: String, systemImage: String, rotation: Double,
                             tip: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .rotationEffect(.degrees(rotation))
            Text(text)
                .font(.system(size: 13))   // same as the app names
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: JMColumn.width)
        .help(tip)
    }

    private var footer: some View {
        HStack {
            // Bottom-left: current license state + shortcut to manage it (always visible).
            Button { showLicenseSheet = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "key.fill").font(.system(size: 11))
                    licenseButtonTitle
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(licenseButtonTint)
            .help("license.manage.help")

            Spacer()

            // Bottom-right: advanced configuration (app blacklist / reservations).
            // Only meaningful while the daemon is running.
            Button { jackMoebiusManager.openAdvanced() } label: {
                Label(String(localized: "jackmoebius.panel.advanced"),
                      systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(JM.accentCyan)
            .disabled(jackMoebiusManager.state != .active)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
    }

    /// Colour-coded license label for the footer button.
    @ViewBuilder private var licenseButtonTitle: some View {
        switch jackMoebiusManager.license {
        case .licensed?:      Text("license.state.licensed")
        case .trial(let d)?:  Text(String(format: String(localized: "license.footer.trial"), d))
        case .expired?:       Text("license.state.expired")
        case nil:             Text("license.footer.default")
        }
    }

    /// Footer license-button tint, following the license state.
    private var licenseButtonTint: Color {
        switch jackMoebiusManager.license {
        case .licensed?: return JM.accentGreen
        case .trial?:    return JM.accentAmber
        case .expired?:  return JM.accentRed
        case nil:        return JM.textTertiary
        }
    }

    // MARK: Not installed

    private var notInstalled: some View {
        VStack(spacing: 16) {
            // Demo clip — spans the full panel width; promo still as offline fallback.
            JackMoebiusDemoVideo(autoplay: false)

            // The original not-installed block, vertically centred in the space
            // left below the video (more balanced than stacking it right under).
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28)).foregroundStyle(JM.accentAmber)
                Text(String(localized: "jackmoebius.panel.not_installed.title"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                // Reuse the info-sheet explanation text.
                Text(String(localized: "jackmoebius.info.body"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                // Enticement: JackMoebius is a paid product with a free trial.
                Text(String(localized: "jackmoebius.panel.not_installed.trial"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(JM.accentAmber)
                    .multilineTextAlignment(.center)
                // Primary CTA (real install) + a discreet "Learn more" link below it.
                VStack(spacing: 10) {
                    InstallJackMoebiusButton()
                    Button(String(localized: "jackmoebius.info.learn_more")) {
                        NSWorkspace.shared.open(JackMoebiusManager.downloadURL)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JM.accentCyan)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: License status (shown centrally when the daemon is stopped)

    /// Central block shown while JackMoebius is stopped: the current license state with a
    /// short call to action, so the panel is informative rather than near-empty.
    @ViewBuilder private var licenseStatusBlock: some View {
        VStack(spacing: 12) {
            switch jackMoebiusManager.license {
            case .licensed?:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30)).foregroundStyle(JM.accentGreen)
                Text("license.state.licensed")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text("license.panel.flip_hint")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            case .trial(let days)?:
                Image(systemName: "clock")
                    .font(.system(size: 30)).foregroundStyle(JM.accentAmber)
                Text(String(format: String(localized: "license.state.trial"), days))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text("license.panel.flip_hint")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            case .expired?:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30)).foregroundStyle(JM.accentRed)
                Text("license.state.expired")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text("license.panel.expired_blurb")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                Button("license.panel.manage") { showLicenseSheet = true }
                    .controlSize(.large).tint(JM.accentCyan).padding(.top, 2)
            case nil:
                Text(String(localized: "jackmoebius.panel.activate_hint"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Light-dismiss (close on a click outside the panel)

    /// Installs a local mouse-down monitor that closes the panel when the click lands
    /// outside it (patchbay, sidebar, header…) — like a popover. The dismissing click
    /// is **consumed** (returns `nil`), which also prevents the toolbar button from
    /// reopening the panel on the same click.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // Don't light-dismiss the panel while a modal it spawned is up (its clicks
            // land outside the panel frame).
            if jackMoebiusManager.blacklistConfirmApp != nil || jackMoebiusManager.showAdvanced { return event }
            guard let contentView = event.window?.contentView else { return event }
            let loc = event.locationInWindow
            // window (bottom-left origin) → SwiftUI `.global` (top-left origin)
            let point = CGPoint(x: loc.x, y: contentView.bounds.height - loc.y)
            if panelFrame.contains(point) { return event }   // inside the panel → interact
            jackMoebiusManager.showPanel = false
            return nil                                        // consume the dismissing click
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }
}

// MARK: - Column geometry

/// Shared metrics so the master toggle, the app Out/In toggles and their channel
/// pickers all line up in fixed columns (Out rightmost, In to its left — JACK order).
private enum JMColumn {
    static let width: CGFloat = 64
    static let gap: CGFloat = 12
}

// MARK: - AppSelectorRow

/// One app row: icon + name + free space (future volume) + In/Out columns. Each column
/// stacks a toggle over an always-visible channel picker, so the toggles never shift.
private struct AppSelectorRow: View {
    @EnvironmentObject var manager: JackMoebiusManager
    @EnvironmentObject var outputVolumeManager: OutputVolumeManager
    let app: JackMoebiusApp
    @State private var isBlacklistHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Fixed-width leading region so the per-app volume controls line up in a
            // column across rows — the gap after the name/blacklist is what varies.
            HStack(spacing: 8) {
                AppIcon(key: app.key, fallbackName: app.name)
                    .frame(width: 38, height: 38)
                Text(app.name)
                    .font(.system(size: 13)).foregroundStyle(.white)
                    .lineLimit(1)
                blacklistButton
                Spacer(minLength: 8)
            }
            .frame(width: 210)

            // Per-app output volume (lock) — aligned column, out-exposed apps only.
            if app.outExposed {
                volumeControl.padding(.trailing, 8)   // ×2 the gap before the In/Out zone
            } else {
                Spacer(minLength: 12)
            }

            HStack(spacing: JMColumn.gap) {
                // In column — only for capture-capable apps; left of Out (JACK convention).
                if app.inActionable {
                    directionColumn(
                        toggle: Binding(get: { app.inExposed },
                                        set: { manager.setIn(app, $0, n: manager.desiredInCount(app)) }),
                        help: String(localized: "jackmoebius.app.in.tip")
                    ) {
                        ChannelPicker(
                            count: Binding(get: { manager.desiredInCount(app) },
                                           set: { manager.setDesiredInChannels(app, n: $0) }),
                            range: 1...16)
                    }
                }
                // Out column — always present, rightmost. Its channel picker is inert: per-app
                // output width isn't configurable yet, so it stays fixed at stereo.
                directionColumn(
                    toggle: Binding(get: { app.outExposed },
                                    set: { manager.setOut(app, $0) }),
                    help: String(localized: "jackmoebius.app.out.tip")
                ) {
                    ChannelPicker(count: .constant(2), range: 2...2, enabled: false)
                }
            }
            // Reserve In+Out width (In column always reserved, Out right-aligned) so every
            // volume slider fills to the same x → identical lengths whether or not In shows.
            .frame(width: JMColumn.width * 2 + JMColumn.gap, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// Excludes the app from the selector (blacklist). Faint by default, brighter on
    /// hover, like the sidebar studio-row buttons. Exposed apps go through a confirmation.
    private var blacklistButton: some View {
        Button { manager.requestBlacklist(app) } label: {
            Image(systemName: "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isBlacklistHovered ? JM.textPrimary : JM.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isBlacklistHovered = $0 }
        .help(String(localized: "jackmoebius.app.blacklist.tip"))
    }

    /// Per-app output volume control, aligned in a column across rows:
    /// **① adjuster** (locked, collapsed) → click → **② adjuster highlighted + 🔒** + passive
    /// slider (mirrors the master) → click 🔒 → **③ 🔓** + draggable slider (independent
    /// override, always shown). In ③ the adjuster icon can't collapse (an override stays
    /// visible); re-lock (🔓 → 🔒) returns to ②, then the adjuster collapses to ①.
    @ViewBuilder
    private var volumeControl: some View {
        let vol      = manager.appVolumes[app.key]
        let locked   = vol?.locked ?? true
        let expanded = manager.volumePreviewExpanded.contains(app.key)
        let showSlider = !locked || expanded          // override always shows; locked only if previewed
        let muted    = outputVolumeManager.jackMoebiusOutMuted   // F10 → per-app sliders to 0

        HStack(spacing: 6) {
            // Adjuster = show/hide toggle, highlighted while the slider is shown. It can
            // only collapse a *locked* preview (② → ①); an unlocked override (③) stays.
            VolumeIconButton(system: "slider.horizontal.3",
                             highlighted: showSlider,
                             help: String(localized: "jackmoebius.volume.adjust.tip")) {
                if !showSlider { manager.expandVolumePreview(app.key) }
                else if locked { manager.collapseVolumePreview(app.key) }
            }

            if showSlider {
                // Lock + slider grouped in a rounded box (like the master volume boxes)
                // to delimit the control visually. The adjuster toggle stays outside it.
                HStack(spacing: 6) {
                    // Lock — cyan open padlock clearly signals an override (③).
                    VolumeIconButton(system: locked ? "lock.fill" : "lock.open.fill",
                                     color: locked ? JM.textSecondary : JM.accentCyan,
                                     help: locked ? String(localized: "jackmoebius.volume.unlock.tip")
                                                  : String(localized: "jackmoebius.volume.lock.tip")) {
                        manager.setAppLocked(app, !locked, master: outputVolumeManager.jackMoebiusOutVolume)
                    }
                    JMVolumeSlider(
                        // The slider works in scalar (position) space; the daemon speaks
                        // linear gain → convert with the shared taper so the per-app slider
                        // sits at the same position as the master (no jump on unlock).
                        // Muted (F10) → show 0 and freeze, like the device sliders.
                        value: muted
                            ? .constant(0)
                            : (locked
                                ? .constant(outputVolumeManager.jackMoebiusOutVolume
                                            ?? VolumeTaper.gainToScalar(vol?.gain ?? 1.0))
                                : Binding(get: { VolumeTaper.gainToScalar(manager.appVolumes[app.key]?.gain ?? 1.0) },
                                          set: { manager.setAppGain(app, VolumeTaper.scalarToGain($0)) })),
                        interactive: !locked && !muted
                    )
                    .frame(maxWidth: .infinity)   // fill the box → long, aligned sliders
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(JM.bgElevated)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(JM.borderFaint, lineWidth: 1)))
            } else {
                // ① collapsed: nothing after the adjuster icon; keep In/Out right-aligned.
                Spacer(minLength: 0)
            }
        }
    }

    /// Small icon button for the per-app volume control: hover-brightens; an optional
    /// highlighted background marks the active adjuster toggle.
    private struct VolumeIconButton: View {
        let system: String
        var color: Color = JM.textTertiary
        var highlighted: Bool = false
        let help: String
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                Image(systemName: system)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovered ? JM.textPrimary : color)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(highlighted ? JM.accentCyan.opacity(0.20) : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .onHover { hovered = $0 }
        }
    }

    /// A fixed-width column: toggle on top, channel picker below (always shown).
    @ViewBuilder
    private func directionColumn<P: View>(toggle: Binding<Bool>, help: String,
                                          @ViewBuilder picker: () -> P) -> some View {
        VStack(spacing: 12) {
            Toggle("", isOn: toggle)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(JM.accentCyan)
                .help(help)
            picker()
        }
        .frame(width: JMColumn.width)
    }
}

// MARK: - ChannelPicker

/// Channel-count selector — reuses the config panel's `JMPopUpButton` (dark rounded
/// pop-up) for a consistent look. Faded and inert when `enabled` is false — as for the Out
/// column, whose per-app output width isn't configurable yet (fixed at stereo).
private struct ChannelPicker: View {
    @Binding var count: Int
    let range: ClosedRange<Int>
    var enabled: Bool = true

    private var chLabel: String { String(localized: "jackmoebius.app.channels") }

    var body: some View {
        JMPopUpButton(
            options: range.map { ("\($0) \(chLabel)", $0) },
            selection: $count
        )
        .frame(width: JMColumn.width, height: 24)
        .opacity(enabled ? 1 : 0.45)
        .allowsHitTesting(enabled)
    }
}

// MARK: - App icon (resolved from bundle ID, cached)

/// Real app icon when `key` is a resolvable bundle ID; otherwise a coloured
/// abbreviation badge (helper-less `path:<exec>` apps).
private struct AppIcon: View {
    let key: String
    let fallbackName: String

    var body: some View {
        if let img = JackMoebiusIconCache.icon(forKey: key) {
            Image(nsImage: img).resizable().scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(BadgeUtils.color(BadgeUtils.abbrev(fallbackName), fullName: fallbackName).opacity(0.30))
                Text(BadgeUtils.abbrev(fallbackName))
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
        }
    }
}

/// Caches resolved app icons by bundle ID (main-actor; resolved lazily on first render).
enum JackMoebiusIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(forKey key: String) -> NSImage? {
        if let cached = cache[key] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)
        let img = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[key] = img
        return img
    }
}

// MARK: - Advanced configuration sheet

/// Manage the JackMoebius user blacklist: re-enable excluded apps and restore the
/// shipped defaults. (Per-app channel-reservation clearing will live here too.)
struct JackMoebiusAdvancedSheet: View {
    @EnvironmentObject var manager: JackMoebiusManager
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .blacklist

    private enum Tab { case blacklist, reservations }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JM.accentCyan)
                Text(String(localized: "jackmoebius.advanced.title"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(JM.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            tabSelector
                .padding(.horizontal, 20).padding(.bottom, 12)

            Rectangle().fill(JM.borderFaint).frame(height: 1)

            Group {
                switch tab {
                case .blacklist:    blacklistTab
                case .reservations: reservationsTab
                }
            }
            .frame(minHeight: 130, alignment: .top)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(JM.bgBase)
        .gradientBorder(cornerRadius: 12)
        .onAppear { manager.refreshBlacklist(); manager.refreshReservations() }
    }

    /// Custom two-segment selector styled with the JackMate accent (full-width, equal
    /// segments) rather than the system segmented control.
    private var tabSelector: some View {
        HStack(spacing: 3) {
            tabButton(.blacklist, String(localized: "jackmoebius.advanced.blacklist.title"))
            tabButton(.reservations, String(localized: "jackmoebius.advanced.reservations.title"))
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func tabButton(_ t: Tab, _ label: String) -> some View {
        Button { tab = t } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tab == t ? .white : .white.opacity(0.55))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(tab == t ? JM.accentCyan : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Blacklist tab: "Restore defaults" up top (so its scope is unambiguous), then the list.
    private var blacklistTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button(String(localized: "jackmoebius.advanced.reset")) {
                    manager.resetBlacklist()
                }
                .buttonStyle(.bordered).controlSize(.small).tint(JM.accentCyan)
            }
            if manager.blacklist.isEmpty {
                Text(String(localized: "jackmoebius.advanced.blacklist.empty"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(manager.blacklist) { entry in
                        BlacklistRow(entry: entry)
                        if entry.id != manager.blacklist.last?.id {
                            Rectangle().fill(JM.borderFaint).frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    /// Channel-reservations tab: apps with a persistent out/in reservation.
    private var reservationsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.reservations.isEmpty {
                Text(String(localized: "jackmoebius.advanced.reservations.empty"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(manager.reservations) { entry in
                        ReservationRow(entry: entry)
                        if entry.id != manager.reservations.last?.id {
                            Rectangle().fill(JM.borderFaint).frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

}

// MARK: - Blacklist row

/// One user-blacklisted app: icon + name + a `minus.circle` button (tooltip) to re-enable
/// it. The shipped defaults are filtered out upstream and never reach this row.
private struct BlacklistRow: View {
    @EnvironmentObject var manager: JackMoebiusManager
    let entry: JackMoebiusBlacklistEntry
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(key: entry.key, fallbackName: entry.name)
                .frame(width: 28, height: 28)
            Text(entry.name)
                .font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            Button { manager.unblacklist(entry) } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isHovered ? JM.accentCyan : JM.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(String(localized: "jackmoebius.advanced.blacklist.reenable"))
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Reservation row

/// One app with a persistent channel reservation: icon + name + a clickable chip per
/// reserved direction (Out / In) that frees that reservation. Reddens on hover (destructive).
private struct ReservationRow: View {
    @EnvironmentObject var manager: JackMoebiusManager
    let entry: JackMoebiusReservation
    @State private var outHovered = false
    @State private var inHovered  = false

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(key: entry.key, fallbackName: entry.name)
                .frame(width: 28, height: 28)
            Text(entry.name)
                .font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            if entry.outOffset != nil {
                clearChip(label: String(localized: "jackmoebius.app.out"),
                          hovered: outHovered,
                          tip: String(localized: "jackmoebius.advanced.reservations.clear_out")) {
                    manager.clearOutReservation(entry)
                }
                .onHover { outHovered = $0 }
            }
            if !entry.inChannels.isEmpty {
                let ch = String(localized: "jackmoebius.app.channels")
                clearChip(label: "\(String(localized: "jackmoebius.app.in")) \(entry.inChannels.count) \(ch)",
                          hovered: inHovered,
                          tip: String(localized: "jackmoebius.advanced.reservations.clear_in")) {
                    manager.clearInReservation(entry)
                }
                .onHover { inHovered = $0 }
            }
        }
        .padding(.vertical, 8)
    }

    private func clearChip(label: String, hovered: Bool, tip: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10, weight: .medium))
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .foregroundStyle(hovered ? JM.accentRed : .white.opacity(0.6))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(hovered ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}
