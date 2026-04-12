import SwiftUI
import UIKit

struct TurboDiagnosticsView: View {
    let report: DevSelfCheckReport?
    let projection: StateMachineProjection
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let logFilePath: String?
    let diagnosticsTranscript: String
    let entries: [DiagnosticsEntry]
    let uploadStatus: String?
    let isRequestingMicrophonePermission: Bool
    let onRequestMicrophonePermission: () -> Void

    var body: some View {
        List {
            if let uploadStatus {
                Section("Published report") {
                    Text(uploadStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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

            Section("Selected session") {
                diagnosticsRow("Selected", projection.selectedSession.selectedHandle ?? "none")
                diagnosticsRow("Phase", projection.selectedSession.selectedPhase)
                diagnosticsRow("Relationship", projection.selectedSession.relationship)
                diagnosticsRow("Status", projection.selectedSession.statusMessage)
                diagnosticsRow("Can transmit", projection.selectedSession.canTransmitNow ? "yes" : "no")
                diagnosticsRow("Joined locally", projection.selectedSession.isJoined ? "yes" : "no")
                diagnosticsRow("Transmitting", projection.selectedSession.isTransmitting ? "yes" : "no")
                diagnosticsRow("Pending action", projection.selectedSession.pendingAction)
                diagnosticsRow("System session", projection.selectedSession.systemSession)
                diagnosticsRow("Media state", projection.selectedSession.mediaState)
                diagnosticsRow("Backend channel status", projection.selectedSession.backendChannelStatus ?? "none")
                diagnosticsRow("Backend readiness", projection.selectedSession.backendReadiness ?? "none")
                diagnosticsRow("Backend membership", projection.selectedSession.backendMembership ?? "none")
                diagnosticsRow("Backend request relationship", projection.selectedSession.backendRequestRelationship ?? "none")
                diagnosticsRow("Backend self joined", boolText(projection.selectedSession.backendSelfJoined))
                diagnosticsRow("Backend peer joined", boolText(projection.selectedSession.backendPeerJoined))
                diagnosticsRow("Peer device connected", boolText(projection.selectedSession.backendPeerDeviceConnected))
                diagnosticsRow("Backend can transmit", boolText(projection.selectedSession.backendCanTransmit))
                diagnosticsRow("Active channel", projection.selectedSession.activeChannelID ?? "none")
                diagnosticsRow("WebSocket", projection.isWebSocketConnected ? "connected" : "disconnected")
            }

            Section("Audio") {
                diagnosticsRow("Microphone", microphonePermissionStatus)
                if needsMicrophonePermission {
                    Button(isRequestingMicrophonePermission ? "Requesting…" : "Enable microphone") {
                        onRequestMicrophonePermission()
                    }
                    .disabled(isRequestingMicrophonePermission)
                }
            }

            if !projection.contacts.isEmpty {
                Section("Contacts") {
                    ForEach(projection.contacts) { contact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contact.handle)
                                .font(.caption.weight(.semibold))
                            Text("online=\(contact.isOnline ? "yes" : "no") listState=\(contact.listState)")
                                .font(.caption.monospaced())
                            Text("badge=\(contact.badgeStatus ?? "none") relationship=\(contact.requestRelationship) incoming=\(contact.hasIncomingRequest ? "yes" : "no") outgoing=\(contact.hasOutgoingRequest ? "yes" : "no") requestCount=\(contact.requestCount)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text("incomingInviteCount=\(contact.incomingInviteCount.map(String.init(describing:)) ?? "none") outgoingInviteCount=\(contact.outgoingInviteCount.map(String.init(describing:)) ?? "none")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
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

    @ViewBuilder
    private func diagnosticsRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func boolText(_ value: Bool?) -> String {
        guard let value else { return "none" }
        return value ? "yes" : "no"
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
    let projection: StateMachineProjection
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let logFilePath: String?
    let diagnosticsTranscript: String
    let entries: [DiagnosticsEntry]
    let uploadStatus: String?
    let isUploading: Bool
    let isRequestingMicrophonePermission: Bool
    let onClose: () -> Void
    let onUpload: () -> Void
    let onClear: () -> Void
    let onRequestMicrophonePermission: () -> Void

    var body: some View {
        NavigationStack {
            TurboDiagnosticsView(
                report: report,
                projection: projection,
                microphonePermissionStatus: microphonePermissionStatus,
                needsMicrophonePermission: needsMicrophonePermission,
                logFilePath: logFilePath,
                diagnosticsTranscript: diagnosticsTranscript,
                entries: entries,
                uploadStatus: uploadStatus,
                isRequestingMicrophonePermission: isRequestingMicrophonePermission,
                onRequestMicrophonePermission: onRequestMicrophonePermission
            )
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isUploading ? "Uploading…" : "Upload", action: onUpload)
                        .disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clear", action: onClear)
                        .disabled(isUploading)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
