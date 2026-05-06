import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct TurboDiagnosticsView: View {
    let report: DevSelfCheckReport?
    let projection: StateMachineProjection
    let directQuic: DirectQuicDiagnosticsSummary?
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let notificationPermissionStatus: String
    let needsNotificationPermission: Bool
    let localNetworkPermissionStatus: String
    let logFilePath: String?
    let diagnosticsTranscript: String
    let entries: [DiagnosticsEntry]
    let uploadStatus: String?
    let isRequestingMicrophonePermission: Bool
    let isRequestingLocalNetworkPermission: Bool
    let isRequestingNotificationPermission: Bool
    let isRunningDirectQuicDebugAction: Bool
    let onRequestMicrophonePermission: () -> Void
    let onRequestLocalNetworkPermission: () -> Void
    let onRequestNotificationPermission: () -> Void
    let onImportDirectQuicIdentity: () -> Void
    let onUseInstalledDirectQuicIdentity: () -> Void
    let onSetRelayOnlyForced: (Bool) -> Void
    let onSetDirectQuicAutoUpgradeDisabled: (Bool) -> Void
    let onSetDirectQuicTransmitStartupPolicy: (DirectQuicTransmitStartupPolicy) -> Void
    let onForceDirectQuicProbe: () -> Void
    let onClearDirectQuicRetryBackoff: () -> Void
    let onCancelDirectQuicAttempt: () -> Void

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
                diagnosticsRow("Remote audio readiness", projection.selectedSession.remoteAudioReadiness ?? "unknown")
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

            Section("Permission preflight") {
                diagnosticsRow("Local network", localNetworkPermissionStatus)
                Button(isRequestingLocalNetworkPermission ? "Checking…" : "Enable local network") {
                    onRequestLocalNetworkPermission()
                }
                .disabled(isRequestingLocalNetworkPermission)

                diagnosticsRow("Push notifications", notificationPermissionStatus)
                if needsNotificationPermission {
                    Button(isRequestingNotificationPermission ? "Requesting…" : "Enable push notifications") {
                        onRequestNotificationPermission()
                    }
                    .disabled(isRequestingNotificationPermission)
                }
            }

            if let directQuic {
                Section("Direct QUIC") {
                    diagnosticsRow("Selected", directQuic.selectedHandle ?? "none")
                    diagnosticsRow("Role", directQuic.role ?? "none")
                    diagnosticsRow("Identity label", directQuic.identityLabel ?? "none")
                    diagnosticsRow("Identity status", directQuic.identityStatus)
                    diagnosticsRow("Installed identities", "\(directQuic.installedIdentityCount)")
                    diagnosticsRow("Path state", directQuic.transportPathState.label)
                    diagnosticsRow("Relay-only override", directQuic.relayOnlyOverride ? "on" : "off")
                    diagnosticsRow("Auto-upgrade", directQuic.autoUpgradeDisabled ? "off" : "on")
                    diagnosticsRow("Backend advertised", directQuic.backendAdvertisesUpgrade ? "yes" : "no")
                    diagnosticsRow("Effective upgrade", directQuic.effectiveUpgradeEnabled ? "yes" : "no")
                    diagnosticsRow("Probe controller", directQuic.probeControllerReady ? "ready" : "idle")
                    diagnosticsRow("Local device", directQuic.localDeviceID ?? "none")
                    diagnosticsRow("Peer device", directQuic.peerDeviceID ?? "none")
                    diagnosticsRow("Attempt", directQuic.attemptID ?? "none")
                    diagnosticsRow("Channel", directQuic.channelID ?? "none")
                    diagnosticsRow("Attempt active", directQuic.isDirectActive ? "yes" : "no")
                    diagnosticsRow("Remote candidates", "\(directQuic.remoteCandidateCount)")
                    diagnosticsRow("End of candidates", directQuic.remoteEndOfCandidates ? "yes" : "no")
                    diagnosticsRow("Started", formattedDateTime(directQuic.attemptStartedAt))
                    diagnosticsRow("Updated", formattedDateTime(directQuic.lastUpdatedAt))
                    diagnosticsRow(
                        "Nominated path",
                        nominatedPathText(directQuic)
                    )
                    diagnosticsRow(
                        "Retry backoff",
                        retryBackoffText(directQuic)
                    )
                    diagnosticsRow("STUN servers", "\(directQuic.stunServerCount)")
                    diagnosticsRow("Promotion timeout", "\(directQuic.promotionTimeoutMilliseconds) ms")
                    diagnosticsRow("Base retry backoff", "\(directQuic.retryBackoffBaseMilliseconds) ms")
                    diagnosticsRow("Transmit startup", directQuic.transmitStartupPolicy.rawValue)

                    Toggle(
                        "Relay-only override",
                        isOn: Binding(
                            get: { directQuic.relayOnlyOverride },
                            set: onSetRelayOnlyForced
                        )
                    )
                    .disabled(isRunningDirectQuicDebugAction)

                    Button {
                        onSetDirectQuicAutoUpgradeDisabled(!directQuic.autoUpgradeDisabled)
                    } label: {
                        Label(
                            directQuic.autoUpgradeDisabled
                                ? "Enable auto-upgrade"
                                : "Disable auto-upgrade",
                            systemImage: directQuic.autoUpgradeDisabled ? "bolt.fill" : "bolt.slash"
                        )
                    }
                    .disabled(isRunningDirectQuicDebugAction)

                    Picker("Transmit startup", selection: Binding(
                        get: { directQuic.transmitStartupPolicy },
                        set: onSetDirectQuicTransmitStartupPolicy
                    )) {
                        Text("Apple-gated").tag(DirectQuicTransmitStartupPolicy.appleGated)
                        Text("Speculative foreground").tag(DirectQuicTransmitStartupPolicy.speculativeForeground)
                    }
                    .disabled(isRunningDirectQuicDebugAction)

                    Text("PKCS#12 controls are a developer fallback. Production Direct QUIC uses the generated local identity and backend fingerprint registration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(isRunningDirectQuicDebugAction ? "Running…" : "Import debug PKCS#12 identity") {
                        onImportDirectQuicIdentity()
                    }
                    .disabled(isRunningDirectQuicDebugAction)

                    Button(isRunningDirectQuicDebugAction ? "Running…" : "Use installed debug identity") {
                        onUseInstalledDirectQuicIdentity()
                    }
                    .disabled(
                        isRunningDirectQuicDebugAction
                            || directQuic.installedIdentityCount == 0
                    )

                    Button(isRunningDirectQuicDebugAction ? "Running…" : "Force probe") {
                        onForceDirectQuicProbe()
                    }
                    .disabled(
                        isRunningDirectQuicDebugAction
                            || directQuic.selectedHandle == nil
                            || directQuic.relayOnlyOverride
                            || directQuic.peerDeviceID == nil
                            || directQuic.attemptID != nil
                    )

                    Button("Clear retry backoff") {
                        onClearDirectQuicRetryBackoff()
                    }
                    .disabled(
                        isRunningDirectQuicDebugAction
                            || directQuic.selectedHandle == nil
                            || directQuic.retryRemainingMilliseconds == nil
                    )

                    Button("Cancel current attempt") {
                        onCancelDirectQuicAttempt()
                    }
                    .disabled(
                        isRunningDirectQuicDebugAction
                            || directQuic.selectedHandle == nil
                            || directQuic.attemptID == nil
                    )
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
                            Text("section=\(contact.listSection) presence=\(contact.presencePill)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
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

    private func formattedDateTime(_ value: Date?) -> String {
        guard let value else { return "none" }
        return value.formatted(date: .omitted, time: .standard)
    }

    private func nominatedPathText(_ summary: DirectQuicDiagnosticsSummary) -> String {
        guard let address = summary.nominatedRemoteAddress,
              let port = summary.nominatedRemotePort else {
            return "none"
        }
        let source = summary.nominatedPathSource ?? "unknown"
        let kind = summary.nominatedRemoteCandidateKind ?? "observed"
        return "\(source) \(address):\(port) (\(kind))"
    }

    private func retryBackoffText(_ summary: DirectQuicDiagnosticsSummary) -> String {
        guard let reason = summary.retryReason,
              let category = summary.retryCategory,
              let remainingMilliseconds = summary.retryRemainingMilliseconds else {
            return "none"
        }
        let totalMilliseconds = summary.retryBackoffMilliseconds ?? remainingMilliseconds
        return "\(category) \(remainingMilliseconds)ms remaining of \(totalMilliseconds)ms (\(reason))"
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

struct TurboDirectQuicIdentityImportSheet: View {
    let fileName: String
    let suggestedLabel: String
    @Binding var password: String
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("PKCS#12 file") {
                    Text(fileName)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Section("Direct QUIC identity") {
                    diagnosticsTextRow("Label", suggestedLabel)
                    SecureField("PKCS#12 password", text: $password)
                        .textContentType(.password)
                }
            }
            .navigationTitle("Import Identity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? "Importing…" : "Import", action: onImport)
                        .disabled(isImporting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func diagnosticsTextRow(_ label: String, _ value: String) -> some View {
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
}

struct TurboDiagnosticsSheet: View {
    let report: DevSelfCheckReport?
    let projection: StateMachineProjection
    let directQuic: DirectQuicDiagnosticsSummary?
    let microphonePermissionStatus: String
    let needsMicrophonePermission: Bool
    let notificationPermissionStatus: String
    let needsNotificationPermission: Bool
    let localNetworkPermissionStatus: String
    let logFilePath: String?
    let diagnosticsTranscript: String
    let entries: [DiagnosticsEntry]
    let uploadStatus: String?
    let isUploading: Bool
    let isRequestingMicrophonePermission: Bool
    let isRequestingLocalNetworkPermission: Bool
    let isRequestingNotificationPermission: Bool
    let isRunningDirectQuicDebugAction: Bool
    let onClose: () -> Void
    let onUpload: () -> Void
    let onClear: () -> Void
    let onRequestMicrophonePermission: () -> Void
    let onRequestLocalNetworkPermission: () -> Void
    let onRequestNotificationPermission: () -> Void
    let onImportDirectQuicIdentity: (URL, String) -> Void
    let onUseInstalledDirectQuicIdentity: () -> Void
    let onSetRelayOnlyForced: (Bool) -> Void
    let onSetDirectQuicAutoUpgradeDisabled: (Bool) -> Void
    let onSetDirectQuicTransmitStartupPolicy: (DirectQuicTransmitStartupPolicy) -> Void
    let onForceDirectQuicProbe: () -> Void
    let onClearDirectQuicRetryBackoff: () -> Void
    let onCancelDirectQuicAttempt: () -> Void

    @State private var isShowingDirectQuicIdentityImporter: Bool = false
    @State private var pendingDirectQuicIdentityImportURL: URL?
    @State private var draftDirectQuicIdentityPassword: String = ""
    @State private var isShowingDirectQuicIdentityImportSheet: Bool = false

    var body: some View {
        NavigationStack {
            TurboDiagnosticsView(
                report: report,
                projection: projection,
                directQuic: directQuic,
                microphonePermissionStatus: microphonePermissionStatus,
                needsMicrophonePermission: needsMicrophonePermission,
                notificationPermissionStatus: notificationPermissionStatus,
                needsNotificationPermission: needsNotificationPermission,
                localNetworkPermissionStatus: localNetworkPermissionStatus,
                logFilePath: logFilePath,
                diagnosticsTranscript: diagnosticsTranscript,
                entries: entries,
                uploadStatus: uploadStatus,
                isRequestingMicrophonePermission: isRequestingMicrophonePermission,
                isRequestingLocalNetworkPermission: isRequestingLocalNetworkPermission,
                isRequestingNotificationPermission: isRequestingNotificationPermission,
                isRunningDirectQuicDebugAction: isRunningDirectQuicDebugAction,
                onRequestMicrophonePermission: onRequestMicrophonePermission,
                onRequestLocalNetworkPermission: onRequestLocalNetworkPermission,
                onRequestNotificationPermission: onRequestNotificationPermission,
                onImportDirectQuicIdentity: {
                    isShowingDirectQuicIdentityImporter = true
                },
                onUseInstalledDirectQuicIdentity: onUseInstalledDirectQuicIdentity,
                onSetRelayOnlyForced: onSetRelayOnlyForced,
                onSetDirectQuicAutoUpgradeDisabled: onSetDirectQuicAutoUpgradeDisabled,
                onSetDirectQuicTransmitStartupPolicy: onSetDirectQuicTransmitStartupPolicy,
                onForceDirectQuicProbe: onForceDirectQuicProbe,
                onClearDirectQuicRetryBackoff: onClearDirectQuicRetryBackoff,
                onCancelDirectQuicAttempt: onCancelDirectQuicAttempt
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
        .sheet(isPresented: $isShowingDirectQuicIdentityImportSheet) {
            TurboDirectQuicIdentityImportSheet(
                fileName: pendingDirectQuicIdentityImportURL?.lastPathComponent ?? "Identity",
                suggestedLabel: directQuic?.identityLabel ?? "pending",
                password: $draftDirectQuicIdentityPassword,
                isImporting: isRunningDirectQuicDebugAction,
                onCancel: {
                    pendingDirectQuicIdentityImportURL = nil
                    draftDirectQuicIdentityPassword = ""
                    isShowingDirectQuicIdentityImportSheet = false
                },
                onImport: {
                    guard let fileURL = pendingDirectQuicIdentityImportURL else { return }
                    onImportDirectQuicIdentity(fileURL, draftDirectQuicIdentityPassword)
                    pendingDirectQuicIdentityImportURL = nil
                    draftDirectQuicIdentityPassword = ""
                    isShowingDirectQuicIdentityImportSheet = false
                }
            )
        }
        .fileImporter(
            isPresented: $isShowingDirectQuicIdentityImporter,
            allowedContentTypes: [UTType(importedAs: "com.rsa.pkcs-12")]
        ) { result in
            switch result {
            case .success(let url):
                pendingDirectQuicIdentityImportURL = url
                draftDirectQuicIdentityPassword = ""
                isShowingDirectQuicIdentityImportSheet = true
            case .failure:
                break
            }
        }
    }
}
