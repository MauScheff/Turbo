//
//  PTTViewModel+Selection.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import UIKit

private enum AbsentBackendMembershipRecovery {
    static let invariantID = "selected.backend_absent_pending_local_action_without_session"
}

private enum AbsentBackendMembershipRepairAction: String {
    case stalePendingJoin = "stale-pending-join"
    case completedPendingLeave = "completed-pending-leave"
    case stalePendingJoinDuringOutgoingRequest = "stale-pending-join-during-outgoing-request"

    var message: String {
        switch self {
        case .stalePendingJoinDuringOutgoingRequest:
            return "Recovered stale local join during outgoing request"
        case .stalePendingJoin, .completedPendingLeave:
            return "Recovered local session state after backend membership became absent"
        }
    }
}

private enum AbsentBackendMembershipSuppressionReason: String {
    case backendJoinSettling = "backend-join-settling"
    case unresolvedLocalJoinAttempt = "unresolved-local-join-attempt"

    var message: String {
        switch self {
        case .backendJoinSettling:
            return "Deferred absent backend membership recovery while backend join is settling"
        case .unresolvedLocalJoinAttempt:
            return "Deferred absent backend membership recovery while local join is unresolved"
        }
    }
}

private enum AbsentBackendMembershipRecoveryDecision {
    case repair(AbsentBackendMembershipRepairAction)
    case suppressed(AbsentBackendMembershipSuppressionReason)
}

enum ContactPresencePresentation: Equatable {
    case connected
    case reachable
    case offline
}

struct ContactListItem: Identifiable, Equatable {
    let contact: Contact
    let presentation: ContactListPresentation

    var id: UUID { contact.id }
}

struct ContactListSections: Equatable {
    let wantsToTalk: [ContactListItem]
    let readyToTalk: [ContactListItem]
    let requested: [ContactListItem]
    let contacts: [ContactListItem]
}

extension PTTViewModel {
    func localTransmitProjection(for contactID: UUID) -> LocalTransmitProjection {
        let snapshot = transmitDomainSnapshot
        let projection = snapshot.localTransmitProjection(
            for: contactID,
            mediaState: mediaConnectionState,
            pttAudioSessionActive: isPTTAudioSessionActive
        )
        if shouldProjectWarmDirectQuicTransmitAsLive(
            projection: projection,
            snapshot: snapshot,
            contactID: contactID
        ) {
            return .transmitting
        }
        return projection
    }

    private func shouldProjectWarmDirectQuicTransmitAsLive(
        projection: LocalTransmitProjection,
        snapshot: TransmitDomainSnapshot,
        contactID: UUID
    ) -> Bool {
        guard case .starting(let stage) = projection else { return false }
        switch stage {
        case .awaitingSystemTransmit, .awaitingAudioSession:
            break
        case .requestingLease, .awaitingAudioConnection:
            return false
        }
        guard snapshot.hasTransmitIntent(for: contactID),
              shouldUseDirectQuicTransport(for: contactID),
              mediaConnectionState == .connected,
              transmitStartupTiming.contactID == contactID,
              (
                transmitStartupTiming.elapsedMilliseconds(for: "backend-lease-granted") != nil
                || transmitStartupTiming.elapsedMilliseconds(for: "backend-lease-bypassed-direct-quic") != nil
              ),
              transmitStartupTiming.elapsedMilliseconds(for: "early-audio-capture-start-completed") != nil
        else {
            return false
        }
        return true
    }

    func localRelayTransportReadyForTransmit(for contactID: UUID) -> Bool {
        guard !shouldUseDirectQuicTransport(for: contactID) else { return true }
        guard let backend = backendServices else { return usesLocalHTTPBackend }
        guard backend.supportsWebSocket else { return true }
        if backend.isWebSocketConnected {
            return true
        }
        return shouldUseLiveCallControlPlaneReconnectGrace(for: contactID)
    }

    func shouldUseLiveCallControlPlaneReconnectGrace(
        for contactID: UUID,
        now: Date = Date()
    ) -> Bool {
        guard let startedAt = liveCallControlPlaneReconnectGraceStartedAt else {
            return false
        }
        guard now.timeIntervalSince(startedAt) <= liveCallControlPlaneReconnectGraceSeconds else {
            return false
        }
        guard selectedContactId == contactID,
              isJoined,
              activeChannelId == contactID,
              selectedPeerCoordinator.state.hadConnectedSessionContinuity,
              selectedSessionSystemSessionMatches(contactID) else {
            return false
        }
        return true
    }

    func selectedSessionSystemSessionMatches(_ contactID: UUID) -> Bool {
        if systemSessionMatches(contactID) {
            return true
        }

        let state = selectedPeerCoordinator.state
        return state.selection?.contactID == contactID
            && state.systemSessionMatchesContact
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
        backendSyncCoordinator.state.syncState.visibleIncomingInvitesByContactID()
    }

    var rawIncomingInviteByContactID: [UUID: TurboInviteResponse] {
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
        case .mismatched(let channelUUID):
            return contact.channelId == channelUUID
        case .none:
            return false
        }
    }

    func localSessionEvidenceExists(for contactID: UUID, expectedChannelUUID: UUID? = nil) -> Bool {
        let expectedChannelUUID = expectedChannelUUID ?? channelUUID(for: contactID)
        return systemSessionMatches(contactID)
            || (isJoined && activeChannelId == contactID)
            || (
                expectedChannelUUID != nil
                && pttCoordinator.state.systemChannelUUID == expectedChannelUUID
            )
    }

    func unresolvedLocalJoinAttemptExists(for contactID: UUID) -> Bool {
        guard let attempt = sessionCoordinator.localJoinAttempt,
              attempt.contactID == contactID else {
            return false
        }
        guard attempt.issuedCount < maxUnresolvedLocalJoinAttempts else {
            return false
        }
        return !localSessionEvidenceExists(
            for: contactID,
            expectedChannelUUID: attempt.channelUUID
        )
    }

    func backendJoinIsSettling(for contactID: UUID) -> Bool {
        if backendRuntime.isBackendJoinSettling(for: contactID) {
            return true
        }
        if let optimisticOutgoingRequest = optimisticOutgoingRequestEvidenceByContactID[contactID],
           optimisticOutgoingRequest.isActive(),
           optimisticOutgoingRequest.phase == .joinTransition,
           relationshipState(for: contactID).isOutgoingRequest,
           !localSessionEvidenceExists(for: contactID) {
            return true
        }
        if sessionCoordinator.pendingJoinContactID == contactID {
            return false
        }
        guard case .join(let request) = backendCommandCoordinator.state.activeOperation else {
            return false
        }
        guard request.contactID == contactID else { return false }
        switch request.intent {
        case .joinAcceptedOutgoingRequest, .joinReadyPeer:
            return true
        case .requestConnection:
            return request.relationship.isIncomingRequest
        }
    }

    func shouldPreservePendingLocalJoinDuringBackendJoinSettling(for contactID: UUID) -> Bool {
        sessionCoordinator.pendingJoinContactID == contactID
            && (
                backendJoinIsSettling(for: contactID)
                || unresolvedLocalJoinAttemptExists(for: contactID)
            )
    }

    func conversationContext(for contact: Contact) -> ConversationDerivationContext {
        return ConversationDerivationContext(
            contactID: contact.id,
            selectedContactID: selectedContactId,
            baseState: selectedContactId == contact.id
                ? selectedPeerBaseState(for: contact.id, relationship: relationshipState(for: contact.id))
                : listConversationState(for: contact.id),
            relationship: relationshipState(for: contact.id),
            contactName: contact.name,
            contactIsOnline: selectedConversationPresenceIsOnline(for: contact.id),
            contactPresence: contactPresencePresentation(for: contact.id),
            isJoined: isJoined,
            localTransmit: localTransmitProjection(for: contact.id),
            peerSignalIsTransmitting: remoteReceiveProjectsPeerTalking(for: contact.id),
            activeChannelID: activeChannelId,
            systemSessionMatchesContact: systemSessionMatches(contact.id),
            systemSessionState: systemSessionState,
            pendingAction: sessionCoordinator.pendingAction,
            pendingConnectAcceptedIncomingRequest:
                sessionCoordinator.pendingConnectAcceptedIncomingRequestContactID == contact.id,
            localJoinFailure: pttCoordinator.state.lastJoinFailure,
            mediaState: mediaConnectionState,
            localMediaWarmupState: localMediaWarmupState(for: contact.id),
            localRelayTransportReady: localRelayTransportReadyForTransmit(for: contact.id),
            directMediaPathActive: shouldUseDirectQuicTransport(for: contact.id),
            firstTalkStartupProfile: firstTalkStartupProfile(for: contact.id, startGraceIfNeeded: false),
            incomingWakeActivationState: pttWakeRuntime.incomingWakeActivationState(for: contact.id),
            backendJoinSettling: backendJoinIsSettling(for: contact.id),
            controlPlaneReconnectGraceActive: shouldUseLiveCallControlPlaneReconnectGrace(for: contact.id),
            hadConnectedSessionContinuity: selectedContactId == contact.id
                ? selectedPeerCoordinator.state.hadConnectedSessionContinuity
                : false,
            channel: selectedChannelSnapshot(for: contact.id)
        )
    }

    func relationshipState(for contactID: UUID) -> PairRelationshipState {
        let incomingInviteCount = incomingInviteByContactID[contactID]?.requestCount
        let outgoingInviteCount = outgoingInviteByContactID[contactID]?.requestCount
        let optimisticOutgoingRequestCount = optimisticOutgoingRequestCount(for: contactID)
        let summary = contactSummaryByContactID[contactID]
        let summaryRelationship =
            backendSyncCoordinator.state.syncState.summaryIncomingRequestIsHandled(for: contactID)
                ? summary?.requestRelationship.removingIncomingRequest ?? .none
                : summary?.requestRelationship ?? .none

        let hasIncomingRequest = incomingInviteCount != nil || summaryRelationship.hasIncomingRequest
        let hasOutgoingRequest =
            outgoingInviteCount != nil
            || summaryRelationship.hasOutgoingRequest
            || optimisticOutgoingRequestCount != nil
        let requestCount =
            [
                incomingInviteCount,
                outgoingInviteCount,
                optimisticOutgoingRequestCount,
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

    func optimisticOutgoingRequestCount(for contactID: UUID, now: Date = Date()) -> Int? {
        guard let evidence = optimisticOutgoingRequestEvidenceByContactID[contactID],
              evidence.isActive(now: now) else {
            return nil
        }
        return max(evidence.requestCount, 1)
    }

    func markOptimisticOutgoingRequestStarted(
        contactID: UUID,
        relationship: PairRelationshipState,
        operationID: String?,
        now: Date = Date()
    ) {
        guard !relationship.isIncomingRequest else { return }
        let requestCount = max((relationship.requestCount ?? 0) + 1, 1)
        optimisticOutgoingRequestEvidenceByContactID[contactID] =
            OptimisticOutgoingRequestEvidence(
                requestCount: requestCount,
                startedAt: now,
                cooldownDeadline: now.addingTimeInterval(30),
                operationID: operationID,
                phase: .cooldownOnly
            )
        diagnostics.record(
            .state,
            message: "Projected outgoing ask optimistically",
            metadata: [
                "contactId": contactID.uuidString,
                "requestCount": "\(requestCount)",
                "operationId": operationID ?? "none",
            ]
        )
        updateStatusForSelectedContact()
    }

    func promoteOptimisticOutgoingRequestToJoinTransition(
        contactID: UUID,
        now: Date = Date()
    ) {
        guard let evidence = optimisticOutgoingRequestEvidenceByContactID[contactID],
              evidence.isActive(now: now) else {
            return
        }
        guard evidence.phase != .joinTransition else { return }
        optimisticOutgoingRequestEvidenceByContactID[contactID] = OptimisticOutgoingRequestEvidence(
            requestCount: evidence.requestCount,
            startedAt: evidence.startedAt,
            cooldownDeadline: max(evidence.cooldownDeadline, now.addingTimeInterval(30)),
            operationID: evidence.operationID,
            phase: .joinTransition
        )
        diagnostics.record(
            .state,
            message: "Promoted optimistic outgoing ask to join transition",
            metadata: [
                "contactId": contactID.uuidString,
                "requestCount": "\(evidence.requestCount)",
                "operationId": evidence.operationID ?? "none",
            ]
        )
        updateStatusForSelectedContact()
    }

    func clearOptimisticOutgoingRequest(
        contactID: UUID,
        reason: String,
        refreshSelection: Bool = true
    ) {
        guard optimisticOutgoingRequestEvidenceByContactID.removeValue(forKey: contactID) != nil else {
            return
        }
        diagnostics.record(
            .state,
            message: "Cleared optimistic outgoing ask projection",
            metadata: ["contactId": contactID.uuidString, "reason": reason]
        )
        if refreshSelection {
            updateStatusForSelectedContact()
        }
    }

    func selectedPeerBaseState(for contactID: UUID, relationship: PairRelationshipState) -> ConversationState {
        if let state = selectedChannelState(for: contactID)?.conversationStatus {
            if state == .incomingRequest,
               backendSyncCoordinator.state.syncState.summaryIncomingRequestIsHandled(for: contactID) {
                return relationship.fallbackConversationState
            }
            return state
        }
        return relationship.fallbackConversationState
    }

    func syncSelectedPeerSession() {
        guard let contact = selectedContact else {
            selectedPeerCoordinator.send(.selectedContactChanged(nil))
            return
        }
        completeReconciledTeardownIfSystemSessionEnded(for: contact.id)
        completeAbsentBackendMembershipRecoveryIfLocalSessionEnded(for: contact.id)
        let localTransmit = localTransmitProjection(for: contact.id)

        let relationship = relationshipState(for: contact.id)
        recordRecentOutgoingRequestEvidenceIfNeeded(
            contactID: contact.id,
            relationship: relationship
        )
        selectedPeerCoordinator.send(
            .syncUpdated(
                SelectedPeerSyncSnapshot(
                    selection:
                        SelectedPeerSelection(
                            contactID: contact.id,
                            contactName: contact.name,
                            contactIsOnline: selectedConversationPresenceIsOnline(for: contact.id),
                            contactPresence: contactPresencePresentation(for: contact.id)
                        ),
                    relationship: relationship,
                    baseState: selectedPeerBaseState(for: contact.id, relationship: relationship),
                    channel: selectedChannelSnapshot(for: contact.id),
                    isJoined: isJoined,
                    activeChannelID: activeChannelId,
                    pendingAction: sessionCoordinator.pendingAction,
                    pendingConnectAcceptedIncomingRequest:
                        sessionCoordinator.pendingConnectAcceptedIncomingRequestContactID == contact.id,
                    requesterAutoJoinOnPeerAcceptanceEnabled:
                        conversationShortcutPolicy.requesterAutoJoinOnPeerAcceptance,
                    localTransmit: localTransmit,
                    peerSignalIsTransmitting: remoteReceiveProjectsPeerTalking(for: contact.id),
                    remotePlaybackDrainBlocksTransmit: remotePlaybackDrainBlocksLocalTransmit(for: contact.id),
                    remoteTransmitStopObserved:
                        receiveExecutionCoordinator
                            .state
                            .remoteTransmitStoppedContactIDs
                            .contains(contact.id),
                    systemSessionState: systemSessionState,
                    systemSessionMatchesContact: systemSessionMatches(contact.id),
                    mediaState: mediaConnectionState,
                    localRelayTransportReady: localRelayTransportReadyForTransmit(for: contact.id),
                    directMediaPathActive: shouldUseDirectQuicTransport(for: contact.id),
                    firstTalkStartupProfile: firstTalkStartupProfile(for: contact.id, startGraceIfNeeded: false),
                    incomingWakeActivationState:
                        pttWakeRuntime.incomingWakeActivationState(for: contact.id),
                    backendJoinSettling:
                        backendJoinIsSettling(for: contact.id),
                    backendSignalingJoinRecoveryActive:
                        backendRuntime.signalingJoinRecoveryTask != nil,
                    controlPlaneReconnectGraceActive:
                        shouldUseLiveCallControlPlaneReconnectGrace(for: contact.id),
                    localJoinFailure: pttCoordinator.state.lastJoinFailure
                )
            )
        )
    }

    func recordRecentOutgoingRequestEvidenceIfNeeded(
        contactID: UUID,
        relationship: PairRelationshipState,
        now: Date = Date()
    ) {
        guard relationship.isOutgoingRequest else { return }
        guard let channelID = contacts.first(where: { $0.id == contactID })?.backendChannelId,
              !channelID.isEmpty else { return }
        recentOutgoingRequestEvidenceByContactID[contactID] =
            RecentOutgoingRequestEvidence(
                channelId: channelID,
                requestCount: relationship.requestCount ?? 0,
                observedAt: now
            )
    }

    private func completeReconciledTeardownIfSystemSessionEnded(for contactID: UUID) {
        guard sessionCoordinator.pendingAction.pendingTeardownContactID == contactID else { return }
        guard systemSessionState == .none else { return }
        guard selectedChannelSnapshot(for: contactID)?.membership.hasLocalMembership != true else { return }

        sessionCoordinator.clearLeaveAction(for: contactID)
        diagnostics.record(
            .state,
            message: "Completing reconciled teardown after local system session ended",
            metadata: [
                "contactId": contactID.uuidString,
                "backendMembership": selectedChannelSnapshot(for: contactID).map { String(describing: $0.membership) } ?? "none",
            ]
        )
        replaceDisconnectRecoveryTask(with: nil)
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        pttCoordinator.reset()
        syncPTTState()
        updateStatusForSelectedContact()
        captureDiagnosticsState("session-teardown:reconciled-complete")
    }

    private func completeAbsentBackendMembershipRecoveryIfLocalSessionEnded(for contactID: UUID) {
        let selectedChannel: ChannelReadinessSnapshot? = {
            if let channelState = channelStateByContactID[contactID] {
                return ChannelReadinessSnapshot(
                    channelState: channelState,
                    readiness: channelReadinessByContactID[contactID]
                )
            }
            return selectedChannelSnapshot(for: contactID)
        }()
        guard selectedChannel?.membership.hasLocalMembership != true else { return }
        let pairRelationship = relationshipState(for: contactID)
        let requestRelationshipIsNone =
            selectedChannel.map { $0.requestRelationship == .none }
            ?? (pairRelationship == .none)
        let requestRelationshipIsOutgoing =
            selectedChannel.map { $0.requestRelationship.hasOutgoingRequest }
            ?? pairRelationship.isOutgoingRequest

        let contactBackendChannelID = contacts.first(where: { $0.id == contactID })?.backendChannelId
        let summaryBackendChannelID = contactSummaryByContactID[contactID]?.channelId
        let backendChannelReferenceAbsent =
            selectedChannel == nil
            && ((contactBackendChannelID?.isEmpty ?? true)
                && (summaryBackendChannelID?.isEmpty ?? true))
        let backendShowsLocalMembershipAbsent =
            selectedChannel?.membership.hasLocalMembership == false

        let localSessionTouchesContact =
            systemSessionMatches(contactID)
            || (isJoined && activeChannelId == contactID)
        guard !localSessionTouchesContact else { return }

        let backendLeaveCommandInFlight: Bool = {
            guard case .leave(let pendingContactID) = backendCommandCoordinator.state.activeOperation else {
                return false
            }
            return pendingContactID == contactID
        }()
        let pendingJoinIsStale = selectedChannel != nil && sessionCoordinator.pendingJoinContactID == contactID
        let pendingJoinContradictsOutgoingRequest =
            pendingJoinIsStale
            && requestRelationshipIsOutgoing
            && !localSessionTouchesContact
            && !backendJoinIsSettling(for: contactID)
        let pendingLeaveIsComplete =
            sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID)
            && !backendLeaveCommandInFlight
            && (backendShowsLocalMembershipAbsent || backendChannelReferenceAbsent)
        guard requestRelationshipIsNone || pendingJoinContradictsOutgoingRequest else { return }
        guard pendingJoinIsStale || pendingLeaveIsComplete else { return }

        let recoveryDecision: AbsentBackendMembershipRecoveryDecision
        if pendingJoinIsStale,
           !pendingJoinContradictsOutgoingRequest,
           shouldPreservePendingLocalJoinDuringBackendJoinSettling(for: contactID) {
            let suppressionReason: AbsentBackendMembershipSuppressionReason =
                backendJoinIsSettling(for: contactID)
                ? .backendJoinSettling
                : .unresolvedLocalJoinAttempt
            recoveryDecision = .suppressed(suppressionReason)
            let noticeKey = [
                contactID.uuidString,
                suppressionReason.rawValue,
                selectedChannel.map { String(describing: $0.membership) } ?? "none",
                selectedChannel?.status?.rawValue ?? "none",
                String(sessionCoordinator.localJoinAttempt?.issuedCount ?? 0),
            ].joined(separator: "|")
            if !deferredAbsentMembershipRecoveryNoticeKeys.contains(noticeKey) {
                deferredAbsentMembershipRecoveryNoticeKeys.insert(noticeKey)
                diagnostics.record(
                    .state,
                    message: suppressionReason.message,
                    metadata: [
                        "contactId": contactID.uuidString,
                        "invariantID": AbsentBackendMembershipRecovery.invariantID,
                        "repairDecision": "suppressed",
                        "repairSuppressionReason": suppressionReason.rawValue,
                        "backendMembership": selectedChannel.map { String(describing: $0.membership) } ?? "none",
                        "backendStatus": selectedChannel?.status?.rawValue ?? "none",
                        "preserveReason": suppressionReason.rawValue,
                        "localJoinAttemptIssuedCount": String(sessionCoordinator.localJoinAttempt?.issuedCount ?? 0),
                    ]
                )
            }
            return
        }

        if pendingJoinContradictsOutgoingRequest {
            recoveryDecision = .repair(.stalePendingJoinDuringOutgoingRequest)
        } else if pendingJoinIsStale {
            recoveryDecision = .repair(.stalePendingJoin)
        } else {
            recoveryDecision = .repair(.completedPendingLeave)
        }

        guard case .repair(let repairAction) = recoveryDecision else { return }
        let recoveryMetadata = absentBackendMembershipRecoveryMetadata(
            contactID: contactID,
            selectedChannel: selectedChannel,
            pairRelationship: pairRelationship,
            pendingJoinIsStale: pendingJoinIsStale,
            pendingLeaveIsComplete: pendingLeaveIsComplete,
            repairAction: repairAction
        )
        diagnostics.record(
            .state,
            message: "Requested absent backend membership recovery",
            metadata: recoveryMetadata.merging([
                "repairDecision": "requested"
            ]) { _, new in new }
        )
        sessionCoordinator.clearPendingJoin(for: contactID)
        sessionCoordinator.clearLeaveAction(for: contactID)
        deferredAbsentMembershipRecoveryNoticeKeys = deferredAbsentMembershipRecoveryNoticeKeys.filter {
            !$0.hasPrefix(contactID.uuidString)
        }
        replaceDisconnectRecoveryTask(with: nil)
        diagnostics.record(
            .state,
            message: repairAction.message,
            metadata: recoveryMetadata.merging([
                "repairDecision": "executed"
            ]) { _, new in new }
        )
        updateStatusForSelectedContact()
        diagnostics.record(
            .state,
            message: "Converged absent backend membership recovery",
            metadata: recoveryMetadata.merging([
                "repairDecision": "converged",
                "pendingActionAfterRepair": String(describing: sessionCoordinator.pendingAction),
            ]) { _, new in new }
        )
        captureDiagnosticsState("session-recovery:backend-membership-absent")
    }

    private func absentBackendMembershipRecoveryMetadata(
        contactID: UUID,
        selectedChannel: ChannelReadinessSnapshot?,
        pairRelationship: PairRelationshipState,
        pendingJoinIsStale: Bool,
        pendingLeaveIsComplete: Bool,
        repairAction: AbsentBackendMembershipRepairAction
    ) -> [String: String] {
        [
            "contactId": contactID.uuidString,
            "invariantID": AbsentBackendMembershipRecovery.invariantID,
            "repairAction": repairAction.rawValue,
            "pendingJoinWasStale": String(pendingJoinIsStale),
            "pendingLeaveWasComplete": String(pendingLeaveIsComplete),
            "backendMembership": selectedChannel.map { String(describing: $0.membership) } ?? "none",
            "requestRelationship": selectedChannel
                .map { String(describing: $0.requestRelationship) }
                ?? String(describing: pairRelationship),
        ]
    }

    func selectedPeerState(for contactID: UUID) -> SelectedPeerState {
        selectedPeerProjection(for: contactID).selectedPeerState
    }

    func selectedPeerProjection(for contactID: UUID) -> SelectedPeerProjection {
        if selectedContactId == contactID {
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

    func contact(for contactID: UUID) -> Contact? {
        contacts.first(where: { $0.id == contactID })
    }

    func contactName(for contactID: UUID) -> String? {
        contact(for: contactID)?.name
    }

    func contactProfileName(for contactID: UUID) -> String? {
        contact(for: contactID)?.profileName
    }

    func contactLocalName(for contactID: UUID) -> String? {
        contact(for: contactID)?.localName
    }

    func contactSubtitle(for contact: Contact, requestCount: Int? = nil) -> String {
        let base: String
        if contact.hasLocalNameOverride {
            base = "\(contact.profileName) • \(contact.handle)"
        } else {
            base = contact.handle
        }

        guard let requestCount, requestCount > 1 else { return base }
        return "\(base) • \(requestCount)x"
    }

    func contactShareLink(for contactID: UUID) -> String? {
        guard let handle = contact(for: contactID)?.handle else { return nil }
        let pathComponent = TurboHandle.sharePathComponent(from: handle)
        let encodedHandle = pathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pathComponent
        return "https://beepbeep.to/\(encodedHandle)"
    }

    func contactDID(for contactID: UUID) -> String? {
        guard let handle = contact(for: contactID)?.handle else { return nil }
        return "did:web:beepbeep.to:id:\(handle)"
    }

    func updateLocalContactName(_ localName: String?, for contactID: UUID) {
        let stored = TurboContactAliasStore.storeLocalName(localName, for: contactID, ownerKey: currentContactAliasOwnerKey)
        updateContact(contactID) { contact in
            contact.localName = stored
        }
        if selectedContactId == contactID {
            updateStatusForSelectedContact()
        }
    }

    func deleteContact(_ contactID: UUID) async -> Bool {
        guard let existingContact = contact(for: contactID) else { return true }
        guard let backend = backendServices else {
            backendStatusMessage = "Backend unavailable"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Delete contact failed: backend unavailable",
                metadata: ["contactId": contactID.uuidString, "handle": existingContact.handle]
            )
            return false
        }

        if selectedContactId != contactID {
            selectContact(existingContact)
        }

        let requiresDisconnect =
            selectedContactId == contactID
            || activeConversationContactID == contactID
            || mediaSessionContactID == contactID
            || systemSessionMatches(contactID)
            || isJoined
            || pttCoordinator.state.systemChannelUUID != nil

        if requiresDisconnect {
            await requestDisconnectSelectedPeer()
        }

        do {
            _ = try await backend.forgetContact(
                otherHandle: existingContact.remoteUserId == nil ? existingContact.handle : nil,
                otherUserId: existingContact.remoteUserId
            )
        } catch {
            let message = error.localizedDescription
            backendStatusMessage = "Delete failed: \(message)"
            diagnostics.record(
                .backend,
                level: .error,
                message: "Delete contact failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "handle": existingContact.handle,
                    "error": message,
                ]
            )
            return false
        }

        _ = TurboContactAliasStore.storeLocalName(nil, for: contactID, ownerKey: currentContactAliasOwnerKey)
        let retainedSummaries = contactSummaryByContactID
            .filter { $0.key != contactID }
            .map { BackendContactSummaryUpdate(contactID: $0.key, summary: $0.value) }
        let retainedIncomingInvites = incomingInviteByContactID
            .filter { $0.key != contactID }
            .map { BackendInviteUpdate(contactID: $0.key, invite: $0.value) }
        let retainedOutgoingInvites = outgoingInviteByContactID
            .filter { $0.key != contactID }
            .map { BackendInviteUpdate(contactID: $0.key, invite: $0.value) }

        backendSyncCoordinator.send(.contactSummariesUpdated(retainedSummaries))
        backendSyncCoordinator.send(.invitesUpdated(
            incoming: retainedIncomingInvites,
            outgoing: retainedOutgoingInvites,
            now: .now
        ))
        backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
        clearRemoteAudioActivity(for: contactID)
        pttWakeRuntime.clear(for: contactID)
        untrackContact(contactID)
        if selectedContactId == contactID {
            resetSelection()
        }
        contacts.removeAll { $0.id == contactID }
        pruneContactsToAuthoritativeState()
        reconcileContactSelectionIfNeeded(
            reason: "contact-deleted",
            allowSelectingFallbackContact: false
        )
        updateStatusForSelectedContact()
        captureDiagnosticsState("contact-deleted")
        await refreshContactSummaries()
        await refreshInvites()
        return contact(for: contactID) == nil
    }

    func requestCooldownRemaining(for contactID: UUID, now: Date = .now) -> Int? {
        let deadline =
            requestCooldownDeadlineByContactID[contactID]
            ?? optimisticOutgoingRequestEvidenceByContactID[contactID]?.cooldownDeadline
        guard let deadline else { return nil }
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

    var activeConversationContactID: UUID? {
        if case .active(let contactID, _) = systemSessionState,
           contacts.contains(where: { $0.id == contactID }) {
            return contactID
        }
        return activeChannelId
    }

    var activeConversationContact: Contact? {
        guard let activeConversationContactID else { return nil }
        return contacts.first(where: { $0.id == activeConversationContactID })
    }

    var transportPathBadgeState: MediaTransportPathState? {
        guard let contactID = activeConversationContactID ?? mediaSessionContactID else {
            return nil
        }

        let phase = selectedPeerProjection(for: contactID).selectedPeerState.phase
        guard phase.showsTransportPathBadge else {
            return nil
        }

        switch mediaTransportPathState {
        case .direct:
            return .direct
        case .fastRelay:
            return .fastRelay
        case .relay, .promoting, .recovering:
            return .relay
        }
    }

    private var listEligibleContacts: [Contact] {
        contacts.filter { contact in
            contact.handle != currentDevUserHandle
                && !(activeConversationContactID == contact.id)
        }
    }

    func contactListItem(for contact: Contact) -> ContactListItem {
        let relationship = relationshipState(for: contact.id)
        let presence = contactPresencePresentation(for: contact.id)
        let presentation = ConversationStateMachine.contactListPresentation(
            for: listConversationState(for: contact.id),
            requestCount: relationship.requestCount,
            presence: presence,
            // Reserve the busy case in the product model until the backend exposes
            // a dedicated peer-busy fact we can trust.
            isBusy: false
        )
        return ContactListItem(contact: contact, presentation: presentation)
    }

    var contactListSections: ContactListSections {
        let items = listEligibleContacts.map(contactListItem(for:))

        return ContactListSections(
            wantsToTalk: sortContactListItems(items.filter { $0.presentation.section == .wantsToTalk }),
            readyToTalk: sortContactListItems(items.filter { $0.presentation.section == .readyToTalk }),
            requested: sortContactListItems(items.filter { $0.presentation.section == .requested }),
            contacts: sortContactListItems(items.filter { $0.presentation.section == .contacts })
        )
    }

    private func sortContactListItems(_ items: [ContactListItem]) -> [ContactListItem] {
        items.sorted { lhs, rhs in
            if lhs.presentation.section == rhs.presentation.section {
                switch lhs.presentation.section {
                case .wantsToTalk, .requested:
                    let lhsRequestCount = lhs.presentation.requestCount ?? 1
                    let rhsRequestCount = rhs.presentation.requestCount ?? 1
                    if lhsRequestCount != rhsRequestCount {
                        return lhsRequestCount > rhsRequestCount
                    }
                case .readyToTalk:
                    let lhsRank = readyToTalkSortRank(lhs.presentation.displayStatus)
                    let rhsRank = readyToTalkSortRank(rhs.presentation.displayStatus)
                    if lhsRank != rhsRank {
                        return lhsRank < rhsRank
                    }
                case .contacts:
                    break
                }
            }

            let lhsPresence = contactPresencePresentation(for: lhs.contact.id)
            let rhsPresence = contactPresencePresentation(for: rhs.contact.id)
            if lhsPresence != rhsPresence {
                return presenceSortRank(lhsPresence) < presenceSortRank(rhsPresence)
            }

            return lhs.contact.name.localizedCaseInsensitiveCompare(rhs.contact.name) == .orderedAscending
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

    private func readyToTalkSortRank(_ displayStatus: ConversationDisplayStatus) -> Int {
        switch displayStatus {
        case .live:
            return 0
        case .ready:
            return 1
        case .offline, .online, .requested:
            return 2
        }
    }

    func ensureContactExists(
        handle: String,
        remoteUserId: String,
        channelId: String,
        displayName: String? = nil
    ) -> UUID {
        let stableID = Contact.stableID(remoteUserId: remoteUserId, fallbackHandle: Contact.normalizedHandle(handle))
        let result = ContactDirectory.ensureContact(
            handle: handle,
            remoteUserId: remoteUserId,
            channelId: channelId,
            displayName: displayName,
            localName: TurboContactAliasStore.localName(for: stableID, ownerKey: currentContactAliasOwnerKey),
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
            let snapshot = ChannelReadinessSnapshot(
                channelState: channelState,
                readiness: channelReadinessByContactID[contactID]
            )
            guard backendSyncCoordinator.state.syncState.summaryIncomingRequestIsHandled(for: contactID),
                  snapshot.requestRelationship.hasIncomingRequest else {
                return snapshot
            }
            return snapshot.replacingRequestRelationship(
                snapshot.requestRelationship.removingIncomingRequest,
                status: snapshot.status == .incomingRequest ? nil : snapshot.status
            )
        }
    }

    func selectContact(
        _ contact: Contact,
        reason: String = "selected-contact",
        opensTalkRequestSurface: Bool = true
    ) {
        let selectionChanged = selectedContactId != contact.id
        trackContact(contact.id)
        if opensTalkRequestSurface {
            markTalkRequestSurfaceOpened(
                for: contact.id,
                inviteID: incomingInviteByContactID[contact.id]?.inviteId
            )
        }
        if selectionChanged {
            selectedContactPrewarmedSelectionContactID = nil
        }
        selectedContactId = contact.id
        sessionCoordinator.select(contactID: contact.id)
        diagnostics.record(
            .state,
            message: "Selected contact",
            metadata: [
                "handle": contact.handle,
                "reason": reason,
            ]
        )
        updateStatusForSelectedContact()
        guard selectionChanged || selectedContactPrewarmedSelectionContactID != contact.id else {
            diagnostics.record(
                .media,
                message: "Skipped selected contact prewarm pipeline",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                    "blockReason": "already-prewarmed-for-selected-contact",
                ]
            )
            return
        }
        Task {
            await runSelectedContactPrewarmPipeline(
                for: contact.id,
                reason: reason
            )
        }
    }

    func runSelectedContactPrewarmPipeline(
        for contactID: UUID,
        reason: String
    ) async {
        guard selectedContactPrewarmPipelineEnabled else {
            diagnostics.record(
                .media,
                message: "Skipped selected contact prewarm pipeline",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": "feature-disabled"
                ]
            )
            return
        }
        guard selectedContactId == contactID else { return }
        guard !selectedContactPrewarmInFlight.contains(contactID) else {
            diagnostics.record(
                .media,
                message: "Coalesced selected contact prewarm pipeline",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                ]
            )
            return
        }
        selectedContactPrewarmInFlight.insert(contactID)
        defer {
            selectedContactPrewarmInFlight.remove(contactID)
        }

        let startedAt = Date()
        diagnostics.record(
            .media,
            message: "Selected contact prewarm pipeline started",
            metadata: selectedContactPrewarmMetadata(
                for: contactID,
                reason: reason,
                startedAt: startedAt
            )
        )

        await runSelectedContactPrewarmStage(
            "media-shell",
            contactID: contactID,
            reason: reason
        ) {
            precreateSelectedContactMediaShellIfNeeded(
                for: contactID,
                reason: reason
            )
        }

        let peerPrewarmHintBlockReason =
            reason.hasPrefix("peer-hint-")
                ? "peer-hint-loop-suppressed"
                : selectedPeerPrewarmHintBlockReason(for: contactID)
                    ?? selectedPeerPrewarmPublishBlockReason(for: contactID)
        async let peerPrewarmHint: Void = runSelectedContactPrewarmStage(
            "peer-prewarm-hint",
            contactID: contactID,
            reason: reason,
            initialBlockReason: peerPrewarmHintBlockReason
        ) {
            guard peerPrewarmHintBlockReason == nil else { return }
            await publishSelectedPeerPrewarmHintIfPossible(for: contactID, reason: reason)
        }
        async let directQuicPrewarm: Void = runSelectedContactPrewarmStage(
            "direct-quic-prewarm",
            contactID: contactID,
            reason: reason,
            initialBlockReason: selectedContactDirectQuicPrewarmBlockReason(for: contactID)
        ) {
            await ingestSelectedContactDirectQuicPrewarm(
                contactID: contactID,
                reason: reason
            )
        }
        async let foregroundTalkPrewarm: Void = runSelectedContactPrewarmStage(
            "foreground-talk-prewarm",
            contactID: contactID,
            reason: reason
        ) {
            await prewarmForegroundTalkPathIfNeeded(
                for: contactID,
                reason: reason
            )
        }
        async let relayPrejoin: Void = runSelectedContactPrewarmStage(
            "media-relay-prejoin",
            contactID: contactID,
            reason: reason
        ) {
            await prejoinMediaRelayForReadyChannelIfNeeded(
                contactID: contactID,
                channelReadiness: channelReadinessByContactID[contactID]
            )
        }
        _ = await (peerPrewarmHint, directQuicPrewarm, foregroundTalkPrewarm, relayPrejoin)

        diagnostics.record(
            .media,
            message: "Selected contact prewarm pipeline completed",
            metadata: selectedContactPrewarmMetadata(
                for: contactID,
                reason: reason,
                startedAt: startedAt
            )
        )
        if selectedContactId == contactID {
            selectedContactPrewarmedSelectionContactID = contactID
        }
    }

    private func runSelectedContactPrewarmStage(
        _ stage: String,
        contactID: UUID,
        reason: String,
        initialBlockReason: String? = nil,
        operation: () async -> Void
    ) async {
        guard selectedContactId == contactID else { return }
        let startedAt = Date()
        var metadata = selectedContactPrewarmMetadata(
            for: contactID,
            reason: reason,
            startedAt: startedAt
        )
        metadata["stage"] = stage
        if let initialBlockReason {
            metadata["initialBlockReason"] = initialBlockReason
        }
        diagnostics.record(
            .media,
            message: "Selected contact prewarm stage started",
            metadata: metadata
        )
        await operation()
        metadata = selectedContactPrewarmMetadata(
            for: contactID,
            reason: reason,
            startedAt: startedAt
        )
        metadata["stage"] = stage
        if let initialBlockReason {
            metadata["initialBlockReason"] = initialBlockReason
        }
        diagnostics.record(
            .media,
            message: "Selected contact prewarm stage completed",
            metadata: metadata
        )
    }

    private func selectedContactPrewarmMetadata(
        for contactID: UUID,
        reason: String,
        startedAt: Date
    ) -> [String: String] {
        let contact = contacts.first(where: { $0.id == contactID })
        return [
            "contactId": contactID.uuidString,
            "handle": contact?.handle ?? "none",
            "reason": reason,
            "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
            "selectedContactCurrent": String(selectedContactId == contactID),
            "applicationState": String(describing: currentApplicationState()),
            "backendChannelId": contact?.backendChannelId ?? "none",
            "remoteUserIdPresent": String(contact?.remoteUserId != nil),
            "webSocketConnected": String(backendServices?.isWebSocketConnected == true),
            "localMediaWarmupState": String(describing: localMediaWarmupState(for: contactID)),
            "directQuicPrewarmBlockReason": selectedContactDirectQuicPrewarmBlockReason(for: contactID) ?? "none",
            "mediaSessionContactId": mediaSessionContactID?.uuidString ?? "none",
            "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
        ]
    }

    func reconcileContactSelectionIfNeeded(
        reason: String,
        allowSelectingFallbackContact: Bool
    ) {
        if let selectedContactId,
           contacts.contains(where: { $0.id == selectedContactId }) {
            return
        }

        if selectedContactId != nil {
            selectedContactId = nil
            selectedPeerCoordinator.send(.selectedContactChanged(nil))
        }

        guard let contact = preferredContactForAutomaticSelection(
            allowSelectingFallbackContact: allowSelectingFallbackContact
        ) else {
            updateStatusForSelectedContact()
            return
        }

        diagnostics.record(
            .state,
            message: "Auto-selected contact",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        selectContact(contact, opensTalkRequestSurface: false)
    }

    @discardableResult
    func selectContactMatchingNotificationHandle(_ handle: String, reason: String) -> Bool {
        let normalizedHandle = Contact.normalizedHandle(handle)
        guard let contact = contacts.first(where: { Contact.normalizedHandle($0.handle) == normalizedHandle }) else {
            return false
        }

        diagnostics.record(
            .pushToTalk,
            message: "Selected contact from talk request notification",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        selectContact(contact)
        return true
    }

    private func preferredContactForAutomaticSelection(
        allowSelectingFallbackContact: Bool
    ) -> Contact? {
        if let incomingRequestContact = contacts
            .filter({ incomingInviteByContactID[$0.id] != nil })
            .max(by: { lhs, rhs in
                let lhsInvite = incomingInviteByContactID[lhs.id]
                let rhsInvite = incomingInviteByContactID[rhs.id]
                return inviteRecencyKey(lhsInvite) < inviteRecencyKey(rhsInvite)
            }) {
            return incomingRequestContact
        }

        if let activeChannelId,
           let activeContact = contacts.first(where: { $0.id == activeChannelId }) {
            return activeContact
        }

        guard allowSelectingFallbackContact else { return nil }
        return contacts.first
    }

    private func inviteRecencyKey(_ invite: TurboInviteResponse?) -> String {
        invite?.updatedAt ?? invite?.createdAt ?? ""
    }

    func resetSelection() {
        selectedContactId = nil
        selectedContactPrewarmedSelectionContactID = nil
        captureDiagnosticsState("selection-reset")
    }

    func updateStatusForSelectedContact() {
        if selectedContact != nil {
            syncSelectedPeerSession()
            statusMessage = selectedPeerCoordinator.state.selectedPeerState.statusMessage
            reconcileSelectedConnectionAttemptTimeout()
        } else {
            cancelSelectedConnectionAttemptTimeout()
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
        reconcileLiveConversationActivity()
    }

    func reconcileLiveConversationActivity() {
        guard let contact = selectedContact else {
            liveConversationActivityController.endActiveActivity()
            return
        }

        let selectedState = selectedPeerCoordinator.state.selectedPeerState
        let projection = LiveConversationActivityProjection(
            contact: contact,
            selectedPeerState: selectedState,
            localDisplayName: currentProfileName
        )
        liveConversationActivityController.reconcile(projection)
    }

    func reconcileSelectedConnectionAttemptTimeout() {
        guard let contactID = selectedContactId else {
            cancelSelectedConnectionAttemptTimeout()
            return
        }
        let selectedPeerState = selectedPeerCoordinator.state.selectedPeerState
        guard selectedPeerState.contactID == contactID,
              shouldTimeoutSelectedConnectionAttempt(selectedPeerState, contactID: contactID) else {
            cancelSelectedConnectionAttemptTimeout()
            return
        }

        let key = "\(contactID.uuidString)|\(selectedPeerState.detail)"
        guard selectedConnectionAttemptTimeoutKey != key else { return }
        cancelSelectedConnectionAttemptTimeout()
        selectedConnectionAttemptTimeoutKey = key
        selectedConnectionAttemptTimeoutTask = Task { [weak self] in
            let timeout = await MainActor.run {
                self?.selectedConnectionAttemptTimeoutNanoseconds ?? 15_000_000_000
            }
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.selectedConnectionAttemptTimeoutKey == key else { return }
                if let contact = self.contacts.first(where: { $0.id == contactID }),
                   let attempt = self.sessionCoordinator.localJoinAttempt,
                   attempt.contactID == contactID,
                   attempt.channelUUID == contact.channelId,
                   !self.localSessionEvidenceExists(for: contactID, expectedChannelUUID: contact.channelId) {
                    if self.hasStaleSystemRejoinSuppression(
                        channelUUID: contact.channelId,
                        contactID: contactID
                    ) {
                        self.sessionCoordinator.clearPendingJoin(for: contactID)
                        self.updateStatusForSelectedContact()
                        self.diagnostics.record(
                            .pushToTalk,
                            message: "Suppressed stale local PTT join retry after recent system leave",
                            metadata: [
                                "contactId": contactID.uuidString,
                                "channelUUID": contact.channelId.uuidString,
                                "issuedCount": String(attempt.issuedCount),
                                "selectedPeerPhase": String(describing: self.selectedPeerCoordinator.state.selectedPeerState.phase),
                            ]
                        )
                        self.captureDiagnosticsState("selected-connection-attempt:retry-blocked-by-recent-leave")
                        self.cancelSelectedConnectionAttemptTimeout()
                        return
                    }
                    self.diagnostics.record(
                        .pushToTalk,
                        level: .notice,
                        message: "Retrying stale local PTT join after connection timeout",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "channelUUID": contact.channelId.uuidString,
                            "issuedCount": String(attempt.issuedCount),
                            "selectedPeerPhase": String(describing: self.selectedPeerCoordinator.state.selectedPeerState.phase),
                        ]
                    )
                    self.selectedConnectionAttemptTimeoutKey = nil
                    self.selectedConnectionAttemptTimeoutTask = nil
                    self.joinPTTChannel(for: contact)
                    self.reconcileSelectedConnectionAttemptTimeout()
                    return
                }
                self.selectedPeerCoordinator.send(.connectionAttemptTimedOut(contactID: contactID))
                self.statusMessage = self.selectedPeerCoordinator.state.selectedPeerState.statusMessage
                self.diagnostics.record(
                    .state,
                    level: .notice,
                    message: "Selected connection attempt timed out",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "selectedPeerPhase": String(describing: self.selectedPeerCoordinator.state.selectedPeerState.phase),
                    ]
                )
                self.captureDiagnosticsState("selected-connection-attempt:timed-out")
                self.cancelSelectedConnectionAttemptTimeout()
            }
        }
    }

    func cancelSelectedConnectionAttemptTimeout() {
        selectedConnectionAttemptTimeoutTask?.cancel()
        selectedConnectionAttemptTimeoutTask = nil
        selectedConnectionAttemptTimeoutKey = nil
    }

    func shouldTimeoutSelectedConnectionAttempt(
        _ selectedPeerState: SelectedPeerState,
        contactID: UUID? = nil
    ) -> Bool {
        if let contactID,
           localSessionEvidenceExists(for: contactID) {
            return false
        }

        if let contactID,
           case .connect(.requestingBackend(let pendingContactID)) = sessionCoordinator.pendingAction,
           pendingContactID == contactID {
            return false
        }

        switch selectedPeerState.detail {
        case .waitingForPeer(reason: .pendingJoin),
             .waitingForPeer(reason: .backendSessionTransition),
             .waitingForPeer(reason: .localSessionTransition),
             .waitingForPeer(reason: .peerReadyToConnect):
            return true
        case .idle, .requested, .incomingRequest, .peerReady, .wakeReady,
             .waitingForPeer, .localJoinFailed, .ready, .startingTransmit,
             .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
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
            summaryContactIDs: Set(contactSummaryByContactID.keys),
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
