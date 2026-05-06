//
//  PTTViewModel+BackendLifecycle.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

extension PTTViewModel {
    func isTransientBackendBootstrapFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let code = URLError.Code(rawValue: nsError.code)

        switch code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    func shouldAutoRetryBackendBootstrapFailure(
        _ error: Error,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        guard hasBackendConfig else { return false }
        guard !backendRuntime.isReady else { return false }
        guard (applicationState ?? currentApplicationState()) == .active else { return false }
        return isTransientBackendBootstrapFailure(error)
    }

    func shouldRecoverBackendControlPlaneAfterSyncFailure(
        _ error: Error,
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        guard backendRuntime.isReady else { return false }
        guard (applicationState ?? currentApplicationState()) == .active else { return false }
        guard backendRuntime.isWebSocketConnected else { return false }
        return isTransientBackendBootstrapFailure(error)
            || shouldTreatBackendJoinDisconnectedSessionAsRecoverable(error)
    }

    func recoverBackendBootstrapIfNeeded(trigger: String) async {
        guard hasBackendConfig else { return }
        guard !backendRuntime.isReady else { return }
        guard shouldMaintainBackgroundControlPlane() else { return }

        diagnostics.record(.backend, message: "Retrying backend bootstrap", metadata: ["trigger": trigger])
        captureDiagnosticsState("backend-bootstrap:retry")
        await configureBackendIfNeeded()
    }

    func recoverBackendControlPlaneAfterSyncFailureIfNeeded(
        scope: String,
        error: Error
    ) async -> Bool {
        guard shouldRecoverBackendControlPlaneAfterSyncFailure(error) else { return false }

        diagnostics.record(
            .backend,
            message: "Recovering backend control plane after sync failure",
            metadata: [
                "scope": scope,
                "error": error.localizedDescription,
            ]
        )
        captureDiagnosticsState("backend-sync:control-plane-recovery")
        await reconnectBackendControlPlane()
        return true
    }

    func scheduleBackendBootstrapRetryIfNeeded(trigger: String, error: Error) {
        guard shouldAutoRetryBackendBootstrapFailure(error) else { return }
        guard backendRuntime.bootstrapRetryTask == nil else { return }

        let delaySeconds = Double(backendBootstrapRetryDelayNanoseconds) / 1_000_000_000
        backendStatusMessage = "Reconnecting backend..."
        updatePrimaryStatusAfterBackendBootstrapFailure(retrying: true)
        diagnostics.record(
            .backend,
            message: "Scheduling backend bootstrap retry",
            metadata: [
                "trigger": trigger,
                "delaySeconds": String(format: "%.1f", delaySeconds),
                "error": error.localizedDescription,
            ]
        )
        captureDiagnosticsState("backend-bootstrap:retry-scheduled")

        replaceBackendBootstrapRetryTask(
            with: Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.backendBootstrapRetryDelayNanoseconds)
                guard !Task.isCancelled else { return }
                self.replaceBackendBootstrapRetryTask(with: nil)
                await self.recoverBackendBootstrapIfNeeded(trigger: "\(trigger)-scheduled")
            }
        )
    }

    func disconnectBackendWebSocket() {
        guard let backend = backendServices, backend.supportsWebSocket else { return }
        diagnostics.record(.websocket, message: "Disconnecting WebSocket for control-plane test")
        backend.suspendWebSocket()
        captureDiagnosticsState("websocket:forced-disconnect")
    }

    func reconnectBackendControlPlane() async {
        diagnostics.record(.backend, message: "Reconnecting backend control plane")
        resetBackendRuntimeForReconnect()
        captureDiagnosticsState("backend:reconnect-start")
        await configureBackendIfNeeded()
        if let selectedContact = selectedContact {
            let localSessionAppearsActive =
                systemSessionMatches(selectedContact.id)
                || (isJoined && activeChannelId == selectedContact.id)
                || pttCoordinator.state.systemChannelUUID == selectedContact.channelId

            if localSessionAppearsActive {
                diagnostics.record(
                    .backend,
                    message: "Reasserting backend join after control-plane reconnect",
                    metadata: ["contactId": selectedContact.id.uuidString, "handle": selectedContact.handle]
                )
                await reassertBackendJoin(for: selectedContact)
            }
        }
        if let selectedContactId {
            await refreshChannelState(for: selectedContactId)
            await reconcileSelectedSessionIfNeeded()
            await syncLocalReceiverAudioReadinessSignal(
                for: selectedContactId,
                reason: "backend-reconnect"
            )
        }
        captureDiagnosticsState("backend:reconnect-finished")
    }

    func reassertBackendJoinAfterWebSocketReconnectIfNeeded() async {
        guard backendRuntime.isReady else { return }
        guard backendRuntime.signalingJoinRecoveryTask == nil else { return }
        guard let contact = signalingJoinRecoveryContact() else { return }

        diagnostics.record(
            .backend,
            message: "Reasserting backend join after WebSocket reconnect",
            metadata: ["contactId": contact.id.uuidString, "handle": contact.handle]
        )
        captureDiagnosticsState("websocket:join-reassertion")
        await reassertBackendJoin(for: contact)
    }

    func handleBackendServerNotice(_ message: String) {
        backendStatusMessage = message
        diagnostics.record(.websocket, message: "Backend server notice", metadata: ["message": message])

        guard shouldRecoverBackendSignalingJoinDrift(from: message),
              let contact = signalingJoinRecoveryContact(),
              backendRuntime.signalingJoinRecoveryTask == nil else {
            return
        }

        diagnostics.record(
            .backend,
            message: "Validating backend join drift before recovery",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "notice": message,
            ]
        )
        captureDiagnosticsState("backend-signaling:recovery-scheduled")

        let contactID = contact.id
        replaceBackendSignalingJoinRecoveryTask(
            with: Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.backendRuntime.signalingJoinRecoveryTask = nil }
                self.controlPlaneCoordinator.send(.receiverAudioReadinessCacheCleared(contactID: contactID))
                if self.backendSyncCoordinator.state.syncState.channelStates[contactID] == nil,
                   self.shouldReassertBackendJoinAfterSignalingDrift(for: contactID) {
                    self.diagnostics.record(
                        .backend,
                        message: "Reasserting backend join after signaling drift notice without cached channel state",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "handle": contact.handle,
                            "notice": message,
                        ]
                    )
                    await self.reassertBackendJoin(for: contact)
                    await self.refreshChannelState(for: contactID)
                    await self.refreshContactSummaries()
                    await self.syncLocalReceiverAudioReadinessSignal(
                        for: contactID,
                        reason: "backend-signaling-recovery"
                    )
                    self.captureDiagnosticsState("backend-signaling:recovered")
                    return
                }
                await self.refreshChannelState(for: contactID)
                guard self.shouldReassertBackendJoinAfterSignalingDrift(for: contactID) else {
                    self.diagnostics.record(
                        .backend,
                        message: "Self-healing stale backend join drift by reconciling local session",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "handle": contact.handle,
                            "notice": message,
                        ]
                    )
                    await self.reconcileSelectedSessionIfNeeded()
                    await self.refreshContactSummaries()
                    self.captureDiagnosticsState("backend-signaling:self-healed")
                    return
                }
                self.diagnostics.record(
                    .backend,
                    message: "Reasserting backend join after signaling drift notice",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "handle": contact.handle,
                        "notice": message,
                    ]
                )
                await self.reassertBackendJoin(for: contact)
                await self.refreshChannelState(for: contactID)
                await self.refreshContactSummaries()
                await self.syncLocalReceiverAudioReadinessSignal(
                    for: contactID,
                    reason: "backend-signaling-recovery"
                )
                self.captureDiagnosticsState("backend-signaling:recovered")
            }
        )
    }

    func shouldRecoverBackendSignalingJoinDrift(from message: String) -> Bool {
        guard backendRuntime.isReady else { return false }
        guard currentApplicationState() == .active else { return false }
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stripped = normalized.hasPrefix("signaling ")
            ? String(normalized.dropFirst("signaling ".count))
            : normalized
        return stripped == "sender device is not joined to this channel"
    }

    func shouldReassertBackendJoinAfterSignalingDrift(for contactID: UUID) -> Bool {
        guard signalingJoinRecoveryContact()?.id == contactID else { return false }
        guard let channelState = backendSyncCoordinator.state.syncState.channelStates[contactID] else {
            return true
        }

        guard channelState.membership.hasLocalMembership else { return false }

        switch channelState.conversationStatus {
        case nil:
            return false
        case .idle:
            return false
        case .requested, .incomingRequest, .waitingForPeer, .ready, .transmitting, .receiving:
            return true
        }
    }

    func signalingJoinRecoveryContact() -> Contact? {
        let candidateContactID = activeChannelId ?? selectedContactId
        guard let contactID = candidateContactID,
              let contact = contacts.first(where: { $0.id == contactID }),
              contact.backendChannelId != nil,
              contact.remoteUserId != nil else {
            return nil
        }

        guard systemSessionMatches(contactID) || (isJoined && activeChannelId == contactID) else {
            return nil
        }

        return contact
    }

    func shouldResetTransmitSessionOnWebSocketIdle(
        hasPendingBeginOrActiveTransmit: Bool,
        systemIsTransmitting: Bool
    ) -> Bool {
        let _ = hasPendingBeginOrActiveTransmit
        let _ = systemIsTransmitting
        // A transient control-plane reconnect should not forcibly end an
        // active system transmit. Lease renewal is HTTP-backed and audio sends
        // already wait briefly for the websocket to reconnect.
        return false
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
            diagnostics.record(
                .pushToTalk,
                message: "Uploading ephemeral PTT token",
                metadata: [
                    "backendChannelId": request.backendChannelID,
                    "tokenPrefix": String(request.tokenHex.prefix(8)),
                    "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                ]
            )
            do {
                let apnsEnvironment = TurboAPNSEnvironmentResolver.current()
                _ = try await backend.uploadEphemeralToken(
                    channelId: request.backendChannelID,
                    token: request.tokenHex,
                    apnsEnvironment: apnsEnvironment
                )
                pttSystemPolicyCoordinator.send(.tokenUploadFinished(request))
                diagnostics.record(
                    .pushToTalk,
                    message: "Uploaded ephemeral PTT token",
                    metadata: [
                        "backendChannelId": request.backendChannelID,
                        "tokenPrefix": String(request.tokenHex.prefix(8)),
                        "apnsEnvironment": apnsEnvironment.rawValue,
                        "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                    ]
                )
            } catch {
                let message = error.localizedDescription
                pttSystemPolicyCoordinator.send(.tokenUploadFailed(message))
                statusMessage = "Token upload failed: \(message)"
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Ephemeral PTT token upload failed",
                    metadata: [
                        "backendChannelId": request.backendChannelID,
                        "tokenPrefix": String(request.tokenHex.prefix(8)),
                        "systemChannelUUID": pttCoordinator.state.systemChannelUUID?.uuidString ?? "none",
                        "error": message,
                    ]
                )
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
            self?.scheduleIncomingSignalDelivery(envelope)
        }
        client.onServerNotice = { [weak self] message in
            self?.handleBackendServerNotice(message)
        }
        client.onWebSocketStateChange = { [weak self] state in
            self?.handleWebSocketStateChange(state)
        }

        do {
            let runtimeConfig = try await client.fetchRuntimeConfig()
            let localRelayOnlyOverride = TurboDirectPathDebugOverride.isRelayOnlyForced()
            let session = try await synchronizedProfileSessionIfNeeded(
                try await client.authenticate(),
                using: client
            )
            let directQuicIdentity = provisionDirectQuicProductionIdentityForRegistration(
                deviceID: client.deviceID
            )
            let mediaEncryptionIdentity = provisionMediaEncryptionIdentityForRegistration(
                deviceID: client.deviceID
            )
            _ = try await client.registerDevice(
                label: UIDevice.current.name,
                alertPushToken: alertPushTokenHex.isEmpty ? nil : alertPushTokenHex,
                alertPushEnvironment: alertPushTokenHex.isEmpty
                    ? nil
                    : TurboAPNSEnvironmentResolver.current(),
                directQuicIdentity: directQuicIdentity,
                mediaEncryptionIdentity: mediaEncryptionIdentity
            )
            if let directQuicIdentity {
                directQuicRegisteredFingerprint = directQuicIdentity.fingerprint
            }
            _ = try await client.heartbeatPresence()
            applyAuthenticatedBackendSession(
                client: client,
                userID: session.userId,
                mode: runtimeConfig.mode,
                telemetryEnabled: runtimeConfig.telemetryEnabled ?? false,
                publicID: session.publicId,
                profileName: session.profileName,
                shareCode: session.shareCode,
                shareLink: session.shareLink
            )
            client.connectWebSocket()
            backendSyncCoordinator.send(.bootstrapCompleted(mode: runtimeConfig.mode, handle: session.handle))
            await refreshContactSummaries()
            await refreshInvites()
            await openPendingTalkRequestNotificationIfNeeded()
            startBackendPollingIfNeeded()
            statusMessage = selectedContact == nil ? "Ready to connect" : statusMessage
            diagnostics.record(
                .backend,
                message: "Backend connected",
                metadata: [
                    "mode": runtimeConfig.mode,
                    "handle": session.handle,
                    "deviceId": client.deviceID,
                    "supportsDirectQuicUpgrade": String(runtimeConfig.supportsDirectQuicUpgrade),
                    "supportsDirectQuicProvisioning": String(runtimeConfig.supportsDirectQuicProvisioning),
                    "supportsMediaEndToEndEncryption": String(runtimeConfig.supportsMediaEndToEndEncryption),
                    "directQuicProvisioningStatus": directQuicProvisioningStatus,
                    "directQuicFingerprint": directQuicIdentity?.fingerprint ?? "none",
                    "mediaEncryptionProvisioningStatus": mediaEncryptionProvisioningStatus,
                    "mediaEncryptionFingerprint": mediaEncryptionIdentity?.fingerprint ?? "none",
                    "localRelayOnlyOverride": String(localRelayOnlyOverride),
                ]
            )
            sendTelemetryEvent(
                eventName: "ios.backend.connected",
                severity: .info,
                reason: runtimeConfig.mode,
                message: "Backend connected",
                metadata: [
                    "deviceId": client.deviceID,
                    "handle": session.handle,
                    "telemetryEnabled": String(runtimeConfig.telemetryEnabled ?? false),
                    "supportsDirectQuicUpgrade": String(runtimeConfig.supportsDirectQuicUpgrade),
                    "supportsMediaEndToEndEncryption": String(runtimeConfig.supportsMediaEndToEndEncryption),
                    "localRelayOnlyOverride": String(localRelayOnlyOverride),
                ]
            )
            if runtimeConfig.supportsDirectQuicUpgrade, localRelayOnlyOverride {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC upgrade disabled by local debug override",
                    metadata: ["deviceId": client.deviceID]
                )
            }
            replaceBackendBootstrapRetryTask(with: nil)
            syncPTTServiceStatus(reason: "backend-connected")
            captureDiagnosticsState("backend-config:connected")
        } catch {
            resetBackendRuntimeForReconnect()
            backendSyncCoordinator.send(.bootstrapFailed(error.localizedDescription))
            scheduleBackendBootstrapRetryIfNeeded(trigger: "configure", error: error)
            updatePrimaryStatusAfterBackendBootstrapFailure(
                retrying: statusMessage == "Reconnecting..."
            )
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend connection failed",
                metadata: ["error": error.localizedDescription]
            )
            syncPTTServiceStatus(reason: "backend-connect-failed")
            captureDiagnosticsState("backend-config:failed")
        }
    }

    var shouldProjectBackendConnectivityInPrimaryStatus: Bool {
        if sessionCoordinator.pendingAction != .none { return true }
        if isJoined || isTransmitting { return true }
        if activeChannelId != nil { return true }
        if systemSessionState != .none { return true }
        if transmitCoordinator.state.isPressingTalk { return true }
        if pttCoordinator.state.isTransmitting { return true }
        if pttWakeRuntime.pendingIncomingPush != nil { return true }
        return false
    }

    private func updatePrimaryStatusAfterBackendBootstrapFailure(retrying: Bool) {
        if shouldProjectBackendConnectivityInPrimaryStatus {
            statusMessage = retrying ? "Reconnecting..." : "Backend unavailable"
        } else {
            updateStatusForSelectedContact()
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

    func restoreExistingIdentity(from reference: String) async -> Bool {
        guard let publicID = TurboIncomingLink.publicID(from: reference) else {
            diagnostics.record(
                .auth,
                level: .error,
                message: "Restore identity failed to parse reference",
                metadata: ["reference": reference]
            )
            return false
        }

        TurboBackendConfig.setPersistedDevUserHandle(publicID)
        replaceBackendConfig(with: TurboBackendConfig.load())
        resetLocalDevState(backendStatus: "Restoring your BeepBeep...")
        backendStatusMessage = "Restoring your BeepBeep..."
        diagnostics.record(.auth, message: "Restoring existing identity", metadata: ["publicId": publicID])
        captureDiagnosticsState("identity-restore:start")
        await configureBackendIfNeeded()

        guard backendRuntime.isReady else {
            captureDiagnosticsState("identity-restore:failed")
            return false
        }

        let restoredProfileName = TurboIdentityProfileStore.storeDraftProfileName(currentProfileName)
        TurboIdentityProfileStore.markOnboardingCompleted()
        storeCurrentProfileName(restoredProfileName)
        captureDiagnosticsState("identity-restore:finished")
        return true
    }

    func createFreshIdentity(handle: String, profileName: String) async -> Bool {
        let normalizedHandle = TurboHandle.normalizedStoredHandle(handle)
        TurboBackendConfig.setPersistedDevUserHandle(normalizedHandle)
        replaceBackendConfig(with: TurboBackendConfig.load())
        resetLocalDevState(backendStatus: "Creating your BeepBeep...")
        backendStatusMessage = "Creating your BeepBeep..."
        diagnostics.record(.auth, message: "Creating fresh identity", metadata: ["handle": normalizedHandle])
        captureDiagnosticsState("identity-create:start")
        await configureBackendIfNeeded()

        guard backendRuntime.isReady else {
            captureDiagnosticsState("identity-create:failed")
            return false
        }

        await updateProfileName(profileName, markOnboardingComplete: true)
        captureDiagnosticsState("identity-create:finished")
        return backendRuntime.isReady
    }

    func updateProfileName(_ profileName: String, markOnboardingComplete: Bool = false) async {
        let normalizedProfileName = TurboIdentityProfileStore.storeDraftProfileName(profileName)
        if markOnboardingComplete {
            TurboIdentityProfileStore.markOnboardingCompleted()
        }
        storeCurrentProfileName(normalizedProfileName)

        guard let backend = backendServices else {
            diagnostics.record(
                .auth,
                message: "Stored local profile name while backend was unavailable",
                metadata: ["profileName": normalizedProfileName]
            )
            captureDiagnosticsState("profile-name:stored-local")
            return
        }

        do {
            let session = try await backend.client.updateProfileName(normalizedProfileName)
            let storedProfileName = TurboIdentityProfileStore.storeDraftProfileName(session.profileName)
            storeCurrentProfileName(storedProfileName)
            applyAuthenticatedBackendSession(
                client: backend.client,
                userID: session.userId,
                mode: backend.mode,
                telemetryEnabled: backend.telemetryEnabled,
                publicID: session.publicId,
                profileName: session.profileName,
                shareCode: session.shareCode,
                shareLink: session.shareLink
            )
            diagnostics.record(
                .auth,
                message: "Updated profile name",
                metadata: ["profileName": storedProfileName]
            )
            await refreshContactSummaries()
            captureDiagnosticsState("profile-name:updated")
        } catch {
            diagnostics.record(
                .auth,
                level: .error,
                message: "Profile name update failed",
                metadata: ["error": error.localizedDescription]
            )
            captureDiagnosticsState("profile-name:update-failed")
        }
    }

    func signOutToFreshIdentity() async {
        diagnostics.record(.auth, message: "Signing out to fresh identity", metadata: ["handle": currentDevUserHandle])
        captureDiagnosticsState("identity-sign-out:start")

        if selectedContactId != nil || isJoined || pttCoordinator.state.systemChannelUUID != nil {
            await requestDisconnectSelectedPeer()
        }

        TurboIdentityProfileStore.resetForFreshIdentity()
        replaceBackendConfig(with: TurboBackendConfig.load())
        resetLocalDevState(backendStatus: "Creating your new BeepBeep...")
        backendStatusMessage = "Creating your new BeepBeep..."
        captureDiagnosticsState("identity-sign-out:local-cleared")
        await configureBackendIfNeeded()
    }

    func restartLocalAppSession() async {
        diagnostics.record(.app, message: "Restarting local app session", metadata: ["handle": currentDevUserHandle])
        captureDiagnosticsState("local-restart:start")

        if selectedContactId != nil || isJoined || pttCoordinator.state.systemChannelUUID != nil {
            await requestDisconnectSelectedPeer()
        }

        resetLocalDevState(backendStatus: "Reconnecting as \(currentDevUserHandle)...")
        backendStatusMessage = "Reconnecting as \(currentDevUserHandle)..."
        captureDiagnosticsState("local-restart:local-cleared")
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
        receiveExecutionCoordinator.send(.reset)
        isPTTAudioSessionActive = false
        selectedContactId = nil
        selectedPeerCoordinator.reset()
        syncPTTState()
        sessionCoordinator.reset()
        backendSyncCoordinator.send(.reset(statusMessage: backendStatus))
        backendCommandCoordinator.send(.reset)
        selfCheckCoordinator.send(.reset)
        pttSystemPolicyCoordinator.send(.reset)
        pttWakeRuntime.clearAll()
        controlPlaneCoordinator.send(.reset)
        clearTrackedContacts()
        resetTransportFaults()
        contacts = []
        diagnostics.clear()
        statusMessage = "Initializing..."
        captureDiagnosticsState("local-state-reset")
    }

    func startBackendPollingIfNeeded() {
        guard !hasPendingBackendPollTask else { return }
        replaceBackendPollTask(with: Task { [weak self] in
            while let self, !Task.isCancelled {
                let (selectedContactId, shouldPoll) = await MainActor.run { @MainActor in
                    (self.selectedContactId, self.shouldMaintainBackgroundControlPlane())
                }
                if shouldPoll {
                    await self.backendSyncCoordinator.handle(.pollRequested(selectedContactID: selectedContactId))
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        })
    }

    func handleWebSocketStateChange(_ state: TurboBackendClient.WebSocketConnectionState) {
        guard let backend = backendServices, backend.supportsWebSocket else { return }
        diagnostics.record(.websocket, message: "WebSocket state changed", metadata: ["state": String(describing: state)])

        let shouldForceBackgroundSuspension =
            currentApplicationState() != .active
            && !shouldMaintainBackgroundControlPlane()
        if shouldForceBackgroundSuspension {
            diagnostics.record(
                .websocket,
                message: "Suspending unexpected background WebSocket activity",
                metadata: ["state": String(describing: state)]
            )
            backend.suspendWebSocket()
            if state != .idle {
                captureDiagnosticsState("websocket:background-suspended")
                return
            }
        }

        switch state {
        case .idle:
            if shouldForceBackgroundSuspension {
                backendStatusMessage = "WebSocket suspended"
            } else {
                backendStatusMessage = backendRuntime.isReady ? "Reconnecting WebSocket..." : "WebSocket disconnected"
            }
            backendSyncCoordinator.send(.webSocketStateChanged(.idle, selectedContactID: selectedContactId))
            controlPlaneCoordinator.send(.webSocketStateChanged(.idle))
            syncPTTServiceStatus(reason: "websocket-idle")
            let shouldResetTransmitSession = shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: hasPendingBeginOrActiveTransmit,
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
            syncPTTServiceStatus(reason: "websocket-connecting")
            captureDiagnosticsState("websocket:connecting")
        case .connected:
            if backendStatusMessage.hasPrefix("WebSocket")
                || backendStatusMessage == "Connected (retrying sync)" {
                backendStatusMessage = "Connected"
            }
            syncPTTServiceStatus(reason: "websocket-connected")
            captureDiagnosticsState("websocket:connected")
            Task {
                await backendSyncCoordinator.handle(.webSocketStateChanged(state, selectedContactID: selectedContactId))
                await controlPlaneCoordinator.handle(.webSocketStateChanged(state))
                await reassertBackendJoinAfterWebSocketReconnectIfNeeded()
                let readinessContactIDs = Set([selectedContactId, activeChannelId, mediaSessionContactID].compactMap { $0 })
                for contactID in readinessContactIDs {
                    await syncLocalReceiverAudioReadinessSignal(
                        for: contactID,
                        reason: "websocket-connected"
                    )
                }
                if let selectedContactId {
                    await prewarmForegroundTalkPathIfNeeded(
                        for: selectedContactId,
                        reason: "websocket-connected"
                    )
                }
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

    private func synchronizedProfileSessionIfNeeded(
        _ session: TurboAuthSessionResponse,
        using client: TurboBackendClient
    ) async throws -> TurboAuthSessionResponse {
        let remoteProfileName = session.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let localProfileName = TurboIdentityProfileStore.storeDraftProfileName(
            TurboIdentityProfileStore.draftProfileName()
        )
        let remoteLooksDefault = remoteProfileName.isEmpty
            || remoteProfileName == session.publicId
            || remoteProfileName == session.handle

        if !TurboIdentityProfileStore.hasCompletedOnboarding() {
            if !remoteLooksDefault {
                let storedRemoteName = TurboIdentityProfileStore.storeDraftProfileName(remoteProfileName)
                TurboIdentityProfileStore.markOnboardingCompleted()
                storeCurrentProfileName(storedRemoteName)
                return sessionWithProfileName(session, profileName: storedRemoteName)
            }

            storeCurrentProfileName(localProfileName)
            return sessionWithProfileName(session, profileName: localProfileName)
        }

        guard localProfileName != remoteProfileName else {
            storeCurrentProfileName(localProfileName)
            return sessionWithProfileName(session, profileName: localProfileName)
        }

        do {
            let updatedSession = try await client.updateProfileName(localProfileName)
            let storedRemoteName = TurboIdentityProfileStore.storeDraftProfileName(updatedSession.profileName)
            storeCurrentProfileName(storedRemoteName)
            diagnostics.record(
                .auth,
                message: "Synchronized profile name on backend connect",
                metadata: ["profileName": storedRemoteName]
            )
            return sessionWithProfileName(updatedSession, profileName: storedRemoteName)
        } catch {
            diagnostics.record(
                .auth,
                level: .error,
                message: "Deferred profile sync failed during backend bootstrap",
                metadata: ["error": error.localizedDescription]
            )
            storeCurrentProfileName(localProfileName)
            return sessionWithProfileName(session, profileName: localProfileName)
        }
    }

    private func sessionWithProfileName(
        _ session: TurboAuthSessionResponse,
        profileName: String
    ) -> TurboAuthSessionResponse {
        TurboAuthSessionResponse(
            userId: session.userId,
            handle: session.handle,
            publicId: session.publicId,
            displayName: session.displayName,
            profileName: profileName,
            shareCode: session.shareCode,
            shareLink: session.shareLink,
            did: session.did,
            subjectKind: session.subjectKind
        )
    }
}
