//
//  PTTViewModel+BackendSync.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

enum IncomingAudioPayloadTransport: Equatable {
    case relayWebSocket
    case mediaRelay
    case directQuic
}

private enum PendingPlaybackDrainDecision {
    case notPending
    case deferTimeout(elapsedNanoseconds: UInt64)
    case exceeded(elapsedNanoseconds: UInt64)
}

extension PTTViewModel {
    func mergedChannelReadinessPreservingWakeCapableFallback(
        existing: TurboChannelReadinessResponse?,
        fetched: TurboChannelReadinessResponse?,
        peerDeviceConnected: Bool,
        peerMembershipPresent: Bool = true,
        existingSessionWasRoutable: Bool = false,
        suppressWakeCapableAudioReadiness: Bool = false
    ) -> TurboChannelReadinessResponse? {
        guard let fetched else { return existing }
        let effectiveFetched: TurboChannelReadinessResponse = {
            guard suppressWakeCapableAudioReadiness,
                  fetched.remoteAudioReadiness == .wakeCapable else {
                return fetched
            }
            return fetched.settingRemoteAudioReadiness(.waiting)
        }()
        guard let existing else { return effectiveFetched }

        let shouldPreserveExplicitReadySignal =
            peerMembershipPresent
            && peerDeviceConnected
            && existingSessionWasRoutable
            && existing.remoteAudioReadiness == .ready
            && effectiveFetched.remoteAudioReadiness == .wakeCapable
        if shouldPreserveExplicitReadySignal {
            return effectiveFetched.settingRemoteAudioReadiness(.ready)
        }

        let fetchedWakeFallbackDowngrade: Bool = {
            guard case .wakeCapable = effectiveFetched.remoteWakeCapability else { return false }
            guard !effectiveFetched.canTransmit else { return false }
            guard !effectiveFetched.peerHasActiveDevice else { return false }
            switch effectiveFetched.statusView {
            case .waitingForPeer:
                return true
            case .inactive, .waitingForSelf, .ready, .selfTransmitting, .peerTransmitting, .unknown:
                return false
            }
        }()

        let shouldPreserveRoutableReadyProjection =
            peerMembershipPresent
            && existingSessionWasRoutable
            && existing.statusView == .ready
            && existing.selfHasActiveDevice
            && existing.peerHasActiveDevice
            && existing.remoteAudioReadiness == .ready
            && !fetchedWakeFallbackDowngrade
            && !effectiveFetched.canTransmit
            && (
                effectiveFetched.selfHasActiveDevice
                || effectiveFetched.peerHasActiveDevice
            )
            && {
                switch effectiveFetched.statusView {
                case .waitingForSelf, .waitingForPeer:
                    return true
                case .inactive, .ready, .selfTransmitting, .peerTransmitting, .unknown:
                    return false
                }
            }()
        if shouldPreserveRoutableReadyProjection {
            diagnostics.record(
                .backend,
                message: "Preserved routable ready projection across transient backend readiness downgrade",
                metadata: [
                    "channelId": effectiveFetched.channelId,
                    "existingStatus": existing.statusKind,
                    "fetchedStatus": effectiveFetched.statusKind,
                    "fetchedSelfHasActiveDevice": String(effectiveFetched.selfHasActiveDevice),
                    "fetchedPeerHasActiveDevice": String(effectiveFetched.peerHasActiveDevice),
                    "fetchedPeerDeviceConnected": String(peerDeviceConnected),
                    "fetchedRemoteAudioReadiness": String(describing: effectiveFetched.remoteAudioReadiness),
                    "existingServerTimestamp": existing.serverTimestamp ?? "none",
                    "fetchedServerTimestamp": effectiveFetched.serverTimestamp ?? "none",
                ]
            )
            return effectiveFetched.preservingRoutableReadyProjection(from: existing)
        }

        guard case .wakeCapable = existing.remoteWakeCapability else {
            return effectiveFetched
        }

        let existingWakeFallbackWasAuthoritative: Bool = {
            if existingSessionWasRoutable {
                return true
            }
            switch existing.statusView {
            case .ready, .selfTransmitting, .peerTransmitting:
                return true
            case .inactive, .waitingForSelf, .waitingForPeer, .unknown:
                return false
            }
        }()

        let fetchedLooksLikeTransientBackgroundDrift: Bool = {
            guard !effectiveFetched.canTransmit else { return false }
            switch effectiveFetched.statusView {
            case .waitingForSelf, .waitingForPeer:
                return true
            case .inactive, .ready, .selfTransmitting, .peerTransmitting, .unknown:
                return false
            }
        }()

        let shouldPreserveWakeCapableFallback =
            peerMembershipPresent
            && (
                !peerDeviceConnected
                || (existingWakeFallbackWasAuthoritative && fetchedLooksLikeTransientBackgroundDrift)
            )
        guard shouldPreserveWakeCapableFallback else { return effectiveFetched }

        var merged = effectiveFetched

        let fetchedWakeCapabilityStillPresent: Bool = {
            if case .wakeCapable = effectiveFetched.remoteWakeCapability {
                return true
            }
            return false
        }()

        if existing.remoteAudioReadiness == .wakeCapable,
           fetchedWakeCapabilityStillPresent,
           !suppressWakeCapableAudioReadiness {
            switch effectiveFetched.remoteAudioReadiness {
            case .waiting, .unknown:
                merged = merged.settingRemoteAudioReadiness(.wakeCapable)
            case .ready, .wakeCapable:
                break
            }
        }

        return merged
    }

    func trackedPresenceFallbackTargets(
        excluding summaries: [UUID: TurboContactSummaryResponse]
    ) -> [(contactID: UUID, handle: String)] {
        let summaryContactIDs = Set(summaries.keys)
        return contacts.compactMap { contact in
            guard trackedContactIDs.contains(contact.id) else { return nil }
            guard !summaryContactIDs.contains(contact.id) else { return nil }
            let normalizedHandle = Contact.normalizedHandle(contact.handle)
            guard normalizedHandle != currentDevUserHandle else { return nil }
            return (contact.id, normalizedHandle)
        }
    }

    func shouldPreserveLocalChannelReferenceForTrackedFallback(contactID: UUID) -> Bool {
        if activeChannelId == contactID || mediaSessionContactID == contactID {
            return true
        }
        if sessionCoordinator.pendingAction.pendingConnectContactID == contactID {
            return true
        }
        return systemSessionMatches(contactID)
    }

    func clearStaleTrackedChannelReferencesMissingFromSummaries(
        excluding summaries: [UUID: TurboContactSummaryResponse]
    ) {
        let summaryContactIDs = Set(summaries.keys)
        let staleTrackedContacts = contacts.filter { contact in
            trackedContactIDs.contains(contact.id)
                && !summaryContactIDs.contains(contact.id)
                && contact.backendChannelId != nil
                && !shouldPreserveLocalChannelReferenceForTrackedFallback(contactID: contact.id)
        }

        guard !staleTrackedContacts.isEmpty else { return }

        for contact in staleTrackedContacts {
            let staleChannelID = contact.backendChannelId ?? "none"
            updateContact(contact.id) { staleContact in
                staleContact.backendChannelId = nil
                staleContact.channelId = UUID()
            }
            backendSyncCoordinator.send(.channelStateCleared(contactID: contact.id))
            diagnostics.record(
                .channel,
                message: "Cleared stale tracked channel reference missing from summaries",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "channelId": staleChannelID,
                ]
            )
        }
    }

    func refreshTrackedContactPresenceFallback(
        excluding summaries: [UUID: TurboContactSummaryResponse]
    ) async {
        guard let backend = backendServices else { return }

        for target in trackedPresenceFallbackTargets(excluding: summaries) {
            do {
                let presence = try await backend.lookupPresence(handle: target.handle)
                updateContact(target.contactID) { contact in
                    contact.isOnline = presence.isOnline
                    contact.remoteUserId = presence.userId
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Tracked presence lookup failed",
                    metadata: ["handle": target.handle, "error": error.localizedDescription]
                )
            }
        }
    }

    func shouldTreatIncomingSignalAsWakeCandidate(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        guard !pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID) else { return false }
        guard receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.hasReceivedAudioChunk != true else {
            return false
        }
        // Once the system-owned PTT audio session is active, later signal-path
        // chunks belong to the current receive flow and must not rearm wake.
        // Foreground receive stays on the existing media path; provisional wake
        // candidates are only for background/inactive receivers that need
        // Apple PTT activation.
        guard !isPTTAudioSessionActive else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    func shouldIgnoreForegroundDirectQuicTransmitControlSignal(
        _ envelope: TurboSignalEnvelope,
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard envelope.type == .transmitStart || envelope.type == .transmitStop else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard !isTransmitting, !pttCoordinator.state.isTransmitting else { return false }
        guard shouldUseDirectQuicTransport(for: contactID) else { return false }
        guard !pttWakeRuntime.hasPendingWake(for: contactID) else { return false }

        let activityState = receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]
        switch envelope.type {
        case .transmitStart:
            guard envelope.payload == "ptt-begin" else { return false }
            return activityState?.hasReceivedAudioChunk == true
                || activityState?.isPeerTransmitting == false
                || (activityState == nil && mediaSessionContactID == contactID && mediaConnectionState == .connected)
        case .transmitStop:
            return activityState == nil || activityState?.isPeerTransmitting == false
        case .offer,
             .answer,
             .iceCandidate,
             .hangup,
             .directQuicUpgradeRequest,
             .selectedPeerPrewarm,
             .audioChunk,
             .receiverReady,
             .receiverNotReady:
            return false
        }
    }

    func shouldBufferDeferredBackgroundAudioAsWakeCandidate(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard !pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID) else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    func shouldUseForegroundAppManagedWakePlayback(
        for contactID: UUID,
        applicationState: UIApplication.State,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) -> Bool {
        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else { return false }
        return prefersForegroundAppManagedReceivePlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        )
    }

    func startForegroundAppManagedWakePlayback(
        for contactID: UUID,
        channelID: String
    ) {
        pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
        pttWakeRuntime.markAppManagedFallbackStarted(for: contactID)
        recordWakeReceiveTiming(
            stage: "foreground-app-managed-playback-started",
            contactID: contactID,
            channelID: channelID
        )
        diagnostics.record(
            .media,
            message: "Using app-managed wake playback for foreground audio",
            metadata: [
                "channelId": channelID,
                "contactId": contactID.uuidString,
            ]
        )
    }

    func shouldTreatIncomingControlSignalAsWakeCandidate(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        guard !isPTTAudioSessionActive else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    func shouldSetSystemRemoteParticipantFromSignalPath(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID
            && !pttCoordinator.state.isTransmitting
    }

    func shouldSuppressForegroundDirectQuicRemoteParticipant(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard directQuicTransmitStartupPolicy == .appleGated else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        return shouldUseDirectQuicTransport(for: contactID)
    }

    func shouldClearSystemRemoteParticipantFromSignalPath(for contactID: UUID) -> Bool {
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        guard pttCoordinator.state.systemChannelUUID == channelUUID else { return false }
        return !pttCoordinator.state.isTransmitting
    }

    func prefersForegroundAppManagedReceivePlayback(for contactID: UUID) -> Bool {
        prefersForegroundAppManagedReceivePlayback(
            for: contactID,
            applicationState: currentApplicationState()
        )
    }

    func prefersForegroundAppManagedReceivePlayback(
        for contactID: UUID,
        applicationState: UIApplication.State,
        incomingAudioTransport: IncomingAudioPayloadTransport? = nil
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        let isSpeculativePolicy = directQuicTransmitStartupPolicy == .speculativeForeground
        let isAppleGatedForegroundDirectAudio =
            directQuicTransmitStartupPolicy == .appleGated
            && incomingAudioTransport == .directQuic
        let isAlreadyAppManagedFallback =
            pttWakeRuntime.incomingWakeActivationState(for: contactID) == .appManagedFallback
        guard isSpeculativePolicy || isAppleGatedForegroundDirectAudio || isAlreadyAppManagedFallback else {
            return false
        }
        return systemSessionMatches(contactID)
    }

    func shouldUseSystemActivatedReceivePlayback(for contactID: UUID) -> Bool {
        shouldUseSystemActivatedReceivePlayback(
            for: contactID,
            applicationState: currentApplicationState()
        )
    }

    func shouldUseSystemActivatedReceivePlayback(
        for contactID: UUID,
        applicationState: UIApplication.State,
        incomingAudioTransport: IncomingAudioPayloadTransport? = nil
    ) -> Bool {
        guard !prefersForegroundAppManagedReceivePlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        ) else { return false }
        guard remoteTransmittingContactIDs.contains(contactID) else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID
            && !pttCoordinator.state.isTransmitting
            && isPTTAudioSessionActive
    }

    func shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard remoteTransmittingContactIDs.contains(contactID) else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    @discardableResult
    func bufferWakeAudioChunkUntilPTTActivation(
        _ payload: String,
        channelID: String,
        contactID: UUID
    ) -> Bool {
        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else { return false }
        pttWakeRuntime.bufferAudioChunk(payload, for: contactID)
        recordWakeReceiveTiming(
            stage: "first-audio-buffered",
            contactID: contactID,
            channelID: channelID,
            ifAbsent: true
        )
        recordWakeReceiveTiming(
            stage: "latest-audio-buffered",
            contactID: contactID,
            channelID: channelID
        )
        diagnostics.record(
            .media,
            message: "Buffered wake audio chunk until PTT activation",
            metadata: ["channelId": channelID, "contactId": contactID.uuidString]
        )
        return true
    }

    func ensurePendingWakeCandidate(
        for contactID: UUID,
        channelId: String,
        senderUserId: String,
        senderDeviceId: String,
        scheduleFallback: Bool = true
    ) {
        let alreadyPending = pttWakeRuntime.hasPendingWake(for: contactID)
        if alreadyPending {
            if scheduleFallback {
                scheduleWakePlaybackFallback(for: contactID)
            }
            return
        }
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
        recordWakeReceiveTiming(
            stage: "provisional-wake-candidate-created",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: channelId,
            subsystem: .pushToTalk,
            metadata: [
                "senderDeviceId": senderDeviceId,
                "senderUserId": senderUserId,
            ]
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
        if scheduleFallback {
            scheduleWakePlaybackFallback(for: contactID)
        }
    }

    func clearRemoteAudioActivity(for contactID: UUID) {
        receiveExecutionCoordinator.send(
            .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: false)
        )
        mediaRuntime.resetIncomingRelayAudioDiagnostics(for: contactID)
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("remote-audio:cleared")
        }
    }

    func markRemoteTransmitStoppedPreservingPlaybackDrain(for contactID: UUID) {
        receiveExecutionCoordinator.send(
            .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: true)
        )
        mediaRuntime.resetIncomingRelayAudioDiagnostics(for: contactID)
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("remote-audio:draining")
        }
    }

    func shouldDeferReceiveTeardownUntilRemoteAudioDrain(for contactID: UUID) -> Bool {
        guard mediaSessionContactID == contactID else { return false }
        guard !isTransmitting else { return false }
        guard let activityState = receiveExecutionCoordinator.state.remoteActivityByContactID[contactID] else {
            return false
        }
        if activityState.hasReceivedAudioChunk {
            return true
        }
        switch pttWakeRuntime.incomingWakeActivationState(for: contactID) {
        case .systemActivated, .appManagedFallback:
            return true
        case .signalBuffered,
             .awaitingSystemActivation,
             .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .none:
            return false
        }
    }

    func finalizeReceiveMediaSessionIfNeeded(
        for contactID: UUID,
        closeMessage: String,
        deferPrewarmMessage: String
    ) {
        let shouldRestoreInteractivePrewarm =
            isJoined
            && activeChannelId == contactID
            && systemSessionMatches(contactID)
            && !isTransmitting

        guard mediaSessionContactID == contactID, !isTransmitting else { return }

        if shouldKeepInteractiveMediaWarmAfterReceiveEnd(
            for: contactID,
            closeMessage: closeMessage
        ) {
            diagnostics.record(
                .media,
                message: "Kept receive media session warm after remote audio ended",
                metadata: [
                    "contactId": contactID.uuidString,
                    "closeMessage": closeMessage,
                ]
            )
            Task {
                await syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .remoteAudioEndedKeepalive
                )
            }
            return
        }

        closeMediaSession(
            preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
        )
        if backendStatusMessage.hasPrefix("Media ") {
            backendStatusMessage = "Connected"
        }
        diagnostics.record(
            .media,
            message: closeMessage,
            metadata: ["contactId": contactID.uuidString]
        )
        if shouldRestoreInteractivePrewarm {
            deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
            diagnostics.record(
                .media,
                message: deferPrewarmMessage,
                metadata: ["contactId": contactID.uuidString]
            )
        }
    }

    private func shouldKeepInteractiveMediaWarmAfterReceiveEnd(
        for contactID: UUID,
        closeMessage: String
    ) -> Bool {
        guard closeMessage == "Closed receive media session after remote audio silence timeout" else {
            return false
        }
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else { return false }
        guard currentApplicationState() == .active else { return false }
        guard selectedContactId == contactID else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard systemSessionMatches(contactID) else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        guard channelSnapshot.membership.hasLocalMembership else { return false }
        guard channelSnapshot.membership.hasPeerMembership else { return false }
        let readiness = channelReadinessByContactID[contactID]
        let transientPeerDeviceLoss =
            channelSnapshot.status == .waitingForPeer
            && readiness?.statusView == .waitingForPeer
            && deviceScopedPeerWakeHintIsAvailableForReceiverAudioReadiness(
                channel: channelSnapshot,
                readiness: readiness
            )

        if !transientPeerDeviceLoss {
            guard channelSnapshot.status == .ready else { return false }
            guard channelSnapshot.canTransmit else { return false }
            guard readiness?.statusView == .ready else { return false }
        }
        return true
    }

    func clearSystemRemoteParticipantIfNeededAfterRemoteAudioEnded(for contactID: UUID) {
        guard shouldClearSystemRemoteParticipantFromSignalPath(for: contactID) else { return }
        Task {
            await updateSystemRemoteParticipant(for: contactID, isActive: false)
        }
    }

    func shouldRecoverRemoteTransmitStopFromChannelRefresh(
        contactID: UUID,
        existingChannelState: TurboChannelStateResponse?,
        effectiveChannelState: TurboChannelStateResponse
    ) -> Bool {
        guard remoteTransmittingContactIDs.contains(contactID) else { return false }
        // Wake receive is still establishing until the pending wake lifecycle
        // clears. Channel refresh must not synthesize a stop during that window,
        // or late-arriving audio will be stranded behind a rearmed wake.
        guard !pttWakeRuntime.hasPendingWake(for: contactID) else { return false }

        let existingLookedLikeReceive =
            existingChannelState?.conversationStatus == .receiving
            || mediaSessionContactID == contactID
            || isPTTAudioSessionActive
        guard existingLookedLikeReceive else { return false }
        return effectiveChannelState.conversationStatus != .receiving
    }

    func recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
        contactID: UUID,
        existingChannelState: TurboChannelStateResponse?,
        effectiveChannelState: TurboChannelStateResponse
    ) async {
        guard shouldRecoverRemoteTransmitStopFromChannelRefresh(
            contactID: contactID,
            existingChannelState: existingChannelState,
            effectiveChannelState: effectiveChannelState
        ) else { return }

        diagnostics.record(
            .backend,
            message: "Recovered missing transmit-stop from channel refresh",
            metadata: [
                "contactId": contactID.uuidString,
                "previousStatus": existingChannelState?.status ?? "none",
                "effectiveStatus": effectiveChannelState.status,
            ]
        )

        let shouldClearRemoteParticipant = shouldClearSystemRemoteParticipantFromSignalPath(for: contactID)
        let shouldPreservePlaybackDrain =
            receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.hasReceivedAudioChunk == true
        if shouldPreservePlaybackDrain {
            markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)
        } else {
            clearRemoteAudioActivity(for: contactID)
        }

        let shouldRestoreInteractivePrewarm =
            isJoined
            && activeChannelId == contactID
            && systemSessionMatches(contactID)
            && !isTransmitting

        if mediaSessionContactID == contactID && !isTransmitting && !shouldPreservePlaybackDrain {
            closeMediaSession(
                preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
            )
            diagnostics.record(
                .media,
                message: "Closed receive media session after channel-refresh transmit stop recovery",
                metadata: ["contactId": contactID.uuidString]
            )
            if shouldRestoreInteractivePrewarm {
                deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
                diagnostics.record(
                    .media,
                    message: "Deferred interactive audio prewarm after channel-refresh transmit stop recovery",
                    metadata: ["contactId": contactID.uuidString]
                )
            }
        }

        if shouldClearRemoteParticipant {
            await updateSystemRemoteParticipant(for: contactID, isActive: false)
        }
    }

    func prepareReceiverForBackendPeerTransmitFromChannelRefreshIfNeeded(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        effectiveChannelReadiness: TurboChannelReadinessResponse?
    ) async {
        let backendShowsPeerTransmit =
            effectiveChannelState.conversationStatus == .receiving
            || effectiveChannelReadiness?.statusView.isPeerTransmitting == true
        guard backendShowsPeerTransmit else { return }
        guard !remoteTransmittingContactIDs.contains(contactID) else { return }
        let applicationState = currentApplicationState()
        guard shouldTreatIncomingSignalAsWakeCandidate(
            for: contactID,
            applicationState: applicationState
        ) else { return }

        let senderUserId =
            effectiveChannelState.activeTransmitterUserId
            ?? effectiveChannelReadiness?.activeTransmitterUserId
            ?? contacts.first(where: { $0.id == contactID })?.remoteUserId
            ?? effectiveChannelState.peerUserId
        let senderDeviceId: String = {
            if case .wakeCapable(let targetDeviceId) = effectiveChannelReadiness?.remoteWakeCapability {
                return targetDeviceId
            }
            return "backend-channel-refresh"
        }()

        ensurePendingWakeCandidate(
            for: contactID,
            channelId: effectiveChannelState.channelId,
            senderUserId: senderUserId,
            senderDeviceId: senderDeviceId,
            scheduleFallback: false
        )
        recordWakeReceiveTiming(
            stage: "backend-peer-transmit-refresh-observed",
            contactID: contactID,
            channelID: effectiveChannelState.channelId,
            subsystem: .backend,
            metadata: [
                "senderUserId": senderUserId,
                "senderDeviceId": senderDeviceId,
                "channelStatus": effectiveChannelState.statusKind,
                "readinessStatus": effectiveChannelReadiness?.statusKind ?? "none",
            ],
            ifAbsent: true
        )
        diagnostics.record(
            .backend,
            message: "Preparing receiver from backend peer-transmitting refresh",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": effectiveChannelState.channelId,
                "senderUserId": senderUserId,
                "senderDeviceId": senderDeviceId,
            ]
        )

        if shouldSetSystemRemoteParticipantFromSignalPath(
            for: contactID,
            applicationState: applicationState
        ) {
            await updateSystemRemoteParticipant(
                for: contactID,
                isActive: true,
                reason: "backend-refresh-remote-active"
            )
        }
    }

    func markRemoteAudioActivity(
        for contactID: UUID,
        source: RemoteReceiveActivitySource = .audioChunk
    ) {
        receiveExecutionCoordinator.send(.remoteActivityDetected(contactID: contactID, source: source))
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
        }
    }

    func remoteReceiveBlocksLocalTransmit(for contactID: UUID) -> Bool {
        if remoteTransmittingContactIDs.contains(contactID) {
            return true
        }
        return remotePlaybackDrainBlocksLocalTransmit(for: contactID)
    }

    func remotePlaybackDrainBlocksLocalTransmit(for contactID: UUID) -> Bool {
        guard mediaSessionContactID == contactID else { return false }
        guard
            let activityState = receiveExecutionCoordinator
                .state
                .remoteActivityByContactID[contactID],
            !activityState.isPeerTransmitting,
            activityState.hasReceivedAudioChunk
        else {
            return false
        }
        return mediaServices.session()?.hasPendingPlayback() == true
    }

    func remoteReceiveProjectsPeerTalking(for contactID: UUID) -> Bool {
        remoteTransmittingContactIDs.contains(contactID)
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

    func shouldTreatChannelRefreshFailureAsAuthoritativeChannelLoss(_ error: Error) -> Bool {
        shouldTreatBackendJoinChannelNotFoundAsRecoverable(error)
    }

    func clearLocalSessionAfterAuthoritativeChannelLoss(
        contactID: UUID,
        backendChannelID: String,
        error: Error
    ) {
        diagnostics.record(
            .channel,
            message: "Clearing local session after authoritative channel loss",
            metadata: [
                "contactId": contactID.uuidString,
                "backendChannelId": backendChannelID,
                "error": error.localizedDescription,
            ]
        )

        clearRemoteAudioActivity(for: contactID)
        if let channelUUID = pttCoordinator.state.systemChannelUUID ?? channelUUID(for: contactID) {
            if isTransmitting {
                try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
            }
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        }
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        pttCoordinator.reset()
        syncPTTState()
        sessionCoordinator.clearPendingConnect(for: contactID)
        sessionCoordinator.clearPendingJoin(for: contactID)
        sessionCoordinator.clearLeaveAction(for: contactID)
        backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
        updateStatusForSelectedContact()
        captureDiagnosticsState("backend-sync:authoritative-channel-loss")
    }

    func shouldPreserveSelectedSessionAfterAuthoritativeChannelLoss(
        contactID: UUID,
        existing: TurboChannelStateResponse?
    ) -> Bool {
        guard selectedContactId == contactID else { return false }
        guard shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID) else {
            return false
        }
        guard sessionCoordinator.pendingAction.pendingTeardownContactID != contactID else {
            return false
        }
        guard channelStateLooksActive(existing) else { return false }
        return true
    }

    func channelStateLooksActive(_ channelState: TurboChannelStateResponse?) -> Bool {
        guard let channelState else { return false }

        let membershipLooksActive =
            channelState.membership.hasLocalMembership
            || channelState.membership.hasPeerMembership
            || channelState.membership.peerDeviceConnected

        if membershipLooksActive {
            return true
        }

        switch channelState.conversationStatus {
        case .waitingForPeer, .ready, .transmitting, .receiving:
            return true
        case .idle, .requested, .incomingRequest, nil:
            return false
        }
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

        let concreteSessionEvidence =
            localSessionEvidenceExists(for: contactID)
            || mediaSessionContactID == contactID
            || remoteTransmittingContactIDs.contains(contactID)

        let existingSessionReady =
            existing.membership.hasLocalMembership
            && existing.membership.hasPeerMembership
            && (
                existing.membership.peerDeviceConnected
                || remoteTransmittingContactIDs.contains(contactID)
                || (
                    existing.conversationStatus == .ready
                    && concreteSessionEvidence
                )
            )

        let existingSessionRecoverableDuringSignalingRecovery =
            existing.membership.hasLocalMembership
            && concreteSessionEvidence
            && {
                switch existing.conversationStatus {
                case .waitingForPeer, .ready, .transmitting, .receiving:
                    return true
                case .idle, .requested, .incomingRequest, nil:
                    return false
                }
            }()

        let incomingLostMembership =
            !incoming.membership.hasLocalMembership
            && !incoming.membership.hasPeerMembership
            && !incoming.membership.peerDeviceConnected

        let incomingLooksTransient =
            incoming.status == "connecting"
            || incoming.status == ConversationState.waitingForPeer.rawValue
            || (
                incoming.status == ConversationState.ready.rawValue
                && existingSessionReady
                && concreteSessionEvidence
            )
            || (
                incoming.status == ConversationState.idle.rawValue
                && (
                    existing.conversationStatus == .receiving
                    || remoteTransmittingContactIDs.contains(contactID)
                    || (
                        backendRuntime.signalingJoinRecoveryTask != nil
                        && existingSessionRecoverableDuringSignalingRecovery
                    )
                    || (
                        existingSessionReady
                        && concreteSessionEvidence
                    )
                )
            )

        return (
            existingSessionReady
                && incomingLostMembership
                && incomingLooksTransient
        ) || (
                backendRuntime.signalingJoinRecoveryTask != nil
                && (existingSessionReady || existingSessionRecoverableDuringSignalingRecovery)
                && incomingLostMembership
                && incomingLooksTransient
            )
    }

    func effectiveChannelStatePreservingLiveMembership(
        contactID: UUID,
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse,
        authoritativeMembershipLoss: Bool = false
    ) -> TurboChannelStateResponse {
        guard let existing else { return incoming }
        guard existing.channelId == incoming.channelId else { return incoming }

        let incomingLostAllMembership =
            !incoming.membership.hasLocalMembership
            && !incoming.membership.hasPeerMembership
            && !incoming.membership.peerDeviceConnected

        if authoritativeMembershipLoss, incomingLostAllMembership {
            return incoming
        }

        if shouldPreserveLiveChannelState(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        ) {
            return existing
        }

        let liveSessionActive =
            shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID)
            || remoteTransmittingContactIDs.contains(contactID)
        guard liveSessionActive else { return incoming }

        let existingSessionReady =
            existing.membership.hasLocalMembership
            && existing.membership.hasPeerMembership
            && (existing.membership.peerDeviceConnected || remoteTransmittingContactIDs.contains(contactID))
        guard existingSessionReady else { return incoming }

        let incomingDroppedOnlyPeerMembership =
            incoming.membership.hasLocalMembership
            && !incoming.membership.hasPeerMembership
            && !incoming.membership.peerDeviceConnected
        let incomingDroppedOnlyLocalMembership =
            !incoming.membership.hasLocalMembership
            && incoming.membership.hasPeerMembership

        if incomingDroppedOnlyLocalMembership {
            let incomingLooksLikeTransientSelfMembershipDrift =
                incoming.status == "connecting"
                || incoming.status == ConversationState.waitingForPeer.rawValue
                || (
                    incoming.status == ConversationState.ready.rawValue
                    && incoming.membership.peerDeviceConnected
                )
            guard incomingLooksLikeTransientSelfMembershipDrift else { return incoming }
            return incoming.settingMembership(existing.membership)
        }

        guard incomingDroppedOnlyPeerMembership else { return incoming }

        let incomingLooksLikeActiveSessionReuse =
            incoming.conversationStatus == .transmitting
            || incoming.status == "connecting"
            || incoming.status == ConversationState.waitingForPeer.rawValue
        guard incomingLooksLikeActiveSessionReuse else { return incoming }

        return incoming.settingMembership(existing.membership)
    }

    func shouldTreatChannelReadinessMembershipLossAsAuthoritative(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "not a channel member"
    }

    func shouldHonorAuthoritativeChannelReadinessMembershipLoss(
        contactID: UUID,
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse
    ) -> Bool {
        if sessionCoordinator.pendingAction.pendingConnectContactID == contactID {
            return false
        }
        if sessionCoordinator.pendingAction.pendingJoinContactID == contactID {
            return false
        }
        if sessionCoordinator.pendingConnectAcceptedIncomingRequestContactID == contactID {
            return false
        }
        if hasChannelMatchedUnattributedSystemSession(contactID: contactID) {
            return false
        }
        if let existingRelationship = existing?.requestRelationship,
           existingRelationship != .none {
            return false
        }
        if incoming.requestRelationship != .none {
            return false
        }
        return true
    }

    func hasChannelMatchedUnattributedSystemSession(contactID: UUID) -> Bool {
        guard case .mismatched(let systemChannelUUID) = systemSessionState else { return false }
        return channelUUID(for: contactID) == systemChannelUUID
    }

    func presenceHeartbeatMinimumInterval(
        backendServices: BackendServices?
    ) -> TimeInterval? {
        guard let backendServices else { return nil }
        if backendServices.shouldSendHTTPPresenceHeartbeat {
            return presenceHeartbeatHTTPFallbackIntervalSeconds
        }
        guard presenceHeartbeatWebSocketIntervalSeconds > 0 else {
            return nil
        }
        return presenceHeartbeatWebSocketIntervalSeconds
    }

    func runBackendSyncEffect(_ effect: BackendSyncEffect) async {
        switch effect {
        case .bootstrapIfNeeded:
            await recoverBackendBootstrapIfNeeded(trigger: "backend-poll")
        case .ensureWebSocketConnected:
            guard shouldMaintainBackgroundControlPlane() else { return }
            backendServices?.ensureWebSocketConnected()
        case .heartbeatPresence:
            guard shouldPublishPresenceHeartbeat() else { return }
            guard let minimumInterval = presenceHeartbeatMinimumInterval(
                backendServices: backendServices
            ) else { return }
            guard backendRuntime.consumePresenceHeartbeatSlot(
                minimumInterval: minimumInterval
            ) else { return }
            _ = try? await backendServices?.heartbeatPresence()
        case .refreshContactSummaries:
            await refreshContactSummaries()
        case .refreshInvites:
            await refreshInvites()
        case .refreshChannelState(let contactID):
            await refreshChannelState(for: contactID)
        case .refreshForegroundControlPlane(let selectedContactID):
            await refreshForegroundControlPlane(selectedContactID: selectedContactID)
        }
    }

    func refreshForegroundControlPlane(selectedContactID: UUID?) async {
        let canRefreshSelectedChannelImmediately = selectedContactID.flatMap { contactID in
            contacts.first(where: { $0.id == contactID })?.backendChannelId
        } != nil

        if let selectedContactID, canRefreshSelectedChannelImmediately {
            async let summaries: Void = refreshContactSummaries()
            async let invites: Void = refreshInvites()
            async let channel: Void = refreshChannelState(for: selectedContactID)
            _ = await (summaries, invites, channel)
            return
        }

        async let summaries: Void = refreshContactSummaries()
        async let invites: Void = refreshInvites()
        _ = await (summaries, invites)

        guard let selectedContactID else { return }
        guard contacts.first(where: { $0.id == selectedContactID })?.backendChannelId != nil else {
            return
        }
        await refreshChannelState(for: selectedContactID)
    }


}
