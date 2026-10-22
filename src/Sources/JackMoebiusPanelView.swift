//
//  JackMoebiusPanelView.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Slide-in control panel (left edge) for the JackMoebius integration: the daemon
//  start/stop toggle, the per-app routing selector (Out/In exposure; each direction shows its
//  backing — default JackMoebius or a dedicated card of N channels — in a pill that opens an
//  Apply panel) with its blacklist action and routing-mismatch bands, and an
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
                // Why the daemon does not run (doctor); the raw launchctl error only when nothing better.
                if jackMoebiusManager.state != .active, !actionableReasons.isEmpty {
                    daemonReasonBanner(actionableReasons)
                } else if case .failed(let message) = jackMoebiusManager.state {
                    failureBanner(message)
                }
                if jackMoebiusManager.state == .active, let problem = jackMoebiusManager.transportProblem {
                    transportBanner(problem)
                }
                if jackMoebiusManager.installed && jackMoebiusManager.daemonTooOld {
                    daemonTooOld
                } else if jackMoebiusManager.installed {
                    if showMismatchBanner { mismatchBanner }
                    if sharedInputApps.count >= 2 { sharedInputBanner }
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
        .onAppear {
            installClickMonitor(); jackMoebiusManager.refreshApps(); jackMoebiusManager.refreshLicense()
            if jackMoebiusManager.state != .active { jackMoebiusManager.refreshDaemonReasons(force: true) }
        }
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
        // Taking an input back to the shared input would also feed the other apps that read it with
        // the cables of its card: ask before applying (nothing is sent until the user decides).
        // Hosted on its own background view: two `.alert` modifiers on the same view conflict in
        // SwiftUI (the second one is dismissed as soon as it opens).
        .background(
            Color.clear.alert(String(localized: "jackmoebius.rewire.title"),
                              isPresented: Binding(get: { jackMoebiusManager.pendingApply != nil },
                                                   set: { if !$0 { DispatchQueue.main.async { jackMoebiusManager.cancelPendingApply() } } }),
                              presenting: jackMoebiusManager.pendingApply) { pending in
                Button(String(localized: "jackmoebius.rewire.confirm")) {
                    jackMoebiusManager.confirmPendingApply(pending, reconnect: true)
                }
                Button(String(localized: "jackmoebius.rewire.ignore")) {
                    jackMoebiusManager.confirmPendingApply(pending, reconnect: false)
                }
                Button(String(localized: "common.cancel"), role: .cancel) { }
            } message: { pending in
                Text(String(format: String(localized: "jackmoebius.rewire.message"),
                            pending.app.name, pending.plan.otherSharedInputApps.joined(separator: ", ")))
            }
        )
        // Leaving the shared input: offer to cut the cables that were drawn only for this app.
        .background(
            Color.clear.alert(String(localized: "jackmoebius.cleanup.title"),
                              isPresented: Binding(get: { jackMoebiusManager.pendingCleanup != nil },
                                                   set: { if !$0 { DispatchQueue.main.async { jackMoebiusManager.cancelCleanup() } } }),
                              presenting: jackMoebiusManager.pendingCleanup) { pending in
                Button(String(localized: "jackmoebius.cleanup.remove")) {
                    jackMoebiusManager.confirmCleanup(pending, remove: true)
                }
                Button(String(localized: "jackmoebius.cleanup.keep")) {
                    jackMoebiusManager.confirmCleanup(pending, remove: false)
                }
                Button(String(localized: "common.cancel"), role: .cancel) { }
            } message: { pending in
                Text(cleanupMessage(pending))
            }
        )
        // Removing a shared input does not silence the app while others keep the shared mode.
        .background(
            Color.clear.alert(String(localized: "jackmoebius.remove_shared.title"),
                              isPresented: Binding(get: { jackMoebiusManager.pendingSharedInputRemoval != nil },
                                                   set: { if !$0 { DispatchQueue.main.async { jackMoebiusManager.cancelSharedInputRemoval() } } }),
                              presenting: jackMoebiusManager.pendingSharedInputRemoval) { pending in
                Button(String(localized: "jackmoebius.remove_shared.confirm"), role: .destructive) {
                    jackMoebiusManager.confirmSharedInputRemoval(pending)
                }
                Button(String(localized: "common.cancel"), role: .cancel) { }
            } message: { pending in
                Text(String(format: String(localized: "jackmoebius.remove_shared.message"),
                            pending.app.name, pending.otherApps.joined(separator: ", ")))
            }
        )
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

    // MARK: Cable clean-up alert text

    /// The « these cables were drawn for X » text with the cables listed (shortened), plus a warning when
    /// other apps still read the shared input.
    private func cleanupMessage(_ pending: JackMoebiusManager.PendingCleanup) -> String {
        let shown = pending.wires.prefix(6).map { w in
            w.from + " → " + w.to.replacingOccurrences(of: "JackMoebius:", with: "")
        }
        var list = shown.joined(separator: "\n")
        if pending.wires.count > shown.count { list += "\n…" }
        var text = String(format: String(localized: "jackmoebius.cleanup.message"), pending.app.name, list)
        if !pending.otherApps.isEmpty {
            text += "\n" + String(format: String(localized: "jackmoebius.cleanup.others"),
                                   pending.otherApps.joined(separator: ", "))
        }
        return text
    }

    // MARK: Shared input banner

    /// Apps whose input is the shared default input (they all hear the same stereo feed).
    private var sharedInputApps: [String] {
        jackMoebiusManager.apps.filter { $0.inExposed && $0.inBacking == .shared }.map(\.name)
    }

    /// General information, always visible while several apps share the default input.
    private var sharedInputBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13)).foregroundStyle(JM.accentBlue)
            Text(String(format: String(localized: "jackmoebius.panel.shared_input_in_use"),
                        sharedInputApps.joined(separator: ", ")))
                .font(.system(size: 12)).foregroundStyle(JM.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JM.accentBlue.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
    }

    // MARK: Why the daemon does not run

    /// The doctor's reasons that say more than « not running » (that one is just the starting point).
    private var actionableReasons: [JMDoctorMessage] {
        jackMoebiusManager.daemonReasons.filter { $0.code != "daemon_not_running" }
    }

    /// The account named in the daemon's sentence (`… another account ("name") …`), for the localised text.
    private func accountName(in text: String) -> String {
        guard let r = text.range(of: "\"[^\"]+\"", options: .regularExpression) else { return "?" }
        return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func reasonTexts(_ m: JMDoctorMessage) -> (message: String, remedy: String) {
        switch m.code {
        case "driver_not_installed":
            return (String(localized: "jackmoebius.reason.driver_not_installed"),
                    String(localized: "jackmoebius.reason.driver_not_installed.remedy"))
        case "other_account_running":
            return (String(format: String(localized: "jackmoebius.reason.other_account_running"), accountName(in: m.text)),
                    String(localized: "jackmoebius.reason.other_account_running.remedy"))
        case "other_account_stale_socket":
            return (String(format: String(localized: "jackmoebius.reason.other_account_stale_socket"), accountName(in: m.text)),
                    String(localized: "jackmoebius.reason.other_account_stale_socket.remedy"))
        case "broker_not_installed":
            return (String(localized: "jackmoebius.transport.broker_not_installed"),
                    String(localized: "jackmoebius.transport.broker_not_installed.remedy"))
        case "broker_switched_off":
            return (String(localized: "jackmoebius.transport.broker_switched_off"),
                    String(localized: "jackmoebius.transport.broker_switched_off.remedy"))
        default:
            return (m.text, m.remedy)
        }
    }

    private func daemonReasonBanner(_ reasons: [JMDoctorMessage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15)).foregroundStyle(JM.accentRed)
                Text(String(localized: "jackmoebius.reason.title"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(JM.accentRed)
            }
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, m in
                let texts = reasonTexts(m)
                VStack(alignment: .leading, spacing: 3) {
                    Text(texts.message)
                        .font(.system(size: 12)).foregroundStyle(JM.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !texts.remedy.isEmpty {
                        Text(texts.remedy)
                            .font(.system(size: 12)).foregroundStyle(JM.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JM.accentRed.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
    }

    // MARK: Transport banner

    /// The six reasons the shared-memory transport can be down, worded from the daemon's stable
    /// code (an unknown code falls back to the daemon's English sentences).
    private func transportTexts(_ p: JMTransportProblem) -> (message: String, remedy: String) {
        switch p.code {
        case "broker_not_installed":
            return (String(localized: "jackmoebius.transport.broker_not_installed"),
                    String(localized: "jackmoebius.transport.broker_not_installed.remedy"))
        case "broker_switched_off":
            return (String(localized: "jackmoebius.transport.broker_switched_off"),
                    String(localized: "jackmoebius.transport.broker_switched_off.remedy"))
        case "broker_unreachable":
            return (String(localized: "jackmoebius.transport.broker_unreachable"),
                    String(localized: "jackmoebius.transport.broker_unreachable.remedy"))
        case "broker_version_mismatch":
            return (String(localized: "jackmoebius.transport.broker_version_mismatch"),
                    String(localized: "jackmoebius.transport.broker_version_mismatch.remedy"))
        case "broker_slot_busy":
            return (String(localized: "jackmoebius.transport.broker_slot_busy"),
                    String(localized: "jackmoebius.transport.broker_slot_busy.remedy"))
        case "driver_not_attached":
            return (String(localized: "jackmoebius.transport.driver_not_attached"),
                    String(localized: "jackmoebius.transport.driver_not_attached.remedy"))
        default:
            return (p.message, p.remedy)
        }
    }

    /// Red banner while the transport is down: no JackMoebius box can exist, so it says why and
    /// what to do (the daemon retries by itself and recovers as soon as the cause is gone).
    private func transportBanner(_ problem: JMTransportProblem) -> some View {
        let texts = transportTexts(problem)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 15)).foregroundStyle(JM.accentRed)
                Text(String(localized: "jackmoebius.transport.title"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(JM.accentRed)
            }
            Text(texts.message)
                .font(.system(size: 12)).foregroundStyle(JM.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !texts.remedy.isEmpty {
                Text(texts.remedy)
                    .font(.system(size: 12)).foregroundStyle(JM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JM.accentRed.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
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
            // How to fix: placed after the lines it refers to (« indiqué ci-dessus »).
            Text(String(localized: "jackmoebius.mismatch.banner.subtitle"))
                .font(.system(size: 12)).foregroundStyle(JM.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "jackmoebius.mismatch.banner.hint"))
                .font(.system(size: 11)).foregroundStyle(JM.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JM.accentOrange.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(JM.borderFaint).frame(height: 1) }
    }

    /// Per-app diagnostic line, worded for the direction's backing (a dedicated card, or the shared
    /// JackMoebius device). When the daemon reports the wrong device (`current_device`) the line
    /// names it. The how-to-fix guidance is the banner subtitle; the « Utiliser le défaut » button
    /// lives only on the app rows.
    private func mismatchLine(_ m: JMMismatch) -> String {
        let app = jackMoebiusManager.apps.first(where: { $0.key == m.key })
        let dedicated = (m.isInput ? app?.inBacking : app?.outBacking) == .dedicated
        if let dev = m.currentDevice, !dev.isEmpty {
            let fmt: String
            switch (m.isInput, dedicated) {
            case (true, true):   fmt = String(localized: "jackmoebius.mismatch.banner.in.device")
            case (true, false):  fmt = String(localized: "jackmoebius.mismatch.banner.in_shared.device")
            case (false, true):  fmt = String(localized: "jackmoebius.mismatch.banner.out_dedicated.device")
            case (false, false): fmt = String(localized: "jackmoebius.mismatch.banner.out.device")
            }
            return String(format: fmt, m.name, dev)
        }
        switch (m.isInput, dedicated) {
        case (true, true):
            return String(format: String(localized: "jackmoebius.mismatch.banner.in"), m.name, m.name)
        case (true, false):
            return String(format: String(localized: "jackmoebius.mismatch.banner.in_shared"), m.name)
        case (false, true):
            return String(format: String(localized: "jackmoebius.mismatch.banner.out_dedicated"), m.name, m.name)
        case (false, false):
            return String(format: String(localized: "jackmoebius.mismatch.banner.out"), m.name)
        }
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
                                AppSelectorRow(app: app, wiredMismatches: mismatches)
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

    // MARK: Daemon too old

    /// Shown instead of the app selector when the installed JackMoebius predates the version
    /// this JackMate needs (older daemons ignore the backing parameters silently).
    private var daemonTooOld: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 28)).foregroundStyle(JM.accentAmber)
            Text(String(localized: "jackmoebius.panel.too_old.title"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Text(String(format: String(localized: "jackmoebius.panel.too_old.body"),
                        JackMoebiusManager.minimumDaemonVersion,
                        jackMoebiusManager.installedVersion ?? "?"))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            InstallJackMoebiusButton(title: "jackmoebius.panel.update_button")
                .environmentObject(jackMoebiusManager)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if jackMoebiusManager.blacklistConfirmApp != nil || jackMoebiusManager.showAdvanced
                || jackMoebiusManager.pendingApply != nil
                || jackMoebiusManager.pendingSharedInputRemoval != nil
                || jackMoebiusManager.pendingCleanup != nil { return event }
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
    static let width: CGFloat = 178
    static let gap: CGFloat = 12
}

// MARK: - AppSelectorRow

/// One app row: icon + name + free space (future volume) + In/Out columns. Each column
/// stacks a toggle over an always-visible channel picker, so the toggles never shift.
private struct AppSelectorRow: View {
    @EnvironmentObject var manager: JackMoebiusManager
    @EnvironmentObject var outputVolumeManager: OutputVolumeManager
    let app: JackMoebiusApp
    /// Exposed directions that are wired and read the wrong device (computed in `ContentView`).
    let wiredMismatches: [JMMismatch]
    @State private var isBlacklistHovered = false
    /// Direction (`true` = input) whose exposure panel is open under the row, if any.
    @State private var panelFor: Bool? = nil

    /// Whether a routing mismatch is flagged for this direction: it is exposed and reads another
    /// device than expected, and it is either wired (then the panel banner shows it too) or was
    /// just configured here — so the user hears about a wrong choice right when making it, without
    /// a flag on every exposed-but-unwired app at launch.
    private func showsMismatch(input: Bool) -> Bool {
        guard input ? app.inExposed : app.outExposed else { return false }
        let status = input ? manager.boxStatus[app.key]?.input : manager.boxStatus[app.key]?.out
        guard status == .mismatch else { return false }
        return wiredMismatches.contains { $0.key == app.key && $0.isInput == input }
            || manager.isConfigured(app.key, input: input)
    }

    var body: some View {
        VStack(spacing: 0) {
            rowLine
            ForEach([true, false], id: \.self) { input in
                if showsMismatch(input: input) {
                    MismatchBand(app: app, isInput: input)
                        .padding(.horizontal, 14).padding(.bottom, 8)
                }
            }
            if let refusal = manager.applyErrors[app.key] {
                ApplyErrorBand(
                    message: refusal.text(appName: app.name),
                    action: refusal.needsInputMovedToo
                        ? (title: String(localized: "jackmoebius.apply_error.both_shared"), run: {
                            // One request for both directions: the card is deleted, its channels freed.
                            manager.dismissApplyError(app.key)
                            manager.apply(app, in: .sharedStereo, out: .sharedStereo)
                        }) : nil
                ) { manager.dismissApplyError(app.key) }
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if let isInput = panelFor {
                ExposurePanel(app: app, isInput: isInput, start: startSide(input: isInput),
                              onClose: { panelFor = nil })
                    .id(isInput)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        // The panel only edits an exposed direction: close it if that direction is switched off.
        .onChange(of: app.inExposed)  { _, on in if !on && panelFor == true  { panelFor = nil } }
        .onChange(of: app.outExposed) { _, on in if !on && panelFor == false { panelFor = nil } }
    }

    /// Switch of one direction. **On** opens the exposure panel (nothing reaches the daemon before
    /// Apply; Cancel switches it back off); **off** hides the direction at once. While the panel is
    /// open for a not-yet-exposed direction, the switch shows on.
    private func toggleBinding(input: Bool) -> Binding<Bool> {
        let exposed = input ? app.inExposed : app.outExposed
        return Binding(
            get: { exposed || panelFor == input },
            set: { on in
                if on {
                    if !exposed { panelFor = input }
                } else {
                    if panelFor == input { panelFor = nil }
                    if exposed { manager.requestHide(app, input: input) }
                }
            })
    }

    /// The side the panel starts from: the current one for an exposed direction, else the
    /// suggestion (reservation, last choice, default).
    private func startSide(input: Bool) -> JMSide {
        let exposed = input ? app.inExposed : app.outExposed
        if exposed { return input ? app.currentIn : app.currentOut }
        return manager.suggestedSide(for: app, input: input)
    }

    private var rowLine: some View {
        HStack(alignment: .top, spacing: 8) {
            // Leading region: icon + name (vertically centred on the toggle + pill block of the
            // columns), with the per-app output volume control (lock) under the name when the
            // output is exposed.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    AppIcon(key: app.key, fallbackName: app.name)
                        .frame(width: 38, height: 38)
                    Text(app.name)
                        .font(.system(size: 13)).foregroundStyle(.white)
                        .lineLimit(1)
                    blacklistButton
                    if app.outExposed { volumeButton }
                    Spacer(minLength: 8)
                }
                .frame(height: 58)
                if app.outExposed && showVolumeSlider {
                    volumeSlider
                        .padding(.leading, 46)   // aligned under the name (icon 38 + gap 8)
                        .padding(.bottom, 2)
                }
            }

            HStack(alignment: .top, spacing: JMColumn.gap) {
                // In column — only for capture-capable apps; left of Out (JACK convention).
                if app.inActionable {
                    directionColumn(
                        toggle: toggleBinding(input: true),
                        help: String(localized: "jackmoebius.app.in.tip")
                    ) {
                        ExposurePill(
                            side: app.inExposed ? app.currentIn : manager.suggestedSide(for: app, input: true),
                            isInput: true, active: app.inExposed, selected: panelFor == true,
                            mismatch: showsMismatch(input: true),
                            onTap: { panelFor = (panelFor == true) ? nil : true })
                    }
                }
                // Out column — always present, rightmost. Its channel picker is inert: per-app
                // output width isn't configurable yet, so it stays fixed at stereo.
                directionColumn(
                    toggle: toggleBinding(input: false),
                    help: String(localized: "jackmoebius.app.out.tip")
                ) {
                    ExposurePill(
                        side: app.outExposed ? app.currentOut : manager.suggestedSide(for: app, input: false),
                        isInput: false, active: app.outExposed, selected: panelFor == false,
                        mismatch: showsMismatch(input: false),
                        onTap: { panelFor = (panelFor == false) ? nil : false })
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

    // MARK: Per-app output volume (adjuster button next to the eye + slider under the name)

    /// Whether the volume slider is shown under the name (the user toggles it with the adjuster
    /// button). An unlocked override can be hidden too: the open padlock next to the button then
    /// tells that this app has its own volume.
    private var showVolumeSlider: Bool { manager.volumePreviewExpanded.contains(app.key) }

    /// `true` when the app plays at its own (unlocked) volume instead of following the master.
    private var hasVolumeOverride: Bool { !(manager.appVolumes[app.key]?.locked ?? true) }

    /// Adjuster button, next to the eye: shows / hides the volume slider under the name. Slider
    /// shown: **passive** (mirrors the master, 🔒) or **draggable** (🔓 independent override).
    /// While an override is hidden, a cyan open padlock beside the button keeps it visible.
    private var volumeButton: some View {
        HStack(spacing: 3) {
            VolumeIconButton(system: "slider.horizontal.3",
                             highlighted: showVolumeSlider,
                             help: String(localized: "jackmoebius.volume.adjust.tip")) {
                if showVolumeSlider { manager.collapseVolumePreview(app.key) }
                else { manager.expandVolumePreview(app.key) }
            }
            if hasVolumeOverride && !showVolumeSlider {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(JM.accentCyan)
                    .help(String(localized: "jackmoebius.volume.override.tip"))
            }
        }
    }

    /// Lock + slider grouped in a rounded box (like the master volume boxes).
    @ViewBuilder
    private var volumeSlider: some View {
        let vol    = manager.appVolumes[app.key]
        let locked = vol?.locked ?? true
        let muted  = outputVolumeManager.jackMoebiusOutMuted
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
            .frame(maxWidth: .infinity)   // fill the box → long sliders
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(JM.bgElevated)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(JM.borderFaint, lineWidth: 1)))
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
        VStack(spacing: 8) {
            Toggle("", isOn: toggle)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(JM.accentCyan)
                .help(help)
            picker()
        }
        .frame(width: JMColumn.width)
    }
}

// MARK: - ExposurePill

/// Shows how one direction of an app reaches JackMoebius: « Défaut JackMoebius » (shared) or
/// « N ch dédié » (a dedicated card). Faded and inert while the direction is off; clickable
/// (it opens the exposure panel) while the direction is on.
private struct ExposurePill: View {
    let side: JMSide
    let isInput: Bool
    let active: Bool
    var selected: Bool = false
    var mismatch: Bool = false      // orange dot: the app reads/writes another device than expected
    var onTap: () -> Void = {}

    private var dedicated: Bool { side.backing == .dedicated }

    private var label: String {
        dedicated ? String(format: String(localized: "jackmoebius.pill.dedicated"), side.channels)
                  : String(localized: "jackmoebius.pill.default")
    }

    /// Same glyphs as the In / Out column headers (arrows pointing toward the JACK boxes); the
    /// backing is told by the label and the colour.
    private var symbol: String { isInput ? "square.and.arrow.down" : "square.and.arrow.up" }
    private var symbolRotation: Double { isInput ? -90 : 90 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                    .rotationEffect(.degrees(symbolRotation))
                Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .minimumScaleFactor(0.85)   // long translations (« JackMoebius-Standard »…)
                if active {
                    Image(systemName: selected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(dedicated ? JM.accentCyan : JM.textSecondary)
            .padding(.horizontal, 8).frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(dedicated ? JM.accentCyan.opacity(0.14) : Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(
                selected ? (dedicated ? JM.accentCyan : Color.white.opacity(0.5))
                         : (dedicated ? JM.accentCyan.opacity(0.35) : Color.white.opacity(0.12)),
                lineWidth: selected ? 1.5 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .opacity(active ? 1 : 0.4)
        .overlay(alignment: .topTrailing) {
            if mismatch {
                Circle().fill(JM.accentOrange).frame(width: 8, height: 8)
                    .offset(x: 1, y: -1)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - ApplyErrorBand

/// Red band under an app row: the daemon refused the change (no free channels, the app has no audio
/// context yet…). Worded from the daemon's error code and its numbers (its English sentence if unknown).
private struct ApplyErrorBand: View {
    let message: String
    /// An optional way out offered by the band (e.g. move the input to the shared mode too).
    var action: (title: String, run: () -> Void)? = nil
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 12)).foregroundStyle(JM.accentRed)
            Text(String(format: String(localized: "jackmoebius.apply_error"), message))
                .font(.system(size: 11)).foregroundStyle(JM.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(NoticeButtonStyle(tint: JM.accentRed))
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JM.textTertiary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "jackmoebius.apply_error.dismiss"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(JM.accentRed.opacity(0.16)))
    }
}

// MARK: - MismatchBand

/// Orange band under an app row: the direction reads or writes another device than expected.
/// For a dedicated direction it offers « Utiliser le défaut » — an escape hatch for an app whose
/// settings don't let the user pick the card; for a shared direction it only points at the fix.
private struct MismatchBand: View {
    @EnvironmentObject var manager: JackMoebiusManager
    let app: JackMoebiusApp
    let isInput: Bool

    private var dedicated: Bool { (isInput ? app.inBacking : app.outBacking) == .dedicated }

    private var text: String {
        let format: String
        switch (isInput, dedicated) {
        case (true, true):   format = String(localized: "jackmoebius.mismatch.row.dedicated.in")
        case (true, false):  format = String(localized: "jackmoebius.mismatch.row.shared.in")
        case (false, true):  format = String(localized: "jackmoebius.mismatch.row.dedicated.out")
        case (false, false): format = String(localized: "jackmoebius.mismatch.row.shared.out")
        }
        return String(format: format, app.name)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(JM.accentOrange)
            Text(text)
                .font(.system(size: 11)).foregroundStyle(JM.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if dedicated {
                Button(String(localized: "jackmoebius.mismatch.use_default")) {
                    if isInput { manager.apply(app, in: .sharedStereo) }
                    else { manager.apply(app, out: .sharedStereo) }
                }
                .buttonStyle(.bordered).controlSize(.small).tint(JM.accentOrange)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(JM.accentOrange.opacity(0.16)))
    }
}

// MARK: - ExposurePanel

/// The panel unfolded under an app row when the user clicks a direction's pill: a segmented
/// choice (default JackMoebius | dedicated), a 1…64 channel menu for a dedicated card, an
/// explanation, a band telling what applying will do to the app's card, and Cancel / Apply.
/// Nothing reaches the daemon before Apply (one `jack_apply`, at most one card rebuild).
private struct ExposurePanel: View {
    @EnvironmentObject var manager: JackMoebiusManager
    let app: JackMoebiusApp
    let isInput: Bool
    let onClose: () -> Void

    @State private var dedicated: Bool
    @State private var channels: Int

    init(app: JackMoebiusApp, isInput: Bool, start: JMSide, onClose: @escaping () -> Void) {
        self.app = app; self.isInput = isInput; self.onClose = onClose
        _dedicated = State(initialValue: start.backing == .dedicated)
        _channels  = State(initialValue: start.backing == .dedicated ? start.channels : 2)
    }

    private var current: JMSide { isInput ? app.currentIn : app.currentOut }
    /// `true` while the direction is not exposed yet: applying exposes it (so there is always
    /// something to apply, even if the proposal equals what the daemon reports for the side).
    private var isNewExposure: Bool { !(isInput ? app.inExposed : app.outExposed) }
    private var draft: JMSide { dedicated ? .dedicated(channels) : .sharedStereo }
    private var changed: Bool { isNewExposure || draft != current }
    private var effect: ExposureEffect? {
        changed ? ExposureEffect.compute(app: app, isInput: isInput, new: draft) : nil
    }

    private var help: String {
        // Literal keys (not built at run time) so the string catalog keeps seeing them as used.
        let format: String
        switch (isInput, dedicated) {
        case (true, true):   format = String(localized: "jackmoebius.panel.help.in_dedicated")
        case (true, false):  format = String(localized: "jackmoebius.panel.help.in_shared")
        case (false, true):  format = String(localized: "jackmoebius.panel.help.out_dedicated")
        case (false, false): format = String(localized: "jackmoebius.panel.help.out_shared")
        }
        return String(format: format, app.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: isInput ? String(localized: "jackmoebius.panel.title.in")
                                        : String(localized: "jackmoebius.panel.title.out"), app.name))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(JM.textPrimary)

            HStack(spacing: 12) {
                segmented
                if dedicated {
                    HStack(spacing: 6) {
                        Text(String(localized: "jackmoebius.panel.voices"))
                            .font(.system(size: 12)).foregroundStyle(JM.textSecondary)
                        JMPopUpButton(options: (1...64).map { ("\($0)", $0) }, selection: $channels)
                            .frame(width: 72, height: 24)
                    }
                } else {
                    Text(String(localized: "jackmoebius.panel.stereo"))
                        .font(.system(size: 12)).foregroundStyle(JM.textSecondary)
                }
                Spacer(minLength: 0)
            }

            Text(help)
                .font(.system(size: 11)).foregroundStyle(JM.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let effect { effectBand(effect) }

            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "common.cancel")) { onClose() }
                    .buttonStyle(.bordered).controlSize(.small)
                Button(changed ? String(localized: "jackmoebius.panel.apply")
                               : String(localized: "jackmoebius.panel.close")) {
                    if changed {
                        if isInput { manager.apply(app, in: draft) } else { manager.apply(app, out: draft) }
                    }
                    onClose()
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(JM.accentCyan)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(JM.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(JM.border, lineWidth: 1))
    }

    /// « Entrée / Sortie par défaut | Dédié » — two capsule segments, like the advanced sheet tabs.
    private var segmented: some View {
        HStack(spacing: 3) {
            segment(isInput ? String(localized: "jackmoebius.panel.seg.in_default")
                            : String(localized: "jackmoebius.panel.seg.out_default"), selected: !dedicated) {
                dedicated = false
            }
            segment(String(localized: "jackmoebius.panel.seg.dedicated"), selected: dedicated) {
                dedicated = true
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? .white : .white.opacity(0.55))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(selected ? JM.accentCyan : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The coloured band: blue = a card is created, orange = rebuilt / kept without this side,
    /// red = deleted.
    private func effectBand(_ effect: ExposureEffect) -> some View {
        let color: Color, icon: String, text: String
        switch effect {
        case .created:
            color = JM.accentBlue; icon = "info.circle.fill"
            text = String(format: String(localized: "jackmoebius.fx.created"), app.name)
        case .recreatedAddingSide:
            color = JM.accentOrange; icon = "exclamationmark.triangle.fill"
            text = String(format: isInput ? String(localized: "jackmoebius.fx.recreated_add.in")
                                          : String(localized: "jackmoebius.fx.recreated_add.out"), app.name)
        case .keptWithoutSide:
            color = JM.accentOrange; icon = "exclamationmark.triangle.fill"
            text = String(format: isInput ? String(localized: "jackmoebius.fx.kept.in")
                                          : String(localized: "jackmoebius.fx.kept.out"), app.name)
        case .deleted:
            color = JM.accentRed; icon = "trash.fill"
            text = String(format: String(localized: "jackmoebius.fx.deleted"), app.name)
        case .recreatedWidth(let n):
            color = JM.accentOrange; icon = "exclamationmark.triangle.fill"
            text = String(format: String(localized: "jackmoebius.fx.recreated_width"), app.name, n)
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
            Text(text)
                .font(.system(size: 11)).foregroundStyle(JM.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.16)))
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

            Rectangle().fill(JM.borderFaint).frame(height: 1)
            debugSection
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(JM.bgBase)
        .gradientBorder(cornerRadius: 12)
        // Rebuilding a card makes its app see the device go and come back: ask first. Hosted here, on the
        // sheet, because an alert of the panel behind it would not show over the sheet.
        .background(
            Color.clear.alert(String(localized: "jackmoebius.rebuild.title"),
                              isPresented: Binding(get: { manager.pendingRebuild != nil },
                                                   set: { if !$0 { DispatchQueue.main.async { manager.cancelRebuild() } } }),
                              presenting: manager.pendingRebuild) { pending in
                Button(String(localized: "jackmoebius.rebuild.confirm")) { manager.confirmRebuild(pending) }
                Button(String(localized: "common.cancel"), role: .cancel) { }
            } message: { pending in
                Text(String(format: String(localized: "jackmoebius.rebuild.message"), pending.name, pending.heldCount))
            }
        )
        .onAppear {
            if manager.advancedOpensOnReservations { tab = .reservations; manager.advancedOpensOnReservations = false }
            manager.refreshBlacklist(); manager.refreshReservations()
        }
    }

    /// « Avancé / débogage »: settings that only help to inspect what JackMoebius does.
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "jackmoebius.advanced.debug.title"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(JM.textTertiary)
                .textCase(.uppercase)
            Toggle(isOn: $manager.showSystemNode) {
                Text(String(localized: "jackmoebius.advanced.show_system_node"))
                    .font(.system(size: 12)).foregroundStyle(.white)
            }
            .toggleStyle(.switch).controlSize(.small).tint(JM.accentCyan)
            Text(String(localized: "jackmoebius.advanced.show_system_node.help"))
                .font(.system(size: 11)).foregroundStyle(JM.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // How full the two channel buses are, shared by every app (amber from 80 %, red when full).
            if let capacity = manager.capacity {
                CapacityGauges(capacity: capacity)
                    .padding(.bottom, 4)
            }
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
        VStack(alignment: .leading, spacing: 4) {
            line
            // Channels a card keeps for an input or output that was removed: reserved, not used.
            if !entry.inHeld.isEmpty {
                heldLine(String(format: String(localized: "jackmoebius.reservations.held.in"), entry.inHeld.count))
            }
            if !entry.outHeld.isEmpty {
                heldLine(String(format: String(localized: "jackmoebius.reservations.held.out"), entry.outHeld.count))
            }
            if entry.heldCount > 0 {
                // Rebuilds the card as it is: frees the unused channels, keeps the app's inputs and outputs.
                Button(String(localized: "jackmoebius.reservations.free_unused")) { manager.requestRebuild(entry) }
                    .buttonStyle(NoticeButtonStyle(tint: JM.accentAmber))
                    .padding(.leading, 36)
            }
            if let refusal = manager.applyErrors[entry.key] {
                ApplyErrorBand(message: refusal.text(appName: entry.name), action: nil) { manager.dismissApplyError(entry.key) }
                    .padding(.leading, 36)
            }
        }
    }

    private func heldLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(JM.accentAmber)
            .padding(.leading, 36)
            .help(String(localized: "jackmoebius.capacity.held.help"))
    }

    private var line: some View {
        HStack(spacing: 8) {
            AppIcon(key: entry.key, fallbackName: entry.name)
                .frame(width: 28, height: 28)
            Text(entry.name)
                .font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            if !entry.outChannels.isEmpty {
                let ch = String(localized: "jackmoebius.app.channels")
                clearChip(label: "\(String(localized: "jackmoebius.app.out")) \(entry.outChannels.count) \(ch)",
                          hovered: outHovered,
                          tip: String(localized: "jackmoebius.advanced.reservations.clear_out")) {
                    manager.clearOutReservation(entry)
                }
                .onHover { outHovered = $0 }
            }
            if entry.inShared {
                // Nothing to free: the shared input reserves no channel. Shown for completeness.
                Text(String(localized: "jackmoebius.reservations.in_shared"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .help(String(localized: "jackmoebius.reservations.in_shared.help"))
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
