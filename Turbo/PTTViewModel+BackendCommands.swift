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

private enum BackendJoinCommandOutcome: Equatable {
    case commandReturned
    case membershipVisible
    case visibilityTimedOut
    case commandTimedOut
}

struct ResolvedBackendJoinContact {
    let contact: Contact
    let executionPlan: BackendJoinExecutionPlan
}

extension PTTViewModel {
    func waitForAcceptedIncomingInviteToDisappear(
        _ acceptedInvite: TurboInviteResponse,
        request: BackendJoinRequest,
        backend: BackendServices
    ) async {
        for attempt in 1 ... 20 {
            do {
                let incomingInvites = try await backend.incomingInvites()
                let stillPending = incomingInvites.contains { $0.inviteId == acceptedInvite.inviteId }
                if !stillPending {
                    diagnostics.record(
                        .backend,
                        message: "Incoming invite acceptance became visible",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "attempt": "\(attempt)",
                        ]
                    )
                    return
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Incoming invite acceptance visibility check failed",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "attempt": "\(attempt)",
                        "error": error.localizedDescription,
                    ]
                )
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        diagnostics.record(
            .backend,
            message: "Incoming invite acceptance still pending after visibility wait",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "inviteId": acceptedInvite.inviteId,
            ]
        )
    }

    func shouldIgnoreInviteNotFoundFailure(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "invite not found"
    }

    func shouldIgnoreIncomingInviteAcceptFailure(_ error: Error) -> Bool {
        shouldIgnoreInviteNotFoundFailure(error)
    }

    func waitForInviteToDisappear(
        inviteID: String,
        contactID: UUID,
        handle: String,
        label: String,
        fetchInvites: @escaping () async throws -> [TurboInviteResponse]
    ) async {
        for attempt in 1 ... 20 {
            do {
                let invites = try await fetchInvites()
                let stillPresent = invites.contains { $0.inviteId == inviteID }
                if !stillPresent {
                    diagnostics.record(
                        .backend,
                        message: "\(label) became visible",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "handle": handle,
                            "attempt": "\(attempt)",
                            "inviteId": inviteID
                        ]
                    )
                    return
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "\(label) visibility check failed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "handle": handle,
                        "attempt": "\(attempt)",
                        "inviteId": inviteID,
                        "error": error.localizedDescription
                    ]
                )
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        diagnostics.record(
            .backend,
            message: "\(label) still pending after visibility wait",
            metadata: [
                "contactId": contactID.uuidString,
                "handle": handle,
                "inviteId": inviteID
            ]
        )
    }

    func shouldTreatBackendJoinChannelNotFoundAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel not found"
    }

    func shouldTreatBackendJoinMetadataFailureAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "missing otheruserid or otherhandle"
    }

    func shouldTreatBackendJoinDisconnectedSessionAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "device session not connected"
    }

    func shouldProceedWithBackendJoinWithoutWebSocket(_ error: Error) -> Bool {
        guard case .webSocketUnavailable = error as? TurboBackendError else { return false }
        return true
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
            markIncomingRequestHandledLocally(
                contactID: contact.id,
                invite: invite,
                relationship: relationshipState(for: contact.id),
                reason: "decline-selected"
            )
            _ = try await backend.declineInvite(inviteId: invite.inviteId)
            await waitForInviteToDisappear(
                inviteID: invite.inviteId,
                contactID: contact.id,
                handle: contact.handle,
                label: "Incoming invite decline",
                fetchInvites: { try await backend.incomingInvites() }
            )
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
            await waitForInviteToDisappear(
                inviteID: invite.inviteId,
                contactID: contact.id,
                handle: contact.handle,
                label: "Outgoing invite cancel",
                fetchInvites: { try await backend.outgoingInvites() }
            )
            await refreshInvites()
            await refreshChannelState(for: contact.id)
            await refreshContactSummaries()
            selectedPeerCoordinator.send(.requesterAutoJoinCancelled(contactID: contact.id))
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
        if currentChannel?.membership.hasLocalMembership == true {
            return .joinSession
        }
        if request.relationship.isIncomingRequest {
            return .joinSession
        }
        if request.intent == .joinReadyPeer {
            return .joinSession
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
            return channelStateByContactID[contact.id].map {
                ChannelReadinessSnapshot(
                    channelState: $0,
                    readiness: channelReadinessByContactID[contact.id]
                )
            }
        }

        do {
            async let channelStateTask = backend.channelState(channelId: backendChannelId)
            async let channelReadinessTask = backend.channelReadiness(channelId: backendChannelId)
            let channelState = try await channelStateTask
            let channelReadiness = try? await channelReadinessTask
            backendSyncCoordinator.send(
                .channelStateUpdated(contactID: contact.id, channelState: channelState)
            )
            if let channelReadiness {
                backendSyncCoordinator.send(
                    .channelReadinessUpdated(contactID: contact.id, readiness: channelReadiness)
                )
            }
            return ChannelReadinessSnapshot(channelState: channelState, readiness: channelReadiness)
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
            return channelStateByContactID[contact.id].map {
                ChannelReadinessSnapshot(
                    channelState: $0,
                    readiness: channelReadinessByContactID[contact.id]
                )
            }
        }
    }

    func openContact(reference: String) async {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReference = TurboIncomingLink.publicID(from: trimmedReference) ?? trimmedReference
        guard !normalizedReference.isEmpty else { return }
        guard backendServices != nil else {
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }

        await backendCommandCoordinator.handle(.openPeerRequested(handle: normalizedReference))
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
        updateAutomaticAudioRouteMonitoring(reason: "backend-join-complete")
        updateStatusForSelectedContact()
    }

    func requestBackendJoin(for contact: Contact, intent: BackendJoinIntent = .requestConnection) {
        let relationship = relationshipState(for: contact.id)
        let incomingInvite = incomingInviteByContactID[contact.id]
        if relationship.isIncomingRequest {
            markIncomingRequestHandledLocally(
                contactID: contact.id,
                invite: incomingInvite,
                relationship: relationship,
                reason: "accept-\(String(describing: intent))"
            )
        }
        guard backendServices != nil else {
            joinPTTChannel(for: contact)
            return
        }
        let activeJoinRequest: BackendJoinRequest? = {
            guard case .join(let request) = backendCommandCoordinator.state.activeOperation,
                  request.contactID == contact.id,
                  request.intent == intent else {
                return nil
            }
            return request
        }()
        let request = BackendJoinRequest(
            contactID: contact.id,
            handle: contact.handle,
            intent: intent,
            operationID: activeJoinRequest?.operationID ?? backendConnectOperationID(for: contact, intent: intent),
            joinOperationID: activeJoinRequest?.joinOperationID ?? backendChannelJoinOperationID(for: contact, intent: intent),
            relationship: relationship,
            existingRemoteUserID: contact.remoteUserId,
            existingBackendChannelID: contact.backendChannelId,
            incomingInvite: incomingInvite,
            outgoingInvite: outgoingInviteByContactID[contact.id],
            requestCooldownRemaining: requestCooldownRemaining(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend
        )
        Task {
            await backendCommandCoordinator.handle(.joinRequested(request))
        }
    }

    func reassertBackendJoin(for contact: Contact) async {
        guard backendServices != nil else { return }
        let request = BackendJoinRequest(
            contactID: contact.id,
            handle: contact.handle,
            intent: .joinReadyPeer,
            operationID: backendConnectOperationID(for: contact, intent: .joinReadyPeer),
            joinOperationID: backendChannelJoinOperationID(for: contact, intent: .joinReadyPeer),
            relationship: relationshipState(for: contact.id),
            existingRemoteUserID: contact.remoteUserId,
            existingBackendChannelID: contact.backendChannelId,
            incomingInvite: incomingInviteByContactID[contact.id],
            outgoingInvite: outgoingInviteByContactID[contact.id],
            requestCooldownRemaining: requestCooldownRemaining(for: contact.id),
            usesLocalHTTPBackend: usesLocalHTTPBackend
        )
        if case .leave(let contactID) = backendCommandCoordinator.state.activeOperation,
           contactID == contact.id {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Skipped backend join reassertion while leave is active",
                metadata: ["contactId": contact.id.uuidString, "handle": contact.handle]
            )
            return
        }
        if case .join(let activeRequest) = backendCommandCoordinator.state.activeOperation,
           activeRequest.contactID == contact.id {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Forcing backend join reassertion past in-flight join",
                metadata: ["contactId": contact.id.uuidString, "handle": contact.handle]
            )
            backendCommandCoordinator.send(.reset)
        }
        await backendCommandCoordinator.handle(.joinRequested(request))
    }

    private func applyInviteMetadata(_ invite: TurboInviteResponse, to contact: inout Contact) {
        contact.backendChannelId = invite.channelId
        contact.channelId = ContactDirectory.stableChannelUUID(for: invite.channelId)
        contact.remoteUserId = invite.direction == "incoming" ? invite.fromUserId : invite.toUserId
    }

    func markIncomingRequestHandledLocally(
        contactID: UUID,
        invite: TurboInviteResponse?,
        relationship: PairRelationshipState,
        reason: String
    ) {
        guard relationship.isIncomingRequest || invite != nil else { return }
        let requestCount = max(relationship.requestCount ?? 0, invite?.requestCount ?? 0)
        backendSyncCoordinator.send(
            .incomingRequestHandled(
                contactID: contactID,
                invite: invite,
                requestCount: requestCount,
                now: Date()
            )
        )
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .contactOpened(contactID: contactID, inviteID: invite?.inviteId)
        )
        diagnostics.record(
            .backend,
            message: "Marked incoming request handled locally",
            metadata: [
                "contactId": contactID.uuidString,
                "inviteId": invite?.inviteId ?? "none",
                "requestCount": "\(requestCount)",
                "reason": reason,
            ]
        )
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

    private func backendPeerIdentityQuery(
        handle: String,
        remoteUserId: String?
    ) -> (otherHandle: String?, otherUserId: String?) {
        if let remoteUserId, !remoteUserId.isEmpty {
            return (nil, remoteUserId)
        }
        return (handle, nil)
    }

    private func performOpenPeer(handle: String) async {
        guard let backend = backendServices else {
            backendCommandCoordinator.send(.operationFailed("Backend unavailable"))
            backendStatusMessage = "Backend unavailable"
            statusMessage = "Backend unavailable"
            return
        }

        do {
            let remoteUser = try await backend.resolveIdentity(reference: handle)
            guard remoteUser.userId != backend.currentUserID else {
                backendCommandCoordinator.send(.operationFailed("cannot open self"))
                statusMessage = "Pick another handle"
                backendStatusMessage = "That handle belongs to this device account"
                return
            }
            let contactID = ensureContactExists(
                handle: remoteUser.publicId,
                remoteUserId: remoteUser.userId,
                channelId: "",
                displayName: remoteUser.profileName
            )
            // Make the new peer authoritative before any further awaits so background sync
            // cannot prune the selection candidate out from under the open-peer flow.
            trackContact(contactID)
            if let contact = contacts.first(where: { $0.id == contactID }) {
                selectContact(contact)
            }
            do {
                _ = try await backend.rememberContact(otherUserId: remoteUser.userId)
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Remember contact failed",
                    metadata: [
                        "reference": handle,
                        "publicId": remoteUser.publicId,
                        "error": error.localizedDescription,
                    ]
                )
            }
            if let presence = try? await backend.lookupPresence(handle: remoteUser.publicId) {
                updateContact(contactID) { contact in
                    contact.name = remoteUser.profileName
                    contact.handle = remoteUser.publicId
                    contact.isOnline = presence.isOnline
                    contact.remoteUserId = presence.userId
                }
            }
            await refreshContactSummaries()
            await refreshInvites()
            backendCommandCoordinator.send(.operationFinished)
            diagnostics.record(
                .state,
                message: "Opened peer identity",
                metadata: ["reference": handle, "publicId": remoteUser.publicId]
            )
        } catch {
            let message = error.localizedDescription
            backendCommandCoordinator.send(.operationFailed(message))
            backendStatusMessage = "Lookup failed: \(message)"
            statusMessage = "Lookup failed"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Peer lookup failed",
                metadata: ["reference": handle, "error": message]
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

    func isPendingInvite(_ invite: TurboInviteResponse) -> Bool {
        invite.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending"
    }

    func freshestMatchingIncomingInvite(
        for request: BackendJoinRequest,
        cachedInvite: TurboInviteResponse?,
        fetchedInvites: [TurboInviteResponse],
        excludingInviteIDs: Set<String> = []
    ) -> TurboInviteResponse? {
        let fetched = fetchedInvites
            .filter { invite in
                !excludingInviteIDs.contains(invite.inviteId)
                    && isPendingInvite(invite)
                    && inviteMatchesJoinRequest(invite, request: request, direction: "incoming")
            }
            .sorted { lhs, rhs in
                (lhs.updatedAt ?? lhs.createdAt) > (rhs.updatedAt ?? rhs.createdAt)
            }
            .first
        if let fetched {
            return fetched
        }

        guard let cachedInvite,
              !excludingInviteIDs.contains(cachedInvite.inviteId),
              isPendingInvite(cachedInvite),
              inviteMatchesJoinRequest(cachedInvite, request: request, direction: "incoming") else {
            return nil
        }
        return cachedInvite
    }

    private func resolveIncomingInvite(
        for request: BackendJoinRequest,
        backend: BackendServices,
        excludingInviteIDs: Set<String> = []
    ) async throws -> TurboInviteResponse? {
        guard request.relationship.isIncomingRequest else { return nil }

        do {
            let incomingInvites = try await backend.incomingInvites()
            let invite = freshestMatchingIncomingInvite(
                for: request,
                cachedInvite: request.incomingInvite,
                fetchedInvites: incomingInvites,
                excludingInviteIDs: excludingInviteIDs
            )
            if let cachedInvite = request.incomingInvite,
               let invite,
               cachedInvite.inviteId != invite.inviteId {
                diagnostics.record(
                    .backend,
                    message: "Using fresher incoming invite instead of cached invite",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "cachedInviteId": cachedInvite.inviteId,
                        "freshInviteId": invite.inviteId,
                    ]
                )
            }
            return invite
        } catch {
            guard let cachedInvite = freshestMatchingIncomingInvite(
                for: request,
                cachedInvite: request.incomingInvite,
                fetchedInvites: [],
                excludingInviteIDs: excludingInviteIDs
            ) else {
                throw error
            }
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Falling back to cached incoming invite after refresh failed",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "inviteId": cachedInvite.inviteId,
                    "error": error.localizedDescription,
                ]
            )
            return cachedInvite
        }
    }

    private func acceptIncomingInviteForJoinRequest(
        _ request: BackendJoinRequest,
        backend: BackendServices
    ) async throws -> TurboInviteResponse? {
        guard request.relationship.isIncomingRequest else { return nil }
        var attemptedInviteIDs: Set<String> = []

        for _ in 0 ..< 2 {
            guard let invite = try await resolveIncomingInvite(
                for: request,
                backend: backend,
                excludingInviteIDs: attemptedInviteIDs
            ) else {
                return nil
            }
            attemptedInviteIDs.insert(invite.inviteId)

            let acceptedInvite: TurboInviteResponse
            do {
                acceptedInvite = try await backend.acceptInvite(inviteId: invite.inviteId)
            } catch {
                guard shouldIgnoreIncomingInviteAcceptFailure(error) else {
                    throw error
                }
                diagnostics.record(
                    .backend,
                    level: .notice,
                    message: "Ignoring stale incoming invite accept failure; retrying with current pending invite",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "inviteId": invite.inviteId,
                        "error": error.localizedDescription,
                    ]
                )
                continue
            }
            if acceptedInvite.pendingJoin != false {
                Task { @MainActor [weak self] in
                    await self?.waitForAcceptedIncomingInviteToDisappear(
                        acceptedInvite,
                        request: request,
                        backend: backend
                    )
                }
                return acceptedInvite
            }

            diagnostics.record(
                .backend,
                level: .notice,
                message: "Accepted stale incoming invite; retrying with current pending invite",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                    "inviteId": invite.inviteId,
                    "status": acceptedInvite.status,
                ]
            )
        }

        return nil
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

    func shouldReplaceExistingOutgoingInvite(for request: BackendJoinRequest) -> Bool {
        guard request.intent == .requestConnection else { return false }
        guard !request.relationship.isIncomingRequest else { return false }
        guard request.relationship.isOutgoingRequest else { return false }
        return request.requestCooldownRemaining == nil
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
        let shouldReplaceOutgoingInvite = shouldReplaceExistingOutgoingInvite(for: request)

        if contact.remoteUserId == nil {
            let remoteUser = try await backend.resolveIdentity(reference: request.handle)
            contact.remoteUserId = remoteUser.userId
            contact.handle = remoteUser.publicId
            contact.name = remoteUser.profileName
        }

        if request.relationship.isIncomingRequest,
           request.relationship.isOutgoingRequest,
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

        if shouldReplaceOutgoingInvite,
           let outgoingInvite = try await resolveOutgoingInvite(for: request, backend: backend) {
            do {
                _ = try await backend.cancelInvite(inviteId: outgoingInvite.inviteId)
                diagnostics.record(
                    .backend,
                    message: "Cancelled stale outgoing request before sending request again",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            } catch {
                guard shouldIgnoreInviteNotFoundFailure(error) else {
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Cancel request-again outgoing invite failed",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "error": error.localizedDescription,
                        ]
                    )
                    throw error
                }
                diagnostics.record(
                    .backend,
                    message: "Ignoring stale request-again outgoing invite cancel failure",
                    metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
                )
            }
        }

        if let invite = try await acceptIncomingInviteForJoinRequest(request, backend: backend) {
            applyInviteMetadata(invite, to: &contact)
        } else if request.relationship.isIncomingRequest {
            diagnostics.record(
                .backend,
                message: "Proceeding without incoming invite metadata",
                metadata: ["contactId": request.contactID.uuidString, "handle": request.handle]
            )
        }

        if contact.backendChannelId == nil || request.relationship.isIncomingRequest {
            let identityQuery = backendPeerIdentityQuery(
                handle: request.handle,
                remoteUserId: contact.remoteUserId ?? request.existingRemoteUserID
            )
            let channel = try await backend.directChannel(
                otherHandle: identityQuery.otherHandle,
                otherUserId: identityQuery.otherUserId
            )
            applyDirectChannelMetadata(channel, currentUserID: backend.currentUserID, to: &contact)
        }

        let currentChannel = await liveJoinChannelSnapshot(for: contact, backend: backend)

        if !shouldReplaceOutgoingInvite,
           let invite = try await resolveOutgoingInvite(for: request, backend: backend) {
            applyInviteMetadata(invite, to: &contact)
        } else if !request.relationship.isIncomingRequest,
                  request.intent != .joinReadyPeer,
                  request.requestCooldownRemaining == nil {
            let identityQuery = backendPeerIdentityQuery(
                handle: request.handle,
                remoteUserId: contact.remoteUserId ?? request.existingRemoteUserID
            )
            let invite = try await backend.createInvite(
                otherHandle: identityQuery.otherHandle,
                otherUserId: identityQuery.otherUserId,
                operationId: request.operationID
            )
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

        contacts[index] = contact
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
        let identityQuery = backendPeerIdentityQuery(
            handle: request.handle,
            remoteUserId: contact.remoteUserId ?? request.existingRemoteUserID
        )
        let channel = try await backend.directChannel(
            otherHandle: identityQuery.otherHandle,
            otherUserId: identityQuery.otherUserId
        )

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
        let remoteUser = try await backend.resolveIdentity(reference: request.handle)
        refreshedContact.remoteUserId = remoteUser.userId
        refreshedContact.handle = remoteUser.publicId
        refreshedContact.name = remoteUser.profileName

        let identityQuery = backendPeerIdentityQuery(
            handle: request.handle,
            remoteUserId: remoteUser.userId
        )
        let channel = try await backend.directChannel(
            otherHandle: identityQuery.otherHandle,
            otherUserId: identityQuery.otherUserId
        )
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
            intent: request.intent,
            operationID: request.operationID,
            joinOperationID: backendChannelJoinOperationID(for: refreshedContact, intent: request.intent),
            relationship: relationshipState(for: refreshedContact.id),
            existingRemoteUserID: refreshedContact.remoteUserId,
            existingBackendChannelID: refreshedContact.backendChannelId,
            incomingInvite: incomingInviteByContactID[refreshedContact.id],
            outgoingInvite: outgoingInviteByContactID[refreshedContact.id],
            requestCooldownRemaining: requestCooldownRemaining(for: refreshedContact.id),
            usesLocalHTTPBackend: request.usesLocalHTTPBackend
        )
    }

    func backendConnectOperationID(for contact: Contact, intent: BackendJoinIntent) -> String? {
        guard intent == .requestConnection else { return nil }
        let stablePeerKey = contact.remoteUserId ?? Contact.normalizedHandle(contact.handle)
        let channelKey = contact.backendChannelId ?? "no-channel"
        let deviceKey = backendServices?.deviceID ?? backendConfig?.deviceID ?? "no-device"
        return [
            "connect",
            deviceKey,
            contact.id.uuidString.lowercased(),
            stablePeerKey,
            channelKey,
            UUID().uuidString.lowercased(),
        ].joined(separator: ":")
    }

    func backendChannelJoinOperationID(for contact: Contact, intent: BackendJoinIntent) -> String? {
        let channelKey = contact.backendChannelId ?? "no-channel"
        let deviceKey = backendServices?.deviceID ?? backendConfig?.deviceID ?? "no-device"
        return [
            "join",
            deviceKey,
            contact.id.uuidString.lowercased(),
            channelKey,
            String(describing: intent),
            UUID().uuidString.lowercased(),
        ].joined(separator: ":")
    }

    func prepareBackendJoinControlPlaneIfNeeded(
        _ backend: BackendServices,
        request: BackendJoinRequest
    ) async throws {
        guard backend.supportsWebSocket else { return }
        guard !backend.isWebSocketConnected else { return }

        diagnostics.record(
            .backend,
            message: "Waiting for backend WebSocket before join",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
            ]
        )
        do {
            try await backend.waitForWebSocketConnection()
        } catch {
            guard shouldProceedWithBackendJoinWithoutWebSocket(error) else {
                throw error
            }
            diagnostics.record(
                .backend,
                message: "Proceeding with backend join while WebSocket remains unavailable",
                metadata: [
                    "contactId": request.contactID.uuidString,
                    "handle": request.handle,
                ]
            )
        }
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
            try await prepareBackendJoinControlPlaneIfNeeded(backend, request: request)
            try await performBackendJoinCommand(
                channelId: backendChannelId,
                request: request,
                backend: backend
            )
            return contact
        } catch {
            guard shouldTreatBackendJoinChannelNotFoundAsRecoverable(error) else {
                if await waitForBackendJoinMembershipVisibility(
                    channelId: backendChannelId,
                    contactID: contact.id,
                    request: request,
                    backend: backend,
                    attempts: 4,
                    intervalNanoseconds: 250_000_000
                ) {
                    diagnostics.record(
                        .backend,
                        message: "Backend join command failed after membership became visible",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "channelId": backendChannelId,
                            "error": error.localizedDescription,
                        ]
                    )
                    return contact
                }
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
            try await prepareBackendJoinControlPlaneIfNeeded(backend, request: request)
            try await performBackendJoinCommand(
                channelId: refreshedChannelId,
                request: request,
                backend: backend,
                operationId: backendChannelJoinOperationID(for: refreshedContact, intent: request.intent) ?? request.joinOperationID
            )
            return refreshedContact
        }
    }

    private func performBackendJoinCommand(
        channelId: String,
        request: BackendJoinRequest,
        backend: BackendServices,
        operationId: String? = nil
    ) async throws {
        let joinOperationID = operationId ?? request.joinOperationID
        try await withThrowingTaskGroup(of: BackendJoinCommandOutcome.self) { group in
            group.addTask { @MainActor in
                _ = try await backend.joinChannel(
                    channelId: channelId,
                    operationId: joinOperationID
                )
                return .commandReturned
            }
            group.addTask { @MainActor in
                await self.waitForBackendJoinMembershipVisibility(
                    channelId: channelId,
                    contactID: request.contactID,
                    request: request,
                    backend: backend,
                    attempts: 16,
                    intervalNanoseconds: 250_000_000
                ) ? .membershipVisible : .visibilityTimedOut
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return .commandTimedOut
            }

            while let outcome = try await group.next() {
                switch outcome {
                case .commandReturned:
                    group.cancelAll()
                    return
                case .membershipVisible:
                    group.cancelAll()
                    diagnostics.record(
                        .backend,
                        message: "Backend join membership became visible before command response",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "channelId": channelId,
                        ]
                    )
                    return
                case .visibilityTimedOut:
                    continue
                case .commandTimedOut:
                    group.cancelAll()
                    throw TurboBackendError.server("backend join command timed out")
                }
            }
        }
    }

    private func refreshBackendJoinVisibility(for contactID: UUID) async {
        await refreshChannelState(for: contactID)
        await refreshContactSummaries()
        await refreshInvites()
        updateStatusForSelectedContact()
    }

    func applyAcceptedBackendJoinProjection(for contact: Contact, backend: BackendServices) {
        guard let backendChannelId = contact.backendChannelId else { return }

        let existing = backendSyncCoordinator.state.syncState.channelStates[contact.id]
        let peerMembership = existing?.membership
        let peerJoined = peerMembership?.hasPeerMembership ?? false
        let peerDeviceConnected = peerMembership?.peerDeviceConnected ?? false
        let membership: TurboChannelMembership = peerJoined
            ? .both(peerDeviceConnected: peerDeviceConnected)
            : .selfOnly
        let preservesLiveStatus =
            existing?.conversationStatus == .ready
            || existing?.conversationStatus == .transmitting
            || existing?.conversationStatus == .receiving
        let projectedState: TurboChannelStateResponse = {
            if let existing {
                if preservesLiveStatus {
                    return existing.settingMembership(membership)
                }
                return TurboChannelStateResponse(
                    channelId: existing.channelId,
                    selfUserId: existing.selfUserId,
                    peerUserId: existing.peerUserId,
                    peerHandle: existing.peerHandle,
                    selfOnline: existing.selfOnline,
                    peerOnline: existing.peerOnline,
                    selfJoined: true,
                    peerJoined: peerJoined,
                    peerDeviceConnected: peerDeviceConnected,
                    hasIncomingRequest: existing.hasIncomingRequest,
                    hasOutgoingRequest: existing.hasOutgoingRequest,
                    requestCount: existing.requestCount,
                    activeTransmitterUserId: existing.activeTransmitterUserId,
                    activeTransmitId: existing.activeTransmitId,
                    transmitLeaseExpiresAt: existing.transmitLeaseExpiresAt,
                    stateEpoch: existing.stateEpoch,
                    serverTimestamp: existing.serverTimestamp,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                )
            }
            return TurboChannelStateResponse(
                channelId: backendChannelId,
                selfUserId: backend.currentUserID ?? "",
                peerUserId: contact.remoteUserId ?? "",
                peerHandle: contact.handle,
                selfOnline: true,
                peerOnline: contact.isOnline,
                selfJoined: true,
                peerJoined: false,
                peerDeviceConnected: false,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                activeTransmitterUserId: nil,
                activeTransmitId: nil,
                transmitLeaseExpiresAt: nil,
                stateEpoch: nil,
                serverTimestamp: nil,
                status: ConversationState.waitingForPeer.rawValue,
                canTransmit: false
            )
        }()

        backendSyncCoordinator.send(
            .channelStateUpdated(contactID: contact.id, channelState: projectedState)
        )
        diagnostics.record(
            .backend,
            message: "Applied accepted backend join projection",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "channelId": backendChannelId,
                "membership": String(describing: projectedState.membership),
                "status": projectedState.status,
            ]
        )
        updateStatusForSelectedContact()
        captureDiagnosticsState("backend-join:accepted-projection")
    }

    private func waitForBackendJoinMembershipVisibility(
        channelId: String,
        contactID: UUID,
        request: BackendJoinRequest,
        backend: BackendServices,
        attempts: Int,
        intervalNanoseconds: UInt64
    ) async -> Bool {
        guard attempts > 0 else { return false }

        for attempt in 1 ... attempts {
            if Task.isCancelled {
                return false
            }

            do {
                let channelState = try await backend.channelState(channelId: channelId)
                backendSyncCoordinator.send(.channelStateUpdated(contactID: contactID, channelState: channelState))
                if channelState.membership.hasLocalMembership {
                    if attempt > 1 {
                        diagnostics.record(
                            .backend,
                            message: "Backend join visibility converged before command response",
                            metadata: [
                                "contactId": request.contactID.uuidString,
                                "handle": request.handle,
                                "channelId": channelId,
                                "attempt": "\(attempt)",
                                "status": channelState.status,
                            ]
                        )
                    }
                    return true
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .notice,
                    message: "Backend join visibility check failed while command was pending",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "channelId": channelId,
                        "attempt": "\(attempt)",
                        "error": error.localizedDescription,
                    ]
                )
            }

            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }

        return false
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
                applyAcceptedBackendJoinProjection(for: contact, backend: backend)
            }
            if request.usesLocalHTTPBackend {
                completeLocalBackendJoin(for: contact)
            } else {
                backendRuntime.markBackendJoinSettling(for: contact.id)
                joinPTTChannel(for: contact)
                if sessionCoordinator.pendingJoinContactID != contact.id {
                    backendRuntime.clearBackendJoinSettling(for: contact.id)
                }
            }
        }

        backendCommandCoordinator.send(.operationFinished)
        Task { @MainActor [weak self, contactID = contact.id] in
            await self?.refreshBackendJoinVisibility(for: contactID)
        }
    }

    private func performBackendJoin(_ request: BackendJoinRequest) async {
        do {
            do {
                try await executeBackendJoin(request)
            } catch {
                if shouldTreatBackendJoinDisconnectedSessionAsRecoverable(error),
                   let backend = backendServices,
                   backend.supportsWebSocket {
                    diagnostics.record(
                        .backend,
                        message: "Recovering backend join after disconnected session drift",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                        ]
                    )
                    await reconnectBackendControlPlane()
                    try await executeBackendJoin(request)
                } else {
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
            }
        } catch {
            let message = error.localizedDescription
            let failedActiveJoin =
                sessionCoordinator.pendingAction.pendingConnectContactID == request.contactID
                || sessionCoordinator.pendingAction.pendingJoinContactID == request.contactID
            backendCommandCoordinator.send(.operationFailed(message))
            sessionCoordinator.clearPendingConnect(for: request.contactID)
            if failedActiveJoin {
                backendSyncCoordinator.send(.channelStateCleared(contactID: request.contactID))
            }
            statusMessage = "Join failed: \(message)"
            captureDiagnosticsState("backend-join:failed")
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
            _ = try await backend.leaveChannel(
                channelId: request.backendChannelID,
                operationId: request.operationID
            )
            await refreshChannelState(for: request.contactID)
            await refreshContactSummaries()
            await refreshInvites()
            backendCommandCoordinator.send(.operationFinished)
        } catch {
            let message = error.localizedDescription
            await refreshChannelState(for: request.contactID)
            let leaveAlreadyApplied =
                selectedChannelSnapshot(for: request.contactID)?.membership.hasLocalMembership == false

            if leaveAlreadyApplied {
                await refreshContactSummaries()
                await refreshInvites()
                backendCommandCoordinator.send(.operationFinished)
                diagnostics.record(
                    .backend,
                    message: "Backend leave request failed after membership was already absent",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "channelId": request.backendChannelID,
                        "error": message,
                    ]
                )
                return
            }

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
