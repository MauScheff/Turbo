import SwiftUI

struct TurboHeaderView: View {
    let statusMessage: String?
    let transportPathState: MediaTransportPathState?
    let transportPathTint: Color
    let latestErrorText: String?
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let notificationPermissionStatus: String
    let needsNotificationPermission: Bool
    let localNetworkPermissionStatus: String
    let showsLocalNetworkPermissionControl: Bool
    let showsResolvedMicrophoneStatus: Bool
    let showsDebugPermissionControls: Bool
    let showsAddContactButton: Bool
    let showsAudioRoutePicker: Bool
    let onAddContact: () -> Void
    let onShowProfile: () -> Void
    let onShowTransportPathInfo: () -> Void
    let onRequestMicrophonePermission: () -> Void
    let onRequestLocalNetworkPermission: () -> Void
    let onRequestNotificationPermission: () -> Void

    private let navigationButtonWidth: CGFloat = 32

    var body: some View {
        let trailingButtonCount = (showsAudioRoutePicker ? 1 : 0) + (showsAddContactButton ? 1 : 0)
        let sideWidth = navigationButtonWidth * CGFloat(max(1, trailingButtonCount))
            + 12 * CGFloat(max(0, trailingButtonCount - 1))

        VStack(spacing: 8) {
            ZStack {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, sideWidth + 16)
                }

                HStack(spacing: 12) {
                    Button(action: onShowProfile) {
                        Image(systemName: "person.crop.circle")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .accessibilityLabel("Profile")
                    }
                    .frame(width: navigationButtonWidth, height: navigationButtonWidth)

                    Spacer(minLength: 0)

                    if showsAudioRoutePicker {
                        AudioRoutePickerButton(style: .icon)
                            .foregroundStyle(.primary)
                            .frame(width: navigationButtonWidth, height: navigationButtonWidth)
                    }

                    if showsAddContactButton {
                        Button(action: onAddContact) {
                            Image(systemName: "plus.circle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                                .accessibilityLabel("Add contact")
                        }
                        .frame(width: navigationButtonWidth, height: navigationButtonWidth)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            if let transportPathState {
                Button(action: onShowTransportPathInfo) {
                    TurboTransportPathBadge(
                        state: transportPathState,
                        tint: transportPathTint
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(transportPathState.label) connection path")
                .accessibilityHint("Shows what the connection badge means")
            }

            if needsMicrophonePermission {
                Button(action: onRequestMicrophonePermission) {
                    Text(microphonePermissionStatus)
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else if showsResolvedMicrophoneStatus {
                Text(microphonePermissionStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if showsDebugPermissionControls {
                VStack(spacing: 6) {
                    if showsLocalNetworkPermissionControl {
                        Button(action: onRequestLocalNetworkPermission) {
                            Text(localNetworkPermissionStatus)
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text(localNetworkPermissionStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if needsNotificationPermission {
                        Button(action: onRequestNotificationPermission) {
                            Text(notificationPermissionStatus)
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text(notificationPermissionStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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

struct TurboTransportPathInfoModal: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Text("Connection types")
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            VStack(alignment: .leading, spacing: 12) {
                TurboTransportPathInfoRow(
                    state: .direct,
                    tint: .green,
                    description: "Fast device-to-device audio. Needs Local Network access."
                )

                TurboTransportPathInfoRow(
                    state: .relay,
                    tint: .orange,
                    description: "Audio passes through BeepBeep when direct is not available."
                )
            }

            Text("Your audio is end-to-end encrypted on both paths, so not even BeepBeep can listen. We use the fastest connection available automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        .padding(.horizontal, 18)
    }
}

private struct TurboTransportPathInfoRow: View {
    let state: MediaTransportPathState
    let tint: Color
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TurboTransportPathBadge(state: state, tint: tint)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TurboTransportPathBadge: View {
    let state: MediaTransportPathState
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            if state.showsSecureIcon {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
            }

            Text(state.label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14))
        .foregroundStyle(tint)
        .clipShape(Capsule())
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

                Text("Add someone by QR, link, or handle to start talking.")
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

struct TurboLaunchSplashView: View {
    let wordmarkName: String

    var body: some View {
        GeometryReader { geometry in
            let topInset = max(geometry.size.height * 0.42, 180)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                Image(wordmarkName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 42)
                    .frame(maxWidth: TurboLayout.contentMaxWidth)
                    .accessibilityLabel("BeepBeep")

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}

struct TurboStartView: View {
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
