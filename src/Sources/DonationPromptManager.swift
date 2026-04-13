
import Foundation
import Combine
import AppKit
import SwiftUI

/// Tracks Jack start events and shows a non-blocking donation prompt every 25 starts.
///
/// Sublime Text-style: the prompt appears after the user has genuinely used the app
/// (any Jack activation — from the UI, menubar, or detected externally), never blocks
/// the workflow, and respects a permanent "Never" choice.
@MainActor
final class DonationPromptManager: ObservableObject {

    /// Explicit publisher required by Swift 6: `@MainActor` classes cannot
    /// synthesise `objectWillChange` automatically without a `@Published` property.
    nonisolated let objectWillChange = ObservableObjectPublisher()

    // MARK: - UserDefaults keys

    private let jackStartCountKey   = "JM.jackStartCount"         // Int: cumulative Jack activations
    private let lastPromptCountKey  = "JM.lastDonationPrompt"     // Int: jackStartCount at last prompt
    private let suppressionKey      = "JM.suppressDonationPrompt" // Bool: permanent "Never"

    // MARK: - Configuration

    /// Show a prompt at the Nth Jack start, then every N starts thereafter.
    private let PROMPT_INTERVAL = 15  // Show after every 15 Jack starts

    // MARK: - Private state

    /// Strong reference to the floating panel so it is not deallocated while visible.
    private var panel: NSPanel?

    /// Combine subscription observing JackManager.isRunning — retained for the lifetime of this object.
    private var cancellable: AnyCancellable?

    // MARK: - Observation setup

    /// Subscribes to `jackManager.$isRunning` via Combine so that Jack start events are
    /// counted regardless of whether any SwiftUI view is currently in the hierarchy.
    /// Call once from `onAppear` of the main window (guaranteed to fire at every launch).
    func startObserving(jackManager: JackManager) {
        guard cancellable == nil else { return }   // idempotent
        cancellable = jackManager.$isRunning
            .filter { $0 }                         // only true → i.e. Jack just started
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recordJackStart() }
    }

    // MARK: - Public API

    /// Increments the cumulative Jack start counter and shows the donation prompt if due.
    func recordJackStart() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: suppressionKey) else { return }

        var count = d.integer(forKey: jackStartCountKey)
        count += 1
        d.set(count, forKey: jackStartCountKey)

        var lastPrompted = d.integer(forKey: lastPromptCountKey)
        // Defensive: stale value from a previous architecture (e.g. stored launchCount instead of
        // jackStartCount). If lastPrompted exceeds the current count, reset it silently.
        if lastPrompted > count {
            lastPrompted = 0
            d.set(0, forKey: lastPromptCountKey)
        }
        let shouldShow   = count >= PROMPT_INTERVAL && (count - lastPrompted) >= PROMPT_INTERVAL
        guard shouldShow else { return }

        // Record immediately so a crash/force-quit doesn't retrigger on next boot.
        d.set(count, forKey: lastPromptCountKey)

        showDonationPanel()
    }

    /// Permanently suppresses future prompts ("Never" button).
    func suppressDonationPrompt() {
        UserDefaults.standard.set(true, forKey: suppressionKey)
    }

    // MARK: - Panel

    /// Creates and displays the floating donation panel (non-blocking).
    /// Jack has already started; this panel is purely informational/optional.
    private func showDonationPanel() {
        // Avoid stacking panels if one is already open.
        if let existing = panel, existing.isVisible { return }

        let p = NSPanel(
            contentRect: .zero,
            styleMask:   [.titled, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        p.title                       = ""
        p.titlebarAppearsTransparent  = true
        p.isMovableByWindowBackground = true
        p.isFloatingPanel             = true
        p.hidesOnDeactivate           = false
        p.isReleasedWhenClosed        = false
        p.backgroundColor             = .clear
        p.isOpaque                    = false

        let sheet = DonationPromptSheet(
            onSupport: { [weak p] in
                p?.close()
                NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/zinc75")!)
            },
            onRemindLater: { [weak p] in
                p?.close()
            },
            onAlreadyDonated: { [weak p] in
                p?.close()
                UserDefaults.standard.set(true, forKey: self.suppressionKey)
            },
            onNever: { [weak p] in
                p?.close()
                UserDefaults.standard.set(true, forKey: self.suppressionKey)
            }
        )

        let hosting = NSHostingView(rootView: sheet)
        hosting.sizingOptions = .intrinsicContentSize
        p.contentView = hosting
        p.setContentSize(hosting.fittingSize)

        // Centre horizontally, vertical midpoint of screen.
        p.center()
        if let screen = NSScreen.main {
            let sf = screen.frame
            let pw = p.frame.width
            let ph = p.frame.height
            let ox = sf.minX + (sf.width  - pw) / 2
            let oy = sf.midY - ph / 2
            p.setFrameOrigin(NSPoint(x: ox, y: oy))
        }

        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }
}

