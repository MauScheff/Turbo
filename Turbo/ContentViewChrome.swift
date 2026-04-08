import SwiftUI
import UIKit

struct TurboHeaderView: View {
    let wordmarkName: String
    let statusMessage: String
    let backendStatusMessage: String
    let selfCheckSummary: String?
    let selfCheckPassing: Bool?
    let logFilePath: String?
    let latestErrorText: String?
    let currentDevUserHandle: String
    let diagnosticsHasError: Bool
    let isRunningSelfCheck: Bool
    let isResettingDevState: Bool
    let onBack: () -> Void
    let onShowIdentity: () -> Void
    let onShowDiagnostics: () -> Void
    let onRunSelfCheck: () -> Void
    let onResetDevState: () -> Void

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

            if let logFilePath {
                Text(logFilePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

struct TurboDiagnosticsView: View {
    let report: DevSelfCheckReport?
    let logFilePath: String?
    let diagnosticsTranscript: String
    let entries: [DiagnosticsEntry]

    var body: some View {
        List {
            if let report {
                Section("Self-check") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(report.summary)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(report.isPassing ? Color.primary : Color.red)
                            Spacer()
                            Text(report.completedAt.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if let targetHandle = report.targetHandle {
                            Text("Target: \(targetHandle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(report.steps) { step in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: iconName(for: step.status))
                                    .foregroundStyle(color(for: step.status))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.id.title)
                                        .font(.caption.weight(.semibold))
                                    Text(step.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let logFilePath {
                Section("Log file") {
                    Text(logFilePath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("Copy transcript") {
                        UIPasteboard.general.string = diagnosticsTranscript
                    }
                }
            }

            if entries.isEmpty {
                ContentUnavailableView("No diagnostics yet", systemImage: "waveform.path.ecg")
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.subsystem.rawValue.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(entry.level == .error ? .red : .secondary)
                            Spacer()
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.body)
                        if !entry.metadata.isEmpty {
                            Text(entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func iconName(for status: DevSelfCheckStatus) -> String {
        switch status {
        case .passed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .skipped:
            return "minus.circle.fill"
        }
    }

    private func color(for status: DevSelfCheckStatus) -> Color {
        switch status {
        case .passed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .secondary
        }
    }
}

struct TurboDevIdentitySheet: View {
    @Binding var draftDevUserHandle: String
    let availableDevUserHandles: [String]
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Current backend user") {
                    TextField("Dev handle", text: $draftDevUserHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Use a different handle on each physical device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Suggested handles") {
                    ForEach(availableDevUserHandles, id: \.self) { handle in
                        Button(handle) {
                            draftDevUserHandle = handle
                        }
                    }
                }
            }
            .navigationTitle("Dev Identity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(draftDevUserHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TurboDiagnosticsSheet: View {
    let report: DevSelfCheckReport?
    let logFilePath: String?
    let diagnosticsTranscript: String
    let entries: [DiagnosticsEntry]
    let onClose: () -> Void
    let onClear: () -> Void

    var body: some View {
        NavigationStack {
            TurboDiagnosticsView(
                report: report,
                logFilePath: logFilePath,
                diagnosticsTranscript: diagnosticsTranscript,
                entries: entries
            )
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clear", action: onClear)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
