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
    func resolvedSystemSessionContactID() -> UUID? {
        if let activeContactID = pttCoordinator.state.activeContactID {
            return activeContactID
        }
        guard let systemChannelUUID = pttCoordinator.state.systemChannelUUID else { return nil }
        return contactId(for: systemChannelUUID)
    }

    func resolvedSystemSessionBackendChannelID() -> String? {
        guard let contactID = resolvedSystemSessionContactID() else { return nil }
        return contacts.first(where: { $0.id == contactID })?.backendChannelId
    }

    private var shouldArmWakeFlowForIncomingPush: Bool {
        currentApplicationState() != .active
    }

    func resumeWebSocketForIncomingPTTPushIfNeeded(
        backendServices: BackendServices,
        contactID: UUID,
        channelUUID: UUID,
        payload: TurboPTTPushPayload
    ) {
        guard backendServices.supportsWebSocket else { return }
        diagnostics.record(
            .websocket,
            message: "Resuming WebSocket for incoming PTT push",
            metadata: [
                "contactId": contactID.uuidString,
                "channelUUID": channelUUID.uuidString,
                "event": payload.event.rawValue,
                "webSocketConnected": String(backendServices.isWebSocketConnected),
            ]
        )
        backendServices.resumeWebSocket()
    }

    var pttSystemCallbacks: PTTSystemClientCallbacks {
        PTTSystemClientCallbacks(
            receivedEphemeralPushToken: { [weak self] token in
                self?.handleReceivedEphemeralPushToken(token)
            },
            receivedIncomingPush: { [weak self] channelUUID, payload in
                self?.handleReceivedIncomingPTTPush(channelUUID: channelUUID, payload: payload)
            },
            willReturnIncomingPushResult: { [weak self] channelUUID, payload, result in
                self?.handleWillReturnIncomingPushResult(
                    channelUUID: channelUUID,
                    payload: payload,
                    result: result
                )
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
            willRequestRestoredChannelDescriptor: { [weak self] channelUUID in
                self?.handleWillRequestRestoredChannelDescriptor(channelUUID)
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
        let backendChannelID = resolvedSystemSessionBackendChannelID()
        pushTokenHex = tokenHex
        diagnostics.record(
            .pushToTalk,
            message: "Received ephemeral PTT token",
            metadata: [
                "backendChannelId": backendChannelID ?? "none",
                "tokenPrefix": String(tokenHex.prefix(8)),
                "activeContactId": activeChannelId?.uuidString ?? "none",
                "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
            ]
        )
        Task {
            await pttSystemPolicyCoordinator.handle(
                .ephemeralTokenReceived(tokenHex: tokenHex, backendChannelID: backendChannelID)
            )
            syncPTTSystemPolicyState()
            captureDiagnosticsState("ptt-callback:token")
        }
    }

    @discardableResult
    func resolveRestoredSystemSessionIfPossible(trigger: String) async -> UUID? {
        guard case .mismatched(let channelUUID) = pttCoordinator.state.systemSessionState else {
            return nil
        }
        guard let contactID = contactId(for: channelUUID),
              let contact = contacts.first(where: { $0.id == contactID }) else {
            return nil
        }

        pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: contactID))
        syncPTTState()
        diagnostics.record(
            .pushToTalk,
            message: "Resolved restored PTT channel contact",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID.uuidString,
                "handle": contact.handle,
                "trigger": trigger,
            ]
        )
        syncPTTSystemChannelDescriptor(channelUUID, reason: "resolved-restored-channel")
        syncPTTServiceStatus(reason: "resolved-restored-channel")
        if let backendChannelID = contact.backendChannelId {
            await pttSystemPolicyCoordinator.handle(.backendChannelReady(backendChannelID))
            syncPTTSystemPolicyState()
        }
        await prewarmLocalMediaIfNeeded(for: contactID)
        captureDiagnosticsState("ptt-callback:restored-resolved")
        return contactID
    }

    func handleWillReturnIncomingPushResult(
        channelUUID: UUID,
        payload: TurboPTTPushPayload,
        result: String
    ) {
        let contactID =
            contactId(for: channelUUID)
            ?? contacts.first(where: { $0.backendChannelId == payload.channelId })?.id
        diagnostics.record(
            .pushToTalk,
            message: "Returning incoming PTT push result",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "event": payload.event.rawValue,
                "result": result,
                "applicationState": String(describing: UIApplication.shared.applicationState),
                "contactId": contactID?.uuidString ?? "none",
                "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
            ]
        )
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

        if shouldArmWakeFlowForIncomingPush,
           payload.event == .transmitStart,
           pttWakeRuntime.shouldIgnoreDuplicateIncomingPush(
                for: contactID,
                channelUUID: channelUUID,
                payload: payload
           ) {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored duplicate incoming PTT push while wake is already pending",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "event": payload.event.rawValue,
                ]
            )
            captureDiagnosticsState("ptt-callback:incoming-push-duplicate")
            return
        }

        switch payload.event {
        case .transmitStart:
            pttWakeRuntime.clearProvisionalWakeCandidateSuppression(for: contactID)
            markRemoteAudioActivity(for: contactID, source: .incomingPush)
            if shouldArmWakeFlowForIncomingPush {
                if pttWakeRuntime.hasPendingWake(for: contactID) {
                    pttWakeRuntime.confirmIncomingPush(for: channelUUID, payload: payload)
                } else {
                    pttWakeRuntime.store(
                        PendingIncomingPTTPush(
                            contactID: contactID,
                            channelUUID: channelUUID,
                            payload: payload,
                            hasConfirmedIncomingPush: true,
                            activationState: .awaitingSystemActivation
                        )
                    )
                }
                pttWakeRuntime.clearPlaybackFallbackTask(for: contactID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Awaiting system PTT audio activation",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "event": payload.event.rawValue,
                    ]
                )
                scheduleWakePlaybackFallback(for: contactID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Reinforcing active remote participant during incoming push",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "participant": payload.participantName,
                    ]
                )
                Task { [weak self] in
                    await self?.reinforceIncomingPushRemoteParticipant(
                        channelUUID: channelUUID,
                        contactID: contactID,
                        payload: payload
                    )
                }
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
                Task { [weak self] in
                    await self?.prepareForegroundReceivePathForIncomingPush(contactID: contactID)
                }
            }
            if selectedContactId == nil {
                selectedContactId = contactID
            }
        case .leaveChannel:
            pttWakeRuntime.suppressProvisionalWakeCandidate(for: contactID)
            clearRemoteAudioActivity(for: contactID)
            pttWakeRuntime.clear(for: contactID)
        }

        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-callback:incoming-push")

        if shouldArmWakeFlowForIncomingPush {
            if let backendServices,
               backendServices.supportsWebSocket {
                resumeWebSocketForIncomingPTTPushIfNeeded(
                    backendServices: backendServices,
                    contactID: contactID,
                    channelUUID: channelUUID,
                    payload: payload
                )
            }
            diagnostics.record(
                .pushToTalk,
                message: "Deferring incoming-push backend sync until PTT audio activation",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "event": payload.event.rawValue,
                ]
            )
        }
    }

    private func prepareForegroundReceivePathForIncomingPush(contactID: UUID) async {
        guard currentApplicationState() == .active else { return }
        guard isJoined, activeChannelId == contactID else { return }
        guard systemSessionMatches(contactID) else { return }
        guard !isTransmitting else { return }

        diagnostics.record(
            .pushToTalk,
            message: "Preparing foreground receive path from incoming PTT push",
            metadata: ["contactId": contactID.uuidString]
        )
        await reassertBackendJoinAfterWakeIfNeeded(for: contactID)
        await prewarmLocalMediaIfNeeded(for: contactID, applicationState: .active)
        await syncLocalReceiverAudioReadinessSignal(
            for: contactID,
            reason: "incoming-push-foreground"
        )
    }

    private func reinforceIncomingPushRemoteParticipant(
        channelUUID: UUID,
        contactID: UUID,
        payload: TurboPTTPushPayload
    ) async {
        do {
            try await pttSystemClient.setActiveRemoteParticipant(
                name: payload.participantName,
                channelUUID: channelUUID
            )
            diagnostics.record(
                .pushToTalk,
                message: "Reinforced active remote participant from incoming push",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "participant": payload.participantName,
                ]
            )
        } catch {
            if isRecoverablePTTChannelUnavailable(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Deferred incoming-push participant reinforcement until system channel is available",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelUUID": channelUUID.uuidString,
                        "participant": payload.participantName,
                        "error": error.localizedDescription,
                    ]
                )
                return
            }
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Failed to reinforce active remote participant from incoming push",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID.uuidString,
                    "participant": payload.participantName,
                    "error": error.localizedDescription,
                ]
            )
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
            syncPTTSystemChannelDescriptor(channelUUID, reason: "did-join")
            syncPTTServiceStatus(reason: "did-join")
            diagnostics.record(
                .pushToTalk,
                message: "Joined channel",
                metadata: ["channelUUID": channelUUID.uuidString, "reason": reason]
            )
            if let contactID {
                await prewarmLocalMediaIfNeeded(for: contactID)
            }
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
            lastReportedPTTServiceStatus = nil
            lastReportedPTTServiceStatusChannelUUID = nil
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
        if joinFailure == .channelLimitReached,
           let contactID {
            diagnostics.record(
                .pushToTalk,
                message: "System join hit stale channel limit; rejoining",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactID": contactID.uuidString,
                    "error": joinFailure.message,
                ]
            )
            recoverStaleSystemChannel(
                for: channelUUID,
                contactID: contactID,
                reason: "join-failed-channel-limit"
            )
            return
        }
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
            let callbackTarget = activeTransmitTarget(for: channelUUID)
            await pttCoordinator.handle(
                .didBeginTransmitting(
                    channelUUID: channelUUID,
                    source: source
                )
            )
            transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
            transmitRuntime.noteSystemTransmitBegan()
            syncPTTState()
            diagnostics.record(
                .pushToTalk,
                message: "System transmit began",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "source": source,
                    "applicationState": String(describing: UIApplication.shared.applicationState),
                    "activeContactId": (callbackTarget?.contactID ?? contactId(for: channelUUID))?.uuidString ?? "none",
                    "activeChannelId": callbackTarget?.channelID ?? "none",
                    "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                    "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                    "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                    "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                    "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                ]
            )
            if callbackTarget == nil {
                handleSystemOriginatedBeginTransmitIfNeeded(
                    channelUUID: channelUUID,
                    source: source
                )
            }
            captureDiagnosticsState("ptt-callback:transmit-began")
        }
    }

    func handleDidEndTransmitting(_ channelUUID: UUID, source: String) {
        Task {
            let matchingActiveTarget = activeTransmitTarget(for: channelUUID)
            let hasPendingLifecycle = hasPendingTransmitLifecycle(for: channelUUID)
            let transmitDurationMilliseconds = transmitRuntime.currentSystemTransmitDurationMilliseconds()
            let applicationState = currentApplicationState()
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
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "source": source,
                    "transmitPressActive": String(transmitRuntime.isPressingTalk),
                    "explicitStopRequested": String(transmitRuntime.explicitStopRequested),
                    "hasMatchingActiveTarget": String(matchingActiveTarget != nil),
                    "hasPendingLifecycle": String(hasPendingLifecycle),
                    "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                    "applicationState": String(describing: applicationState),
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                    "activeContactId": matchingActiveTarget?.contactID.uuidString ?? "none",
                    "activeChannelId": matchingActiveTarget?.channelID ?? "none",
                    "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                    "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                    "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                    "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                    "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                ]
            )
            switch transmitRuntime.handleSystemTransmitEnded(
                applicationStateIsActive: applicationState == .active,
                matchingActiveTarget: matchingActiveTarget
            ) {
            case .implicitRelease:
                diagnostics.record(
                    .pushToTalk,
                    message: "Treating background system transmit end as implicit release",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "source": source,
                        "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                        "applicationState": String(describing: applicationState),
                        "activeContactId": matchingActiveTarget?.contactID.uuidString ?? "none",
                        "activeChannelId": matchingActiveTarget?.channelID ?? "none",
                        "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                        "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                        "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                        "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                        "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                    ]
                )
            case .requireFreshPress:
                diagnostics.record(
                    .pushToTalk,
                    message: "Unexpected system transmit end requires fresh press",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "source": source,
                        "systemTransmitDurationMs": transmitDurationMilliseconds.map(String.init) ?? "unknown",
                        "applicationState": String(describing: applicationState),
                        "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                        "activeContactId": matchingActiveTarget?.contactID.uuidString ?? "none",
                        "activeChannelId": matchingActiveTarget?.channelID ?? "none",
                        "pttServiceStatus": lastReportedPTTServiceStatus.map(String.init(describing:)) ?? "none",
                        "pttServiceStatusReason": lastReportedPTTServiceStatusReason ?? "none",
                        "pttDescriptorName": lastReportedPTTDescriptorName ?? "none",
                        "pttDescriptorReason": lastReportedPTTDescriptorReason ?? "none",
                        "backendWebSocketConnected": String(backendRuntime.isWebSocketConnected),
                    ]
                )
                syncTransmitState()
            case .none:
                break
            }
            if hasPendingLifecycle {
                await transmitCoordinator.handle(.systemEnded)
                syncTransmitState()
            }
            captureDiagnosticsState("ptt-callback:transmit-ended")
        }
    }

    func handleFailedToBeginTransmitting(_ channelUUID: UUID, error: any Error) {
        transmitRuntime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)
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
        let contactID = contactId(for: channelUUID)
        diagnostics.record(
            .pushToTalk,
            message: "Restored PTT channel",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID?.uuidString ?? "none",
                "applicationState": String(describing: UIApplication.shared.applicationState),
            ]
        )
        pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: contactID))
        syncPTTState()
        syncPTTSystemChannelDescriptor(channelUUID, reason: "restored-channel")
        syncPTTServiceStatus(reason: "restored-channel")
        if let contactID {
            Task {
                if let backendChannelID = contacts.first(where: { $0.id == contactID })?.backendChannelId {
                    await pttSystemPolicyCoordinator.handle(.backendChannelReady(backendChannelID))
                    syncPTTSystemPolicyState()
                }
                await prewarmLocalMediaIfNeeded(for: contactID)
            }
        }
        captureDiagnosticsState("ptt-callback:restored")
    }

    func handleDidActivateAudioSession(_ audioSession: AVAudioSession) {
        isPTTAudioSessionActive = true
        diagnostics.record(
            .pushToTalk,
            message: "PTT audio session activated",
            metadata: audioSessionDiagnostics(audioSession).merging(
                [
                    "applicationState": String(describing: UIApplication.shared.applicationState),
                    "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
                    "pendingWakeContactId": pttWakeRuntime.pendingIncomingPush?.contactID.uuidString ?? "none",
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        Task {
            await handleActivatedAudioSession(audioSession)
            captureDiagnosticsState("ptt-callback:audio-activated")
        }
    }

    func handleDidDeactivateAudioSession(_ audioSession: AVAudioSession) {
        isPTTAudioSessionActive = false
        diagnostics.record(
            .pushToTalk,
            message: "PTT audio session deactivated",
            metadata: audioSessionDiagnostics(audioSession).merging(
                [
                    "applicationState": String(describing: UIApplication.shared.applicationState),
                    "pendingWakeChannelUUID": pttWakeRuntime.pendingIncomingPush?.channelUUID.uuidString ?? "none",
                    "pendingWakeContactId": pttWakeRuntime.pendingIncomingPush?.contactID.uuidString ?? "none",
                ],
                uniquingKeysWith: { _, new in new }
            )
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

    func handleWillRequestRestoredChannelDescriptor(_ channelUUID: UUID) {
        diagnostics.record(
            .pushToTalk,
            message: "PTT restored channel descriptor requested",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactId(for: channelUUID)?.uuidString ?? "none",
                "applicationState": String(describing: UIApplication.shared.applicationState),
            ]
        )
    }

    func channelDescriptorForRestoredChannel(_ channelUUID: UUID) -> PTChannelDescriptor {
        let name = systemDescriptorName(for: channelUUID)
        // TODO: Return a cached per-channel image once we persist it locally.
        return PTChannelDescriptor(name: name, image: nil)
    }

    func debugInjectIncomingPTTPush(_ payload: TurboPTTPushPayload, channelUUID: UUID) {
        handleReceivedIncomingPTTPush(channelUUID: channelUUID, payload: payload)
    }
}
