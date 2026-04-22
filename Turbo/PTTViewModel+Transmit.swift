//
//  PTTViewModel+Transmit.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk
import AVFAudio
import UIKit

extension PTTViewModel {
    private var wakePlaybackFallbackDelayNanoseconds: UInt64 { 3_500_000_000 }
    // Wake-capable receive now buffers early audio and the backend preserves the
    // active transmit target, so a long blind hold here just shifts speech behind
    // the user's finger and makes short phrases feel cut off on release.
    private var wakeCapableInitialAudioSendGraceNanoseconds: UInt64 { 300_000_000 }
    private var wakeCapablePostReleaseAudioSendGraceNanoseconds: UInt64 { 750_000_000 }
    private var mediaSessionRetryCooldown: TimeInterval { 0.75 }
    private var deferredInteractivePrewarmRecoveryDelayNanoseconds: UInt64 { 500_000_000 }
    private var transmitLeaseRenewIntervalNanoseconds: UInt64 { 1_000_000_000 }
    private var remoteReceiverAudioReadyGateTimeoutNanoseconds: UInt64 { 3_500_000_000 }
    private var remoteReceiverAudioReadyGatePollNanoseconds: UInt64 { 50_000_000 }

    func shouldUseAppManagedWakePlaybackFallback(
        applicationState: UIApplication.State
    ) -> Bool {
        applicationState == .active
    }

    func shouldSuspendForegroundMediaForBackgroundTransition(
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard mediaServices.hasSession() else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        return true
    }

    func suspendForegroundMediaForBackgroundTransition(
        reason: String,
        applicationState: UIApplication.State
    ) async {
        guard shouldSuspendForegroundMediaForBackgroundTransition(
            applicationState: applicationState
        ) else { return }
        guard let contactID = mediaSessionContactID else { return }
        diagnostics.record(
            .media,
            message: "Suspending foreground media for background transition",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
                "applicationState": String(describing: applicationState)
            ]
        )
        closeMediaSession()
        await syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: "app-background-media-closed"
        )
        updateStatusForSelectedContact()
    }

    func desiredLocalReceiverAudioReadiness(for contactID: UUID) -> Bool {
        let projection = selectedPeerProjection(for: contactID)
        guard projection.durableSession == .connected else { return false }
        guard projection.connectedExecution == nil else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        return true
    }

    func peerIsRoutableForReceiverAudioReadiness(for contactID: UUID) -> Bool {
        guard let channel = selectedChannelSnapshot(for: contactID) else { return false }
        if channel.membership.hasPeerMembership {
            return true
        }

        if channel.membership.peerDeviceConnected {
            return true
        }

        guard systemSessionMatches(contactID) else { return false }

        if remoteTransmittingContactIDs.contains(contactID) {
            return true
        }

        switch pttWakeRuntime.incomingWakeActivationState(for: contactID) {
        case .signalBuffered, .awaitingSystemActivation, .appManagedFallback, .systemActivated:
            return true
        case .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .none:
            return false
        }
    }

    func shouldReassertBackendJoinAfterWake(for contactID: UUID) -> Bool {
        guard backendServices != nil else { return false }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return false }
        guard contact.backendChannelId != nil, contact.remoteUserId != nil else { return false }
        guard let channel = selectedChannelSnapshot(for: contactID) else { return false }
        guard !channel.membership.hasLocalMembership else { return false }
        return systemSessionMatches(contactID) || (isJoined && activeChannelId == contactID)
    }

    @discardableResult
    func reassertBackendJoinAfterWakeIfNeeded(for contactID: UUID) async -> Bool {
        guard shouldReassertBackendJoinAfterWake(for: contactID) else { return false }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return false }
        diagnostics.record(
            .backend,
            message: "Reasserting backend join after wake recovery",
            metadata: [
                "contactId": contactID.uuidString,
                "handle": contact.handle,
                "applicationState": String(describing: currentApplicationState()),
            ]
        )
        // A readiness publish sent before backend membership is repaired may be
        // ignored by the control plane. Force a clean republish after rejoin.
        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
        await reassertBackendJoin(for: contact)
        return true
    }

    func syncLocalReceiverAudioReadinessSignal(for contactID: UUID, reason: String) async {
        guard let intent = receiverAudioReadinessIntent(for: contactID, reason: reason) else {
            controlPlaneCoordinator.send(.receiverAudioReadinessContextUnavailable(contactID: contactID))
            return
        }

        await controlPlaneCoordinator.handle(
            .receiverAudioReadinessSyncRequested(
                intent,
                peerIsRoutable: peerIsRoutableForReceiverAudioReadiness(for: contactID),
                webSocketConnected: backendServices?.isWebSocketConnected == true
            )
        )
    }

    func prewarmLocalMediaIfNeeded(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) async {
        let applicationState = applicationState ?? currentApplicationState()
        guard isJoined, activeChannelId == contactID else { return }
        guard systemSessionMatches(contactID) else { return }
        guard !isTransmitting else { return }
        guard applicationState == .active else {
            diagnostics.record(
                .media,
                message: "Deferred interactive audio prewarm until app is foregrounded",
                metadata: [
                    "contactId": contactID.uuidString,
                    "applicationState": String(describing: applicationState)
                ]
            )
            return
        }

        let startupContext = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        let media = mediaServices

        if media.contactID() == contactID, mediaConnectionState == .connected {
            return
        }
        if media.isStartupInFlight(startupContext) {
            return
        }

        diagnostics.record(
            .media,
            message: "Prewarming interactive audio for joined session",
            metadata: ["contactId": contactID.uuidString]
        )
        await ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        updateStatusForSelectedContact()
    }

    func shouldClosePrewarmedMediaBeforeSystemTransmit(for contactID: UUID) -> Bool {
        guard mediaServices.hasSession() else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }

        switch mediaConnectionState {
        case .connected, .preparing:
            return true
        case .idle, .failed, .closed:
            return false
        }
    }

    func deferInteractivePrewarmUntilPTTAudioDeactivation(for contactID: UUID) {
        mediaRuntime.requestInteractivePrewarmAfterAudioDeactivation(for: contactID)
        mediaRuntime.replaceInteractivePrewarmRecoveryTask(with: Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.deferredInteractivePrewarmRecoveryDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self.recoverDeferredInteractivePrewarmWithoutPTTDeactivationIfNeeded(for: contactID)
        })
    }

    func recoverDeferredInteractivePrewarmWithoutPTTDeactivationIfNeeded(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) async {
        let applicationState = applicationState ?? currentApplicationState()
        guard mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID else { return }
        guard !isPTTAudioSessionActive else { return }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return }
        guard isJoined, activeChannelId == contactID else { return }
        guard systemSessionMatches(contactID) else { return }
        guard !isTransmitting else { return }
        guard applicationState == .active else { return }

        _ = mediaRuntime.takePendingInteractivePrewarmAfterAudioDeactivationContactID()
        diagnostics.record(
            .media,
            message: "Recovering deferred interactive audio prewarm without PTT deactivation callback",
            metadata: ["contactId": contactID.uuidString]
        )
        await prewarmLocalMediaIfNeeded(for: contactID)
    }

    func resumeInteractiveAudioPrewarmIfNeeded(
        reason: String,
        applicationState: UIApplication.State
    ) async {
        guard applicationState == .active else { return }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return }
        guard !transmitCoordinator.state.isPressingTalk else { return }
        guard let contact = selectedContact else { return }
        guard isJoined, activeChannelId == contact.id else { return }
        guard systemSessionMatches(contact.id) else { return }
        guard !isTransmitting else { return }

        switch localMediaWarmupState(for: contact.id) {
        case .cold, .failed:
            diagnostics.record(
                .media,
                message: "Resuming interactive audio prewarm after app activation",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                ]
            )
            await prewarmLocalMediaIfNeeded(for: contact.id)
        case .prewarming, .ready:
            return
        }
    }

    func shouldRecreateMediaSession(connectionState: MediaConnectionState) -> Bool {
        switch connectionState {
        case .closed, .failed:
            return true
        case .idle, .preparing, .connected:
            return false
        }
    }

    func shouldTreatTransmitBeginMembershipLossAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "not a channel member"
    }

    func shouldTreatTransmitLeaseLossAsStop(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no active transmit state for sender"
    }

    func shouldPreserveLocalTransmitState(
        selectedContactID: UUID?,
        refreshedContactID: UUID,
        backendChannelStatus: String,
        transmitSnapshot: TransmitDomainSnapshot
    ) -> Bool {
        guard selectedContactID == refreshedContactID else { return false }
        if backendChannelStatus == ConversationState.transmitting.rawValue {
            return true
        }
        if transmitSnapshot.isSystemTransmitting {
            return true
        }
        if transmitSnapshot.activeContactID == refreshedContactID,
           transmitSnapshot.isPressActive {
            return true
        }

        switch transmitSnapshot.phase {
        case .idle:
            return false
        case .requesting(let contactID), .active(let contactID), .stopping(let contactID):
            return contactID == refreshedContactID
        }
    }

    func beginTransmit() {
        guard isJoined else {
            diagnostics.record(.media, message: "Ignored begin transmit request", metadata: ["reason": "not-joined"])
            return
        }
        guard let contact = selectedContact else {
            statusMessage = "Pick a contact"
            diagnostics.record(.media, message: "Ignored begin transmit request", metadata: ["reason": "no-selected-contact"])
            return
        }
        guard !transmitRuntime.isPressingTalk else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "local-press-already-active", "contact": contact.handle]
            )
            return
        }
        guard !transmitRuntime.requiresReleaseBeforeNextPress else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "requires-fresh-press-after-unexpected-end", "contact": contact.handle]
            )
            return
        }
        guard !hasPendingBeginOrActiveTransmit else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "pending-begin-or-active-target", "contact": contact.handle]
            )
            return
        }
        guard activeChannelId == contact.id else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: [
                    "reason": "selected-contact-not-active-channel",
                    "contact": contact.handle,
                    "activeChannelId": activeChannelId?.uuidString ?? "none",
                ]
            )
            return
        }
        guard !remoteTransmittingContactIDs.contains(contact.id) else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "peer-still-transmitting", "contact": contact.handle]
            )
            updateStatusForSelectedContact()
            return
        }
        let selectedPeer = selectedPeerState(for: contact.id)
        let isWakeReady = selectedPeer.phase == .wakeReady

        guard canBeginTransmit(for: contact.id) else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: [
                    "reason": "selected-peer-disallows-hold-to-talk",
                    "contact": contact.handle,
                    "phase": String(describing: selectedPeer.phase),
                ]
            )
            updateStatusForSelectedContact()
            return
        }

        if !isWakeReady {
            guard let channelState = selectedChannelState,
                  channelState.canTransmit else {
                diagnostics.record(
                    .media,
                    message: "Ignored begin transmit request",
                    metadata: [
                        "reason": "backend-channel-cannot-transmit",
                        "contact": contact.handle,
                        "channelStatus": selectedChannelState?.status ?? "none",
                    ]
                )
                updateStatusForSelectedContact()
                return
            }
        }

        guard let backendChannelId = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let backend = backendServices else {
            statusMessage = "Channel is not ready"
            return
        }

        diagnostics.record(.media, message: "Begin transmit requested", metadata: ["contact": contact.handle])
        let request = TransmitRequestContext(
            contactID: contact.id,
            contactHandle: contact.handle,
            backendChannelID: backendChannelId,
            remoteUserID: remoteUserID,
            channelUUID: channelUUID(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend,
            backendSupportsWebSocket: backend.supportsWebSocket
        )
        // Latch the press locally before the async reducer runs so a single
        // hold gesture cannot enqueue multiple begin-transmit attempts.
        transmitRuntime.markPressBegan()
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-begin:requested")
        Task {
            await transmitCoordinator.handle(.pressRequested(request))
            syncTransmitState()
        }
    }

    func handleSystemOriginatedBeginTransmitIfNeeded(
        channelUUID: UUID,
        source: String
    ) {
        guard !usesLocalHTTPBackend else { return }
        guard !transmitRuntime.isPressingTalk else { return }
        guard !transmitCoordinator.state.isPressingTalk else { return }
        guard !hasPendingBeginOrActiveTransmit else { return }
        guard let request = systemOriginatedTransmitRequest(for: channelUUID) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "System-originated transmit began without resolvable backend request context",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "source": source,
                    "applicationState": String(describing: UIApplication.shared.applicationState),
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Beginning backend transmit after system-originated handoff",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelUUID": channelUUID.uuidString,
                "channelId": request.backendChannelID,
                "source": source,
            ]
        )
        if selectedContactId == nil {
            selectedContactId = request.contactID
        }
        transmitRuntime.markPressBegan()
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-begin:system-originated")
        Task {
            await transmitCoordinator.handle(.systemPressRequested(request))
            syncTransmitState()
        }
    }

    func systemOriginatedTransmitRequest(for channelUUID: UUID) -> TransmitRequestContext? {
        guard isJoined else { return nil }
        guard let contactID = contactId(for: channelUUID),
              activeChannelId == contactID,
              let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelId = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let backend = backendServices else {
            return nil
        }

        return TransmitRequestContext(
            contactID: contact.id,
            contactHandle: contact.handle,
            backendChannelID: backendChannelId,
            remoteUserID: remoteUserID,
            channelUUID: channelUUID,
            usesLocalHTTPBackend: usesLocalHTTPBackend,
            backendSupportsWebSocket: backend.supportsWebSocket
        )
    }

    func hasPendingTransmitLifecycle(for systemChannelUUID: UUID) -> Bool {
        transmitProjection.hasPendingLifecycle(
            for: systemChannelUUID,
            channelUUIDForContact: { [weak self] contactID in
                self?.channelUUID(for: contactID)
            }
        )
    }

    func noteTransmitTouchReleased() {
        transmitRuntime.noteTouchReleased()
    }

    func endTransmit() {
        transmitRuntime.noteTouchReleased()
        guard isJoined else { return }
        let hasPendingOrActiveTransmit =
            transmitCoordinator.state.isPressingTalk
            || hasPendingBeginOrActiveTransmit
            || isTransmitting
        guard hasPendingOrActiveTransmit else { return }
        diagnostics.record(.media, message: "End transmit requested")
        // Clear the local press latch immediately so a system-end callback racing
        // with release does not look like an unexpected end that should be retried.
        transmitRuntime.markExplicitStopRequested()
        transmitRuntime.markPressEnded()
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        Task {
            await transmitCoordinator.handle(.releaseRequested)
            syncTransmitState()
            updateStatusForSelectedContact()
        }
    }

    func runTransmitEffect(_ effect: TransmitEffect) async {
        switch effect {
        case .beginTransmit(let request):
            transmitTaskCoordinator.send(.beginRequested(request))
        case .activateTransmit(let request, let target):
            await performActivateTransmit(request, target: target)
        case .stopTransmit(let target):
            await performStopTransmit(target)
        case .abortTransmit(let target):
            await performAbortTransmit(target)
        }
    }

    func runTransmitTaskEffect(_ effect: TransmitTaskEffect) {
        switch effect {
        case .cancelBegin:
            transmitTaskRuntime.cancelBeginTask()
        case .startBegin(let workID, let request):
            transmitTaskRuntime.replaceBeginTask(
                with: Task { [weak self] in
                    await self?.performBeginTransmit(request, workID: workID)
                },
                id: workID
            )
        case .cancelRenewal:
            transmitTaskRuntime.cancelRenewalTask()
        case .startRenewal(let workID, let target):
            transmitTaskRuntime.replaceRenewalTask(
                with: Task.detached(priority: .userInitiated) { [weak self] in
                    await self?.performTransmitLeaseRenewal(for: target, workID: workID)
                },
                id: workID,
                target: target
            )
        }
    }

    private func resumeWebSocketBeforePTTTransportWaitIfNeeded(
        _ backend: BackendServices,
        contactID: UUID,
        channelID: String,
        reason: String
    ) {
        guard backend.supportsWebSocket else { return }
        guard !backend.isWebSocketConnected else { return }
        backend.resumeWebSocket()
        diagnostics.record(
            .websocket,
            message: "Resuming WebSocket before PTT transport wait",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "reason": reason,
                "applicationState": String(describing: currentApplicationState()),
            ]
        )
    }

    func refreshWebSocketForSystemTransmitActivationIfNeeded(
        _ backend: BackendServices,
        contactID: UUID,
        channelID: String
    ) {
        guard backend.supportsWebSocket else { return }
        let applicationState = currentApplicationState()
        guard applicationState != .active else {
            resumeWebSocketBeforePTTTransportWaitIfNeeded(
                backend,
                contactID: contactID,
                channelID: channelID,
                reason: "system-transmit-activation"
            )
            return
        }

        diagnostics.record(
            .websocket,
            message: "Refreshing WebSocket for system-originated transmit activation",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "applicationState": String(describing: applicationState),
            ]
        )
        backend.forceReconnectWebSocket()
    }

    func refreshWebSocketForWakeReceiveActivationIfNeeded(
        _ backend: BackendServices,
        contactID: UUID,
        channelID: String
    ) {
        guard backend.supportsWebSocket else { return }
        let applicationState = currentApplicationState()
        resumeWebSocketBeforePTTTransportWaitIfNeeded(
            backend,
            contactID: contactID,
            channelID: channelID,
            reason: "wake-receive-activation"
        )
        guard applicationState != .active else { return }
        guard !backend.isWebSocketConnected else {
            diagnostics.record(
                .websocket,
                message: "Preserving active WebSocket during wake receive activation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "applicationState": String(describing: applicationState),
                ]
            )
            return
        }

        diagnostics.record(
            .websocket,
            message: "Refreshing WebSocket for wake receive activation",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "applicationState": String(describing: applicationState),
            ]
        )
        backend.forceReconnectWebSocket()
    }

    private func performBeginTransmit(_ request: TransmitRequestContext, workID: Int) async {
        defer {
            transmitTaskCoordinator.send(.beginFinished(id: workID))
            syncTransmitState()
        }
        guard let backend = backendServices else { return }

        do {
            try requestSystemTransmitHandoffIfNeeded(for: request)
            if request.backendSupportsWebSocket {
                resumeWebSocketBeforePTTTransportWaitIfNeeded(
                    backend,
                    contactID: request.contactID,
                    channelID: request.backendChannelID,
                    reason: "begin-transmit"
                )
            }
            if await reassertBackendJoinAfterWakeIfNeeded(for: request.contactID) {
                await refreshChannelState(for: request.contactID)
            }
            // `beginTransmit` is an HTTP control-plane call that acquires the
            // transmit lease and triggers APNs wake. Do not block that on
            // websocket readiness, which can take several seconds on a cold
            // background path. The later activation step still waits for the
            // websocket before live audio signaling starts.
            let response = try await backend.beginTransmit(channelId: request.backendChannelID)
            let target = TransmitTarget(
                contactID: request.contactID,
                userID: request.remoteUserID,
                deviceID: response.targetDeviceId,
                channelID: request.backendChannelID
            )
            transmitRuntime.syncActiveTarget(target)
            diagnostics.record(
                .media,
                message: "Backend transmit lease granted",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "startedAt": response.startedAt,
                    "expiresAt": response.expiresAt,
                    "targetDeviceId": response.targetDeviceId,
                ]
            )
            // The backend lease starts as soon as beginTransmit succeeds.
            // Keep it alive from that point, not from later PTT activation
            // callbacks, which can land seconds later on a cold wake path.
            if transmitRuntime.isPressingTalk {
                diagnostics.record(
                    .media,
                    message: "Starting transmit lease renewal after backend grant",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "source": "begin-transmit",
                    ]
                )
                startRenewingTransmit(target)
            } else {
                diagnostics.record(
                    .media,
                    message: "Backend transmit lease granted after release; stopping immediately",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "source": "begin-transmit",
                    ]
                )
            }
            await transmitCoordinator.handle(.beginSucceeded(target, request))
            syncTransmitState()
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: target
            )
        } catch {
            if Task.isCancelled || isExpectedBackendSyncCancellation(error) {
                cancelRequestedSystemTransmitHandoffIfNeeded(
                    channelUUID: request.channelUUID,
                    reason: "backend-begin-cancelled"
                )
                return
            }
            if shouldTreatTransmitBeginMembershipLossAsRecoverable(error) {
                diagnostics.record(
                    .media,
                    message: "Recovering transmit begin after membership drift",
                    metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID]
                )
                if await recoverTransmitBeginMembershipLoss(request: request, backend: backend) {
                    return
                }
            }
            cancelRequestedSystemTransmitHandoffIfNeeded(
                channelUUID: request.channelUUID,
                reason: "backend-begin-failed"
            )
            let message = error.localizedDescription
            await transmitCoordinator.handle(.beginFailed(message))
            syncTransmitState()
            statusMessage = "Transmit failed: \(message)"
            diagnostics.record(.media, level: .error, message: "Transmit failed", metadata: ["contact": request.contactHandle, "error": message])
        }
    }

    private func recoverTransmitBeginMembershipLoss(
        request: TransmitRequestContext,
        backend: BackendServices
    ) async -> Bool {
        do {
            _ = try await backend.joinChannel(channelId: request.backendChannelID)
            let response = try await backend.beginTransmit(channelId: request.backendChannelID)
            let target = TransmitTarget(
                contactID: request.contactID,
                userID: request.remoteUserID,
                deviceID: response.targetDeviceId,
                channelID: request.backendChannelID
            )
            transmitRuntime.syncActiveTarget(target)
            diagnostics.record(
                .media,
                message: "Backend transmit lease granted",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "startedAt": response.startedAt,
                    "expiresAt": response.expiresAt,
                    "targetDeviceId": response.targetDeviceId,
                ]
            )
            if transmitRuntime.isPressingTalk {
                diagnostics.record(
                    .media,
                    message: "Starting transmit lease renewal after recovered backend grant",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "source": "membership-recovery",
                    ]
                )
                startRenewingTransmit(target)
            } else {
                diagnostics.record(
                    .media,
                    message: "Recovered backend transmit lease granted after release; stopping immediately",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "source": "membership-recovery",
                    ]
                )
            }
            diagnostics.record(
                .media,
                message: "Recovered transmit membership drift",
                metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID]
            )
            await transmitCoordinator.handle(.beginSucceeded(target, request))
            syncTransmitState()
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: target
            )
            return true
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Transmit membership recovery failed",
                metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID, "error": error.localizedDescription]
            )
            await refreshChannelState(for: request.contactID)
            return false
        }
    }

    private func performActivateTransmit(_ request: TransmitRequestContext, target: TransmitTarget) async {
        if request.usesLocalHTTPBackend {
            configureOutgoingAudioRoute(target: target)
            startRenewingTransmit(target)
            isTransmitting = true
        } else {
            guard request.channelUUID != nil else {
                let message = "PTT channel is not ready"
                statusMessage = message
                await transmitCoordinator.handle(.stopFailed(message))
                syncTransmitState()
                return
            }
            // Keep the backend transmit lease alive during the cold PTT
            // activation window instead of waiting for later audio-session
            // callbacks, which can arrive after the initial lease expires.
            startRenewingTransmit(target)
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: target
            )
        }

        await refreshChannelState(for: request.contactID)
    }

    private func requestSystemTransmitHandoffIfNeeded(
        for request: TransmitRequestContext
    ) throws {
        guard !request.usesLocalHTTPBackend else { return }
        guard let channelUUID = request.channelUUID else { return }
        guard !pttCoordinator.state.isTransmitting || pttCoordinator.state.systemChannelUUID != channelUUID else { return }
        guard !transmitRuntime.isSystemTransmitBeginPending(channelUUID: channelUUID) else { return }

        if shouldClosePrewarmedMediaBeforeSystemTransmit(for: request.contactID) {
            diagnostics.record(
                .media,
                message: "Closing app-managed media session before system transmit handoff",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "mediaState": String(describing: mediaConnectionState),
                ]
            )
            closeMediaSession()
        }

        diagnostics.record(
            .pushToTalk,
            message: "Requesting system transmit handoff",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelUUID": channelUUID.uuidString,
                "source": "parallel-begin",
            ]
        )
        transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        do {
            try pttSystemClient.beginTransmitting(channelUUID: channelUUID)
        } catch {
            transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
            throw error
        }
    }

    private func cancelRequestedSystemTransmitHandoffIfNeeded(
        channelUUID: UUID?,
        reason: String
    ) {
        guard let channelUUID else { return }
        let hadPendingBegin = transmitRuntime.isSystemTransmitBeginPending(channelUUID: channelUUID)
        let isActiveSystemTransmit =
            pttCoordinator.state.systemChannelUUID == channelUUID
            && (pttCoordinator.state.isTransmitting || isPTTAudioSessionActive)
        guard hadPendingBegin || isActiveSystemTransmit else { return }

        transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
        diagnostics.record(
            .pushToTalk,
            message: "Cancelling requested system transmit handoff",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "reason": reason,
                "hadPendingBegin": String(hadPendingBegin),
                "isActiveSystemTransmit": String(isActiveSystemTransmit),
            ]
        )
        try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
    }

    private func completeDeferredSystemTransmitActivationIfReady(
        request: TransmitRequestContext,
        target: TransmitTarget
    ) async {
        guard !request.usesLocalHTTPBackend else { return }
        guard let channelUUID = request.channelUUID else { return }
        guard pttCoordinator.state.systemChannelUUID == channelUUID else { return }
        guard isPTTAudioSessionActive else { return }
        await completeSystemTransmitActivation(channelUUID: channelUUID)
    }

    func activeTransmitTarget(for systemChannelUUID: UUID) -> TransmitTarget? {
        transmitProjection.activeTarget(
            for: systemChannelUUID,
            channelUUIDForContact: { [weak self] contactID in
                self?.channelUUID(for: contactID)
            }
        )
    }

    func completeSystemTransmitActivation(channelUUID: UUID) async {
        guard let target = activeTransmitTarget(for: channelUUID) else { return }
        guard transmitCoordinator.state.isPressingTalk else { return }
        guard transmitRuntime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID) else {
            diagnostics.record(
                .media,
                message: "Skipped duplicate system transmit activation",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                ]
            )
            return
        }

        var activationCompleted = false
        defer {
            if !activationCompleted {
                transmitRuntime.clearSystemTransmitActivation(channelUUID: channelUUID)
            }
        }

        startRenewingTransmit(target)

        guard let backend = backendServices, backend.supportsWebSocket else {
            await refreshChannelState(for: target.contactID)
            return
        }

        do {
            refreshWebSocketForSystemTransmitActivationIfNeeded(
                backend,
                contactID: target.contactID,
                channelID: target.channelID
            )
            try await backend.waitForWebSocketConnection()
            configureOutgoingAudioRoute(target: target)
            await ensureMediaSession(
                for: target.contactID,
                activationMode: .systemActivated,
                startupMode: .interactive
            )
            configureOutgoingAudioRoute(target: target)
            try await mediaServices.session()?.startSendingAudio()
            try await backend.sendSignal(
                TurboSignalEnvelope(
                    type: .transmitStart,
                    channelId: target.channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: target.userID,
                    toDeviceId: target.deviceID,
                    payload: "ptt-begin"
                )
            )
            transmitRuntime.noteSystemTransmitActivationCompleted(channelUUID: channelUUID)
            activationCompleted = true
            await refreshChannelState(for: target.contactID)
        } catch {
            let message = error.localizedDescription
            let contactHandle = contacts.first(where: { $0.id == target.contactID })?.handle ?? "unknown"
            statusMessage = "Transmit failed: \(message)"
            diagnostics.record(
                .media,
                level: .error,
                message: "Transmit activation failed",
                metadata: ["contact": contactHandle, "error": message]
            )
            await performStopTransmit(target)
        }
    }

    func handleActivatedAudioSession(_ audioSession: AVAudioSession) async {
        applyPreferredAudioOutputRoute(to: audioSession)
        let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID
        let activeTarget = activeSystemChannelUUID.flatMap(activeTransmitTarget(for:))
        if let activeTarget,
           audioSession.category != .playAndRecord {
            diagnostics.record(
                .media,
                message: "Continuing system transmit activation from initial audio session category",
                metadata: [
                    "contactId": activeTarget.contactID.uuidString,
                    "channelUUID": activeSystemChannelUUID?.uuidString ?? "none",
                    "category": audioSession.category.rawValue,
                    "mode": audioSession.mode.rawValue,
                ]
            )
        }
        let pendingWake = pttWakeRuntime.pendingIncomingPush
        if let wake = pendingWake {
            pttWakeRuntime.replacePlaybackFallbackTask(for: wake.contactID, with: nil)
            pttWakeRuntime.markAudioSessionActivated(for: wake.channelUUID)
            diagnostics.record(
                .pushToTalk,
                message: "Handling PTT wake audio activation",
                metadata: [
                    "channelUUID": wake.channelUUID.uuidString,
                    "contactID": wake.contactID.uuidString,
                    "event": wake.payload.event.rawValue,
                ]
            )
            let contactID = wake.contactID
            if let backend = backendServices,
               let channelID =
                wake.payload.channelId
                ?? contacts.first(where: { $0.id == contactID })?.backendChannelId {
                // The pre-activation reconnect may still be a stale `connecting`
                // socket started before the system granted background audio
                // execution. Once the system PTT session is active, force a
                // fresh reconnect so deferred receiver-ready publications can
                // actually drain during the wake window.
                refreshWebSocketForWakeReceiveActivationIfNeeded(
                    backend,
                    contactID: contactID,
                    channelID: channelID
                )
            } else {
                backendServices?.resumeWebSocket()
            }
            diagnostics.record(
                .media,
                message: "Recreating media session after PTT audio activation",
                metadata: ["contactId": contactID.uuidString]
            )
            closeMediaSession(deactivateAudioSession: false)
            await ensureMediaSession(
                for: contactID,
                activationMode: .systemActivated,
                startupMode: .playbackOnly
            )
            let bufferedAudioChunks = pttWakeRuntime.takeBufferedAudioChunks(for: contactID)
            if !bufferedAudioChunks.isEmpty {
                diagnostics.record(
                    .media,
                    message: "Flushing buffered wake audio after PTT activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "bufferedChunkCount": String(bufferedAudioChunks.count)
                    ]
                )
                for payload in bufferedAudioChunks {
                    await receiveRemoteAudioChunk(payload)
                }
            } else {
                diagnostics.record(
                    .media,
                    message: "No buffered wake audio to flush after PTT activation",
                    metadata: ["contactId": contactID.uuidString]
                )
            }
            captureDiagnosticsState("ptt-wake:audio-activated")
            schedulePostWakeBackendRefresh(for: contactID)
        }

        if activeTarget == nil,
           pendingWake == nil,
           let activeSystemChannelUUID,
           let receiveContactID = contactId(for: activeSystemChannelUUID),
           remoteTransmittingContactIDs.contains(receiveContactID),
           shouldUseSystemActivatedReceivePlayback(for: receiveContactID) {
            diagnostics.record(
                .media,
                message: "Preparing receive media session after PTT audio activation",
                metadata: [
                    "contactId": receiveContactID.uuidString,
                    "channelUUID": activeSystemChannelUUID.uuidString
                ]
            )
            await ensureMediaSession(
                for: receiveContactID,
                activationMode: .systemActivated,
                startupMode: .playbackOnly
            )
        }

        if let activeSystemChannelUUID,
           let activeTarget {
            configureOutgoingAudioRoute(target: activeTarget)
            await completeSystemTransmitActivation(channelUUID: activeSystemChannelUUID)
        }
    }

    func schedulePostWakeBackendRefresh(for contactID: UUID) {
        Task { [weak self] in
            await self?.controlPlaneCoordinator.handle(.postWakeRepairRequested(contactID: contactID))
        }
    }

    func setAudioOutputPreference(_ preference: AudioOutputPreference) {
        guard preference == .speaker else { return }
        guard audioOutputPreference != preference else {
            applyPreferredAudioOutputRouteIfPossible()
            return
        }
        audioOutputPreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: AudioOutputPreference.storageKey)
        applyPreferredAudioOutputRouteIfPossible()
        diagnostics.record(
            .media,
            message: "Audio output preference updated",
            metadata: ["preference": preference.rawValue]
        )
        captureDiagnosticsState("audio-route:updated")
    }

    func applyPreferredAudioOutputRoute(to audioSession: AVAudioSession = .sharedInstance()) {
        let overridePlan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: audioOutputPreference,
            category: audioSession.category,
            outputPortTypes: audioSession.currentRoute.outputs.map(\.portType)
        )
        guard overridePlan.shouldApplySpeakerOverride else {
            guard audioSession.category != .playAndRecord else { return }
            diagnostics.record(
                .media,
                message: "Skipped preferred audio output route override until play-and-record session is active",
                metadata: [
                    "preference": audioOutputPreference.rawValue,
                    "category": audioSession.category.rawValue,
                    "mode": audioSession.mode.rawValue,
                ]
            )
            return
        }
        do {
            try audioSession.overrideOutputAudioPort(.speaker)
            diagnostics.record(
                .media,
                message: "Applied preferred audio output route",
                metadata: audioSessionDiagnostics(audioSession).merging(
                    ["preference": audioOutputPreference.rawValue]
                ) { _, new in new }
            )
        } catch {
            let message = error.localizedDescription
            if message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "session activation failed" {
                diagnostics.record(
                    .media,
                    message: "Deferred preferred audio output route until session activation",
                    metadata: [
                        "preference": audioOutputPreference.rawValue,
                        "category": audioSession.category.rawValue,
                        "mode": audioSession.mode.rawValue,
                    ]
                )
                return
            }
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to apply preferred audio output route",
                metadata: [
                    "error": message,
                    "preference": audioOutputPreference.rawValue,
                    "category": audioSession.category.rawValue,
                    "mode": audioSession.mode.rawValue,
                ]
            )
        }
    }

    func applyPreferredAudioOutputRouteIfPossible() {
        guard mediaServices.hasSession() || pttCoordinator.state.systemChannelUUID != nil else { return }
        applyPreferredAudioOutputRoute()
    }

    func handleDeactivatedAudioSession(
        _ audioSession: AVAudioSession,
        applicationState: UIApplication.State? = nil
    ) async {
        let applicationState = applicationState ?? UIApplication.shared.applicationState
        let _ = audioSession
        if !pttCoordinator.state.isTransmitting {
            try? await mediaServices.session()?.stopSendingAudio()
        }
        mediaRuntime.replaceInteractivePrewarmRecoveryTask(with: nil)
        pttWakeRuntime.clearAll(clearSuppression: false)
        if let contactID = mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID {
            guard applicationState == .active else {
                diagnostics.record(
                    .media,
                    message: "Deferred interactive audio prewarm after PTT audio deactivation until foreground",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "applicationState": String(describing: applicationState)
                    ]
                )
                return
            }
            _ = mediaRuntime.takePendingInteractivePrewarmAfterAudioDeactivationContactID()
            diagnostics.record(
                .media,
                message: "Resuming deferred interactive audio prewarm after PTT audio deactivation",
                metadata: ["contactId": contactID.uuidString]
            )
            try? await Task.sleep(nanoseconds: 200_000_000)
            await prewarmLocalMediaIfNeeded(for: contactID, applicationState: applicationState)
        }
    }

    func scheduleWakePlaybackFallback(for contactID: UUID) {
        guard pttWakeRuntime.hasPendingWake(for: contactID) else { return }
        guard !pttWakeRuntime.hasPlaybackFallbackTask(for: contactID) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: wakePlaybackFallbackDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self.runWakePlaybackFallbackIfNeeded(for: contactID)
        }
        pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: task)
    }

    func resumeBufferedWakePlaybackIfNeeded(
        reason: String,
        applicationState: UIApplication.State
    ) async {
        guard let pendingWake = pttWakeRuntime.pendingIncomingPush else { return }
        guard pttWakeRuntime.shouldBufferAudioChunk(for: pendingWake.contactID) else { return }
        guard pttWakeRuntime.bufferedAudioChunkCount(for: pendingWake.contactID) > 0 else { return }
        await runWakePlaybackFallbackIfNeeded(
            for: pendingWake.contactID,
            reason: reason,
            applicationState: applicationState
        )
    }

    func runWakePlaybackFallbackIfNeeded(for contactID: UUID) async {
        await runWakePlaybackFallbackIfNeeded(
            for: contactID,
            reason: "ptt-activation-timeout",
            applicationState: currentApplicationState()
        )
    }

    func runWakePlaybackFallbackIfNeeded(
        for contactID: UUID,
        reason: String,
        applicationState: UIApplication.State
    ) async {
        defer {
            pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
        }

        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else { return }
        let bufferedChunkCount = pttWakeRuntime.bufferedAudioChunkCount(for: contactID)
        guard shouldUseAppManagedWakePlaybackFallback(applicationState: applicationState) else {
            pttWakeRuntime.markFallbackDeferredUntilForeground(for: contactID)
            diagnostics.record(
                .media,
                level: .error,
                message: "PTT system audio activation timed out while app remained backgrounded",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "applicationState": String(describing: applicationState),
                    "bufferedChunkCount": String(bufferedChunkCount),
                    "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
                    "pendingWakeActivationState": String(describing: pttWakeRuntime.pendingIncomingPush?.activationState ?? .signalBuffered),
                ]
            )
            captureDiagnosticsState("ptt-wake:fallback-deferred")
            return
        }
        guard bufferedChunkCount > 0 else {
            diagnostics.record(
                .media,
                message: "PTT activation timed out before buffered audio arrived",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "applicationState": String(describing: applicationState),
                ]
            )
            captureDiagnosticsState("ptt-wake:fallback-timeout-no-audio")
            return
        }

        let bufferedAudioChunks = pttWakeRuntime.takeBufferedAudioChunks(for: contactID)
        pttWakeRuntime.markAppManagedFallbackStarted(for: contactID)
        diagnostics.record(
            .media,
            message: "PTT activation timed out; falling back to app-managed playback",
            metadata: [
                "contactId": contactID.uuidString,
                "bufferedChunkCount": String(bufferedChunkCount),
                "reason": reason
            ]
        )
        captureDiagnosticsState("ptt-wake:fallback-started")

        await ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        for payload in bufferedAudioChunks {
            await receiveRemoteAudioChunk(payload)
        }
    }

    private func configureOutgoingAudioRoute(target: TransmitTarget) {
        guard let backend = backendServices else {
            mediaServices.replaceSendAudioChunk(nil)
            mediaServices.session()?.updateSendAudioChunk(nil)
            diagnostics.record(
                .media,
                level: .error,
                message: "Cleared outgoing audio transport because backend services are unavailable",
                metadata: ["contactId": target.contactID.uuidString, "channelId": target.channelID]
            )
            return
        }

        let channelID = target.channelID
        let fromUserID = backend.currentUserID ?? ""
        let fromDeviceID = backend.deviceID
        let toUserID = target.userID
        let toDeviceID = target.deviceID

        let sendAudioChunk: @Sendable (String) async throws -> Void = { [weak self] payload in
            if let self,
               await self.takeShouldAwaitInitialOutboundAudioSendGate() {
                _ = await self.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
                    target: target
                )
            }
            let envelope = TurboSignalEnvelope(
                type: .audioChunk,
                channelId: channelID,
                fromUserId: fromUserID,
                fromDeviceId: fromDeviceID,
                toUserId: toUserID,
                toDeviceId: toDeviceID,
                payload: payload
            )
            try await backend.sendSignal(envelope)
        }
        mediaServices.replaceSendAudioChunk(sendAudioChunk)
        mediaServices.session()?.updateSendAudioChunk(sendAudioChunk)
        diagnostics.record(
            .media,
            message: "Configured outgoing audio transport",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "deviceId": target.deviceID
            ]
        )
    }

    func takeShouldAwaitInitialOutboundAudioSendGate() -> Bool {
        transmitRuntime.takeShouldAwaitInitialOutboundAudioSendGate()
    }

    func waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
        target: TransmitTarget,
        timeoutNanoseconds: UInt64? = nil,
        pollNanoseconds: UInt64? = nil,
        wakeRecoveryGraceNanoseconds: UInt64? = nil,
        postReleaseWakeRecoveryGraceNanoseconds: UInt64? = nil
    ) async -> Bool {
        let timeoutNanoseconds = timeoutNanoseconds ?? remoteReceiverAudioReadyGateTimeoutNanoseconds
        let pollNanoseconds = pollNanoseconds ?? remoteReceiverAudioReadyGatePollNanoseconds
        let wakeRecoveryGraceNanoseconds =
            wakeRecoveryGraceNanoseconds ?? wakeCapableInitialAudioSendGraceNanoseconds
        let postReleaseWakeRecoveryGraceNanoseconds =
            postReleaseWakeRecoveryGraceNanoseconds ?? wakeCapablePostReleaseAudioSendGraceNanoseconds

        guard let channelSnapshot = selectedChannelSnapshot(for: target.contactID) else {
            return true
        }
        guard !channelSnapshot.remoteAudioReadyForLiveTransmit else {
            return true
        }
        let wakeCapablePeer: Bool
        if case .wakeCapable = channelSnapshot.remoteWakeCapability {
            wakeCapablePeer = true
            diagnostics.record(
                .media,
                message: "Waiting for wake-capable receiver recovery before sending initial outbound audio",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "remoteAudioReadiness": String(describing: channelSnapshot.remoteAudioReadiness),
                    "readinessStatus": String(describing: channelSnapshot.readinessStatus),
                    "wakeRecoveryGraceMilliseconds": String(wakeRecoveryGraceNanoseconds / 1_000_000),
                ]
            )
        } else {
            wakeCapablePeer = false
            diagnostics.record(
                .media,
                message: "Waiting for remote receiver audio readiness before sending outbound audio",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "remoteAudioReadiness": String(describing: channelSnapshot.remoteAudioReadiness),
                    "readinessStatus": String(describing: channelSnapshot.readinessStatus),
                    "peerDeviceConnected": String(channelSnapshot.membership.peerDeviceConnected),
                ]
            )
        }

        let startedAt = Date()
        var releaseLogged = false
        var postReleaseGraceLogged = false
        while true {
            if selectedChannelSnapshot(for: target.contactID)?.remoteAudioReadyForLiveTransmit == true {
                diagnostics.record(
                    .media,
                    message: "Remote receiver audio became ready; releasing outbound audio send gate",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    ]
                )
                return true
            }

            let waitedNanoseconds = UInt64(Date().timeIntervalSince(startedAt) * 1_000_000_000)
            if waitedNanoseconds >= timeoutNanoseconds {
                let currentSnapshot = selectedChannelSnapshot(for: target.contactID)
                diagnostics.recordInvariantViolation(
                    invariantID: "transmit.outbound_audio_without_remote_receiver_ready",
                    scope: .backend,
                    message: "sender resumed outbound audio before remote receiver readiness recovered",
                    metadata: [
                        "reason": "remote-receiver-ready-gate-timeout",
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "selectedPeerPhase": String(describing: selectedPeerState(for: target.contactID).phase),
                        "backendChannelStatus": currentSnapshot?.status?.rawValue ?? "none",
                        "backendReadiness": currentSnapshot?.readinessStatus?.kind ?? "none",
                        "remoteAudioReadiness": String(describing: currentSnapshot?.remoteAudioReadiness ?? .unknown),
                        "peerDeviceConnected": String(currentSnapshot?.membership.peerDeviceConnected ?? false),
                        "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    ]
                )
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Timed out waiting for remote receiver audio readiness; sending anyway",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    ]
                )
                return false
            }

            if wakeCapablePeer && waitedNanoseconds >= wakeRecoveryGraceNanoseconds {
                if !transmitRuntime.isPressingTalk,
                   waitedNanoseconds
                    < wakeRecoveryGraceNanoseconds + postReleaseWakeRecoveryGraceNanoseconds {
                    if !postReleaseGraceLogged {
                        postReleaseGraceLogged = true
                        diagnostics.record(
                            .media,
                            message: "Extending wake-capable receiver recovery hold after talk release to preserve buffered audio",
                            metadata: [
                                "contactId": target.contactID.uuidString,
                                "channelId": target.channelID,
                                "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                                "postReleaseGraceMilliseconds": String(
                                    postReleaseWakeRecoveryGraceNanoseconds / 1_000_000
                                ),
                            ]
                        )
                    }
                } else if !transmitRuntime.isPressingTalk {
                    diagnostics.record(
                        .media,
                        message: "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                            "remoteAudioReadiness": String(
                                describing: selectedChannelSnapshot(for: target.contactID)?.remoteAudioReadiness ?? .unknown
                            ),
                        ]
                    )
                    return true
                }
            }

            if !transmitRuntime.isPressingTalk {
                if !wakeCapablePeer {
                    return false
                }
                if !releaseLogged {
                    releaseLogged = true
                    diagnostics.record(
                        .media,
                        message: "Continuing to hold initial outbound audio after talk release until wake-capable receiver recovery",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                        ]
                    )
                }
            }

            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    func reconcileExplicitTransmitStopIfNeeded(
        target: TransmitTarget,
        source: String
    ) async {
        guard !usesLocalHTTPBackend else { return }
        guard pttCoordinator.state.isTransmitting else { return }
        guard let systemChannelUUID = pttCoordinator.state.systemChannelUUID,
              channelUUID(for: target.contactID) == systemChannelUUID else {
            return
        }

        diagnostics.record(
            .pushToTalk,
            message: "Reconciling explicit transmit stop without system callback",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelUUID": systemChannelUUID.uuidString,
                "source": source,
            ]
        )
        await pttCoordinator.handle(
            .didEndTransmitting(
                channelUUID: systemChannelUUID,
                source: source
            )
        )
        syncPTTState()
        captureDiagnosticsState("transmit-stop:reconciled")
    }

    func finalizeExplicitTransmitStopLocallyIfNeeded(
        target: TransmitTarget,
        source: String
    ) async {
        await reconcileExplicitTransmitStopIfNeeded(
            target: target,
            source: source
        )

        let shouldCompleteStop =
            transmitCoordinator.state.activeTarget == target
            || transmitRuntime.activeTarget == target
            || {
                switch transmitCoordinator.state.phase {
                case .stopping(let contactID):
                    return contactID == target.contactID
                case .idle, .requesting, .active:
                    return false
                }
            }()
        guard shouldCompleteStop else { return }

        diagnostics.record(
            .pushToTalk,
            message: "Finalizing explicit transmit stop locally",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "source": source,
            ]
        )
        await transmitCoordinator.handle(.stopCompleted)
        syncTransmitState()
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-stop:completed-locally")
    }

    private func performStopTransmit(_ target: TransmitTarget) async {
        let media = mediaServices
        transmitTaskCoordinator.send(.renewalCancelled)

        if usesLocalHTTPBackend {
            isTransmitting = false
        } else if let activeChannelId,
                  let channelUUID = channelUUID(for: activeChannelId),
                  pttCoordinator.state.isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }

        do {
            try? await media.session()?.stopSendingAudio()
            await finalizeExplicitTransmitStopLocallyIfNeeded(
                target: target,
                source: "explicit-stop-local-complete"
            )
            if let backend = backendServices {
                diagnostics.record(
                    .media,
                    message: "Ending transmit on backend",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "webSocketConnected": String(backend.isWebSocketConnected),
                    ]
                )
                _ = try await backend.endTransmit(channelId: target.channelID)
                diagnostics.record(
                    .media,
                    message: "Ended transmit on backend",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                    ]
                )
                if backend.supportsWebSocket && backend.isWebSocketConnected {
                    try? await backend.sendSignal(
                        TurboSignalEnvelope(
                            type: .transmitStop,
                            channelId: target.channelID,
                            fromUserId: backend.currentUserID ?? "",
                            fromDeviceId: backend.deviceID,
                            toUserId: target.userID,
                            toDeviceId: target.deviceID,
                            payload: "ptt-end"
                        )
                    )
                }
            }
            await refreshChannelState(for: target.contactID)
        } catch {
            guard !isExpectedBackendSyncCancellation(error) else {
                await refreshChannelState(for: target.contactID)
                updateStatusForSelectedContact()
                return
            }
            let message = error.localizedDescription
            statusMessage = "Stop cleanup failed: \(message)"
            diagnostics.record(
                .media,
                level: .error,
                message: "Transmit stop cleanup failed after local completion",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "error": message,
                ]
            )
            await refreshChannelState(for: target.contactID)
        }

        updateStatusForSelectedContact()
    }

    private func performAbortTransmit(_ target: TransmitTarget) async {
        transmitTaskCoordinator.send(.renewalCancelled)
        try? await mediaServices.session()?.stopSendingAudio()

        if let backend = backendServices {
            diagnostics.record(
                .media,
                message: "Aborting transmit on backend",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "webSocketConnected": String(backend.isWebSocketConnected),
                ]
            )
            _ = try? await backend.endTransmit(channelId: target.channelID)
            diagnostics.record(
                .media,
                message: "Aborted transmit on backend",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                ]
            )
            if backend.supportsWebSocket && backend.isWebSocketConnected {
                try? await backend.sendSignal(
                    TurboSignalEnvelope(
                        type: .transmitStop,
                        channelId: target.channelID,
                        fromUserId: backend.currentUserID ?? "",
                        fromDeviceId: backend.deviceID,
                        toUserId: target.userID,
                        toDeviceId: target.deviceID,
                        payload: "ptt-end"
                    )
                )
            }
        }

        await refreshChannelState(for: target.contactID)
        syncTransmitState()
        updateStatusForSelectedContact()
    }

    private func currentTransmitLeaseRenewalContext(
        for target: TransmitTarget
    ) -> (systemTransmitDurationMs: String, webSocketConnected: Bool)? {
        guard transmitCoordinator.state.isPressingTalk,
              transmitProjection.activeTarget?.channelID == target.channelID else { return nil }
        return (
            systemTransmitDurationMs: transmitRuntime.currentSystemTransmitDurationMilliseconds().map(String.init) ?? "unknown",
            webSocketConnected: backendServices?.isWebSocketConnected == true
        )
    }

    private func renewTransmitLeaseOnBackend(
        channelId: String
    ) async throws -> TurboRenewTransmitResponse {
        guard let backend = backendServices else {
            throw TurboBackendError.invalidConfiguration
        }
        return try await backend.renewTransmit(channelId: channelId)
    }

    private func startRenewingTransmit(_ target: TransmitTarget) {
        transmitTaskCoordinator.send(.renewalRequested(target))
    }

    private func performTransmitLeaseRenewal(for target: TransmitTarget, workID: Int) async {
        defer {
            transmitTaskCoordinator.send(.renewalFinished(id: workID))
        }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: transmitLeaseRenewIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            guard let context = currentTransmitLeaseRenewalContext(for: target) else { return }
            let renewStartedAt = Date()
            do {
                await MainActor.run {
                    self.diagnostics.record(
                        .media,
                        message: "Renewing transmit lease",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "systemTransmitDurationMs": context.systemTransmitDurationMs,
                            "webSocketConnected": String(context.webSocketConnected),
                        ]
                    )
                }
                let response = try await renewTransmitLeaseOnBackend(channelId: target.channelID)
                let renewDurationMs = Int(Date().timeIntervalSince(renewStartedAt) * 1000)
                await MainActor.run {
                    self.diagnostics.record(
                        .media,
                        message: "Transmit lease renewed",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "systemTransmitDurationMs": context.systemTransmitDurationMs,
                            "renewDurationMs": String(renewDurationMs),
                            "expiresAt": response.expiresAt,
                        ]
                    )
                }
            } catch {
                let renewDurationMs = Int(Date().timeIntervalSince(renewStartedAt) * 1000)
                let currentSystemTransmitDurationMs = await MainActor.run {
                    self.transmitRuntime.currentSystemTransmitDurationMilliseconds().map(String.init) ?? "unknown"
                }
                let shouldTreatAsCancellation = await MainActor.run {
                    self.isExpectedBackendSyncCancellation(error)
                        || !self.transmitCoordinator.state.isPressingTalk
                        || !self.pttCoordinator.state.isTransmitting
                }
                if shouldTreatAsCancellation {
                    await MainActor.run {
                        self.diagnostics.record(
                            .media,
                            message: "Transmit lease renewal cancelled",
                            metadata: [
                                "contactId": target.contactID.uuidString,
                                "channelId": target.channelID,
                                "renewDurationMs": String(renewDurationMs),
                                "systemTransmitDurationMs": currentSystemTransmitDurationMs,
                                "error": error.localizedDescription,
                            ]
                        )
                    }
                    return
                }
                let shouldTreatAsLeaseLoss = await MainActor.run {
                    self.shouldTreatTransmitLeaseLossAsStop(error)
                }
                if shouldTreatAsLeaseLoss {
                    await MainActor.run {
                        self.diagnostics.record(
                            .media,
                            level: .error,
                            message: "Transmit lease lost during renewal",
                            metadata: [
                                "contactId": target.contactID.uuidString,
                                "channelId": target.channelID,
                                "renewDurationMs": String(renewDurationMs),
                                "systemTransmitDurationMs": currentSystemTransmitDurationMs,
                                "error": error.localizedDescription,
                            ]
                        )
                    }
                    await handleTransmitLeaseLossDuringRenewal(target: target)
                    return
                }
                let message = error.localizedDescription
                await MainActor.run {
                    self.statusMessage = "Transmit lease expired: \(message)"
                    self.isTransmitting = false
                    self.diagnostics.record(
                        .media,
                        level: .error,
                        message: "Transmit lease renewal failed",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "renewDurationMs": String(renewDurationMs),
                            "systemTransmitDurationMs": currentSystemTransmitDurationMs,
                            "error": message,
                        ]
                    )
                }
                await transmitCoordinator.handle(.renewalFailed(message))
                await refreshChannelState(for: target.contactID)
                await MainActor.run {
                    self.syncTransmitState()
                }
                return
            }
        }
    }

    private func handleTransmitLeaseLossDuringRenewal(target: TransmitTarget) async {
        if !usesLocalHTTPBackend,
           let channelUUID = channelUUID(for: target.contactID) {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }
        if let backend = backendServices,
           backend.supportsWebSocket,
           backend.isWebSocketConnected {
            try? await backend.sendSignal(
                TurboSignalEnvelope(
                    type: .transmitStop,
                    channelId: target.channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: target.userID,
                    toDeviceId: target.deviceID,
                    payload: "ptt-end"
                )
            )
        }
        isTransmitting = false
        await transmitCoordinator.handle(.stopCompleted)
        await refreshChannelState(for: target.contactID)
        syncTransmitState()
        updateStatusForSelectedContact()
    }

    func mediaSession(_ session: MediaSession, didChange state: MediaConnectionState) {
        let media = mediaServices
        guard session === media.session() else { return }
        media.updateConnectionState(state)
        diagnostics.record(.media, message: "Media state changed", metadata: ["state": String(describing: state)])
        switch state {
        case .failed(let message):
            backendStatusMessage = "Media failed: \(message)"
        case .connected:
            if let contactID = media.contactID(),
               viewModelWakeStateNeedsClearingAfterRecovery(contactID: contactID) {
                pttWakeRuntime.clear(for: contactID)
            }
        case .closed, .idle, .preparing:
            break
        }
        updateStatusForSelectedContact()
        if let contactID = media.contactID() {
            Task {
                await syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: "media-\(String(describing: state))"
                )
            }
        }
    }

    private func viewModelWakeStateNeedsClearingAfterRecovery(contactID: UUID) -> Bool {
        pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd
    }

    private func shouldPreserveAudioSessionDuringMediaClose() -> Bool {
        pttWakeRuntime.pendingIncomingPush != nil
    }

    func ensureMediaSession(
        for contactID: UUID,
        activationMode: MediaSessionActivationMode? = nil,
        startupMode: MediaSessionStartupMode = .interactive
    ) async {
        guard contacts.contains(where: { $0.id == contactID }) else { return }
        let media = mediaServices
        let sessionNeedsContactSwitch = media.contactID() != contactID
        let sessionNeedsRecreation = shouldRecreateMediaSession(connectionState: mediaConnectionState)
        let sessionNeedsCreation = !media.hasSession()
        let resolvedActivationMode = activationMode ?? pttWakeRuntime.mediaSessionActivationMode(for: contactID)
        let startupContext = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: resolvedActivationMode,
            startupMode: startupMode
        )

        if sessionNeedsContactSwitch {
            closeMediaSession()
        }

        if sessionNeedsRecreation {
            closeMediaSession()
        }

        if sessionNeedsCreation || sessionNeedsContactSwitch || sessionNeedsRecreation {
            let supportsWebSocket = backendServices?.supportsWebSocket == true
            let session = makeDefaultMediaSession(
                supportsWebSocket: supportsWebSocket,
                sendAudioChunk: media.sendAudioChunk(),
                reportEvent: { [weak self] message, metadata in
                    guard let self else { return }
                    await MainActor.run {
                        self.diagnostics.record(.media, message: message, metadata: metadata)
                    }
                }
            )
            session.delegate = self
            media.attach(session, contactID)
            session.updateSendAudioChunk(media.sendAudioChunk())
        }

        if media.isStartupInFlight(startupContext) {
            return
        }

        let shouldStartSession =
            sessionNeedsCreation
            || sessionNeedsContactSwitch
            || sessionNeedsRecreation
            || mediaConnectionState != .connected

        guard shouldStartSession else { return }

        if media.shouldDelayRetry(startupContext, mediaSessionRetryCooldown) {
            diagnostics.record(
                .media,
                message: "Deferred media session retry after recent start failure",
                metadata: [
                    "contactId": contactID.uuidString,
                    "activationMode": String(describing: resolvedActivationMode),
                    "startupMode": String(describing: startupMode)
                ]
            )
            return
        }

        media.markStartupInFlight(startupContext)

        do {
            try await media.session()?.start(
                activationMode: resolvedActivationMode,
                startupMode: startupMode
            )
            media.markStartupSucceeded()
            applyPreferredAudioOutputRouteIfPossible()
        } catch {
            let message = error.localizedDescription
            media.markStartupFailed(startupContext, message)
            backendStatusMessage = "Media setup failed: \(message)"
            diagnostics.record(
                .media,
                level: .error,
                message: "Media session start failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "activationMode": String(describing: resolvedActivationMode),
                    "startupMode": String(describing: startupMode),
                    "error": message
                ]
            )
        }
    }

    func closeMediaSession(deactivateAudioSession: Bool = true) {
        let shouldDeactivateAudioSession =
            deactivateAudioSession && !shouldPreserveAudioSessionDuringMediaClose()
        if deactivateAudioSession && !shouldDeactivateAudioSession {
            diagnostics.record(
                .media,
                message: "Preserving audio session during media close while wake activation is pending",
                metadata: [
                    "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
                    "pendingWakeContactID": pttWakeRuntime.pendingIncomingPush?.contactID.uuidString ?? "none",
                    "pendingWakeActivationState": String(
                        describing: pttWakeRuntime.pendingIncomingPush?.activationState ?? .signalBuffered
                    ),
                ]
            )
        }
        mediaServices.reset(shouldDeactivateAudioSession)
    }
}
