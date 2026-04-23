import SwiftUI
import UIKit

struct TurboProfileSetupView: View {
    let wordmarkName: String
    @Binding var draftProfileName: String
    let isSaving: Bool
    let onShuffle: () -> Void
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = min(geometry.size.width - 48, 360)
            let topInset = max(geometry.size.height * 0.12, 56)
            let wordmarkGap = max(geometry.size.height * 0.1, 44)
            let copyGap = max(geometry.size.height * 0.05, 28)
            let bottomInset = max(geometry.safeAreaInsets.bottom + 24, 28)

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topInset)

                VStack(alignment: .leading, spacing: 0) {
                    Image(wordmarkName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 30)
                        .accessibilityLabel("BeepBeep")

                    Spacer()
                        .frame(height: wordmarkGap)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Choose a name")
                            .font(.system(size: 32, weight: .semibold, design: .default))
                            .tracking(-0.6)

                        Text("People will see this when you share your BeepBeep.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                        .frame(height: copyGap)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            TextField("Name", text: $draftProfileName)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .font(.body)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 15)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                            Button(action: onShuffle) {
                                Image(systemName: "shuffle")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 50, height: 50)
                            }
                            .buttonStyle(.bordered)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityLabel("Shuffle suggested name")
                        }

                        Button(action: onContinue) {
                            Text(isSaving ? "Saving…" : "Continue")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    }
                }
                .frame(width: columnWidth, alignment: .leading)

                Spacer(minLength: bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
    }
}

struct TurboProfileSheet: View {
    @Binding var draftProfileName: String
    let currentIdentityCode: String
    let currentShareLink: String
    let isSavingProfileName: Bool
    let isSigningOut: Bool
    let showsDeveloperControls: Bool
    let onClose: () -> Void
    let onSaveProfileName: () -> Void
    let onSignOut: () -> Void
    let onShowDevIdentity: () -> Void
    let onShowDiagnostics: () -> Void
    let onRunSelfCheck: () -> Void
    let onResetDevState: () -> Void

    private var shareURL: URL? {
        URL(string: currentShareLink)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profileCard
                    identityCard

                    if showsDeveloperControls {
                        developerCard
                    }

                    Button(role: .destructive, action: onSignOut) {
                        Text(isSigningOut ? "Signing Out…" : "Sign Out")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSigningOut || isSavingProfileName)
                }
                .padding()
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    private var profileCard: some View {
        TurboProfileCard(
            title: "Your name",
            subtitle: "You can change this later."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $draftProfileName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button(action: onSaveProfileName) {
                    Text(isSavingProfileName ? "Saving…" : "Save Name")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingProfileName || isSigningOut)
            }
        }
    }

    private var identityCard: some View {
        TurboProfileCard(
            title: "Your BeepBeep",
            subtitle: "This is the share code and link tied to this device identity."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(currentIdentityCode)
                        .font(.headline)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Share link")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(currentShareLink)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button("Copy Code") {
                        UIPasteboard.general.string = currentIdentityCode
                    }
                    .buttonStyle(.bordered)

                    Button("Copy Link") {
                        UIPasteboard.general.string = currentShareLink
                    }
                    .buttonStyle(.bordered)

                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Text("Share")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var developerCard: some View {
        TurboProfileCard(
            title: "Developer",
            subtitle: "Debug-only tools stay here, not in the main flow."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Button("Choose Dev Identity", action: onShowDevIdentity)
                    .buttonStyle(.bordered)

                Button("Diagnostics", action: onShowDiagnostics)
                    .buttonStyle(.bordered)

                Button("Run Self-Check", action: onRunSelfCheck)
                    .buttonStyle(.bordered)

                Button("Reset Dev State", role: .destructive, action: onResetDevState)
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct TurboProfileCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
