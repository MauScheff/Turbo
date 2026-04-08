//
//  PTTViewModel+PTT.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk
import AVFAudio

extension PTTViewModel {
    func initializeIfNeeded() async {
        guard !pttSystemClient.isReady else { return }
        diagnostics.record(.app, message: "Initializing app")
        await configureBackendIfNeeded()

        do {
            try await pttSystemClient.configure(delegate: self, restorationDelegate: self)
            isReady = true
            statusMessage = "Ready to connect"
            diagnostics.record(.pushToTalk, message: "PTT channel manager ready")
        } catch {
            statusMessage = "Failed to init: \(error.localizedDescription)"
            diagnostics.record(.pushToTalk, level: .error, message: "PTT init failed", metadata: ["error": error.localizedDescription])
        }
    }

    func endSystemSession() {
        guard let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID else { return }
        sessionCoordinator.markExplicitLeave(contactID: selectedContactId)
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
        cancelPendingTransmitWork()
        transmitRuntime.isPressingTalk = false
        closeMediaSession()
        diagnostics.record(.channel, message: "Disconnect requested", metadata: ["selectedContactId": selectedContactId?.uuidString ?? "none"])
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
                updateStatusForSelectedContact()
                statusMessage = "Disconnected"
            }
            return
        }

        guard let activeChannelId,
              let channelUUID = channelUUID(for: activeChannelId) else {
            statusMessage = "Disconnected"
            isJoined = false
            return
        }

        if isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }
        try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        statusMessage = "Disconnecting..."
    }

    func performConnect(to contact: Contact) {
        if usesLocalHTTPBackend {
            if isJoined, activeChannelId == contact.id {
                return
            }
            sessionCoordinator.queueJoin(contactID: contact.id)
            requestBackendJoin(for: contact)
            return
        }

        if isJoined, activeChannelId == contact.id {
            return
        }

        sessionCoordinator.queueJoin(contactID: contact.id)

        if isJoined, let activeChannelId, let channelUUID = channelUUID(for: activeChannelId) {
            if isTransmitting {
                try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
            }
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
            statusMessage = "Connecting..."
        } else {
            requestBackendJoin(for: contact)
        }
    }

    func requestJoinSelectedPeer() async {
        syncSelectedPeerSession()
        await selectedPeerCoordinator.handle(.joinRequested)
    }

    func requestDisconnectSelectedPeer() async {
        syncSelectedPeerSession()
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
            performConnect(to: contact)
        case .disconnect:
            performDisconnect()
        case .restoreLocalSession(let contactID):
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            diagnostics.record(
                .state,
                message: "Restoring local session to match backend-ready channel",
                metadata: ["contactId": contactID.uuidString, "handle": contact.handle]
            )
            joinPTTChannel(for: contact)
        case .teardownLocalSession(let contactID):
            guard selectedContactId == contactID else { return }
            diagnostics.record(
                .state,
                message: "Tearing down drifted local session",
                metadata: ["contactId": contactID.uuidString]
            )
            performDisconnect()
        }
    }

    func runPTTEffect(_ effect: PTTEffect) async {
        switch effect {
        case .syncJoinedChannel(let contactID):
            if let contactID {
                sessionCoordinator.clearAfterSuccessfulJoin(for: contactID)
                await refreshChannelState(for: contactID)
                await refreshContactSummaries()
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

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken token: Data) {
        let tokenHex = PTTSystemDisplayPolicy.pushTokenHex(from: token)
        let backendChannelID = activeChannelId.flatMap { activeContactID in
            contacts.first(where: { $0.id == activeContactID })?.backendChannelId
        }
        pushTokenHex = tokenHex
        print("PTT push token:", pushTokenHex)
        Task {
            await pttSystemPolicyCoordinator.handle(
                .ephemeralTokenReceived(tokenHex: tokenHex, backendChannelID: backendChannelID)
            )
            syncPTTSystemPolicyState()
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
        let contactID = contactId(for: channelUUID)
        Task {
            await pttCoordinator.handle(
                .didJoinChannel(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: String(describing: reason)
                )
            )
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "Joined channel",
                metadata: ["channelUUID": channelUUID.uuidString, "reason": String(describing: reason)]
            )
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
        let contactID = contactId(for: channelUUID)
        let autoRejoinContactID = sessionCoordinator.autoRejoinContactID(afterLeaving: contactID)
        Task {
            await pttCoordinator.handle(
                .didLeaveChannel(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: String(describing: reason),
                    autoRejoinContactID: autoRejoinContactID
                )
            )
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "Left channel",
                metadata: ["channelUUID": channelUUID.uuidString, "reason": String(describing: reason)]
            )
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: any Error) {
        let message = formatError(error)
        Task {
            await pttCoordinator.handle(.failedToJoinChannel(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Join failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Join failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToLeaveChannel channelUUID: UUID, error: any Error) {
        let message = formatError(error)
        Task {
            await pttCoordinator.handle(.failedToLeaveChannel(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Leave failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Leave failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task {
            await pttCoordinator.handle(
                .didBeginTransmitting(
                    channelUUID: channelUUID,
                    source: String(describing: source)
                )
            )
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "System transmit began",
                metadata: ["channelUUID": channelUUID.uuidString, "source": String(describing: source)]
            )
        }
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task {
            await pttCoordinator.handle(
                .didEndTransmitting(
                    channelUUID: channelUUID,
                    source: String(describing: source)
                )
            )
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "System transmit ended",
                metadata: ["channelUUID": channelUUID.uuidString, "source": String(describing: source)]
            )
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToBeginTransmittingInChannel channelUUID: UUID, error: any Error) {
        cancelPendingTransmitWork()
        let message = formatError(error)
        Task {
            await pttCoordinator.handle(.failedToBeginTransmitting(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Transmit failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "System transmit begin failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToStopTransmittingInChannel channelUUID: UUID, error: any Error) {
        let message = formatError(error)
        Task {
            await pttCoordinator.handle(.failedToStopTransmitting(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Stop failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "System transmit stop failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {}

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {}

    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String : Any]) -> PTPushResult {
        let name = pushPayload["activeSpeaker"] as? String ?? "Remote (stub)"
        let participant = PTParticipant(name: name, image: nil)
        return .activeRemoteParticipant(participant)
    }

    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: contactId(for: channelUUID)))
        syncPTTState()
        let name = PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: channelUUID,
            contacts: contacts,
            fallbackName: channelName
        )
        return PTChannelDescriptor(name: name, image: nil)
    }

    func joinPTTChannel(for contact: Contact) {
        guard pttSystemClient.isReady else {
            statusMessage = "Not ready"
            return
        }
        sessionCoordinator.queueJoin(contactID: contact.id)
        do {
            try pttSystemClient.joinChannel(channelUUID: contact.channelId, name: "Chat with \(contact.name)")
            statusMessage = "Connecting..."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func channelUUID(for contactId: UUID) -> UUID? {
        contacts.first { $0.id == contactId }?.channelId
    }

    func contactId(for channelUUID: UUID) -> UUID? {
        contacts.first { $0.channelId == channelUUID }?.id
    }

    private func formatError(_ error: Error) -> String {
        if let channelError = error as? PTChannelError {
            return String(describing: channelError.code)
        }

        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code))"
    }
}
