//
//  WindowDelegate.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//

import AppKit
import SwiftUI

/// A `ViewModifier` that attaches `MainWindowDelegate` to the hosting window.
///
/// Apply via the `mainWindowDelegate()` convenience extension on `View`.
struct WindowDelegateModifier: ViewModifier {
    let delegate = MainWindowDelegate()

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(delegate: delegate))
    }
}

extension View {
    /// Attaches the main window delegate to intercept close and deactivation events.
    func mainWindowDelegate() -> some View {
        modifier(WindowDelegateModifier())
    }
}

// MARK: - NSWindowDelegate

/// Handles window lifecycle events for the JackMate main window.
///
/// Intercepts `windowShouldClose` to delegate the decision to `AppDelegate`,
/// and switches the app to accessory activation policy when the window closes
/// so it retreats to the menu bar without a Dock icon.
class MainWindowDelegate: NSObject, NSWindowDelegate {

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Delegate to AppDelegate; always return false to prevent actual closure
        // (the window hides instead, keeping the app alive in the menu bar).
        _ = AppDelegate.shared?.windowShouldClose(sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Retreat to menu-bar-only mode when the window is hidden.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - WindowAccessor

/// An invisible `NSView` used to reach the parent `NSWindow` from a SwiftUI hierarchy.
///
/// Assigns the provided `NSWindowDelegate` to the window on the next run-loop tick,
/// after the SwiftUI view has been embedded in an actual window.
struct WindowAccessor: NSViewRepresentable {
    let delegate: MainWindowDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = self.delegate
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
