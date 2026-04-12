//
//  PTTViewModel+PTTCallbacks.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk
import AVFAudio
import UIKit

extension PTTViewModel {
    private var shouldArmWakeFlowForIncomingPush: Bool {
        UIApplication.shared.applicationState != .active
    }

    var pttSystemCallbacks: PTTSystemClientCallbacks {
        PTTSystemClientCallbacks(
            receivedEphemeralPushToken: { [weak self] token in
                self?.handleReceivedEphemeralPushToken(token)
            },
            receivedIncomingPush: { [weak self] channelUUID, payload in
                self?.handleReceivedIncomingPTTPush(channelUUID: channelUUID, payload: payload)
            },
            didJoinChannel: { [weak self] channelUUID, reason in
                self?.handleDidJoinChannel(channelUUID, reason: reason)
            },
            didLeaveChannel: { [weak self] channelUUID, reason in
                self?.handleDidLeaveChannel(channelUUID, reason: reason)
            },
            failedToJoinChannel: { [weak self] channelUUID, error in
                self?.handleFailedToJoinChannel(channelUUID, error: error)
            },
            failedToLeaveChannel: { [weak self] channelUUID, error in
                self?.handleFailedToLeaveChannel(channelUUID, error: error)
            },
            didBeginTransmitting: { [weak self] channelUUID, source in
                self?.handleDidBeginTransmitting(channelUUID, source: source)
            },
            didEndTransmitting: { [weak self] channelUUID, source in
                self?.handleDidEndTransmitting(channelUUID, source: source)
            },
            failedToBeginTransmitting: { [weak self] channelUUID, error in
                self?.handleFailedToBeginTransmitting(channelUUID, error: error)
            },
            failedToStopTransmitting: { [weak self] channelUUID, error in
                self?.handleFailedToStopTransmitting(channelUUID, error: error)
            },
            didActivateAudioSession: { [weak self] audioSession in
                self?.handleDidActivateAudioSession(audioSession)
            },
            didDeactivateAudioSession: { [weak self] audioSession in
                self?.handleDidDeactivateAudioSession(audioSession)
            },
            descriptorForRestoredChannel: { [weak self] channelUUID in
                self?.channelDescriptorForRestoredChannel(channelUUID)
                    ?? PTChannelDescriptor(name: "Restored session", image: nil)
            },
            restoredChannel: { [weak self] channelUUID in
                self?.handleRestoredChannel(channelUUID)
            }
        )
    }

    func handleReceivedEphemeralPushToken(_ token: Data) {
        let tokenHex = PTTSystemDisplayPolicy.pushTokenHex(from: token)
        let backendChannelID = activeChannelId.flatMap { activeContactID in
            contacts.first(where: { $0.id == activeContactID })?.backendChannelId
        }
        pushTokenHex = tokenHex
        print("PTT push token:", pushTokenHex)
        Task {
            await pttSystemPolicyCoordinator.handle(
                .ephemeralTokenReceived(tokenHex: tokenHex, backendChannelID: backendChannelID)
            )
            syncPTTSystemPolicyState()
            captureDiagnosticsState("ptt-callback:token")
        }
    }

    func handleReceivedIncomingPTTPush(channelUUID: UUID, payload: TurboPTTPushPayload) {
        let contactID =
            contactId(for: channelUUID)
            ?? contacts.first(where: { $0.backendChannelId == payload.channelId })?.id

        diagnostics.record(
            .pushToTalk,
            message: "Incoming PTT push received",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "event": payload.event.rawValue,
                "channelId": payload.channelId ?? "none",
                "activeSpeaker": payload.activeSpeaker ?? "none",
                "senderDeviceId": payload.senderDeviceId ?? "none",
            ]
        )

        guard let contactID else {
            captureDiagnosticsState("ptt-callback:incoming-push-unmatched")
            return
        }

        switch payload.event {
        case .transmitStart:
            remoteTransmittingContactIDs.insert(contactID)
            if shouldArmWakeFlowForIncomingPush {
                if pttWakeRuntime.hasPendingWake(for: contactID) {
                    pttWakeRuntime.confirmIncomingPush(for: channelUUID, payload: payload)
                } else {
                    pttWakeRuntime.store(
                        PendingIncomingPTTPush(
                            contactID: contactID,
                            channelUUID: channelUUID,
                            payload: payload,
                            hasConfirmedIncomingPush: true
                        )
                    )
                }
                scheduleWakePlaybackFallback(for: contactID)
            } else {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored foreground wake flow for incoming PTT push",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "event": payload.event.rawValue,
                    ]
                )
                pttWakeRuntime.clear(for: contactID)
            }
            if selectedContactId == nil {
                selectedContactId = contactID
            }
        case .leaveChannel:
            clearRemoteAudioActivity(for: contactID)
            pttWakeRuntime.clear(for: contactID)
        }

        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-callback:incoming-push")

        Task { [weak self] in
            guard let self else { return }
            if shouldArmWakeFlowForIncomingPush,
               let backendServices,
               backendServices.supportsWebSocket {
                backendServices.ensureWebSocketConnected()
                do {
                    try await backendServices.waitForWebSocketConnection()
                    diagnostics.record(
                        .websocket,
                        message: "WebSocket connected for incoming PTT push",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelUUID": channelUUID.uuidString,
                        ]
                    )
                } catch {
                    diagnostics.record(
                        .websocket,
                        level: .error,
                        message: "WebSocket reconnection failed for incoming PTT push",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelUUID": channelUUID.uuidString,
                            "error": error.localizedDescription,
                        ]
                    )
                }
            }
            if shouldArmWakeFlowForIncomingPush {
                await refreshContactSummaries()
                await refreshChannelState(for: contactID)
            }
        }
    }

    func handleDidJoinChannel(_ channelUUID: UUID, reason: String) {
        let contactID = contactId(for: channelUUID)
        Task {
            await pttCoordinator.handle(
                .didJoinChannel(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: reason
                )
            )
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "Joined channel",
                metadata: ["channelUUID": channelUUID.uuidString, "reason": reason]
            )
            captureDiagnosticsState("ptt-callback:joined")
        }
    }

    func handleDidLeaveChannel(_ channelUUID: UUID, reason: String) {
        let contactID = contactId(for: channelUUID)
        let autoRejoinContactID = sessionCoordinator.autoRejoinContactID(afterLeaving: contactID)
        Task {
            await pttCoordinator.handle(
                .didLeaveChannel(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: reason,
                    autoRejoinContactID: autoRejoinContactID
                )
            )
            if let contactID,
               sessionCoordinator.pendingAction.pendingTeardownContactID == contactID {
                sessionCoordinator.clearLeaveAction(for: contactID)
            }
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "Left channel",
                metadata: ["channelUUID": channelUUID.uuidString, "reason": reason]
            )
            captureDiagnosticsState("ptt-callback:left")
        }
    }

    func handleFailedToJoinChannel(_ channelUUID: UUID, error: any Error) {
        let contactID = contactId(for: channelUUID)
        let joinFailure = classifyPTTJoinFailure(error)
        Task {
            await pttCoordinator.handle(
                .failedToJoinChannel(
                    channelUUID: channelUUID,
                    contactID: contactID,
                    reason: joinFailure
                )
            )
            if let contactID {
                sessionCoordinator.clearPendingJoin(for: contactID)
            }
            syncPTTState()
            updateStatusForSelectedContact()
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Join failed",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID?.uuidString ?? "none",
                    "error": joinFailure.message,
                    "recovery": joinFailure.recoveryMessage
                ]
            )
            captureDiagnosticsState("ptt-callback:join-failed")
        }
    }

    func handleFailedToLeaveChannel(_ channelUUID: UUID, error: any Error) {
        let message = formatPTTError(error)
        Task {
            await pttCoordinator.handle(.failedToLeaveChannel(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Leave failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Leave failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
            captureDiagnosticsState("ptt-callback:leave-failed")
        }
    }

    func handleDidBeginTransmitting(_ channelUUID: UUID, source: String) {
        Task {
            await pttCoordinator.handle(
                .didBeginTransmitting(
                    channelUUID: channelUUID,
                    source: source
                )
            )
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "System transmit began",
                metadata: ["channelUUID": channelUUID.uuidString, "source": source]
            )
            captureDiagnosticsState("ptt-callback:transmit-began")
        }
    }

    func handleDidEndTransmitting(_ channelUUID: UUID, source: String) {
        Task {
            await pttCoordinator.handle(
                .didEndTransmitting(
                    channelUUID: channelUUID,
                    source: source
                )
            )
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "System transmit ended",
                metadata: ["channelUUID": channelUUID.uuidString, "source": source]
            )
            captureDiagnosticsState("ptt-callback:transmit-ended")
        }
    }

    func handleFailedToBeginTransmitting(_ channelUUID: UUID, error: any Error) {
        cancelPendingTransmitWork()
        if isRecoverablePTTChannelUnavailable(error),
           let contactID = contactId(for: channelUUID) {
            diagnostics.record(
                .pushToTalk,
                message: "System transmit begin hit stale channel; rejoining",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID.uuidString,
                    "error": formatPTTError(error)
                ]
            )
            recoverStaleSystemChannel(
                for: channelUUID,
                contactID: contactID,
                reason: "transmit-begin-failed"
            )
            return
        }
        let message = formatPTTError(error)
        Task {
            await pttCoordinator.handle(.failedToBeginTransmitting(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Transmit failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "System transmit begin failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
            captureDiagnosticsState("ptt-callback:transmit-begin-failed")
        }
    }

    func handleFailedToStopTransmitting(_ channelUUID: UUID, error: any Error) {
        if isExpectedPTTStopFailure(error) && !pttCoordinator.state.isTransmitting {
            diagnostics.record(
                .pushToTalk,
                message: "Ignoring expected transmit stop failure",
                metadata: ["channelUUID": channelUUID.uuidString, "error": formatPTTError(error)]
            )
            captureDiagnosticsState("ptt-callback:transmit-stop-ignored")
            return
        }
        let message = formatPTTError(error)
        Task {
            await pttCoordinator.handle(.failedToStopTransmitting(channelUUID: channelUUID, message: message))
            syncPTTState()
            statusMessage = "Stop failed: \(message)"
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "System transmit stop failed",
                metadata: ["channelUUID": channelUUID.uuidString, "error": message]
            )
            captureDiagnosticsState("ptt-callback:transmit-stop-failed")
        }
    }

    func handleRestoredChannel(_ channelUUID: UUID) {
        pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: contactId(for: channelUUID)))
        syncPTTState()
        captureDiagnosticsState("ptt-callback:restored")
    }

    func handleDidActivateAudioSession(_ audioSession: AVAudioSession) {
        diagnostics.record(
            .pushToTalk,
            message: "PTT audio session activated",
            metadata: audioSessionDiagnostics(audioSession)
        )
        Task {
            await handleActivatedAudioSession(audioSession)
            captureDiagnosticsState("ptt-callback:audio-activated")
        }
    }

    func handleDidDeactivateAudioSession(_ audioSession: AVAudioSession) {
        diagnostics.record(
            .pushToTalk,
            message: "PTT audio session deactivated",
            metadata: audioSessionDiagnostics(audioSession)
        )
        Task {
            await handleDeactivatedAudioSession(audioSession)
            captureDiagnosticsState("ptt-callback:audio-deactivated")
        }
    }

    func audioSessionDiagnostics(_ audioSession: AVAudioSession) -> [String: String] {
        let outputs = audioSession.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        let inputs = audioSession.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        return [
            "category": audioSession.category.rawValue,
            "mode": audioSession.mode.rawValue,
            "sampleRate": String(audioSession.sampleRate),
            "outputs": outputs.isEmpty ? "none" : outputs,
            "inputs": inputs.isEmpty ? "none" : inputs
        ]
    }

    func audioSessionDiagnostics() -> [String: String] {
        audioSessionDiagnostics(AVAudioSession.sharedInstance())
    }

    func channelDescriptorForRestoredChannel(_ channelUUID: UUID) -> PTChannelDescriptor {
        let name = PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: channelUUID,
            contacts: contacts,
            fallbackName: channelName
        )
        return PTChannelDescriptor(name: name, image: nil)
    }

    func debugInjectIncomingPTTPush(_ payload: TurboPTTPushPayload, channelUUID: UUID) {
        handleReceivedIncomingPTTPush(channelUUID: channelUUID, payload: payload)
    }
}
