//
//  NotificationManager.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//

import Foundation
import UserNotifications
import SwiftUI
import Combine

// MARK: - Toast model

/// A transient in-window message displayed as an overlay banner.
struct ToastMessage: Equatable {
    /// The text displayed in the toast.
    let text:  String
    /// SF Symbol name used as the leading icon.
    let icon:  String
    /// Tint colour applied to the icon and border.
    let color: Color
}

// MARK: - NotificationManager

/// Manages both macOS system notifications and in-window toast banners.
///
/// Acts as the `UNUserNotificationCenterDelegate` so that notifications
/// are shown even when the app is in the foreground.
/// Access via the shared singleton `NotificationManager.shared`.
@MainActor
final class NotificationManager: NSObject, ObservableObject {

    /// The shared singleton instance.
    static let shared = NotificationManager()

    /// The toast currently visible in the main window, or `nil` when hidden.
    @Published var currentToast: ToastMessage? = nil

    private var toastTask: Task<Void, Never>? = nil

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission

    /// Requests authorisation to display system alerts and play sounds.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    // MARK: - Jack state notifications

    /// Posts a notification and toast indicating that the Jack server has started.
    ///
    /// - Parameter launchedByUs: `true` if JackMate started the server itself,
    ///   `false` if an external Jack process was detected.
    func notifyJackStarted(launchedByUs: Bool) {
        let body = launchedByUs
            ? "Le serveur Jack a démarré via JackMate."
            : "Un serveur Jack externe est en cours d'exécution."
        sendSystem(title: "Jack est actif", body: body, id: "jack.started")
        showToast(ToastMessage(
            text:  "Jack est actif",
            icon:  "waveform.path.ecg",
            color: .green))
    }

    /// Posts a notification and toast indicating that the Jack server has stopped.
    func notifyJackStopped() {
        sendSystem(title: "Jack s'est arrêté",
                   body:  "Le serveur Jack n'est plus actif.",
                   id:    "jack.stopped")
        showToast(ToastMessage(
            text:  "Jack s'est arrêté",
            icon:  "waveform.path",
            color: .secondary))
    }

    /// Posts a critical notification and toast indicating that Jack failed to start.
    func notifyJackFailed() {
        sendSystem(title: "Jack n'a pas démarré",
                   body:  "Vérifiez la configuration dans JackMate.",
                   id:    "jack.failed",
                   sound: .defaultCritical)
        showToast(ToastMessage(
            text:  "Échec du démarrage",
            icon:  "exclamationmark.triangle.fill",
            color: .red))
    }

    // MARK: - Toast

    /// Displays an in-window toast banner and automatically hides it after 3 seconds.
    ///
    /// Cancels any previously scheduled hide task before showing the new toast.
    ///
    /// - Parameter toast: The message to display.
    func showToast(_ toast: ToastMessage) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            currentToast = toast
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    currentToast = nil
                }
            }
        }
    }

    // MARK: - System notification

    /// Schedules a `UNNotificationRequest` for delivery after a short delay.
    ///
    /// Any pending notification with the same `id` is removed before scheduling
    /// the new one to avoid duplicates.
    ///
    /// - Parameters:
    ///   - title: Notification title.
    ///   - body: Notification body text.
    ///   - id: Stable identifier used for deduplication.
    ///   - sound: Optional sound; defaults to `nil` (silent).
    private func sendSystem(title: String,
                            body:  String,
                            id:    String,
                            sound: UNNotificationSound? = nil) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body
        if let sound { content.sound = sound }

        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])

        let request = UNNotificationRequest(
            identifier: id,
            content:    content,
            trigger:    UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Allows notifications to be shown as banners even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
