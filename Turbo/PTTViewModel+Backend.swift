//
//  PTTViewModel+Backend.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

extension PTTViewModel {
    func openContact(handle: String) async {
        let normalizedHandle = Contact.normalizedHandle(handle)
        guard normalizedHandle != currentDevUserHandle else {
            statusMessage = "Pick another handle"
            return
        }
        guard backendRuntime.client != nil else {
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }

        await backendCommandCoordinator.handle(.openPeerRequested(handle: normalizedHandle))
    }

    func runBackendSyncEffect(_ effect: BackendSyncEffect) async {
        switch effect {
        case .ensureWebSocketConnected:
            backendRuntime.client?.ensureWebSocketConnected()
        case .heartbeatPresence:
            _ = try? await backendRuntime.client?.heartbeatPresence()
        case .refreshContactSummaries:
            await refreshContactSummaries()
        case .refreshInvites:
            await refreshInvites()
        case .refreshChannelState(let contactID):
            await refreshChannelState(for: contactID)
        }
    }

    func runBackendCommandEffect(_ effect: BackendCommandEffect) async {
        switch effect {
        case .openPeer(let handle):
            await performOpenPeer(handle: handle)
        case .join(let request):
            await performBackendJoin(request)
        case .leave(let request):
            await performBackendLeave(request)
        }
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
            guard let backendClient = backendRuntime.client else {
                pttSystemPolicyCoordinator.send(.tokenUploadFailed("Backend unavailable"))
                return
            }
            do {
                _ = try await backendClient.uploadEphemeralToken(
                    channelId: request.backendChannelID,
                    token: request.tokenHex
                )
                pttSystemPolicyCoordinator.send(.tokenUploadFinished)
            } catch {
                let message = error.localizedDescription
                pttSystemPolicyCoordinator.send(.tokenUploadFailed(message))
                statusMessage = "Token upload failed: \(message)"
            }
        }
    }

    func configureBackendIfNeeded() async {
        guard let backendConfig = backendRuntime.config else {
            backendStatusMessage = "Backend not configured"
            diagnostics.record(.backend, level: .error, message: "Backend configuration missing")
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
            diagnostics.record(.backend, message: "Backend connected", metadata: ["mode": runtimeConfig.mode, "handle": session.handle, "deviceId": client.deviceID])
        } catch {
            backendRuntime.mode = "unknown"
            backendSyncCoordinator.send(.bootstrapFailed(error.localizedDescription))
            statusMessage = "Backend unavailable"
            diagnostics.record(.backend, level: .error, message: "Backend connection failed", metadata: ["error": error.localizedDescription])
        }
    }

    func updateDevUserHandle(_ handle: String) async {
        TurboBackendConfig.setPersistedDevUserHandle(handle)
        backendRuntime.config = TurboBackendConfig.load()
        resetLocalDevState(backendStatus: "Reconnecting as \(currentDevUserHandle)...")
        diagnostics.record(.auth, message: "Switching dev identity", metadata: ["handle": currentDevUserHandle])
        await configureBackendIfNeeded()
    }

    func resetDevEnvironment() async {
        statusMessage = "Resetting dev state..."
        diagnostics.record(.app, message: "Resetting dev state", metadata: ["handle": currentDevUserHandle])
        do {
            if let backendClient = backendRuntime.client {
                let response = try await backendClient.resetDevState()
                diagnostics.record(
                    .backend,
                    message: "Backend dev state reset",
                    metadata: [
                        "clearedInvites": "\(response.clearedInvites)",
                        "clearedPresenceEntries": "\(response.clearedPresenceEntries)",
                        "clearedChannels": "\(response.clearedChannels ?? 0)"
                    ]
                )
            }
        } catch {
            diagnostics.record(.backend, level: .error, message: "Backend dev reset failed", metadata: ["error": error.localizedDescription])
        }

        resetLocalDevState(backendStatus: "Resetting as \(currentDevUserHandle)...")
        backendStatusMessage = "Reconnecting as \(currentDevUserHandle)..."
        await configureBackendIfNeeded()
    }

    func runSelfCheck() async {
        let startedAt = Date()
        diagnostics.record(.selfCheck, message: "Running self-check", metadata: ["selectedContact": selectedContact?.handle ?? "none"])
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: backendRuntime.config != nil,
            isBackendClientReady: backendRuntime.client != nil,
            selectedTarget: selectedContact.map { DevSelfCheckTarget(contactID: $0.id, handle: $0.handle) }
        )
        await selfCheckCoordinator.handle(.runRequested(request))
    }

    private func performSelfCheck(_ request: DevSelfCheckRequest) async {
        guard let backendClient = backendRuntime.client else {
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
            fetchRuntimeConfig: { try await backendClient.fetchRuntimeConfig() },
            authenticate: { try await backendClient.authenticate() },
            heartbeatPresence: { try await backendClient.heartbeatPresence() },
            ensureWebSocketConnected: { backendClient.ensureWebSocketConnected() },
            waitForWebSocketConnection: { try await backendClient.waitForWebSocketConnection() },
            lookupUser: { handle in try await backendClient.lookupUser(handle: handle) },
            directChannel: { handle in try await backendClient.directChannel(otherHandle: handle) },
            channelState: { channelID in try await backendClient.channelState(channelId: channelID) },
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

        let outcome = await DevSelfCheckRunner.run(
            request: request,
            services: services
        )

        if let authenticatedUserID = outcome.authenticatedUserID {
            backendRuntime.currentUserID = authenticatedUserID
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

    func resetLocalDevState(backendStatus: String) {
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
        clearTrackedContacts()
        contacts = []
        statusMessage = "Initializing..."
    }

    func completeLocalBackendJoin(for contact: Contact) {
        sessionCoordinator.clearAfterSuccessfulJoin(for: contact.id)
        activeChannelId = contact.id
        isJoined = true
        updateStatusForSelectedContact()
    }

    func requestBackendJoin(for contact: Contact) {
        guard backendRuntime.client != nil else {
            joinPTTChannel(for: contact)
            return
        }
        let request = BackendJoinRequest(
            contactID: contact.id,
            handle: contact.handle,
            existingRemoteUserID: contact.remoteUserId,
            existingBackendChannelID: contact.backendChannelId,
            incomingInvite: incomingInviteByContactID[contact.id],
            outgoingInvite: outgoingInviteByContactID[contact.id],
            requestCooldownRemaining: requestCooldownRemaining(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend
        )
        Task {
            await backendCommandCoordinator.handle(.joinRequested(request))
        }
    }

    private func applyInviteMetadata(_ invite: TurboInviteResponse, to contact: inout Contact) {
        contact.backendChannelId = invite.channelId
        contact.channelId = ContactDirectory.stableChannelUUID(for: invite.channelId)
        contact.remoteUserId = invite.direction == "incoming" ? invite.fromUserId : invite.toUserId
    }

    private func performOpenPeer(handle: String) async {
        guard let backendClient = backendRuntime.client else {
            backendCommandCoordinator.send(.operationFailed("Backend unavailable"))
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }

        do {
            let remoteUser = try await backendClient.lookupUser(handle: handle)
            let contactID = ensureContactExists(handle: handle, remoteUserId: remoteUser.userId, channelId: "")
            backendRuntime.trackedContactIDs.insert(contactID)
            if let contact = contacts.first(where: { $0.id == contactID }) {
                selectContact(contact)
            }
            backendCommandCoordinator.send(.operationFinished)
            diagnostics.record(.state, message: "Opened peer handle", metadata: ["handle": handle])
        } catch {
            let message = error.localizedDescription
            backendCommandCoordinator.send(.operationFailed(message))
            backendStatusMessage = "Lookup failed: \(message)"
            statusMessage = "Lookup failed"
            diagnostics.record(.backend, level: .error, message: "Peer lookup failed", metadata: ["handle": handle, "error": message])
        }
    }

    private func resolveBackendJoinContact(_ request: BackendJoinRequest) async throws -> Contact {
        guard let backendClient = backendRuntime.client else {
            throw TurboBackendError.invalidConfiguration
        }
        guard let index = contacts.firstIndex(where: { $0.id == request.contactID }) else {
            throw TurboBackendError.invalidResponse
        }

        var contact = contacts[index]

        if let invite = request.incomingInvite {
            _ = try await backendClient.acceptInvite(inviteId: invite.inviteId)
            applyInviteMetadata(invite, to: &contact)
        } else {
            if let invite = request.outgoingInvite {
                applyInviteMetadata(invite, to: &contact)
            } else if request.requestCooldownRemaining == nil {
                let invite = try await backendClient.createInvite(otherHandle: request.handle)
                applyInviteMetadata(invite, to: &contact)
                if invite.direction == "outgoing" {
                    backendSyncCoordinator.send(
                        .outgoingInviteSeeded(
                            contactID: request.contactID,
                            invite: invite,
                            now: Date()
                        )
                    )
                }
            }
        }

        if contact.remoteUserId == nil {
            let remoteUser = try await backendClient.lookupUser(handle: request.handle)
            contact.remoteUserId = remoteUser.userId
        }
        if contact.backendChannelId == nil {
            let channel = try await backendClient.directChannel(otherHandle: request.handle)
            contact.backendChannelId = channel.channelId
            contact.channelId = ContactDirectory.stableChannelUUID(for: channel.channelId)
        }

        contacts[index] = contact
        return contact
    }

    private func performBackendJoin(_ request: BackendJoinRequest) async {
        do {
            let contact = try await resolveBackendJoinContact(request)
            if let backendChannelId = contact.backendChannelId,
               let backendClient = backendRuntime.client {
                _ = try await backendClient.joinChannel(channelId: backendChannelId)
            }
            if request.usesLocalHTTPBackend {
                completeLocalBackendJoin(for: contact)
            } else {
                joinPTTChannel(for: contact)
            }
            await refreshChannelState(for: contact.id)
            await refreshContactSummaries()
            await refreshInvites()
            backendCommandCoordinator.send(.operationFinished)
        } catch {
            let message = error.localizedDescription
            backendCommandCoordinator.send(.operationFailed(message))
            statusMessage = "Join failed: \(message)"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend join failed",
                metadata: ["contactId": request.contactID.uuidString, "handle": request.handle, "error": message]
            )
        }
    }

    private func performBackendLeave(_ request: BackendLeaveRequest) async {
        guard let backendClient = backendRuntime.client else {
            backendCommandCoordinator.send(.operationFailed("Backend unavailable"))
            return
        }

        do {
            _ = try await backendClient.leaveChannel(channelId: request.backendChannelID)
            await refreshChannelState(for: request.contactID)
            await refreshContactSummaries()
            await refreshInvites()
            backendCommandCoordinator.send(.operationFinished)
        } catch {
            let message = error.localizedDescription
            backendCommandCoordinator.send(.operationFailed(message))
            diagnostics.record(
                .backend,
                level: .error,
                message: "Backend leave failed",
                metadata: ["contactId": request.contactID.uuidString, "channelId": request.backendChannelID, "error": message]
            )
        }
    }

    func handleIncomingSignal(_ envelope: TurboSignalEnvelope) {
        guard let contactID = contacts.first(where: { $0.backendChannelId == envelope.channelId })?.id else {
            backendStatusMessage = "Signal: \(envelope.type.rawValue)"
            return
        }

        switch envelope.type {
        case .transmitStart, .transmitStop:
            diagnostics.record(.websocket, message: "Signal received", metadata: ["type": envelope.type.rawValue, "channelId": envelope.channelId])
            Task {
                await refreshContactSummaries()
                await refreshChannelState(for: contactID)
            }
        case .audioChunk:
            diagnostics.record(.media, message: "Audio chunk received", metadata: ["channelId": envelope.channelId, "fromDeviceId": envelope.fromDeviceId])
            Task {
                if selectedContactId == nil {
                    selectedContactId = contactID
                }
                await refreshChannelState(for: contactID)
                await ensureMediaSession(for: contactID)
                await mediaRuntime.session?.receiveRemoteAudioChunk(envelope.payload)
            }
        case .offer, .answer, .iceCandidate, .hangup:
            backendStatusMessage = "Media relay signaling is not wired in this build"
            diagnostics.record(.websocket, message: "Unsupported signal received", metadata: ["type": envelope.type.rawValue])
        }
    }

    func refreshContactSummaries() async {
        guard let backendClient = backendRuntime.client else { return }

        do {
            let summaries = try await backendClient.contactSummaries()
            var nextSummaries: [UUID: TurboContactSummaryResponse] = [:]
            for summary in summaries {
                let channelID = summary.channelId ?? ""
                let contactID = ensureContactExists(
                    handle: summary.handle,
                    remoteUserId: summary.userId,
                    channelId: channelID
                )
                nextSummaries[contactID] = summary
                updateContact(contactID) { contact in
                    contact.isOnline = summary.isOnline
                    contact.remoteUserId = summary.userId
                    if let channelId = summary.channelId {
                        contact.backendChannelId = channelId
                        contact.channelId = ContactDirectory.stableChannelUUID(for: channelId)
                    }
                }
            }
            let updates = nextSummaries.map { BackendContactSummaryUpdate(contactID: $0.key, summary: $0.value) }
            backendSyncCoordinator.send(.contactSummariesUpdated(updates))
            pruneContactsToAuthoritativeState()
            updateStatusForSelectedContact()
            await reconcileSelectedSessionIfNeeded()
        } catch {
            backendSyncCoordinator.send(.contactSummariesFailed("Contact sync failed: \(error.localizedDescription)"))
            contacts = contacts.map { contact in
                var next = contact
                next.isOnline = false
                return next
            }
            pruneContactsToAuthoritativeState()
            diagnostics.record(.backend, level: .error, message: "Contact sync failed", metadata: ["error": error.localizedDescription])
            await reconcileSelectedSessionIfNeeded()
        }
    }

    func refreshChannelState(for contactID: UUID) async {
        guard let backendClient = backendRuntime.client,
              let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelId = contact.backendChannelId else {
            backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
            updateStatusForSelectedContact()
            return
        }

        do {
            let channelState = try await backendClient.channelState(channelId: backendChannelId)
            backendSyncCoordinator.send(.channelStateUpdated(contactID: contactID, channelState: channelState))
            updateContact(contactID) { contact in
                contact.isOnline = channelState.peerOnline
                contact.remoteUserId = channelState.peerUserId
            }
            if selectedContactId == contactID {
                isTransmitting = channelState.status == ConversationState.transmitting.rawValue
                if !isTransmitting {
                    tearDownTransmitRuntime(resetCoordinator: true)
                }
                updateStatusForSelectedContact()
            }
            if selectedContactId == contactID,
               channelState.selfJoined,
               channelState.peerJoined,
               channelState.canTransmit {
                await ensureMediaSession(for: contactID)
            }
            await reconcileSelectedSessionIfNeeded()
        } catch {
            backendSyncCoordinator.send(
                .channelStateFailed(
                    contactID: contactID,
                    message: "Channel sync failed: \(error.localizedDescription)"
                )
            )
            if selectedContactId == contactID {
                resetTransmitSession(closeMediaSession: true)
                updateStatusForSelectedContact()
            }
            diagnostics.record(.channel, level: .error, message: "Channel state refresh failed", metadata: ["contactId": contactID.uuidString, "error": error.localizedDescription])
            await reconcileSelectedSessionIfNeeded()
        }
    }

    func refreshInvites() async {
        guard let backendClient = backendRuntime.client else { return }
        do {
            let incoming = try await backendClient.incomingInvites()
            let outgoing = try await backendClient.outgoingInvites()
            var nextIncoming: [UUID: TurboInviteResponse] = [:]
            var nextOutgoing: [UUID: TurboInviteResponse] = [:]
            for invite in incoming {
                if let handle = invite.fromHandle {
                    let contactID = ensureContactExists(handle: handle, remoteUserId: invite.fromUserId, channelId: invite.channelId)
                    nextIncoming[contactID] = invite
                }
            }
            for invite in outgoing {
                if let handle = invite.toHandle {
                    let contactID = ensureContactExists(handle: handle, remoteUserId: invite.toUserId, channelId: invite.channelId)
                    nextOutgoing[contactID] = invite
                }
            }
            let incomingUpdates = nextIncoming.map { BackendInviteUpdate(contactID: $0.key, invite: $0.value) }
            let outgoingUpdates = nextOutgoing.map { BackendInviteUpdate(contactID: $0.key, invite: $0.value) }
            backendSyncCoordinator.send(.invitesUpdated(incoming: incomingUpdates, outgoing: outgoingUpdates, now: .now))
            pruneContactsToAuthoritativeState()
            updateStatusForSelectedContact()
            await reconcileSelectedSessionIfNeeded()
        } catch {
            backendSyncCoordinator.send(.invitesFailed("Invite sync failed: \(error.localizedDescription)"))
            pruneContactsToAuthoritativeState()
            diagnostics.record(.backend, level: .error, message: "Invite sync failed", metadata: ["error": error.localizedDescription])
            await reconcileSelectedSessionIfNeeded()
        }
    }

    func startBackendPollingIfNeeded() {
        guard backendRuntime.pollTask == nil else { return }
        backendRuntime.pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let selectedContactId = await MainActor.run(body: { self.selectedContactId })
                await self.backendSyncCoordinator.handle(.pollRequested(selectedContactID: selectedContactId))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func handleWebSocketStateChange(_ state: TurboBackendClient.WebSocketConnectionState) {
        guard let backendClient = backendRuntime.client, backendClient.supportsWebSocket else { return }
        diagnostics.record(.websocket, message: "WebSocket state changed", metadata: ["state": String(describing: state)])

        switch state {
        case .idle:
            if transmitRuntime.activeTarget != nil || mediaRuntime.session != nil {
                Task {
                    await transmitCoordinator.handle(.websocketDisconnected)
                    resetTransmitSession(closeMediaSession: true)
                    updateStatusForSelectedContact()
                }
            }
        case .connecting:
            backendStatusMessage = "Connecting WebSocket..."
        case .connected:
            Task {
                await backendSyncCoordinator.handle(.webSocketStateChanged(state, selectedContactID: selectedContactId))
            }
        }
    }
}
