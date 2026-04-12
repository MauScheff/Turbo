//
//  PTTViewModel+Transmit.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk
import AVFAudio

extension PTTViewModel {
    private var wakePlaybackFallbackDelayNanoseconds: UInt64 { 1_500_000_000 }
    private var mediaSessionRetryCooldown: TimeInterval { 0.75 }

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

    func shouldPreserveLocalTransmitState(
        selectedContactID: UUID?,
        refreshedContactID: UUID,
        backendChannelStatus: String,
        transmitPhase: TransmitPhase,
        systemIsTransmitting: Bool
    ) -> Bool {
        guard selectedContactID == refreshedContactID else { return false }
        if backendChannelStatus == ConversationState.transmitting.rawValue {
            return true
        }
        if systemIsTransmitting {
            return true
        }

        switch transmitPhase {
        case .idle:
            return false
        case .requesting(let contactID), .active(let contactID), .stopping(let contactID):
            return contactID == refreshedContactID
        }
    }

    func beginTransmit() {
        guard isJoined else { return }
        guard let contact = selectedContact else {
            statusMessage = "Pick a contact"
            return
        }
        let transmit = transmitServices
        guard !transmit.hasPendingBeginOrActiveTarget() else { return }
        guard activeChannelId == contact.id else { return }
        guard !remoteTransmittingContactIDs.contains(contact.id) else {
            updateStatusForSelectedContact()
            return
        }
        let selectedPeer = selectedPeerState(for: contact.id)
        let isWakeReady = selectedPeer.phase == .wakeReady

        guard canBeginTransmit(for: contact.id) else {
            updateStatusForSelectedContact()
            return
        }

        if !isWakeReady {
            guard let channelState = selectedChannelState,
                  channelState.canTransmit else {
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
        let request = TransmitRequestContext(
            contactID: contact.id,
            contactHandle: contact.handle,
            backendChannelID: backendChannelId,
            remoteUserID: remoteUserID,
            channelUUID: channelUUID(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend,
            backendSupportsWebSocket: backend.supportsWebSocket
        )
        Task {
            await transmitCoordinator.handle(.pressRequested(request))
            syncTransmitState()
        }
    }

    func endTransmit() {
        guard isJoined else { return }
        diagnostics.record(.media, message: "End transmit requested")
        Task {
            await transmitCoordinator.handle(.releaseRequested)
            syncTransmitState()
            updateStatusForSelectedContact()
        }
    }

    func runTransmitEffect(_ effect: TransmitEffect) async {
        switch effect {
        case .beginTransmit(let request):
            await performBeginTransmit(request)
        case .activateTransmit(let request, let target):
            await performActivateTransmit(request, target: target)
        case .stopTransmit(let target):
            await performStopTransmit(target)
        case .abortTransmit(let target):
            await performAbortTransmit(target)
        }
    }

    private func performBeginTransmit(_ request: TransmitRequestContext) async {
        guard let backend = backendServices else { return }
        let transmit = transmitServices

        transmit.replaceBeginTask(Task { [weak self] in
            guard let self else { return }
            do {
                if request.backendSupportsWebSocket {
                    try await backend.waitForWebSocketConnection()
                }
                let response = try await backend.beginTransmit(channelId: request.backendChannelID)
                let target = TransmitTarget(
                    contactID: request.contactID,
                    userID: request.remoteUserID,
                    deviceID: response.targetDeviceId,
                    channelID: request.backendChannelID
                )
                await transmitCoordinator.handle(.beginSucceeded(target, request))
                syncTransmitState()
            } catch {
                if shouldTreatTransmitBeginMembershipLossAsRecoverable(error) {
                    diagnostics.record(
                        .media,
                        message: "Recovering transmit begin after membership drift",
                        metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID]
                    )
                    if await recoverTransmitBeginMembershipLoss(request: request, backend: backend) {
                        transmit.replaceBeginTask(nil)
                        return
                    }
                }
                let message = error.localizedDescription
                await transmitCoordinator.handle(.beginFailed(message))
                syncTransmitState()
                statusMessage = "Transmit failed: \(message)"
                diagnostics.record(.media, level: .error, message: "Transmit failed", metadata: ["contact": request.contactHandle, "error": message])
            }
            transmit.replaceBeginTask(nil)
        })
    }

    private func recoverTransmitBeginMembershipLoss(
        request: TransmitRequestContext,
        backend: BackendServices
    ) async -> Bool {
        do {
            _ = try await backend.joinChannel(channelId: request.backendChannelID)
            let response = try await backend.beginTransmit(channelId: request.backendChannelID)
            let target = TransmitTarget(
                contactID: request.contactID,
                userID: request.remoteUserID,
                deviceID: response.targetDeviceId,
                channelID: request.backendChannelID
            )
            diagnostics.record(
                .media,
                message: "Recovered transmit membership drift",
                metadata: ["contact": request.contactHandle, "channelId": request.backendChannelID]
            )
            await transmitCoordinator.handle(.beginSucceeded(target, request))
            syncTransmitState()
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

    private func performActivateTransmit(_ request: TransmitRequestContext, target: TransmitTarget) async {
        configureOutgoingAudioRoute(target: target)

        if request.usesLocalHTTPBackend {
            startRenewingTransmit(target)
            isTransmitting = true
        } else {
            guard let channelUUID = request.channelUUID else {
                let message = "PTT channel is not ready"
                statusMessage = message
                await transmitCoordinator.handle(.stopFailed(message))
                syncTransmitState()
                return
            }
            do {
                try pttSystemClient.beginTransmitting(channelUUID: channelUUID)
            } catch {
                let message = error.localizedDescription
                statusMessage = message
                await transmitCoordinator.handle(.stopFailed(message))
                syncTransmitState()
                return
            }
        }

        await refreshChannelState(for: request.contactID)
    }

    func activeTransmitTarget(for systemChannelUUID: UUID) -> TransmitTarget? {
        guard let activeTarget = transmitCoordinator.state.activeTarget else { return nil }
        guard channelUUID(for: activeTarget.contactID) == systemChannelUUID else { return nil }
        return activeTarget
    }

    func completeSystemTransmitActivation(channelUUID: UUID) async {
        guard let target = activeTransmitTarget(for: channelUUID) else { return }
        guard transmitCoordinator.state.isPressingTalk else { return }

        startRenewingTransmit(target)

        guard let backend = backendServices, backend.supportsWebSocket else {
            await refreshChannelState(for: target.contactID)
            return
        }

        do {
            try await backend.waitForWebSocketConnection()
            configureOutgoingAudioRoute(target: target)
            await ensureMediaSession(
                for: target.contactID,
                activationMode: .systemActivated,
                startupMode: .interactive
            )
            configureOutgoingAudioRoute(target: target)
            try await mediaServices.session()?.startSendingAudio()
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
            await performStopTransmit(target)
        }
    }

    func handleActivatedAudioSession(_ audioSession: AVAudioSession) async {
        applyPreferredAudioOutputRoute(to: audioSession)
        let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID
        let activeTarget = activeSystemChannelUUID.flatMap(activeTransmitTarget(for:))
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
            pttWakeRuntime.replacePlaybackFallbackTask(for: wake.contactID, with: nil)
            pttWakeRuntime.markAudioSessionActivated(for: wake.channelUUID)
            diagnostics.record(
                .pushToTalk,
                message: "Handling PTT wake audio activation",
                metadata: [
                    "channelUUID": wake.channelUUID.uuidString,
                    "contactID": wake.contactID.uuidString,
                    "event": wake.payload.event.rawValue,
                ]
            )
            backendServices?.ensureWebSocketConnected()
            await refreshContactSummaries()
            await refreshChannelState(for: wake.contactID)
            let contactID = wake.contactID
            diagnostics.record(
                .media,
                message: "Recreating media session after PTT audio activation",
                metadata: ["contactId": contactID.uuidString]
            )
            closeMediaSession()
            await ensureMediaSession(
                for: contactID,
                activationMode: .systemActivated,
                startupMode: .playbackOnly
            )
            let bufferedAudioChunks = pttWakeRuntime.takeBufferedAudioChunks(for: contactID)
            if !bufferedAudioChunks.isEmpty {
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
            } else {
                diagnostics.record(
                    .media,
                    message: "No buffered wake audio to flush after PTT activation",
                    metadata: ["contactId": contactID.uuidString]
                )
            }
        }

        if activeTarget == nil,
           pendingWake == nil,
           let activeSystemChannelUUID,
           let receiveContactID = contactId(for: activeSystemChannelUUID),
           remoteTransmittingContactIDs.contains(receiveContactID) {
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

    func setAudioOutputPreference(_ preference: AudioOutputPreference) {
        guard preference == .speaker else { return }
        guard audioOutputPreference != preference else {
            applyPreferredAudioOutputRouteIfPossible()
            return
        }
        audioOutputPreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: AudioOutputPreference.storageKey)
        applyPreferredAudioOutputRouteIfPossible()
        diagnostics.record(
            .media,
            message: "Audio output preference updated",
            metadata: ["preference": preference.rawValue]
        )
        captureDiagnosticsState("audio-route:updated")
    }

    func applyPreferredAudioOutputRoute(to audioSession: AVAudioSession = .sharedInstance()) {
        guard audioSession.category == .playAndRecord else {
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

    func handleDeactivatedAudioSession(_ audioSession: AVAudioSession) async {
        let _ = audioSession
        if !pttCoordinator.state.isTransmitting {
            try? await mediaServices.session()?.stopSendingAudio()
        }
        pttWakeRuntime.clearAll()
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

    func runWakePlaybackFallbackIfNeeded(for contactID: UUID) async {
        defer {
            pttWakeRuntime.replacePlaybackFallbackTask(for: contactID, with: nil)
        }

        guard pttWakeRuntime.shouldBufferAudioChunk(for: contactID) else { return }
        let bufferedChunkCount = pttWakeRuntime.bufferedAudioChunkCount(for: contactID)
        guard bufferedChunkCount > 0 else { return }

        let bufferedAudioChunks = pttWakeRuntime.takeBufferedAudioChunks(for: contactID)
        pttWakeRuntime.markAppManagedFallbackStarted(for: contactID)
        diagnostics.record(
            .media,
            message: "PTT activation timed out; falling back to app-managed playback",
            metadata: [
                "contactId": contactID.uuidString,
                "bufferedChunkCount": String(bufferedChunkCount)
            ]
        )

        await ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        for payload in bufferedAudioChunks {
            await receiveRemoteAudioChunk(payload)
        }
    }

    private func configureOutgoingAudioRoute(target: TransmitTarget) {
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

        let sendAudioChunk: @Sendable (String) async throws -> Void = { payload in
            let envelope = TurboSignalEnvelope(
                type: .audioChunk,
                channelId: channelID,
                fromUserId: fromUserID,
                fromDeviceId: fromDeviceID,
                toUserId: toUserID,
                toDeviceId: toDeviceID,
                payload: payload
            )
            try await backend.sendSignal(envelope)
        }
        mediaServices.replaceSendAudioChunk(sendAudioChunk)
        mediaServices.session()?.updateSendAudioChunk(sendAudioChunk)
        diagnostics.record(
            .media,
            message: "Configured outgoing audio transport",
            metadata: [
                "contactId": target.contactID.uuidString,
                "channelId": target.channelID,
                "deviceId": target.deviceID
            ]
        )
    }

    private func performStopTransmit(_ target: TransmitTarget) async {
        let transmit = transmitServices
        let media = mediaServices
        transmit.clearPendingWork()

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
                _ = try await backend.endTransmit(channelId: target.channelID)
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
            await transmitCoordinator.handle(.stopCompleted)
            syncTransmitState()
        } catch {
            let message = error.localizedDescription
            statusMessage = "Stop failed: \(message)"
            await refreshChannelState(for: target.contactID)
            await transmitCoordinator.handle(.stopFailed(message))
            syncTransmitState()
        }

        updateStatusForSelectedContact()
    }

    private func performAbortTransmit(_ target: TransmitTarget) async {
        transmitServices.clearPendingWork()
        try? await mediaServices.session()?.stopSendingAudio()

        if let backend = backendServices {
            _ = try? await backend.endTransmit(channelId: target.channelID)
        }

        await refreshChannelState(for: target.contactID)
        syncTransmitState()
        updateStatusForSelectedContact()
    }

    private func startRenewingTransmit(_ target: TransmitTarget) {
        let transmit = transmitServices
        transmit.replaceRenewTask(nil)
        guard let backend = backendServices else { return }
        transmit.replaceRenewTask(Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard transmitCoordinator.state.isPressingTalk,
                      transmit.activeTarget()?.channelID == target.channelID else { return }
                do {
                    _ = try await backend.renewTransmit(channelId: target.channelID)
                } catch {
                    if isExpectedBackendSyncCancellation(error)
                        || !transmitCoordinator.state.isPressingTalk
                        || !pttCoordinator.state.isTransmitting {
                        return
                    }
                    if shouldTreatTransmitLeaseLossAsStop(error) {
                        if !usesLocalHTTPBackend,
                           let channelUUID = channelUUID(for: target.contactID) {
                            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
                        }
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
                        await MainActor.run {
                            self.isTransmitting = false
                        }
                        await transmitCoordinator.handle(.stopCompleted)
                        syncTransmitState()
                        await refreshChannelState(for: target.contactID)
                        updateStatusForSelectedContact()
                        return
                    }
                    let message = error.localizedDescription
                    await MainActor.run {
                        self.statusMessage = "Transmit lease expired: \(message)"
                        self.isTransmitting = false
                        self.diagnostics.record(.media, level: .error, message: "Transmit lease renewal failed", metadata: ["channelId": target.channelID, "error": message])
                    }
                    await transmitCoordinator.handle(.renewalFailed(message))
                    syncTransmitState()
                    await refreshChannelState(for: target.contactID)
                    return
                }
            }
        })
    }

    func mediaSession(_ session: MediaSession, didChange state: MediaConnectionState) {
        let media = mediaServices
        guard session === media.session() else { return }
        media.updateConnectionState(state)
        diagnostics.record(.media, message: "Media state changed", metadata: ["state": String(describing: state)])
        switch state {
        case .failed(let message):
            backendStatusMessage = "Media failed: \(message)"
        case .connected, .closed, .idle, .preparing:
            break
        }
    }

    func ensureMediaSession(
        for contactID: UUID,
        activationMode: MediaSessionActivationMode? = nil,
        startupMode: MediaSessionStartupMode = .interactive
    ) async {
        guard contacts.contains(where: { $0.id == contactID }) else { return }
        let media = mediaServices
        let sessionNeedsContactSwitch = media.contactID() != contactID
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
            closeMediaSession()
        }

        if sessionNeedsCreation || sessionNeedsContactSwitch || sessionNeedsRecreation {
            let supportsWebSocket = backendServices?.supportsWebSocket == true
            let session = makeDefaultMediaSession(
                supportsWebSocket: supportsWebSocket,
                sendAudioChunk: media.sendAudioChunk(),
                reportEvent: { [weak self] message, metadata in
                    guard let self else { return }
                    await MainActor.run {
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

    func closeMediaSession() {
        mediaServices.reset()
    }
}
