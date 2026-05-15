//
//  PTTViewModel+ControlPlane.swift
//  Turbo
//
//  Created by Codex on 20.04.2026.
//

import Foundation
import UIKit

extension PTTViewModel {
    func receiverAudioReadinessIntent(
        for contactID: UUID,
        reason: ReceiverAudioReadinessReason
    ) -> ReceiverAudioReadinessIntent? {
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let backend = backendServices,
              let backendChannelId = contact.backendChannelId,
              let remoteUserId = contact.remoteUserId else {
            return nil
        }

        let applicationState = currentApplicationState()
        let isReady = reason.isBackgroundMediaClosure
            ? false
            : desiredLocalReceiverAudioReadiness(for: contactID)
        let effectiveReason: ReceiverAudioReadinessReason = {
            guard !isReady else { return reason }
            guard applicationState != .active else { return reason }
            return .appBackgroundMediaClosed
        }()

        return ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: contact.handle,
            backendChannelID: backendChannelId,
            remoteUserID: remoteUserId,
            currentUserID: backend.currentUserID ?? "",
            deviceID: backend.deviceID,
            isReady: isReady,
            reason: effectiveReason,
            telemetry: currentLocalCallTelemetry(includeAudio: isReady)
        )
    }

    func runControlPlaneEffect(_ effect: ControlPlaneEffect) async {
        switch effect {
        case .deferReceiverAudioReadinessUntilReconnect(let intent):
            guard let backend = backendServices else {
                controlPlaneCoordinator.send(
                    .receiverAudioReadinessContextUnavailable(contactID: intent.contactID)
                )
                return
            }
            guard shouldMaintainBackgroundControlPlane() else { return }
            backend.ensureWebSocketConnected()
            diagnostics.record(
                .websocket,
                message: "Deferred receiver audio readiness publish until WebSocket reconnects",
                metadata: [
                    "contactId": intent.contactID.uuidString,
                    "handle": intent.contactHandle,
                    "state": intent.isReady ? "ready" : "not-ready",
                    "reason": intent.reason.wireValue,
                ]
            )

        case .publishReceiverAudioReadiness(let intent):
            await publishReceiverAudioReadiness(intent)

        case .performPostWakeRepair(let contactID):
            await performPostWakeControlPlaneRepair(for: contactID)
        }
    }

    func publishReceiverAudioReadiness(_ intent: ReceiverAudioReadinessIntent) async {
        guard let backend = backendServices else {
            controlPlaneCoordinator.send(
                .receiverAudioReadinessContextUnavailable(contactID: intent.contactID)
            )
            return
        }
        let targetDeviceID = receiverAudioReadinessTargetDeviceID(for: intent.contactID)

        if !intent.isReady,
           !intent.reason.isBackgroundMediaClosure,
           currentApplicationState() != .active {
            diagnostics.recordInvariantViolation(
                invariantID: "receiver.background_not_ready_without_wake_reason",
                scope: .local,
                message: "background receiver-not-ready would be interpreted as ordinary waiting instead of wake-capable",
                metadata: [
                    "contactId": intent.contactID.uuidString,
                    "handle": intent.contactHandle,
                    "reason": intent.reason.wireValue,
                    "applicationState": String(describing: currentApplicationState()),
                ]
            )
        }

        let signalType: TurboSignalKind = intent.isReady ? .receiverReady : .receiverNotReady
        let payload = ReceiverAudioReadinessSignalPayload(
            reason: intent.reason,
            telemetry: intent.telemetry
        ).wirePayload()

        do {
            var publishedTransport = "http"
            if backend.supportsWebSocket, backend.isWebSocketConnected {
                do {
                    try await backend.sendSignal(
                        TurboSignalEnvelope(
                            type: signalType,
                            channelId: intent.backendChannelID,
                            fromUserId: intent.currentUserID,
                            fromDeviceId: intent.deviceID,
                            toUserId: intent.remoteUserID,
                            toDeviceId: targetDeviceID,
                            payload: payload
                        )
                    )
                    publishedTransport = "websocket"
                } catch TurboBackendError.webSocketUnavailable {
                    _ = try await backend.publishReceiverAudioReadiness(
                        channelId: intent.backendChannelID,
                        type: signalType,
                        payload: payload
                    )
                    publishedTransport = "http"
                }
            } else {
                _ = try await backend.publishReceiverAudioReadiness(
                    channelId: intent.backendChannelID,
                    type: signalType,
                    payload: payload
                )
                publishedTransport = "http"
            }
            diagnostics.record(
                publishedTransport == "websocket" ? .websocket : .backend,
                message: "Published receiver audio readiness",
                metadata: [
                    "contactId": intent.contactID.uuidString,
                    "handle": intent.contactHandle,
                    "state": intent.isReady ? "ready" : "not-ready",
                    "reason": intent.reason.wireValue,
                    "targetDeviceId": targetDeviceID.isEmpty ? "server-selected" : targetDeviceID,
                    "transport": publishedTransport,
                ]
            )
            controlPlaneCoordinator.send(.receiverAudioReadinessPublished(intent))
            captureDiagnosticsState("receiver-audio-readiness:published")
        } catch {
            if case TurboBackendError.webSocketUnavailable = error {
                await controlPlaneCoordinator.handle(.receiverAudioReadinessDeferred(intent))
                return
            }

            diagnostics.record(
                .websocket,
                level: .error,
                message: "Receiver audio readiness publish failed",
                metadata: [
                    "contactId": intent.contactID.uuidString,
                    "handle": intent.contactHandle,
                    "state": intent.isReady ? "ready" : "not-ready",
                    "reason": intent.reason.wireValue,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func receiverAudioReadinessTargetDeviceID(for contactID: UUID) -> String {
        directQuicPeerDeviceID(for: contactID) ?? ""
    }

    func performPostWakeControlPlaneRepair(for contactID: UUID) async {
        diagnostics.record(
            .backend,
            message: "Deferring wake backend refresh off audio activation critical path",
            metadata: ["contactId": contactID.uuidString]
        )
        // If the local/system session already proves this receiver is still
        // joined, repair backend membership immediately instead of waiting for
        // potentially slow background refreshes to confirm what we already know.
        var reassertedJoin = await reassertBackendJoinAfterWakeIfNeeded(for: contactID)
        if !reassertedJoin {
            await refreshContactSummaries()
            await refreshChannelState(for: contactID)
            reassertedJoin = await reassertBackendJoinAfterWakeIfNeeded(for: contactID)
        }
        if reassertedJoin {
            await refreshContactSummaries()
            await refreshChannelState(for: contactID)
        }
        await syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: .pttWakePostActivationRefresh
        )
        captureDiagnosticsState("ptt-wake:post-activation-refresh")
        controlPlaneCoordinator.send(.postWakeRepairFinished(contactID: contactID))
    }
}
