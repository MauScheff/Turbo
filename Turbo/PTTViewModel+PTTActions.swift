//
//  PTTViewModel+PTTActions.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk

extension PTTViewModel {
    private func performReconciledTeardown(for contactID: UUID) {
        if selectedContactId == contactID {
            remoteTransmittingContactIDs.remove(contactID)
        }
        resetTransmitRuntimeOnly()
        closeMediaSession()
        diagnostics.record(
            .channel,
            message: "Ending local session after peer departure",
            metadata: ["contactId": contactID.uuidString]
        )
        captureDiagnosticsState("session-teardown:start")

        if usesLocalHTTPBackend {
            Task {
                if let contact = contacts.first(where: { $0.id == contactID }),
                   let backendChannelId = contact.backendChannelId {
                    let request = BackendLeaveRequest(contactID: contact.id, backendChannelID: backendChannelId)
                    await backendCommandCoordinator.handle(.leaveRequested(request))
                }
                pttCoordinator.reset()
                syncPTTState()
                resetTransmitSession(closeMediaSession: false)
                sessionCoordinator.clearLeaveAction(for: contactID)
                updateStatusForSelectedContact()
                statusMessage = "Disconnected"
                captureDiagnosticsState("session-teardown:local-finished")
            }
            return
        }

        guard let systemChannelUUID = pttCoordinator.state.systemChannelUUID else {
            pttCoordinator.reset()
            syncPTTState()
            resetTransmitSession(closeMediaSession: false)
            updateStatusForSelectedContact()
            captureDiagnosticsState("session-teardown:local-reset")
            return
        }

        if isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: systemChannelUUID)
        }
        try? pttSystemClient.leaveChannel(channelUUID: systemChannelUUID)
        statusMessage = "Peer disconnected"
        captureDiagnosticsState("session-teardown:ptt-leave-requested")
    }

    func initializeIfNeeded() async {
        guard !pttSystemClient.isReady else { return }
        refreshMicrophonePermission()
        diagnostics.record(.app, message: "Initializing app")
        captureDiagnosticsState("app-initialize:start")
        await configureBackendIfNeeded()

        do {
            try await pttSystemClient.configure(callbacks: pttSystemCallbacks)
            isReady = true
            statusMessage = "Ready to connect"
            diagnostics.record(.pushToTalk, message: "PTT channel manager ready")
            captureDiagnosticsState("app-initialize:ptt-ready")
        } catch {
            statusMessage = "Failed to init: \(error.localizedDescription)"
            diagnostics.record(.pushToTalk, level: .error, message: "PTT init failed", metadata: ["error": error.localizedDescription])
            captureDiagnosticsState("app-initialize:ptt-failed")
        }
    }

    func endSystemSession() {
        guard let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID else { return }
        sessionCoordinator.markExplicitLeave(contactID: selectedContactId)
        if let selectedContactId {
            remoteTransmittingContactIDs.remove(selectedContactId)
        }
        diagnostics.record(.channel, message: "Ending system session", metadata: ["channelUUID": activeSystemChannelUUID.uuidString])

        if let contactID = contactId(for: activeSystemChannelUUID),
           let contact = contacts.first(where: { $0.id == contactID }),
           let backendChannelId = contact.backendChannelId {
            Task {
                let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelId)
                await backendCommandCoordinator.handle(.leaveRequested(request))
            }
        }

        try? pttSystemClient.leaveChannel(channelUUID: activeSystemChannelUUID)
        pttCoordinator.reset()
        syncPTTState()
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        updateStatusForSelectedContact()
        captureDiagnosticsState("system-session:end")
    }

    func joinChannel() {
        guard selectedContact != nil else {
            statusMessage = "Pick a contact"
            return
        }
        Task {
            await requestJoinSelectedPeer()
        }
    }

    func disconnect() {
        Task {
            await requestDisconnectSelectedPeer()
        }
    }

    func performDisconnect() {
        sessionCoordinator.markExplicitLeave(contactID: selectedContactId)
        if let selectedContactId {
            remoteTransmittingContactIDs.remove(selectedContactId)
        }
        resetTransmitRuntimeOnly()
        closeMediaSession()
        diagnostics.record(.channel, message: "Disconnect requested", metadata: ["selectedContactId": selectedContactId?.uuidString ?? "none"])
        captureDiagnosticsState("session-disconnect:start")
        if usesLocalHTTPBackend {
            Task {
                if let contact = selectedContact,
                   let backendChannelId = contact.backendChannelId {
                    let request = BackendLeaveRequest(contactID: contact.id, backendChannelID: backendChannelId)
                    await backendCommandCoordinator.handle(.leaveRequested(request))
                }
                pttCoordinator.reset()
                syncPTTState()
                resetTransmitSession(closeMediaSession: false)
                sessionCoordinator.clearLeaveAction(for: selectedContactId)
                updateStatusForSelectedContact()
                statusMessage = "Disconnected"
                captureDiagnosticsState("session-disconnect:local-finished")
            }
            return
        }

        guard let activeChannelId,
              let channelUUID = channelUUID(for: activeChannelId) else {
            statusMessage = "Disconnected"
            isJoined = false
            sessionCoordinator.clearLeaveAction(for: selectedContactId)
            return
        }

        if isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }
        try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        statusMessage = "Disconnecting..."
        captureDiagnosticsState("session-disconnect:ptt-leave-requested")
    }

    func performConnect(to contact: Contact) {
        if usesLocalHTTPBackend {
            if isJoined, activeChannelId == contact.id {
                return
            }
            sessionCoordinator.queueConnect(contactID: contact.id)
            captureDiagnosticsState("session-connect:queued-local")
            requestBackendJoin(for: contact)
            return
        }

        if isJoined, activeChannelId == contact.id {
            return
        }

        sessionCoordinator.queueConnect(contactID: contact.id)
        captureDiagnosticsState("session-connect:queued")

        if isJoined, let activeChannelId, let channelUUID = channelUUID(for: activeChannelId) {
            if isTransmitting {
                try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
            }
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
            statusMessage = "Connecting..."
            captureDiagnosticsState("session-connect:switching-channel")
        } else {
            requestBackendJoin(for: contact)
        }
    }

    func requestJoinSelectedPeer() async {
        syncSelectedPeerSession()
        captureDiagnosticsState("selected-peer:join-requested")
        await selectedPeerCoordinator.handle(.joinRequested)
    }

    func requestDisconnectSelectedPeer() async {
        syncSelectedPeerSession()
        captureDiagnosticsState("selected-peer:disconnect-requested")
        await selectedPeerCoordinator.handle(.disconnectRequested)
    }

    func reconcileSelectedSessionIfNeeded() async {
        guard selectedContact != nil else { return }
        syncSelectedPeerSession()
        await selectedPeerCoordinator.handle(.reconcileRequested)
    }

    func runSelectedPeerEffect(_ effect: SelectedPeerEffect) async {
        switch effect {
        case .connect(let contactID):
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            captureDiagnosticsState("selected-peer-effect:connect")
            performConnect(to: contact)
        case .disconnect:
            captureDiagnosticsState("selected-peer-effect:disconnect")
            performDisconnect()
        case .restoreLocalSession(let contactID):
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            diagnostics.record(
                .state,
                message: "Restoring local session to match backend-ready channel",
                metadata: ["contactId": contactID.uuidString, "handle": contact.handle]
            )
            captureDiagnosticsState("selected-peer-effect:restore-local")
            joinPTTChannel(for: contact)
        case .teardownLocalSession(let contactID):
            guard selectedContactId == contactID else { return }
            sessionCoordinator.markReconciledTeardown(contactID: contactID)
            diagnostics.record(
                .state,
                message: "Tearing down drifted local session",
                metadata: ["contactId": contactID.uuidString]
            )
            captureDiagnosticsState("selected-peer-effect:teardown-local")
            performReconciledTeardown(for: contactID)
        }
    }

    func runPTTEffect(_ effect: PTTEffect) async {
        switch effect {
        case .syncJoinedChannel(let contactID):
            if let contactID {
                await refreshChannelState(for: contactID)
                await refreshContactSummaries()
                if let backendChannelID = contacts.first(where: { $0.id == contactID })?.backendChannelId {
                    await pttSystemPolicyCoordinator.handle(.backendChannelReady(backendChannelID))
                    syncPTTSystemPolicyState()
                }
            } else {
                updateStatusForSelectedContact()
            }
        case .syncLeftChannel(let contactID, let autoRejoinContactID):
            tearDownTransmitRuntime(resetCoordinator: true)
            closeMediaSession()
            if let contactID,
               let contact = contacts.first(where: { $0.id == contactID }),
               let backendChannelId = contact.backendChannelId {
                let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelId)
                await backendCommandCoordinator.handle(.leaveRequested(request))
            }
            if let autoRejoinContactID,
               let contact = contacts.first(where: { $0.id == autoRejoinContactID }) {
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    requestBackendJoin(for: contact)
                }
            } else {
                backendSyncCoordinator.send(.clearAllChannelStates)
            }
            updateStatusForSelectedContact()
        case .closeMediaSession:
            closeMediaSession()
        case .handleSystemTransmitFailure(let message):
            await transmitCoordinator.handle(.systemBeginFailed(message))
            syncTransmitState()
        }
    }

    func joinPTTChannel(for contact: Contact) {
        guard pttSystemClient.isReady else {
            statusMessage = "Not ready"
            captureDiagnosticsState("ptt-join:not-ready")
            return
        }

        if sessionCoordinator.pendingJoinContactID == contact.id {
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:dedup-pending")
            return
        }

        let localSessionAlreadyActive =
            systemSessionMatches(contact.id)
            || (isJoined && activeChannelId == contact.id)
            || pttCoordinator.state.systemChannelUUID == contact.channelId
        if localSessionAlreadyActive {
            sessionCoordinator.clearPendingJoin(for: contact.id)
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:dedup-active")
            return
        }

        sessionCoordinator.queueJoin(contactID: contact.id)
        do {
            try pttSystemClient.joinChannel(channelUUID: contact.channelId, name: "Chat with \(contact.name)")
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:requested")
        } catch {
            sessionCoordinator.clearPendingJoin(for: contact.id)
            statusMessage = error.localizedDescription
            captureDiagnosticsState("ptt-join:failed-immediate")
        }
    }

    func channelUUID(for contactId: UUID) -> UUID? {
        contacts.first { $0.id == contactId }?.channelId
    }

    func contactId(for channelUUID: UUID) -> UUID? {
        contacts.first { $0.channelId == channelUUID }?.id
    }

    func formatPTTError(_ error: Error) -> String {
        if let channelError = error as? PTChannelError {
            return String(describing: channelError.code)
        }

        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code))"
    }

    func isExpectedPTTStopFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain && nsError.code == 5 {
            return true
        }

        if let channelError = error as? PTChannelError {
            return channelError.code.rawValue == 5
        }

        return false
    }

    func isRecoverablePTTChannelUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain && nsError.code == 1 {
            return true
        }

        if let channelError = error as? PTChannelError {
            return channelError.code.rawValue == 1
        }

        return false
    }

    func recoverStaleSystemChannel(for channelUUID: UUID, contactID: UUID, reason: String) {
        diagnostics.record(
            .pushToTalk,
            message: "Recovering stale system channel",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactID": contactID.uuidString,
                "reason": reason
            ]
        )
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        pttCoordinator.reset()
        syncPTTState()
        sessionCoordinator.clearPendingJoin(for: contactID)
        statusMessage = "Reconnecting..."
        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-recover-stale-channel")

        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.joinPTTChannel(for: contact)
        }
    }

    func classifyPTTJoinFailure(_ error: Error) -> PTTJoinFailureReason {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain, nsError.code == 2 {
            return .channelLimitReached
        }
        return .other(message: formatPTTError(error))
    }
}
