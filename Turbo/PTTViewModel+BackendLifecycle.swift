//
//  PTTViewModel+BackendLifecycle.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

extension PTTViewModel {
    func shouldResetTransmitSessionOnWebSocketIdle(
        hasPendingBeginOrActiveTransmit: Bool,
        systemIsTransmitting: Bool
    ) -> Bool {
        hasPendingBeginOrActiveTransmit || systemIsTransmitting
    }

    func runSelfCheckEffect(_ effect: DevSelfCheckEffect) async {
        switch effect {
        case .run(let request):
            await performSelfCheck(request)
        }
    }

    func runPTTSystemPolicyEffect(_ effect: PTTSystemPolicyEffect) async {
        switch effect {
        case .uploadEphemeralToken(let request):
            guard let backend = backendServices else {
                pttSystemPolicyCoordinator.send(.tokenUploadFailed("Backend unavailable"))
                return
            }
            do {
                _ = try await backend.uploadEphemeralToken(
                    channelId: request.backendChannelID,
                    token: request.tokenHex
                )
                pttSystemPolicyCoordinator.send(.tokenUploadFinished(request))
            } catch {
                let message = error.localizedDescription
                pttSystemPolicyCoordinator.send(.tokenUploadFailed(message))
                statusMessage = "Token upload failed: \(message)"
            }
        }
    }

    func configureBackendIfNeeded() async {
        guard let backendConfig = backendConfig else {
            backendStatusMessage = "Backend not configured"
            diagnostics.record(.backend, level: .error, message: "Backend configuration missing")
            captureDiagnosticsState("backend-config:missing")
            return
        }
        let client = TurboBackendClient(config: backendConfig)
        client.onSignal = { [weak self] envelope in
            self?.handleIncomingSignal(envelope)
        }
        client.onServerNotice = { [weak self] message in
            self?.backendStatusMessage = message
        }
        client.onWebSocketStateChange = { [weak self] state in
            self?.handleWebSocketStateChange(state)
        }

        do {
            let runtimeConfig = try await client.fetchRuntimeConfig()
            let session = try await client.authenticate()
            _ = try await client.registerDevice(label: UIDevice.current.name)
            _ = try await client.heartbeatPresence()
            applyAuthenticatedBackendSession(
                client: client,
                userID: session.userId,
                mode: runtimeConfig.mode
            )
            client.connectWebSocket()
            backendSyncCoordinator.send(.bootstrapCompleted(mode: runtimeConfig.mode, handle: session.handle))
            await refreshContactSummaries()
            await refreshInvites()
            startBackendPollingIfNeeded()
            statusMessage = selectedContact == nil ? "Ready to connect" : statusMessage
            diagnostics.record(
                .backend,
                message: "Backend connected",
                metadata: ["mode": runtimeConfig.mode, "handle": session.handle, "deviceId": client.deviceID]
            )
            captureDiagnosticsState("backend-config:connected")
        } catch {
            resetBackendRuntimeForReconnect()
            backendSyncCoordinator.send(.bootstrapFailed(error.localizedDescription))
            statusMessage = "Backend unavailable"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend connection failed",
                metadata: ["error": error.localizedDescription]
            )
            captureDiagnosticsState("backend-config:failed")
        }
    }

    func updateDevUserHandle(_ handle: String) async {
        TurboBackendConfig.setPersistedDevUserHandle(handle)
        replaceBackendConfig(with: TurboBackendConfig.load())
        resetLocalDevState(backendStatus: "Reconnecting as \(currentDevUserHandle)...")
        diagnostics.record(.auth, message: "Switching dev identity", metadata: ["handle": currentDevUserHandle])
        captureDiagnosticsState("identity-switch:start")
        await configureBackendIfNeeded()
    }

    func resetDevEnvironment() async {
        statusMessage = "Resetting dev world..."
        diagnostics.record(.app, message: "Resetting dev world", metadata: ["handle": currentDevUserHandle])
        captureDiagnosticsState("dev-reset:start")
        do {
            if let backend = backendServices {
                let response = try await backend.resetAllDevState()
                let seeded = try await backend.seedDevUsers()
                diagnostics.record(
                    .backend,
                    message: "Backend dev world reset",
                    metadata: [
                        "clearedInvites": "\(response.clearedInvites)",
                        "clearedPresenceEntries": "\(response.clearedPresenceEntries)",
                        "clearedChannels": "\(response.clearedChannels ?? 0)",
                        "clearedUsers": "\(response.clearedUsers ?? 0)",
                        "seededUsers": "\(seeded.users.count)"
                    ]
                )
            }
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend dev world reset failed",
                metadata: ["error": error.localizedDescription]
            )
        }

        resetLocalDevState(backendStatus: "Resetting as \(currentDevUserHandle)...")
        backendStatusMessage = "Reconnecting as \(currentDevUserHandle)..."
        captureDiagnosticsState("dev-reset:local-cleared")
        await configureBackendIfNeeded()
    }

    func runSelfCheck() async {
        refreshMicrophonePermission()
        let startedAt = Date()
        diagnostics.record(
            .selfCheck,
            message: "Running self-check",
            metadata: ["selectedContact": selectedContact?.handle ?? "none"]
        )
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: hasBackendConfig,
            isBackendClientReady: backendServices != nil,
            microphonePermission: microphonePermission,
            selectedTarget: selectedContact.map { DevSelfCheckTarget(contactID: $0.id, handle: $0.handle) }
        )
        await selfCheckCoordinator.handle(.runRequested(request))
    }

    func publishDiagnostics() async throws -> TurboDiagnosticsUploadResponse {
        try await publishDiagnosticsIfPossible(trigger: "manual-upload", recordSuccess: true)
    }

    func publishDiagnosticsIfPossible(
        trigger: String,
        recordSuccess: Bool
    ) async throws -> TurboDiagnosticsUploadResponse {
        guard let backend = backendServices, let backendConfig else {
            throw TurboBackendError.invalidConfiguration
        }

        let payload = TurboDiagnosticsUploadRequest(
            deviceId: backend.deviceID,
            appVersion: appVersionDescription,
            backendBaseURL: backendConfig.baseURL.absoluteString,
            selectedHandle: selectedContact?.handle,
            snapshot: diagnosticsSnapshot,
            transcript: diagnosticsTranscript
        )

        let response = try await backend.uploadDiagnostics(payload)
        if recordSuccess {
            diagnostics.record(
                .app,
                message: "Published diagnostics",
                metadata: [
                    "deviceId": response.report.deviceId,
                    "uploadedAt": response.report.uploadedAt,
                    "trigger": trigger
                ]
            )
        }
        return response
    }

    func resetLocalDevState(backendStatus: String) {
        cancelAutomaticDiagnosticsPublish()
        resetBackendRuntimeForReconnect()
        pttCoordinator.reset()
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        selectedContactId = nil
        syncPTTState()
        sessionCoordinator.reset()
        backendSyncCoordinator.send(.reset(statusMessage: backendStatus))
        backendCommandCoordinator.send(.reset)
        selfCheckCoordinator.send(.reset)
        pttSystemPolicyCoordinator.send(.reset)
        pttWakeRuntime.clearAll()
        clearTrackedContacts()
        contacts = []
        statusMessage = "Initializing..."
        captureDiagnosticsState("local-state-reset")
    }

    func startBackendPollingIfNeeded() {
        guard !hasPendingBackendPollTask else { return }
        replaceBackendPollTask(with: Task { [weak self] in
            while let self, !Task.isCancelled {
                let selectedContactId = await MainActor.run(body: { self.selectedContactId })
                await self.backendSyncCoordinator.handle(.pollRequested(selectedContactID: selectedContactId))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        })
    }

    func handleWebSocketStateChange(_ state: TurboBackendClient.WebSocketConnectionState) {
        guard let backend = backendServices, backend.supportsWebSocket else { return }
        diagnostics.record(.websocket, message: "WebSocket state changed", metadata: ["state": String(describing: state)])

        switch state {
        case .idle:
            backendStatusMessage = "WebSocket disconnected"
            let shouldResetTransmitSession = shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: transmitServices.hasPendingBeginOrActiveTarget(),
                systemIsTransmitting: pttCoordinator.state.isTransmitting
            )
            if shouldResetTransmitSession {
                Task {
                    await transmitCoordinator.handle(.websocketDisconnected)
                    resetTransmitSession(closeMediaSession: false)
                    updateStatusForSelectedContact()
                }
            }
            captureDiagnosticsState("websocket:idle")
        case .connecting:
            backendStatusMessage = "Connecting WebSocket..."
            captureDiagnosticsState("websocket:connecting")
        case .connected:
            captureDiagnosticsState("websocket:connected")
            Task {
                await backendSyncCoordinator.handle(.webSocketStateChanged(state, selectedContactID: selectedContactId))
            }
        }
    }

    private func performSelfCheck(_ request: DevSelfCheckRequest) async {
        guard let backend = backendServices else {
            let outcome = DevSelfCheckOutcome(
                report: DevSelfCheckReport(
                    startedAt: request.startedAt,
                    completedAt: Date(),
                    targetHandle: request.selectedTarget?.handle,
                    steps: [DevSelfCheckStep(.runtimeConfig, status: .failed, detail: "Backend client is not initialized")]
                ),
                authenticatedUserID: nil,
                contactUpdate: nil,
                channelStateUpdate: nil
            )
            selfCheckCoordinator.send(.runCompleted(outcome.report))
            diagnostics.record(.selfCheck, level: .error, message: outcome.report.summary)
            return
        }

        let services = DevSelfCheckServices(
            fetchRuntimeConfig: { try await backend.fetchRuntimeConfig() },
            authenticate: { try await backend.authenticate() },
            heartbeatPresence: { try await backend.heartbeatPresence() },
            ensureWebSocketConnected: { backend.ensureWebSocketConnected() },
            waitForWebSocketConnection: { try await backend.waitForWebSocketConnection() },
            lookupUser: { handle in try await backend.lookupUser(handle: handle) },
            directChannel: { handle in try await backend.directChannel(otherHandle: handle) },
            channelState: { channelID in try await backend.channelState(channelId: channelID) },
            alignmentAction: { [weak self] contactUpdate in
                guard let self,
                      let existingContact = self.contacts.first(where: { $0.id == contactUpdate.contactID }) else {
                    return .none
                }
                var contact = existingContact
                contact.remoteUserId = contactUpdate.remoteUserID
                contact.backendChannelId = contactUpdate.backendChannelID
                contact.channelId = contactUpdate.channelUUID
                return ConversationStateMachine.reconciliationAction(for: self.conversationContext(for: contact))
            }
        )

        let outcome = await DevSelfCheckRunner.run(request: request, services: services)

        if let authenticatedUserID = outcome.authenticatedUserID {
            storeAuthenticatedUserID(authenticatedUserID)
        }
        if let contactUpdate = outcome.contactUpdate {
            updateContact(contactUpdate.contactID) { mutableContact in
                mutableContact.remoteUserId = contactUpdate.remoteUserID
                mutableContact.backendChannelId = contactUpdate.backendChannelID
                mutableContact.channelId = contactUpdate.channelUUID
            }
        }
        if let channelStateUpdate = outcome.channelStateUpdate {
            backendSyncCoordinator.send(
                .channelStateUpdated(
                    contactID: channelStateUpdate.contactID,
                    channelState: channelStateUpdate.channelState
                )
            )
        }

        selfCheckCoordinator.send(.runCompleted(outcome.report))
        diagnostics.record(
            .selfCheck,
            level: outcome.report.isPassing ? .info : .error,
            message: outcome.report.summary,
            metadata: ["target": outcome.report.targetHandle ?? "none"]
        )
    }
}
