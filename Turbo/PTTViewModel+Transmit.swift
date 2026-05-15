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
    func shouldUseAppManagedWakePlaybackFallback(
        applicationState: UIApplication.State
    ) -> Bool {
        applicationState == .active
    }
}

extension PTTViewModel {
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

        if localReceiverAudioReadinessSessionIsLive(for: contactID) {
            return true
        }

        let projection = selectedPeerProjection(for: contactID)
        guard projection.durableSession == .connected else { return false }
        guard projection.connectedExecution == nil else { return false }
        return true
    }

    func localReceiverAudioReadinessSessionIsLive(for contactID: UUID) -> Bool {
        let localSessionEstablished =
            systemSessionMatches(contactID)
            || (isJoined && activeChannelId == contactID)
        guard localSessionEstablished else { return false }

        guard let channel = selectedChannelSnapshot(for: contactID),
              channel.membership.hasLocalMembership else {
            return false
        }

        switch channel.status {
        case .waitingForPeer, .ready, .transmitting, .receiving:
            return true
        case .requested, .incomingRequest, .idle, nil:
            return false
        }
    }

    func peerIsRoutableForReceiverAudioReadiness(for contactID: UUID) -> Bool {
        guard let channel = selectedChannelSnapshot(for: contactID) else { return false }
        if channel.membership.peerDeviceConnected {
            return true
        }

        if let readiness = channelReadinessByContactID[contactID],
           readiness.peerHasActiveDevice,
           readiness.peerTargetDeviceId != nil,
           readiness.remoteAudioReadiness == .ready {
            return true
        }

        if channel.membership.hasPeerMembership,
           deviceScopedPeerWakeHintIsAvailableForReceiverAudioReadiness(
                channel: channel,
                readiness: channelReadinessByContactID[contactID]
           ) {
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

    func deviceScopedPeerWakeHintIsAvailableForReceiverAudioReadiness(
        channel: ChannelReadinessSnapshot,
        readiness: TurboChannelReadinessResponse?
    ) -> Bool {
        let hasTargetDevice =
            readiness?.peerTargetDeviceId != nil
            || {
                if case .wakeCapable = channel.remoteWakeCapability {
                    return true
                }
                return false
            }()
        guard hasTargetDevice else { return false }

        switch channel.remoteAudioReadiness {
        case .ready, .wakeCapable:
            return true
        case .waiting, .unknown:
            if case .wakeCapable = channel.remoteWakeCapability {
                return true
            }
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
        forceReceiverAudioReadinessRepublishIfBackendHasNotObservedLocalReady(
            for: contactID,
            reason: reason
        )

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

    func forceReceiverAudioReadinessRepublishIfBackendHasNotObservedLocalReady(
        for contactID: UUID,
        reason: ReceiverAudioReadinessReason
    ) {
        guard desiredLocalReceiverAudioReadiness(for: contactID) else { return }
        guard peerIsRoutableForReceiverAudioReadiness(for: contactID) else { return }
        guard let published = localReceiverAudioReadinessPublications[contactID],
              published.isReady,
              published.peerWasRoutable else {
            return
        }
        guard channelReadinessByContactID[contactID]?.localAudioReadiness != .ready else {
            return
        }
        guard let recoveryBasis = reason.recoveryPublicationBasis else {
            return
        }
        guard published.basis != recoveryBasis else {
            return
        }

        controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
        diagnostics.record(
            .websocket,
            message: "Republishing receiver audio readiness because backend has not observed local ready",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason.wireValue,
                "recoveryBasis": String(describing: recoveryBasis),
                "previousBasis": String(describing: published.basis),
                "backendLocalAudioReadiness": String(
                    describing: channelReadinessByContactID[contactID]?.localAudioReadiness ?? .unknown
                ),
                "backendReadiness": channelReadinessByContactID[contactID]?.statusKind ?? "none",
            ]
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
        guard !isPTTAudioSessionActive else {
            diagnostics.record(
                .media,
                message: "Deferred interactive audio prewarm while PTT audio session is active",
                metadata: ["contactId": contactID.uuidString]
            )
            deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
            return
        }

        let startupContext = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
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
            message: "Prewarming foreground media for joined session",
            metadata: ["contactId": contactID.uuidString]
        )
        await ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
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
        foregroundDirectTransmitDelegationsByContactID[target.contactID]?.matches(target) == true
    }

    func directQuicBackendLeaseBypassedRequest(for contactID: UUID) -> TransmitRequestContext? {
        foregroundDirectTransmitDelegationsByContactID[contactID]?.request
    }

    func storeForegroundDirectTransmitDelegation(
        request: TransmitRequestContext,
        target: TransmitTarget,
        reason: String
    ) -> ForegroundDirectTransmitDelegation {
        let delegation = ForegroundDirectTransmitDelegation(
            grantID: UUID().uuidString.lowercased(),
            request: request,
            target: target,
            reason: reason,
            grantedAt: Date()
        )
        foregroundDirectTransmitDelegationsByContactID[target.contactID] = delegation
        return delegation
    }

    func clearForegroundDirectTransmitDelegation(
        for contactID: UUID,
        reason: String
    ) {
        guard let delegation = foregroundDirectTransmitDelegationsByContactID.removeValue(forKey: contactID) else {
            return
        }
        diagnostics.record(
            .media,
            message: "Cleared foreground Direct QUIC transmit delegation",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": delegation.target.channelID,
                "grantId": delegation.grantID,
                "reason": reason,
            ]
        )
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
        guard !hasLocalTransmitStartupOrActiveIntent(for: contactID) else {
            cancelDeferredInteractivePrewarmForLocalTransmitIfNeeded(
                contactID: contactID,
                reason: "local-transmit-active-during-recovery"
            )
            return
        }
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
            return transmitSnapshot.hasTransmitIntent(for: refreshedContactID)
                || (
                    transmitSnapshot.isSystemTransmitting
                    && !transmitSnapshot.explicitStopRequested
                )
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
        refreshedContactID: UUID,
        transmitSnapshot: TransmitDomainSnapshot
    ) -> Bool {
        backendShowsLocalTransmit
            && !transmitSnapshot.explicitStopRequested
            && (
                transmitSnapshot.hasTransmitIntent(for: refreshedContactID)
                || transmitSnapshot.isSystemTransmitting
            )
    }

    func hasActiveTransmitPressIntent() -> Bool {
        !transmitRuntime.explicitStopRequested
            && (transmitRuntime.isPressingTalk || transmitCoordinator.state.isPressingTalk)
    }

    func hasLocalTransmitStartupOrActiveIntent(for contactID: UUID) -> Bool {
        if hasActiveTransmitPressIntent() { return true }
        if isTransmitting || pttCoordinator.state.isTransmitting { return true }
        if transmitCoordinator.state.pendingRequest?.contactID == contactID { return true }
        if transmitCoordinator.state.activeTarget?.contactID == contactID { return true }
        return false
    }

    func cancelDeferredInteractivePrewarmForLocalTransmitIfNeeded(
        contactID: UUID,
        reason: String
    ) {
        guard mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID else {
            return
        }
        _ = mediaRuntime.takePendingInteractivePrewarmAfterAudioDeactivationContactID()
        mediaRuntime.replaceInteractivePrewarmRecoveryTask(with: nil)
        diagnostics.record(
            .media,
            message: "Cancelled deferred interactive audio prewarm for local transmit",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
            ]
        )
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
        cancelDeferredInteractivePrewarmForLocalTransmitIfNeeded(
            contactID: contact.id,
            reason: "begin-transmit"
        )
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
            if await reassertBackendJoinAfterWakeIfNeeded(for: request.contactID) {
                await refreshChannelState(for: request.contactID)
            }
            try await requestSystemTransmitHandoffIfNeeded(for: request)
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
                let delegation = storeForegroundDirectTransmitDelegation(
                    request: request,
                    target: target,
                    reason: "begin-transmit-lease-bypass"
                )
                diagnostics.record(
                    .media,
                    message: "Started foreground Direct QUIC transmit delegation",
                    metadata: [
                        "contactId": target.contactID.uuidString,
                        "channelId": target.channelID,
                        "targetDeviceId": target.deviceID,
                        "grantId": delegation.grantID,
                        "reason": delegation.reason,
                        "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                    ]
                )
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
                scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
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
                scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
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
                scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
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
                scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
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

    func scheduleBackendTransmitLeaseGrantedAfterReleaseCleanup(
        target: TransmitTarget,
        backend: BackendServices,
        source: String
    ) {
        Task { @MainActor [weak self, backend] in
            await self?.cleanupBackendTransmitLeaseGrantedAfterRelease(
                target: target,
                backend: backend,
                source: source
            )
        }
    }

    func cleanupBackendTransmitLeaseGrantedAfterRelease(
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
        await mediaServices.session()?.abortSendingAudio()
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
        do {
            _ = try await backend.endTransmit(channelId: target.channelID, transmitId: target.transmitID)
            diagnostics.record(
                .media,
                message: "Ended late backend transmit lease after release",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "source": source,
                ]
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to end late backend transmit lease after release",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "source": source,
                    "error": error.localizedDescription,
                ]
            )
        }
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
            let preserveDirectQuic = shouldUseDirectQuicTransport(for: request.contactID)
            let preserveMediaRelay =
                !preserveDirectQuic && shouldPreserveMediaRelayDuringMediaClose(for: request.contactID)
            diagnostics.record(
                .media,
                message: "Closing app-managed media session before system transmit handoff",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "mediaState": String(describing: mediaConnectionState),
                    "deactivateAudioSession": String(deactivateAudioSession),
                    "preserveDirectQuic": String(preserveDirectQuic),
                    "preserveMediaRelay": String(preserveMediaRelay),
                    "startupPolicy": directQuicTransmitStartupPolicy.rawValue,
                ]
            )
            closeMediaSession(
                deactivateAudioSession: deactivateAudioSession,
                preserveDirectQuic: preserveDirectQuic,
                preserveMediaRelay: preserveMediaRelay
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

        _ = configureProvisionalOutgoingAudioRouteIfPossible(
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
        guard await waitForPendingSystemTransmitOutgoingAudioRouteIfNeeded(
            request: request,
            channelUUID: channelUUID,
            trigger: trigger
        ) else {
            diagnostics.record(
                .media,
                message: "Deferred early transmit audio capture until outgoing audio transport is configured",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "channelId": request.backendChannelID,
                    "trigger": trigger,
                ]
            )
            recordFirstTransmitStartupTimingStageIfAbsent(
                "early-audio-capture-deferred-until-outgoing-transport",
                metadata: ["trigger": trigger]
            )
            return
        }
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

    func waitForPendingSystemTransmitOutgoingAudioRouteIfNeeded(
        request: TransmitRequestContext,
        channelUUID: UUID,
        trigger: String,
        timeoutNanoseconds: UInt64 = 200_000_000,
        pollNanoseconds: UInt64 = 20_000_000
    ) async -> Bool {
        if mediaServices.sendAudioChunk() != nil {
            return true
        }
        if let activeTarget = pendingSystemTransmitOutgoingAudioTarget(for: request) {
            configureOutgoingAudioRoute(target: activeTarget)
            if mediaServices.sendAudioChunk() != nil {
                diagnostics.record(
                    .media,
                    message: "Configured outgoing audio route from active transmit target during pending system audio capture",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "channelId": request.backendChannelID,
                        "targetDeviceId": activeTarget.deviceID,
                        "trigger": trigger,
                    ]
                )
                return true
            }
        }

        var waitedNanoseconds: UInt64 = 0
        while waitedNanoseconds < timeoutNanoseconds {
            guard shouldContinuePendingSystemTransmitAudioCapture(
                request: request,
                stage: "outgoing-transport-wait"
            ) else {
                return false
            }

            let sleepNanoseconds = min(pollNanoseconds, timeoutNanoseconds - waitedNanoseconds)
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            waitedNanoseconds += sleepNanoseconds

            if mediaServices.sendAudioChunk() != nil {
                return true
            }
            if let activeTarget = pendingSystemTransmitOutgoingAudioTarget(for: request) {
                configureOutgoingAudioRoute(target: activeTarget)
                if mediaServices.sendAudioChunk() != nil {
                    diagnostics.record(
                        .media,
                        message: "Configured outgoing audio route from active transmit target during pending system audio capture",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "channelUUID": channelUUID.uuidString,
                            "channelId": request.backendChannelID,
                            "targetDeviceId": activeTarget.deviceID,
                            "trigger": trigger,
                            "waitedMilliseconds": String(waitedNanoseconds / 1_000_000),
                        ]
                    )
                    return true
                }
            }
        }

        return mediaServices.sendAudioChunk() != nil
            || configureProvisionalOutgoingAudioRouteIfPossible(
                for: request,
                reason: "post-media-session-start-\(trigger)"
            )
    }

    func pendingSystemTransmitOutgoingAudioTarget(
        for request: TransmitRequestContext
    ) -> TransmitTarget? {
        guard let activeTarget = transmitCoordinator.state.activeTarget else {
            return nil
        }
        guard activeTarget.contactID == request.contactID else { return nil }
        guard activeTarget.channelID == request.backendChannelID else { return nil }
        return activeTarget
    }

    @discardableResult
    func configureProvisionalOutgoingAudioRouteIfPossible(
        for request: TransmitRequestContext,
        reason: String
    ) -> Bool {
        if configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
            for: request,
            reason: reason
        ) {
            return true
        }

        guard let peerDeviceID = directQuicPeerDeviceID(for: request.contactID),
              !peerDeviceID.isEmpty else {
            diagnostics.record(
                .media,
                message: "Skipped provisional outgoing audio route because peer device is unknown",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "reason": reason,
                ]
            )
            return false
        }

        let provisionalTarget = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: peerDeviceID,
            channelID: request.backendChannelID
        )
        configureOutgoingAudioRoute(target: provisionalTarget)
        guard mediaServices.sendAudioChunk() != nil else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to configure provisional outgoing audio route",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "channelId": request.backendChannelID,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                ]
            )
            return false
        }

        diagnostics.record(
            .media,
            message: "Configured provisional outgoing audio route",
            metadata: [
                "contactId": request.contactID.uuidString,
                "channelId": request.backendChannelID,
                "peerDeviceId": peerDeviceID,
                "reason": reason,
                "transport": configuredOutgoingAudioTransportLabel(for: request.contactID),
            ]
        )
        return true
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

}
