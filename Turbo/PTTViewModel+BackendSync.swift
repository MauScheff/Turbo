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
    case directQuic
}

private enum PendingPlaybackDrainDecision {
    case notPending
    case deferTimeout(elapsedNanoseconds: UInt64)
    case exceeded(elapsedNanoseconds: UInt64)
}

extension PTTViewModel {
    private var encryptedAudioRecoveryMaxBufferedPayloads: Int { 16 }
    private var encryptedAudioRecoveryAttempts: Int { 6 }
    private var encryptedAudioRecoveryRetryNanoseconds: UInt64 { 250_000_000 }

    private func remoteAudioTimeoutNanoseconds(for phase: RemoteReceiveTimeoutPhase) -> UInt64 {
        switch phase {
        case .awaitingFirstAudioChunk:
            return remoteAudioInitialChunkTimeoutNanoseconds
        case .drainingAudio:
            return remoteAudioSilenceTimeoutNanoseconds
        }
    }

    func runReceiveExecutionEffect(_ effect: ReceiveExecutionEffect) {
        switch effect {
        case .scheduleRemoteSilenceTimeout(let contactID, let phase, let generation):
            let task = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: self?.remoteAudioTimeoutNanoseconds(for: phase) ?? 0
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard
                        let activityState = self.receiveExecutionCoordinator
                            .state
                            .remoteActivityByContactID[contactID],
                        activityState.timeoutPhase == phase,
                        activityState.activityGeneration == generation
                    else {
                        return
                    }
                    self.handleRemoteAudioSilenceTimeout(for: contactID, phase: phase)
                }
            }
            receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: task)

        case .cancelRemoteSilenceTimeout(let contactID):
            receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: nil)

        case .cancelAllRemoteSilenceTimeouts:
            receiveExecutionRuntime.cancelAllRemoteAudioSilenceTasks()
        }
    }

    func handleRemoteAudioSilenceTimeout(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase? = nil
    ) {
        let resolvedPhase = phase
            ?? receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.timeoutPhase
            ?? .drainingAudio
        switch pendingPlaybackDrainDecision(for: contactID, phase: resolvedPhase) {
        case .deferTimeout(let elapsedNanoseconds):
            diagnostics.record(
                .media,
                message: "Deferred remote audio silence timeout while playback is still draining",
                metadata: [
                    "contactId": contactID.uuidString,
                    "phase": resolvedPhase.rawValue,
                    "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
                    "maxMilliseconds": String(remoteAudioPendingPlaybackDrainMaxNanoseconds / 1_000_000),
                ]
            )
            runReceiveExecutionEffect(
                .scheduleRemoteSilenceTimeout(
                    contactID: contactID,
                    phase: resolvedPhase,
                    generation: receiveExecutionCoordinator
                        .state
                        .remoteActivityByContactID[contactID]?
                        .activityGeneration ?? 0
                )
            )
            return
        case .exceeded(let elapsedNanoseconds):
            diagnostics.recordInvariantViolation(
                invariantID: "selected.receiving_stale_pending_playback_drain",
                scope: .local,
                message: "selectedPeerPhase=receiving while pending playback drain exceeded maximum duration",
                metadata: [
                    "contactId": contactID.uuidString,
                    "phase": resolvedPhase.rawValue,
                    "elapsedMilliseconds": String(elapsedNanoseconds / 1_000_000),
                    "maxMilliseconds": String(remoteAudioPendingPlaybackDrainMaxNanoseconds / 1_000_000),
                    "backendChannelStatus": selectedChannelSnapshot(for: contactID)?.status?.rawValue ?? "none",
                    "backendReadiness": selectedChannelSnapshot(for: contactID)?.readinessStatus?.kind ?? "none",
                    "selectedPeerPhase": String(describing: selectedPeerState(for: contactID).phase),
                ]
            )
        case .notPending:
            break
        }
        if shouldDeferRemoteAudioSilenceTimeout(for: contactID, phase: resolvedPhase) {
            diagnostics.record(
                .media,
                message: "Deferred remote audio silence timeout while peer transmit is authoritative",
                metadata: [
                    "contactId": contactID.uuidString,
                    "phase": resolvedPhase.rawValue,
                    "backendChannelStatus": selectedChannelSnapshot(for: contactID)?.status?.rawValue ?? "none",
                    "remoteActivityActive": String(remoteTransmittingContactIDs.contains(contactID)),
                ]
            )
            runReceiveExecutionEffect(
                .scheduleRemoteSilenceTimeout(
                    contactID: contactID,
                    phase: resolvedPhase,
                    generation: receiveExecutionCoordinator
                        .state
                        .remoteActivityByContactID[contactID]?
                        .activityGeneration ?? 0
                )
            )
            return
        }
        receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: nil)
        receiveExecutionRuntime.clearPendingPlaybackDrainDeferral(for: contactID)
        receiveExecutionCoordinator.send(.silenceTimeoutElapsed(contactID: contactID))
        diagnostics.record(
            .media,
            message: resolvedPhase == .awaitingFirstAudioChunk
                ? "Initial remote audio chunk timed out"
                : "Remote audio activity timed out",
            metadata: [
                "contactId": contactID.uuidString,
                "phase": resolvedPhase.rawValue,
            ]
        )

        switch pttWakeRuntime.incomingWakeActivationState(for: contactID) {
        case .systemActivated, .appManagedFallback:
            pttWakeRuntime.clear(for: contactID)
            diagnostics.record(
                .pushToTalk,
                message: "Cleared completed wake state after remote audio activity ended",
                metadata: ["contactId": contactID.uuidString]
            )
        case .signalBuffered,
             .awaitingSystemActivation,
             .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .none:
            break
        }

        finalizeReceiveMediaSessionIfNeeded(
            for: contactID,
            closeMessage: "Closed receive media session after remote audio silence timeout",
            deferPrewarmMessage: "Deferred interactive audio prewarm after remote audio silence timeout"
        )
        clearSystemRemoteParticipantIfNeededAfterRemoteAudioEnded(for: contactID)

        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("remote-audio:cleared")
        }
    }

    private func pendingPlaybackDrainDecision(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase
    ) -> PendingPlaybackDrainDecision {
        guard phase == .drainingAudio else { return .notPending }
        guard mediaSessionContactID == contactID else {
            receiveExecutionRuntime.clearPendingPlaybackDrainDeferral(for: contactID)
            return .notPending
        }
        guard mediaServices.session()?.hasPendingPlayback() == true else {
            receiveExecutionRuntime.clearPendingPlaybackDrainDeferral(for: contactID)
            return .notPending
        }

        let elapsedNanoseconds = receiveExecutionRuntime
            .pendingPlaybackDrainDeferralElapsedNanoseconds(for: contactID)
        guard elapsedNanoseconds < remoteAudioPendingPlaybackDrainMaxNanoseconds else {
            receiveExecutionRuntime.clearPendingPlaybackDrainDeferral(for: contactID)
            return .exceeded(elapsedNanoseconds: elapsedNanoseconds)
        }
        return .deferTimeout(elapsedNanoseconds: elapsedNanoseconds)
    }

    private func shouldDeferRemoteAudioSilenceTimeout(
        for contactID: UUID,
        phase: RemoteReceiveTimeoutPhase
    ) -> Bool {
        guard phase == .drainingAudio else { return false }
        guard remoteTransmittingContactIDs.contains(contactID) else { return false }
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        return channelSnapshot.status == .receiving
            || channelSnapshot.readinessStatus?.isPeerTransmitting == true
    }

    func shouldResumeLocalInteractivePrewarmForRemoteReady(
        contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard selectedContactId == contactID else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard systemSessionMatches(contactID) else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard !remoteTransmittingContactIDs.contains(contactID) else { return false }

        switch localMediaWarmupState(for: contactID) {
        case .cold, .failed:
            return true
        case .prewarming, .ready:
            return false
        }
    }

    func resumeLocalInteractivePrewarmForRemoteReady(
        contactID: UUID,
        applicationState: UIApplication.State
    ) async {
        guard shouldResumeLocalInteractivePrewarmForRemoteReady(
            contactID: contactID,
            applicationState: applicationState
        ) else { return }

        diagnostics.record(
            .media,
            message: "Resuming local interactive audio prewarm after peer became ready",
            metadata: [
                "contactId": contactID.uuidString,
                "applicationState": String(describing: applicationState),
            ]
        )
        await prewarmLocalMediaIfNeeded(for: contactID, applicationState: applicationState)
        updateStatusForSelectedContact()
    }

    func shouldReleaseLocalInteractivePrewarmForRemoteBackgrounding(
        contactID: UUID,
        readinessSignalReason: ReceiverAudioReadinessReason,
        applicationState: UIApplication.State
    ) -> Bool {
        guard readinessSignalReason.isBackgroundMediaClosure else { return false }
        guard applicationState == .active else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard systemSessionMatches(contactID) else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard !remoteTransmittingContactIDs.contains(contactID) else { return false }
        return true
    }

    func releaseLocalInteractivePrewarmForRemoteBackgrounding(
        contactID: UUID,
        readinessSignalReason: ReceiverAudioReadinessReason,
        applicationState: UIApplication.State
    ) {
        guard shouldReleaseLocalInteractivePrewarmForRemoteBackgrounding(
            contactID: contactID,
            readinessSignalReason: readinessSignalReason,
            applicationState: applicationState
        ) else { return }

        diagnostics.record(
            .media,
            message: "Released local interactive audio prewarm after peer backgrounded",
            metadata: [
                "contactId": contactID.uuidString,
                "applicationState": String(describing: applicationState),
                "reason": readinessSignalReason.wireValue,
            ]
        )
        closeMediaSession(
            preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
        )
        updateStatusForSelectedContact()
    }

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

    private func shouldTreatIncomingSignalAsWakeCandidate(
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
             .audioChunk,
             .receiverReady,
             .receiverNotReady:
            return false
        }
    }

    private func shouldBufferDeferredBackgroundAudioAsWakeCandidate(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard !pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID) else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    private func shouldUseForegroundAppManagedWakePlayback(
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

    private func startForegroundAppManagedWakePlayback(
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

    private func shouldTreatIncomingControlSignalAsWakeCandidate(
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
    private func bufferWakeAudioChunkUntilPTTActivation(
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

    private func ensurePendingWakeCandidate(
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
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        guard channelSnapshot.status == .ready else { return false }
        guard channelSnapshot.membership.hasLocalMembership else { return false }
        guard channelSnapshot.membership.hasPeerMembership else { return false }
        guard channelSnapshot.canTransmit else { return false }
        guard channelReadinessByContactID[contactID]?.statusView == .ready else { return false }
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
        // Once signal-path audio is arriving, the backend channel state can
        // move back to ready before the final queued chunks drain to the
        // receiver. In that phase, only an explicit transmit-stop signal or
        // the remote-audio silence timeout should end receive locally.
        guard receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.hasReceivedAudioChunk != true else {
            return false
        }

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
        clearRemoteAudioActivity(for: contactID)

        let shouldRestoreInteractivePrewarm =
            isJoined
            && activeChannelId == contactID
            && systemSessionMatches(contactID)
            && !isTransmitting

        if mediaSessionContactID == contactID && !isTransmitting {
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
            existing.membership.hasLocalMembership
            && existing.membership.hasPeerMembership
            && (existing.membership.peerDeviceConnected || remoteTransmittingContactIDs.contains(contactID))

        let incomingLostMembership =
            !incoming.membership.hasLocalMembership
            && !incoming.membership.hasPeerMembership
            && !incoming.membership.peerDeviceConnected

        let incomingLooksTransient =
            incoming.status == "connecting"
            || incoming.status == ConversationState.waitingForPeer.rawValue
            || (
                incoming.status == ConversationState.idle.rawValue
                && (
                    existing.conversationStatus == .receiving
                    || remoteTransmittingContactIDs.contains(contactID)
                )
            )

        return (
            existingSessionReady
                && incomingLostMembership
                && incomingLooksTransient
        ) || (
                backendRuntime.signalingJoinRecoveryTask != nil
                && existingSessionReady
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

    func runBackendSyncEffect(_ effect: BackendSyncEffect) async {
        switch effect {
        case .bootstrapIfNeeded:
            await recoverBackendBootstrapIfNeeded(trigger: "backend-poll")
        case .ensureWebSocketConnected:
            guard shouldMaintainBackgroundControlPlane() else { return }
            backendServices?.ensureWebSocketConnected()
        case .heartbeatPresence:
            guard shouldPublishForegroundPresence() else { return }
            _ = try? await backendServices?.heartbeatPresence()
        case .refreshContactSummaries:
            await refreshContactSummaries()
        case .refreshInvites:
            await refreshInvites()
        case .refreshChannelState(let contactID):
            await refreshChannelState(for: contactID)
        }
    }

    func scheduleIncomingSignalDelivery(_ envelope: TurboSignalEnvelope) {
        switch backendRuntime.transportFaults.consumeWebSocketReorderResult(for: envelope) {
        case .buffered:
            diagnostics.record(
                .websocket,
                message: "Buffered websocket signal for scenario reorder",
                metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
            )
            captureDiagnosticsState("backend-signal:buffered:\(envelope.type.rawValue)")
        case .deliver(let envelopes):
            if envelopes.count > 1 {
                diagnostics.record(
                    .websocket,
                    message: "Reordered websocket signals for scenario fault injection",
                    metadata: [
                        "count": "\(envelopes.count)",
                        "types": envelopes.map(\.type.rawValue).joined(separator: ",")
                    ]
                )
                captureDiagnosticsState("backend-signal:reordered")
            }
            for envelope in envelopes {
                deliverIncomingSignalWithFaultPlan(envelope)
            }
        }
    }

    private func deliverIncomingSignalWithFaultPlan(_ envelope: TurboSignalEnvelope) {
        let plan = backendRuntime.transportFaults.consumeWebSocketSignalDeliveryPlan(for: envelope.type)

        if plan.shouldDrop {
            diagnostics.record(
                .websocket,
                message: "Dropped websocket signal for scenario fault injection",
                metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
            )
            captureDiagnosticsState("backend-signal:dropped:\(envelope.type.rawValue)")
            return
        }

        for deliveryIndex in 0...plan.duplicateDeliveries {
            let deliveryDelayMilliseconds = plan.delayMilliseconds + (deliveryIndex * 25)
            Task { @MainActor [weak self] in
                if deliveryDelayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(deliveryDelayMilliseconds) * 1_000_000)
                }
                guard let self else { return }
                if deliveryIndex > 0 {
                    self.diagnostics.record(
                        .websocket,
                        message: "Duplicated websocket signal for scenario fault injection",
                        metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
                    )
                } else if plan.delayMilliseconds > 0 {
                    self.diagnostics.record(
                        .websocket,
                        message: "Delayed websocket signal for scenario fault injection",
                        metadata: [
                            "type": envelope.type.rawValue,
                            "channelId": envelope.channelId,
                            "delayMilliseconds": "\(plan.delayMilliseconds)"
                        ]
                    )
                }
                self.handleIncomingSignal(envelope)
            }
        }
    }

    func withHTTPTransportFault<Response>(
        route: TransportFaultHTTPRoute,
        operation: () async throws -> Response
    ) async throws -> Response {
        let delayMilliseconds = backendRuntime.transportFaults.consumeHTTPDelay(for: route)
        if delayMilliseconds > 0 {
            diagnostics.record(
                .backend,
                message: "Delayed HTTP backend request for scenario fault injection",
                metadata: [
                    "route": route.rawValue,
                    "delayMilliseconds": "\(delayMilliseconds)"
                ]
            )
            try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
        }
        return try await operation()
    }

    func shouldSurfaceDirectTransportPath(for contactID: UUID) -> Bool {
        selectedContactId == contactID
            || activeChannelId == contactID
            || mediaSessionContactID == contactID
    }

    func applyDirectQuicUpgradeTransition(
        _ transition: DirectQuicUpgradeTransition,
        for contactID: UUID
    ) {
        guard shouldSurfaceDirectTransportPath(for: contactID) else { return }

        mediaRuntime.updateTransportPathState(transition.pathState)

        switch transition {
        case .enteredPromoting, .updatedPromoting:
            backendStatusMessage = "Direct path promoting"
        case .directActivated:
            backendStatusMessage = "Direct path active"
        case .recovering:
            backendStatusMessage = "Direct path recovering"
        case .fellBackToRelay:
            if backendStatusMessage.hasPrefix("Direct path")
                || backendStatusMessage.hasPrefix("signaling ") {
                backendStatusMessage = "Connected"
            }
        }

        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("direct-quic:\(transition.pathState.rawValue)")
        }
    }

    func handleIncomingDirectQuicControlSignal(
        _ envelope: TurboSignalEnvelope,
        contactID: UUID
    ) {
        do {
            let signal = try envelope.decodeDirectQuicSignalPayload()
            guard shouldAcceptIncomingDirectQuicSignal(
                signal,
                envelope: envelope,
                contactID: contactID
            ) else {
                let debugBypass: String = {
                    if case .offer(let payload) = signal {
                        return String(payload.debugBypass == true)
                    }
                    return "false"
                }()
                diagnostics.record(
                    .websocket,
                    message: "Ignored direct QUIC signal while upgrade disabled",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "attemptId": signal.attemptId,
                        "backendAdvertisesDirectQuicUpgrade": String(backendAdvertisesDirectQuicUpgrade),
                        "localRelayOnlyOverride": String(isDirectPathRelayOnlyForced),
                        "debugBypass": debugBypass,
                    ]
                )
                return
            }
            guard shouldObserveIncomingDirectQuicSignal(
                signal,
                envelope: envelope,
                contactID: contactID
            ) else {
                return
            }

            if !effectiveDirectQuicUpgradeEnabled {
                diagnostics.record(
                    .websocket,
                    message: "Accepted direct QUIC signal through debug bypass",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "attemptId": signal.attemptId,
                        "backendAdvertisesDirectQuicUpgrade": String(backendAdvertisesDirectQuicUpgrade),
                    ]
                )
            }

            let transition = mediaRuntime.directQuicUpgrade.observeIncomingSignal(
                contactID: contactID,
                channelID: envelope.channelId,
                signal: signal
            )

            var metadata: [String: String] = [
                "type": envelope.type.rawValue,
                "channelId": envelope.channelId,
                "contactId": contactID.uuidString,
                "attemptId": signal.attemptId,
                "pathState": transition.pathState.rawValue,
                "fromDeviceId": envelope.fromDeviceId,
                "toDeviceId": envelope.toDeviceId,
            ]

            let message: String = {
                switch signal {
                case .offer(let payload):
                    metadata["candidateCount"] = "\(payload.candidates.count)"
                    metadata["quicAlpn"] = payload.quicAlpn
                    metadata["roleIntent"] = payload.roleIntent?.rawValue ?? "none"
                    metadata["debugBypass"] = String(payload.debugBypass == true)
                    return "Direct QUIC offer received"
                case .answer(let payload):
                    metadata["candidateCount"] = "\(payload.candidates.count)"
                    metadata["accepted"] = String(payload.accepted)
                    if let rejectionReason = payload.rejectionReason {
                        metadata["rejectionReason"] = rejectionReason
                    }
                    return "Direct QUIC answer received"
                case .candidate(let payload):
                    metadata["hasCandidate"] = String(payload.candidate != nil)
                    metadata["endOfCandidates"] = String(payload.endOfCandidates)
                    return "Direct QUIC candidate received"
                case .hangup(let payload):
                    metadata["reason"] = payload.reason
                    return "Direct QUIC hangup received"
                }
            }()

            diagnostics.record(.websocket, message: message, metadata: metadata)
            applyDirectQuicUpgradeTransition(transition, for: contactID)
            Task {
                await handleDirectQuicSignal(
                    signal,
                    envelope: envelope,
                    contactID: contactID
                )
            }
        } catch {
            backendStatusMessage = "Direct path signal decode failed"
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Failed to decode direct QUIC signal",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func shouldObserveIncomingDirectQuicSignal(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) -> Bool {
        switch signal {
        case .offer, .hangup:
            return true
        case .answer, .candidate:
            guard directQuicAttempt(for: contactID, matching: signal.attemptId) != nil else {
                diagnostics.record(
                    .websocket,
                    message: "Ignored stale Direct QUIC follow-up signal without active attempt",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "attemptId": signal.attemptId,
                        "fromDeviceId": envelope.fromDeviceId,
                        "toDeviceId": envelope.toDeviceId,
                    ]
                )
                return false
            }
            return true
        }
    }

    func shouldAcceptIncomingDirectQuicSignal(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) -> Bool {
        if let authorizationFailure = directQuicProductionSignalAuthorizationFailure(
            signal: signal,
            envelope: envelope,
            contactID: contactID
        ) {
            let recoverableIdentityRace = isRecoverableDirectQuicAuthorizationRace(authorizationFailure)
            diagnostics.record(
                .media,
                level: recoverableIdentityRace ? .info : .error,
                message: recoverableIdentityRace
                    ? "Deferred direct QUIC signal until backend peer identity is available"
                    : "Rejected direct QUIC signal because backend peer identity did not authorize it",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "attemptId": signal.attemptId,
                    "reason": authorizationFailure,
                    "fromDeviceId": envelope.fromDeviceId,
                    "backendPeerFingerprint": backendPeerDirectQuicFingerprint(for: contactID) ?? "none",
                ]
            )
            if !recoverableIdentityRace {
                mediaRuntime.directQuicUpgrade.applyRetryBackoff(
                    for: contactID,
                    request: directQuicRetryBackoffRequest(
                        reason: authorizationFailure,
                        attemptID: signal.attemptId
                    )
                )
            }
            return false
        }
        if effectiveDirectQuicUpgradeEnabled {
            return true
        }
        guard !isDirectPathRelayOnlyForced else {
            return false
        }

        if case .offer(let payload) = signal,
           payload.debugBypass == true,
           envelope.toDeviceId == backendServices?.deviceID {
            return true
        }

        guard let existingAttempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            return false
        }
        return existingAttempt.attemptId == signal.attemptId
    }

    func isRecoverableDirectQuicAuthorizationRace(_ reason: String) -> Bool {
        reason == "backend-peer-fingerprint-missing"
    }

    func handleIncomingAudioPayload(
        _ payload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport = .relayWebSocket
    ) async {
        let applicationState = currentApplicationState()
        configureMediaEncryptionSessionIfPossible(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: fromDeviceID
        )
        if shouldDeferIncomingEncryptedMediaUntilSessionReady(
            payload,
            channelID: channelID,
            fromDeviceID: fromDeviceID,
            contactID: contactID
        ) {
            deferIncomingEncryptedAudioPayloadUntilMediaEncryptionReady(
                payload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport
            )
            return
        }
        let audioPayload: String
        do {
            guard let openedPayload = try openIncomingMediaPayloadIfPossible(
                payload,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                contactID: contactID
            ) else {
                return
            }
            audioPayload = openedPayload
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to open incoming media E2EE payload",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "transport": String(describing: incomingAudioTransport),
                    "error": error.localizedDescription,
                ]
            )
            return
        }
        let alreadyHasPendingWake = pttWakeRuntime.hasPendingWake(for: contactID)
        let shouldArmDeferredBackgroundAudioWakeCandidate =
            !alreadyHasPendingWake
            && shouldBufferDeferredBackgroundAudioAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            )
        let shouldArmAudioWakeCandidate =
            shouldTreatIncomingSignalAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            )
            || shouldArmDeferredBackgroundAudioWakeCandidate
        let wakeIsAlreadySystemActivated =
            pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated
        let shouldRepairRemoteParticipant =
            !wakeIsAlreadySystemActivated
            && !shouldSuppressForegroundDirectQuicRemoteParticipant(
                for: contactID,
                applicationState: applicationState
            )
            && (!remoteTransmittingContactIDs.contains(contactID) || shouldArmDeferredBackgroundAudioWakeCandidate)
            && (alreadyHasPendingWake || shouldArmAudioWakeCandidate)
            && shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: applicationState
            )
        if shouldArmAudioWakeCandidate {
            ensurePendingWakeCandidate(
                for: contactID,
                channelId: channelID,
                senderUserId: fromUserID,
                senderDeviceId: fromDeviceID
            )
        }
        recordWakeReceiveTiming(
            stage: "signal-audio-received",
            contactID: contactID,
            channelID: channelID,
            metadata: [
                "fromDeviceId": fromDeviceID,
                "fromUserId": fromUserID,
                "transport": String(describing: incomingAudioTransport),
            ],
            ifAbsent: true
        )
        markRemoteAudioActivity(for: contactID, source: .audioChunk)
        if selectedContactId == nil {
            selectedContactId = contactID
        }
        if shouldRepairRemoteParticipant {
            await updateSystemRemoteParticipant(for: contactID, isActive: true)
        }
        if shouldUseForegroundAppManagedWakePlayback(
            for: contactID,
            applicationState: applicationState,
            incomingAudioTransport: incomingAudioTransport
        ) {
            startForegroundAppManagedWakePlayback(
                for: contactID,
                channelID: channelID
            )
        }
        if bufferWakeAudioChunkUntilPTTActivation(
            audioPayload,
            channelID: channelID,
            contactID: contactID
        ) {
            return
        }
        if shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
            for: contactID,
            applicationState: applicationState
        ) {
            if shouldBufferDeferredBackgroundAudioAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            ) {
                ensurePendingWakeCandidate(
                    for: contactID,
                    channelId: channelID,
                    senderUserId: fromUserID,
                    senderDeviceId: fromDeviceID
                )
                if bufferWakeAudioChunkUntilPTTActivation(
                    audioPayload,
                    channelID: channelID,
                    contactID: contactID
                ) {
                    return
                }
            }
            if !pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID) {
                diagnostics.recordInvariantViolation(
                    invariantID: "audio.deferred_background_chunk_requires_wake_buffer",
                    scope: .local,
                    message: "background audio chunk was deferred without an active wake buffer",
                    metadata: [
                        "channelId": channelID,
                        "contactId": contactID.uuidString,
                        "applicationState": String(describing: applicationState),
                        "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                        "remoteActivity": String(
                            describing: receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]
                        ),
                    ]
                )
            }
            diagnostics.record(
                .media,
                message: "Deferred background audio chunk until PTT audio session activates",
                metadata: ["channelId": channelID, "contactId": contactID.uuidString]
            )
            return
        }
        if mediaSessionContactID == contactID, mediaConnectionState == .preparing {
            await receiveRemoteAudioChunk(audioPayload, incomingAudioTransport: incomingAudioTransport)
            return
        }
        let receiveActivationMode: MediaSessionActivationMode =
            shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: applicationState,
                incomingAudioTransport: incomingAudioTransport
            ) ? .systemActivated : .appManaged
        await ensureMediaSession(
            for: contactID,
            activationMode: receiveActivationMode,
            startupMode: .playbackOnly
        )
        await receiveRemoteAudioChunk(audioPayload, incomingAudioTransport: incomingAudioTransport)
    }

    func deferIncomingEncryptedAudioPayloadUntilMediaEncryptionReady(
        _ payload: String,
        channelID: String,
        fromUserID: String,
        fromDeviceID: String,
        contactID: UUID,
        incomingAudioTransport: IncomingAudioPayloadTransport
    ) {
        let queuedCount = mediaRuntime.enqueuePendingEncryptedAudioPayload(
            PendingEncryptedAudioPayload(
                payload: payload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                transport: incomingAudioTransport,
                receivedAt: Date()
            ),
            for: contactID,
            maxCount: encryptedAudioRecoveryMaxBufferedPayloads
        )
        diagnostics.record(
            .media,
            message: "Buffered encrypted media payload until E2EE session is configured",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "fromDeviceId": fromDeviceID,
                "transport": String(describing: incomingAudioTransport),
                "queuedPayloadCount": String(queuedCount),
            ]
        )

        guard !mediaRuntime.hasEncryptedAudioRecoveryTask(for: contactID) else {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.recoverPendingEncryptedAudioPayloadsIfPossible(for: contactID)
        }
        mediaRuntime.replaceEncryptedAudioRecoveryTask(for: contactID, with: task)
    }

    func recoverPendingEncryptedAudioPayloadsIfPossible(for contactID: UUID) async {
        defer {
            mediaRuntime.clearEncryptedAudioRecoveryTask(for: contactID)
        }

        for attempt in 1...encryptedAudioRecoveryAttempts {
            guard !Task.isCancelled else { return }

            let pending = mediaRuntime.pendingEncryptedAudioPayloads(for: contactID)
            guard let first = pending.first else { return }

            await refreshChannelState(for: contactID)
            configureMediaEncryptionSessionIfPossible(
                contactID: contactID,
                channelID: first.channelID,
                peerDeviceID: first.fromDeviceID
            )

            if !shouldDeferIncomingEncryptedMediaUntilSessionReady(
                first.payload,
                channelID: first.channelID,
                fromDeviceID: first.fromDeviceID,
                contactID: contactID
            ) {
                diagnostics.record(
                    .media,
                    message: "Recovered media E2EE session; draining buffered encrypted audio",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": first.channelID,
                        "fromDeviceId": first.fromDeviceID,
                        "attempt": String(attempt),
                        "payloadCount": String(pending.count),
                    ]
                )
                let pending = mediaRuntime.drainPendingEncryptedAudioPayloads(for: contactID)
                mediaRuntime.clearEncryptedAudioRecoveryTask(for: contactID)
                for buffered in pending {
                    await handleIncomingAudioPayload(
                        buffered.payload,
                        channelID: buffered.channelID,
                        fromUserID: buffered.fromUserID,
                        fromDeviceID: buffered.fromDeviceID,
                        contactID: contactID,
                        incomingAudioTransport: buffered.transport
                    )
                }
                continue
            }

            try? await Task.sleep(nanoseconds: encryptedAudioRecoveryRetryNanoseconds)
        }

        let droppedCount = mediaRuntime.discardPendingEncryptedAudioPayloads(for: contactID)
        diagnostics.record(
            .media,
            level: .error,
            message: "Dropped buffered encrypted media payloads because E2EE session did not recover",
            metadata: [
                "contactId": contactID.uuidString,
                "droppedPayloadCount": String(droppedCount),
            ]
        )
    }

    private func recordIncomingWebSocketAudioChunkDiagnosticIfNeeded(
        _ envelope: TurboSignalEnvelope,
        contactID: UUID
    ) {
        switch mediaRuntime.consumeIncomingRelayAudioDiagnosticDisposition(for: contactID) {
        case .detailed:
            let decodedChunkCount = AudioChunkPayloadCodec.decode(envelope.payload).count
            diagnostics.record(
                .media,
                message: "Audio chunk received",
                metadata: [
                    "channelId": envelope.channelId,
                    "fromDeviceId": envelope.fromDeviceId,
                    "payloadLength": String(envelope.payload.count),
                    "transportDigest": AudioChunkPayloadCodec.transportDigest(envelope.payload),
                    "decodedChunkCount": String(decodedChunkCount),
                ]
            )

        case .suppressedNotice:
            diagnostics.record(
                .media,
                message: "Suppressing repetitive WebSocket audio chunk diagnostics",
                metadata: [
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "reason": "budget-exhausted",
                    "detailedReportLimit": "3",
                ]
            )

        case .suppressed:
            break
        }
    }

    func handleIncomingSignal(_ envelope: TurboSignalEnvelope) {
        guard let contactID = contacts.first(where: { $0.backendChannelId == envelope.channelId })?.id else {
            backendStatusMessage = "Signal: \(envelope.type.rawValue)"
            return
        }

        let applicationState = currentApplicationState()
        if shouldIgnoreForegroundDirectQuicTransmitControlSignal(
            envelope,
            for: contactID,
            applicationState: applicationState
        ) {
            diagnostics.record(
                .websocket,
                message: "Ignored redundant foreground Direct QUIC transmit control signal",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "payload": envelope.payload,
                ]
            )
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:redundant-direct-quic-\(envelope.type.rawValue)")
            }
            return
        }

        switch envelope.type {
        case .transmitStart where envelope.payload == "ptt-prepare":
            pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
            mediaRuntime.resetIncomingRelayAudioDiagnostics(for: contactID)
            mediaRuntime.resetMediaEncryptionReceiveSequence(for: contactID)
            if shouldTreatIncomingControlSignalAsWakeCandidate(
                for: contactID,
                applicationState: applicationState
            ) {
                ensurePendingWakeCandidate(
                    for: contactID,
                    channelId: envelope.channelId,
                    senderUserId: envelope.fromUserId,
                    senderDeviceId: envelope.fromDeviceId,
                    scheduleFallback: false
                )
            }
            recordWakeReceiveTiming(
                stage: "backend-peer-transmit-prepare-observed",
                contactID: contactID,
                channelID: envelope.channelId,
                subsystem: .websocket,
                metadata: [
                    "fromDeviceId": envelope.fromDeviceId,
                    "fromUserId": envelope.fromUserId,
                    "payloadLength": String(envelope.payload.count),
                ],
                ifAbsent: true
            )
            diagnostics.record(
                .websocket,
                message: "Receiver transmit prepare signal received",
                metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId]
            )
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:transmit-prepare")
            }
            Task {
                if shouldSetSystemRemoteParticipantFromSignalPath(
                    for: contactID,
                    applicationState: applicationState
                ),
                   !shouldSuppressForegroundDirectQuicRemoteParticipant(
                    for: contactID,
                    applicationState: applicationState
                   ) {
                    await updateSystemRemoteParticipant(
                        for: contactID,
                        isActive: true,
                        reason: "backend-sync-remote-prepare"
                    )
                }
                await refreshContactSummaries()
                await refreshChannelState(for: contactID)
            }
        case .transmitStart, .transmitStop:
            let shouldDeferReceiveTeardown = envelope.type == .transmitStop
                && shouldDeferReceiveTeardownUntilRemoteAudioDrain(for: contactID)
            if envelope.type == .transmitStart {
                pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
                mediaRuntime.resetIncomingRelayAudioDiagnostics(for: contactID)
                mediaRuntime.resetMediaEncryptionReceiveSequence(for: contactID)
                let shouldArmWakeCandidate = shouldTreatIncomingControlSignalAsWakeCandidate(
                    for: contactID,
                    applicationState: applicationState
                )
                markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
                if shouldArmWakeCandidate {
                    ensurePendingWakeCandidate(
                        for: contactID,
                        channelId: envelope.channelId,
                        senderUserId: envelope.fromUserId,
                        senderDeviceId: envelope.fromDeviceId
                    )
                }
                Task {
                    await connectMediaRelayForReceiveIfNeeded(
                        contactID: contactID,
                        channelID: envelope.channelId,
                        peerDeviceID: envelope.fromDeviceId
                    )
                }
                recordWakeReceiveTiming(
                    stage: "backend-peer-transmitting-observed",
                    contactID: contactID,
                    channelID: envelope.channelId,
                    subsystem: .websocket,
                    metadata: [
                        "fromDeviceId": envelope.fromDeviceId,
                        "fromUserId": envelope.fromUserId,
                        "payloadLength": String(envelope.payload.count),
                    ],
                    ifAbsent: true
                )
            } else {
                pttWakeRuntime.suppressProvisionalWakeCandidate(for: contactID)
                if let activationState = pttWakeRuntime.incomingWakeActivationState(for: contactID),
                   activationState == .signalBuffered
                    || activationState == .awaitingSystemActivation
                    || activationState == .systemActivationTimedOutWaitingForForeground {
                    pttWakeRuntime.markSystemActivationInterruptedByTransmitEnd(for: contactID)
                    diagnostics.record(
                        .media,
                        level: .error,
                        message: "Transmit ended before system wake audio activation arrived",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": envelope.channelId,
                            "activationState": String(describing: activationState),
                        ]
                    )
                } else {
                    if shouldDeferReceiveTeardown {
                        diagnostics.record(
                            .media,
                            message: "Deferring receive teardown until remote audio drain after transmit stop",
                            metadata: ["contactId": contactID.uuidString]
                        )
                        pttWakeRuntime.clear(for: contactID)
                        markRemoteTransmitStoppedPreservingPlaybackDrain(for: contactID)
                    } else {
                        pttWakeRuntime.clear(for: contactID)
                    }
                }
                if !shouldDeferReceiveTeardown {
                    clearRemoteAudioActivity(for: contactID)
                    finalizeReceiveMediaSessionIfNeeded(
                        for: contactID,
                        closeMessage: "Closed receive media session after transmit stop",
                        deferPrewarmMessage: "Deferred interactive audio prewarm until PTT audio deactivation"
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
                let shouldSetRemoteParticipant =
                    envelope.type == .transmitStart
                    && shouldSetSystemRemoteParticipantFromSignalPath(
                        for: contactID,
                        applicationState: currentApplicationState()
                    )
                    && !shouldSuppressForegroundDirectQuicRemoteParticipant(
                        for: contactID,
                        applicationState: currentApplicationState()
                    )
                let shouldClearRemoteParticipant =
                    envelope.type == .transmitStop
                    && !shouldDeferReceiveTeardown
                    && shouldClearSystemRemoteParticipantFromSignalPath(for: contactID)
                if shouldSetRemoteParticipant || shouldClearRemoteParticipant {
                    await updateSystemRemoteParticipant(
                        for: contactID,
                        isActive: shouldSetRemoteParticipant
                    )
                }
                await refreshContactSummaries()
                await refreshChannelState(for: contactID)
            }
        case .receiverReady, .receiverNotReady:
            let applicationState = currentApplicationState()
            let readinessPayload = ReceiverAudioReadinessSignalPayload.decode(from: envelope.payload)
            let readinessReason = readinessPayload.reason
            applyPeerCallTelemetry(
                readinessPayload.telemetry,
                for: contactID,
                source: envelope.type.rawValue
            )
            let readiness: RemoteAudioReadinessState = {
                switch envelope.type {
                case .receiverReady:
                    return .ready
                case .receiverNotReady:
                    return readinessReason.isBackgroundMediaClosure ? .wakeCapable : .waiting
                default:
                    return .unknown
                }
            }()
            if envelope.type == .receiverNotReady {
                releaseLocalInteractivePrewarmForRemoteBackgrounding(
                    contactID: contactID,
                    readinessSignalReason: readinessReason,
                    applicationState: applicationState
                )
                if readinessReason.isBackgroundMediaClosure {
                    if let attempt = directQuicAttempt(for: contactID) {
                        diagnostics.record(
                            .media,
                            message: "Preserving Direct QUIC path after receiver readiness closed",
                            metadata: [
                                "contactId": contactID.uuidString,
                                "channelId": attempt.channelID,
                                "attemptId": attempt.attemptId,
                                "isDirectActive": String(attempt.isDirectActive),
                            ]
                        )
                    }
                }
            }
            if let existing = channelReadinessByContactID[contactID] {
                let updatedReadiness: TurboChannelReadinessResponse = {
                    var next = existing.settingRemoteAudioReadiness(readiness)
                    if envelope.type == .receiverNotReady,
                       readinessReason.isBackgroundMediaClosure {
                        next = next.settingRemoteWakeCapability(
                            .wakeCapable(targetDeviceId: envelope.fromDeviceId)
                        )
                    }
                    return next
                }()
                backendSyncCoordinator.send(
                    .channelReadinessUpdated(
                        contactID: contactID,
                        readiness: updatedReadiness
                    )
                )
            }
            diagnostics.record(
                .websocket,
                message: "Receiver audio readiness signal received",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "payload": envelope.payload,
                    "reason": readinessReason.wireValue,
                    "hasTelemetry": String(readinessPayload.telemetry != nil),
                ]
            )
            if backendStatusMessage.hasPrefix("signaling ") {
                backendStatusMessage = "Connected"
            }
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:\(envelope.type.rawValue)")
            }
            Task {
                if readiness == .ready {
                    await resumeLocalInteractivePrewarmForRemoteReady(
                        contactID: contactID,
                        applicationState: applicationState
                    )
                    await syncLocalReceiverAudioReadinessSignal(
                        for: contactID,
                        reason: .channelRefresh
                    )
                }
                await refreshChannelState(for: contactID)
            }
        case .audioChunk:
            recordIncomingWebSocketAudioChunkDiagnosticIfNeeded(envelope, contactID: contactID)
            Task {
                await handleIncomingAudioPayload(
                    envelope.payload,
                    channelID: envelope.channelId,
                    fromUserID: envelope.fromUserId,
                    fromDeviceID: envelope.fromDeviceId,
                    contactID: contactID
                )
            }
        case .directQuicUpgradeRequest:
            handleIncomingDirectQuicUpgradeRequest(envelope, contactID: contactID)
        case .offer, .answer, .iceCandidate, .hangup:
            handleIncomingDirectQuicControlSignal(envelope, contactID: contactID)
        }
    }

    func handleIncomingDirectQuicTransmitPrepare(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String
    ) async {
        pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
        mediaRuntime.resetMediaEncryptionReceiveSequence(for: contactID)
        let senderUserID =
            contacts.first(where: { $0.id == contactID })?.remoteUserId
            ?? ""
        let applicationState = currentApplicationState()
        let shouldArmWakeCandidate = shouldTreatIncomingControlSignalAsWakeCandidate(
            for: contactID,
            applicationState: applicationState
        )
        if shouldArmWakeCandidate {
            ensurePendingWakeCandidate(
                for: contactID,
                channelId: payload.channelId,
                senderUserId: senderUserID,
                senderDeviceId: payload.fromDeviceId,
                scheduleFallback: applicationState != .active
            )
        }
        recordWakeReceiveTiming(
            stage: "direct-quic-transmit-prepare-observed",
            contactID: contactID,
            channelID: payload.channelId,
            subsystem: .media,
            metadata: [
                "attemptId": attemptID,
                "fromDeviceId": payload.fromDeviceId,
                "requestId": payload.requestId,
                "reason": payload.reason,
                "applicationState": String(describing: applicationState),
                "armedWakeCandidate": String(shouldArmWakeCandidate),
            ],
            ifAbsent: true
        )
        diagnostics.record(
            .media,
            message: "Direct QUIC receiver transmit prepare received",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": payload.channelId,
                "attemptId": attemptID,
                "requestId": payload.requestId,
                "reason": payload.reason,
                "applicationState": String(describing: applicationState),
                "armedWakeCandidate": String(shouldArmWakeCandidate),
            ]
        )
        if applicationState == .active {
            await prewarmLocalMediaIfNeeded(for: contactID)
            await syncLocalReceiverAudioReadinessSignal(
                for: contactID,
                reason: .directQuicTransmitPrepare
            )
        }
        if shouldArmWakeCandidate,
           shouldSetSystemRemoteParticipantFromSignalPath(
            for: contactID,
            applicationState: applicationState
           ),
           !shouldSuppressForegroundDirectQuicRemoteParticipant(
            for: contactID,
            applicationState: applicationState
           ) {
            await updateSystemRemoteParticipant(
                for: contactID,
                isActive: true,
                reason: "direct-quic-remote-prepare"
            )
        }
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("direct-quic:transmit-prepare")
        }
    }

    func updateSystemRemoteParticipant(
        for contactID: UUID,
        isActive: Bool,
        reason: String? = nil
    ) async {
        guard let channelUUID = channelUUID(for: contactID) else { return }
        let participantName = isActive
            ? contacts.first(where: { $0.id == contactID })?.name
                ?? contacts.first(where: { $0.id == contactID })?.handle
            : nil
        let resolvedReason =
            reason ?? (isActive ? "backend-sync-remote-active" : "backend-sync-remote-inactive")
        do {
            try await setSystemActiveRemoteParticipant(
                name: participantName,
                channelUUID: channelUUID,
                contactID: contactID,
                reason: resolvedReason
            )
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
            let summaries = try await withHTTPTransportFault(route: .contactSummaries) {
                try await backend.contactSummaries()
            }
            var nextSummaries: [UUID: TurboContactSummaryResponse] = [:]
            for summary in summaries {
                let channelID = summary.channelId ?? ""
                let contactID = ensureContactExists(
                    handle: summary.publicId,
                    remoteUserId: summary.userId,
                    channelId: channelID,
                    displayName: summary.profileName
                )
                nextSummaries[contactID] = summary
                updateContact(contactID) { contact in
                    contact.name = summary.profileName
                    contact.handle = summary.publicId
                    contact.isOnline = summary.isOnline
                    contact.remoteUserId = summary.userId
                    if let channelId = summary.channelId {
                        contact.backendChannelId = channelId
                        contact.channelId = ContactDirectory.stableChannelUUID(for: channelId)
                    }
                }
            }
            clearStaleTrackedChannelReferencesMissingFromSummaries(excluding: nextSummaries)
            await refreshTrackedContactPresenceFallback(excluding: nextSummaries)
            let updates = nextSummaries.map { BackendContactSummaryUpdate(contactID: $0.key, summary: $0.value) }
            backendSyncCoordinator.send(.contactSummariesUpdated(updates))
            pruneContactsToAuthoritativeState()
            if await resolveRestoredSystemSessionIfPossible(trigger: "contact-summaries") == nil {
                clearUnresolvedRestoredSystemSessionIfNeeded(trigger: "contact-summaries")
            }
            reconcileContactSelectionIfNeeded(
                reason: "contact-summaries",
                allowSelectingFallbackContact: currentApplicationState() == .active
            )
            updateStatusForSelectedContact()
            captureDiagnosticsState("backend-sync:contact-summaries")
            await reconcileSelectedSessionIfNeeded()
        } catch {
            guard !isExpectedBackendSyncCancellation(error) else { return }
            if await recoverBackendControlPlaneAfterSyncFailureIfNeeded(
                scope: "contact-summaries",
                error: error
            ) {
                return
            }
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
            async let channelStateTask = withHTTPTransportFault(route: .channelState) {
                try await backend.channelState(channelId: backendChannelId)
            }
            async let channelReadinessTask = withHTTPTransportFault(route: .channelReadiness) {
                try await backend.channelReadiness(channelId: backendChannelId)
            }

            let channelState = try await channelStateTask
            let fetchedChannelReadiness: TurboChannelReadinessResponse?
            let channelReadinessFailure: Error?
            do {
                fetchedChannelReadiness = try await channelReadinessTask
                channelReadinessFailure = nil
            } catch {
                fetchedChannelReadiness = nil
                channelReadinessFailure = error
            }

            let existingChannelState = backendSyncCoordinator.state.syncState.channelStates[contactID]
            let readinessMembershipLoss =
                channelReadinessFailure.map(shouldTreatChannelReadinessMembershipLossAsAuthoritative) ?? false
            let authoritativeMembershipLoss =
                readinessMembershipLoss
                && shouldHonorAuthoritativeChannelReadinessMembershipLoss(
                    contactID: contactID,
                    existing: existingChannelState,
                    incoming: channelState
                )
            let effectiveChannelState = effectiveChannelStatePreservingLiveMembership(
                contactID: contactID,
                existing: existingChannelState,
                incoming: channelState,
                authoritativeMembershipLoss: authoritativeMembershipLoss
            )
            if authoritativeMembershipLoss {
                diagnostics.record(
                    .channel,
                    message: "Honoring backend membership loss after readiness refresh",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": backendChannelId,
                    ]
                )
            }
            await recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
                contactID: contactID,
                existingChannelState: existingChannelState,
                effectiveChannelState: effectiveChannelState
            )
            let existingSessionWasRoutable =
                systemSessionMatches(contactID)
                || (isJoined && activeChannelId == contactID)
            let existingChannelReadiness = channelReadinessByContactID[contactID]
            let directQuicReceiveOrPrepareEvidence =
                receiveExecutionCoordinator.state
                    .remoteActivityByContactID[contactID]?
                    .hasReceivedAudioChunk == true
                || existingChannelReadiness?.remoteAudioReadiness == .waiting
            let shouldSuppressWakeCapableAudioReadiness =
                shouldUseDirectQuicTransport(for: contactID)
                && directQuicReceiveOrPrepareEvidence
            let effectiveChannelReadiness: TurboChannelReadinessResponse? = {
                guard effectiveChannelState.membership != .absent else { return nil }
                return mergedChannelReadinessPreservingWakeCapableFallback(
                    existing: existingChannelReadiness,
                    fetched: fetchedChannelReadiness,
                    peerDeviceConnected: effectiveChannelState.membership.peerDeviceConnected,
                    peerMembershipPresent: effectiveChannelState.membership.hasPeerMembership,
                    existingSessionWasRoutable: existingSessionWasRoutable,
                    suppressWakeCapableAudioReadiness: shouldSuppressWakeCapableAudioReadiness
                )
            }()
            let localSessionEstablished =
                systemSessionMatches(contactID)
                || (isJoined && activeChannelId == contactID)
            let localSessionCleared =
                !systemSessionMatches(contactID)
                && !(isJoined && activeChannelId == contactID)
            let leaveWasInFlight = sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
            sessionCoordinator.reconcileAfterChannelRefresh(
                for: contactID,
                effectiveChannelState: effectiveChannelState,
                localSessionEstablished: localSessionEstablished,
                localSessionCleared: localSessionCleared
            )
            if leaveWasInFlight,
               !sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
                replaceDisconnectRecoveryTask(with: nil)
                updateStatusForSelectedContact()
                captureDiagnosticsState("session-teardown:channel-refresh-complete")
            }
            backendSyncCoordinator.send(
                .channelStateUpdated(contactID: contactID, channelState: effectiveChannelState)
            )
            if let effectiveChannelReadiness {
                backendSyncCoordinator.send(
                    .channelReadinessUpdated(contactID: contactID, readiness: effectiveChannelReadiness)
                )
            }
            await prepareReceiverForBackendPeerTransmitFromChannelRefreshIfNeeded(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                effectiveChannelReadiness: effectiveChannelReadiness
            )
            updateContact(contactID) { contact in
                contact.isOnline = effectiveChannelState.peerOnline
                contact.remoteUserId = effectiveChannelState.peerUserId
            }
            if backendStatusMessage.hasPrefix("signaling "),
               let effectiveChannelReadiness,
               !effectiveChannelReadiness.statusKind.isEmpty {
                backendStatusMessage = "Connected"
            }
            if selectedContactId == contactID {
                let backendChannelSnapshot = ChannelReadinessSnapshot(
                    channelState: effectiveChannelState,
                    readiness: effectiveChannelReadiness
                )
                let backendShowsLocalTransmit = backendChannelSnapshot.status == .transmitting
                let transmitSnapshot = transmitDomainSnapshot
                let shouldAcceptBackendLocalTransmit = shouldAcceptBackendLocalTransmitProjection(
                    backendShowsLocalTransmit: backendShowsLocalTransmit,
                    transmitSnapshot: transmitSnapshot
                )
                let shouldPreserveTransmitState = shouldPreserveLocalTransmitState(
                    selectedContactID: selectedContactId,
                    refreshedContactID: contactID,
                    backendChannelStatus: backendChannelSnapshot.status?.rawValue ?? effectiveChannelState.status,
                    transmitSnapshot: transmitSnapshot
                )
                isTransmitting =
                    shouldAcceptBackendLocalTransmit
                    || (
                        transmitSnapshot.isSystemTransmitting
                        && !transmitSnapshot.explicitStopRequested
                    )
                    || (
                        transmitSnapshot.activeContactID == contactID
                        && transmitSnapshot.isPressActive
                    )
                if !shouldPreserveTransmitState {
                    tearDownTransmitRuntime(resetCoordinator: true)
                }
                updateStatusForSelectedContact()
            }
            captureDiagnosticsState("backend-sync:channel-state")
            await syncLocalReceiverAudioReadinessSignal(for: contactID, reason: .channelRefresh)
            await reconcileSelectedSessionIfNeeded()
            if selectedContactId == contactID {
                await prewarmForegroundTalkPathIfNeeded(
                    for: contactID,
                    reason: "channel-ready"
                )
                await prejoinMediaRelayForReadyChannelIfNeeded(
                    contactID: contactID,
                    channelReadiness: effectiveChannelReadiness
                )
                if shouldRequestAutomaticDirectQuicProbe(for: contactID) {
                    await maybeStartAutomaticDirectQuicProbe(
                        for: contactID,
                        reason: "channel-ready"
                    )
                }
            }
        } catch {
            guard !isExpectedBackendSyncCancellation(error) else { return }
            if await recoverBackendControlPlaneAfterSyncFailureIfNeeded(
                scope: "channel-state",
                error: error
            ) {
                return
            }
            if shouldTreatChannelRefreshFailureAsAuthoritativeChannelLoss(error) {
                clearLocalSessionAfterAuthoritativeChannelLoss(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    error: error
                )
                await refreshContactSummaries()
                await reconcileSelectedSessionIfNeeded()
                return
            }
            let shouldPreserveLocalSession =
                selectedContactId == contactID
                && shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID)

            backendSyncCoordinator.send(
                .channelStateFailed(
                    contactID: contactID,
                    message: "Channel sync failed: \(error.localizedDescription)"
                )
            )
            if selectedContactId == contactID {
                if !shouldPreserveLocalSession {
                    resetTransmitSession(closeMediaSession: true)
                }
                updateStatusForSelectedContact()
            }
            diagnostics.record(
                .channel,
                level: shouldPreserveLocalSession ? .info : .error,
                message: shouldPreserveLocalSession
                    ? "Channel state refresh failed; preserving local session"
                    : "Channel state refresh failed",
                metadata: ["contactId": contactID.uuidString, "error": error.localizedDescription]
            )
            captureDiagnosticsState("backend-sync:channel-failed")
            await reconcileSelectedSessionIfNeeded()
        }
    }

    func refreshInvites() async {
        guard let backend = backendServices else { return }
        func updates(
            incoming: [TurboInviteResponse]?,
            outgoing: [TurboInviteResponse]?
        ) -> ([BackendInviteUpdate]?, [BackendInviteUpdate]?) {
            var nextIncoming: [UUID: TurboInviteResponse] = [:]
            var nextOutgoing: [UUID: TurboInviteResponse] = [:]

            if let incoming {
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
            }

            if let outgoing {
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
            }

            return (
                incoming.map { _ in nextIncoming.map { BackendInviteUpdate(contactID: $0.key, invite: $0.value) } },
                outgoing.map { _ in nextOutgoing.map { BackendInviteUpdate(contactID: $0.key, invite: $0.value) } }
            )
        }

        func finishInviteSync(stateReason: String) async {
            syncTalkRequestNotificationBadge()
            reconcileTalkRequestSurface()
            pruneContactsToAuthoritativeState()
            reconcileContactSelectionIfNeeded(
                reason: "invite-sync",
                allowSelectingFallbackContact: currentApplicationState() == .active
            )
            updateStatusForSelectedContact()
            captureDiagnosticsState(stateReason)
            await reconcileSelectedSessionIfNeeded()
        }

        let incomingResult: Result<[TurboInviteResponse], Error>
        do {
            incomingResult = .success(
                try await withHTTPTransportFault(route: .incomingInvites) {
                    try await backend.incomingInvites()
                }
            )
        } catch {
            incomingResult = .failure(error)
        }

        let outgoingResult: Result<[TurboInviteResponse], Error>
        do {
            outgoingResult = .success(
                try await withHTTPTransportFault(route: .outgoingInvites) {
                    try await backend.outgoingInvites()
                }
            )
        } catch {
            outgoingResult = .failure(error)
        }

        switch (incomingResult, outgoingResult) {
        case (.success(let incoming), .success(let outgoing)):
            let (incomingUpdates, outgoingUpdates) = updates(incoming: incoming, outgoing: outgoing)
            backendSyncCoordinator.send(
                .invitesUpdated(
                    incoming: incomingUpdates ?? [],
                    outgoing: outgoingUpdates ?? [],
                    now: .now
                )
            )
            await finishInviteSync(stateReason: "backend-sync:invites")

        case (.success(let incoming), .failure(let error)):
            guard !isExpectedBackendSyncCancellation(error) else { return }
            let (incomingUpdates, _) = updates(incoming: incoming, outgoing: nil)
            backendSyncCoordinator.send(.invitesPartiallyUpdated(incoming: incomingUpdates, outgoing: nil, now: .now))
            recordInviteSyncPartialRecovery(failedRoute: "outgoing", error: error)
            await finishInviteSync(stateReason: "backend-sync:invites-partial")

        case (.failure(let error), .success(let outgoing)):
            guard !isExpectedBackendSyncCancellation(error) else { return }
            let (_, outgoingUpdates) = updates(incoming: nil, outgoing: outgoing)
            backendSyncCoordinator.send(.invitesPartiallyUpdated(incoming: nil, outgoing: outgoingUpdates, now: .now))
            recordInviteSyncPartialRecovery(failedRoute: "incoming", error: error)
            await finishInviteSync(stateReason: "backend-sync:invites-partial")

        case (.failure(let incomingError), .failure(let outgoingError)):
            guard !isExpectedBackendSyncCancellation(incomingError) else { return }
            guard !isExpectedBackendSyncCancellation(outgoingError) else { return }
            if await recoverBackendControlPlaneAfterSyncFailureIfNeeded(
                scope: "invite-sync",
                error: incomingError
            ) {
                return
            }
            let message = "incoming=\(incomingError.localizedDescription); outgoing=\(outgoingError.localizedDescription)"
            backendSyncCoordinator.send(.invitesFailed("Invite sync failed: \(message)"))
            diagnostics.record(.backend, level: .error, message: "Invite sync failed", metadata: ["error": message])
            captureDiagnosticsState("backend-sync:invites-failed")
            await reconcileSelectedSessionIfNeeded()
        }
    }

    func recordInviteSyncPartialRecovery(failedRoute: String, error: Error) {
        diagnostics.record(
            .backend,
            level: .notice,
            message: "Invite sync partially recovered",
            metadata: ["failedRoute": failedRoute, "error": error.localizedDescription]
        )
    }
}
