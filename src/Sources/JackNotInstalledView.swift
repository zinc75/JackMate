//
//  JackNotInstalledView.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Sheet displayed at launch (and on app activation) when the Jack executable
//  is not found on the system. Guides the user through installation options.
//

import SwiftUI

/// A modal sheet shown when the Jack executable is not found on the system.
///
/// Explains what Jack is, why it is required, and — in the GitHub build —
/// lets the user choose between Homebrew and the official `.pkg` installer.
/// Selecting a method dismisses the sheet and updates `jackManager.selectedInstallMethod`.
struct JackNotInstalledView: View {
    @EnvironmentObject var jackManager: JackManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(JM.accentAmber)

                VStack(alignment: .leading, spacing: 5) {
                    Text("jack_not_installed.title")
                        .font(.system(size: 15, weight: .semibold))
                    Text("jack_not_installed.subtitle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()

            // ── Body ──────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 18) {

                Text("jack_not_installed.body")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)

                // ── Installation method choice (GitHub build only) ─────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("jack_not_installed.install_prompt")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)

                    HStack(spacing: 10) {
                        InstallMethodButton(
                            label:    String(localized: "jack_not_installed.method.homebrew"),
                            icon:     "terminal",
                            selected: jackManager.selectedInstallMethod == .homebrew
                        ) {
                            jackManager.selectedInstallMethod = .homebrew
                            dismiss()
                        }
                        InstallMethodButton(
                            label:       String(localized: "jack_not_installed.method.pkg"),
                            icon:        "shippingbox",
                            selected:    jackManager.selectedInstallMethod == .pkg,
                            recommended: true
                        ) {
                            // One-click: download + open the notarized installer. Keep the sheet open
                            // with a spinner while it downloads (dismissed by the isFetchingJackPkg
                            // onChange below once Installer launches). If a newer official release
                            // exists, installJackPkg() opens that page instead → close immediately.
                            jackManager.selectedInstallMethod = .pkg
                            let willDownload = jackManager.jackPkgOneClickAvailable
                            jackManager.installJackPkg()
                            if !willDownload { dismiss() }
                        }
                    }
                    .disabled(jackManager.isFetchingJackPkg)

                    // Download feedback: keep the sheet up with a spinner while the installer fetches.
                    if jackManager.isFetchingJackPkg {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)

            Divider()

            // ── Footer ─────────────────────────────────────────────────────
            HStack {
                Button("jack_not_installed.method.official") {
                    NSWorkspace.shared.open(URL(string: "https://jackaudio.org/downloads/")!)
                }
                Spacer()
                Button("common.close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: jackManager.isFetchingJackPkg) { old, new in
            if old && !new { dismiss() }   // download finished (Installer opened) → close the sheet
        }
    }
}

// MARK: - InstallMethodButton (GitHub build only)

/// A selectable button representing one Jack installation method.
///
/// Renders with a green highlight when `selected` is `true`.
private struct InstallMethodButton: View {
    let label:       String
    let icon:        String
    let selected:    Bool
    var recommended: Bool = false
    let action:      () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                if recommended {
                    Text("jack_not_installed.recommended")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(JM.accentGreen.opacity(0.18)))
                        .foregroundStyle(JM.accentGreen)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected
                          ? JM.accentGreen.opacity(0.15)
                          : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(selected
                                    ? JM.accentGreen.opacity(0.6)
                                    : Color.white.opacity(0.12),
                                    lineWidth: 1)
                    )
            )
            .foregroundStyle(selected ? JM.accentGreen : Color.secondary)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}
