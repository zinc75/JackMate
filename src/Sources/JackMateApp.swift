//
//  JackMateApp.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Application entry point: App struct, AppDelegate, About panel,
//  and top-level navigation notification names.
//

import SwiftUI
import AVFoundation
import UserNotifications

// MARK: - Navigation notifications

extension Notification.Name {
    /// Posted to switch the main window to the Configuration tab.
    static let navigateToConfiguration = Notification.Name("JM.navigateToConfiguration")
    /// Posted to switch the main window to the Patchbay tab.
    static let navigateToPatchbay      = Notification.Name("JM.navigateToPatchbay")
    /// Posted after the main window is brought to the front (e.g. from the menu bar).
    static let mainWindowDidOpen       = Notification.Name("JM.mainWindowDidOpen")
}

// MARK: - About panel

private var _aboutPanel: NSPanel?

/// Shows the custom About panel for JackMate.
///
/// Re-raises the existing panel if it is already open, so only one instance
/// exists at a time.
func showAboutPanel() {
    if let panel = _aboutPanel {
        panel.makeKeyAndOrderFront(nil)
        return
    }

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    let panel = NSPanel(
        contentRect: .zero,
        styleMask:   [.titled, .closable, .fullSizeContentView],
        backing:     .buffered,
        defer:       false
    )
    panel.title                       = ""
    panel.titlebarAppearsTransparent  = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed        = false
    panel.appearance                  = NSAppearance(named: .darkAqua)

    let content = AboutView(version: version, build: build)
    let hostingView = NSHostingView(rootView: content)
    panel.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    panel.setContentSize(hostingView.fittingSize)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    _aboutPanel = panel
}

// MARK: - AboutView

/// The SwiftUI content of the JackMate About panel.
///
/// Inspired by the Xcode About layout: app icon on the left,
/// name / version / description / links on the right.
private struct AboutView: View {
    /// Display version string (e.g. `"1.7.2"`).
    let version: String
    /// Build number string.
    let build:   String

    var body: some View {
        HStack(alignment: .center, spacing: 24) {

            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            // App info
            VStack(alignment: .leading, spacing: 0) {
                Text("JackMate")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.bottom, 3)

                Text(verbatim: String(format: String(localized: "about.version"), version, build))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)

                Text("about.description")
                    .font(.system(size: 12))
                    .padding(.bottom, 4)

                Text("about.license")
                    .font(.system(size: 12))
                    .padding(.bottom, 10)

                Text("© 2026 Éric Bavu")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                // Action buttons
                HStack(spacing: 8) {
                    Button("about.button.source") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/zinc75/JackMate")!)
                    }
                    Button("about.button.support") {
                        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/zinc75")!)
                    }
                    Spacer()
                    Button("common.close") { NSApp.keyWindow?.close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .fixedSize()
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - JackMateApp

@main
struct JackMateApp: App {

    @StateObject private var jackManager  = JackManager()
    @StateObject private var audioManager = CoreAudioManager()

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        requestMicrophonePermission()
        NotificationManager.shared.requestAuthorization()
    }

    /// Requests microphone access and re-activates the app window after the system prompt dismisses.
    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                // Bring the app back to the foreground after the user responds
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    var body: some Scene {

        Window("JackMate", id: "main") {
            ContentView()
                .environmentObject(jackManager)
                .environmentObject(audioManager)
                .mainWindowDelegate()
                .onAppear {
                    AppDelegate.shared?.jackManager = jackManager
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 850)
        .defaultPosition(.center)
        .commands {
            // ── App menu ────────────────────────────────────────────────
            CommandGroup(replacing: .windowSize) { }
            CommandGroup(replacing: .appInfo) {
                Button("menu.app.about") { showAboutPanel() }
            }
            CommandGroup(replacing: .systemServices) { }

            // ── View menu ────────────────────────────────────────────────
            CommandGroup(after: .sidebar) {
                Divider()
                Button("menu.view.configuration") {
                    NotificationCenter.default.post(name: .navigateToConfiguration, object: nil)
                }
                .keyboardShortcut("1")
                Button("menu.view.patchbay") {
                    NotificationCenter.default.post(name: .navigateToPatchbay, object: nil)
                }
                .keyboardShortcut("2")
            }

            // ── Help menu — replace default (removes "JackMate Help" helpbook item) ──
            CommandGroup(replacing: .help) {
                Button("menu.help.documentation") {
                    NSWorkspace.shared.open(URL(string: "https://zinc75.github.io/JackMate/")!)
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(jackManager)
                .environmentObject(audioManager)
        } label: {
            Image(systemName: jackManager.isRunning
                  ? "waveform.path.ecg"
                  : "waveform.path")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate

/// The application delegate for JackMate.
///
/// Responsibilities:
/// - Sets `darkAqua` appearance and manages activation policy transitions
/// - Intercepts window close events to show confirmation dialogs
/// - Routes the "window should close" decision from `MainWindowDelegate`
class AppDelegate: NSObject, NSApplicationDelegate {

    /// The shared `AppDelegate` instance, weakly held to avoid retain cycles.
    static weak var shared: AppDelegate?

    /// The `JackManager` instance, injected after the scene finishes launching.
    var jackManager: JackManager?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Start as accessory (no Dock icon), then switch to regular after a short
        // delay so the main window can be presented on first launch.
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    /// Re-opens the main window when the user clicks the Dock icon while no window is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Window close interception

    /// Handles the window-close request forwarded by `MainWindowDelegate`.
    ///
    /// If the suppression preference is set, the window hides immediately.
    /// Otherwise a contextual dialog is presented based on whether Jack is running.
    /// Always returns `false`; the window is hidden rather than destroyed.
    @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let jackManager else {
            hideWindow(sender)
            return false
        }

        if UserDefaults.standard.bool(forKey: "suppressCloseWarning") {
            hideWindow(sender)
            return false
        }

        if jackManager.isRunning {
            showCloseDialogJackRunning(window: sender, jackManager: jackManager)
        } else {
            showCloseDialogJackStopped(window: sender)
        }
        return false
    }

    // MARK: - Close dialog — Jack running (3 buttons)
    //
    // Visual order left → right:
    //   [Quitter et éteindre Jack]  [Quitter JackMate]  [Fermer la fenêtre]
    //
    // NSAlert appends buttons right-to-left, so they are added in reverse order:
    //   addButton #1 → rightmost  → .alertFirstButtonReturn
    //   addButton #2 → centre     → .alertSecondButtonReturn
    //   addButton #3 → leftmost   → .alertThirdButtonReturn

    private func showCloseDialogJackRunning(window: NSWindow, jackManager: JackManager) {
        let alert = NSAlert()
        alert.messageText     = String(localized: "alert.close.jack_running.title")
        alert.informativeText = String(localized: "alert.close.jack_running.message")
        alert.alertStyle = .informational

        // Added in reverse display order
        alert.addButton(withTitle: String(localized: "alert.close.button.hide_window"))   // right   → .alertFirstButtonReturn
        alert.addButton(withTitle: String(localized: "alert.close.button.quit"))          // centre  → .alertSecondButtonReturn
        alert.addButton(withTitle: String(localized: "alert.close.button.quit_and_stop")) // left    → .alertThirdButtonReturn

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "common.no_more_message")

        alert.beginSheetModal(for: window) { [weak self] response in
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "suppressCloseWarning")
            }
            switch response {
            case .alertFirstButtonReturn:
                // Hide the window — Jack keeps running, menu bar remains active
                self?.hideWindow(window)

            case .alertSecondButtonReturn:
                // Quit JackMate — Jack continues in the background
                NSApp.terminate(nil)

            case .alertThirdButtonReturn:
                // Quit and stop Jack (graceful: close clients first if available)
                if let graceful = jackManager.gracefulStop {
                    graceful()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        NSApp.terminate(nil)
                    }
                } else {
                    jackManager.stopJack()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.terminate(nil)
                    }
                }

            default:
                break
            }
        }
    }

    // MARK: - Close dialog — Jack stopped (2 buttons)
    //
    // Visual order left → right:
    //   [Quitter JackMate]  [Fermer la fenêtre]

    private func showCloseDialogJackStopped(window: NSWindow) {
        let alert = NSAlert()
        alert.messageText     = String(localized: "alert.close.jack_stopped.title")
        alert.informativeText = String(localized: "alert.close.jack_stopped.message")
        alert.alertStyle = .informational

        alert.addButton(withTitle: String(localized: "alert.close.button.hide_window")) // right → .alertFirstButtonReturn
        alert.addButton(withTitle: String(localized: "alert.close.button.quit"))        // left  → .alertSecondButtonReturn

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "common.no_more_message")

        alert.beginSheetModal(for: window) { [weak self] response in
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "suppressCloseWarning")
            }
            switch response {
            case .alertFirstButtonReturn:
                // Hide the window, menu bar stays active
                self?.hideWindow(window)

            case .alertSecondButtonReturn:
                // Quit JackMate completely
                NSApp.terminate(nil)

            default:
                break
            }
        }
    }

    // MARK: - Helper

    /// Hides `window` and switches the app to accessory activation policy (no Dock icon).
    private func hideWindow(_ window: NSWindow) {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}
