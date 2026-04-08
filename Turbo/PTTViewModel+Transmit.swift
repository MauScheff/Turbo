//
//  PTTViewModel+Transmit.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk

extension PTTViewModel {
    func beginTransmit() {
        guard isJoined else { return }
        guard let contact = selectedContact else {
            statusMessage = "Pick a contact"
            return
        }
        guard transmitRuntime.beginTask == nil, transmitRuntime.activeTarget == nil else { return }
        guard activeChannelId == contact.id else { return }
        guard canTransmitNow(for: contact.id),
              let channelState = selectedChannelState,
              channelState.canTransmit else {
            updateStatusForSelectedContact()
            return
        }

        guard let backendChannelId = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let backendClient = backendRuntime.client else {
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
            backendSupportsWebSocket: backendClient.supportsWebSocket
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
        }
    }

    private func performBeginTransmit(_ request: TransmitRequestContext) async {
        guard let backendClient = backendRuntime.client else { return }

        transmitRuntime.beginTask?.cancel()
        transmitRuntime.beginTask = Task { [weak self] in
            guard let self else { return }
            do {
                if request.backendSupportsWebSocket {
                    try await backendClient.waitForWebSocketConnection()
                }
                let response = try await backendClient.beginTransmit(channelId: request.backendChannelID)
                let target = TransmitTarget(
                    contactID: request.contactID,
                    userID: request.remoteUserID,
                    deviceID: response.targetDeviceId,
                    channelID: request.backendChannelID
                )
                await transmitCoordinator.handle(.beginSucceeded(target, request))
                syncTransmitState()
            } catch {
                let message = error.localizedDescription
                await transmitCoordinator.handle(.beginFailed(message))
                syncTransmitState()
                statusMessage = "Transmit failed: \(message)"
                diagnostics.record(.media, level: .error, message: "Transmit failed", metadata: ["contact": request.contactHandle, "error": message])
            }
            transmitRuntime.beginTask = nil
        }
    }

    private func performActivateTransmit(_ request: TransmitRequestContext, target: TransmitTarget) async {
        startRenewingTransmit(target)

        if request.backendSupportsWebSocket, let backendClient = backendRuntime.client {
            await ensureMediaSession(for: request.contactID)
            do {
                try await mediaRuntime.session?.startSendingAudio()
                try await backendClient.sendSignal(
                    TurboSignalEnvelope(
                        type: .transmitStart,
                        channelId: request.backendChannelID,
                        fromUserId: backendRuntime.currentUserID ?? "",
                        fromDeviceId: backendClient.deviceID,
                        toUserId: request.remoteUserID,
                        toDeviceId: target.deviceID,
                        payload: "ptt-begin"
                    )
                )
            } catch {
                let message = error.localizedDescription
                statusMessage = "Transmit failed: \(message)"
                diagnostics.record(.media, level: .error, message: "Transmit activation failed", metadata: ["contact": request.contactHandle, "error": message])
                await transmitCoordinator.handle(.stopFailed(message))
                syncTransmitState()
                return
            }
        }

        if request.usesLocalHTTPBackend {
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

    private func performStopTransmit(_ target: TransmitTarget) async {
        transmitRuntime.renewTask?.cancel()
        transmitRuntime.renewTask = nil
        transmitRuntime.beginTask?.cancel()
        transmitRuntime.beginTask = nil

        if usesLocalHTTPBackend {
            isTransmitting = false
        } else if let activeChannelId,
                  let channelUUID = channelUUID(for: activeChannelId) {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }

        do {
            try? await mediaRuntime.session?.stopSendingAudio()
            if let backendClient = backendRuntime.client {
                _ = try await backendClient.endTransmit(channelId: target.channelID)
                if backendClient.supportsWebSocket && backendClient.isWebSocketConnected {
                    try? await backendClient.sendSignal(
                        TurboSignalEnvelope(
                            type: .transmitStop,
                            channelId: target.channelID,
                            fromUserId: backendRuntime.currentUserID ?? "",
                            fromDeviceId: backendClient.deviceID,
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

    private func startRenewingTransmit(_ target: TransmitTarget) {
        transmitRuntime.renewTask?.cancel()
        guard let backendClient = backendRuntime.client else { return }
        transmitRuntime.renewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard transmitCoordinator.state.isPressingTalk,
                      transmitRuntime.activeTarget?.channelID == target.channelID else { return }
                do {
                    _ = try await backendClient.renewTransmit(channelId: target.channelID)
                } catch {
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
        }
    }

    func mediaSession(_ session: MediaSession, didChange state: MediaConnectionState) {
        guard session === mediaRuntime.session else { return }
        mediaRuntime.connectionState = state
        diagnostics.record(.media, message: "Media state changed", metadata: ["state": String(describing: state)])
        switch state {
        case .failed(let message):
            backendStatusMessage = "Media failed: \(message)"
        case .connected, .closed, .idle, .preparing:
            break
        }
    }

    func ensureMediaSession(for contactID: UUID) async {
        guard contacts.contains(where: { $0.id == contactID }) else { return }

        if mediaRuntime.contactID != contactID {
            closeMediaSession()
        }

        if mediaRuntime.session == nil {
            let session: MediaSession
            if let backendClient = backendRuntime.client, backendClient.supportsWebSocket {
                session = PCMWebSocketMediaSession { [weak self] payload in
                    guard let self else {
                        throw TurboBackendError.webSocketUnavailable
                    }
                    let outboundSignal = try await MainActor.run {
                        try self.makeOutgoingAudioSignal(payload: payload)
                    }

                    let envelope = TurboSignalEnvelope(
                        type: .audioChunk,
                        channelId: outboundSignal.channelId,
                        fromUserId: outboundSignal.fromUserId,
                        fromDeviceId: outboundSignal.fromDeviceId,
                        toUserId: outboundSignal.toUserId,
                        toDeviceId: outboundSignal.toDeviceId,
                        payload: payload
                    )
                    try await outboundSignal.backendClient.sendSignal(envelope)
                }
            } else {
                session = StubRelayMediaSession()
            }
            session.delegate = self
            mediaRuntime.session = session
            mediaRuntime.contactID = contactID
        }

        do {
            try await mediaRuntime.session?.start()
        } catch {
            backendStatusMessage = "Media setup failed: \(error.localizedDescription)"
        }
    }

    func closeMediaSession() {
        mediaRuntime.session?.close()
        mediaRuntime.session = nil
        mediaRuntime.contactID = nil
        mediaRuntime.connectionState = .idle
    }

    private func makeOutgoingAudioSignal(payload _: String) throws -> (
        backendClient: TurboBackendClient,
        channelId: String,
        fromDeviceId: String,
        fromUserId: String,
        toUserId: String,
        toDeviceId: String
    ) {
        guard let backendClient = backendRuntime.client,
              let activeTransmitTarget = transmitRuntime.activeTarget else {
            throw TurboBackendError.webSocketUnavailable
        }
        return (
            backendClient: backendClient,
            channelId: activeTransmitTarget.channelID,
            fromDeviceId: backendClient.deviceID,
            fromUserId: backendRuntime.currentUserID ?? "",
            toUserId: activeTransmitTarget.userID,
            toDeviceId: activeTransmitTarget.deviceID
        )
    }
}
