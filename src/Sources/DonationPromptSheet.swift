
import SwiftUI

/// Modal sheet prompting user to support JackMate development via Buy Me A Coffee.
/// Non-intrusive Cyberduck-style: appears after 5+ min sessions, every 10 app opens.
/// Offers three choices: Support (donate), Remind Later, Never.
///
/// Layout mirrors the macOS NSAlert aesthetic: app icon at top, centred title + body,
/// full-width stacked buttons. Displayed in a transparent NSPanel with vibrancy.
struct DonationPromptSheet: View {
    let onSupport: () -> Void
    let onRemindLater: () -> Void
    let onAlreadyDonated: () -> Void
    let onNever: () -> Void

    var body: some View {
        VStack(spacing: 0) {

            // MARK: - App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.top, 24)
                .padding(.bottom, 12)

            // MARK: - Title
            Text(String(localized: "donation.prompt.title"))
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)

            // MARK: - Message
            Text(String(localized: "donation.prompt.message"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
                .padding(.bottom, 20)

            // MARK: - Buttons (full-width, stacked)
            VStack(spacing: 8) {
                Button(action: onSupport) {
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill").font(.system(size: 11))
                        Text(String(localized: "donation.prompt.button.support"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(JM.accentAmber)
                .controlSize(.large)

                Button(action: onRemindLater) {
                    Text(String(localized: "donation.prompt.button.remind"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onAlreadyDonated) {
                    Text(String(localized: "donation.prompt.button.donated"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onNever) {
                    Text(String(localized: "donation.prompt.button.never"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 24)
        .frame(width: 380)
        .background(.ultraThinMaterial)
    }
}


