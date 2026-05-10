import Foundation
import UIKit

extension PTTViewModel {
    private var defaultDirectQuicPromotionTimeoutMilliseconds: Int { 15_000 }
    private var defaultDirectQuicRetryBackoffMilliseconds: Int { 15_000 }
    private var foregroundDirectQuicPathLostRetryBackoffMilliseconds: Int { 1_000 }
    private var foregroundDirectQuicInitialConnectivityRetryBackoffMilliseconds: Int { 1_000 }
    private var foregroundDirectQuicInitialConnectivityRetryLimit: Int { 2 }
    var directQuicFirstTalkGraceMilliseconds: Int { 5_000 }
    var directQuicAudioFreshnessMilliseconds: Int { 30_000 }
    var directQuicUpgradeRequestThrottleMilliseconds: Int { 5_000 }

    func directQuicAttemptRole(
        localDeviceID: String,
        peerDeviceID: String
    ) -> DirectQuicAttemptRole {
        DirectQuicAttemptRole.resolve(
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID
        )
    }

    func directQuicPeerDeviceID(
        for contactID: UUID,
        fallback: String? = nil
    ) -> String? {
        channelReadinessByContactID[contactID]?.peerTargetDeviceId
            ?? fallback
    }

    func shouldUseDirectQuicTransport(for contactID: UUID) -> Bool {
        guard mediaRuntime.directQuicProbeController != nil else { return false }
        return mediaRuntime.directQuicUpgrade.attempt(for: contactID)?.isDirectActive == true
    }

    func shouldUseDirectQuicAudioTransport(for contactID: UUID) -> Bool {
        guard shouldUseDirectQuicTransport(for: contactID) else { return false }
        let maximumAge = TimeInterval(directQuicAudioFreshnessMilliseconds) / 1_000
        return mediaRuntime.receiverPrewarmRequestIsAcknowledged(
            for: contactID,
            maximumAge: maximumAge
        ) || mediaRuntime.directQuicWarmPongIsFresh(
            for: contactID,
            maximumAge: maximumAge
        )
    }

    func hasActiveBackgroundPTTFlowOwningDirectQuic(for contactID: UUID) -> Bool {
        if isTransmitting || transmitCoordinator.state.isPressingTalk || pttCoordinator.state.isTransmitting {
            return true
        }
        if isPTTAudioSessionActive {
            return true
        }
        if pttWakeRuntime.pendingIncomingPush?.contactID == contactID {
            return true
        }
        if pttWakeRuntime.incomingWakeActivationState(for: contactID) != nil {
            return true
        }
        if remoteTransmittingContactIDs.contains(contactID) {
            return true
        }
        return false
    }

    func shouldRetireIdleDirectQuicForBackgroundTransition(
        for contactID: UUID,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState != .active else { return false }
        guard !shouldPreserveLiveCallForProximityInactiveTransition(
            applicationState: applicationState
        ) else {
            return false
        }
        guard shouldUseDirectQuicTransport(for: contactID) else { return false }
        return !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID)
    }

    @discardableResult
    func retireDirectQuicPath(
        for contactID: UUID,
        reason: String,
        sendHangup: Bool,
        configureActiveRoute: Bool
    ) async -> Bool {
        retireDirectQuicPathImmediately(
            for: contactID,
            reason: reason,
            sendHangup: sendHangup,
            configureActiveRoute: configureActiveRoute
        )
    }

    @discardableResult
    func retireDirectQuicPathImmediately(
        for contactID: UUID,
        reason: String,
        sendHangup: Bool,
        configureActiveRoute: Bool
    ) -> Bool {
        guard let attempt = directQuicAttempt(for: contactID) else {
            return false
        }
        let controller = mediaRuntime.directQuicProbeController

        diagnostics.record(
            .media,
            message: "Retiring Direct QUIC media path",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attempt.attemptId,
                "reason": reason,
                "wasDirectActive": String(attempt.isDirectActive),
            ]
        )

        let didBeginPathClosing = sendHangup && beginDirectQuicPathClosingIfPossible(
            for: contactID,
            attempt: attempt,
            reason: reason,
            controller: controller
        )

        cancelDirectQuicPromotionTimeout()
        mediaRuntime.clearReceiverPrewarmState(for: contactID)
        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: contactID,
            fallbackReason: reason
        )
        applyDirectQuicUpgradeTransition(fallback, for: contactID)
        if !didBeginPathClosing {
            controller?.cancel(reason: reason)
        }
        mediaRuntime.directQuicProbeController = nil

        if configureActiveRoute,
           let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            configureOutgoingAudioRoute(target: activeTarget)
        }

        if sendHangup {
            Task { @MainActor [weak self] in
                await self?.sendDirectQuicHangup(
                    for: contactID,
                    attempt: attempt,
                    reason: reason
                )
            }
        }

        return true
    }

    @discardableResult
    func retireIdleDirectQuicForBackgroundTransitionIfNeeded(
        for contactID: UUID,
        reason: String,
        applicationState: UIApplication.State
    ) async -> Bool {
        guard shouldRetireIdleDirectQuicForBackgroundTransition(
            for: contactID,
            applicationState: applicationState
        ) else {
            return false
        }

        return await retireDirectQuicPath(
            for: contactID,
            reason: reason,
            sendHangup: true,
            configureActiveRoute: false
        )
    }

    func directQuicAttempt(
        for contactID: UUID,
        matching attemptID: String? = nil
    ) -> DirectQuicUpgradeAttempt? {
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            return nil
        }
        guard let attemptID else { return attempt }
        return attempt.attemptId == attemptID ? attempt : nil
    }

    func directQuicExpectedPeerCertificateFingerprint(
        for attempt: DirectQuicUpgradeAttempt
    ) -> String? {
        if let answerFingerprint = attempt.remoteAnswer?.certificateFingerprint,
           !answerFingerprint.isEmpty {
            return answerFingerprint
        }
        if let offerFingerprint = attempt.remoteOffer?.certificateFingerprint,
           !offerFingerprint.isEmpty {
            return offerFingerprint
        }
        return nil
    }

    func directQuicCandidateBatchToProbe(
        for attempt: DirectQuicUpgradeAttempt,
        payload: TurboDirectQuicCandidatePayload
    ) -> [TurboDirectQuicCandidate] {
        if let candidate = payload.candidate {
            return [candidate]
        }
        if payload.endOfCandidates {
            return attempt.remoteCandidates
        }
        return []
    }

    func directQuicProbeController() -> DirectQuicProbeController {
        if let existing = mediaRuntime.directQuicProbeController {
            return existing
        }
        let controller = DirectQuicProbeController(
            reportEvent: { [weak self] message, metadata in
                guard let self else { return }
                await MainActor.run {
                    self.diagnostics.record(.media, message: message, metadata: metadata)
                }
            }
        )
        mediaRuntime.directQuicProbeController = controller
        return controller
    }

    func directQuicPromotionTimeoutMilliseconds() -> Int {
        let configured = backendServices?.directQuicPolicy?.promotionTimeoutMs
            ?? defaultDirectQuicPromotionTimeoutMilliseconds
        return max(configured, defaultDirectQuicPromotionTimeoutMilliseconds, 250)
    }

    func directQuicRetryBackoffMilliseconds() -> Int {
        let configured = backendServices?.directQuicPolicy?.retryBackoffMs
            ?? defaultDirectQuicRetryBackoffMilliseconds
        return max(configured, 0)
    }

    func directQuicRetryBackoffRequest(
        reason: String,
        attemptID: String? = nil,
        preferredMilliseconds: Int? = nil,
        priorFailureCount: Int = 0
    ) -> DirectQuicRetryBackoffRequest? {
        let baseMilliseconds = directQuicRetryBackoffMilliseconds()
        let category = DirectQuicRetryBackoffPolicy.category(for: reason)
        let resolvedMilliseconds = DirectQuicRetryBackoffPolicy.milliseconds(
            baseMilliseconds: baseMilliseconds,
            category: category,
            priorFailureCount: priorFailureCount
        )
        let milliseconds = preferredMilliseconds.map { min(max($0, 0), resolvedMilliseconds) }
            ?? resolvedMilliseconds
        guard milliseconds > 0 else { return nil }
        return DirectQuicRetryBackoffRequest(
            milliseconds: milliseconds,
            reason: reason,
            category: category,
            attemptId: attemptID
        )
    }

    func directQuicPathLostRetryBackoffRequest(
        for contactID: UUID,
        reason: String,
        attemptID: String
    ) -> DirectQuicRetryBackoffRequest? {
        let isActiveTransmitPath = transmitProjection.activeTarget?.contactID == contactID
        let isForegroundSelectedPath =
            currentApplicationState() == .active
            && selectedContactId == contactID
        let preferredMilliseconds =
            (isActiveTransmitPath || isForegroundSelectedPath)
            ? foregroundDirectQuicPathLostRetryBackoffMilliseconds
            : nil
        return directQuicRetryBackoffRequest(
            reason: reason,
            attemptID: attemptID,
            preferredMilliseconds: preferredMilliseconds
        )
    }

    func directQuicPromotionRetryBackoffRequest(
        for contactID: UUID,
        reason: String,
        attemptID: String?
    ) -> DirectQuicRetryBackoffRequest? {
        let isForegroundSelectedPath =
            currentApplicationState() == .active
            && selectedContactId == contactID
        let category = DirectQuicRetryBackoffPolicy.category(for: reason)
        let isConnectivityFailure =
            category == .connectivity
        let priorFailureCount =
            isConnectivityFailure
            ? max(
                mediaRuntime.directQuicUpgrade.retryFailureCount(
                    for: contactID,
                    category: .connectivity
                ) - (isForegroundSelectedPath ? foregroundDirectQuicInitialConnectivityRetryLimit : 0),
                0
            )
            : mediaRuntime.directQuicUpgrade.retryFailureCount(
                for: contactID,
                category: category
            )
        let fastRetryNumber =
            (isForegroundSelectedPath && isConnectivityFailure)
            ? mediaRuntime.directQuicUpgrade.consumeFastConnectivityRetry(
                for: contactID,
                maxAttempts: foregroundDirectQuicInitialConnectivityRetryLimit
            )
            : nil
        let preferredMilliseconds = fastRetryNumber == nil
            ? nil
            : foregroundDirectQuicInitialConnectivityRetryBackoffMilliseconds
        if let fastRetryNumber {
            diagnostics.record(
                .media,
                message: "Using fast direct QUIC promotion retry",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "attemptId": attemptID ?? "",
                    "fastRetryNumber": String(fastRetryNumber),
                    "fastRetryLimit": String(foregroundDirectQuicInitialConnectivityRetryLimit),
                    "retryBackoffMs": String(foregroundDirectQuicInitialConnectivityRetryBackoffMilliseconds),
                ]
            )
        }
        return directQuicRetryBackoffRequest(
            reason: reason,
            attemptID: attemptID,
            preferredMilliseconds: preferredMilliseconds,
            priorFailureCount: priorFailureCount
        )
    }

    func directQuicStunServers() -> [TurboDirectQuicStunServer] {
        backendServices?.directQuicPolicy?.effectiveStunServers ?? []
    }

    func preferredDirectQuicIdentityLabel() -> String {
        DirectQuicIdentityConfiguration.preferredLabel(
            deviceID: backendServices?.deviceID,
            fallbackHandle: currentIdentityHandle
        )
    }

    func provisionDirectQuicProductionIdentityForRegistration(
        deviceID: String
    ) -> DirectQuicIdentityRegistrationMetadata? {
        let label = DirectQuicIdentityConfiguration.preferredLabel(
            deviceID: deviceID,
            fallbackHandle: currentIdentityHandle
        )
        directQuicProvisioningStatus = "provisioning"
        do {
            let identity = try DirectQuicIdentityConfiguration.provisionProductionIdentity(
                label: label,
                deviceID: deviceID
            )
            directQuicProvisioningStatus = "ready"
            directQuicRegisteredFingerprint = identity.certificateFingerprint
            diagnostics.record(
                .media,
                message: "Direct QUIC production identity provisioned",
                metadata: [
                    "label": label,
                    "fingerprint": identity.certificateFingerprint,
                    "source": identity.source.rawValue,
                ]
            )
            return DirectQuicIdentityRegistrationMetadata(
                fingerprint: identity.certificateFingerprint
            )
        } catch {
            directQuicProvisioningStatus = "failed"
            let statusAfterFailure = DirectQuicIdentityConfiguration.status()
            pendingDirectQuicIdentityProvisioningFailureTelemetry = [
                "label": label,
                "deviceId": deviceID,
                "error": error.localizedDescription,
                "identityStatus": statusAfterFailure.diagnosticsText,
                "identitySource": statusAfterFailure.source.rawValue,
                "fingerprint": statusAfterFailure.fingerprint ?? "none",
                "provisioningStatus": directQuicProvisioningStatus,
            ]
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC production identity provisioning failed",
                metadata: [
                    "label": label,
                    "deviceId": deviceID,
                    "error": error.localizedDescription,
                    "identityStatus": statusAfterFailure.diagnosticsText,
                    "identitySource": statusAfterFailure.source.rawValue,
                ]
            )
            flushPendingDirectQuicIdentityProvisioningFailureTelemetry(reason: "provisioning-failed")
            return nil
        }
    }

    func currentDirectQuicIdentityRegistrationMetadata() -> DirectQuicIdentityRegistrationMetadata? {
        let label = preferredDirectQuicIdentityLabel()
        return DirectQuicIdentityConfiguration.productionIdentityRegistrationMetadata(label: label)
    }

    func repairDirectQuicProductionIdentityRegistrationIfPossible(
        contactID: UUID,
        channelID: String,
        reason: String
    ) async -> Bool {
        guard let backend = backendServices else { return false }
        let status = DirectQuicIdentityConfiguration.status()
        if status.source == .production,
           let fingerprint = status.fingerprint,
           fingerprint == directQuicRegisteredFingerprint || directQuicRegisteredFingerprint == nil {
            return true
        }
        guard !directQuicIdentityRepairAttemptedDeviceIDs.contains(backend.deviceID) else {
            return false
        }
        directQuicIdentityRepairAttemptedDeviceIDs.insert(backend.deviceID)
        diagnostics.record(
            .media,
            message: "Repairing Direct QUIC production identity registration",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "deviceId": backend.deviceID,
                "reason": reason,
                "identityStatus": status.diagnosticsText,
                "provisioningStatus": directQuicProvisioningStatus,
                "registeredFingerprint": directQuicRegisteredFingerprint ?? "none",
            ]
        )
        guard let identity = provisionDirectQuicProductionIdentityForRegistration(
            deviceID: backend.deviceID
        ) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC production identity repair failed during provisioning",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "deviceId": backend.deviceID,
                    "reason": reason,
                ]
            )
            return false
        }
        do {
            _ = try await backend.registerDevice(
                label: UIDevice.current.name,
                alertPushToken: alertPushTokenHex.isEmpty ? nil : alertPushTokenHex,
                alertPushEnvironment: alertPushTokenHex.isEmpty
                    ? nil
                    : TurboAPNSEnvironmentResolver.current(),
                directQuicIdentity: identity,
                mediaEncryptionIdentity: currentMediaEncryptionIdentityRegistrationMetadata()
            )
            directQuicRegisteredFingerprint = identity.fingerprint
            diagnostics.record(
                .media,
                message: "Direct QUIC production identity registration repaired",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "deviceId": backend.deviceID,
                    "fingerprint": identity.fingerprint,
                    "reason": reason,
                ]
            )
            await refreshContactSummaries()
            return true
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC production identity repair registration failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "deviceId": backend.deviceID,
                    "fingerprint": identity.fingerprint,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    func backendPeerDirectQuicFingerprint(for contactID: UUID) -> String? {
        channelReadinessByContactID[contactID]?.peerDirectQuicFingerprint
    }

    func directQuicProductionSignalAuthorizationFailure(
        signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) -> String? {
        if case .offer(let payload) = signal,
           payload.debugBypass == true,
           developerIdentityControlsEnabled {
            return nil
        }
        guard effectiveDirectQuicUpgradeEnabled else {
            return nil
        }
        let signaledFingerprint: String? = {
            switch signal {
            case .offer(let payload):
                return payload.certificateFingerprint
            case .answer(let payload):
                return payload.certificateFingerprint
            case .candidate, .hangup:
                return nil
            }
        }()
        guard let signaledFingerprint else { return nil }
        guard let normalizedSignaled = DirectQuicProductionIdentityManager.normalizedFingerprint(signaledFingerprint) else {
            return "invalid-signaled-peer-fingerprint"
        }
        guard let backendFingerprint = backendPeerDirectQuicFingerprint(for: contactID) else {
            return "backend-peer-fingerprint-missing"
        }
        guard normalizedSignaled == backendFingerprint else {
            return "backend-peer-fingerprint-mismatch"
        }
        guard envelope.fromDeviceId == directQuicPeerDeviceID(for: contactID, fallback: envelope.fromDeviceId) else {
            return "peer-device-id-mismatch"
        }
        return nil
    }

    func cancelDirectQuicPromotionTimeout() {
        mediaRuntime.replaceDirectQuicPromotionTimeoutTask(with: nil)
    }

    func cancelDirectQuicAutoProbe() {
        mediaRuntime.replaceDirectQuicAutoProbeTask(with: nil)
    }

    func shouldAllowDirectQuicDebugBypassForAutomaticProbe() -> Bool {
        developerIdentityControlsEnabled && !backendAdvertisesDirectQuicUpgrade
    }

    func automaticDirectQuicProbeBlockReason(for contactID: UUID) -> String? {
        if isDirectPathRelayOnlyForced {
            return "relay-only-forced"
        }
        if isDirectQuicAutoUpgradeDisabledForDebug {
            return "auto-upgrade-disabled"
        }
        if backendRuntime.signalingJoinRecoveryTask != nil {
            return "signaling-join-recovery-active"
        }
        if sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
            return "leave-in-flight"
        }
        if !backendAdvertisesDirectQuicUpgrade,
           !shouldAllowDirectQuicDebugBypassForAutomaticProbe() {
            return "backend-capability-disabled"
        }
        if currentApplicationState() != .active,
           !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) {
            return "background-idle"
        }
        guard let backend = backendServices else {
            return "backend-unavailable"
        }
        guard selectedContactId == contactID else {
            return "not-selected-contact"
        }
        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            return "contact-missing"
        }
        guard contact.backendChannelId != nil,
              contact.remoteUserId != nil else {
            return "channel-metadata-missing"
        }
        guard mediaRuntime.directQuicUpgrade.attempt(for: contactID) == nil else {
            return "attempt-active"
        }
        guard mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID) == nil else {
            return "retry-backoff"
        }
        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            return "peer-device-missing"
        }
        guard directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
        ) == .listenerOfferer else {
            return "not-listener-offerer"
        }
        guard systemSessionMatches(contactID),
              isJoined,
              activeChannelId == contactID else {
            return "local-session-not-aligned"
        }
        guard let channel = selectedChannelSnapshot(for: contactID) else {
            return "channel-snapshot-missing"
        }
        guard case .both(let peerDeviceConnected) = channel.membership,
              peerDeviceConnected else {
            return "peer-device-not-connected"
        }
        guard channel.canTransmit,
              channel.readinessStatus == .ready else {
            return "channel-not-ready"
        }
        return nil
    }

    func shouldRequestAutomaticDirectQuicProbe(for contactID: UUID) -> Bool {
        automaticDirectQuicProbeBlockReason(for: contactID) == nil
    }

    func directQuicFirstTalkWarmupBlockReason(for contactID: UUID) -> String? {
        if isDirectPathRelayOnlyForced {
            return "relay-only-forced"
        }
        if isDirectQuicAutoUpgradeDisabledForDebug {
            return "auto-upgrade-disabled"
        }
        if currentApplicationState() != .active,
           !hasActiveBackgroundPTTFlowOwningDirectQuic(for: contactID) {
            return "background-idle"
        }
        let existingAttempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID)
        if existingAttempt == nil,
           !backendAdvertisesDirectQuicUpgrade {
            return "backend-capability-disabled"
        }
        guard let backend = backendServices else {
            return "backend-unavailable"
        }
        guard selectedContactId == contactID else {
            return "not-selected-contact"
        }
        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            return "contact-missing"
        }
        guard contact.backendChannelId != nil,
              contact.remoteUserId != nil else {
            return "channel-metadata-missing"
        }
        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            return "peer-device-missing"
        }
        if existingAttempt == nil,
           directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
           ) != .listenerOfferer {
            return "not-listener-offerer"
        }
        guard systemSessionMatches(contactID),
              isJoined,
              activeChannelId == contactID else {
            return "local-session-not-aligned"
        }
        guard let channel = selectedChannelSnapshot(for: contactID) else {
            return "channel-snapshot-missing"
        }
        guard case .both(let peerDeviceConnected) = channel.membership,
              peerDeviceConnected else {
            return "peer-device-not-connected"
        }
        guard channel.canTransmit,
              channel.readinessStatus == .ready else {
            return "channel-not-ready"
        }
        if existingAttempt != nil {
            return nil
        }
        if !shouldAllowDirectQuicDebugBypassForAutomaticProbe() {
            let localIdentityStatus = DirectQuicIdentityConfiguration.status()
            guard localIdentityStatus.source == .production,
                  let localFingerprint = localIdentityStatus.fingerprint,
                  localFingerprint == directQuicRegisteredFingerprint
                    || directQuicRegisteredFingerprint == nil else {
                return "identity-unavailable"
            }
            guard backendPeerDirectQuicFingerprint(for: contactID) != nil else {
                return "peer-identity-missing"
            }
        }
        if let retryBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID) {
            let isFastConnectivityRetry =
                retryBackoff.category == .connectivity
                && retryBackoff.milliseconds <= foregroundDirectQuicInitialConnectivityRetryBackoffMilliseconds
            return isFastConnectivityRetry ? nil : "retry-backoff"
        }
        return nil
    }

    func maybeStartAutomaticDirectQuicProbe(
        for contactID: UUID,
        reason: String
    ) async {
        if let blockReason = automaticDirectQuicProbeBlockReason(for: contactID) {
            diagnostics.record(
                .media,
                message: "Automatic Direct QUIC probe skipped",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": blockReason,
                    "debugBypass": String(shouldAllowDirectQuicDebugBypassForAutomaticProbe()),
                ]
            )
            if blockReason == "not-listener-offerer" {
                await requestRemoteDirectQuicOfferIfPossible(
                    for: contactID,
                    reason: reason
                )
            }
            return
        }

        diagnostics.record(
            .media,
            message: "Automatic Direct QUIC probe requested",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
                "debugBypass": String(shouldAllowDirectQuicDebugBypassForAutomaticProbe()),
            ]
        )
        await maybeStartDirectQuicProbe(
            for: contactID,
            allowDebugBypassWithoutBackendAdvertisement: shouldAllowDirectQuicDebugBypassForAutomaticProbe()
        )
    }

    func requestRemoteDirectQuicOfferIfPossible(
        for contactID: UUID,
        reason: String
    ) async {
        guard backendAdvertisesDirectQuicUpgrade else {
            diagnostics.record(
                .websocket,
                message: "Direct QUIC upgrade request skipped because backend capability is disabled",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        let throttleInterval = TimeInterval(directQuicUpgradeRequestThrottleMilliseconds) / 1_000
        guard mediaRuntime.shouldSendDirectQuicUpgradeRequest(
            for: contactID,
            minimumInterval: throttleInterval
        ) else {
            diagnostics.record(
                .media,
                message: "Direct QUIC upgrade request throttled",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "throttleMs": "\(directQuicUpgradeRequestThrottleMilliseconds)",
                ]
            )
            return
        }
        guard let backend = backendServices, backend.supportsWebSocket else {
            diagnostics.record(
                .websocket,
                message: "Direct QUIC upgrade request skipped because websocket is unavailable",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            diagnostics.record(
                .websocket,
                message: "Direct QUIC upgrade request skipped because peer routing metadata is missing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        guard directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
        ) == .dialerAnswerer else {
            return
        }

        let payload = TurboDirectQuicUpgradeRequestPayload(
            requestId: UUID().uuidString.lowercased(),
            channelId: channelID,
            fromDeviceId: backend.deviceID,
            toDeviceId: peerDeviceID,
            reason: reason,
            roleIntent: .listener,
            debugBypass: false
        )

        do {
            let envelope = try TurboSignalEnvelope.directQuicUpgradeRequest(
                channelId: channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: payload
            )
            try await backend.sendSignal(envelope)
            mediaRuntime.markDirectQuicUpgradeRequestSent(for: contactID)
            diagnostics.record(
                .websocket,
                message: "Direct QUIC upgrade request sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "requestId": payload.requestId,
                    "reason": reason,
                    "localRole": DirectQuicAttemptRole.dialerAnswerer.rawValue,
                    "peerDeviceId": peerDeviceID,
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC upgrade request send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "reason": reason,
                    "peerDeviceId": peerDeviceID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func scheduleAutomaticDirectQuicProbe(
        for contactID: UUID,
        reason: String
    ) {
        if isDirectQuicAutoUpgradeDisabledForDebug {
            diagnostics.record(
                .media,
                message: "Automatic Direct QUIC reprobe not scheduled",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": "auto-upgrade-disabled",
                ]
            )
            return
        }

        let retryRemainingMilliseconds = mediaRuntime.directQuicUpgrade
            .retryBackoffRemaining(for: contactID)
            .map { max(Int($0 * 1_000), 0) } ?? 0
        let delayMilliseconds = max(retryRemainingMilliseconds, 250)

        mediaRuntime.replaceDirectQuicAutoProbeTask(with: Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.maybeStartAutomaticDirectQuicProbe(
                for: contactID,
                reason: "\(reason)-scheduled"
            )
            await MainActor.run {
                self.mediaRuntime.directQuicAutoProbeTask = nil
            }
        })

        diagnostics.record(
            .media,
            message: "Scheduled automatic Direct QUIC reprobe",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
                "delayMilliseconds": "\(delayMilliseconds)",
            ]
        )
    }

    func importDirectQuicIdentityForDebug(
        from fileURL: URL,
        password: String
    ) async {
        let resolvedLabel = preferredDirectQuicIdentityLabel()
        let didAccessSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let pkcs12Data = try Data(contentsOf: fileURL)
            try DirectQuicIdentityConfiguration.importPKCS12Identity(
                data: pkcs12Data,
                password: password,
                label: resolvedLabel
            )
            DirectQuicIdentityConfiguration.setResolvedLabel(resolvedLabel)
            diagnostics.record(
                .media,
                message: "Direct QUIC identity imported from diagnostics",
                metadata: [
                    "file": fileURL.lastPathComponent,
                    "label": resolvedLabel,
                    "selectedContact": selectedContact?.handle ?? "none",
                ]
            )
            statusMessage = "Direct QUIC identity imported"
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC identity import failed",
                metadata: [
                    "file": fileURL.lastPathComponent,
                    "label": resolvedLabel,
                    "error": error.localizedDescription,
                ]
            )
            statusMessage = error.localizedDescription
        }

        captureDiagnosticsState("direct-quic:identity-import")
    }

    func adoptInstalledDirectQuicIdentityForDebug() {
        let resolvedLabel = preferredDirectQuicIdentityLabel()

        do {
            let fingerprint = try DirectQuicIdentityConfiguration.adoptInstalledIdentity(
                label: resolvedLabel
            )
            diagnostics.record(
                .media,
                message: "Direct QUIC installed identity adopted from diagnostics",
                metadata: [
                    "label": resolvedLabel,
                    "fingerprint": fingerprint,
                    "installedIdentityCount": String(
                        DirectQuicIdentityConfiguration.installedIdentityCount()
                    ),
                ]
            )
            statusMessage = "Direct QUIC installed identity adopted"
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC installed identity adoption failed",
                metadata: [
                    "label": resolvedLabel,
                    "error": error.localizedDescription,
                    "installedIdentityCount": String(
                        DirectQuicIdentityConfiguration.installedIdentityCount()
                    ),
                ]
            )
            statusMessage = error.localizedDescription
        }

        captureDiagnosticsState("direct-quic:identity-adopt-installed")
    }

    func setDirectPathRelayOnlyForcedForDebug(_ isForced: Bool) async {
        let previousValue = isDirectPathRelayOnlyForced
        TurboDirectPathDebugOverride.setRelayOnlyForced(isForced)

        diagnostics.record(
            .media,
            message: "Direct QUIC relay-only override updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isForced),
            ]
        )

        if isForced {
            await cancelSelectedDirectQuicAttemptForDebug(reason: "debug-force-relay-only")
        }

        statusMessage = isForced
            ? "Direct path upgrade disabled for debugging"
            : "Direct path upgrade enabled"
        captureDiagnosticsState("direct-quic:debug-relay-only")
    }

    func setDirectQuicAutoUpgradeDisabledForDebug(_ isDisabled: Bool) async {
        let previousValue = isDirectQuicAutoUpgradeDisabledForDebug
        TurboDirectPathDebugOverride.setAutoUpgradeDisabled(isDisabled)

        diagnostics.record(
            .media,
            message: "Direct QUIC auto-upgrade override updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isDisabled),
            ]
        )

        if isDisabled {
            cancelDirectQuicAutoProbe()
        }

        statusMessage = isDisabled
            ? "Direct path auto-upgrade disabled"
            : "Direct path auto-upgrade enabled"
        captureDiagnosticsState("direct-quic:debug-auto-upgrade")
    }

    func setDirectQuicTransmitStartupPolicyForDebug(
        _ policy: DirectQuicTransmitStartupPolicy
    ) {
        let previousValue = directQuicTransmitStartupPolicy
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(policy)

        diagnostics.record(
            .media,
            message: "Direct QUIC transmit startup policy updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": previousValue.rawValue,
                "newValue": policy.rawValue,
            ]
        )
        statusMessage = policy == .appleGated
            ? "Direct transmit waits for Apple PTT"
            : "Direct transmit starts speculatively in foreground"
        captureDiagnosticsState("direct-quic:debug-transmit-startup-policy")
    }

    func forceSelectedDirectQuicProbeForDebug() async {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC debug probe skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-force-probe:no-selection")
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC debug probe requested",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "relayOnlyOverride": String(isDirectPathRelayOnlyForced),
                "backendAdvertised": String(backendAdvertisesDirectQuicUpgrade),
                "directQuicEnabled": String(effectiveDirectQuicUpgradeEnabled),
                "existingAttempt": String(
                    mediaRuntime.directQuicUpgrade.attempt(for: selectedContact.id) != nil
                ),
            ]
        )
        captureDiagnosticsState("direct-quic:debug-force-probe:requested")
        await maybeStartDirectQuicProbe(
            for: selectedContact.id,
            allowDebugBypassWithoutBackendAdvertisement: true
        )
        captureDiagnosticsState("direct-quic:debug-force-probe:completed")
    }

    func clearSelectedDirectQuicRetryBackoffForDebug() {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC retry backoff clear skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-clear-backoff:no-selection")
            return
        }

        let previousBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: selectedContact.id)
        mediaRuntime.directQuicUpgrade.clearRetryBackoff(for: selectedContact.id)
        diagnostics.record(
            .media,
            message: previousBackoff == nil
                ? "Direct QUIC retry backoff was already clear"
                : "Direct QUIC retry backoff cleared from diagnostics",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "previousReason": previousBackoff?.reason ?? "none",
                "previousCategory": previousBackoff?.category.rawValue ?? "none",
                "previousAttemptId": previousBackoff?.attemptId ?? "none",
                "previousBackoffMs": previousBackoff.map { String($0.milliseconds) } ?? "none",
            ]
        )
        captureDiagnosticsState("direct-quic:debug-clear-backoff")
    }

    func cancelSelectedDirectQuicAttemptForDebug(
        reason: String = "debug-cancel"
    ) async {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC debug cancel skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-cancel:no-selection")
            return
        }
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: selectedContact.id) else {
            diagnostics.record(
                .media,
                message: "Direct QUIC debug cancel skipped because there is no active attempt",
                metadata: [
                    "contactId": selectedContact.id.uuidString,
                    "handle": selectedContact.handle,
                    "reason": reason,
                ]
            )
            captureDiagnosticsState("direct-quic:debug-cancel:no-attempt")
            return
        }

        cancelDirectQuicPromotionTimeout()
        await sendDirectQuicHangup(
            for: selectedContact.id,
            attempt: attempt,
            reason: reason
        )
        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: selectedContact.id,
            fallbackReason: reason,
            retryBackoff: nil
        )
        applyDirectQuicUpgradeTransition(fallback, for: selectedContact.id)
        mediaRuntime.directQuicProbeController?.cancel(reason: reason)
        mediaRuntime.directQuicProbeController = nil
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == selectedContact.id {
            configureOutgoingAudioRoute(target: activeTarget)
        }
        diagnostics.record(
            .media,
            message: "Direct QUIC attempt cancelled from diagnostics",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "attemptId": attempt.attemptId,
                "reason": reason,
                "wasDirectActive": String(attempt.isDirectActive),
            ]
        )
        captureDiagnosticsState("direct-quic:debug-cancel")
    }

    func scheduleDirectQuicPromotionTimeout(
        contactID: UUID,
        attemptID: String
    ) {
        let timeoutMilliseconds = directQuicPromotionTimeoutMilliseconds()
        mediaRuntime.replaceDirectQuicPromotionTimeoutTask(with: Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.handleDirectQuicPromotionTimeout(
                contactID: contactID,
                attemptID: attemptID,
                timeoutMilliseconds: timeoutMilliseconds
            )
        })
    }

    func handleDirectQuicPromotionTimeout(
        contactID: UUID,
        attemptID: String,
        timeoutMilliseconds: Int
    ) async {
        guard let activeAttempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
              activeAttempt.attemptId == attemptID else {
            return
        }
        let elapsedSinceProgressMilliseconds = Int(Date().timeIntervalSince(activeAttempt.lastUpdatedAt) * 1_000)
        if elapsedSinceProgressMilliseconds < max(timeoutMilliseconds - 250, 0) {
            diagnostics.record(
                .media,
                message: "Direct QUIC promotion timeout extended after recent progress",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": activeAttempt.channelID,
                    "attemptId": attemptID,
                    "timeoutMilliseconds": "\(timeoutMilliseconds)",
                    "elapsedSinceProgressMilliseconds": "\(elapsedSinceProgressMilliseconds)",
                ]
            )
            scheduleDirectQuicPromotionTimeout(contactID: contactID, attemptID: attemptID)
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC promotion timed out",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": activeAttempt.channelID,
                "attemptId": attemptID,
                "timeoutMilliseconds": "\(timeoutMilliseconds)",
            ]
        )
        await finishDirectQuicAttempt(
            for: contactID,
            reason: "promotion-timeout",
            sendHangup: true,
            applyRetryBackoff: true
        )
    }

    func finishDirectQuicAttempt(
        for contactID: UUID,
        reason: String,
        sendHangup: Bool,
        applyRetryBackoff: Bool
    ) async {
        cancelDirectQuicPromotionTimeout()

        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            mediaRuntime.directQuicProbeController?.cancel(reason: reason)
            mediaRuntime.directQuicProbeController = nil
            return
        }

        if sendHangup {
            await sendDirectQuicHangup(
                for: contactID,
                attempt: attempt,
                reason: reason
            )
        }

        let retryBackoff = applyRetryBackoff
            ? directQuicPromotionRetryBackoffRequest(
                for: contactID,
                reason: reason,
                attemptID: attempt.attemptId
            )
            : nil

        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: contactID,
            fallbackReason: reason,
            retryBackoff: retryBackoff
        )
        applyDirectQuicUpgradeTransition(fallback, for: contactID)
        mediaRuntime.directQuicProbeController?.cancel(reason: reason)
        mediaRuntime.directQuicProbeController = nil
        if retryBackoff?.category == .connectivity {
            scheduleAutomaticDirectQuicProbe(
                for: contactID,
                reason: reason
            )
        }
    }

    func activateDirectQuicMediaPath(
        for contactID: UUID,
        attemptID: String
    ) async {
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID) else {
            return
        }
        guard let controller = mediaRuntime.directQuicProbeController else { return }
        guard let nominatedPath = controller.nominatedPath(matching: attemptID) else {
            diagnostics.record(
                .media,
                message: "Direct QUIC activation deferred because no nominated path is available yet",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                ]
            )
            return
        }

        do {
            try await controller.activateMediaTransport(
                onIncomingAudioPayload: { [weak self] payload in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleIncomingDirectQuicAudioPayload(
                            payload,
                            contactID: contactID,
                            attemptID: attemptID
                        )
                    }
                },
                onReceiverPrewarmRequest: { [weak self] payload in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleIncomingDirectQuicReceiverPrewarmRequest(
                            payload,
                            contactID: contactID,
                            attemptID: attemptID
                        )
                    }
                },
                onReceiverPrewarmAck: { [weak self] payload in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.handleDirectQuicReceiverPrewarmAck(
                            payload,
                            contactID: contactID,
                            attemptID: attemptID
                        )
                    }
                },
                onPathClosing: { [weak self] payload in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleIncomingDirectQuicPathClosing(
                            payload,
                            contactID: contactID,
                            attemptID: attemptID
                        )
                    }
                },
                onWarmPong: { [weak self] pingID in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.handleDirectQuicWarmPong(
                            pingID,
                            contactID: contactID,
                            attemptID: attemptID
                        )
                    }
                },
                onPathLost: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleDirectQuicMediaPathLost(
                            for: contactID,
                            attemptID: attemptID,
                            reason: reason
                        )
                    }
                }
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to activate direct QUIC media path",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "activation-failed",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        guard let transition = mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: attemptID,
            nominatedPath: nominatedPath
        ) else {
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC media path activated",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attemptID,
                "nominatedPathSource": nominatedPath.source.rawValue,
                "nominatedRemoteAddress": nominatedPath.remoteAddress,
                "nominatedRemotePort": "\(nominatedPath.remotePort)",
                "nominatedRemoteCandidateKind": nominatedPath.remoteCandidateKind?.rawValue ?? "observed",
            ]
        )
        cancelDirectQuicPromotionTimeout()
        cancelDirectQuicAutoProbe()
        mediaRuntime.clearFirstTalkDirectQuicGrace(for: contactID)
        applyDirectQuicUpgradeTransition(transition, for: contactID)
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            configureOutgoingAudioRoute(target: activeTarget)
        }
        await requestReceiverPrewarmForFirstTalk(
            for: contactID,
            reason: "direct-quic-activated"
        )
    }

    func requestReceiverPrewarmForFirstTalk(
        for contactID: UUID,
        reason: String
    ) async {
        if mediaRuntime.hasReceiverPrewarmRequest(for: contactID),
           mediaRuntime.receiverPrewarmRequestIsAcknowledged(for: contactID) {
            diagnostics.record(
                .media,
                message: "Skipping duplicate Direct QUIC receiver prewarm request",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "acknowledged": String(mediaRuntime.receiverPrewarmRequestIsAcknowledged(for: contactID)),
                ]
            )
            return
        }

        if shouldUseDirectQuicTransport(for: contactID),
           await sendDirectQuicReceiverPrewarmRequest(for: contactID, reason: reason) {
            await sendDirectQuicWarmPingIfPossible(for: contactID, reason: reason)
            return
        }

        await syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: .receiverPrewarmRequest
        )
    }

    @discardableResult
    func sendDirectQuicReceiverPrewarmRequest(
        for contactID: UUID,
        reason: String,
        requestID: String? = nil,
        recordOutboundRequestID: Bool = false
    ) async -> Bool {
        guard let backend = backendServices,
              let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId,
              let attempt = directQuicAttempt(for: contactID),
              attempt.isDirectActive,
              let controller = mediaRuntime.directQuicProbeController else {
            return false
        }

        let requestID = requestID ?? mediaRuntime.receiverPrewarmRequestID(for: contactID)
        if recordOutboundRequestID {
            mediaRuntime.replaceReceiverPrewarmRequestID(
                for: contactID,
                requestID: requestID
            )
        }
        let payload = DirectQuicReceiverPrewarmPayload(
            requestId: requestID,
            channelId: channelID,
            fromDeviceId: backend.deviceID,
            reason: reason,
            directQuicAttemptId: attempt.attemptId
        )

        do {
            try await controller.sendReceiverPrewarmRequest(payload)
            diagnostics.record(
                .media,
                message: "Direct QUIC receiver prewarm request sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attempt.attemptId,
                    "requestId": requestID,
                    "reason": reason,
                ]
            )
            return true
        } catch {
            mediaRuntime.clearReceiverPrewarmState(for: contactID)
            diagnostics.record(
                .media,
                message: "Direct QUIC receiver prewarm request failed; using relay readiness fallback",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attempt.attemptId,
                    "requestId": requestID,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    @discardableResult
    func beginDirectQuicPathClosingIfPossible(
        for contactID: UUID,
        attempt: DirectQuicUpgradeAttempt,
        reason: String,
        controller: DirectQuicProbeController?
    ) -> Bool {
        guard attempt.isDirectActive,
              let controller else {
            return false
        }

        let payload = DirectQuicPathClosingPayload(
            attemptId: attempt.attemptId,
            reason: reason
        )

        controller.beginIntentionalPathClose(
            payload,
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attempt.attemptId,
                "reason": reason,
            ],
            cancelReason: reason
        )
        return true
    }

    @discardableResult
    func sendDirectQuicReceiverTransmitPrepareIfPossible(
        for contactID: UUID,
        reason: String,
        sendWarmPing: Bool = true
    ) async -> Bool {
        let requestID = UUID().uuidString.lowercased()
        let transmitPrepareReason = "transmit-\(reason)"
        let sent = await sendDirectQuicReceiverPrewarmRequest(
            for: contactID,
            reason: transmitPrepareReason,
            requestID: requestID,
            recordOutboundRequestID: true
        )
        if sent, sendWarmPing {
            await sendDirectQuicWarmPingIfPossible(for: contactID, reason: transmitPrepareReason)
        }
        return sent
    }

    func handleIncomingDirectQuicReceiverPrewarmRequest(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String
    ) async {
        let isFirstDelivery = mediaRuntime.markReceiverPrewarmRequestHandled(payload.requestId)
        diagnostics.record(
            .media,
            message: isFirstDelivery
                ? "Direct QUIC receiver prewarm request received"
                : "Direct QUIC receiver prewarm request replayed",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": payload.channelId,
                "attemptId": attemptID,
                "requestId": payload.requestId,
                "reason": payload.reason,
            ]
        )

        if isFirstDelivery, payload.reason.hasPrefix("transmit-") {
            await handleIncomingDirectQuicTransmitPrepare(
                payload,
                contactID: contactID,
                attemptID: attemptID
            )
        } else if isFirstDelivery {
            await prewarmLocalMediaIfNeeded(for: contactID)
            await syncLocalReceiverAudioReadinessSignal(
                for: contactID,
                reason: .directQuicReceiverPrewarm
            )
        }

        guard let controller = mediaRuntime.directQuicProbeController else { return }
        do {
            try await controller.sendReceiverPrewarmAck(payload)
            diagnostics.record(
                .media,
                message: "Direct QUIC receiver prewarm ack sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": payload.channelId,
                    "attemptId": attemptID,
                    "requestId": payload.requestId,
                ]
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC receiver prewarm ack failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": payload.channelId,
                    "attemptId": attemptID,
                    "requestId": payload.requestId,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func handleDirectQuicReceiverPrewarmAck(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String
    ) {
        mediaRuntime.markReceiverPrewarmAckReceived(
            contactID: contactID,
            requestID: payload.requestId
        )
        if let existing = channelReadinessByContactID[contactID] {
            backendSyncCoordinator.send(
                .channelReadinessUpdated(
                    contactID: contactID,
                    readiness: existing.settingRemoteAudioReadiness(.ready)
                )
            )
        }
        diagnostics.record(
            .media,
            message: "Direct QUIC receiver prewarm ack received",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": payload.channelId,
                "attemptId": attemptID,
                "requestId": payload.requestId,
            ]
        )
        updateStatusForSelectedContact()
    }

    func handleIncomingDirectQuicPathClosing(
        _ payload: DirectQuicPathClosingPayload,
        contactID: UUID,
        attemptID: String
    ) async {
        guard payload.attemptId == attemptID else {
            diagnostics.record(
                .media,
                message: "Ignored Direct QUIC path closing for stale attempt",
                metadata: [
                    "contactId": contactID.uuidString,
                    "expectedAttemptId": attemptID,
                    "receivedAttemptId": payload.attemptId,
                    "reason": payload.reason,
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC path closing received",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": payload.attemptId,
                "reason": payload.reason,
            ]
        )
        if isRemoteReceiverBackgroundTransitionReason(payload.reason),
           let existing = channelReadinessByContactID[contactID] {
            var updated = existing.settingRemoteAudioReadiness(.wakeCapable)
            if case .unavailable = existing.remoteWakeCapability,
               let peerDeviceID = directQuicPeerDeviceID(for: contactID),
               !peerDeviceID.isEmpty {
                updated = updated.settingRemoteWakeCapability(
                    .wakeCapable(targetDeviceId: peerDeviceID)
                )
            }
            backendSyncCoordinator.send(
                .channelReadinessUpdated(contactID: contactID, readiness: updated)
            )
            diagnostics.record(
                .media,
                message: "Marked peer receiver wake-capable from Direct QUIC path closing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": payload.attemptId,
                    "reason": payload.reason,
                ]
            )
        }
        await retireDirectQuicPath(
            for: contactID,
            reason: payload.reason,
            sendHangup: false,
            configureActiveRoute: true
        )
    }

    func isRemoteReceiverBackgroundTransitionReason(_ reason: String) -> Bool {
        reason == "app-background-media-closed"
            || reason == "application-will-resign-active"
            || reason == "application-did-enter-background"
    }

    func sendDirectQuicWarmPingIfPossible(
        for contactID: UUID,
        reason: String
    ) async {
        guard shouldUseDirectQuicTransport(for: contactID),
              let attempt = directQuicAttempt(for: contactID),
              attempt.isDirectActive,
              let controller = mediaRuntime.directQuicProbeController else {
            return
        }

        let pingID = UUID().uuidString.lowercased()
        do {
            try await controller.sendWarmPing(id: pingID)
            diagnostics.record(
                .media,
                message: "Direct QUIC warm ping sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "pingId": pingID,
                    "reason": reason,
                ]
            )
        } catch {
            diagnostics.record(
                .media,
                message: "Direct QUIC warm ping failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "pingId": pingID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func handleDirectQuicWarmPong(
        _ pingID: String?,
        contactID: UUID,
        attemptID: String
    ) {
        mediaRuntime.markDirectQuicWarmPongReceived(
            contactID: contactID,
            pingID: pingID
        )
        diagnostics.record(
            .media,
            message: "Direct QUIC warm pong received",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": attemptID,
                "pingId": pingID ?? "",
            ]
        )
    }

    func handleIncomingDirectQuicAudioPayload(
        _ payload: String,
        contactID: UUID,
        attemptID: String
    ) async {
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID) else {
            return
        }
        let remoteUserID = contacts.first(where: { $0.id == contactID })?.remoteUserId ?? ""
        let fromDeviceID = attempt.peerDeviceID ?? "direct-quic"

        diagnostics.record(
            .media,
            message: "Direct QUIC audio payload received",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attemptID,
                "fromDeviceId": fromDeviceID,
            ]
        )
        recordWakeReceiveTiming(
            stage: "direct-quic-audio-received",
            contactID: contactID,
            channelID: attempt.channelID,
            metadata: [
                "attemptId": attemptID,
                "fromDeviceId": fromDeviceID,
            ],
            ifAbsent: true
        )
        await handleIncomingAudioPayload(
            payload,
            channelID: attempt.channelID,
            fromUserID: remoteUserID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: .directQuic
        )
    }

    func handleDirectQuicMediaPathLost(
        for contactID: UUID,
        attemptID: String,
        reason: String
    ) async {
        let category = DirectQuicRetryBackoffPolicy.category(for: reason)
        diagnostics.record(
            .media,
            level: .notice,
            message: "Direct QUIC media path lost",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": attemptID,
                "reason": reason,
                "failureCategory": category.rawValue,
            ]
        )
        mediaRuntime.directQuicUpgrade.applyRetryBackoff(
            for: contactID,
            request: directQuicPathLostRetryBackoffRequest(
                for: contactID,
                reason: reason,
                attemptID: attemptID
            )
        )

        if let recovering = mediaRuntime.directQuicUpgrade.markDirectPathLost(
            for: contactID,
            reason: reason
        ) {
            mediaRuntime.clearReceiverPrewarmState(for: contactID)
            applyDirectQuicUpgradeTransition(recovering, for: contactID)
            applyDirectQuicUpgradeTransition(
                .fellBackToRelay(previousAttemptId: recovering.attemptId, reason: reason),
                for: contactID
            )
        }

        mediaRuntime.directQuicProbeController?.cancel(reason: "path-lost")
        mediaRuntime.directQuicProbeController = nil
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            configureOutgoingAudioRoute(target: activeTarget)
        }
        scheduleAutomaticDirectQuicProbe(
            for: contactID,
            reason: "path-lost"
        )
    }

    func sendDirectQuicHangup(
        for contactID: UUID,
        attempt: DirectQuicUpgradeAttempt,
        reason: String
    ) async {
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let remoteUserID = contact.remoteUserId else {
            return
        }
        let peerDeviceID = attempt.peerDeviceID
            ?? directQuicPeerDeviceID(for: contactID)
            ?? attempt.remoteOffer?.fromDeviceId
        guard let peerDeviceID, !peerDeviceID.isEmpty else {
            diagnostics.record(
                .websocket,
                message: "Skipped direct QUIC hangup because peer device is unknown",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "reason": reason,
                ]
            )
            return
        }

        do {
            try await backend.waitForWebSocketConnection()
            let envelope = try TurboSignalEnvelope.directQuicHangup(
                channelId: attempt.channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: TurboDirectQuicHangupPayload(
                    attemptId: attempt.attemptId,
                    reason: reason
                )
            )
            try await backend.sendSignal(envelope)
            diagnostics.record(
                .websocket,
                message: "Direct QUIC hangup sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC hangup send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func sendDirectQuicCandidateSignals(
        channelID: String,
        contactID: UUID,
        remoteUserID: String,
        remoteDeviceID: String,
        attemptID: String,
        candidates: [TurboDirectQuicCandidate],
        endOfCandidates: Bool
    ) async {
        guard let backend = backendServices else { return }

        do {
            try await backend.waitForWebSocketConnection()
            for candidate in candidates {
                let envelope = try TurboSignalEnvelope.directQuicCandidate(
                    channelId: channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: remoteUserID,
                    toDeviceId: remoteDeviceID,
                    payload: TurboDirectQuicCandidatePayload(
                        attemptId: attemptID,
                        candidate: candidate
                    )
                )
                try await backend.sendSignal(envelope)
            }
            if endOfCandidates {
                let envelope = try TurboSignalEnvelope.directQuicCandidate(
                    channelId: channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: remoteUserID,
                    toDeviceId: remoteDeviceID,
                    payload: TurboDirectQuicCandidatePayload(
                        attemptId: attemptID,
                        candidate: nil,
                        endOfCandidates: true
                    )
                )
                try await backend.sendSignal(envelope)
            }
            diagnostics.record(
                .websocket,
                message: "Direct QUIC candidates sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "endOfCandidates": String(endOfCandidates),
                    "peerDeviceId": remoteDeviceID,
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC candidate send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "endOfCandidates": String(endOfCandidates),
                    "peerDeviceId": remoteDeviceID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func continueDirectQuicPromotionIfNeeded(
        for contactID: UUID,
        attemptID: String,
        expectedPeerCertificateFingerprint: String,
        candidates: [TurboDirectQuicCandidate],
        trigger: String
    ) async {
        guard !candidates.isEmpty else { return }
        guard directQuicAttempt(for: contactID, matching: attemptID)?.isDirectActive != true else {
            return
        }
        guard let controller = mediaRuntime.directQuicProbeController else { return }

        do {
            let outcome = try await controller.probeRemoteCandidatesIfNeeded(
                attemptId: attemptID,
                expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
                candidates: candidates
            )
            guard outcome.didEstablishPath else {
                let metadata: [String: String] = [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "viableCandidateCount": "\(outcome.viableCandidateCount)",
                    "newlyAttemptedCandidateCount": "\(outcome.newlyAttemptedCandidateCount)",
                    "trigger": trigger,
                    "disposition": outcome.disposition.rawValue,
                    "lastError": outcome.lastErrorDescription ?? "none",
                ]
                let message: String
                switch outcome.disposition {
                case .alreadyConnected, .pathEstablished:
                    message = "Direct QUIC remote candidate probe established path"
                case .noViableCandidates:
                    message = "Direct QUIC promotion ignored remote candidates without viable UDP addresses"
                case .noNewCandidates:
                    message = "Direct QUIC promotion is waiting because remote candidates were already attempted"
                case .probeAlreadyInFlight:
                    message = "Direct QUIC promotion probe is already in flight"
                case .batchExhausted:
                    message = "Direct QUIC remote candidate probe batch exhausted without nomination"
                }
                diagnostics.record(
                    .media,
                    level: .info,
                    message: message,
                    metadata: metadata
                )
                return
            }

            diagnostics.record(
                .media,
                message: "Direct QUIC remote candidate probe established path",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "viableCandidateCount": "\(outcome.viableCandidateCount)",
                    "newlyAttemptedCandidateCount": "\(outcome.newlyAttemptedCandidateCount)",
                    "trigger": trigger,
                    "disposition": outcome.disposition.rawValue,
                ]
            )
            await activateDirectQuicMediaPath(
                for: contactID,
                attemptID: attemptID
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC remote candidate probe failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "trigger": trigger,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func maybeStartDirectQuicProbe(
        for contactID: UUID,
        allowDebugBypassWithoutBackendAdvertisement: Bool = false
    ) async {
        let isUpgradeAllowed =
            !isDirectPathRelayOnlyForced
            && (
                backendAdvertisesDirectQuicUpgrade
                    || allowDebugBypassWithoutBackendAdvertisement
            )
        guard isUpgradeAllowed else { return }
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        guard let channelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId else {
            return
        }
        if allowDebugBypassWithoutBackendAdvertisement,
           !backendAdvertisesDirectQuicUpgrade {
            diagnostics.record(
                .media,
                message: "Direct QUIC debug probe bypassed backend capability gate",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "handle": contact.handle,
                ]
            )
        }
        guard mediaRuntime.directQuicUpgrade.attempt(for: contactID) == nil else { return }
        if let retryBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID),
           let retryRemaining = mediaRuntime.directQuicUpgrade.retryBackoffRemaining(for: contactID) {
            diagnostics.record(
                .media,
                message: "Skipped direct QUIC probe during retry backoff",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "retryRemainingMs": "\(Int(retryRemaining * 1_000))",
                    "retryReason": retryBackoff.reason,
                    "retryCategory": retryBackoff.category.rawValue,
                    "retryAttemptId": retryBackoff.attemptId ?? "",
                    "retryBackoffMs": "\(retryBackoff.milliseconds)",
                ]
            )
            return
        }

        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            diagnostics.record(
                .media,
                message: "Skipped direct QUIC probe because peer target device is unknown",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                ]
            )
            return
        }

        let role = directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
        )
        guard role == .listenerOfferer else { return }

        if !allowDebugBypassWithoutBackendAdvertisement {
            let localIdentityStatus = DirectQuicIdentityConfiguration.status()
            let identityIsRegistered =
                localIdentityStatus.source == .production
                    && localIdentityStatus.fingerprint != nil
                    && (
                        localIdentityStatus.fingerprint == directQuicRegisteredFingerprint
                            || directQuicRegisteredFingerprint == nil
                    )
            if !identityIsRegistered {
                let repaired = await repairDirectQuicProductionIdentityRegistrationIfPossible(
                    contactID: contactID,
                    channelID: channelID,
                    reason: "direct-quic-probe"
                )
                guard repaired else {
                    diagnostics.record(
                        .media,
                        level: .error,
                        message: "Skipped direct QUIC probe because production identity is not registered",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "identitySource": localIdentityStatus.source.rawValue,
                            "identityStatus": localIdentityStatus.diagnosticsText,
                            "provisioningStatus": directQuicProvisioningStatus,
                            "fingerprint": localIdentityStatus.fingerprint ?? "none",
                            "registeredFingerprint": directQuicRegisteredFingerprint ?? "none",
                        ]
                    )
                    return
                }
                diagnostics.record(
                    .media,
                    message: "Continuing Direct QUIC probe after repairing production identity registration",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "registeredFingerprint": directQuicRegisteredFingerprint ?? "none",
                    ]
                )
            }
            guard backendPeerDirectQuicFingerprint(for: contactID) != nil else {
                diagnostics.record(
                    .media,
                    message: "Skipped direct QUIC probe because backend peer identity is missing",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                    ]
                )
                return
            }
        }

        let attemptID = UUID().uuidString.lowercased()
        let transition = mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: channelID,
            attemptID: attemptID,
            peerDeviceID: peerDeviceID
        )
        applyDirectQuicUpgradeTransition(transition, for: contactID)

        do {
            let preparedOffer = try await directQuicProbeController().prepareListenerOffer(
                attemptId: attemptID,
                stunServers: directQuicStunServers()
            )
            let offerPayload = TurboDirectQuicOfferPayload(
                attemptId: attemptID,
                channelId: channelID,
                fromDeviceId: backend.deviceID,
                toDeviceId: peerDeviceID,
                quicAlpn: preparedOffer.quicAlpn,
                certificateFingerprint: preparedOffer.certificateFingerprint,
                candidates: preparedOffer.candidates,
                roleIntent: .listener,
                debugBypass: allowDebugBypassWithoutBackendAdvertisement
                    && !backendAdvertisesDirectQuicUpgrade
            )
            try await backend.waitForWebSocketConnection()
            let envelope = try TurboSignalEnvelope.directQuicOffer(
                channelId: channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: offerPayload
            )
            try await backend.sendSignal(envelope)
            diagnostics.record(
                .websocket,
                message: "Direct QUIC offer sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(preparedOffer.candidates.count)",
                    "peerDeviceId": peerDeviceID,
                ]
            )
            scheduleDirectQuicPromotionTimeout(contactID: contactID, attemptID: attemptID)
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC offer preparation failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "offer-failed",
                sendHangup: false,
                applyRetryBackoff: true
            )
        }
    }

    func handleDirectQuicSignal(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        switch signal {
        case .offer(let payload):
            await respondToDirectQuicOffer(
                payload,
                envelope: envelope,
                contactID: contactID
            )
        case .answer(let payload):
            await handleDirectQuicAnswer(
                payload,
                envelope: envelope,
                contactID: contactID
            )
        case .candidate(let payload):
            guard let attempt = directQuicAttempt(for: contactID, matching: payload.attemptId) else {
                return
            }
            if payload.endOfCandidates {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC remote candidate trickle completed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": attempt.channelID,
                        "attemptId": payload.attemptId,
                        "remoteCandidateCount": "\(attempt.remoteCandidateCount)",
                    ]
                )
            }
            guard let expectedPeerCertificateFingerprint = directQuicExpectedPeerCertificateFingerprint(
                for: attempt
            ) else {
                return
            }
            let candidatesToProbe = directQuicCandidateBatchToProbe(
                for: attempt,
                payload: payload
            )
            if !attempt.isDirectActive {
                scheduleDirectQuicPromotionTimeout(
                    contactID: contactID,
                    attemptID: payload.attemptId
                )
            }
            await continueDirectQuicPromotionIfNeeded(
                for: contactID,
                attemptID: payload.attemptId,
                expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
                candidates: candidatesToProbe,
                trigger: payload.endOfCandidates ? "end-of-candidates" : "trickle-candidate"
            )
        case .hangup(let payload):
            let isRecoveringActivePath =
                mediaRuntime.transportPathState == .direct
                || mediaRuntime.transportPathState == .recovering
            if directQuicAttempt(for: contactID)?.isDirectActive == true {
                await handleDirectQuicMediaPathLost(
                    for: contactID,
                    attemptID: payload.attemptId,
                    reason: payload.reason
                )
                return
            }
            cancelDirectQuicPromotionTimeout()
            mediaRuntime.directQuicUpgrade.applyRetryBackoff(
                for: contactID,
                request: directQuicPromotionRetryBackoffRequest(
                    for: contactID,
                    reason: payload.reason,
                    attemptID: payload.attemptId
                )
            )
            mediaRuntime.directQuicProbeController?.cancel(reason: payload.reason)
            mediaRuntime.directQuicProbeController = nil
            if isRecoveringActivePath {
                mediaRuntime.clearReceiverPrewarmState(for: contactID)
                applyDirectQuicUpgradeTransition(
                    .fellBackToRelay(
                        previousAttemptId: payload.attemptId,
                        reason: payload.reason
                    ),
                    for: contactID
                )
                if let activeTarget = transmitProjection.activeTarget,
                   activeTarget.contactID == contactID {
                    configureOutgoingAudioRoute(target: activeTarget)
                }
            }
        }
    }

    func handleIncomingDirectQuicUpgradeRequest(
        _ envelope: TurboSignalEnvelope,
        contactID: UUID
    ) {
        do {
            let payload = try envelope.decodeDirectQuicUpgradeRequestPayload()
            guard let backend = backendServices else { return }

            var metadata: [String: String] = [
                "contactId": contactID.uuidString,
                "channelId": envelope.channelId,
                "requestId": payload.requestId,
                "reason": payload.reason,
                "fromDeviceId": envelope.fromDeviceId,
                "toDeviceId": envelope.toDeviceId,
                "debugBypass": String(payload.debugBypass == true),
            ]

            guard envelope.toDeviceId == backend.deviceID,
                  payload.toDeviceId == backend.deviceID,
                  payload.fromDeviceId == envelope.fromDeviceId,
                  payload.channelId == envelope.channelId else {
                diagnostics.record(
                    .websocket,
                    level: .error,
                    message: "Rejected Direct QUIC upgrade request because envelope and payload disagree",
                    metadata: metadata
                )
                return
            }

            let peerDeviceID = directQuicPeerDeviceID(for: contactID, fallback: envelope.fromDeviceId)
            guard peerDeviceID == envelope.fromDeviceId else {
                metadata["expectedPeerDeviceId"] = peerDeviceID ?? "none"
                diagnostics.record(
                    .websocket,
                    level: .error,
                    message: "Rejected Direct QUIC upgrade request from unexpected peer device",
                    metadata: metadata
                )
                return
            }

            let role = directQuicAttemptRole(
                localDeviceID: backend.deviceID,
                peerDeviceID: envelope.fromDeviceId
            )
            metadata["localRole"] = role.rawValue
            guard role == .listenerOfferer else {
                diagnostics.record(
                    .websocket,
                    message: "Ignored Direct QUIC upgrade request because local role is not listener-offerer",
                    metadata: metadata
                )
                return
            }

            if let blockReason = automaticDirectQuicProbeBlockReason(for: contactID) {
                metadata["blockReason"] = blockReason
                diagnostics.record(
                    .websocket,
                    message: "Ignored Direct QUIC upgrade request because automatic probe is blocked",
                    metadata: metadata
                )
                return
            }

            diagnostics.record(
                .websocket,
                message: "Direct QUIC upgrade request accepted",
                metadata: metadata
            )
            Task {
                await maybeStartDirectQuicProbe(
                    for: contactID,
                    allowDebugBypassWithoutBackendAdvertisement: payload.debugBypass == true
                        && shouldAllowDirectQuicDebugBypassForAutomaticProbe()
                )
            }
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Failed to decode Direct QUIC upgrade request",
                metadata: [
                    "type": envelope.type.rawValue,
                    "channelId": envelope.channelId,
                    "contactId": contactID.uuidString,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func respondToDirectQuicOffer(
        _ offer: TurboDirectQuicOfferPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        guard let backend = backendServices else { return }

        let role = directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: envelope.fromDeviceId
        )
        guard role == .dialerAnswerer else {
            diagnostics.record(
                .websocket,
                message: "Ignored direct QUIC offer because local role is not dialer",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "localDeviceId": backend.deviceID,
                    "peerDeviceId": envelope.fromDeviceId,
                ]
            )
            return
        }

        let answerPayload: TurboDirectQuicAnswerPayload
        var shouldProbeRemoteCandidates = false
        do {
            let preparedAnswer = try await directQuicProbeController().prepareDialerAnswer(
                using: offer,
                stunServers: directQuicStunServers()
            )
            answerPayload = TurboDirectQuicAnswerPayload(
                attemptId: offer.attemptId,
                accepted: true,
                certificateFingerprint: preparedAnswer.certificateFingerprint,
                candidates: preparedAnswer.candidates
            )
            shouldProbeRemoteCandidates = true
            diagnostics.record(
                .media,
                message: "Direct QUIC answer prepared; sending candidates before probing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "localCandidateCount": "\(preparedAnswer.candidates.count)",
                    "remoteCandidateCount": "\(offer.candidates.count)",
                ]
            )
        } catch {
            answerPayload = TurboDirectQuicAnswerPayload(
                attemptId: offer.attemptId,
                accepted: false,
                rejectionReason: error.localizedDescription
            )
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC probe connect failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            let relayFallback = mediaRuntime.directQuicUpgrade.clearAttempt(
                for: contactID,
                fallbackReason: "probe-connect-failed",
                retryBackoff: directQuicRetryBackoffRequest(
                    reason: "probe-connect-failed",
                    attemptID: offer.attemptId
                )
            )
            applyDirectQuicUpgradeTransition(relayFallback, for: contactID)
            mediaRuntime.directQuicProbeController?.cancel(reason: "connect-failed")
            mediaRuntime.directQuicProbeController = nil
        }

        do {
            try await backend.waitForWebSocketConnection()
            let answerEnvelope = try TurboSignalEnvelope.directQuicAnswer(
                channelId: envelope.channelId,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: envelope.fromUserId,
                toDeviceId: envelope.fromDeviceId,
                payload: answerPayload
            )
            try await backend.sendSignal(answerEnvelope)
            diagnostics.record(
                .websocket,
                message: "Direct QUIC answer sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "accepted": String(answerPayload.accepted),
                ]
            )
            if answerPayload.accepted {
                await sendDirectQuicCandidateSignals(
                    channelID: envelope.channelId,
                    contactID: contactID,
                    remoteUserID: envelope.fromUserId,
                    remoteDeviceID: envelope.fromDeviceId,
                    attemptID: offer.attemptId,
                    candidates: answerPayload.candidates,
                    endOfCandidates: true
                )
                scheduleDirectQuicPromotionTimeout(
                    contactID: contactID,
                    attemptID: offer.attemptId
                )
                if shouldProbeRemoteCandidates {
                    await continueDirectQuicPromotionIfNeeded(
                        for: contactID,
                        attemptID: offer.attemptId,
                        expectedPeerCertificateFingerprint: offer.certificateFingerprint,
                        candidates: offer.candidates,
                        trigger: "received-offer"
                    )
                }
            } else {
                mediaRuntime.directQuicProbeController?.cancel(reason: "answer-sent")
                mediaRuntime.directQuicProbeController = nil
            }
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC answer send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "answer-send-failed",
                sendHangup: false,
                applyRetryBackoff: true
            )
        }
    }

    func handleDirectQuicAnswer(
        _ answer: TurboDirectQuicAnswerPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        if !answer.accepted {
            cancelDirectQuicPromotionTimeout()
            let rejectionReason = answer.rejectionReason ?? "answer-rejected"
            mediaRuntime.directQuicUpgrade.applyRetryBackoff(
                for: contactID,
                request: directQuicRetryBackoffRequest(
                    reason: rejectionReason,
                    attemptID: answer.attemptId
                )
            )
            mediaRuntime.directQuicProbeController?.cancel(
                reason: rejectionReason
            )
            mediaRuntime.directQuicProbeController = nil
            return
        }

        guard let controller = mediaRuntime.directQuicProbeController else {
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "missing-probe-controller",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }
        guard let expectedPeerCertificateFingerprint = answer.certificateFingerprint,
              !expectedPeerCertificateFingerprint.isEmpty else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC answer missing peer certificate fingerprint",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": answer.attemptId,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "missing-peer-certificate-fingerprint",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        let localCandidatesToRetrickle = controller.preparedLocalCandidates(
            matching: answer.attemptId
        )
        if !localCandidatesToRetrickle.isEmpty {
            await sendDirectQuicCandidateSignals(
                channelID: envelope.channelId,
                contactID: contactID,
                remoteUserID: envelope.fromUserId,
                remoteDeviceID: envelope.fromDeviceId,
                attemptID: answer.attemptId,
                candidates: localCandidatesToRetrickle,
                endOfCandidates: true
            )
        }

        do {
            if try controller.verifyConnectedPeerCertificateFingerprintIfAvailable(
                expectedPeerCertificateFingerprint
            ) {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC listener received successful probe answer",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "attemptId": answer.attemptId,
                        "peerCertificateFingerprint": expectedPeerCertificateFingerprint,
                        "peerCandidateCount": "\(answer.candidates.count)",
                    ]
                )
                await activateDirectQuicMediaPath(
                    for: contactID,
                    attemptID: answer.attemptId
                )
                return
            }
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC answer peer certificate fingerprint verification failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": answer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "peer-certificate-fingerprint-mismatch",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        let remoteCandidates = directQuicAttempt(
            for: contactID,
            matching: answer.attemptId
        )?.remoteCandidates ?? answer.candidates
        diagnostics.record(
            .media,
            message: "Direct QUIC answer accepted; continuing promotion with remote candidates",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": envelope.channelId,
                "attemptId": answer.attemptId,
                "peerCertificateFingerprint": expectedPeerCertificateFingerprint,
                "peerCandidateCount": "\(remoteCandidates.count)",
            ]
        )
        scheduleDirectQuicPromotionTimeout(
            contactID: contactID,
            attemptID: answer.attemptId
        )
        await continueDirectQuicPromotionIfNeeded(
            for: contactID,
            attemptID: answer.attemptId,
            expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
            candidates: remoteCandidates,
            trigger: "accepted-answer"
        )
    }
}
