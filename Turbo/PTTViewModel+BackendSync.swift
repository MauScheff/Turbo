//
//  PTTViewModel+BackendSync.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

extension PTTViewModel {
    private func shouldTreatIncomingSignalAsWakeCandidate(for contactID: UUID) -> Bool {
        guard UIApplication.shared.applicationState != .active else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    private func ensurePendingWakeCandidate(
        for contactID: UUID,
        channelId: String,
        senderUserId: String,
        senderDeviceId: String
    ) {
        guard !pttWakeRuntime.hasPendingWake(for: contactID) else { return }
        guard let channelUUID = channelUUID(for: contactID) else { return }
        let speakerName =
            contacts.first(where: { $0.id == contactID })?.name
            ?? contacts.first(where: { $0.id == contactID })?.handle
            ?? "Remote"
        pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: channelId,
                    activeSpeaker: speakerName,
                    senderUserId: senderUserId,
                    senderDeviceId: senderDeviceId
                )
            )
        )
        diagnostics.record(
            .pushToTalk,
            message: "Created provisional wake candidate from signal path",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactID": contactID.uuidString,
                "channelId": channelId,
            ]
        )
        scheduleWakePlaybackFallback(for: contactID)
    }

    func clearRemoteAudioActivity(for contactID: UUID) {
        remoteAudioSilenceTasks[contactID]?.cancel()
        remoteAudioSilenceTasks[contactID] = nil
        remoteTransmittingContactIDs.remove(contactID)
    }

    func markRemoteAudioActivity(for contactID: UUID) {
        remoteTransmittingContactIDs.insert(contactID)
        remoteAudioSilenceTasks[contactID]?.cancel()
        remoteAudioSilenceTasks[contactID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.remoteAudioSilenceTasks[contactID] = nil
                self.remoteTransmittingContactIDs.remove(contactID)
                if self.selectedContactId == contactID {
                    self.updateStatusForSelectedContact()
                    self.captureDiagnosticsState("remote-audio:cleared")
                }
            }
        }
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
        }
    }

    func isExpectedBackendSyncCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        return error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "cancelled"
    }

    func shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: UUID) -> Bool {
        let localSessionActive = isJoined && activeChannelId == contactID
        let systemSessionActive = systemSessionMatches(contactID)
        let mediaSessionActive = mediaSessionContactID == contactID

        let transmitLifecycleTouchesContact: Bool
        switch transmitCoordinator.state.phase {
        case .idle:
            transmitLifecycleTouchesContact = false
        case .requesting(let transmitContactID),
             .active(let transmitContactID),
             .stopping(let transmitContactID):
            transmitLifecycleTouchesContact = transmitContactID == contactID
        }

        return localSessionActive
            || systemSessionActive
            || mediaSessionActive
            || transmitLifecycleTouchesContact
    }

    func shouldPreserveLiveChannelState(
        contactID: UUID,
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse
    ) -> Bool {
        guard let existing else { return false }
        guard existing.channelId == incoming.channelId else { return false }

        let liveSessionActive =
            shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID)
            || remoteTransmittingContactIDs.contains(contactID)

        guard liveSessionActive else { return false }

        let existingSessionReady =
            existing.selfJoined
            && existing.peerJoined
            && (existing.peerDeviceConnected || remoteTransmittingContactIDs.contains(contactID))

        let incomingLostMembership =
            !incoming.selfJoined
            && !incoming.peerJoined
            && !incoming.peerDeviceConnected

        let transientStatuses = [
            ConversationState.idle.rawValue,
            "connecting",
            ConversationState.waitingForPeer.rawValue,
        ]

        return existingSessionReady
            && incomingLostMembership
            && transientStatuses.contains(incoming.status)
    }

    func runBackendSyncEffect(_ effect: BackendSyncEffect) async {
        switch effect {
        case .ensureWebSocketConnected:
            backendServices?.ensureWebSocketConnected()
        case .heartbeatPresence:
            _ = try? await backendServices?.heartbeatPresence()
        case .refreshContactSummaries:
            await refreshContactSummaries()
        case .refreshInvites:
            await refreshInvites()
        case .refreshChannelState(let contactID):
            await refreshChannelState(for: contactID)
        }
    }

    func handleIncomingSignal(_ envelope: TurboSignalEnvelope) {
        guard let contactID = contacts.first(where: { $0.backendChannelId == envelope.channelId })?.id else {
            backendStatusMessage = "Signal: \(envelope.type.rawValue)"
            return
        }

        switch envelope.type {
        case .transmitStart, .transmitStop:
            if envelope.type == .transmitStart {
                remoteTransmittingContactIDs.insert(contactID)
                if shouldTreatIncomingSignalAsWakeCandidate(for: contactID) {
                    ensurePendingWakeCandidate(
                        for: contactID,
                        channelId: envelope.channelId,
                        senderUserId: envelope.fromUserId,
                        senderDeviceId: envelope.fromDeviceId
                    )
                }
            } else {
                pttWakeRuntime.clear(for: contactID)
                clearRemoteAudioActivity(for: contactID)
                if mediaSessionContactID == contactID && !isTransmitting {
                    closeMediaSession()
                    if backendStatusMessage.hasPrefix("Media ") {
                        backendStatusMessage = "Connected"
                    }
                    diagnostics.record(
                        .media,
                        message: "Closed receive media session after transmit stop",
                        metadata: ["contactId": contactID.uuidString]
                    )
                }
            }
            diagnostics.record(
                .websocket,
                message: "Signal received",
                metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
            )
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:\(envelope.type.rawValue)")
            }
            Task {
                await updateSystemRemoteParticipant(
                    for: contactID,
                    isActive: envelope.type == .transmitStart
                )
                await refreshContactSummaries()
                await refreshChannelState(for: contactID)
            }
        case .audioChunk:
            diagnostics.record(
                .media,
                message: "Audio chunk received",
                metadata: ["channelId": envelope.channelId, "fromDeviceId": envelope.fromDeviceId]
            )
            Task {
                let shouldRepairRemoteParticipant = !remoteTransmittingContactIDs.contains(contactID)
                if shouldTreatIncomingSignalAsWakeCandidate(for: contactID) {
                    ensurePendingWakeCandidate(
                        for: contactID,
                        channelId: envelope.channelId,
                        senderUserId: envelope.fromUserId,
                        senderDeviceId: envelope.fromDeviceId
                    )
                }
                markRemoteAudioActivity(for: contactID)
                if selectedContactId == nil {
                    selectedContactId = contactID
                }
                if shouldRepairRemoteParticipant {
                    await updateSystemRemoteParticipant(for: contactID, isActive: true)
                }
                if pttWakeRuntime.shouldBufferAudioChunk(for: contactID) {
                    pttWakeRuntime.bufferAudioChunk(envelope.payload, for: contactID)
                    diagnostics.record(
                        .media,
                        message: "Buffered wake audio chunk until PTT activation",
                        metadata: ["channelId": envelope.channelId, "contactId": contactID.uuidString]
                    )
                    return
                }
                if mediaSessionContactID == contactID, mediaConnectionState == .preparing {
                    await receiveRemoteAudioChunk(envelope.payload)
                    return
                }
                await ensureMediaSession(for: contactID, startupMode: .playbackOnly)
                await receiveRemoteAudioChunk(envelope.payload)
            }
        case .offer, .answer, .iceCandidate, .hangup:
            backendStatusMessage = "Media relay signaling is not wired in this build"
            diagnostics.record(.websocket, message: "Unsupported signal received", metadata: ["type": envelope.type.rawValue])
        }
    }

    func updateSystemRemoteParticipant(for contactID: UUID, isActive: Bool) async {
        guard let channelUUID = channelUUID(for: contactID) else { return }
        let participantName = isActive
            ? contacts.first(where: { $0.id == contactID })?.name
                ?? contacts.first(where: { $0.id == contactID })?.handle
            : nil
        do {
            try await pttSystemClient.setActiveRemoteParticipant(name: participantName, channelUUID: channelUUID)
            diagnostics.record(
                .pushToTalk,
                message: isActive ? "Set active remote participant" : "Cleared active remote participant",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "participant": participantName ?? "none"
                ]
            )
        } catch {
            if isRecoverablePTTChannelUnavailable(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: isActive
                        ? "Ignoring stale-channel active remote participant set failure"
                        : "Ignoring stale-channel active remote participant clear failure",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "participant": participantName ?? "none",
                        "error": error.localizedDescription
                    ]
                )
                return
            }
            if !isActive && isExpectedPTTStopFailure(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignoring expected active remote participant clear failure",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "participant": participantName ?? "none",
                        "error": error.localizedDescription
                    ]
                )
                return
            }
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: isActive ? "Failed to set active remote participant" : "Failed to clear active remote participant",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "participant": participantName ?? "none",
                    "error": error.localizedDescription
                ]
            )
        }
    }

    func refreshContactSummaries() async {
        guard let backend = backendServices else { return }

        do {
            let summaries = try await backend.contactSummaries()
            var nextSummaries: [UUID: TurboContactSummaryResponse] = [:]
            for summary in summaries {
                let channelID = summary.channelId ?? ""
                let contactID = ensureContactExists(
                    handle: summary.handle,
                    remoteUserId: summary.userId,
                    channelId: channelID
                )
                nextSummaries[contactID] = summary
                updateContact(contactID) { contact in
                    contact.isOnline = summary.isOnline
                    contact.remoteUserId = summary.userId
                    if let channelId = summary.channelId {
                        contact.backendChannelId = channelId
                        contact.channelId = ContactDirectory.stableChannelUUID(for: channelId)
                    }
                }
            }
            let updates = nextSummaries.map { BackendContactSummaryUpdate(contactID: $0.key, summary: $0.value) }
            backendSyncCoordinator.send(.contactSummariesUpdated(updates))
            pruneContactsToAuthoritativeState()
            updateStatusForSelectedContact()
            captureDiagnosticsState("backend-sync:contact-summaries")
            await reconcileSelectedSessionIfNeeded()
        } catch {
            guard !isExpectedBackendSyncCancellation(error) else { return }
            backendSyncCoordinator.send(.contactSummariesFailed("Contact sync failed: \(error.localizedDescription)"))
            diagnostics.record(.backend, level: .error, message: "Contact sync failed", metadata: ["error": error.localizedDescription])
            captureDiagnosticsState("backend-sync:contact-summaries-failed")
            await reconcileSelectedSessionIfNeeded()
        }
    }

    func refreshChannelState(for contactID: UUID) async {
        guard let backend = backendServices,
              let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelId = contact.backendChannelId else {
            backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
            updateStatusForSelectedContact()
            captureDiagnosticsState("backend-sync:channel-cleared")
            return
        }

        do {
            let channelState = try await backend.channelState(channelId: backendChannelId)
            let existingChannelState = backendSyncCoordinator.state.syncState.channelStates[contactID]
            let mergedChannelState = BackendSyncState.effectiveChannelState(
                existing: existingChannelState,
                incoming: channelState
            )
            let effectiveChannelState =
                shouldPreserveLiveChannelState(
                    contactID: contactID,
                    existing: existingChannelState,
                    incoming: mergedChannelState
                )
                ? existingChannelState ?? mergedChannelState
                : mergedChannelState
            let leaveInFlight = sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
            let localSessionEstablished =
                systemSessionMatches(contactID)
                || (isJoined && activeChannelId == contactID)
            let localSessionCleared =
                !systemSessionMatches(contactID)
                && !(isJoined && activeChannelId == contactID)
            sessionCoordinator.reconcileAfterChannelRefresh(
                for: contactID,
                effectiveChannelState: effectiveChannelState,
                localSessionEstablished: localSessionEstablished,
                localSessionCleared: localSessionCleared
            )
            backendSyncCoordinator.send(.channelStateUpdated(contactID: contactID, channelState: channelState))
            updateContact(contactID) { contact in
                contact.isOnline = effectiveChannelState.peerOnline
                contact.remoteUserId = effectiveChannelState.peerUserId
            }
            if selectedContactId == contactID {
                let backendShowsLocalTransmit = effectiveChannelState.status == ConversationState.transmitting.rawValue
                let shouldPreserveTransmitState = shouldPreserveLocalTransmitState(
                    selectedContactID: selectedContactId,
                    refreshedContactID: contactID,
                    backendChannelStatus: effectiveChannelState.status,
                    transmitPhase: transmitCoordinator.state.phase,
                    systemIsTransmitting: pttCoordinator.state.isTransmitting
                )
                isTransmitting = backendShowsLocalTransmit || pttCoordinator.state.isTransmitting
                if !shouldPreserveTransmitState {
                    tearDownTransmitRuntime(resetCoordinator: true)
                }
                updateStatusForSelectedContact()
            }
            captureDiagnosticsState("backend-sync:channel-state")
            await reconcileSelectedSessionIfNeeded()
        } catch {
            guard !isExpectedBackendSyncCancellation(error) else { return }
            backendSyncCoordinator.send(
                .channelStateFailed(
                    contactID: contactID,
                    message: "Channel sync failed: \(error.localizedDescription)"
                )
            )
            if selectedContactId == contactID {
                if !shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID) {
                    resetTransmitSession(closeMediaSession: true)
                }
                updateStatusForSelectedContact()
            }
            diagnostics.record(
                .channel,
                level: .error,
                message: "Channel state refresh failed",
                metadata: ["contactId": contactID.uuidString, "error": error.localizedDescription]
            )
            captureDiagnosticsState("backend-sync:channel-failed")
            await reconcileSelectedSessionIfNeeded()
        }
    }

    func refreshInvites() async {
        guard let backend = backendServices else { return }
        do {
            let incoming = try await backend.incomingInvites()
            let outgoing = try await backend.outgoingInvites()
            var nextIncoming: [UUID: TurboInviteResponse] = [:]
            var nextOutgoing: [UUID: TurboInviteResponse] = [:]
            for invite in incoming {
                if let handle = invite.fromHandle {
                    let contactID = ensureContactExists(
                        handle: handle,
                        remoteUserId: invite.fromUserId,
                        channelId: invite.channelId
                    )
                    nextIncoming[contactID] = invite
                }
            }
            for invite in outgoing {
                if let handle = invite.toHandle {
                    let contactID = ensureContactExists(
                        handle: handle,
                        remoteUserId: invite.toUserId,
                        channelId: invite.channelId
                    )
                    nextOutgoing[contactID] = invite
                }
            }
            let incomingUpdates = nextIncoming.map { BackendInviteUpdate(contactID: $0.key, invite: $0.value) }
            let outgoingUpdates = nextOutgoing.map { BackendInviteUpdate(contactID: $0.key, invite: $0.value) }
            backendSyncCoordinator.send(.invitesUpdated(incoming: incomingUpdates, outgoing: outgoingUpdates, now: .now))
            pruneContactsToAuthoritativeState()
            updateStatusForSelectedContact()
            captureDiagnosticsState("backend-sync:invites")
            await reconcileSelectedSessionIfNeeded()
        } catch {
            guard !isExpectedBackendSyncCancellation(error) else { return }
            backendSyncCoordinator.send(.invitesFailed("Invite sync failed: \(error.localizedDescription)"))
            diagnostics.record(.backend, level: .error, message: "Invite sync failed", metadata: ["error": error.localizedDescription])
            captureDiagnosticsState("backend-sync:invites-failed")
            await reconcileSelectedSessionIfNeeded()
        }
    }
}
