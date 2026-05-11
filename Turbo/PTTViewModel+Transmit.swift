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

private enum OutgoingAudioSendError: LocalizedError, Sendable {
    case remoteReceiverAudioNotReady

    var errorDescription: String? {
        switch self {
        case .remoteReceiverAudioNotReady:
            return "remote receiver audio was not ready"
        }
    }
}

private actor RemoteParticipantClearResultBox {
    private var result: Result<Void, Error>?

    func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
    }

    func currentResult() -> Result<Void, Error>? {
        result
    }
}

extension PTTViewModel {
    private var wakePlaybackFallbackDelayNanoseconds: UInt64 { 3_500_000_000 }
    // Wake-capable receive needs to preserve short utterances while iOS brings
    // the background peer's PTT audio session up. Release immediately on an
    // explicit receiver-ready signal; otherwise use a bounded post-release hold.
    private var wakeCapableInitialAudioSendGraceNanoseconds: UInt64 { 300_000_000 }
    private var wakeCapablePostReleaseAudioSendGraceNanoseconds: UInt64 { 4_500_000_000 }
    private var mediaSessionRetryCooldown: TimeInterval { 0.75 }
    private var deferredInteractivePrewarmRecoveryDelayNanoseconds: UInt64 { 500_000_000 }
    private var transmitLeaseRenewIntervalNanoseconds: UInt64 { 1_000_000_000 }
    private var minimumUsableBackendTransmitLeaseSeconds: TimeInterval { 3.0 }
    private var remoteReceiverAudioReadyGateTimeoutNanoseconds: UInt64 { 6_000_000_000 }
    private var remoteReceiverAudioReadyGatePollNanoseconds: UInt64 { 50_000_000 }
    private var remoteParticipantClearBeforeTransmitTimeoutNanoseconds: UInt64 { 250_000_000 }

    func startTransmitStartupTiming(
        for request: TransmitRequestContext,
        source: String
    ) {
        transmitStartupTiming.start(
            contactID: request.contactID,
            channelUUID: request.channelUUID,
            backendChannelID: request.backendChannelID,
            source: source
        )
        recordTransmitStartupTiming(
            stage: "press-requested",
            contactID: request.contactID,
            channelUUID: request.channelUUID,
            channelID: request.backendChannelID
        )
    }

    func recordTransmitStartupTiming(
        stage: String,
        contactID: UUID? = nil,
        channelUUID: UUID? = nil,
        channelID: String? = nil,
        subsystem: DiagnosticsSubsystem = .media,
        metadata extraMetadata: [String: String] = [:]
    ) {
        let resolvedContactID = contactID ?? transmitStartupTiming.contactID
        let resolvedChannelUUID = channelUUID ?? transmitStartupTiming.channelUUID
        let resolvedChannelID = channelID ?? transmitStartupTiming.backendChannelID
        let elapsedMilliseconds = transmitStartupTiming.noteStage(stage)
        var metadata = extraMetadata
        metadata["stage"] = stage
        metadata["pressToStageMs"] = elapsedMilliseconds.map(String.init) ?? "unknown"
        metadata["contactId"] = resolvedContactID?.uuidString ?? "none"
        metadata["channelUUID"] = resolvedChannelUUID?.uuidString ?? "none"
        metadata["channelId"] = resolvedChannelID ?? "none"
        metadata["source"] = transmitStartupTiming.source ?? "unknown"
        metadata["applicationState"] = String(describing: currentApplicationState())
        metadata["mediaState"] = String(describing: mediaConnectionState)
        metadata["isPTTAudioSessionActive"] = String(isPTTAudioSessionActive)
        metadata["backendWebSocketConnected"] = String(backendRuntime.isWebSocketConnected)
        if let resolvedContactID {
            metadata["directQuicActive"] = String(shouldUseDirectQuicTransport(for: resolvedContactID))
        }
        diagnostics.record(
            subsystem,
            message: "Transmit startup timing",
            metadata: metadata
        )
    }

    func recordFirstTransmitStartupTimingStageIfAbsent(
        _ stage: String,
        subsystem: DiagnosticsSubsystem = .media,
        metadata extraMetadata: [String: String] = [:]
    ) {
        guard transmitStartupTiming.elapsedMilliseconds(for: stage) == nil else {
            return
        }
        recordTransmitStartupTiming(
            stage: stage,
            subsystem: subsystem,
            metadata: extraMetadata
        )
    }

    func recordTransmitStartupTimingForMediaEvent(
        _ message: String,
        metadata: [String: String]
    ) {
        let stage: String?
        switch message {
        case "Captured local audio buffer":
            stage = "first-audio-captured"
        case "Enqueued outbound audio chunk":
            stage = "first-audio-enqueued"
        case "Dispatching outbound audio transport payload":
            stage = "first-audio-dispatched"
        case "Delivered outbound audio transport payload":
            stage = "first-audio-delivered"
        default:
            stage = nil
        }
        guard let stage else { return }
        recordFirstTransmitStartupTimingStageIfAbsent(
            stage,
            metadata: metadata
        )
    }

    func recordTransmitStartupTimingSummary(
        reason: String,
        contactID: UUID? = nil,
        channelUUID: UUID? = nil,
        channelID: String? = nil,
        metadata extraMetadata: [String: String] = [:]
    ) {
        let resolvedContactID = contactID ?? transmitStartupTiming.contactID
        let resolvedChannelUUID = channelUUID ?? transmitStartupTiming.channelUUID
        let resolvedChannelID = channelID ?? transmitStartupTiming.backendChannelID
        let stages = [
            "press-requested",
            "system-handoff-started",
            "system-handoff-requested",
            "system-transmit-began",
            "system-audio-session-activated",
            "backend-lease-requested",
            "backend-lease-granted",
            "direct-quic-transmit-prepare-requested",
            "direct-quic-transmit-prepare-sent",
            "media-session-start-requested",
            "media-session-start-completed",
            "early-media-session-start-requested",
            "early-media-session-start-completed",
            "audio-capture-start-requested",
            "audio-capture-start-completed",
            "early-audio-capture-start-requested",
            "early-audio-capture-start-completed",
            "first-audio-captured",
            "first-audio-enqueued",
            "first-audio-dispatched",
            "first-audio-delivered",
            "transmit-start-signal-sent",
            "startup-completed",
            "system-transmit-ended",
        ]
        var metadata = extraMetadata
        metadata["reason"] = reason
        metadata["contactId"] = resolvedContactID?.uuidString ?? "none"
        metadata["channelUUID"] = resolvedChannelUUID?.uuidString ?? "none"
        metadata["channelId"] = resolvedChannelID ?? "none"
        metadata["source"] = transmitStartupTiming.source ?? "unknown"
        metadata["totalPressElapsedMs"] = transmitStartupTiming.elapsedMilliseconds().map(String.init) ?? "unknown"
        metadata["applicationState"] = String(describing: currentApplicationState())
        metadata["mediaState"] = String(describing: mediaConnectionState)
        metadata["isPTTAudioSessionActive"] = String(isPTTAudioSessionActive)
        metadata["backendWebSocketConnected"] = String(backendRuntime.isWebSocketConnected)
        if let resolvedContactID {
            metadata["directQuicActive"] = String(shouldUseDirectQuicTransport(for: resolvedContactID))
        }
        for stage in stages {
            if let elapsed = transmitStartupTiming.elapsedMilliseconds(for: stage) {
                metadata["\(stage)Ms"] = String(elapsed)
            }
        }
        if let appleStarted = transmitStartupTiming.elapsedMilliseconds(for: "system-handoff-requested"),
           let appleReady = transmitStartupTiming.elapsedMilliseconds(for: "system-audio-session-activated") {
            metadata["appleActivationDeltaMs"] = String(max(0, appleReady - appleStarted))
        }
        if let backendRequested = transmitStartupTiming.elapsedMilliseconds(for: "backend-lease-requested"),
           let backendGranted = transmitStartupTiming.elapsedMilliseconds(for: "backend-lease-granted") {
            metadata["backendLeaseDeltaMs"] = String(max(0, backendGranted - backendRequested))
        }
        let captureStartCandidates = [
            transmitStartupTiming.elapsedMilliseconds(for: "audio-capture-start-requested"),
            transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-requested"),
        ].compactMap { $0 }
        if let captureRequested = captureStartCandidates.min(),
           let firstCaptured = transmitStartupTiming.elapsedMilliseconds(for: "first-audio-captured") {
            metadata["captureToFirstAudioDeltaMs"] = String(max(0, firstCaptured - captureRequested))
        }
        if let captured = transmitStartupTiming.elapsedMilliseconds(for: "first-audio-captured"),
           let delivered = transmitStartupTiming.elapsedMilliseconds(for: "first-audio-delivered") {
            metadata["firstAudioTransportDeltaMs"] = String(max(0, delivered - captured))
        }
        diagnostics.record(
            .media,
            message: "Transmit startup timing summary",
            metadata: metadata
        )
    }

    func recordWakeReceiveTiming(
        stage: String,
        contactID: UUID,
        channelUUID: UUID? = nil,
        channelID: String? = nil,
        subsystem: DiagnosticsSubsystem = .media,
        metadata extraMetadata: [String: String] = [:],
        ifAbsent: Bool = false
    ) {
        guard pttWakeRuntime.timing.contactID == contactID else { return }
        if ifAbsent {
            pttWakeRuntime.noteTimingStage(stage, for: contactID, ifAbsent: true)
        } else {
            pttWakeRuntime.noteTimingStage(stage, for: contactID)
        }
        let elapsedMilliseconds = pttWakeRuntime.timing.elapsedMilliseconds(for: stage)
        var metadata = extraMetadata
        metadata["stage"] = stage
        metadata["wakeToStageMs"] = elapsedMilliseconds.map(String.init) ?? "unknown"
        metadata["contactId"] = contactID.uuidString
        metadata["channelUUID"] =
            channelUUID?.uuidString
            ?? pttWakeRuntime.timing.channelUUID?.uuidString
            ?? "none"
        metadata["channelId"] = channelID ?? pttWakeRuntime.timing.channelID ?? "none"
        metadata["source"] = pttWakeRuntime.timing.source ?? "unknown"
        metadata["applicationState"] = String(describing: currentApplicationState())
        metadata["mediaState"] = String(describing: mediaConnectionState)
        metadata["incomingWakeActivationState"] =
            pttWakeRuntime.incomingWakeActivationState(for: contactID).map(String.init(describing:)) ?? "none"
        metadata["bufferedAudioChunkCount"] = String(pttWakeRuntime.bufferedAudioChunkCount(for: contactID))
        diagnostics.record(
            subsystem,
            message: "Wake receive timing",
            metadata: metadata
        )
    }

    func recordWakeReceiveTimingForMediaEvent(
        _ message: String,
        metadata: [String: String]
    ) {
        guard let contactID = mediaSessionContactID,
              pttWakeRuntime.timing.contactID == contactID else {
            return
        }
        let stage: String?
        switch message {
        case "Media session start requested":
            stage = "media-session-start-requested"
        case "Media session start completed":
            stage = "media-session-start-completed"
        case "Playback buffer scheduled":
            stage = "first-playback-buffer-scheduled"
        case "Playback engine started":
            stage = "playback-engine-started"
        case "Playback node started":
            stage = metadata["reason"] == "system-activated-playback-prime"
                ? "playback-node-primed"
                : "playback-node-started"
        case "Playback node startup reasserted":
            stage = "playback-node-startup-reasserted"
        default:
            stage = nil
        }
        guard let stage else { return }
        recordWakeReceiveTiming(
            stage: stage,
            contactID: contactID,
            metadata: metadata,
            ifAbsent: stage == "first-playback-buffer-scheduled"
        )
    }

    func recordWakeReceiveTimingSummary(
        reason: String,
        contactID: UUID,
        channelUUID: UUID? = nil,
        channelID: String? = nil,
        metadata extraMetadata: [String: String] = [:]
    ) {
        guard pttWakeRuntime.timing.contactID == contactID else { return }
        let stages = [
            "wake-started",
            "provisional-wake-candidate-created",
            "incoming-push-result-active-participant-returned",
            "incoming-push-confirmed",
            "backend-peer-transmit-prepare-observed",
            "backend-peer-transmit-refresh-observed",
            "backend-peer-transmitting-observed",
            "active-remote-participant-requested",
            "active-remote-participant-completed",
            "active-remote-participant-failed",
            "direct-quic-audio-received",
            "signal-audio-received",
            "first-audio-buffered",
            "latest-audio-buffered",
            "system-audio-activation-observed",
            "media-session-start-requested",
            "media-session-start-completed",
            "playback-engine-started",
            "playback-node-primed",
            "playback-node-started",
            "playback-node-startup-reasserted",
            "buffered-audio-flush-started",
            "first-playback-buffer-scheduled",
            "buffered-audio-flush-completed",
            "app-managed-fallback-started",
            "app-managed-fallback-flush-started",
            "app-managed-fallback-flush-completed",
            "fallback-deferred-until-foreground",
            "system-activation-interrupted-by-transmit-end",
        ]
        var metadata = extraMetadata
        metadata["reason"] = reason
        metadata["contactId"] = contactID.uuidString
        metadata["channelUUID"] =
            channelUUID?.uuidString
            ?? pttWakeRuntime.timing.channelUUID?.uuidString
            ?? "none"
        metadata["channelId"] = channelID ?? pttWakeRuntime.timing.channelID ?? "none"
        metadata["source"] = pttWakeRuntime.timing.source ?? "unknown"
        metadata["totalWakeElapsedMs"] = pttWakeRuntime.timing.elapsedMilliseconds().map(String.init) ?? "unknown"
        metadata["applicationState"] = String(describing: currentApplicationState())
        metadata["mediaState"] = String(describing: mediaConnectionState)
        metadata["incomingWakeActivationState"] =
            pttWakeRuntime.incomingWakeActivationState(for: contactID).map(String.init(describing:)) ?? "none"
        metadata["bufferedAudioChunkCount"] = String(pttWakeRuntime.bufferedAudioChunkCount(for: contactID))
        for stage in stages {
            if let elapsed = pttWakeRuntime.timing.elapsedMilliseconds(for: stage) {
                metadata["\(stage)Ms"] = String(elapsed)
            }
        }
        if let started = pttWakeRuntime.timing.elapsedMilliseconds(for: "wake-started"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["wakeToSystemActivationDeltaMs"] = String(max(0, activated - started))
        }
        if let firstBuffered = pttWakeRuntime.timing.elapsedMilliseconds(for: "first-audio-buffered"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["firstBufferedToSystemActivationDeltaMs"] = String(max(0, activated - firstBuffered))
        }
        if let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed"),
           let playbackScheduled = pttWakeRuntime.timing.elapsedMilliseconds(for: "first-playback-buffer-scheduled") {
            metadata["systemActivationToFirstPlaybackScheduledDeltaMs"] = String(max(0, playbackScheduled - activated))
        }
        if let firstBuffered = pttWakeRuntime.timing.elapsedMilliseconds(for: "first-audio-buffered"),
           let playbackScheduled = pttWakeRuntime.timing.elapsedMilliseconds(for: "first-playback-buffer-scheduled") {
            metadata["firstBufferedToFirstPlaybackScheduledDeltaMs"] = String(max(0, playbackScheduled - firstBuffered))
        }
        if let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["activeParticipantRequestedToDidActivateMs"] = String(activated - requested)
        }
        if let completed = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-completed"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["activeParticipantCompletedToDidActivateMs"] = String(activated - completed)
        }
        let firstAudioReceived = [
            pttWakeRuntime.timing.elapsedMilliseconds(for: "direct-quic-audio-received"),
            pttWakeRuntime.timing.elapsedMilliseconds(for: "signal-audio-received"),
            pttWakeRuntime.timing.elapsedMilliseconds(for: "first-audio-buffered"),
        ]
        .compactMap { $0 }
        .min()
        if let firstAudioReceived,
           let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested") {
            metadata["firstAudioToActiveParticipantRequestedMs"] = String(requested - firstAudioReceived)
        }
        if let backendPeerTransmit = pttWakeRuntime.timing.elapsedMilliseconds(for: "backend-peer-transmitting-observed"),
           let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested") {
            metadata["backendPeerTransmitToActiveParticipantRequestedMs"] = String(requested - backendPeerTransmit)
        }
        if let backendPeerPrepare = pttWakeRuntime.timing.elapsedMilliseconds(for: "backend-peer-transmit-prepare-observed"),
           let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested") {
            metadata["backendPeerPrepareToActiveParticipantRequestedMs"] = String(requested - backendPeerPrepare)
        }
        if let backendPeerRefresh = pttWakeRuntime.timing.elapsedMilliseconds(for: "backend-peer-transmit-refresh-observed"),
           let requested = pttWakeRuntime.timing.elapsedMilliseconds(for: "active-remote-participant-requested") {
            metadata["backendPeerRefreshToActiveParticipantRequestedMs"] = String(requested - backendPeerRefresh)
        }
        if let incomingPushResult = pttWakeRuntime.timing.elapsedMilliseconds(for: "incoming-push-result-active-participant-returned"),
           let activated = pttWakeRuntime.timing.elapsedMilliseconds(for: "system-audio-activation-observed") {
            metadata["incomingPushResultToDidActivateMs"] = String(activated - incomingPushResult)
        }
        diagnostics.record(
            .media,
            message: "Wake receive timing summary",
            metadata: metadata
        )
    }

    func shouldUseAppManagedWakePlaybackFallback(
        applicationState: UIApplication.State
    ) -> Bool {
        applicationState == .active
    }

    func shouldSuspendForegroundMediaForBackgroundTransition(
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            return false
        }
        guard mediaServices.hasSession() else { return false }
        guard let contactID = mediaSessionContactID else { return false }
        guard !isTransmitting else { return false }
        guard !transmitCoordinator.state.isPressingTalk else { return false }
        guard !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) else { return false }
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
            reason: .appBackgroundMediaClosed
        )
        updateStatusForSelectedContact()
    }

    func backgroundTransitionTransportContactIDs() -> Set<UUID> {
        Set([selectedContactId, activeChannelId, mediaSessionContactID].compactMap { $0 })
    }

    func shouldPublishReceiverNotReadyForIdleBackgroundTransition(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            return false
        }
        return !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID)
    }

    @discardableResult
    func retireIdleDirectQuicForBackgroundTransitionImmediately(
        reason: String,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            diagnostics.record(
                .media,
                message: "Preserving Direct QUIC during proximity inactive transition",
                metadata: ["reason": reason]
            )
            return false
        }

        var didUpdateTransport = false
        for contactID in backgroundTransitionTransportContactIDs() {
            guard shouldRetireIdleDirectQuicForBackgroundTransition(
                for: contactID,
                applicationState: applicationState
            ) else { continue }

            didUpdateTransport = retireDirectQuicPathImmediately(
                for: contactID,
                reason: reason,
                sendHangup: true,
                configureActiveRoute: false
            ) || didUpdateTransport
        }

        if didUpdateTransport {
            updateStatusForSelectedContact()
        }
        return didUpdateTransport
    }

    func reconcileIdleTransportForBackgroundTransition(
        reason: String,
        applicationState: UIApplication.State
    ) async {
        guard applicationState != .active else { return }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            diagnostics.record(
                .media,
                message: "Skipped background transport reconciliation during proximity inactive transition",
                metadata: ["reason": reason]
            )
            return
        }

        var didUpdateTransport = false
        for contactID in backgroundTransitionTransportContactIDs() {
            let retired = await retireIdleDirectQuicForBackgroundTransitionIfNeeded(
                for: contactID,
                reason: reason,
                applicationState: applicationState
            )
            didUpdateTransport = didUpdateTransport || retired

            if shouldPublishReceiverNotReadyForIdleBackgroundTransition(
                for: contactID,
                applicationState: applicationState
            ) {
                await syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .appBackgroundMediaClosed
                )
            }
        }

        if didUpdateTransport {
            updateStatusForSelectedContact()
        }
    }

    func desiredLocalReceiverAudioReadiness(for contactID: UUID) -> Bool {
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return false }
        let peerDeviceID =
            channelReadinessByContactID[contactID]?.peerTargetDeviceId
            ?? directQuicPeerDeviceID(for: contactID)
        guard localReceiverMediaEncryptionReadyForLiveMedia(
            contactID: contactID,
            channelID: contact.backendChannelId,
            peerDeviceID: peerDeviceID
        ) else {
            diagnostics.record(
                .media,
                message: "Withholding receiver-ready until media E2EE session is configured",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": contact.backendChannelId ?? "none",
                    "peerDeviceId": peerDeviceID ?? "none",
                    "peerIdentityAdvertised": String(mediaEncryptionIsRequired(for: contactID)),
                ]
            )
            return false
        }

        switch pttWakeRuntime.incomingWakeActivationState(for: contactID) {
        case .systemActivated, .appManagedFallback:
            // Wake-activated receive should publish ready from the actual
            // connected playback session even if the selected-session
            // projection is still polluted by a stale local transmit path.
            return true
        case .signalBuffered,
             .awaitingSystemActivation,
             .systemActivationTimedOutWaitingForForeground,
             .systemActivationInterruptedByTransmitEnd,
             .none:
            break
        }

        let projection = selectedPeerProjection(for: contactID)
        guard projection.durableSession == .connected else { return false }
        guard projection.connectedExecution == nil else { return false }
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

    func syncLocalReceiverAudioReadinessSignal(
        for contactID: UUID,
        reason: ReceiverAudioReadinessReason
    ) async {
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
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else {
            diagnostics.record(
                .media,
                message: "Skipped app-managed foreground audio prewarm before system PTT activation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "applicationState": String(describing: applicationState),
                    "reason": "avoid-ptt-audio-session-contention",
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

    func shouldPrewarmForegroundTalkPath(
        for contactID: UUID,
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
        guard !remoteReceiveBlocksLocalTransmit(for: contactID) else { return false }
        guard let channelSnapshot = selectedChannelSnapshot(for: contactID) else { return false }
        guard channelSnapshot.membership.hasLocalMembership else { return false }
        guard channelSnapshot.canTransmit else { return false }
        return true
    }

    func foregroundTalkPathNeedsPrewarm(for contactID: UUID) -> Bool {
        let mediaNeedsWarmup: Bool = {
            guard foregroundAppManagedInteractiveAudioPrewarmEnabled else {
                return false
            }
            switch localMediaWarmupState(for: contactID) {
            case .cold, .failed:
                return true
            case .prewarming, .ready:
                return false
            }
        }()
        let webSocketNeedsWarmup =
            backendServices?.supportsWebSocket == true
            && backendServices?.isWebSocketConnected != true
        let localReceiverReadinessNeedsPublish =
            desiredLocalReceiverAudioReadiness(for: contactID)
            && channelReadinessByContactID[contactID]?.localAudioReadiness != .ready

        return mediaNeedsWarmup
            || webSocketNeedsWarmup
            || localReceiverReadinessNeedsPublish
            || shouldRequestAutomaticDirectQuicProbe(for: contactID)
    }

    func firstTalkReadiness(for contactID: UUID) -> FirstTalkReadinessProjection {
        let localMediaWarm =
            localMediaWarmupState(for: contactID) == .ready
            || shouldUseDirectQuicTransport(for: contactID)
        let receiverWarm =
            selectedChannelSnapshot(for: contactID)?.remoteAudioReadyForLiveTransmit == true
            || mediaRuntime.receiverPrewarmRequestIsAcknowledged(
                for: contactID,
                maximumAge: TimeInterval(directQuicAudioFreshnessMilliseconds) / 1_000
            )
        let transportWarm = localRelayTransportReadyForTransmit(for: contactID)

        return FirstTalkReadinessProjection(
            localMediaWarm: localMediaWarm,
            receiverWarm: receiverWarm,
            transportWarm: transportWarm
        )
    }

    func firstTalkStartupProfile(
        for contactID: UUID,
        startGraceIfNeeded: Bool = false
    ) -> FirstTalkStartupProfile {
        if shouldUseDirectQuicTransport(for: contactID) {
            if startGraceIfNeeded {
                mediaRuntime.clearFirstTalkDirectQuicGrace(for: contactID)
            }
            return .directQuicWarm
        }

        let relayReadiness = firstTalkReadiness(for: contactID)
        let relayProfile: FirstTalkStartupProfile = relayReadiness.isReady ? .relayWarm : .relayWarming
        guard !relayReadiness.isReady else {
            if startGraceIfNeeded {
                kickDirectQuicFirstTalkWarmupProbeIfNeeded(for: contactID)
            }
            return .relayWarm
        }

        guard let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId else {
            if startGraceIfNeeded {
                mediaRuntime.clearFirstTalkDirectQuicGrace(for: contactID)
            }
            return relayProfile
        }

        let directWarmupBlockReason = directQuicFirstTalkWarmupBlockReason(for: contactID)
        guard directWarmupBlockReason == nil || directWarmupBlockReason == "not-listener-offerer" else {
            if startGraceIfNeeded {
                mediaRuntime.clearFirstTalkDirectQuicGrace(for: contactID)
            }
            return relayProfile
        }

        let existingGrace = mediaRuntime.firstTalkDirectQuicGrace(
            for: contactID,
            channelID: channelID
        )
        if !startGraceIfNeeded {
            guard let existingGrace else { return relayProfile }
            let elapsedMilliseconds = Int(Date().timeIntervalSince(existingGrace.startedAt) * 1_000)
            return !existingGrace.expired && elapsedMilliseconds < directQuicFirstTalkGraceMilliseconds
                ? .directQuicWarming
                : relayProfile
        }
        let grace = mediaRuntime.markFirstTalkDirectQuicGraceStartedIfNeeded(
            for: contactID,
            channelID: channelID
        )
        if existingGrace == nil {
            diagnostics.record(
                .media,
                message: "Started Direct QUIC first-talk grace window",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "graceMs": String(directQuicFirstTalkGraceMilliseconds),
                ]
            )
            kickDirectQuicFirstTalkWarmupProbeIfNeeded(for: contactID)
        }

        let elapsedMilliseconds = Int(Date().timeIntervalSince(grace.startedAt) * 1_000)
        guard !grace.expired,
              elapsedMilliseconds < directQuicFirstTalkGraceMilliseconds else {
            mediaRuntime.expireFirstTalkDirectQuicGrace(
                for: contactID,
                channelID: channelID
            )
            return relayProfile
        }

        scheduleDirectQuicFirstTalkGraceExpirationRefresh(
            for: contactID,
            channelID: channelID,
            remainingMilliseconds: directQuicFirstTalkGraceMilliseconds - elapsedMilliseconds
        )
        return .directQuicWarming
    }

    func kickDirectQuicFirstTalkWarmupProbeIfNeeded(for contactID: UUID) {
        guard shouldRequestAutomaticDirectQuicProbe(for: contactID) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.maybeStartAutomaticDirectQuicProbe(
                for: contactID,
                reason: "first-talk-grace"
            )
        }
    }

    func scheduleDirectQuicFirstTalkGraceExpirationRefresh(
        for contactID: UUID,
        channelID: String,
        remainingMilliseconds: Int
    ) {
        guard !mediaRuntime.hasFirstTalkDirectQuicGraceExpiryTask(for: contactID) else { return }
        let delayMilliseconds = max(remainingMilliseconds, 0)
        mediaRuntime.replaceFirstTalkDirectQuicGraceExpiryTask(
            for: contactID,
            with: Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.mediaRuntime.expireFirstTalkDirectQuicGrace(
                        for: contactID,
                        channelID: channelID
                    )
                    self.diagnostics.record(
                        .media,
                        message: "Direct QUIC first-talk grace expired; allowing relay startup",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "graceMs": String(self.directQuicFirstTalkGraceMilliseconds),
                        ]
                    )
                    self.updateStatusForSelectedContact()
                    self.captureDiagnosticsState("direct-quic:first-talk-grace-expired")
                }
            }
        )
    }

    func prewarmForegroundTalkPathIfNeeded(
        for contactID: UUID,
        reason: String,
        applicationState: UIApplication.State? = nil
    ) async {
        let applicationState = applicationState ?? currentApplicationState()
        guard shouldPrewarmForegroundTalkPath(
            for: contactID,
            applicationState: applicationState
        ) else { return }
        guard foregroundTalkPathNeedsPrewarm(for: contactID) else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelID = contact.backendChannelId else {
            return
        }

        diagnostics.record(
            .media,
            message: "Prewarming foreground talk path",
            metadata: [
                "contactId": contactID.uuidString,
                "handle": contact.handle,
                "channelId": backendChannelID,
                "reason": reason,
                "localMediaWarmupState": String(describing: localMediaWarmupState(for: contactID)),
                "appManagedAudioPrewarmEnabled": String(foregroundAppManagedInteractiveAudioPrewarmEnabled),
                "webSocketConnected": String(backendServices?.isWebSocketConnected == true),
                "directQuicActive": String(shouldUseDirectQuicTransport(for: contactID)),
            ]
        )

        if let backend = backendServices {
            resumeWebSocketBeforePTTTransportWaitIfNeeded(
                backend,
                contactID: contactID,
                channelID: backendChannelID,
                reason: "foreground-talk-prewarm-\(reason)"
            )
        }
        if foregroundAppManagedInteractiveAudioPrewarmEnabled {
            await prewarmLocalMediaIfNeeded(for: contactID, applicationState: applicationState)
        }
        await syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: .foregroundTalkPrewarm(reason)
        )
        await maybeStartAutomaticDirectQuicProbe(
            for: contactID,
            reason: "foreground-talk-prewarm-\(reason)"
        )
        await requestReceiverPrewarmForFirstTalk(
            for: contactID,
            reason: "foreground-talk-prewarm-\(reason)"
        )
        updateStatusForSelectedContact()
    }

    func shouldClosePrewarmedMediaBeforeSystemTransmit(for contactID: UUID) -> Bool {
        guard mediaServices.hasSession() else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard !isPTTAudioSessionActive else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        if directQuicTransmitStartupPolicy == .appleGated,
           shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID) {
            return true
        }
        guard !shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID) else {
            return false
        }

        switch mediaConnectionState {
        case .connected, .preparing:
            return true
        case .idle, .failed, .closed:
            return false
        }
    }

    func shouldDeactivatePrewarmedAudioSessionBeforeSystemTransmit(for contactID: UUID) -> Bool {
        directQuicTransmitStartupPolicy == .appleGated
            && shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID)
    }

    func shouldBridgePrewarmedDirectMediaDuringSystemTransmit(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return false }
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else { return false }
        guard mediaServices.hasSession() else { return false }
        guard mediaSessionContactID == contactID else { return false }
        guard mediaConnectionState == .connected else { return false }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return false }
        guard shouldUseDirectQuicTransport(for: contactID) else { return false }
        return true
    }

    func shouldUseForegroundWarmDirectTransmit(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        shouldBridgePrewarmedDirectMediaDuringSystemTransmit(
            for: contactID,
            applicationState: applicationState
        )
    }

    func shouldUseForegroundDirectQuicControlPath(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return false }
        guard isJoined, activeChannelId == contactID else { return false }
        return shouldUseDirectQuicTransport(for: contactID)
    }

    func shouldUseSpeculativeForegroundWarmDirectTransmit(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        guard directQuicTransmitStartupPolicy == .speculativeForeground else { return false }
        return shouldUseForegroundWarmDirectTransmit(
            for: contactID,
            applicationState: applicationState
        )
    }

    func isBackendLeaseBypassedTransmitTarget(_ target: TransmitTarget) -> Bool {
        directQuicBackendLeaseBypassedContactIDs.contains(target.contactID)
    }

    func directQuicBackendLeaseBypassedRequest(for contactID: UUID) -> TransmitRequestContext? {
        directQuicBackendLeaseBypassedRequestsByContactID[contactID]
    }

    func directQuicBackendLeaseBypassTarget(
        for request: TransmitRequestContext,
        reason: String
    ) -> TransmitTarget? {
        guard !request.usesLocalHTTPBackend else { return nil }
        guard shouldUseDirectQuicTransport(for: request.contactID) else { return nil }
        return provisionalDirectQuicTransmitTarget(
            for: request,
            reason: reason
        )
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
        guard foregroundAppManagedInteractiveAudioPrewarmEnabled else {
            diagnostics.record(
                .media,
                message: "Skipped app-managed interactive audio prewarm after app activation",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                ]
            )
            return
        }

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

    func shouldTreatTransmitStopCleanupAsAlreadyComplete(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        switch message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "not a channel member", "no active transmit state for sender":
            return true
        default:
            return false
        }
    }

    func shouldPreserveLocalTransmitState(
        selectedContactID: UUID?,
        refreshedContactID: UUID,
        backendChannelStatus: String,
        transmitSnapshot: TransmitDomainSnapshot
    ) -> Bool {
        guard selectedContactID == refreshedContactID else { return false }
        if transmitSnapshot.isSystemTransmitting {
            return true
        }
        if transmitSnapshot.activeContactID == refreshedContactID,
           transmitSnapshot.isPressActive {
            return true
        }
        if backendChannelStatus == ConversationState.transmitting.rawValue {
            if transmitSnapshot.isStopping(for: refreshedContactID) {
                return true
            }
            return !transmitSnapshot.explicitStopRequested
        }

        switch transmitSnapshot.phase {
        case .idle:
            return false
        case .requesting(let contactID), .active(let contactID), .stopping(let contactID):
            return contactID == refreshedContactID
        }
    }

    func shouldAcceptBackendLocalTransmitProjection(
        backendShowsLocalTransmit: Bool,
        transmitSnapshot: TransmitDomainSnapshot
    ) -> Bool {
        backendShowsLocalTransmit && !transmitSnapshot.explicitStopRequested
    }

    func hasActiveTransmitPressIntent() -> Bool {
        !transmitRuntime.explicitStopRequested
            && (transmitRuntime.isPressingTalk || transmitCoordinator.state.isPressingTalk)
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
        guard !remoteReceiveBlocksLocalTransmit(for: contact.id) else {
            diagnostics.record(
                .media,
                message: "Ignored begin transmit request",
                metadata: ["reason": "peer-receive-still-draining", "contact": contact.handle]
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
        sendTelemetryEvent(
            eventName: "ios.transmit.begin_requested",
            severity: .notice,
            reason: "hold-to-talk",
            message: "Begin transmit requested",
            metadata: [
                "contact": contact.handle,
                "backendChannelId": contact.backendChannelId ?? "none",
                "usesLocalHTTPBackend": String(usesLocalHTTPBackend),
            ],
            peerHandle: contact.handle,
            channelId: contact.backendChannelId
        )
        let request = TransmitRequestContext(
            contactID: contact.id,
            contactHandle: contact.handle,
            backendChannelID: backendChannelId,
            remoteUserID: remoteUserID,
            channelUUID: channelUUID(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend,
            backendSupportsWebSocket: backend.supportsWebSocket
        )
        startTransmitStartupTiming(for: request, source: "hold-to-talk")
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
        source: String,
        origin: SystemTransmitBeginOrigin
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
                    "origin": origin.rawValue,
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
                "origin": origin.rawValue,
            ]
        )
        if selectedContactId == nil {
            selectedContactId = request.contactID
        }
        startTransmitStartupTiming(for: request, source: "system-originated-\(origin.rawValue)")
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

    @discardableResult
    func cancelActiveTransmitForLifecycleInterruption(reason: String) -> Bool {
        let hasPendingOrActiveTransmit =
            transmitCoordinator.state.isPressingTalk
            || transmitRuntime.isPressingTalk
            || hasPendingBeginOrActiveTransmit
            || isTransmitting
        guard hasPendingOrActiveTransmit else { return false }

        diagnostics.record(
            .media,
            message: "Cancelling active transmit for lifecycle interruption",
            metadata: [
                "reason": reason,
                "isTransmitting": String(isTransmitting),
                "runtimePressing": String(transmitRuntime.isPressingTalk),
                "coordinatorPressing": String(transmitCoordinator.state.isPressingTalk),
                "coordinatorPhase": String(describing: transmitCoordinator.state.phase),
            ]
        )
        endTransmit(reason: reason)
        return true
    }

    func endTransmit(reason: String = "release") {
        transmitRuntime.noteTouchReleased()
        guard isJoined else { return }
        let hasPendingOrActiveTransmit =
            transmitCoordinator.state.isPressingTalk
            || transmitRuntime.isPressingTalk
            || hasPendingBeginOrActiveTransmit
            || isTransmitting
        guard hasPendingOrActiveTransmit else { return }
        diagnostics.record(.media, message: "End transmit requested", metadata: ["reason": reason])
        sendTelemetryEvent(
            eventName: "ios.transmit.end_requested",
            severity: .notice,
            reason: reason,
            message: "End transmit requested",
            metadata: ["reason": reason]
        )
        // Clear the local press latch immediately so a system-end callback racing
        // with release does not look like an unexpected end that should be retried.
        let pendingWarmDirectRequest = transmitCoordinator.state.pendingRequest
        sendForegroundWarmDirectTransmitStopIfNeeded(
            for: pendingWarmDirectRequest,
            reason: reason
        )
        if let activeTarget = transmitCoordinator.state.activeTarget ?? transmitRuntime.activeTarget {
            sendForegroundWarmDirectTransmitStopIfNeeded(
                target: activeTarget,
                reason: "\(reason)-active-target"
            )
        }
        transmitRuntime.markExplicitStopRequested()
        transmitRuntime.markPressEnded()
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        let systemChannelUUID =
            transmitCoordinator.state.pendingRequest?.channelUUID
            ?? transmitCoordinator.state.activeTarget.flatMap { channelUUID(for: $0.contactID) }
            ?? transmitRuntime.activeTarget.flatMap { channelUUID(for: $0.contactID) }
            ?? activeChannelId.flatMap { channelUUID(for: $0) }
        cancelRequestedSystemTransmitHandoffIfNeeded(
            channelUUID: systemChannelUUID,
            reason: reason
        )
        transmitTaskCoordinator.send(.cancelBegin)
        syncTransmitState()
        Task {
            await transmitCoordinator.handle(.releaseRequested)
            syncTransmitState()
            updateStatusForSelectedContact()
        }
    }

    private func sendForegroundWarmDirectTransmitStopIfNeeded(
        for request: TransmitRequestContext?,
        reason: String
    ) {
        guard let request else { return }
        guard shouldUseForegroundDirectQuicControlPath(for: request.contactID) else { return }
        guard let backend = backendServices, backend.supportsWebSocket, backend.isWebSocketConnected else {
            return
        }
        guard let target = provisionalDirectQuicTransmitTarget(
            for: request,
            reason: "foreground-warm-direct-stop-\(reason)"
        ) else {
            return
        }

        diagnostics.record(
            .media,
            message: "Sending foreground warm Direct QUIC transmit stop before backend grant",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "targetDeviceId": target.deviceID,
                "reason": reason,
            ]
        )
        Task { [weak self] in
            guard let self else { return }
            try? await self.mediaServices.session()?.stopSendingAudio()
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

    private func sendForegroundWarmDirectTransmitStopIfNeeded(
        target: TransmitTarget,
        reason: String
    ) {
        guard isBackendLeaseBypassedTransmitTarget(target) else { return }
        guard shouldUseForegroundDirectQuicControlPath(for: target.contactID) else { return }
        guard let backend = backendServices, backend.supportsWebSocket, backend.isWebSocketConnected else {
            return
        }

        diagnostics.record(
            .media,
            message: "Sending foreground warm Direct QUIC transmit stop on release",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "targetDeviceId": target.deviceID,
                "reason": reason,
            ]
        )
        Task { [weak self] in
            guard let self else { return }
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
            try? await self.mediaServices.session()?.stopSendingAudio()
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
        resumeWebSocketBeforePTTTransportWaitIfNeeded(
            backend,
            contactID: contactID,
            channelID: channelID,
            reason: "system-transmit-activation"
        )
        guard applicationState != .active else { return }
        guard backend.isWebSocketConnected else {
            diagnostics.record(
                .websocket,
                message: "Allowing background WebSocket reconnect to continue for system-originated transmit activation",
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
            message: "Preserving active WebSocket during system-originated transmit activation",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "applicationState": String(describing: applicationState),
            ]
        )
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
            recordTransmitStartupTiming(
                stage: "begin-work-started",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID
            )
            if request.backendSupportsWebSocket {
                recordTransmitStartupTiming(
                    stage: "websocket-resume-requested",
                    contactID: request.contactID,
                    channelUUID: request.channelUUID,
                    channelID: request.backendChannelID,
                    subsystem: .websocket
                )
                resumeWebSocketBeforePTTTransportWaitIfNeeded(
                    backend,
                    contactID: request.contactID,
                    channelID: request.backendChannelID,
                    reason: "begin-transmit"
                )
            }
            try await requestSystemTransmitHandoffIfNeeded(for: request)
            if await reassertBackendJoinAfterWakeIfNeeded(for: request.contactID) {
                await refreshChannelState(for: request.contactID)
            }
            if let target = directQuicBackendLeaseBypassTarget(
                for: request,
                reason: "begin-transmit-lease-bypass"
            ) {
                diagnostics.record(
                    .media,
                    message: "Bypassing backend transmit lease for warm Direct QUIC",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelId": request.backendChannelID,
                        "targetDeviceId": target.deviceID,
                        "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                    ]
                )
                recordTransmitStartupTiming(
                    stage: "backend-lease-bypassed-direct-quic",
                    contactID: request.contactID,
                    channelUUID: request.channelUUID,
                    channelID: request.backendChannelID,
                    metadata: [
                        "targetDeviceId": target.deviceID,
                        "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                    ]
                )
                guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                    diagnostics.record(
                        .media,
                        message: "Direct QUIC transmit target resolved after release; skipping activation",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "targetDeviceId": target.deviceID,
                        ]
                    )
                    return
                }
                directQuicBackendLeaseBypassedContactIDs.insert(target.contactID)
                directQuicBackendLeaseBypassedRequestsByContactID[target.contactID] = request
                transmitRuntime.syncActiveTarget(target)
                configureOutgoingAudioRoute(target: target)
                await transmitCoordinator.handle(.beginSucceeded(target, request))
                syncTransmitState()
                await completeDeferredSystemTransmitActivationIfReady(
                    request: request,
                    target: target
                )
                return
            }
            // `beginTransmit` is an HTTP control-plane call that acquires the
            // transmit lease and triggers APNs wake. Do not block that on
            // websocket readiness, which can take several seconds on a cold
            // background path. The later activation step still waits for the
            // websocket before live audio signaling starts.
            recordTransmitStartupTiming(
                stage: "backend-lease-requested",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID
            )
            let backendLeaseRequestStartedAt = Date()
            let response = try await backend.beginTransmit(channelId: request.backendChannelID)
            let backendLeaseRequestElapsedMs = Int(Date().timeIntervalSince(backendLeaseRequestStartedAt) * 1_000)
            let target = TransmitTarget(
                contactID: request.contactID,
                userID: request.remoteUserID,
                deviceID: response.targetDeviceId,
                channelID: request.backendChannelID,
                transmitID: response.transmitId ?? response.startedAt
            )
            diagnostics.record(
                .media,
                message: "Backend transmit lease granted",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "startedAt": response.startedAt,
                    "transmitId": target.transmitID ?? "missing",
                    "expiresAt": response.expiresAt,
                    "targetDeviceId": response.targetDeviceId,
                    "clientHttpElapsedMs": String(backendLeaseRequestElapsedMs),
                ]
            )
            recordTransmitStartupTiming(
                stage: "backend-lease-granted",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID,
                metadata: [
                    "targetDeviceId": response.targetDeviceId,
                    "startedAt": response.startedAt,
                    "transmitId": target.transmitID ?? "missing",
                    "expiresAt": response.expiresAt,
                    "clientHttpElapsedMs": String(backendLeaseRequestElapsedMs),
                ]
            )
            sendTelemetryEvent(
                eventName: "ios.transmit.backend_granted",
                severity: .notice,
                reason: "begin-transmit",
                message: "Backend transmit lease granted",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "startedAt": response.startedAt,
                    "transmitId": target.transmitID ?? "missing",
                    "expiresAt": response.expiresAt,
                    "targetDeviceId": response.targetDeviceId,
                    "clientHttpElapsedMs": String(backendLeaseRequestElapsedMs),
                ],
                peerHandle: request.contactHandle,
                channelId: target.channelID
            )
            guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                await cleanupBackendTransmitLeaseGrantedAfterRelease(
                    target: target,
                    backend: backend,
                    source: "begin-transmit"
                )
                return
            }
            let usableTarget = try await refreshBackendTransmitLeaseBeforeActivationIfNeeded(
                response: response,
                target: target,
                request: request,
                backend: backend,
                source: "begin-transmit"
            )
            guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                await cleanupBackendTransmitLeaseGrantedAfterRelease(
                    target: usableTarget,
                    backend: backend,
                    source: "begin-transmit-post-renew"
                )
                return
            }
            transmitRuntime.syncActiveTarget(usableTarget)
            configureOutgoingAudioRoute(target: usableTarget)
            recordTransmitStartupTiming(
                stage: "audio-route-configured-after-lease",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID
            )
            // The backend lease starts as soon as beginTransmit succeeds.
            // Keep it alive from that point, not from later PTT activation
            // callbacks, which can land seconds later on a cold wake path.
            diagnostics.record(
                .media,
                message: "Starting transmit lease renewal after backend grant",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "source": "begin-transmit",
                ]
            )
            startRenewingTransmit(usableTarget)
            await transmitCoordinator.handle(.beginSucceeded(usableTarget, request))
            syncTransmitState()
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: usableTarget
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
                if await recoverTransmitBeginMembershipLoss(
                    request: request,
                    backend: backend,
                    workID: workID
                ) {
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
        backend: BackendServices,
        workID: Int
    ) async -> Bool {
        do {
            _ = try await backend.joinChannel(channelId: request.backendChannelID)
            let response = try await backend.beginTransmit(channelId: request.backendChannelID)
            let target = TransmitTarget(
                contactID: request.contactID,
                userID: request.remoteUserID,
                deviceID: response.targetDeviceId,
                channelID: request.backendChannelID,
                transmitID: response.transmitId ?? response.startedAt
            )
            diagnostics.record(
                .media,
                message: "Backend transmit lease granted",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "startedAt": response.startedAt,
                    "transmitId": target.transmitID ?? "missing",
                    "expiresAt": response.expiresAt,
                    "targetDeviceId": response.targetDeviceId,
                ]
            )
            guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                await cleanupBackendTransmitLeaseGrantedAfterRelease(
                    target: target,
                    backend: backend,
                    source: "membership-recovery"
                )
                return true
            }
            let usableTarget = try await refreshBackendTransmitLeaseBeforeActivationIfNeeded(
                response: response,
                target: target,
                request: request,
                backend: backend,
                source: "membership-recovery"
            )
            guard shouldActivateBackendTransmitLease(request: request, workID: workID) else {
                await cleanupBackendTransmitLeaseGrantedAfterRelease(
                    target: usableTarget,
                    backend: backend,
                    source: "membership-recovery-post-renew"
                )
                return true
            }
            transmitRuntime.syncActiveTarget(usableTarget)
            diagnostics.record(
                .media,
                message: "Starting transmit lease renewal after recovered backend grant",
                metadata: [
                    "contactId": usableTarget.contactID.uuidString,
                    "channelId": usableTarget.channelID,
                    "source": "membership-recovery",
                ]
            )
            startRenewingTransmit(usableTarget)
            diagnostics.record(
                .media,
                message: "Recovered transmit membership drift",
                metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID]
            )
            await transmitCoordinator.handle(.beginSucceeded(usableTarget, request))
            syncTransmitState()
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: usableTarget
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

    func shouldActivateBackendTransmitLease(
        request: TransmitRequestContext,
        workID: Int
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        if let runningRequest = transmitTaskCoordinator.state.begin.request,
           runningRequest != request {
            return false
        }
        guard !transmitRuntime.explicitStopRequested else { return false }
        let hasMatchingSystemHandoff =
            request.channelUUID.map {
                transmitRuntime.isSystemTransmitBeginPending(channelUUID: $0)
                || (
                    pttCoordinator.state.isTransmitting
                    && pttCoordinator.state.systemChannelUUID == $0
                )
            } ?? false
        guard transmitRuntime.isPressingTalk || hasMatchingSystemHandoff else { return false }
        guard transmitCoordinator.state.isPressingTalk || hasMatchingSystemHandoff else { return false }
        guard transmitCoordinator.state.pendingRequest == request else { return false }
        return true
    }

    func parsedBackendInstant(_ text: String) -> Date? {
        guard text.hasSuffix("Z") else { return nil }
        let withoutZone = String(text.dropLast())
        let parts = withoutZone.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let baseText = String(parts[0]) + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let baseDate = formatter.date(from: baseText) else { return nil }
        guard parts.count == 2 else { return baseDate }

        let fractionalDigits = parts[1].prefix { $0 >= "0" && $0 <= "9" }
        guard !fractionalDigits.isEmpty else { return baseDate }
        let scale = pow(10.0, Double(fractionalDigits.count))
        let fractionalSeconds = (Double(fractionalDigits) ?? 0) / scale
        return baseDate.addingTimeInterval(fractionalSeconds)
    }

    func backendTransmitLeaseRemainingSeconds(
        expiresAt: String,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let expiration = parsedBackendInstant(expiresAt) else { return nil }
        return expiration.timeIntervalSince(now)
    }

    func backendTransmitLeaseNeedsImmediateRenewal(
        expiresAt: String,
        now: Date = Date()
    ) -> Bool {
        guard let remaining = backendTransmitLeaseRemainingSeconds(expiresAt: expiresAt, now: now) else {
            return false
        }
        return remaining < minimumUsableBackendTransmitLeaseSeconds
    }

    private func refreshBackendTransmitLeaseBeforeActivationIfNeeded(
        response: TurboBeginTransmitResponse,
        target: TransmitTarget,
        request: TransmitRequestContext,
        backend: BackendServices,
        source: String
    ) async throws -> TransmitTarget {
        guard let remainingSeconds = backendTransmitLeaseRemainingSeconds(expiresAt: response.expiresAt) else {
            diagnostics.record(
                .media,
                level: .notice,
                message: "Could not parse backend transmit lease expiration",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "expiresAt": response.expiresAt,
                    "source": source,
                ]
            )
            return target
        }
        guard remainingSeconds < minimumUsableBackendTransmitLeaseSeconds else { return target }

        let remainingMilliseconds = Int(remainingSeconds * 1_000)
        diagnostics.record(
            .media,
            level: .notice,
            message: "Backend transmit lease grant had low remaining lifetime; renewing before activation",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "targetDeviceId": target.deviceID,
                "startedAt": response.startedAt,
                "expiresAt": response.expiresAt,
                "remainingMs": String(remainingMilliseconds),
                "minimumUsableMs": String(Int(minimumUsableBackendTransmitLeaseSeconds * 1_000)),
                "source": source,
            ]
        )
        recordTransmitStartupTiming(
            stage: "backend-lease-immediate-renew-requested",
            contactID: request.contactID,
            channelUUID: request.channelUUID,
            channelID: request.backendChannelID,
            metadata: [
                "targetDeviceId": target.deviceID,
                "remainingMs": String(remainingMilliseconds),
                "source": source,
            ]
        )

        let renewStartedAt = Date()
        do {
            let renewed = try await backend.renewTransmit(
                channelId: target.channelID,
                transmitId: target.transmitID
            )
            let renewDurationMs = Int(Date().timeIntervalSince(renewStartedAt) * 1_000)
            diagnostics.record(
                .media,
                message: "Backend transmit lease renewed before activation",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "targetDeviceId": target.deviceID,
                    "startedAt": renewed.startedAt,
                    "transmitId": renewed.transmitId ?? target.transmitID ?? "missing",
                    "expiresAt": renewed.expiresAt,
                    "renewDurationMs": String(renewDurationMs),
                    "source": source,
                ]
            )
            recordTransmitStartupTiming(
                stage: "backend-lease-immediate-renewed",
                contactID: request.contactID,
                channelUUID: request.channelUUID,
                channelID: request.backendChannelID,
                metadata: [
                    "targetDeviceId": target.deviceID,
                    "expiresAt": renewed.expiresAt,
                    "renewDurationMs": String(renewDurationMs),
                    "source": source,
                ]
            )
            return TransmitTarget(
                contactID: target.contactID,
                userID: target.userID,
                deviceID: target.deviceID,
                channelID: target.channelID,
                transmitID: renewed.transmitId ?? target.transmitID
            )
        } catch {
            guard shouldTreatTransmitLeaseLossAsStop(error) else { throw error }

            diagnostics.record(
                .media,
                level: .notice,
                message: "Backend transmit lease expired before activation; reacquiring",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "targetDeviceId": target.deviceID,
                    "remainingMs": String(remainingMilliseconds),
                    "error": error.localizedDescription,
                    "source": source,
                ]
            )
            let reacquired = try await backend.beginTransmit(channelId: request.backendChannelID)
            return TransmitTarget(
                contactID: request.contactID,
                userID: request.remoteUserID,
                deviceID: reacquired.targetDeviceId,
                channelID: request.backendChannelID,
                transmitID: reacquired.transmitId ?? reacquired.startedAt
            )
        }
    }

    private func cleanupBackendTransmitLeaseGrantedAfterRelease(
        target: TransmitTarget,
        backend: BackendServices,
        source: String
    ) async {
        guard !transmitRuntime.isPressingTalk || transmitRuntime.explicitStopRequested else {
            diagnostics.record(
                .media,
                message: "Ignoring stale backend transmit lease while another press is active",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "source": source,
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Backend transmit lease granted after release; ending without activating",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "source": source,
            ]
        )
        transmitTaskCoordinator.send(.renewalCancelled)
        transmitTaskRuntime.cancelCaptureReassertionTask()
        try? await mediaServices.session()?.stopSendingAudio()
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
        _ = try? await backend.endTransmit(channelId: target.channelID, transmitId: target.transmitID)
        await refreshChannelState(for: target.contactID)
        updateStatusForSelectedContact()
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
                await transmitCoordinator.handle(.stopFailed(target, message))
                syncTransmitState()
                return
            }
            if isBackendLeaseBypassedTransmitTarget(target) {
                configureOutgoingAudioRoute(target: target)
                diagnostics.record(
                    .media,
                    message: "Activating Direct QUIC transmit without backend lease renewal",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "targetDeviceId": target.deviceID,
                        "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                    ]
                )
                if directQuicTransmitStartupPolicy == .speculativeForeground {
                    await startPrewarmedDirectSystemTransmitBridgeIfPossible(
                        request: request,
                        target: target,
                        trigger: "direct-quic-lease-bypassed"
                    )
                }
                await completeDeferredSystemTransmitActivationIfReady(
                    request: request,
                    target: target
                )
                await refreshChannelState(for: request.contactID)
                return
            }
            // Keep the backend transmit lease alive during the cold PTT
            // activation window instead of waiting for later audio-session
            // callbacks, which can arrive after the initial lease expires.
            startRenewingTransmit(target)
            await startPrewarmedDirectSystemTransmitBridgeIfPossible(
                request: request,
                target: target,
                trigger: "backend-lease-granted"
            )
            await completeDeferredSystemTransmitActivationIfReady(
                request: request,
                target: target
            )
        }

        await refreshChannelState(for: request.contactID)
    }

    private func requestSystemTransmitHandoffIfNeeded(
        for request: TransmitRequestContext
    ) async throws {
        guard !request.usesLocalHTTPBackend else { return }
        guard let channelUUID = request.channelUUID else { return }
        recordTransmitStartupTiming(
            stage: "direct-quic-transmit-prepare-requested",
            contactID: request.contactID,
            channelUUID: channelUUID,
            channelID: request.backendChannelID,
            subsystem: .media
        )
        let didSendDirectQuicTransmitPrepare = await sendDirectQuicReceiverTransmitPrepareIfPossible(
            for: request.contactID,
            reason: "system-transmit-handoff",
            sendWarmPing: false
        )
        if didSendDirectQuicTransmitPrepare {
            recordTransmitStartupTiming(
                stage: "direct-quic-transmit-prepare-sent",
                contactID: request.contactID,
                channelUUID: channelUUID,
                channelID: request.backendChannelID,
                subsystem: .media
            )
            Task { @MainActor [weak self] in
                await self?.sendDirectQuicWarmPingIfPossible(
                    for: request.contactID,
                    reason: "transmit-system-transmit-handoff"
                )
            }
        }
        guard !pttCoordinator.state.isTransmitting || pttCoordinator.state.systemChannelUUID != channelUUID else { return }
        guard !transmitRuntime.isSystemTransmitBeginPending(channelUUID: channelUUID) else { return }

        recordTransmitStartupTiming(
            stage: "system-handoff-started",
            contactID: request.contactID,
            channelUUID: channelUUID,
            channelID: request.backendChannelID,
            subsystem: .pushToTalk
        )
        await clearSystemRemoteParticipantBeforeLocalTransmit(
            contactID: request.contactID,
            channelUUID: channelUUID,
            reason: "before-system-transmit-handoff",
            timeoutNanoseconds: remoteParticipantClearBeforeTransmitTimeoutNanoseconds
        )

        let usesSpeculativeForegroundWarmDirectTransmit =
            shouldUseSpeculativeForegroundWarmDirectTransmit(for: request.contactID)
        if usesSpeculativeForegroundWarmDirectTransmit {
            diagnostics.record(
                .media,
                message: "Preparing foreground warm Direct QUIC transmit alongside system handoff",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "mediaState": String(describing: mediaConnectionState),
                    "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                ]
            )
            configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
                for: request,
                reason: "foreground-warm-direct-transmit"
            )
        } else if shouldClosePrewarmedMediaBeforeSystemTransmit(for: request.contactID) {
            let deactivateAudioSession =
                shouldDeactivatePrewarmedAudioSessionBeforeSystemTransmit(for: request.contactID)
            diagnostics.record(
                .media,
                message: "Closing app-managed media session before system transmit handoff",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "mediaState": String(describing: mediaConnectionState),
                    "deactivateAudioSession": String(deactivateAudioSession),
                    "preserveDirectQuic": String(shouldUseDirectQuicTransport(for: request.contactID)),
                    "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                ]
            )
            closeMediaSession(
                deactivateAudioSession: deactivateAudioSession,
                preserveDirectQuic: shouldUseDirectQuicTransport(for: request.contactID)
            )
            recordTransmitStartupTiming(
                stage: "prewarmed-media-closed",
                contactID: request.contactID,
                channelUUID: channelUUID,
                channelID: request.backendChannelID
            )
            configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
                for: request,
                reason: "after-prewarmed-media-close"
            )
        } else if shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: request.contactID) {
            diagnostics.record(
                .media,
                message: "Preserving prewarmed Direct QUIC media session for system transmit bridge",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "mediaState": String(describing: mediaConnectionState),
                ]
            )
            recordTransmitStartupTiming(
                stage: "prewarmed-media-preserved",
                contactID: request.contactID,
                channelUUID: channelUUID,
                channelID: request.backendChannelID,
                metadata: [
                    "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                    "bridge": "prewarmed-direct",
                ]
            )
            configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
                for: request,
                reason: "prewarmed-media-preserved"
            )
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
            recordTransmitStartupTiming(
                stage: "system-handoff-requested",
                contactID: request.contactID,
                channelUUID: channelUUID,
                channelID: request.backendChannelID,
                subsystem: .pushToTalk
            )
            if usesSpeculativeForegroundWarmDirectTransmit {
                diagnostics.record(
                    .media,
                    message: "Starting foreground warm Direct QUIC audio after system handoff request",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                    ]
                )
                Task { @MainActor [weak self] in
                    await self?.startPrewarmedDirectSystemTransmitBridgeIfPossible(
                        request: request,
                        trigger: "system-handoff-requested"
                    )
                    self?.schedulePreActivationDirectCaptureReassertion(
                        request: request,
                        trigger: "system-handoff-requested"
                    )
                }
            }
        } catch {
            transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
            throw error
        }
    }

    func schedulePreActivationDirectCaptureReassertion(
        request: TransmitRequestContext,
        trigger: String
    ) {
        guard shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: request.contactID) else { return }
        transmitTaskRuntime.replaceCaptureReassertionTask(
            with: Task { @MainActor [weak self] in
                let delays: [UInt64] = [
                    250_000_000,
                    650_000_000,
                    1_250_000_000,
                    2_000_000_000,
                ]
                for (index, delay) in delays.enumerated() {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled, let self else { return }
                    guard !self.isPTTAudioSessionActive else { return }
                    guard self.shouldContinuePendingSystemTransmitAudioCapture(
                        request: request,
                        stage: "pre-activation-capture-reassertion-\(index + 1)"
                    ) else { return }
                    self.diagnostics.record(
                        .media,
                        message: "Reasserting prewarmed Direct QUIC capture during PTT handoff",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "channelId": request.backendChannelID,
                            "attempt": String(index + 1),
                            "trigger": trigger,
                        ]
                    )
                    await self.startPrewarmedDirectSystemTransmitBridgeIfPossible(
                        request: request,
                        trigger: "pre-activation-capture-reassertion-\(index + 1)"
                    )
                }
            }
        )
    }

    @discardableResult
    func clearSystemRemoteParticipantBeforeLocalTransmit(
        contactID: UUID,
        channelUUID: UUID,
        reason: String,
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        let startedAt = Date()
        let clearResult: Result<Void, Error>?

        if let timeoutNanoseconds {
            let resultBox = RemoteParticipantClearResultBox()
            Task { @MainActor [weak self] in
                guard let self else {
                    await resultBox.resolve(.failure(PTTSystemClientError.notReady))
                    return
                }
                do {
                    try await self.setSystemActiveRemoteParticipant(
                        name: nil,
                        channelUUID: channelUUID,
                        contactID: contactID,
                        reason: reason
                    )
                    await resultBox.resolve(.success(()))
                } catch {
                    await resultBox.resolve(.failure(error))
                }
            }

            let pollNanoseconds: UInt64 = 10_000_000
            let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
            var resolvedResult: Result<Void, Error>?
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let result = await resultBox.currentResult() {
                    resolvedResult = result
                    break
                }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { break }
                let remaining = deadline - now
                try? await Task.sleep(nanoseconds: min(pollNanoseconds, remaining))
            }
            if let resolvedResult {
                clearResult = resolvedResult
            } else {
                clearResult = await resultBox.currentResult()
            }
        } else {
            do {
                try await setSystemActiveRemoteParticipant(
                    name: nil,
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: reason
                )
                clearResult = .success(())
            } catch {
                clearResult = .failure(error)
            }
        }

        guard let clearResult else {
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            diagnostics.record(
                .pushToTalk,
                message: "Timed out clearing active remote participant before local transmit",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                    "timeoutMs": String((timeoutNanoseconds ?? 0) / 1_000_000),
                ]
            )
            recordTransmitStartupTiming(
                stage: "remote-participant-clear-timed-out",
                contactID: contactID,
                channelUUID: channelUUID,
                subsystem: .pushToTalk,
                metadata: [
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                    "timeoutMs": String((timeoutNanoseconds ?? 0) / 1_000_000),
                ]
            )
            return false
        }

        switch clearResult {
        case .success:
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            diagnostics.record(
                .pushToTalk,
                message: "Cleared active remote participant before local transmit",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                ]
            )
            recordTransmitStartupTiming(
                stage: "remote-participant-clear-completed",
                contactID: contactID,
                channelUUID: channelUUID,
                subsystem: .pushToTalk,
                metadata: [
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                ]
            )
            return true

        case .failure(let error):
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            if isExpectedPTTRemoteParticipantClearFailure(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Skipped remote participant clear because no active remote participant was present",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                        "durationMs": String(durationMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                recordTransmitStartupTiming(
                    stage: "remote-participant-clear-not-needed",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    subsystem: .pushToTalk,
                    metadata: [
                        "reason": reason,
                        "durationMs": String(durationMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                return true
            }
            if isRecoverablePTTChannelUnavailable(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Skipped remote participant clear for unavailable system channel",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                        "durationMs": String(durationMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                recordTransmitStartupTiming(
                    stage: "remote-participant-clear-skipped",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    subsystem: .pushToTalk,
                    metadata: [
                        "reason": reason,
                        "durationMs": String(durationMilliseconds),
                        "error": error.localizedDescription,
                    ]
                )
                return true
            }
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Failed to clear active remote participant before local transmit",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                    "error": error.localizedDescription,
                ]
            )
            recordTransmitStartupTiming(
                stage: "remote-participant-clear-failed",
                contactID: contactID,
                channelUUID: channelUUID,
                subsystem: .pushToTalk,
                metadata: [
                    "reason": reason,
                    "durationMs": String(durationMilliseconds),
                    "error": error.localizedDescription,
                ]
            )
            return false
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
        guard shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "deferred-activation-ready"
        ) else {
            return
        }
        await completeSystemTransmitActivation(channelUUID: channelUUID)
    }

    @discardableResult
    func startPrewarmedDirectSystemTransmitBridgeIfPossible(
        request: TransmitRequestContext,
        trigger: String
    ) async -> Bool {
        guard let target = provisionalDirectQuicTransmitTarget(
            for: request,
            reason: "prewarmed-direct-bridge-\(trigger)"
        ) else {
            return false
        }
        return await startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            target: target,
            trigger: trigger
        )
    }

    @discardableResult
    func startPrewarmedDirectSystemTransmitBridgeIfPossible(
        request: TransmitRequestContext,
        target: TransmitTarget,
        trigger: String
    ) async -> Bool {
        guard !request.usesLocalHTTPBackend else { return false }
        guard request.channelUUID != nil else { return false }
        guard hasActiveTransmitPressIntent() else { return false }
        guard shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: request.contactID) else {
            return false
        }
        guard transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-requested") == nil else {
            return false
        }
        guard directQuicTransmitStartupPolicy != .appleGated
                || isPTTAudioSessionActive else {
            recordAppleGatedWarmDirectCaptureDeferred(
                request: request,
                target: target,
                trigger: trigger,
                reason: "waiting-for-apple-audio-session"
            )
            return false
        }

        configureOutgoingAudioRoute(target: target)
        diagnostics.record(
            .media,
            message: "Starting prewarmed Direct QUIC audio bridge before PTT activation",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "targetDeviceId": target.deviceID,
                "trigger": trigger,
                "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
            ]
        )
        do {
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-requested",
                metadata: ["trigger": trigger, "bridge": "prewarmed-direct"]
            )
            try await mediaServices.session()?.startSendingAudio()
            guard shouldContinuePrewarmedDirectSystemTransmitBridge(
                request: request,
                target: target,
                stage: "early-audio-capture-start-completed",
                recordCompletedSideEffectInvariant: false
            ) else {
                await mediaServices.session()?.abortSendingAudio()
                return false
            }
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-completed",
                metadata: ["trigger": trigger, "bridge": "prewarmed-direct"]
            )
            return true
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Prewarmed Direct QUIC audio bridge failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "trigger": trigger,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    func recordAppleGatedWarmDirectCaptureDeferred(
        request: TransmitRequestContext,
        target: TransmitTarget,
        trigger: String,
        reason: String
    ) {
        diagnostics.record(
            .media,
            message: "Deferring warm Direct QUIC capture until Apple audio activation",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": request.channelUUID?.uuidString ?? "none",
                "targetDeviceId": target.deviceID,
                "trigger": trigger,
                "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                "applicationState": String(describing: currentApplicationState()),
                "mediaState": String(describing: mediaConnectionState),
                "reason": reason,
            ]
        )
        recordFirstTransmitStartupTimingStageIfAbsent(
            "early-audio-capture-deferred-until-system-activation",
            metadata: [
                "trigger": trigger,
                "bridge": "prewarmed-direct",
                "reason": reason,
            ]
        )
    }

    func startAppleBeganWarmDirectQuicCaptureIfPossible(
        channelUUID: UUID,
        source: String
    ) async {
        guard directQuicTransmitStartupPolicy == .appleGated else { return }
        guard let target = activeTransmitTarget(for: channelUUID) else { return }
        guard isBackendLeaseBypassedTransmitTarget(target) else { return }
        guard let request = directQuicBackendLeaseBypassedRequest(for: target.contactID) else { return }
        guard shouldUseForegroundDirectQuicControlPath(for: target.contactID) else { return }

        guard isPTTAudioSessionActive else {
            guard shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: target.contactID) else {
                recordAppleGatedWarmDirectCaptureDeferred(
                    request: request,
                    target: target,
                    trigger: "system-transmit-began",
                    reason: "prewarmed-audio-session-closed-before-apple-activation"
                )
                return
            }
            let didStart = await startPrewarmedDirectSystemTransmitBridgeIfPossible(
                request: request,
                target: target,
                trigger: "system-transmit-began"
            )
            guard didStart else { return }
            await sendDirectQuicLeaseBypassedTransmitStartSignalIfPossible(
                target: target,
                channelUUID: channelUUID
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Starting warm Direct QUIC capture after Apple transmit began",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "channelUUID": channelUUID.uuidString,
                "source": source,
                "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
            ]
        )
        let didStart = await startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            target: target,
            trigger: "system-transmit-began"
        )
        guard didStart else { return }
        await sendDirectQuicLeaseBypassedTransmitStartSignalIfPossible(
            target: target,
            channelUUID: channelUUID
        )
    }

    func activeTransmitTarget(for systemChannelUUID: UUID) -> TransmitTarget? {
        transmitProjection.activeTarget(
            for: systemChannelUUID,
            channelUUIDForContact: { [weak self] contactID in
                self?.channelUUID(for: contactID)
            }
        )
    }

    private func stageCompletedTransmitStartupSideEffect(_ stage: String) -> Bool {
        switch stage {
        case "audio-capture-start-completed",
             "early-audio-capture-start-completed",
             "audio-capture-refreshed-after-system-activation",
             "transmit-start-signal-sent":
            return true
        default:
            return false
        }
    }

    private func recordStaleTransmitStartupSideEffectInvariantIfNeeded(
        stage: String,
        reason: String,
        contactID: UUID,
        channelID: String,
        channelUUID: UUID?,
        metadata: [String: String] = [:]
    ) {
        guard stageCompletedTransmitStartupSideEffect(stage) else { return }
        diagnostics.recordInvariantViolation(
            invariantID: "transmit.stale_startup_side_effect",
            scope: .local,
            message: "transmit startup side effect completed after activation was no longer current",
            metadata: metadata.merging(
                [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "channelUUID": channelUUID?.uuidString ?? "none",
                    "stage": stage,
                    "reason": reason,
                    "runtimePressActive": String(transmitRuntime.isPressingTalk),
                    "coordinatorPressActive": String(transmitCoordinator.state.isPressingTalk),
                    "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
    }

    func shouldContinueSystemTransmitActivation(
        channelUUID: UUID,
        target: TransmitTarget,
        stage: String,
        recordCompletedSideEffectInvariant: Bool = true
    ) -> Bool {
        let activeTarget = activeTransmitTarget(for: channelUUID)
        let reason: String?
        if transmitRuntime.explicitStopRequested {
            reason = "explicit-stop-requested"
        } else if !hasActiveTransmitPressIntent() {
            reason = "press-ended"
        } else if pttCoordinator.state.systemChannelUUID != channelUUID {
            reason = "system-channel-mismatch"
        } else if activeTarget != target {
            reason = "active-target-mismatch"
        } else {
            reason = nil
        }

        guard let reason else { return true }
        diagnostics.record(
            .media,
            message: "Cancelled stale system transmit activation continuation",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "channelUUID": channelUUID.uuidString,
                "stage": stage,
                "reason": reason,
                "runtimePressActive": String(transmitRuntime.isPressingTalk),
                "coordinatorPressActive": String(transmitCoordinator.state.isPressingTalk),
                "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                "activeTargetMatches": String(activeTarget == target),
            ]
        )
        if recordCompletedSideEffectInvariant {
            recordStaleTransmitStartupSideEffectInvariantIfNeeded(
                stage: stage,
                reason: reason,
                contactID: target.contactID,
                channelID: target.channelID,
                channelUUID: channelUUID,
                metadata: ["activeTargetMatches": String(activeTarget == target)]
            )
        }
        return false
    }

    func shouldContinuePendingSystemTransmitAudioCapture(
        request: TransmitRequestContext,
        stage: String,
        recordCompletedSideEffectInvariant: Bool = true
    ) -> Bool {
        let activeTarget = request.channelUUID.flatMap { activeTransmitTarget(for: $0) }
        let requestStillCurrent =
            transmitCoordinator.state.pendingRequest == request
            || (
                activeTarget?.contactID == request.contactID
                && activeTarget?.channelID == request.backendChannelID
                && activeTarget?.userID == request.remoteUserID
            )
        let reason: String?
        if transmitRuntime.explicitStopRequested {
            reason = "explicit-stop-requested"
        } else if !hasActiveTransmitPressIntent() {
            reason = "press-ended"
        } else if pttCoordinator.state.systemChannelUUID != request.channelUUID {
            reason = "system-channel-mismatch"
        } else if !requestStillCurrent {
            reason = "request-not-current"
        } else {
            reason = nil
        }

        guard let reason else { return true }
        diagnostics.record(
            .media,
            message: "Cancelled stale pending system transmit audio capture",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": request.channelUUID?.uuidString ?? "none",
                "stage": stage,
                "reason": reason,
                "runtimePressActive": String(transmitRuntime.isPressingTalk),
                "coordinatorPressActive": String(transmitCoordinator.state.isPressingTalk),
                "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                "requestStillCurrent": String(requestStillCurrent),
            ]
        )
        if recordCompletedSideEffectInvariant {
            recordStaleTransmitStartupSideEffectInvariantIfNeeded(
                stage: stage,
                reason: reason,
                contactID: request.contactID,
                channelID: request.backendChannelID,
                channelUUID: request.channelUUID,
                metadata: [
                    "requestKind": "pending-system-audio-capture",
                    "requestStillCurrent": String(requestStillCurrent),
                ]
            )
        }
        return false
    }

    func shouldRefreshPrewarmedAudioCaptureAfterSystemActivation(for contactID: UUID) -> Bool {
        guard transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-completed") != nil else {
            return false
        }
        guard isPTTAudioSessionActive else { return false }
        guard transmitStartupTiming.elapsedMilliseconds(
            for: "audio-capture-refreshed-after-system-activation"
        ) == nil else {
            return false
        }
        return true
    }

    func shouldContinuePrewarmedDirectSystemTransmitBridge(
        request: TransmitRequestContext,
        target: TransmitTarget,
        stage: String,
        recordCompletedSideEffectInvariant: Bool = true
    ) -> Bool {
        let activeTarget = request.channelUUID.flatMap { activeTransmitTarget(for: $0) }
        let requestStillCurrent =
            transmitCoordinator.state.pendingRequest == request
            || activeTarget == target
        let reason: String?
        if transmitRuntime.explicitStopRequested {
            reason = "explicit-stop-requested"
        } else if !hasActiveTransmitPressIntent() {
            reason = "press-ended"
        } else if !requestStillCurrent {
            reason = "request-not-current"
        } else {
            reason = nil
        }

        guard let reason else { return true }
        diagnostics.record(
            .media,
            message: "Cancelled stale prewarmed Direct QUIC bridge continuation",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "channelUUID": request.channelUUID?.uuidString ?? "none",
                "targetDeviceId": target.deviceID,
                "stage": stage,
                "reason": reason,
                "runtimePressActive": String(transmitRuntime.isPressingTalk),
                "coordinatorPressActive": String(transmitCoordinator.state.isPressingTalk),
                "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                "requestStillCurrent": String(requestStillCurrent),
            ]
        )
        if recordCompletedSideEffectInvariant {
            recordStaleTransmitStartupSideEffectInvariantIfNeeded(
                stage: stage,
                reason: reason,
                contactID: request.contactID,
                channelID: request.backendChannelID,
                channelUUID: request.channelUUID,
                metadata: [
                    "requestKind": "prewarmed-direct-bridge",
                    "targetDeviceId": target.deviceID,
                    "requestStillCurrent": String(requestStillCurrent),
                ]
            )
        }
        return false
    }

    func completeSystemTransmitActivation(channelUUID: UUID) async {
        guard let target = activeTransmitTarget(for: channelUUID) else { return }
        guard shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "activation-start"
        ) else {
            return
        }
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

        if !isBackendLeaseBypassedTransmitTarget(target) {
            startRenewingTransmit(target)
        }
        recordTransmitStartupTiming(
            stage: "system-activation-started",
            contactID: target.contactID,
            channelUUID: channelUUID,
            channelID: target.channelID
        )

        if isBackendLeaseBypassedTransmitTarget(target) {
            activationCompleted = await completeDirectQuicLeaseBypassedSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target
            )
            return
        }

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
            recordTransmitStartupTiming(
                stage: "websocket-wait-started",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                subsystem: .websocket
            )
            try await backend.waitForWebSocketConnection()
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "websocket-wait-completed"
            ) else {
                return
            }
            recordTransmitStartupTiming(
                stage: "websocket-wait-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                subsystem: .websocket
            )
            configureOutgoingAudioRoute(target: target)
            recordTransmitStartupTiming(
                stage: "media-session-start-requested",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            await ensureMediaSession(
                for: target.contactID,
                activationMode: .systemActivated,
                startupMode: .interactive
            )
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "media-session-start-completed"
            ) else {
                return
            }
            recordTransmitStartupTiming(
                stage: "media-session-start-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            configureOutgoingAudioRoute(target: target)
            if transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-completed") != nil {
                if shouldRefreshPrewarmedAudioCaptureAfterSystemActivation(for: target.contactID) {
                    guard shouldContinueSystemTransmitActivation(
                        channelUUID: channelUUID,
                        target: target,
                        stage: "audio-capture-refresh-after-system-activation-requested"
                    ) else {
                        return
                    }
                    diagnostics.record(
                        .media,
                        message: "Refreshing prewarmed audio capture after system audio activation",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "channelUUID": channelUUID.uuidString,
                            "trigger": "system-activation",
                        ]
                    )
                    recordTransmitStartupTiming(
                        stage: "audio-capture-refresh-after-system-activation-requested",
                        contactID: target.contactID,
                        channelUUID: channelUUID,
                        channelID: target.channelID
                    )
                    try await mediaServices.session()?.startSendingAudio()
                    guard shouldContinueSystemTransmitActivation(
                        channelUUID: channelUUID,
                        target: target,
                        stage: "audio-capture-refresh-after-system-activation-start-returned",
                        recordCompletedSideEffectInvariant: false
                    ) else {
                        await mediaServices.session()?.abortSendingAudio()
                        return
                    }
                    recordTransmitStartupTiming(
                        stage: "audio-capture-refreshed-after-system-activation",
                        contactID: target.contactID,
                        channelUUID: channelUUID,
                        channelID: target.channelID
                    )
                } else {
                    diagnostics.record(
                        .media,
                        message: "Skipping duplicate system audio capture start because prewarmed Direct QUIC bridge is already sending",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "channelUUID": channelUUID.uuidString,
                        ]
                    )
                    recordTransmitStartupTiming(
                        stage: "audio-capture-already-started",
                        contactID: target.contactID,
                        channelUUID: channelUUID,
                        channelID: target.channelID
                    )
                }
            } else {
                guard shouldContinueSystemTransmitActivation(
                    channelUUID: channelUUID,
                    target: target,
                    stage: "audio-capture-start-requested"
                ) else {
                    return
                }
                recordTransmitStartupTiming(
                    stage: "audio-capture-start-requested",
                    contactID: target.contactID,
                    channelUUID: channelUUID,
                    channelID: target.channelID
                )
                try await mediaServices.session()?.startSendingAudio()
                guard shouldContinueSystemTransmitActivation(
                    channelUUID: channelUUID,
                    target: target,
                    stage: "audio-capture-start-completed",
                    recordCompletedSideEffectInvariant: false
                ) else {
                    await mediaServices.session()?.abortSendingAudio()
                    return
                }
                recordTransmitStartupTiming(
                    stage: "audio-capture-start-completed",
                    contactID: target.contactID,
                    channelUUID: channelUUID,
                    channelID: target.channelID
                )
            }
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "before-transmit-start-signal"
            ) else {
                return
            }
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
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "transmit-start-signal-sent"
            ) else {
                return
            }
            recordTransmitStartupTiming(
                stage: "transmit-start-signal-sent",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            transmitRuntime.noteSystemTransmitActivationCompleted(channelUUID: channelUUID)
            activationCompleted = true
            recordTransmitStartupTiming(
                stage: "startup-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            recordTransmitStartupTimingSummary(
                reason: "startup-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
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
            recordTransmitStartupTimingSummary(
                reason: "activation-failed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: ["error": message]
            )
            await performStopTransmit(target)
        }
    }

    private func completeDirectQuicLeaseBypassedSystemTransmitActivation(
        channelUUID: UUID,
        target: TransmitTarget
    ) async -> Bool {
        do {
            configureOutgoingAudioRoute(target: target)
            recordTransmitStartupTiming(
                stage: "media-session-start-requested",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            await ensureMediaSession(
                for: target.contactID,
                activationMode: .systemActivated,
                startupMode: .interactive
            )
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "media-session-start-completed"
            ) else {
                return false
            }
            recordTransmitStartupTiming(
                stage: "media-session-start-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            if transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-completed") != nil {
                if shouldRefreshPrewarmedAudioCaptureAfterSystemActivation(for: target.contactID) {
                    guard shouldContinueSystemTransmitActivation(
                        channelUUID: channelUUID,
                        target: target,
                        stage: "audio-capture-refresh-after-system-activation-requested"
                    ) else {
                        return false
                    }
                    diagnostics.record(
                        .media,
                        message: "Refreshing prewarmed Direct QUIC capture after system audio activation",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "channelUUID": channelUUID.uuidString,
                            "backendLease": "bypassed-direct-quic",
                        ]
                    )
                    recordTransmitStartupTiming(
                        stage: "audio-capture-refresh-after-system-activation-requested",
                        contactID: target.contactID,
                        channelUUID: channelUUID,
                        channelID: target.channelID,
                        metadata: ["backendLease": "bypassed-direct-quic"]
                    )
                    try await mediaServices.session()?.startSendingAudio()
                    guard shouldContinueSystemTransmitActivation(
                        channelUUID: channelUUID,
                        target: target,
                        stage: "audio-capture-refresh-after-system-activation-start-returned",
                        recordCompletedSideEffectInvariant: false
                    ) else {
                        await mediaServices.session()?.abortSendingAudio()
                        return false
                    }
                    recordTransmitStartupTiming(
                        stage: "audio-capture-refreshed-after-system-activation",
                        contactID: target.contactID,
                        channelUUID: channelUUID,
                        channelID: target.channelID,
                        metadata: ["backendLease": "bypassed-direct-quic"]
                    )
                } else {
                    diagnostics.record(
                        .media,
                        message: "Skipping duplicate Direct QUIC audio capture refresh after system audio activation",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "channelUUID": channelUUID.uuidString,
                            "backendLease": "bypassed-direct-quic",
                        ]
                    )
                    recordTransmitStartupTiming(
                        stage: "audio-capture-already-started",
                        contactID: target.contactID,
                        channelUUID: channelUUID,
                        channelID: target.channelID,
                        metadata: ["backendLease": "bypassed-direct-quic"]
                    )
                }
                await sendDirectQuicLeaseBypassedTransmitStartSignalIfPossible(
                    target: target,
                    channelUUID: channelUUID
                )
                transmitRuntime.noteSystemTransmitActivationCompleted(channelUUID: channelUUID)
                recordTransmitStartupTiming(
                    stage: "startup-completed",
                    contactID: target.contactID,
                    channelUUID: channelUUID,
                    channelID: target.channelID
                )
                recordTransmitStartupTimingSummary(
                    reason: "startup-completed",
                    contactID: target.contactID,
                    channelUUID: channelUUID,
                    channelID: target.channelID,
                    metadata: ["backendLease": "bypassed-direct-quic"]
                )
                await refreshChannelState(for: target.contactID)
                return true
            }
            recordTransmitStartupTiming(
                stage: "audio-capture-start-requested",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            try await mediaServices.session()?.startSendingAudio()
            guard shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "audio-capture-start-completed",
                recordCompletedSideEffectInvariant: false
            ) else {
                await mediaServices.session()?.abortSendingAudio()
                return false
            }
            recordTransmitStartupTiming(
                stage: "audio-capture-start-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            await sendDirectQuicLeaseBypassedTransmitStartSignalIfPossible(
                target: target,
                channelUUID: channelUUID
            )
            transmitRuntime.noteSystemTransmitActivationCompleted(channelUUID: channelUUID)
            recordTransmitStartupTiming(
                stage: "startup-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID
            )
            recordTransmitStartupTimingSummary(
                reason: "startup-completed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: ["backendLease": "bypassed-direct-quic"]
            )
            await refreshChannelState(for: target.contactID)
            return true
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC transmit activation failed",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "error": error.localizedDescription,
                ]
            )
            recordTransmitStartupTimingSummary(
                reason: "activation-failed",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: ["error": error.localizedDescription]
            )
            await performStopTransmit(target)
            return false
        }
    }

    private func sendDirectQuicLeaseBypassedTransmitStartSignalIfPossible(
        target: TransmitTarget,
        channelUUID: UUID
    ) async {
        guard transmitStartupTiming.elapsedMilliseconds(for: "transmit-start-signal-sent") == nil else {
            return
        }
        guard let backend = backendServices, backend.supportsWebSocket else { return }
        guard backend.isWebSocketConnected else {
            diagnostics.record(
                .websocket,
                message: "Skipped transmit start signal for Direct QUIC lease bypass because WebSocket is not connected",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "channelUUID": channelUUID.uuidString,
                ]
            )
            return
        }
        do {
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
            recordTransmitStartupTiming(
                stage: "transmit-start-signal-sent",
                contactID: target.contactID,
                channelUUID: channelUUID,
                channelID: target.channelID,
                metadata: ["backendLease": "bypassed-direct-quic"]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Transmit start signal failed for Direct QUIC lease bypass",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func startPendingSystemTransmitAudioCaptureIfPossible(
        channelUUID: UUID,
        trigger: String
    ) async {
        guard !usesLocalHTTPBackend else { return }
        guard hasActiveTransmitPressIntent() else { return }
        guard let request = transmitCoordinator.state.pendingRequest else { return }
        guard request.channelUUID == channelUUID else { return }
        guard pttCoordinator.state.systemChannelUUID == channelUUID else { return }
        guard isPTTAudioSessionActive else { return }
        guard mediaSessionContactID == nil || mediaSessionContactID == request.contactID else { return }
        guard shouldContinuePendingSystemTransmitAudioCapture(
            request: request,
            stage: "start"
        ) else {
            return
        }

        configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
            for: request,
            reason: "early-system-audio-capture-\(trigger)"
        )

        recordFirstTransmitStartupTimingStageIfAbsent(
            "early-media-session-start-requested",
            metadata: ["trigger": trigger]
        )
        await ensureMediaSession(
            for: request.contactID,
            activationMode: .systemActivated,
            startupMode: .interactive
        )
        guard shouldContinuePendingSystemTransmitAudioCapture(
            request: request,
            stage: "media-session-start-completed"
        ) else {
            return
        }
        recordFirstTransmitStartupTimingStageIfAbsent(
            "early-media-session-start-completed",
            metadata: ["trigger": trigger]
        )
        do {
            guard transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-completed") == nil else {
                if trigger == "audio-session-activated",
                   shouldRefreshPrewarmedAudioCaptureAfterSystemActivation(for: request.contactID) {
                    guard shouldContinuePendingSystemTransmitAudioCapture(
                        request: request,
                        stage: "audio-capture-refresh-after-system-activation-requested"
                    ) else {
                        return
                    }
                    diagnostics.record(
                        .media,
                        message: "Refreshing prewarmed audio capture after system audio activation",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "channelId": request.backendChannelID,
                            "channelUUID": channelUUID.uuidString,
                            "trigger": trigger,
                        ]
                    )
                    recordFirstTransmitStartupTimingStageIfAbsent(
                        "audio-capture-refresh-after-system-activation-requested",
                        metadata: ["trigger": trigger]
                    )
                    try await mediaServices.session()?.startSendingAudio()
                    guard shouldContinuePendingSystemTransmitAudioCapture(
                        request: request,
                        stage: "audio-capture-refresh-after-system-activation-start-returned",
                        recordCompletedSideEffectInvariant: false
                    ) else {
                        await mediaServices.session()?.abortSendingAudio()
                        return
                    }
                    recordFirstTransmitStartupTimingStageIfAbsent(
                        "audio-capture-refreshed-after-system-activation",
                        metadata: ["trigger": trigger]
                    )
                    return
                }
                diagnostics.record(
                    .media,
                    message: "Skipping duplicate pending system audio capture start because audio capture is already active",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelId": request.backendChannelID,
                        "channelUUID": channelUUID.uuidString,
                        "trigger": trigger,
                    ]
                )
                return
            }
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-requested",
                metadata: ["trigger": trigger]
            )
            try await mediaServices.session()?.startSendingAudio()
            guard shouldContinuePendingSystemTransmitAudioCapture(
                request: request,
                stage: "audio-capture-start-completed",
                recordCompletedSideEffectInvariant: false
            ) else {
                await mediaServices.session()?.abortSendingAudio()
                return
            }
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-start-completed",
                metadata: ["trigger": trigger]
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Early transmit audio capture failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "channelId": request.backendChannelID,
                    "trigger": trigger,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    @discardableResult
    func configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
        for request: TransmitRequestContext,
        reason: String
    ) -> Bool {
        guard let provisionalTarget = provisionalDirectQuicTransmitTarget(
            for: request,
            reason: reason
        ) else {
            return false
        }

        configureOutgoingAudioRoute(target: provisionalTarget)
        diagnostics.record(
            .media,
            message: "Configured provisional Direct QUIC outgoing audio route",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "peerDeviceId": provisionalTarget.deviceID,
                "reason": reason,
            ]
        )
        return true
    }

    func provisionalDirectQuicTransmitTarget(
        for request: TransmitRequestContext,
        reason: String
    ) -> TransmitTarget? {
        guard shouldUseDirectQuicTransport(for: request.contactID) else {
            return nil
        }
        let peerDeviceID =
            directQuicAttempt(for: request.contactID)?.peerDeviceID
            ?? directQuicPeerDeviceID(for: request.contactID)
        guard let peerDeviceID, !peerDeviceID.isEmpty else {
            diagnostics.record(
                .media,
                message: "Skipped provisional Direct QUIC audio route because peer device is unknown",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "reason": reason,
                ]
            )
            return nil
        }

        return TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: peerDeviceID,
            channelID: request.backendChannelID,
            transmitID: directQuicAttempt(for: request.contactID)?.attemptId
        )
    }

    func handleActivatedAudioSession(_ audioSession: AVAudioSession) async {
        applyPreferredAudioOutputRoute(to: audioSession)
        let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID
        let activeTarget = activeSystemChannelUUID.flatMap(activeTransmitTarget(for:))
        let pendingRequest = transmitCoordinator.state.pendingRequest
        if let activeSystemChannelUUID {
            recordTransmitStartupTiming(
                stage: "system-audio-session-activated",
                contactID: activeTarget?.contactID ?? pendingRequest?.contactID ?? contactId(for: activeSystemChannelUUID),
                channelUUID: activeSystemChannelUUID,
                channelID: activeTarget?.channelID ?? pendingRequest?.backendChannelID,
                subsystem: .pushToTalk,
                metadata: [
                    "category": audioSession.category.rawValue,
                    "mode": audioSession.mode.rawValue,
                    "targetSource": activeTarget == nil ? "pending-request" : "active-target",
                ]
            )
        }
        if let activeSystemChannelUUID {
            await startPendingSystemTransmitAudioCaptureIfPossible(
                channelUUID: activeSystemChannelUUID,
                trigger: "audio-session-activated"
            )
        }
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
            let contactID = wake.contactID
            if wake.activationState == .appManagedFallback,
               prefersForegroundAppManagedReceivePlayback(for: contactID),
               mediaSessionContactID == contactID,
               (mediaConnectionState == .connected || mediaConnectionState == .preparing) {
                pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
                await mediaServices.session()?.audioRouteDidChange()
                recordWakeReceiveTiming(
                    stage: "late-system-audio-activation-preserved-app-managed-playback",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId,
                    subsystem: .pushToTalk
                )
                diagnostics.record(
                    .media,
                    message: "Preserved app-managed wake playback after late PTT audio activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": wake.channelUUID.uuidString,
                    ]
                )
                diagnostics.record(
                    .media,
                    message: "Refreshed app-managed wake playback after late PTT audio activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": wake.channelUUID.uuidString,
                    ]
                )
                captureDiagnosticsState("ptt-wake:preserved-app-managed-playback")
                schedulePostWakeBackendRefresh(for: contactID)
                return
            }
            pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
            pttWakeRuntime.markAudioSessionActivated(for: wake.channelUUID)
            recordWakeReceiveTiming(
                stage: "system-audio-activation-observed",
                contactID: contactID,
                channelUUID: wake.channelUUID,
                channelID: wake.payload.channelId,
                subsystem: .pushToTalk
            )
            diagnostics.record(
                .pushToTalk,
                message: "Handling PTT wake audio activation",
                metadata: [
                    "channelUUID": wake.channelUUID.uuidString,
                    "contactID": wake.contactID.uuidString,
                    "event": wake.payload.event.rawValue,
                ]
            )
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
            closeMediaSession(
                deactivateAudioSession: false,
                preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
            )
            await ensureMediaSession(
                for: contactID,
                activationMode: .systemActivated,
                startupMode: .playbackOnly
            )
            let bufferedAudioChunks = pttWakeRuntime.takeBufferedAudioChunks(for: contactID)
            if !bufferedAudioChunks.isEmpty {
                markRemoteAudioActivity(for: contactID, source: .audioChunk)
                recordWakeReceiveTiming(
                    stage: "buffered-audio-flush-started",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId,
                    metadata: ["bufferedChunkCount": String(bufferedAudioChunks.count)]
                )
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
                recordWakeReceiveTiming(
                    stage: "buffered-audio-flush-completed",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId,
                    metadata: ["bufferedChunkCount": String(bufferedAudioChunks.count)]
                )
                recordWakeReceiveTimingSummary(
                    reason: "system-activated-buffered-flush",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId,
                    metadata: ["bufferedChunkCount": String(bufferedAudioChunks.count)]
                )
            } else {
                diagnostics.record(
                    .media,
                    message: "No buffered wake audio to flush after PTT activation",
                    metadata: ["contactId": contactID.uuidString]
                )
                recordWakeReceiveTimingSummary(
                    reason: "system-activated-no-buffered-audio",
                    contactID: contactID,
                    channelUUID: wake.channelUUID,
                    channelID: wake.payload.channelId
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
        setAudioOutputPreference(preference, persist: true, reason: "manual")
    }

    func setAudioOutputPreference(
        _ preference: AudioOutputPreference,
        persist: Bool,
        reason: String
    ) {
        guard audioOutputPreference != preference else {
            applyPreferredAudioOutputRouteIfPossible()
            return
        }
        audioOutputPreference = preference
        if persist {
            UserDefaults.standard.set(preference.rawValue, forKey: AudioOutputPreference.storageKey)
        }
        applyPreferredAudioOutputRouteIfPossible()
        _ = currentLocalCallTelemetry(includeAudio: activeChannelId != nil)
        Task { @MainActor [weak self] in
            await self?.syncActiveCallTelemetryIfNeeded(reason: .audioRoutePreference(reason))
        }
        diagnostics.record(
            .media,
            message: "Audio output preference updated",
            metadata: [
                "preference": preference.rawValue,
                "persisted": String(persist),
                "reason": reason,
            ]
        )
        captureDiagnosticsState("audio-route:updated")
    }

    func applyPreferredAudioOutputRoute(to audioSession: AVAudioSession = .sharedInstance()) {
        let overridePlan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: audioOutputPreference,
            category: audioSession.category,
            outputPortTypes: audioSession.currentRoute.outputs.map(\.portType)
        )
        if overridePlan.shouldClearSpeakerOverride {
            do {
                try audioSession.overrideOutputAudioPort(.none)
                diagnostics.record(
                    .media,
                    message: "Cleared preferred speaker audio route",
                    metadata: audioSessionDiagnostics(audioSession).merging(
                        ["preference": audioOutputPreference.rawValue]
                    ) { _, new in new }
                )
            } catch {
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Failed to clear preferred speaker audio route",
                    metadata: [
                        "error": error.localizedDescription,
                        "preference": audioOutputPreference.rawValue,
                        "category": audioSession.category.rawValue,
                        "mode": audioSession.mode.rawValue,
                    ]
                )
            }
            return
        }

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

        diagnostics.record(
            .media,
            message: "PTT activation timed out; starting app-managed playback fallback",
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

        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else {
            diagnostics.record(
                .media,
                message: "Skipped app-managed playback fallback because wake activation changed during startup",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "activationState": String(
                        describing: pttWakeRuntime.incomingWakeActivationState(for: contactID) ?? .signalBuffered
                    )
                ]
            )
            return
        }

        let bufferedAudioChunks = pttWakeRuntime.takeBufferedAudioChunks(for: contactID)
        pttWakeRuntime.markAppManagedFallbackStarted(for: contactID)
        recordWakeReceiveTiming(
            stage: "app-managed-fallback-flush-started",
            contactID: contactID,
            metadata: [
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "reason": reason,
            ]
        )
        diagnostics.record(
            .media,
            message: "Flushing buffered wake audio through app-managed playback fallback",
            metadata: [
                "contactId": contactID.uuidString,
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "reason": reason
            ]
        )
        markRemoteAudioActivity(for: contactID, source: .audioChunk)
        for payload in bufferedAudioChunks {
            await receiveRemoteAudioChunk(payload)
        }
        recordWakeReceiveTiming(
            stage: "app-managed-fallback-flush-completed",
            contactID: contactID,
            metadata: [
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "reason": reason,
            ]
        )
        recordWakeReceiveTimingSummary(
            reason: "app-managed-fallback-flush",
            contactID: contactID,
            metadata: [
                "bufferedChunkCount": String(bufferedAudioChunks.count),
                "fallbackReason": reason,
            ]
        )
    }

    func configureOutgoingAudioRoute(target: TransmitTarget) {
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
        configureMediaEncryptionSessionIfPossible(
            contactID: target.contactID,
            channelID: channelID,
            peerDeviceID: toDeviceID
        )
        let sendAudioChunk: @Sendable (String) async throws -> Void = { [weak self] payload in
            if let self,
               await self.takeShouldAwaitInitialOutboundAudioSendGate() {
                let receiverBecameReady = await self.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
                    target: target
                )
                guard receiverBecameReady else {
                    throw OutgoingAudioSendError.remoteReceiverAudioNotReady
                }
            }

            let transportPayload: String
            if let self {
                transportPayload = try await MainActor.run {
                    try self.sealOutgoingMediaPayloadIfPossible(payload, target: target)
                }
            } else {
                transportPayload = payload
            }

            let relaySend: @Sendable () async throws -> Void = {
                let envelope = TurboSignalEnvelope(
                    type: .audioChunk,
                    channelId: channelID,
                    fromUserId: fromUserID,
                    fromDeviceId: fromDeviceID,
                    toUserId: toUserID,
                    toDeviceId: toDeviceID,
                    payload: transportPayload
                )
                try await backend.sendSignal(envelope)
            }

            if let self {
                let directTransport = await MainActor.run { () -> DirectQuicProbeController? in
                    guard !TurboMediaRelayDebugOverride.isForced(),
                          self.shouldUseDirectQuicAudioTransport(for: target.contactID) else {
                        return nil
                    }
                    return self.mediaRuntime.directQuicProbeController
                }
                if let directTransport {
                    do {
                        try await directTransport.sendAudioPayload(transportPayload)
                        return
                    } catch {
                        await MainActor.run {
                            self.diagnostics.record(
                                .media,
                                level: .error,
                                message: "Direct QUIC audio send failed; falling back to relay",
                                metadata: [
                                    "contactId": target.contactID.uuidString,
                                    "channelId": target.channelID,
                                    "error": error.localizedDescription,
                                ]
                            )
                        }
                    }
                }

                if let relayClient = await self.mediaRelayClientForAudioSend(target: target) {
                    do {
                        try await relayClient.sendAudioPayload(transportPayload)
                        return
                    } catch {
                        await MainActor.run {
                            self.diagnostics.record(
                                .media,
                                level: .error,
                                message: "Media relay audio send failed; falling back to WebSocket relay",
                                metadata: [
                                    "contactId": target.contactID.uuidString,
                                    "channelId": target.channelID,
                                    "error": error.localizedDescription,
                                ]
                            )
                            let key = MediaRelayConnectionKey(
                                sessionID: target.channelID,
                                localDeviceID: fromDeviceID,
                                peerDeviceID: target.deviceID
                            )
                            self.mediaRuntime.clearMediaRelayClient(matching: key)
                        }
                    }
                }
            }

            try await relaySend()
        }
        mediaServices.replaceSendAudioChunk(sendAudioChunk)
        mediaServices.session()?.updateSendAudioChunk(sendAudioChunk)
        diagnostics.record(
            .media,
            message: "Configured outgoing audio transport",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "deviceId": target.deviceID,
                "transport": configuredOutgoingAudioTransportLabel(for: target.contactID),
                "directQuicActive": String(shouldUseDirectQuicTransport(for: target.contactID)),
                "mediaRelayEnabled": String(TurboMediaRelayDebugOverride.isEnabled()),
                "mediaRelayForced": String(TurboMediaRelayDebugOverride.isForced()),
                "mediaRelayConfigured": String(TurboMediaRelayDebugOverride.config()?.isConfigured == true),
                "selection": "dynamic",
            ]
        )
    }

    func configuredOutgoingAudioTransportLabel(for contactID: UUID) -> String {
        if TurboMediaRelayDebugOverride.isForced() {
            return "media-relay-forced"
        }
        if shouldUseDirectQuicAudioTransport(for: contactID) {
            return "direct-quic"
        }
        if TurboMediaRelayDebugOverride.isEnabled() {
            return "media-relay-standby"
        }
        return "relay-websocket"
    }

    func mediaRelayClientForAudioSend(target: TransmitTarget) async -> TurboMediaRelayClient? {
        await mediaRelayClientIfEnabled(
            contactID: target.contactID,
            channelID: target.channelID,
            peerDeviceID: target.deviceID,
            missingConfigMessage: "Media relay skipped because relay config is missing",
            connectingMessage: "Connecting media relay",
            selectedMessage: "Media relay selected",
            failureMessage: "Media relay connection failed; falling back to WebSocket relay",
            fromUserIDForIncoming: { target.userID }
        )
    }

    func connectMediaRelayForReceiveIfNeeded(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String
    ) async {
        _ = await mediaRelayClientIfEnabled(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID,
            missingConfigMessage: "Media relay receive prejoin skipped because relay config is missing",
            connectingMessage: "Prejoining media relay for receive",
            selectedMessage: "Media relay receive prejoin selected",
            failureMessage: "Media relay receive prejoin failed",
            fromUserIDForIncoming: { [weak self] in
                await MainActor.run {
                    self?.contacts.first(where: { $0.id == contactID })?.remoteUserId ?? ""
                }
            }
        )
    }

    func mediaRelayClientIfEnabled(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        missingConfigMessage: String,
        connectingMessage: String,
        selectedMessage: String,
        failureMessage: String,
        fromUserIDForIncoming: @escaping @Sendable () async -> String
    ) async -> TurboMediaRelayClient? {
        let shouldAttempt = await MainActor.run {
            TurboMediaRelayDebugOverride.isEnabled() || TurboMediaRelayDebugOverride.isForced()
        }
        guard shouldAttempt else { return nil }
        guard let config = await MainActor.run(body: { TurboMediaRelayDebugOverride.config() }) else {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    level: .error,
                    message: missingConfigMessage,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                    ]
                )
            }
            return nil
        }
        let localDeviceId = await MainActor.run { backendServices?.deviceID ?? "" }
        guard !localDeviceId.isEmpty else {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Media relay skipped because local device id is missing",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                    ]
                )
            }
            return nil
        }
        let key = MediaRelayConnectionKey(
            sessionID: channelID,
            localDeviceID: localDeviceId,
            peerDeviceID: peerDeviceID
        )
        let start = await MainActor.run {
            mediaRuntime.mediaRelayConnectionStart(for: key)
        }
        switch start {
        case .existingClient(let client):
            return client
        case .existingAttempt(let attempt):
            return await attempt.wait()
        case .newAttempt(let attempt):
            return await connectNewMediaRelayClient(
                attempt: attempt,
                config: config,
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                localDeviceID: localDeviceId,
                connectingMessage: connectingMessage,
                selectedMessage: selectedMessage,
                failureMessage: failureMessage,
                fromUserIDForIncoming: fromUserIDForIncoming
            )
        }
    }

    func connectNewMediaRelayClient(
        attempt: MediaRelayConnectionAttempt,
        config: TurboMediaRelayClientConfig,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        localDeviceID: String,
        connectingMessage: String,
        selectedMessage: String,
        failureMessage: String,
        fromUserIDForIncoming: @escaping @Sendable () async -> String
    ) async -> TurboMediaRelayClient? {
        let client = TurboMediaRelayClient(
            config: config,
            sessionId: channelID,
            localDeviceId: localDeviceID,
            peerDeviceId: peerDeviceID,
            onIncomingAudioPayload: { [weak self] payload in
                let fromUserID = await fromUserIDForIncoming()
                await self?.handleIncomingAudioPayload(
                    payload,
                    channelID: channelID,
                    fromUserID: fromUserID,
                    fromDeviceID: peerDeviceID,
                    contactID: contactID,
                    incomingAudioTransport: .directQuic
                )
            },
            reportEvent: { [weak self] message, metadata in
                await MainActor.run {
                    self?.diagnostics.record(.media, message: message, metadata: metadata)
                }
            }
        )
        await MainActor.run {
            diagnostics.record(
                .media,
                message: connectingMessage,
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "host": config.host,
                    "quicPort": String(config.quicPort),
                    "tcpPort": String(config.tcpPort),
                    "forced": String(TurboMediaRelayDebugOverride.isForced()),
                ]
            )
        }
        do {
            let transport = try await client.connect()
            let accepted = await MainActor.run {
                mediaRuntime.finishMediaRelayConnectionAttempt(attempt, client: client)
            }
            guard accepted else { return nil }
            await MainActor.run {
                mediaRuntime.updateTransportPathState(.fastRelay)
                diagnostics.record(
                    .media,
                    message: selectedMessage,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                        "transport": transport.rawValue,
                    ]
                )
            }
            return client
        } catch {
            await MainActor.run {
                _ = mediaRuntime.finishMediaRelayConnectionAttempt(attempt, client: nil)
                diagnostics.record(
                    .media,
                    level: .error,
                    message: failureMessage,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                        "error": error.localizedDescription,
                    ]
                )
            }
            return nil
        }
    }

    func prejoinMediaRelayForReadyChannelIfNeeded(
        contactID: UUID,
        channelReadiness: TurboChannelReadinessResponse?
    ) async {
        let shouldAttempt = await MainActor.run {
            TurboMediaRelayDebugOverride.isEnabled() || TurboMediaRelayDebugOverride.isForced()
        }
        guard shouldAttempt else { return }
        guard let channelReadiness,
              let peerDeviceID = channelReadiness.peerTargetDeviceId,
              !peerDeviceID.isEmpty else {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    message: "Media relay ready-channel prejoin skipped because peer target device is missing",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelReadiness?.channelId ?? "none",
                    ]
                )
            }
            return
        }
        await connectMediaRelayForReceiveIfNeeded(
            contactID: contactID,
            channelID: channelReadiness.channelId,
            peerDeviceID: peerDeviceID
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
                    message: "Timed out waiting for remote receiver audio readiness; not sending outbound audio",
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
        guard let systemChannelUUID = pttCoordinator.state.systemChannelUUID,
              channelUUID(for: target.contactID) == systemChannelUUID else {
            return
        }

        let previousPTTState = pttCoordinator.state
        let endOrigin = SystemTransmitEndOrigin.explicitStopReconciliation(source: source)
        await pttCoordinator.handle(
            .didEndTransmitting(
                channelUUID: systemChannelUUID,
                origin: endOrigin
            )
        )
        guard pttCoordinator.state != previousPTTState else { return }

        diagnostics.record(
            .pushToTalk,
            message: "Reconciling explicit transmit stop without system callback",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelUUID": systemChannelUUID.uuidString,
                "source": source,
                "origin": endOrigin.kind,
            ]
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
        await transmitCoordinator.handle(.stopCompleted(target))
        syncTransmitState()
        directQuicBackendLeaseBypassedContactIDs.remove(target.contactID)
        directQuicBackendLeaseBypassedRequestsByContactID.removeValue(forKey: target.contactID)
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-stop:completed-locally")
    }

    private func performStopTransmit(_ target: TransmitTarget) async {
        let media = mediaServices
        transmitTaskCoordinator.send(.renewalCancelled)
        transmitTaskRuntime.cancelCaptureReassertionTask()

        if usesLocalHTTPBackend {
            isTransmitting = false
        } else if let activeChannelId,
                  let channelUUID = channelUUID(for: activeChannelId),
                  pttCoordinator.state.isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }

        do {
            try? await media.session()?.stopSendingAudio()
            if let backend = backendServices {
                if backend.supportsWebSocket && backend.isWebSocketConnected {
                    diagnostics.record(
                        .websocket,
                        message: "Sending transmit stop signal before backend end",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                        ]
                    )
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
                if isBackendLeaseBypassedTransmitTarget(target) {
                    diagnostics.record(
                        .media,
                        message: "Skipped backend endTransmit for Direct QUIC lease bypass",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "webSocketConnected": String(backend.isWebSocketConnected),
                        ]
                    )
                    await finalizeExplicitTransmitStopLocallyIfNeeded(
                        target: target,
                        source: "explicit-stop-direct-quic-lease-bypass"
                    )
                    directQuicBackendLeaseBypassedContactIDs.remove(target.contactID)
                    directQuicBackendLeaseBypassedRequestsByContactID.removeValue(forKey: target.contactID)
                    await refreshChannelState(for: target.contactID)
                    updateStatusForSelectedContact()
                    return
                }
                diagnostics.record(
                    .media,
                    message: "Ending transmit on backend",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "webSocketConnected": String(backend.isWebSocketConnected),
                    ]
                )
                _ = try await backend.endTransmit(channelId: target.channelID, transmitId: target.transmitID)
                diagnostics.record(
                    .media,
                    message: "Ended transmit on backend",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                    ]
                )
            }
            await finalizeExplicitTransmitStopLocallyIfNeeded(
                target: target,
                source: "explicit-stop-backend-complete"
            )
            await refreshChannelState(for: target.contactID)
        } catch {
            await finalizeExplicitTransmitStopLocallyIfNeeded(
                target: target,
                source: "explicit-stop-backend-failed"
            )
            guard !isExpectedBackendSyncCancellation(error) else {
                await refreshChannelState(for: target.contactID)
                updateStatusForSelectedContact()
                return
            }
            if shouldTreatTransmitStopCleanupAsAlreadyComplete(error) {
                diagnostics.record(
                    .media,
                    level: .notice,
                    message: "Treated transmit stop cleanup failure as already complete",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "error": error.localizedDescription,
                    ]
                )
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
        transmitTaskRuntime.cancelCaptureReassertionTask()
        try? await mediaServices.session()?.stopSendingAudio()

        if isBackendLeaseBypassedTransmitTarget(target) {
            diagnostics.record(
                .media,
                message: "Skipped backend abort for Direct QUIC lease bypass",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                ]
            )
            directQuicBackendLeaseBypassedContactIDs.remove(target.contactID)
            directQuicBackendLeaseBypassedRequestsByContactID.removeValue(forKey: target.contactID)
            await finalizeExplicitTransmitStopLocallyIfNeeded(
                target: target,
                source: "abort-direct-quic-lease-bypass"
            )
            return
        }

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
            _ = try? await backend.endTransmit(channelId: target.channelID, transmitId: target.transmitID)
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
        target: TransmitTarget
    ) async throws -> TurboRenewTransmitResponse {
        guard let backend = backendServices else {
            throw TurboBackendError.invalidConfiguration
        }
        return try await withHTTPTransportFault(route: .renewTransmit) {
            try await backend.renewTransmit(channelId: target.channelID, transmitId: target.transmitID)
        }
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
                let response = try await renewTransmitLeaseOnBackend(target: target)
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
        await transmitCoordinator.handle(.stopCompleted(target))
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
                    reason: .mediaState(state)
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
        let existingMediaContactID = media.contactID()
        let sessionNeedsContactSwitch =
            existingMediaContactID != nil && existingMediaContactID != contactID
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
            closeMediaSession(
                preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
            )
        }

        if sessionNeedsCreation || sessionNeedsContactSwitch || sessionNeedsRecreation {
            let supportsWebSocket = backendServices?.supportsWebSocket == true
            let session = makeDefaultMediaSession(
                supportsWebSocket: supportsWebSocket,
                sendAudioChunk: media.sendAudioChunk(),
                reportEvent: { [weak self] message, metadata in
                    guard let self else { return }
                    await MainActor.run {
                        self.recordTransmitStartupTimingForMediaEvent(
                            message,
                            metadata: metadata
                        )
                        self.recordWakeReceiveTimingForMediaEvent(
                            message,
                            metadata: metadata
                        )
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
            await maybeStartAutomaticDirectQuicProbe(
                for: contactID,
                reason: "media-session-started"
            )
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

    func closeMediaSession(
        deactivateAudioSession: Bool = true,
        preserveDirectQuic: Bool = false
    ) {
        if let contactID = mediaSessionContactID,
           let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
           !preserveDirectQuic {
            cancelDirectQuicPromotionTimeout()
            Task { [weak self] in
                guard let self else { return }
                await self.sendDirectQuicHangup(
                    for: contactID,
                    attempt: attempt,
                    reason: "media-session-closed"
                )
            }
        }
        if preserveDirectQuic {
            diagnostics.record(
                .media,
                message: "Preserving direct QUIC media path during media close",
                metadata: [
                    "contactId": mediaSessionContactID?.uuidString ?? "none",
                    "reason": "system-transmit-handoff",
                ]
            )
        }
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
        mediaServices.reset(shouldDeactivateAudioSession, preserveDirectQuic)
    }
}
