//
//  PTTViewModel+BackendSyncTransportFaultsAndSignals.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation
import UIKit

extension PTTViewModel {
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
                await self.ingestBackendWebSocketSignal(envelope)
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

        let surfacedPathState = mediaRuntime.surfacedTransportPathState(for: transition)
        let suppressedByActiveMediaRelay =
            surfacedPathState != transition.pathState && mediaRuntime.hasActiveMediaRelayClient

        if suppressedByActiveMediaRelay {
            diagnostics.record(
                .media,
                message: "Preserved fast relay path while processing Direct QUIC transition",
                metadata: [
                    "contactId": contactID.uuidString,
                    "directQuicPathState": transition.pathState.rawValue,
                    "surfacedPathState": surfacedPathState.rawValue,
                    "attemptId": transition.attemptId ?? "none",
                    "reason": transition.reason ?? "none",
                ]
            )
        }

        mediaRuntime.updateTransportPathState(surfacedPathState)

        switch transition {
        case .enteredPromoting, .updatedPromoting:
            if !suppressedByActiveMediaRelay {
                backendStatusMessage = "Direct path promoting"
            }
        case .directActivated:
            backendStatusMessage = "Direct path active"
        case .recovering:
            if !suppressedByActiveMediaRelay {
                backendStatusMessage = "Direct path recovering"
            } else if backendStatusMessage.hasPrefix("Direct path")
                || backendStatusMessage.hasPrefix("signaling ") {
                backendStatusMessage = "Connected"
            }
        case .fellBackToRelay:
            if backendStatusMessage.hasPrefix("Direct path")
                || backendStatusMessage.hasPrefix("signaling ") {
                backendStatusMessage = "Connected"
            }
        }

        if selectedContactId == contactID {
            updateStatusForSelectedContact()
            captureDiagnosticsState("direct-quic:\(surfacedPathState.rawValue)")
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
        if !MediaEncryptedAudioPacket.isEncodedPacket(payload) {
            let digest = AudioChunkPayloadCodec.transportDigest(audioPayload)
            let duplicateDecision = mediaRuntime.acceptIncomingPlaintextAudioPayload(
                contactID: contactID,
                channelID: channelID,
                fromDeviceID: fromDeviceID,
                transport: incomingAudioTransport,
                digest: digest
            )
            guard duplicateDecision.shouldAccept else {
                diagnostics.record(
                    .media,
                    message: "Ignored duplicate plaintext audio payload from standby transport",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "fromDeviceId": fromDeviceID,
                        "transport": String(describing: incomingAudioTransport),
                        "previousTransport": duplicateDecision.previousTransport.map(String.init(describing:)) ?? "unknown",
                        "transportDigest": digest,
                    ]
                )
                return
            }
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
            await sendFirstAudioPlaybackStartedAckIfNeeded(
                originalPayload: payload,
                channelID: channelID,
                fromUserID: fromUserID,
                fromDeviceID: fromDeviceID,
                contactID: contactID,
                incomingAudioTransport: incomingAudioTransport
            )
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
        await sendFirstAudioPlaybackStartedAckIfNeeded(
            originalPayload: payload,
            channelID: channelID,
            fromUserID: fromUserID,
            fromDeviceID: fromDeviceID,
            contactID: contactID,
            incomingAudioTransport: incomingAudioTransport
        )
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
            clearFirstAudioPlaybackAckSentState(
                contactID: contactID,
                channelID: envelope.channelId,
                senderDeviceID: envelope.fromDeviceId
            )
            markRemoteAudioActivity(for: contactID, source: .transmitPrepareSignal)
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
                clearFirstAudioPlaybackAckSentState(
                    contactID: contactID,
                    channelID: envelope.channelId,
                    senderDeviceID: envelope.fromDeviceId
                )
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
                clearFirstAudioPlaybackAckSentState(
                    contactID: contactID,
                    channelID: envelope.channelId,
                    senderDeviceID: envelope.fromDeviceId
                )
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
            let suppressReceiverReadinessRegressionDuringPlaybackDrain =
                remoteReceiveBlocksLocalTransmit(for: contactID)
                && (envelope.type == .receiverReady || readiness != .ready)
            if suppressReceiverReadinessRegressionDuringPlaybackDrain {
                diagnostics.record(
                    .websocket,
                    message: "Ignored receiver audio readiness regression during playback drain",
                    metadata: [
                        "type": envelope.type.rawValue,
                        "channelId": envelope.channelId,
                        "contactId": contactID.uuidString,
                        "payload": envelope.payload,
                        "reason": readinessReason.wireValue,
                        "readiness": String(describing: readiness),
                    ]
                )
            } else if let existing = channelReadinessByContactID[contactID] {
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
                applyChannelReadiness(
                    updatedReadiness,
                    for: contactID,
                    reason: "receiver-audio-readiness-signal"
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
            if suppressReceiverReadinessRegressionDuringPlaybackDrain {
                return
            }
            let shouldEchoReadyAfterPeerReconnect =
                readiness == .ready
                && readinessReason.requestsReciprocalReceiverReadinessAfterReconnect
            Task {
                if readiness == .ready {
                    await resumeLocalInteractivePrewarmForRemoteReady(
                        contactID: contactID,
                        applicationState: applicationState
                    )
                    if shouldEchoReadyAfterPeerReconnect {
                        controlPlaneCoordinator.send(
                            .receiverAudioReadinessCacheCleared(contactID: contactID)
                        )
                        await syncLocalReceiverAudioReadinessSignal(
                            for: contactID,
                            reason: .receiverPrewarmRequest
                        )
                    }
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
        case .audioPlaybackStarted:
            do {
                let payload = try envelope.decodeAudioPlaybackStartedPayload()
                diagnostics.record(
                    .websocket,
                    message: "Audio playback ACK signal received",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "fromDeviceId": envelope.fromDeviceId,
                        "toDeviceId": envelope.toDeviceId,
                        "transportDigest": payload.transportDigest,
                        "ackId": payload.ackId,
                    ]
                )
                handleAudioPlaybackStartedAck(
                    payload,
                    contactID: contactID,
                    source: .backendWebSocket
                )
            } catch {
                diagnostics.record(
                    .websocket,
                    level: .error,
                    message: "Rejected audio playback ACK signal because payload was invalid",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "fromDeviceId": envelope.fromDeviceId,
                        "error": error.localizedDescription,
                    ]
                )
            }
        case .directQuicUpgradeRequest:
            handleIncomingDirectQuicUpgradeRequest(envelope, contactID: contactID)
        case .selectedPeerPrewarm:
            handleIncomingSelectedPeerPrewarmHint(envelope, contactID: contactID)
        case .callContext:
            applyPeerCallContextPayload(
                envelope.payload,
                for: contactID,
                source: envelope.type.rawValue
            )
            if selectedContactId == contactID {
                updateStatusForSelectedContact()
                captureDiagnosticsState("backend-signal:\(envelope.type.rawValue)")
            }
        case .offer, .answer, .iceCandidate, .hangup:
            handleIncomingDirectQuicControlSignal(envelope, contactID: contactID)
        }
    }

    func handleIncomingSelectedPeerPrewarmHint(
        _ envelope: TurboSignalEnvelope,
        contactID: UUID
    ) {
        guard let backend = backendServices else { return }
        let payload: TurboSelectedPeerPrewarmPayload
        do {
            payload = try envelope.decodeSelectedPeerPrewarmPayload()
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected selected peer prewarm hint because payload was invalid",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "fromDeviceId": envelope.fromDeviceId,
                    "toDeviceId": envelope.toDeviceId,
                    "error": error.localizedDescription,
                ]
            )
            return
        }
        var metadata = [
            "contactId": contactID.uuidString,
            "channelId": envelope.channelId,
            "requestId": payload.requestId,
            "reason": payload.reason,
            "fromDeviceId": envelope.fromDeviceId,
            "toDeviceId": envelope.toDeviceId,
        ]

        guard envelope.toDeviceId == backend.deviceID,
              payload.fromDeviceId == envelope.fromDeviceId,
              payload.channelId == envelope.channelId,
              payload.toDeviceId.isEmpty || payload.toDeviceId == backend.deviceID else {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected selected peer prewarm hint because envelope and payload disagree",
                metadata: metadata
            )
            return
        }

        if let contact = contacts.first(where: { $0.id == contactID }),
           let remoteUserId = contact.remoteUserId,
           remoteUserId != envelope.fromUserId {
            metadata["expectedRemoteUserId"] = remoteUserId
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Rejected selected peer prewarm hint from unexpected peer user",
                metadata: metadata
            )
            return
        }

        recentPeerDeviceEvidenceByContactID[contactID] = RecentPeerDeviceEvidence(
            deviceId: envelope.fromDeviceId,
            channelId: envelope.channelId,
            reason: "selected-peer-prewarm:\(payload.reason)",
            observedAt: Date()
        )
        metadata["recordedPeerDeviceId"] = envelope.fromDeviceId

        if let blockReason = selectedPeerPrewarmHintBlockReason(for: contactID) {
            metadata["blockReason"] = blockReason
            diagnostics.record(
                .websocket,
                message: "Ignored selected peer prewarm hint because receiver is not warmable",
                metadata: metadata
            )
            return
        }

        diagnostics.record(
            .websocket,
            message: "Selected peer prewarm hint received",
            metadata: metadata
        )
        if selectedContactId == contactID {
            Task {
                await runSelectedContactPrewarmPipeline(
                    for: contactID,
                    reason: "peer-hint-\(payload.reason)"
                )
            }
        } else {
            diagnostics.record(
                .websocket,
                message: "Deferred selected peer prewarm hint until contact selection",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "reason": payload.reason,
                    "recordedPeerDeviceId": envelope.fromDeviceId,
                ]
            )
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
            reconcileTalkRequestSurface(allowsSelectedContact: true)
            if await resolveRestoredSystemSessionIfPossible(trigger: "contact-summaries") == nil {
                clearUnresolvedRestoredSystemSessionIfNeeded(trigger: "contact-summaries")
            }
            reconcileContactSelectionIfNeeded(
                reason: "contact-summaries",
                allowSelectingFallbackContact: false
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
            if shouldClearBackendJoinSettlingAfterSelfPresenceVisible(
                effectiveChannelState: effectiveChannelState,
                effectiveChannelReadiness: effectiveChannelReadiness,
                localSessionEstablished: localSessionEstablished
            ) {
                backendRuntime.clearBackendJoinSettling(for: contactID)
                diagnostics.record(
                    .backend,
                    message: "Cleared backend join settling after active device became visible",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": backendChannelId,
                        "backendStatus": effectiveChannelState.status,
                        "backendReadiness": effectiveChannelReadiness?.statusKind ?? "none",
                    ]
                )
            }
            if shouldRecoverMissingBackendDevicePresence(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                effectiveChannelReadiness: effectiveChannelReadiness,
                localSessionEstablished: localSessionEstablished
            ) {
                startBackendJoinRecoveryForActiveLocalSession(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    contact: contact,
                    invariantID: "selected.local_session_without_backend_presence",
                    invariantMessage: "local/system session is active, but backend readiness says selfHasActiveDevice=false",
                    backendStatus: effectiveChannelState.status,
                    backendReadiness: effectiveChannelReadiness?.statusKind ?? "none",
                    recoveryMessage: "Repairing missing backend device presence for active local session",
                    captureReason: "backend-presence:self-healed"
                )
            } else if shouldRecoverMissingBackendMembershipForActiveLocalSession(
                contactID: contactID,
                effectiveChannelState: effectiveChannelState,
                localSessionEstablished: localSessionEstablished
            ) {
                startBackendJoinRecoveryForActiveLocalSession(
                    contactID: contactID,
                    backendChannelID: backendChannelId,
                    contact: contact,
                    invariantID: "selected.local_session_without_backend_membership",
                    invariantMessage: "local/system session is active, but backend membership dropped self while the peer remained joined",
                    backendStatus: effectiveChannelState.status,
                    backendReadiness: effectiveChannelReadiness?.statusKind ?? "none",
                    recoveryMessage: "Repairing missing backend membership for active local session",
                    captureReason: "backend-membership:self-healed"
                )
            }
            let leaveWasInFlight = sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
            let shouldPreserveSettlingBackendJoin =
                !effectiveChannelState.membership.hasLocalMembership
                && shouldPreservePendingLocalJoinDuringBackendJoinSettling(for: contactID)
            if shouldPreserveSettlingBackendJoin {
                diagnostics.record(
                    .state,
                    message: "Preserved pending local join during settling backend channel refresh",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": backendChannelId,
                        "backendMembership": String(describing: effectiveChannelState.membership),
                        "backendStatus": effectiveChannelState.status,
                    ]
                )
            } else {
                sessionCoordinator.reconcileAfterChannelRefresh(
                    for: contactID,
                    effectiveChannelState: effectiveChannelState,
                    localSessionEstablished: localSessionEstablished,
                    localSessionCleared: localSessionCleared
                )
            }
            if leaveWasInFlight,
               !sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID) {
                replaceDisconnectRecoveryTask(with: nil)
                updateStatusForSelectedContact()
                captureDiagnosticsState("session-teardown:channel-refresh-complete")
            }
            backendSyncCoordinator.send(
                .channelStateUpdated(contactID: contactID, channelState: effectiveChannelState)
            )
            let setupChannelReadiness =
                effectiveChannelReadiness
                ?? (fetchedChannelReadiness?.peerTargetDeviceId == nil ? nil : fetchedChannelReadiness)
            if let setupChannelReadiness {
                applyChannelReadiness(
                    setupChannelReadiness,
                    for: contactID,
                    reason: "channel-refresh"
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
            if let effectiveChannelReadiness,
               !effectiveChannelReadiness.statusKind.isEmpty {
                let normalizedBackendNotice = normalizedBackendServerNotice(backendStatusMessage)
                let channelReadyClearsTargetDeviceNotice =
                    effectiveChannelReadiness.statusKind == ConversationState.ready.rawValue
                    && normalizedBackendNotice == "target user has no connected receiving device in this channel"
                if backendStatusMessage.hasPrefix("signaling ") || channelReadyClearsTargetDeviceNotice {
                    backendStatusMessage = "Connected"
                }
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
                    refreshedContactID: contactID,
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
                await maybeStartSelectedContactDirectQuicPrewarm(
                    for: contactID,
                    reason: "channel-refresh"
                )
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
                let existingChannelState = backendSyncCoordinator.state.syncState.channelStates[contactID]
                if shouldPreserveSelectedSessionAfterAuthoritativeChannelLoss(
                    contactID: contactID,
                    existing: existingChannelState
                ) {
                    backendSyncCoordinator.send(
                        .channelStateFailed(
                            contactID: contactID,
                            message: "Channel sync failed: \(error.localizedDescription)"
                        )
                    )
                    diagnostics.record(
                        .channel,
                        level: .info,
                        message: "Preserving selected session after transient authoritative channel loss",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": backendChannelId,
                            "error": error.localizedDescription,
                        ]
                    )
                    updateStatusForSelectedContact()
                    captureDiagnosticsState("backend-sync:authoritative-channel-loss-preserved")
                    await refreshContactSummaries()
                    await reconcileSelectedSessionIfNeeded()
                    return
                }
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
            reconcileTalkRequestSurface(allowsSelectedContact: true)
            pruneContactsToAuthoritativeState()
            reconcileContactSelectionIfNeeded(
                reason: "invite-sync",
                allowSelectingFallbackContact: false
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

    func shouldRecoverMissingBackendDevicePresence(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        effectiveChannelReadiness: TurboChannelReadinessResponse?,
        localSessionEstablished: Bool
    ) -> Bool {
        guard effectiveChannelState.membership.hasLocalMembership else { return false }
        guard localSessionEstablished else { return false }
        guard effectiveChannelReadiness?.selfHasActiveDevice == false else { return false }
        if currentApplicationState() != .active,
           case .wakeCapable = effectiveChannelReadiness?.localWakeCapability {
            return false
        }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return false }
        guard !sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return false }
        guard !shouldUseLiveCallControlPlaneReconnectGrace(for: contactID) else { return false }
        return !backendRuntime.isBackendJoinSettling(for: contactID)
    }

    func shouldRecoverMissingBackendMembershipForActiveLocalSession(
        contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        localSessionEstablished: Bool
    ) -> Bool {
        guard !effectiveChannelState.membership.hasLocalMembership else { return false }
        guard effectiveChannelState.membership.hasPeerMembership else { return false }
        guard localSessionEstablished else { return false }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return false }
        guard !sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return false }
        guard !shouldUseLiveCallControlPlaneReconnectGrace(for: contactID) else { return false }
        return !backendRuntime.isBackendJoinSettling(for: contactID)
    }

    func startBackendJoinRecoveryForActiveLocalSession(
        contactID: UUID,
        backendChannelID: String,
        contact: Contact,
        invariantID: String,
        invariantMessage: String,
        backendStatus: String,
        backendReadiness: String,
        recoveryMessage: String,
        captureReason: String
    ) {
        diagnostics.recordInvariantViolation(
            invariantID: invariantID,
            scope: .convergence,
            message: invariantMessage,
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": backendChannelID,
                "backendStatus": backendStatus,
                "backendReadiness": backendReadiness,
            ]
        )
        replaceBackendSignalingJoinRecoveryTask(
            with: Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.backendRuntime.signalingJoinRecoveryTask = nil
                    self.updateStatusForSelectedContact()
                }
                self.diagnostics.record(
                    .backend,
                    message: recoveryMessage,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": backendChannelID,
                        "handle": contact.handle,
                    ]
                )
                self.backendServices?.ensureWebSocketConnected()
                await self.reassertBackendJoin(for: contact)
                await self.refreshChannelState(for: contactID)
                await self.refreshContactSummaries()
                await self.syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: .backendSignalingRecovery
                )
                self.captureDiagnosticsState(captureReason)
            }
        )
    }

    func shouldClearBackendJoinSettlingAfterSelfPresenceVisible(
        effectiveChannelState: TurboChannelStateResponse,
        effectiveChannelReadiness: TurboChannelReadinessResponse?,
        localSessionEstablished: Bool
    ) -> Bool {
        guard effectiveChannelState.membership.hasLocalMembership else { return false }
        guard localSessionEstablished else { return false }
        guard effectiveChannelReadiness?.selfHasActiveDevice == true else { return false }
        guard effectiveChannelState.membership.hasPeerMembership || effectiveChannelState.canTransmit else {
            return false
        }
        return effectiveChannelState.canTransmit
            || effectiveChannelReadiness?.statusKind == ConversationState.ready.rawValue
    }
}

private extension ReceiverAudioReadinessReason {
    var requestsReciprocalReceiverReadinessAfterReconnect: Bool {
        switch self {
        case .websocketConnected, .backendReconnect:
            return true
        case .appBackgroundMediaClosed,
             .audioRouteChange,
             .audioRoutePreference(_),
             .backendSignalingRecovery,
             .channelRefresh,
             .directQuicReceiverPrewarm,
             .directQuicTransmitPrepare,
             .foregroundTalkPrewarm(_),
             .incomingPushForeground,
             .mediaState(_),
             .networkChange,
             .pttSync,
             .pttWakePostActivationRefresh,
             .receiverPrewarmRequest,
             .remoteAudioEndedKeepalive,
             .telemetryRefresh,
             .legacy(_):
            return false
        }
    }
}
