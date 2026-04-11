//
//  PTTViewModel+BackendCommands.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation

enum BackendJoinExecutionPlan: Equatable {
    case requestOnly
    case joinSession
}

struct ResolvedBackendJoinContact {
    let contact: Contact
    let executionPlan: BackendJoinExecutionPlan
}

extension PTTViewModel {
    func shouldIgnoreInviteNotFoundFailure(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "invite not found"
    }

    func shouldIgnoreIncomingInviteAcceptFailure(_ error: Error) -> Bool {
        shouldIgnoreInviteNotFoundFailure(error)
    }

    func shouldTreatBackendJoinChannelNotFoundAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel not found"
    }

    func shouldTreatBackendJoinMetadataFailureAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "missing otheruserid or otherhandle"
    }

    func declineIncomingRequestForSelectedContact() async {
        guard let contact = selectedContact else {
            statusMessage = "Pick a contact"
            return
        }
        guard let backend = backendServices else {
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }
        guard let invite = incomingInviteByContactID[contact.id] else {
            statusMessage = "No incoming request"
            return
        }

        do {
            _ = try await backend.declineInvite(inviteId: invite.inviteId)
            await refreshInvites()
            await refreshChannelState(for: contact.id)
            await refreshContactSummaries()
            diagnostics.record(.backend, message: "Declined incoming request", metadata: ["handle": contact.handle])
            captureDiagnosticsState("selected-peer:decline-request")
            updateStatusForSelectedContact()
        } catch {
            let message = error.localizedDescription
            backendStatusMessage = "Decline failed: \(message)"
            statusMessage = "Decline failed"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Decline request failed",
                metadata: ["handle": contact.handle, "error": message]
            )
            captureDiagnosticsState("selected-peer:decline-request-failed")
        }
    }

    func cancelOutgoingRequestForSelectedContact() async {
        guard let contact = selectedContact else {
            statusMessage = "Pick a contact"
            return
        }
        guard let backend = backendServices else {
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }
        guard let invite = outgoingInviteByContactID[contact.id] else {
            statusMessage = "No outgoing request"
            return
        }

        do {
            _ = try await backend.cancelInvite(inviteId: invite.inviteId)
            await refreshInvites()
            await refreshChannelState(for: contact.id)
            await refreshContactSummaries()
            diagnostics.record(.backend, message: "Cancelled outgoing request", metadata: ["handle": contact.handle])
            captureDiagnosticsState("selected-peer:cancel-request")
            updateStatusForSelectedContact()
        } catch {
            let message = error.localizedDescription
            backendStatusMessage = "Cancel failed: \(message)"
            statusMessage = "Cancel failed"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Cancel request failed",
                metadata: ["handle": contact.handle, "error": message]
            )
            captureDiagnosticsState("selected-peer:cancel-request-failed")
        }
    }

    func backendJoinExecutionPlan(
        request: BackendJoinRequest,
        createdInvite: TurboInviteResponse?,
        currentChannel: ChannelReadinessSnapshot?
    ) -> BackendJoinExecutionPlan {
        if request.relationship.isIncomingRequest {
            return .joinSession
        }
        if currentChannel?.peerJoined == true {
            return .joinSession
        }
        if request.relationship.isOutgoingRequest,
           currentChannel?.peerJoined != true {
            return .requestOnly
        }
        if request.outgoingInvite != nil {
            return .requestOnly
        }
        if createdInvite?.direction == "incoming" {
            return .joinSession
        }
        return .requestOnly
    }

    private func liveJoinChannelSnapshot(
        for contact: Contact,
        backend: BackendServices
    ) async -> ChannelReadinessSnapshot? {
        guard let backendChannelId = contact.backendChannelId else {
            return channelStateByContactID[contact.id].map(ChannelReadinessSnapshot.init(channelState:))
        }

        do {
            let channelState = try await backend.channelState(channelId: backendChannelId)
            backendSyncCoordinator.send(
                .channelStateUpdated(contactID: contact.id, channelState: channelState)
            )
            return ChannelReadinessSnapshot(channelState: channelState)
        } catch {
            diagnostics.record(
                .backend,
                message: "Falling back to cached join visibility after channel-state refresh failed",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "channelId": backendChannelId,
                    "error": error.localizedDescription,
                ]
            )
            return channelStateByContactID[contact.id].map(ChannelReadinessSnapshot.init(channelState:))
        }
    }

    func openContact(handle: String) async {
        let normalizedHandle = Contact.normalizedHandle(handle)
        guard normalizedHandle != currentDevUserHandle else {
            statusMessage = "Pick another handle"
            return
        }
        guard backendServices != nil else {
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }

        await backendCommandCoordinator.handle(.openPeerRequested(handle: normalizedHandle))
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

    func completeLocalBackendJoin(for contact: Contact) {
        sessionCoordinator.clearAfterSuccessfulJoin(for: contact.id)
        activeChannelId = contact.id
        isJoined = true
        updateStatusForSelectedContact()
    }

    func requestBackendJoin(for contact: Contact) {
        guard backendServices != nil else {
            joinPTTChannel(for: contact)
            return
        }
        let request = BackendJoinRequest(
            contactID: contact.id,
            handle: contact.handle,
            relationship: relationshipState(for: contact.id),
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

    private func applyDirectChannelMetadata(
        _ channel: TurboDirectChannelResponse,
        currentUserID: String?,
        to contact: inout Contact
    ) {
        contact.backendChannelId = channel.channelId
        contact.channelId = ContactDirectory.stableChannelUUID(for: channel.channelId)
        guard let currentUserID else { return }

        if channel.lowUserId == currentUserID {
            contact.remoteUserId = channel.highUserId
        } else if channel.highUserId == currentUserID {
            contact.remoteUserId = channel.lowUserId
        }
    }

    private func performOpenPeer(handle: String) async {
        guard let backend = backendServices else {
            backendCommandCoordinator.send(.operationFailed("Backend unavailable"))
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }

        do {
            let remoteUser = try await backend.lookupUser(handle: handle)
            let contactID = ensureContactExists(handle: handle, remoteUserId: remoteUser.userId, channelId: "")
            trackContact(contactID)
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
            diagnostics.record(
                .backend,
                level: .error,
                message: "Peer lookup failed",
                metadata: ["handle": handle, "error": message]
            )
        }
    }

    func inviteMatchesJoinRequest(_ invite: TurboInviteResponse, request: BackendJoinRequest, direction: String) -> Bool {
        guard invite.direction == direction else { return false }

        let normalizedHandle = Contact.normalizedHandle(request.handle)
        let expectedChannelID = request.existingBackendChannelID
        let expectedRemoteUserID = request.existingRemoteUserID

        if let expectedChannelID, invite.channelId == expectedChannelID {
            return true
        }

        switch direction {
        case "incoming":
            if invite.fromHandle.map(Contact.normalizedHandle) == normalizedHandle {
                return true
            }
            if let expectedRemoteUserID, invite.fromUserId == expectedRemoteUserID {
                return true
            }
        case "outgoing":
            if invite.toHandle.map(Contact.normalizedHandle) == normalizedHandle {
                return true
            }
            if let expectedRemoteUserID, invite.toUserId == expectedRemoteUserID {
                return true
            }
        default:
            break
        }

        return false
    }

    private func resolveIncomingInvite(
        for request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> TurboInviteResponse? {
        guard request.relationship.isIncomingRequest else { return nil }
        if let invite = request.incomingInvite {
            return invite
        }

        let incomingInvites = try await backend.incomingInvites()
        return incomingInvites.first { inviteMatchesJoinRequest($0, request: request, direction: "incoming") }
    }

    private func resolveOutgoingInvite(
        for request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> TurboInviteResponse? {
        guard request.relationship.isOutgoingRequest else { return nil }
        if let invite = request.outgoingInvite {
            return invite
        }

        let outgoingInvites = try await backend.outgoingInvites()
        return outgoingInvites.first { inviteMatchesJoinRequest($0, request: request, direction: "outgoing") }
    }

    private func resolveBackendJoinContact(_ request: BackendJoinRequest) async throws -> ResolvedBackendJoinContact {
        guard let backend = backendServices else {
            throw TurboBackendError.invalidConfiguration
        }
        guard let index = contacts.firstIndex(where: { $0.id == request.contactID }) else {
            throw TurboBackendError.invalidResponse
        }

        var contact = contacts[index]
        var createdInvite: TurboInviteResponse?

        if contact.remoteUserId == nil {
            let remoteUser = try await backend.lookupUser(handle: request.handle)
            contact.remoteUserId = remoteUser.userId
        }

        if request.relationship.isIncomingRequest,
           let outgoingInvite = try await resolveOutgoingInvite(for: request, backend: backend) {
            do {
                _ = try await backend.cancelInvite(inviteId: outgoingInvite.inviteId)
                diagnostics.record(
                    .backend,
                    message: "Cancelled superseded outgoing request before incoming join",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            } catch {
                guard shouldIgnoreInviteNotFoundFailure(error) else {
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Cancel superseded outgoing request failed",
                        metadata: ["contactId": request.contactID.uuidString, "handle": request.handle, "error": error.localizedDescription]
                    )
                    throw error
                }
                diagnostics.record(
                    .backend,
                    message: "Ignoring stale superseded outgoing request cancel failure",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            }
        }

        if let invite = try await resolveIncomingInvite(for: request, backend: backend) {
            do {
                _ = try await backend.acceptInvite(inviteId: invite.inviteId)
            } catch {
                guard shouldIgnoreIncomingInviteAcceptFailure(error) else {
                    throw error
                }
                diagnostics.record(
                    .backend,
                    message: "Ignoring stale incoming invite accept failure",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            }
            applyInviteMetadata(invite, to: &contact)
        } else if request.relationship.isIncomingRequest {
            diagnostics.record(
                .backend,
                message: "Proceeding without incoming invite metadata",
                metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
            )
        } else if let invite = try await resolveOutgoingInvite(for: request, backend: backend) {
            applyInviteMetadata(invite, to: &contact)
        } else if request.requestCooldownRemaining == nil {
            let invite = try await backend.createInvite(otherHandle: request.handle)
            createdInvite = invite
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

        if contact.backendChannelId == nil || request.relationship.isIncomingRequest {
            let channel = try await backend.directChannel(otherHandle: request.handle)
            applyDirectChannelMetadata(channel, currentUserID: backend.currentUserID, to: &contact)
        }

        contacts[index] = contact
        let currentChannel = await liveJoinChannelSnapshot(for: contact, backend: backend)
        return ResolvedBackendJoinContact(
            contact: contact,
            executionPlan: backendJoinExecutionPlan(
                request: request,
                createdInvite: createdInvite,
                currentChannel: currentChannel
            )
        )
    }

    private func refreshJoinChannelMetadata(
        for contact: Contact,
        request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> Contact {
        let channel = try await backend.directChannel(otherHandle: request.handle)

        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else {
            throw TurboBackendError.invalidResponse
        }

        var refreshedContact = contacts[index]
        applyDirectChannelMetadata(channel, currentUserID: backend.currentUserID, to: &refreshedContact)
        contacts[index] = refreshedContact

        diagnostics.record(
            .backend,
            message: "Refreshed backend channel metadata after join drift",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "channelId": channel.channelId,
            ]
        )

        return refreshedContact
    }

    private func refreshJoinContactMetadata(
        for request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> BackendJoinRequest {
        guard let index = contacts.firstIndex(where: { $0.id == request.contactID }) else {
            throw TurboBackendError.invalidResponse
        }

        var refreshedContact = contacts[index]
        let remoteUser = try await backend.lookupUser(handle: request.handle)
        refreshedContact.remoteUserId = remoteUser.userId

        let channel = try await backend.directChannel(otherHandle: request.handle)
        applyDirectChannelMetadata(channel, currentUserID: backend.currentUserID, to: &refreshedContact)

        contacts[index] = refreshedContact

        await refreshContactSummaries()
        await refreshInvites()
        await refreshChannelState(for: refreshedContact.id)

        diagnostics.record(
            .backend,
            message: "Refreshed join contact metadata after backend drift",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "channelId": refreshedContact.backendChannelId ?? "none",
            ]
        )

        return BackendJoinRequest(
            contactID: refreshedContact.id,
            handle: refreshedContact.handle,
            relationship: relationshipState(for: refreshedContact.id),
            existingRemoteUserID: refreshedContact.remoteUserId,
            existingBackendChannelID: refreshedContact.backendChannelId,
            incomingInvite: incomingInviteByContactID[refreshedContact.id],
            outgoingInvite: outgoingInviteByContactID[refreshedContact.id],
            requestCooldownRemaining: requestCooldownRemaining(for: refreshedContact.id),
            usesLocalHTTPBackend: request.usesLocalHTTPBackend
        )
    }

    private func performRecoverableBackendJoin(
        contact: Contact,
        request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> Contact {
        guard let backendChannelId = contact.backendChannelId else {
            throw TurboBackendError.invalidResponse
        }

        do {
            _ = try await backend.joinChannel(channelId: backendChannelId)
            return contact
        } catch {
            guard shouldTreatBackendJoinChannelNotFoundAsRecoverable(error) else {
                throw error
            }

            diagnostics.record(
                .backend,
                message: "Recovering backend join after channel drift",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "channelId": backendChannelId,
                ]
            )

            let refreshedContact = try await refreshJoinChannelMetadata(for: contact, request: request, backend: backend)
            guard let refreshedChannelId = refreshedContact.backendChannelId else {
                throw TurboBackendError.invalidResponse
            }
            _ = try await backend.joinChannel(channelId: refreshedChannelId)
            return refreshedContact
        }
    }

    private func refreshBackendJoinVisibility(for contactID: UUID) async {
        await refreshChannelState(for: contactID)
        await refreshContactSummaries()
        await refreshInvites()
        updateStatusForSelectedContact()
    }

    private func executeBackendJoin(_ request: BackendJoinRequest) async throws {
        let resolution = try await resolveBackendJoinContact(request)
        var contact = resolution.contact

        switch resolution.executionPlan {
        case .requestOnly:
            sessionCoordinator.clearPendingConnect(for: request.contactID)
            updateStatusForSelectedContact()
        case .joinSession:
            if let backend = backendServices {
                contact = try await performRecoverableBackendJoin(
                    contact: contact,
                    request: request,
                    backend: backend
                )
                diagnostics.record(
                    .backend,
                    message: "Backend join completed",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "channelId": contact.backendChannelId ?? "none",
                    ]
                )
                await refreshBackendJoinVisibility(for: contact.id)
            }
            if request.usesLocalHTTPBackend {
                completeLocalBackendJoin(for: contact)
            } else {
                joinPTTChannel(for: contact)
            }
        }

        await refreshBackendJoinVisibility(for: contact.id)
        backendCommandCoordinator.send(.operationFinished)
    }

    private func performBackendJoin(_ request: BackendJoinRequest) async {
        do {
            do {
                try await executeBackendJoin(request)
            } catch {
                guard let backend = backendServices,
                      shouldTreatBackendJoinMetadataFailureAsRecoverable(error) else {
                    throw error
                }

                diagnostics.record(
                    .backend,
                    message: "Recovering backend join after metadata drift",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                    ]
                )

                let refreshedRequest = try await refreshJoinContactMetadata(for: request, backend: backend)
                try await executeBackendJoin(refreshedRequest)
            }
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
        guard let backend = backendServices else {
            backendCommandCoordinator.send(.operationFailed("Backend unavailable"))
            return
        }

        do {
            _ = try await backend.leaveChannel(channelId: request.backendChannelID)
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
}
