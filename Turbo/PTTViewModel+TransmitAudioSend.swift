//
//  PTTViewModel+TransmitAudioSend.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation
import PushToTalk
import AVFAudio
import UIKit

extension PTTViewModel {
    func recordMediaRelayPeerUnavailableInvariantIfNeeded(
        error: Error,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String,
        operation: String
    ) {
        guard case let DirectQuicProbeError.connectionFailed(message) = error,
              message == "media relay peer is unavailable" else { return }
        diagnostics.recordInvariantViolation(
            invariantID: "relay.send_without_live_peer",
            scope: .backend,
            message: "media relay send was attempted after relay reported peer unavailable",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "operation": operation,
                "selectedPeerPhase": String(describing: selectedPeerState(for: contactID).phase),
                "systemSession": String(describing: systemSessionState),
                "error": error.localizedDescription,
            ]
        )
    }

    func shouldTreatTransmitLeaseLossAsStop(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no active transmit state for sender"
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
                            self.recordMediaRelayPeerUnavailableInvariantIfNeeded(
                                error: error,
                                contactID: target.contactID,
                                channelID: target.channelID,
                                peerDeviceID: target.deviceID,
                                operation: "audio-payload"
                            )
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
                            self.mediaRuntime.clearMediaRelayClient(matching: key, client: relayClient)
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
        preconnectMediaRelayForAudioSendIfNeeded(target: target)
    }

    func preconnectMediaRelayForAudioSendIfNeeded(target: TransmitTarget) {
        let shouldAttempt =
            !isDirectPathRelayOnlyForced
            && (TurboMediaRelayDebugOverride.isEnabled()
            || TurboMediaRelayDebugOverride.isForced()
            )
        guard shouldAttempt else { return }
        guard TurboMediaRelayDebugOverride.config()?.isConfigured == true else { return }
        diagnostics.record(
            .media,
            message: "Preconnecting media relay for audio send",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "peerDeviceId": target.deviceID,
                "forced": String(TurboMediaRelayDebugOverride.isForced()),
            ]
        )
        Task { [weak self] in
            guard let self else { return }
            _ = await self.mediaRelayClientForAudioSend(target: target)
        }
    }

    func configuredOutgoingAudioTransportLabel(for contactID: UUID) -> String {
        if isDirectPathRelayOnlyForced {
            return "relay-websocket"
        }
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
                guard let viewModel = self else { return "" }
                return await MainActor.run {
                    viewModel.contacts.first(where: { $0.id == contactID })?.remoteUserId ?? ""
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
            !isDirectPathRelayOnlyForced
                && (TurboMediaRelayDebugOverride.isEnabled() || TurboMediaRelayDebugOverride.isForced())
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
        let localDeviceId = await MainActor.run {
            backendServices?.deviceID ?? backendConfig?.deviceID ?? ""
        }
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
            onIncomingControlFrame: { [weak self] frame in
                await self?.handleIncomingMediaRelayControlFrame(
                    frame,
                    contactID: contactID,
                    channelID: channelID,
                    peerDeviceID: peerDeviceID
                )
            },
            onDisconnected: { [weak self] client in
                guard let viewModel = self else { return }
                await MainActor.run {
                    let key = MediaRelayConnectionKey(
                        sessionID: channelID,
                        localDeviceID: localDeviceID,
                        peerDeviceID: peerDeviceID
                    )
                    viewModel.mediaRuntime.clearMediaRelayClient(matching: key, client: client)
                    viewModel.diagnostics.record(
                        .media,
                        message: "Media relay disconnected; returning to WebSocket relay",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelId": channelID,
                            "peerDeviceId": peerDeviceID,
                        ]
                    )
                }
            },
            reportEvent: { [weak self] message, metadata in
                guard let viewModel = self else { return }
                await MainActor.run {
                    viewModel.diagnostics.record(.media, message: message, metadata: metadata)
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

    func handleIncomingMediaRelayControlFrame(
        _ frame: TurboMediaRelayControlFrame,
        contactID: UUID,
        channelID: String,
        peerDeviceID: String
    ) async {
        do {
            let payload = try DirectQuicReceiverPrewarmPayloadCodec.decode(frame.payload)
            guard payload.channelId == channelID,
                  payload.fromDeviceId == peerDeviceID else {
                await MainActor.run {
                    diagnostics.record(
                        .media,
                        message: "Ignored stale media relay control frame",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "expectedChannelId": channelID,
                            "receivedChannelId": payload.channelId,
                            "expectedPeerDeviceId": peerDeviceID,
                            "receivedPeerDeviceId": payload.fromDeviceId,
                            "kind": frame.kind.rawValue,
                            "requestId": payload.requestId,
                        ]
                    )
                }
                return
            }

            await MainActor.run {
                diagnostics.record(
                    .media,
                    message: "Media relay control frame received",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                        "kind": frame.kind.rawValue,
                        "requestId": payload.requestId,
                    ]
                )
            }

            switch frame.kind {
            case .receiverPrewarmRequest:
                await ingestMediaRelayReceiverPrewarmRequest(payload, contactID: contactID)
            case .receiverPrewarmAck:
                await ingestMediaRelayReceiverPrewarmAck(payload, contactID: contactID)
            }
        } catch {
            await MainActor.run {
                diagnostics.record(
                    .media,
                    level: .error,
                    message: "Media relay control frame decode failed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "peerDeviceId": peerDeviceID,
                        "kind": frame.kind.rawValue,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func prejoinMediaRelayForReadyChannelIfNeeded(
        contactID: UUID,
        channelReadiness: TurboChannelReadinessResponse?
    ) async {
        let shouldAttempt = await MainActor.run {
            !isDirectPathRelayOnlyForced
                && (TurboMediaRelayDebugOverride.isEnabled() || TurboMediaRelayDebugOverride.isForced())
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
                if transmitRuntime.isPressingTalk {
                    diagnostics.record(
                        .media,
                        message: "Wake-capable receiver grace elapsed; releasing outbound audio send gate",
                        metadata: [
                            "contactId": target.contactID.uuidString,
                            "channelId": target.channelID,
                            "waitedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                            "wakeRecoveryGraceMilliseconds": String(wakeRecoveryGraceNanoseconds / 1_000_000),
                        ]
                    )
                    return true
                }
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
        clearForegroundDirectTransmitDelegation(
            for: target.contactID,
            reason: "\(source)-completed-locally"
        )
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-stop:completed-locally")
    }

    func performStopTransmit(_ target: TransmitTarget) async {
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
                    clearForegroundDirectTransmitDelegation(
                        for: target.contactID,
                        reason: "explicit-stop-direct-quic-lease-bypass"
                    )
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

    func performAbortTransmit(_ target: TransmitTarget) async {
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
            clearForegroundDirectTransmitDelegation(
                for: target.contactID,
                reason: "abort-direct-quic-lease-bypass"
            )
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

    func startRenewingTransmit(_ target: TransmitTarget) {
        transmitTaskCoordinator.send(.renewalRequested(target))
    }

    func performTransmitLeaseRenewal(for target: TransmitTarget, workID: Int) async {
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
            localAudioLevel = 0
            backendStatusMessage = "Media failed: \(message)"
        case .connected:
            if let contactID = media.contactID(),
               viewModelWakeStateNeedsClearingAfterRecovery(contactID: contactID) {
                pttWakeRuntime.clear(for: contactID)
            }
        case .closed, .idle, .preparing:
            localAudioLevel = 0
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

    func mediaSession(_ session: MediaSession, didMeasureLocalAudioLevel level: Double) {
        let media = mediaServices
        guard session === media.session() else { return }
        let clampedLevel = max(0, min(1, level))
        let smoothing = clampedLevel > localAudioLevel ? 0.58 : 0.24
        let smoothedLevel = localAudioLevel + (clampedLevel - localAudioLevel) * smoothing
        guard abs(smoothedLevel - localAudioLevel) >= 0.01 || clampedLevel == 0 else { return }
        localAudioLevel = smoothedLevel
    }

    private func viewModelWakeStateNeedsClearingAfterRecovery(contactID: UUID) -> Bool {
        pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd
    }

    private func shouldPreserveAudioSessionDuringMediaClose() -> Bool {
        pttWakeRuntime.pendingIncomingPush != nil
    }

    func precreateSelectedContactMediaShellIfNeeded(
        for contactID: UUID,
        reason: String,
        applicationState: UIApplication.State? = nil
    ) {
        #if targetEnvironment(simulator)
        return
        #else
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return }
        guard contacts.contains(where: { $0.id == contactID }) else { return }
        guard !isTransmitting else { return }
        guard !isPTTAudioSessionActive else { return }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return }
        guard mediaSessionContactID == nil || mediaSessionContactID == contactID else { return }

        _ = prepareMediaSessionShellIfNeeded(
            for: contactID,
            reason: "selected-contact-\(reason)"
        )
        #endif
    }

    func publishSelectedPeerPrewarmHintIfPossible(
        for contactID: UUID,
        reason: String
    ) async {
        guard selectedPeerPrewarmPublishBlockReason(for: contactID) == nil else {
            diagnostics.record(
                .websocket,
                message: "Selected peer prewarm hint skipped",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": selectedPeerPrewarmPublishBlockReason(for: contactID) ?? "unknown",
                ]
            )
            return
        }
        guard let backend = backendServices, let currentUserID = backend.currentUserID else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let channelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId else {
            diagnostics.record(
                .websocket,
                message: "Selected peer prewarm hint skipped because routing metadata is missing",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }

        // Pre-call selection hints should follow the backend's fresh presence
        // routing instead of trusting a possibly stale cached peer device.
        let peerDeviceID = ""
        let payload = TurboSelectedPeerPrewarmPayload(
            requestId: UUID().uuidString.lowercased(),
            channelId: channelID,
            fromDeviceId: backend.deviceID,
            toDeviceId: peerDeviceID,
            reason: reason
        )

        do {
            let envelope = try TurboSignalEnvelope.selectedPeerPrewarm(
                channelId: channelID,
                fromUserId: currentUserID,
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: payload
            )
            try await backend.sendSignal(envelope)
            diagnostics.record(
                .websocket,
                message: "Selected peer prewarm hint sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "requestId": payload.requestId,
                    "reason": reason,
                    "targetDeviceId": peerDeviceID.isEmpty ? "prejoin-fresh-device" : peerDeviceID,
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .notice,
                message: "Selected peer prewarm hint send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func selectedPeerPrewarmPublishBlockReason(for contactID: UUID) -> String? {
        guard let backend = backendServices else { return "backend-unavailable" }
        guard backend.supportsWebSocket else { return "websocket-unsupported" }
        guard backend.currentUserID != nil else { return "missing-current-user" }
        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            return "missing-contact"
        }
        guard contact.backendChannelId != nil else { return "missing-channel-id" }
        guard contact.remoteUserId != nil else { return "missing-remote-user-id" }
        return nil
    }

    func selectedPeerPrewarmHintBlockReason(
        for contactID: UUID,
        applicationState: UIApplication.State? = nil
    ) -> String? {
        let applicationState = applicationState ?? currentApplicationState()
        guard applicationState == .active else { return "not-foreground" }
        guard contacts.contains(where: { $0.id == contactID }) else { return "missing-contact" }
        guard !isJoined, activeChannelId == nil else { return "local-session-active" }
        guard sessionCoordinator.pendingAction == .none else { return "local-session-transition" }
        guard !isTransmitting else { return "transmitting" }
        guard !isPTTAudioSessionActive else { return "ptt-audio-active" }
        guard pttWakeRuntime.pendingIncomingPush == nil else { return "incoming-wake-pending" }
        guard mediaSessionContactID == nil || mediaSessionContactID == contactID else {
            return "other-media-session-active"
        }
        return nil
    }

    @discardableResult
    func prepareMediaSessionShellIfNeeded(
        for contactID: UUID,
        reason: String
    ) -> Bool {
        guard contacts.contains(where: { $0.id == contactID }) else { return false }
        let media = mediaServices
        let existingMediaContactID = media.contactID()
        let sessionNeedsContactSwitch =
            existingMediaContactID != nil && existingMediaContactID != contactID
        let sessionNeedsRecreation = shouldRecreateMediaSession(connectionState: mediaConnectionState)

        if sessionNeedsContactSwitch {
            closeMediaSession()
        }

        if sessionNeedsRecreation {
            closeMediaSession(
                preserveDirectQuic: shouldUseDirectQuicTransport(for: contactID)
            )
        }

        guard !media.hasSession() else { return false }

        let sessionCreationStartedAt = Date()
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
        diagnostics.record(
            .media,
            message: "Media session shell prepared",
            metadata: [
                "contactId": contactID.uuidString,
                "supportsWebSocket": String(supportsWebSocket),
                "durationMs": String(Int(Date().timeIntervalSince(sessionCreationStartedAt) * 1000)),
                "reason": reason,
            ]
        )
        return true
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
            _ = prepareMediaSessionShellIfNeeded(
                for: contactID,
                reason: sessionNeedsCreation ? "created" : sessionNeedsContactSwitch ? "contact-switch" : "recreated"
            )
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
            let startRequestedAt = Date()
            try await media.session()?.start(
                activationMode: resolvedActivationMode,
                startupMode: startupMode
            )
            diagnostics.record(
                .media,
                message: "Media session start await completed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "activationMode": String(describing: resolvedActivationMode),
                    "startupMode": String(describing: startupMode),
                    "durationMs": String(Int(Date().timeIntervalSince(startRequestedAt) * 1000)),
                ]
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
        preserveDirectQuic: Bool = false,
        preserveMediaRelay: Bool = false
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
        if preserveMediaRelay {
            diagnostics.record(
                .media,
                message: "Preserving fast relay media path during media close",
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
        mediaServices.reset(shouldDeactivateAudioSession, preserveDirectQuic, preserveMediaRelay)
    }

    func shouldPreserveMediaRelayDuringMediaClose(for contactID: UUID) -> Bool {
        guard mediaSessionContactID == contactID else { return false }
        guard mediaRuntime.hasActiveMediaRelayClient else { return false }
        return mediaTransportPathState == .fastRelay
    }
}
