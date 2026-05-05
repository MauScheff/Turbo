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
        reason: String
    ) -> ReceiverAudioReadinessIntent? {
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let backend = backendServices,
              backend.supportsWebSocket,
              let backendChannelId = contact.backendChannelId,
              let remoteUserId = contact.remoteUserId else {
            return nil
        }

        let isBackgroundMediaClosure = reason == "app-background-media-closed"
        let isReady = isBackgroundMediaClosure
            ? false
            : desiredLocalReceiverAudioReadiness(for: contactID)
        let effectiveReason: String = {
            guard !isReady else { return reason }
            let appState = currentApplicationState()
            guard appState != .active else { return reason }
            if reason == "app-background-media-closed" || reason.hasPrefix("media-") {
                return "app-background-media-closed"
            }
            return reason
        }()

        return ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: contact.handle,
            backendChannelID: backendChannelId,
            remoteUserID: remoteUserId,
            currentUserID: backend.currentUserID ?? "",
            deviceID: backend.deviceID,
            isReady: isReady,
            reason: effectiveReason
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
                    "reason": intent.reason,
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

        do {
            try await backend.waitForWebSocketConnection()
            try await backend.sendSignal(
                TurboSignalEnvelope(
                    type: intent.isReady ? .receiverReady : .receiverNotReady,
                    channelId: intent.backendChannelID,
                    fromUserId: intent.currentUserID,
                    fromDeviceId: intent.deviceID,
                    toUserId: intent.remoteUserID,
                    toDeviceId: intent.deviceID,
                    payload: intent.reason
                )
            )
            diagnostics.record(
                .websocket,
                message: "Published receiver audio readiness",
                metadata: [
                    "contactId": intent.contactID.uuidString,
                    "handle": intent.contactHandle,
                    "state": intent.isReady ? "ready" : "not-ready",
                    "reason": intent.reason,
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
                    "reason": intent.reason,
                    "error": error.localizedDescription,
                ]
            )
        }
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
            reason: "ptt-wake:post-activation-refresh"
        )
        captureDiagnosticsState("ptt-wake:post-activation-refresh")
        controlPlaneCoordinator.send(.postWakeRepairFinished(contactID: contactID))
    }
}
