import SwiftUI

struct TurboHeaderView: View {
    let wordmarkName: String
    let statusMessage: String
    let latestErrorText: String?
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let onAddContact: () -> Void
    let onShowProfile: () -> Void
    let onRequestMicrophonePermission: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Image(wordmarkName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
                    .accessibilityLabel("BeepBeep")

                HStack(spacing: 12) {
                    Spacer()

                    Button(action: onAddContact) {
                        Image(systemName: "plus.circle")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .accessibilityLabel("Add contact")
                    }

                    Button(action: onShowProfile) {
                        Image(systemName: "person.crop.circle")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .accessibilityLabel("Profile")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            if needsMicrophonePermission {
                Button(action: onRequestMicrophonePermission) {
                    Text(microphonePermissionStatus)
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                Text(microphonePermissionStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let latestErrorText {
                Text(latestErrorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }
}

struct TurboEmptyContactsView: View {
    let onAddContact: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()
                .frame(height: 18)

            VStack(spacing: 6) {
                Text("No contacts yet")
                    .font(.title3.weight(.semibold))

                Text("Add someone by QR, link, or code to start talking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
                .frame(height: 26)

            Button(action: onAddContact) {
                Text("Add Contact")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
        }
        .frame(maxWidth: TurboLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct TurboSplashView: View {
    let wordmarkName: String
    let hasCompletedOnboarding: Bool
    let hasContacts: Bool
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let buttonWidth = TurboLayout.primaryButtonWidth(for: geometry.size.width)
            let topInset = max(geometry.size.height * 0.18, 96)
            let bottomInset = max(geometry.safeAreaInsets.bottom + 20, 28)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                Image(wordmarkName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 42)
                    .accessibilityLabel("BeepBeep")

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                Button(action: onContinue) {
                    Text(hasCompletedOnboarding || hasContacts ? "Continue" : "Get Started")
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .frame(width: buttonWidth)
                .padding(.bottom, bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}
