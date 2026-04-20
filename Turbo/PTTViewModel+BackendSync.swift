//
//  PTTViewModel+BackendSync.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

extension PTTViewModel {
    private var remoteAudioSilenceTimeoutNanoseconds: UInt64 { 1_500_000_000 }

    func runReceiveExecutionEffect(_ effect: ReceiveExecutionEffect) {
        switch effect {
        case .scheduleRemoteSilenceTimeout(let contactID):
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.remoteAudioSilenceTimeoutNanoseconds ?? 0)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.handleRemoteAudioSilenceTimeout(for: contactID)
                }
            }
            receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: task)

        case .cancelRemoteSilenceTimeout(let contactID):
            receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: nil)

        case .cancelAllRemoteSilenceTimeouts:
            receiveExecutionRuntime.cancelAllRemoteAudioSilenceTasks()
        }
    }

    func handleRemoteAudioSilenceTimeout(for contactID: UUID) {
        receiveExecutionRuntime.replaceRemoteAudioSilenceTask(for: contactID, with: nil)
        receiveExecutionCoordinator.send(.silenceTimeoutElapsed(contactID: contactID))
        diagnostics.record(
            .media,
            message: "Remote audio activity timed out",
            metadata: ["contactId": contactID.uuidString]
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

        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("remote-audio:cleared")
        }
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
        readinessSignalPayload: String,
        applicationState: UIApplication.State
    ) -> Bool {
        guard readinessSignalPayload == "app-background-media-closed" else { return false }
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
        readinessSignalPayload: String,
        applicationState: UIApplication.State
    ) {
        guard shouldReleaseLocalInteractivePrewarmForRemoteBackgrounding(
            contactID: contactID,
            readinessSignalPayload: readinessSignalPayload,
            applicationState: applicationState
        ) else { return }

        diagnostics.record(
            .media,
            message: "Released local interactive audio prewarm after peer backgrounded",
            metadata: [
                "contactId": contactID.uuidString,
                "applicationState": String(describing: applicationState),
                "reason": readinessSignalPayload,
            ]
        )
        closeMediaSession()
        updateStatusForSelectedContact()
    }

    func mergedChannelReadinessPreservingWakeCapableFallback(
        existing: TurboChannelReadinessResponse?,
        fetched: TurboChannelReadinessResponse?,
        peerDeviceConnected: Bool,
        peerMembershipPresent: Bool = true,
        existingSessionWasRoutable: Bool = false
    ) -> TurboChannelReadinessResponse? {
        guard let fetched else { return existing }
        guard let existing else { return fetched }
        guard case .wakeCapable(let existingTargetDeviceId) = existing.remoteWakeCapability else {
            return fetched
        }

        let existingWakeFallbackWasAuthoritative: Bool = {
            if existingSessionWasRoutable {
                return true
            }
            switch existing.statusView {
            case .ready, .selfTransmitting, .peerTransmitting:
                return true
            case .waitingForSelf, .waitingForPeer, .unknown:
                return false
            }
        }()

        let fetchedLooksLikeTransientBackgroundDrift: Bool = {
            guard !fetched.canTransmit else { return false }
            switch fetched.statusView {
            case .waitingForSelf, .waitingForPeer:
                return true
            case .ready, .selfTransmitting, .peerTransmitting, .unknown:
                return false
            }
        }()

        let shouldPreserveWakeCapableFallback =
            peerMembershipPresent
            && (
                !peerDeviceConnected
                || (existingWakeFallbackWasAuthoritative && fetchedLooksLikeTransientBackgroundDrift)
            )
        guard shouldPreserveWakeCapableFallback else { return fetched }

        var merged = fetched

        if existing.remoteAudioReadiness == .wakeCapable {
            switch fetched.remoteAudioReadiness {
            case .waiting, .unknown:
                merged = merged.settingRemoteAudioReadiness(.wakeCapable)
            case .ready, .wakeCapable:
                break
            }
        }

        if case .unavailable = fetched.remoteWakeCapability {
            merged = merged.settingRemoteWakeCapability(
                .wakeCapable(targetDeviceId: existingTargetDeviceId)
            )
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

    private func shouldTreatIncomingSignalAsWakeCandidate(for contactID: UUID) -> Bool {
        guard currentApplicationState() != .active else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        guard !pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID && !pttCoordinator.state.isTransmitting
    }

    func shouldSetSystemRemoteParticipantFromSignalPath(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard let channelUUID = channelUUID(for: contactID) else { return false }
        return pttCoordinator.state.systemChannelUUID == channelUUID
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
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
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
        applicationState: UIApplication.State
    ) -> Bool {
        guard !prefersForegroundAppManagedReceivePlayback(
            for: contactID,
            applicationState: applicationState
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
        receiveExecutionCoordinator.send(.remoteTransmitStopped(contactID: contactID))
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("remote-audio:cleared")
        }
    }

    func shouldRecoverRemoteTransmitStopFromChannelRefresh(
        contactID: UUID,
        existingChannelState: TurboChannelStateResponse?,
        effectiveChannelState: TurboChannelStateResponse
    ) -> Bool {
        guard remoteTransmittingContactIDs.contains(contactID) else { return false }

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
        clearRemoteAudioActivity(for: contactID)

        let shouldRestoreInteractivePrewarm =
            isJoined
            && activeChannelId == contactID
            && systemSessionMatches(contactID)
            && !isTransmitting

        if mediaSessionContactID == contactID && !isTransmitting {
            closeMediaSession()
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

    func markRemoteAudioActivity(
        for contactID: UUID,
        source: RemoteReceiveActivitySource = .audioChunk
    ) {
        receiveExecutionCoordinator.send(.remoteActivityDetected(contactID: contactID, source: source))
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
            existing.membership.hasLocalMembership
            && existing.membership.hasPeerMembership
            && (existing.membership.peerDeviceConnected || remoteTransmittingContactIDs.contains(contactID))

        let incomingLostMembership =
            !incoming.membership.hasLocalMembership
            && !incoming.membership.hasPeerMembership
            && !incoming.membership.peerDeviceConnected

        let transientStatuses = [
            ConversationState.idle.rawValue,
            "connecting",
            ConversationState.waitingForPeer.rawValue,
        ]

        return existingSessionReady
            && incomingLostMembership
            && transientStatuses.contains(incoming.status)
    }

    func effectiveChannelStatePreservingLiveMembership(
        contactID: UUID,
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse
    ) -> TurboChannelStateResponse {
        guard let existing else { return incoming }
        guard existing.channelId == incoming.channelId else { return incoming }

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

    func runBackendSyncEffect(_ effect: BackendSyncEffect) async {
        switch effect {
        case .ensureWebSocketConnected:
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

    func handleIncomingSignal(_ envelope: TurboSignalEnvelope) {
        guard let contactID = contacts.first(where: { $0.backendChannelId == envelope.channelId })?.id else {
            backendStatusMessage = "Signal: \(envelope.type.rawValue)"
            return
        }

        switch envelope.type {
        case .transmitStart, .transmitStop:
            if envelope.type == .transmitStart {
                pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
                markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)
                if shouldTreatIncomingSignalAsWakeCandidate(for: contactID) {
                    ensurePendingWakeCandidate(
                        for: contactID,
                        channelId: envelope.channelId,
                        senderUserId: envelope.fromUserId,
                        senderDeviceId: envelope.fromDeviceId
                    )
                }
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
                    pttWakeRuntime.clear(for: contactID)
                }
                clearRemoteAudioActivity(for: contactID)
                let shouldRestoreInteractivePrewarm =
                    isJoined
                    && activeChannelId == contactID
                    && systemSessionMatches(contactID)
                    && !isTransmitting
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
                    if shouldRestoreInteractivePrewarm {
                        deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
                        diagnostics.record(
                            .media,
                            message: "Deferred interactive audio prewarm until PTT audio deactivation",
                            metadata: ["contactId": contactID.uuidString]
                        )
                    }
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
                let shouldClearRemoteParticipant =
                    envelope.type == .transmitStop
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
            let readiness: RemoteAudioReadinessState = {
                switch envelope.type {
                case .receiverReady:
                    return .ready
                case .receiverNotReady:
                    return envelope.payload == "app-background-media-closed" ? .wakeCapable : .waiting
                default:
                    return .unknown
                }
            }()
            if envelope.type == .receiverNotReady {
                releaseLocalInteractivePrewarmForRemoteBackgrounding(
                    contactID: contactID,
                    readinessSignalPayload: envelope.payload,
                    applicationState: applicationState
                )
            }
            if let existing = channelReadinessByContactID[contactID] {
                let updatedReadiness: TurboChannelReadinessResponse = {
                    var next = existing.settingRemoteAudioReadiness(readiness)
                    if envelope.type == .receiverNotReady,
                       envelope.payload == "app-background-media-closed" {
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
                }
                await refreshChannelState(for: contactID)
            }
        case .audioChunk:
            diagnostics.record(
                .media,
                message: "Audio chunk received",
                metadata: ["channelId": envelope.channelId, "fromDeviceId": envelope.fromDeviceId]
            )
            Task {
                let applicationState = currentApplicationState()
                let shouldRepairRemoteParticipant =
                    !remoteTransmittingContactIDs.contains(contactID)
                    && shouldSetSystemRemoteParticipantFromSignalPath(
                        for: contactID,
                        applicationState: applicationState
                    )
                if shouldTreatIncomingSignalAsWakeCandidate(for: contactID) {
                    ensurePendingWakeCandidate(
                        for: contactID,
                        channelId: envelope.channelId,
                        senderUserId: envelope.fromUserId,
                        senderDeviceId: envelope.fromDeviceId
                    )
                }
                markRemoteAudioActivity(for: contactID, source: .audioChunk)
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
                if shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                    for: contactID,
                    applicationState: applicationState
                ) {
                    diagnostics.record(
                        .media,
                        message: "Deferred background audio chunk until PTT audio session activates",
                        metadata: ["channelId": envelope.channelId, "contactId": contactID.uuidString]
                    )
                    return
                }
                if mediaSessionContactID == contactID, mediaConnectionState == .preparing {
                    await receiveRemoteAudioChunk(envelope.payload)
                    return
                }
                let receiveActivationMode: MediaSessionActivationMode =
                    shouldUseSystemActivatedReceivePlayback(for: contactID) ? .systemActivated : .appManaged
                await ensureMediaSession(
                    for: contactID,
                    activationMode: receiveActivationMode,
                    startupMode: .playbackOnly
                )
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
            let summaries = try await withHTTPTransportFault(route: .contactSummaries) {
                try await backend.contactSummaries()
            }
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
            await refreshTrackedContactPresenceFallback(excluding: nextSummaries)
            let updates = nextSummaries.map { BackendContactSummaryUpdate(contactID: $0.key, summary: $0.value) }
            backendSyncCoordinator.send(.contactSummariesUpdated(updates))
            pruneContactsToAuthoritativeState()
            _ = await resolveRestoredSystemSessionIfPossible(trigger: "contact-summaries")
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
            async let channelStateTask = withHTTPTransportFault(route: .channelState) {
                try await backend.channelState(channelId: backendChannelId)
            }
            async let channelReadinessTask = withHTTPTransportFault(route: .channelReadiness) {
                try await backend.channelReadiness(channelId: backendChannelId)
            }

            let channelState = try await channelStateTask
            let fetchedChannelReadiness = try? await channelReadinessTask
            let existingChannelState = backendSyncCoordinator.state.syncState.channelStates[contactID]
            let effectiveChannelState = effectiveChannelStatePreservingLiveMembership(
                contactID: contactID,
                existing: existingChannelState,
                incoming: channelState
            )
            await recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
                contactID: contactID,
                existingChannelState: existingChannelState,
                effectiveChannelState: effectiveChannelState
            )
            let existingSessionWasRoutable =
                systemSessionMatches(contactID)
                || (isJoined && activeChannelId == contactID)
            let effectiveChannelReadiness = mergedChannelReadinessPreservingWakeCapableFallback(
                existing: channelReadinessByContactID[contactID],
                fetched: fetchedChannelReadiness,
                peerDeviceConnected: effectiveChannelState.membership.peerDeviceConnected,
                peerMembershipPresent: effectiveChannelState.membership.hasPeerMembership,
                existingSessionWasRoutable: existingSessionWasRoutable
            )
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
            backendSyncCoordinator.send(
                .channelStateUpdated(contactID: contactID, channelState: effectiveChannelState)
            )
            if let effectiveChannelReadiness {
                backendSyncCoordinator.send(
                    .channelReadinessUpdated(contactID: contactID, readiness: effectiveChannelReadiness)
                )
            }
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
                let shouldPreserveTransmitState = shouldPreserveLocalTransmitState(
                    selectedContactID: selectedContactId,
                    refreshedContactID: contactID,
                    backendChannelStatus: backendChannelSnapshot.status?.rawValue ?? effectiveChannelState.status,
                    transmitSnapshot: transmitSnapshot
                )
                isTransmitting =
                    backendShowsLocalTransmit
                    || transmitSnapshot.isSystemTransmitting
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
            await syncLocalReceiverAudioReadinessSignal(for: contactID, reason: "channel-refresh")
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
            async let incomingTask = withHTTPTransportFault(route: .incomingInvites) {
                try await backend.incomingInvites()
            }
            async let outgoingTask = withHTTPTransportFault(route: .outgoingInvites) {
                try await backend.outgoingInvites()
            }
            let incoming = try await incomingTask
            let outgoing = try await outgoingTask
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
            syncTalkRequestNotificationBadge()
            reconcileTalkRequestSurface()
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
