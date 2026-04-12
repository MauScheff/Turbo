import SwiftUI

struct TurboHeaderView: View {
    let wordmarkName: String
    let statusMessage: String
    let backendStatusMessage: String
    let selfCheckSummary: String?
    let selfCheckPassing: Bool?
    let latestErrorText: String?
    let currentDevUserHandle: String
    let diagnosticsHasError: Bool
    let isRunningSelfCheck: Bool
    let isResettingDevState: Bool
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let onBack: () -> Void
    let onShowIdentity: () -> Void
    let onShowDiagnostics: () -> Void
    let onRunSelfCheck: () -> Void
    let onResetDevState: () -> Void
    let onRequestMicrophonePermission: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Back")
                }

                Spacer()

                Image(wordmarkName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
                    .accessibilityLabel("BeepBeep")

                Spacer()

                Button(action: onShowIdentity) {
                    Image(systemName: "person.crop.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Choose dev identity")
                }

                Button(action: onShowDiagnostics) {
                    Image(systemName: diagnosticsHasError ? "exclamationmark.bubble" : "waveform.path.ecg")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(diagnosticsHasError ? Color.red : Color.primary)
                        .accessibilityLabel("Diagnostics")
                }

                Button(action: onRunSelfCheck) {
                    Image(systemName: isRunningSelfCheck ? "checklist.checked" : "checklist")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(selfCheckPassing == false ? Color.red : Color.primary)
                        .accessibilityLabel("Run self-check")
                }
                .disabled(isRunningSelfCheck || isResettingDevState)

                Button(action: onResetDevState) {
                    Image(systemName: isResettingDevState ? "arrow.clockwise.circle.fill" : "arrow.clockwise.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Reset dev state")
                }
                .disabled(isResettingDevState)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(backendStatusMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let selfCheckSummary {
                Text(selfCheckSummary)
                    .font(.caption2)
                    .foregroundStyle(selfCheckPassing == false ? Color.red : Color.secondary)
                    .lineLimit(2)
            }

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

            Text("Identity: \(currentDevUserHandle)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct TurboPeerLookupBar: View {
    @Binding var draftPeerHandle: String
    let quickPeerHandles: [String]
    let isOpeningPeer: Bool
    let isResettingDevState: Bool
    let openPeer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !quickPeerHandles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPeerHandles, id: \.self) { handle in
                            Button(handle) {
                                draftPeerHandle = handle
                                openPeer(handle)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isOpeningPeer || isResettingDevState)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                TextField("Peer handle", text: $draftPeerHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    openPeer(draftPeerHandle)
                } label: {
                    Text(isOpeningPeer ? "Opening…" : "Open")
                        .frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftPeerHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isOpeningPeer || isResettingDevState)
            }
        }
    }
}

struct TurboSplashView<LookupBar: View>: View {
    let wordmarkName: String
    let backendStatusMessage: String
    let currentDevUserHandle: String
    let lookupBar: LookupBar
    let onShowIdentity: () -> Void
    let onConnect: () -> Void

    init(
        wordmarkName: String,
        backendStatusMessage: String,
        currentDevUserHandle: String,
        @ViewBuilder lookupBar: () -> LookupBar,
        onShowIdentity: @escaping () -> Void,
        onConnect: @escaping () -> Void
    ) {
        self.wordmarkName = wordmarkName
        self.backendStatusMessage = backendStatusMessage
        self.currentDevUserHandle = currentDevUserHandle
        self.lookupBar = lookupBar()
        self.onShowIdentity = onShowIdentity
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(wordmarkName)
                .resizable()
                .scaledToFit()
                .frame(height: 36)
                .accessibilityLabel("BeepBeep")

            Text("Ready to connect")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(backendStatusMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button(action: onShowIdentity) {
                Text("Use \(currentDevUserHandle)")
                    .font(.caption)
            }

            lookupBar
                .padding(.horizontal, 24)

            Button(action: onConnect) {
                Text("Connect")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding()
    }
}
