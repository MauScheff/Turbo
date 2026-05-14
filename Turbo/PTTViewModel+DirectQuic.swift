import Foundation
import UIKit

extension PTTViewModel {
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
                        await self.ingestDirectQuicReceiverPrewarmRequest(
                            payload,
                            contactID: contactID,
                            attemptID: attemptID
                        )
                    }
                },
                onReceiverPrewarmAck: { [weak self] payload in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.ingestDirectQuicReceiverPrewarmAck(
                            payload,
                            contactID: contactID,
                            attemptID: attemptID
                        )
                    }
                },
                onPathClosing: { [weak self] payload in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.ingestDirectQuicPathClosing(
                            payload,
                            contactID: contactID
                        )
                    }
                },
                onWarmPong: { [weak self] pingID in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.ingestDirectQuicWarmPong(
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
            Task { @MainActor [weak self] in
                _ = await self?.sendMediaRelayReceiverPrewarmRequestIfPossible(
                    for: contactID,
                    reason: reason,
                    requestID: self?.mediaRuntime.receiverPrewarmRequestID(for: contactID)
                )
            }
            await sendDirectQuicWarmPingIfPossible(for: contactID, reason: reason)
            return
        }

        if await sendMediaRelayReceiverPrewarmRequestIfPossible(for: contactID, reason: reason) {
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
        if sent {
            Task { @MainActor [weak self] in
                _ = await self?.sendMediaRelayReceiverPrewarmRequestIfPossible(
                    for: contactID,
                    reason: transmitPrepareReason,
                    requestID: requestID
                )
            }
        } else {
            _ = await sendMediaRelayReceiverPrewarmRequestIfPossible(
                for: contactID,
                reason: transmitPrepareReason,
                requestID: requestID,
                recordOutboundRequestID: true
            )
        }
        return sent
    }

    @discardableResult
    func sendMediaRelayReceiverPrewarmRequestIfPossible(
        for contactID: UUID,
        reason: String,
        requestID: String? = nil,
        recordOutboundRequestID: Bool = false
    ) async -> Bool {
        guard !isDirectPathRelayOnlyForced else { return false }
        guard let backend = backendServices,
              let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId,
              let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
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
            directQuicAttemptId: directQuicAttempt(for: contactID)?.attemptId
        )
        guard let relayClient = await mediaRelayClientIfEnabled(
            contactID: contactID,
            channelID: channelID,
            peerDeviceID: peerDeviceID,
            missingConfigMessage: "Media relay prewarm skipped because relay config is missing",
            connectingMessage: "Connecting media relay for prewarm",
            selectedMessage: "Media relay prewarm path selected",
            failureMessage: "Media relay prewarm connection failed",
            fromUserIDForIncoming: { contact.remoteUserId ?? "" }
        ) else {
            return false
        }
        do {
            try await relayClient.sendReceiverPrewarmRequest(payload)
            diagnostics.record(
                .media,
                message: "Media relay receiver prewarm request sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "requestId": requestID,
                    "reason": reason,
                ]
            )
            return true
        } catch {
            recordMediaRelayPeerUnavailableInvariantIfNeeded(
                error: error,
                contactID: contactID,
                channelID: channelID,
                peerDeviceID: peerDeviceID,
                operation: "receiver-prewarm-request"
            )
            diagnostics.record(
                .media,
                level: .error,
                message: "Media relay receiver prewarm request failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "requestId": requestID,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    @discardableResult
    func sendMediaRelayReceiverPrewarmAckIfPossible(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID
    ) async -> Bool {
        guard !isDirectPathRelayOnlyForced else { return false }
        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID, fallback: payload.fromDeviceId),
              let contact = contacts.first(where: { $0.id == contactID }) else {
            return false
        }
        guard let relayClient = await mediaRelayClientIfEnabled(
            contactID: contactID,
            channelID: payload.channelId,
            peerDeviceID: peerDeviceID,
            missingConfigMessage: "Media relay prewarm ack skipped because relay config is missing",
            connectingMessage: "Connecting media relay for prewarm ack",
            selectedMessage: "Media relay prewarm ack path selected",
            failureMessage: "Media relay prewarm ack connection failed",
            fromUserIDForIncoming: { contact.remoteUserId ?? "" }
        ) else {
            return false
        }
        do {
            try await relayClient.sendReceiverPrewarmAck(payload)
            diagnostics.record(
                .media,
                message: "Media relay receiver prewarm ack sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": payload.channelId,
                    "peerDeviceId": peerDeviceID,
                    "requestId": payload.requestId,
                ]
            )
            return true
        } catch {
            recordMediaRelayPeerUnavailableInvariantIfNeeded(
                error: error,
                contactID: contactID,
                channelID: payload.channelId,
                peerDeviceID: peerDeviceID,
                operation: "receiver-prewarm-ack"
            )
            diagnostics.record(
                .media,
                level: .error,
                message: "Media relay receiver prewarm ack failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": payload.channelId,
                    "peerDeviceId": peerDeviceID,
                    "requestId": payload.requestId,
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    func handleIncomingDirectQuicReceiverPrewarmRequest(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String,
        source: ControlEventSource = .directQuicDataChannel
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

        switch source {
        case .mediaRelay:
            _ = await sendMediaRelayReceiverPrewarmAckIfPossible(payload, contactID: contactID)
        default:
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
    }

    func handleDirectQuicReceiverPrewarmAck(
        _ payload: DirectQuicReceiverPrewarmPayload,
        contactID: UUID,
        attemptID: String,
        source: ControlEventSource = .directQuicDataChannel
    ) {
        mediaRuntime.markReceiverPrewarmAckReceived(
            contactID: contactID,
            requestID: payload.requestId
        )
        if let existing = channelReadinessByContactID[contactID] {
            applyChannelReadiness(
                existing.settingRemoteAudioReadiness(.ready),
                for: contactID,
                reason: "direct-quic-receiver-prewarm-ack"
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
                "source": source.rawValue,
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
            applyChannelReadiness(
                updated,
                for: contactID,
                reason: "direct-quic-path-closing"
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
            && !TurboMediaRelayDebugOverride.isForced()
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

            if TurboJoinAcceptedControlSignal.matches(payload) {
                handleIncomingJoinAcceptedControlSignal(
                    envelope,
                    payload: payload,
                    contactID: contactID,
                    metadata: metadata
                )
                return
            }

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

            let allowsSelectionPrewarmRequest = payload.reason.hasPrefix("selection-direct-quic-prewarm-")
            let blockReason = allowsSelectionPrewarmRequest
                ? directQuicSelectionPrewarmBlockReason(
                    for: contactID,
                    requireSelectedContact: false
                )
                : automaticDirectQuicProbeBlockReason(for: contactID)
            if let blockReason {
                metadata["blockReason"] = blockReason
                let message = allowsSelectionPrewarmRequest
                    ? "Ignored Direct QUIC upgrade request because selection prewarm is blocked"
                    : "Ignored Direct QUIC upgrade request because automatic probe is blocked"
                diagnostics.record(
                    .websocket,
                    message: message,
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

    func handleIncomingJoinAcceptedControlSignal(
        _ envelope: TurboSignalEnvelope,
        payload: TurboDirectQuicUpgradeRequestPayload,
        contactID: UUID,
        metadata: [String: String]
    ) {
        guard let backend = backendServices else { return }
        var metadata = metadata

        guard envelope.toDeviceId == backend.deviceID,
              payload.fromDeviceId == envelope.fromDeviceId,
              payload.channelId == envelope.channelId else {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected join accepted control signal because envelope and payload disagree",
                metadata: metadata
            )
            return
        }

        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected join accepted control signal because contact is missing",
                metadata: metadata
            )
            return
        }

        if let remoteUserId = contact.remoteUserId,
           remoteUserId != envelope.fromUserId {
            metadata["expectedRemoteUserId"] = remoteUserId
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected join accepted control signal from unexpected peer user",
                metadata: metadata
            )
            return
        }

        if let outgoingInvite = outgoingInviteByContactID[contactID],
           outgoingInvite.inviteId != payload.requestId {
            metadata["currentInviteId"] = outgoingInvite.inviteId
            diagnostics.record(
                .websocket,
                message: "Ignored stale join accepted control signal",
                metadata: metadata
            )
            return
        }

        let relationship = relationshipState(for: contactID)
        let acceptedToken = recentOutgoingJoinAcceptedTokensByContactID[contactID]
        let acceptedViaRecentOutgoingToken = acceptedToken?.matches(payload) == true
        let recentOutgoingRequestEvidence = recentOutgoingRequestEvidenceByContactID[contactID]
        let acceptedViaRecentOutgoingRequestEvidence =
            recentOutgoingRequestEvidence?.matches(payload) == true
        guard relationship.isOutgoingRequest
            || outgoingInviteByContactID[contactID] != nil
            || acceptedViaRecentOutgoingToken
            || acceptedViaRecentOutgoingRequestEvidence else {
            diagnostics.record(
                .websocket,
                message: "Ignored join accepted control signal without a local outgoing request",
                metadata: metadata
            )
            return
        }
        if acceptedViaRecentOutgoingToken {
            metadata["acceptedViaRecentOutgoingToken"] = "true"
            recentOutgoingJoinAcceptedTokensByContactID.removeValue(forKey: contactID)
        }
        if acceptedViaRecentOutgoingRequestEvidence {
            metadata["acceptedViaRecentOutgoingRequestEvidence"] = "true"
            metadata["recentOutgoingRequestCount"] =
                String(recentOutgoingRequestEvidence?.requestCount ?? 0)
            recentOutgoingRequestEvidenceByContactID.removeValue(forKey: contactID)
        }

        guard selectedContactId == contactID else {
            diagnostics.record(
                .websocket,
                message: "Ignored join accepted control signal for non-selected contact",
                metadata: metadata
            )
            return
        }

        guard !backendLeaveIsInFlight(for: contactID) else {
            metadata["pendingAction"] = String(describing: sessionCoordinator.pendingAction)
            metadata["activeBackendOperation"] = String(describing: backendCommandCoordinator.state.activeOperation)
            diagnostics.record(
                .websocket,
                level: .notice,
                message: "Ignored join accepted control signal while leave is active",
                metadata: metadata
            )
            return
        }

        diagnostics.record(
            .websocket,
            message: "Join accepted control signal received",
            metadata: metadata
        )

        promoteOptimisticOutgoingRequestToJoinTransition(contactID: contactID)
        backendRuntime.markBackendJoinSettling(for: contactID)
        let localSessionAlreadyActive =
            systemSessionMatches(contactID)
            || (isJoined && activeChannelId == contactID)
            || sessionCoordinator.pendingJoinContactID == contactID
        if !localSessionAlreadyActive {
            joinPTTChannel(for: contact)
        } else {
            updateStatusForSelectedContact()
            captureDiagnosticsState("backend-signal:join-accepted-dedup")
        }

        Task { @MainActor [weak self, contact] in
            guard let self else { return }
            await self.reassertBackendJoin(for: contact, intent: .joinAcceptedOutgoingRequest)
            await self.refreshContactSummaries()
            await self.refreshChannelState(for: contactID)
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
