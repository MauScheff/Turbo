//
//  PTTViewModel+Selection.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation

enum ContactPresencePresentation: Equatable {
    case connected
    case reachable
    case offline
}

extension PTTViewModel {
    func localTransmitProjection(for contactID: UUID) -> LocalTransmitProjection {
        transmitDomainSnapshot.localTransmitProjection(
            for: contactID,
            mediaState: mediaConnectionState,
            pttAudioSessionActive: isPTTAudioSessionActive
        )
    }

    var contactSummaryByContactID: [UUID: TurboContactSummaryResponse] {
        backendSyncCoordinator.state.syncState.contactSummaries
    }

    var channelStateByContactID: [UUID: TurboChannelStateResponse] {
        backendSyncCoordinator.state.syncState.channelStates
    }

    var channelReadinessByContactID: [UUID: TurboChannelReadinessResponse] {
        backendSyncCoordinator.state.syncState.channelReadiness
    }

    var incomingInviteByContactID: [UUID: TurboInviteResponse] {
        backendSyncCoordinator.state.syncState.incomingInvites
    }

    var outgoingInviteByContactID: [UUID: TurboInviteResponse] {
        backendSyncCoordinator.state.syncState.outgoingInvites
    }

    var requestCooldownDeadlineByContactID: [UUID: Date] {
        backendSyncCoordinator.state.syncState.requestCooldownDeadlines
    }

    var requestContactIDs: Set<UUID> {
        backendSyncCoordinator.state.syncState.requestContactIDs
    }

    func systemSessionMatches(_ contactID: UUID) -> Bool {
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return false }
        switch systemSessionState {
        case .active(let activeContactID, let channelUUID):
            return activeContactID == contactID && contact.channelId == channelUUID
        case .none, .mismatched:
            return false
        }
    }

    func conversationContext(for contact: Contact) -> ConversationDerivationContext {
        return ConversationDerivationContext(
            contactID: contact.id,
            selectedContactID: selectedContactId,
            baseState: selectedContactId == contact.id
                ? selectedPeerBaseState(for: contact.id, relationship: relationshipState(for: contact.id))
                : listConversationState(for: contact.id),
            contactName: contact.name,
            contactIsOnline: selectedConversationPresenceIsOnline(for: contact.id),
            contactPresence: contactPresencePresentation(for: contact.id),
            isJoined: isJoined,
            localTransmit: localTransmitProjection(for: contact.id),
            peerSignalIsTransmitting: remoteTransmittingContactIDs.contains(contact.id),
            activeChannelID: activeChannelId,
            systemSessionMatchesContact: systemSessionMatches(contact.id),
            systemSessionState: systemSessionState,
            pendingAction: sessionCoordinator.pendingAction,
            localJoinFailure: pttCoordinator.state.lastJoinFailure,
            mediaState: mediaConnectionState,
            localMediaWarmupState: localMediaWarmupState(for: contact.id),
            incomingWakeActivationState: pttWakeRuntime.incomingWakeActivationState(for: contact.id),
            hadConnectedSessionContinuity: selectedContactId == contact.id
                ? selectedPeerCoordinator.state.hadConnectedSessionContinuity
                : false,
            channel: selectedChannelSnapshot(for: contact.id)
        )
    }

    func relationshipState(for contactID: UUID) -> PairRelationshipState {
        let incomingInviteCount = incomingInviteByContactID[contactID]?.requestCount
        let outgoingInviteCount = outgoingInviteByContactID[contactID]?.requestCount
        let summary = contactSummaryByContactID[contactID]
        let summaryRelationship = summary?.requestRelationship ?? .none

        let hasIncomingRequest = incomingInviteCount != nil || summaryRelationship.hasIncomingRequest
        let hasOutgoingRequest = outgoingInviteCount != nil || summaryRelationship.hasOutgoingRequest
        let requestCount =
            [
                incomingInviteCount,
                outgoingInviteCount,
                summaryRelationship.requestCount,
            ]
            .compactMap { $0 }
            .max() ?? 0

        return ConversationStateMachine.relationshipState(
            hasIncomingRequest: hasIncomingRequest,
            hasOutgoingRequest: hasOutgoingRequest,
            requestCount: requestCount
        )
    }

    func selectedPeerBaseState(for contactID: UUID, relationship: PairRelationshipState) -> ConversationState {
        if let state = selectedChannelState(for: contactID)?.conversationStatus {
            return state
        }
        return relationship.fallbackConversationState
    }

    func syncSelectedPeerSession() {
        guard let contact = selectedContact else {
            selectedPeerCoordinator.send(.selectedContactChanged(nil))
            return
        }
        let localTransmit = localTransmitProjection(for: contact.id)

        let relationship = relationshipState(for: contact.id)
        selectedPeerCoordinator.send(
            .selectedContactChanged(
                SelectedPeerSelection(
                    contactID: contact.id,
                    contactName: contact.name,
                    contactIsOnline: selectedConversationPresenceIsOnline(for: contact.id),
                    contactPresence: contactPresencePresentation(for: contact.id)
                )
            )
        )
        selectedPeerCoordinator.send(.relationshipUpdated(relationship))
        selectedPeerCoordinator.send(.baseStateUpdated(selectedPeerBaseState(for: contact.id, relationship: relationship)))
        selectedPeerCoordinator.send(.channelUpdated(selectedChannelSnapshot(for: contact.id)))
        selectedPeerCoordinator.send(
            .localSessionUpdated(
                isJoined: isJoined,
                activeChannelID: activeChannelId,
                pendingAction: sessionCoordinator.pendingAction,
                localJoinFailure: pttCoordinator.state.lastJoinFailure
            )
        )
        selectedPeerCoordinator.send(.localTransmitUpdated(localTransmit))
        selectedPeerCoordinator.send(
            .peerSignalTransmittingUpdated(remoteTransmittingContactIDs.contains(contact.id))
        )
        selectedPeerCoordinator.send(
            .systemSessionUpdated(
                systemSessionState,
                matchesSelectedContact: systemSessionMatches(contact.id)
            )
        )
        selectedPeerCoordinator.send(.mediaStateUpdated(mediaConnectionState))
        selectedPeerCoordinator.send(
            .incomingWakeActivationStateUpdated(
                pttWakeRuntime.incomingWakeActivationState(for: contact.id)
            )
        )
    }

    func selectedPeerState(for contactID: UUID) -> SelectedPeerState {
        selectedPeerProjection(for: contactID).selectedPeerState
    }

    func selectedPeerProjection(for contactID: UUID) -> SelectedPeerProjection {
        if selectedContactId == contactID {
            syncSelectedPeerSession()
            let state = selectedPeerCoordinator.state
            return SelectedPeerProjection(
                durableSession: state.durableSessionProjection,
                connectedExecution: state.connectedExecutionProjection,
                connectedControlPlane: state.connectedControlPlaneProjection,
                selectedPeerState: state.selectedPeerState,
                reconciliationAction: state.reconciliationAction
            )
        }

        guard let contact = contacts.first(where: { $0.id == contactID }) else {
            let selectedPeerState = SelectedPeerState(
                relationship: .none,
                phase: .idle,
                statusMessage: "Ready to connect",
                canTransmitNow: false
            )
            return SelectedPeerProjection(
                durableSession: .inactive,
                connectedExecution: nil,
                connectedControlPlane: .unavailable,
                selectedPeerState: selectedPeerState,
                reconciliationAction: .none
            )
        }
        return ConversationStateMachine.projection(
            for: conversationContext(for: contact),
            relationship: relationshipState(for: contactID)
        )
    }

    // List decoration only. Selected-screen truth must come from selectedPeerState.
    func listConversationState(for contactID: UUID) -> ConversationState {
        if selectedContactId == contactID,
           let status = channelStateByContactID[contactID]?.status,
           let state = ConversationState(rawValue: status) {
            return state
        }
        if let summary = contactSummaryByContactID[contactID] {
            return ConversationStateMachine.listConversationState(for: summary)
        }
        return .idle
    }

    func incomingInvite(for contactID: UUID) -> TurboInviteResponse? {
        incomingInviteByContactID[contactID]
    }

    func outgoingInvite(for contactID: UUID) -> TurboInviteResponse? {
        outgoingInviteByContactID[contactID]
    }

    func contactSummary(for contactID: UUID) -> TurboContactSummaryResponse? {
        contactSummaryByContactID[contactID]
    }

    func contactName(for contactID: UUID) -> String? {
        contacts.first(where: { $0.id == contactID })?.name
    }

    func requestCooldownRemaining(for contactID: UUID, now: Date = .now) -> Int? {
        guard let deadline = requestCooldownDeadlineByContactID[contactID] else { return nil }
        let remaining = Int(ceil(deadline.timeIntervalSince(now)))
        guard remaining > 0 else { return nil }
        return remaining
    }

    func contactPresencePresentation(for contactID: UUID) -> ContactPresencePresentation {
        let rawPresenceOnline = contactSummaryByContactID[contactID]?.isOnline
            ?? contacts.first(where: { $0.id == contactID })?.isOnline
            ?? false

        if let channelSnapshot = selectedChannelSnapshot(for: contactID) {
            if case .absent = channelSnapshot.membership {
                return rawPresenceOnline ? .connected : .offline
            }
            return channelSnapshot.membership.peerDeviceConnected ? .connected : (rawPresenceOnline ? .reachable : .offline)
        }

        if let summary = contactSummaryByContactID[contactID] {
            switch summary.badge {
            case .online:
                return .connected
            case .offline:
                return .offline
            case .idle, .unknown:
                break
            default:
                return rawPresenceOnline ? .reachable : .offline
            }

            if summary.channelId != nil {
                return summary.membership.peerDeviceConnected ? .connected : (rawPresenceOnline ? .reachable : .offline)
            }
        }

        return rawPresenceOnline ? .connected : .offline
    }

    func selectedConversationPresenceIsOnline(for contactID: UUID) -> Bool {
        contactPresencePresentation(for: contactID) == .connected
    }

    var visibleContacts: [Contact] {
        contacts.filter { contact in
            contact.handle != currentDevUserHandle
                && !requestContactIDs.contains(contact.id)
                && !(activeChannelId == contact.id)
                && !(selectedContactId == contact.id)
        }
    }

    var sortedContacts: [Contact] {
        visibleContacts.sorted { lhs, rhs in
            let lhsPresence = contactPresencePresentation(for: lhs.id)
            let rhsPresence = contactPresencePresentation(for: rhs.id)
            if lhsPresence != rhsPresence {
                return presenceSortRank(lhsPresence) < presenceSortRank(rhsPresence)
            }
            return lhs.name < rhs.name
        }
    }

    private func presenceSortRank(_ presence: ContactPresencePresentation) -> Int {
        switch presence {
        case .connected:
            return 0
        case .reachable:
            return 1
        case .offline:
            return 2
        }
    }

    var incomingRequests: [(Contact, TurboInviteResponse)] {
        contacts.compactMap { contact in
            guard contact.handle != currentDevUserHandle else { return nil }
            guard contact.id != selectedContactId else { return nil }
            guard contactSummaryByContactID[contact.id]?.requestRelationship.hasIncomingRequest == true,
                  let invite = incomingInviteByContactID[contact.id] else { return nil }
            return (contact, invite)
        }
    }

    var outgoingRequests: [(Contact, TurboInviteResponse)] {
        contacts.compactMap { contact in
            guard contact.handle != currentDevUserHandle else { return nil }
            guard contact.id != selectedContactId else { return nil }
            guard contactSummaryByContactID[contact.id]?.requestRelationship.hasOutgoingRequest == true,
                  let invite = outgoingInviteByContactID[contact.id] else { return nil }
            return (contact, invite)
        }
    }

    func ensureContactExists(handle: String, remoteUserId: String, channelId: String) -> UUID {
        let result = ContactDirectory.ensureContact(
            handle: handle,
            remoteUserId: remoteUserId,
            channelId: channelId,
            existingContacts: contacts
        )
        contacts = result.contacts
        return result.contactID
    }

    func selectedChannelState(for contactID: UUID) -> TurboChannelStateResponse? {
        guard let channelState = channelStateByContactID[contactID] else { return nil }

        let localSessionAligned =
            systemSessionMatches(contactID)
            || (isJoined && activeChannelId == contactID)

        if localSessionAligned {
            return channelState
        }

        guard let summary = contactSummaryByContactID[contactID],
              let summaryChannelID = summary.channelId,
              !summaryChannelID.isEmpty,
              summaryChannelID == channelState.channelId else {
            return nil
        }

        return channelState
    }

    func selectedChannelSnapshot(for contactID: UUID) -> ChannelReadinessSnapshot? {
        selectedChannelState(for: contactID).map { channelState in
            ChannelReadinessSnapshot(
                channelState: channelState,
                readiness: channelReadinessByContactID[contactID]
            )
        }
    }

    func selectContact(_ contact: Contact) {
        trackContact(contact.id)
        markTalkRequestSurfaceOpened(
            for: contact.id,
            inviteID: incomingInviteByContactID[contact.id]?.inviteId
        )
        selectedContactId = contact.id
        sessionCoordinator.select(contactID: contact.id)
        diagnostics.record(.state, message: "Selected contact", metadata: ["handle": contact.handle])
        updateStatusForSelectedContact()
        captureDiagnosticsState("selected-contact")
        Task {
            await prewarmLocalMediaIfNeeded(for: contact.id)
        }
    }

    func resetSelection() {
        selectedContactId = nil
        captureDiagnosticsState("selection-reset")
    }

    func updateStatusForSelectedContact() {
        if selectedContact != nil {
            syncSelectedPeerSession()
            statusMessage = selectedPeerCoordinator.state.selectedPeerState.statusMessage
        } else {
            statusMessage = ConversationStateMachine.statusMessage(
                for: ConversationDerivationContext(
                    contactID: UUID(),
                    selectedContactID: nil,
                    baseState: .idle,
                    contactName: "",
                    contactIsOnline: false,
                    isJoined: isJoined,
                    activeChannelID: activeChannelId,
                    systemSessionMatchesContact: false,
                    systemSessionState: systemSessionState,
                    pendingAction: sessionCoordinator.pendingAction,
                    localJoinFailure: pttCoordinator.state.lastJoinFailure,
                    localMediaWarmupState: .cold,
                    channel: nil
                )
            )
        }
        captureDiagnosticsState("selected-status-refresh")
    }

    func localMediaWarmupState(for contactID: UUID) -> LocalMediaWarmupState {
        guard mediaSessionContactID == contactID else { return .cold }
        switch mediaConnectionState {
        case .idle, .closed:
            return .cold
        case .preparing:
            return .prewarming
        case .connected:
            return .ready
        case .failed:
            return .failed
        }
    }

    func updateContact(_ id: UUID, mutate: (inout Contact) -> Void) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        var contact = contacts[index]
        mutate(&contact)
        contacts[index] = contact
    }

    var authoritativeContactIDs: Set<UUID> {
        ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: trackedContactIDs,
            selectedContactID: selectedContactId,
            activeChannelID: activeChannelId,
            mediaSessionContactID: mediaSessionContactID,
            pendingJoinContactID: pendingJoinContactId,
            inviteContactIDs: requestContactIDs
        )
    }

    func pruneContactsToAuthoritativeState() {
        contacts = ContactDirectory.retainedContacts(
            existingContacts: contacts,
            authoritativeContactIDs: authoritativeContactIDs
        )
    }
}
