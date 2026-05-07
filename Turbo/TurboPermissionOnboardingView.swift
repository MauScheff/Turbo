import SwiftUI

enum TurboOnboardingPermissionKind: Equatable {
    case localNetwork
    case microphone
    case notifications

    var title: String {
        switch self {
        case .localNetwork:
            return "Make It Fast"
        case .microphone:
            return "Use Your Voice"
        case .notifications:
            return "Know When They're Ready"
        }
    }

    var message: String {
        switch self {
        case .localNetwork:
            return "Allow Local Network so BeepBeep can connect directly to nearby devices for faster audio."
        case .microphone:
            return "Allow microphone access so you can talk. Audio only sends when you hold to talk."
        case .notifications:
            return "Allow notifications so you can receive talk requests when BeepBeep is not open."
        }
    }

    var allowTitle: String {
        switch self {
        case .localNetwork:
            return "Allow Local Network"
        case .microphone:
            return "Allow Microphone"
        case .notifications:
            return "Allow Notifications"
        }
    }
}

struct TurboPermissionNoticePrompt {
    let kind: TurboOnboardingPermissionKind
    let title: String
    let message: String
    let actionTitle: String
}

struct TurboPermissionOnboardingView: View {
    let wordmarkName: String
    let permission: TurboOnboardingPermissionKind
    let isRequesting: Bool
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = TurboLayout.contentWidth(for: geometry.size.width)
            let topInset = max(geometry.size.height * 0.12, 56)
            let wordmarkGap = max(geometry.size.height * 0.12, 48)
            let copyGap = max(geometry.size.height * 0.06, 32)
            let bottomInset = max(geometry.safeAreaInsets.bottom + 24, 28)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                VStack(spacing: 0) {
                    Image(wordmarkName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("BeepBeep")

                    Spacer()
                        .frame(height: wordmarkGap)

                    VStack(spacing: 10) {
                        Text(permission.title)
                            .font(.system(size: 32, weight: .semibold, design: .default))

                        Text(permission.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                    Spacer()
                        .frame(height: copyGap)

                    VStack(spacing: 12) {
                        Button(action: onAllow) {
                            Text(isRequesting ? "Waiting..." : permission.allowTitle)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: TurboLayout.primaryButtonMaxWidth)
                        .disabled(isRequesting)

                        Button(action: onSkip) {
                            Text("Not Now")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isRequesting)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: columnWidth)
                .frame(maxWidth: .infinity)

                Spacer(minLength: bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, TurboLayout.horizontalPadding)
    }
}

struct TurboPermissionNoticeBanner: View {
    let prompt: TurboPermissionNoticePrompt
    let isRequesting: Bool
    let onEnable: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title)
                    .font(.subheadline.weight(.semibold))
                Text(prompt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: onEnable) {
                Text(isRequesting ? "Waiting..." : prompt.actionTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isRequesting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(Color.red.opacity(0.18))
        }
    }
}
