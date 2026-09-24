//
//  WhatsNew.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  "What's New" panel shown once at the first launch of a version the user hasn't seen yet
//  (fresh install or update), plus the shared changelog URL. NOT gated on build channel —
//  App Store users update too and should see the release highlights.
//

import SwiftUI
import Combine

// MARK: - WhatsNewManager

@MainActor
final class WhatsNewManager: ObservableObject {

    /// Full changelog on the docs site (GitHub Pages).
    static let changelogURL = URL(string: "https://zinc75.github.io/JackMate/changelog.html")!

    private static let lastRunVersionKey = "JM.lastRunVersion"

    /// The running app version (`CFBundleShortVersionString`).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Drives the What's New sheet — set once at launch when the version has changed.
    @Published var showWhatsNew = false

    /// Shows the sheet at the **first launch of a version the user hasn't seen yet** — both a
    /// fresh install (no version recorded) and an update to a new version — then records the
    /// current version so it fires only once. A plain relaunch of the same version does nothing.
    func checkForVersionChange() {
        let d = UserDefaults.standard
        let previous = d.string(forKey: Self.lastRunVersionKey)
        d.set(Self.currentVersion, forKey: Self.lastRunVersionKey)
        if previous != Self.currentVersion {
            showWhatsNew = true
        }
    }
}

// MARK: - WhatsNewSheet

/// Shown once after an update: a short summary of the release + a link to the full changelog.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "whats_new.title"))
                        .font(.headline).foregroundStyle(JM.textPrimary)
                    Text(verbatim: "JackMate \(WhatsNewManager.currentVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(JM.textTertiary)
                }
            }

            Text(String(localized: "whats_new.body"))
                .font(.system(size: 12))
                .foregroundStyle(JM.textPrimary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            HStack {
                Button(String(localized: "whats_new.jackmoebius")) {
                    NSWorkspace.shared.open(JackMoebiusManager.docsURL)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                Button(String(localized: "whats_new.changelog")) {
                    NSWorkspace.shared.open(WhatsNewManager.changelogURL)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(String(localized: "common.close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
