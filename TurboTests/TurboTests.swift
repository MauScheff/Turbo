import Foundation
import Testing
@testable import BeepBeep

struct TurboTests {

    @Test func explicitLeaveBlocksAutoRejoin() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.markExplicitLeave(contactID: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func successfulJoinClearsPendingJoin() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.clearAfterSuccessfulJoin(for: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func selectingContactDoesNotQueueJoin() {
        var coordinator = SessionCoordinatorState()
        let selectedContactID = UUID()
        let pendingContactID = UUID()

        coordinator.queueJoin(contactID: pendingContactID)
        coordinator.select(contactID: selectedContactID)

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func effectiveStateRequiresSystemAndPeerReadiness() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.effectiveState(for: context) == .waitingForPeer)
    }

    @Test func statusMessageReturnsOnlineAfterExplicitLeave() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .explicitLeave(contactID: contactID),
            channel: nil
        )

        #expect(ConversationStateMachine.statusMessage(for: context) == "Blake is online")
    }

    @Test func retainedContactsOnlyKeepAuthoritativeIDs() {
        let avery = Contact(
            id: Contact.stableID(for: "@avery"),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-avery",
            remoteUserId: "user-avery"
        )
        let blake = Contact(
            id: Contact.stableID(for: "@blake"),
            name: "Blake",
            handle: "@blake",
            isOnline: false,
            channelId: UUID(),
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
        )
        let tatum = Contact(
            id: Contact.stableID(for: "@tatum"),
            name: "Tatum",
            handle: "@tatum",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-tatum",
            remoteUserId: "user-tatum"
        )

        let contacts = ContactDirectory.retainedContacts(
            existingContacts: [tatum, blake, avery],
            authoritativeContactIDs: [avery.id, blake.id]
        )

        #expect(contacts.map(\.handle) == ["@avery", "@blake"])
    }

    @Test func authoritativeContactIDsOnlyIncludeTrackedAndActivePeers() {
        let tracked = Set([UUID(), UUID()])
        let selected = UUID()
        let active = UUID()
        let media = UUID()
        let pending = UUID()
        let invite = UUID()

        let ids = ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: tracked,
            selectedContactID: selected,
            activeChannelID: active,
            mediaSessionContactID: media,
            pendingJoinContactID: pending,
            inviteContactIDs: [invite]
        )

        #expect(ids == tracked.union([selected, active, media, pending, invite]))
    }

    @Test func requestContactsRemainAuthoritativeWithoutTracking() {
        let inviteOnly = UUID()

        let ids = ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: [],
            selectedContactID: nil,
            activeChannelID: nil,
            mediaSessionContactID: nil,
            pendingJoinContactID: nil,
            inviteContactIDs: [inviteOnly]
        )

        #expect(ids == [inviteOnly])
    }

    @Test func backendReadyWithoutLocalSessionRequestsRestoration() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .restoreLocalSession(contactID: contactID)
        )
    }

    @Test func staleLocalSessionWithoutBackendMembershipTearsDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func suggestedDevHandlesIncludeCorePeers() {
        #expect(ContactDirectory.suggestedDevHandles.contains("@avery"))
        #expect(ContactDirectory.suggestedDevHandles.contains("@blake"))
        #expect(ContactDirectory.suggestedDevHandles.contains("@turbo-ios"))
    }

    @Test func waitingForPeerPrimaryActionIsDisabled() {
        let action = ConversationStateMachine.primaryAction(
            conversationState: .waitingForPeer,
            isSelectedChannelJoined: true,
            canTransmitNow: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        switch action.kind {
        case .connect:
            break
        case .holdToTalk:
            Issue.record("Expected connect primary action while waiting for peer")
        }
        #expect(action.label == "Waiting for Peer")
        #expect(action.isEnabled == false)
        switch action.style {
        case .muted:
            break
        case .accent, .active:
            Issue.record("Expected muted styling while waiting for peer")
        }
    }

    @Test func selectedPeerStateKeepsOutgoingRequestOutOfWaitingWithoutSessionTransition() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .outgoingRequest(requestCount: 2)
        )

        #expect(state.phase == .requested)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Requested Blake")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateUsesWaitingDuringPendingJoin() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .join(contactID: contactID),
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Connecting...")
    }

    @Test func selectedPeerStateDoesNotReportReadyUntilLocalSessionAligns() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateAllowsTransmitWhenSessionIsFullyAligned() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.conversationState == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
    }

    @Test func selectedPeerReducerKeepsOutgoingRequestRequestedUntilRealTransitionStarts() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let events: [SelectedPeerEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingRequest(requestCount: 2)),
            .baseStateUpdated(.requested),
            .channelUpdated(nil),
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let state = reduceSelectedPeerState(events)

        #expect(state.selectedPeerState.phase == .requested)
        #expect(state.selectedPeerState.conversationState == .requested)
        #expect(state.selectedPeerState.statusMessage == "Requested Blake")
    }

    @Test func selectedPeerReducerUsesWaitingForPendingJoin() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let events: [SelectedPeerEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .join(contactID: contactID)),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let state = reduceSelectedPeerState(events)

        #expect(state.selectedPeerState.phase == .waitingForPeer)
        #expect(state.selectedPeerState.statusMessage == "Connecting...")
    }

    @Test func selectedPeerReducerUsesBackendReadyOnlyAfterLocalAlignment() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let waitingEvents: [SelectedPeerEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(isJoined: true, activeChannelID: contactID, pendingAction: .none),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let waitingState = reduceSelectedPeerState(waitingEvents)
        #expect(waitingState.selectedPeerState.phase == .waitingForPeer)
        #expect(waitingState.selectedPeerState.canTransmitNow == false)

        let readyState = SelectedPeerReducer.reduce(
            state: waitingState,
            event: .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: UUID()),
                matchesSelectedContact: true
            )
        ).state

        #expect(readyState.selectedPeerState.phase == .ready)
        #expect(readyState.selectedPeerState.statusMessage == "Connected")
        #expect(readyState.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerJoinRequestEmitsConnectForJoinableSelection() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingRequest(requestCount: 1)),
            .baseStateUpdated(.requested),
            .channelUpdated(nil),
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.connect(contactID: contactID)])
    }

    @Test func selectedPeerReducerDisconnectRequestEmitsDisconnectForPendingJoin() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .join(contactID: contactID)),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .disconnectRequested)

        #expect(transition.effects == [.disconnect(contactID: contactID)])
    }

    @Test func selectedPeerReducerReconcileRequestEmitsRestoreEffect() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.restoreLocalSession(contactID: contactID)])
    }

    @Test func selectedPeerReducerClearsStateOnDeselection() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.incomingRequest(requestCount: 1)),
            .baseStateUpdated(.incomingRequest),
            .channelUpdated(nil),
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none),
            .systemSessionUpdated(.none, matchesSelectedContact: false),
            .selectedContactChanged(nil)
        ])

        #expect(state.selection == nil)
        #expect(state.selectedPeerState.phase == .idle)
        #expect(state.reconciliationAction == .none)
    }

    @Test func listConversationStatePrefersIncomingRequestOverSummaryBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel",
            isOnline: true,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 3,
            isActiveConversation: false,
            badgeStatus: "ready"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .incomingRequest)
    }

    @Test func listConversationStateMapsBackendReadyBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            isActiveConversation: true,
            badgeStatus: "ready"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .ready)
    }

    @Test func listConversationStateFallsBackToIdleForUnknownBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@casey",
            displayName: "Casey",
            channelId: nil,
            isOnline: false,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            isActiveConversation: false,
            badgeStatus: "mystery"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .idle)
    }

    @Test func transmitReducerPressRequestEmitsBeginEffect() {
        let request = makeTransmitRequest()

        let transition = TransmitReducer.reduce(
            state: .initial,
            event: .pressRequested(request)
        )

        #expect(transition.state.phase == .requesting(contactID: request.contactID))
        #expect(transition.state.isPressingTalk)
        #expect(transition.effects == [.beginTransmit(request)])
    }

    @Test func transmitReducerBeginSuccessEmitsActivationWhileStillPressing() {
        let request = makeTransmitRequest()
        let requestingState = TransmitReducer.reduce(
            state: .initial,
            event: .pressRequested(request)
        ).state
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let transition = TransmitReducer.reduce(
            state: requestingState,
            event: .beginSucceeded(target, request)
        )

        #expect(transition.state.phase == .active(contactID: request.contactID))
        #expect(transition.state.activeTarget == target)
        #expect(transition.effects == [.activateTransmit(request, target)])
    }

    @Test func transmitReducerReleaseAfterGrantEmitsStopEffect() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let activeState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .beginSucceeded(target, request)
        ).state

        let transition = TransmitReducer.reduce(
            state: activeState,
            event: .releaseRequested
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects == [.stopTransmit(target)])
    }

    @Test func transmitReducerLateGrantAfterReleaseStopsImmediately() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let releasedState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .releaseRequested
        ).state

        let transition = TransmitReducer.reduce(
            state: releasedState,
            event: .beginSucceeded(target, request)
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.effects == [.stopTransmit(target)])
    }

    @Test func pttReducerRestoredUnknownChannelIsMismatched() {
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .restoredChannel(channelUUID: channelUUID, contactID: nil)
        )

        #expect(transition.state.systemSessionState == .mismatched(channelUUID: channelUUID))
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerJoinEmitsSyncEffect() {
        let contactID = UUID()
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "push")
        )

        #expect(transition.state.isJoined)
        #expect(transition.state.activeContactID == contactID)
        #expect(transition.state.systemSessionState == .active(contactID: contactID, channelUUID: channelUUID))
        #expect(transition.effects == [.syncJoinedChannel(contactID: contactID)])
    }

    @Test func pttReducerLeaveEmitsSyncAndAutoRejoinEffects() {
        let contactID = UUID()
        let channelUUID = UUID()
        let joinedState = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "manual")
        ).state
        let autoRejoinContactID = UUID()

        let transition = PTTReducer.reduce(
            state: joinedState,
            event: .didLeaveChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "switch",
                autoRejoinContactID: autoRejoinContactID
            )
        )

        #expect(transition.state.isJoined == false)
        #expect(transition.state.systemSessionState == .none)
        #expect(
            transition.effects == [
                .syncLeftChannel(contactID: contactID, autoRejoinContactID: autoRejoinContactID)
            ]
        )
    }

    @Test func pttReducerSystemTransmitFailureEmitsTransmitFailureEffect() {
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: PTTSessionState(
                systemChannelUUID: channelUUID,
                activeContactID: UUID(),
                isJoined: true,
                isTransmitting: true,
                lastError: nil
            ),
            event: .failedToBeginTransmitting(channelUUID: channelUUID, message: "denied")
        )

        #expect(transition.state.isTransmitting == false)
        #expect(transition.state.lastError == "denied")
        #expect(transition.effects == [.handleSystemTransmitFailure("denied")])
    }

    @Test func backendSyncReducerPollRefreshesSelectedChannel() {
        let contactID = UUID()

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .pollRequested(selectedContactID: contactID)
        )

        #expect(
            transition.effects == [
                .ensureWebSocketConnected,
                .heartbeatPresence,
                .refreshContactSummaries,
                .refreshInvites,
                .refreshChannelState(contactID)
            ]
        )
    }

    @Test func backendSyncReducerContactSummaryUpdateReplacesSnapshot() {
        let contactID = UUID()
        let summary = makeContactSummary(channelId: "channel-1")

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
    }

    @Test func backendSyncReducerSeededInviteStartsCooldown() {
        let contactID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let invite = makeInvite(direction: "outgoing")

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .outgoingInviteSeeded(contactID: contactID, invite: invite, now: now)
        )

        #expect(transition.state.syncState.outgoingInvites[contactID] == invite)
        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == now.addingTimeInterval(30))
    }

    @Test func backendCommandReducerOpenPeerEmitsLookupEffect() {
        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState.initial,
            event: .openPeerRequested(handle: "@avery")
        )

        #expect(transition.state.activeOperation == .openPeer(handle: "@avery"))
        #expect(transition.effects == [.openPeer(handle: "@avery")])
    }

    @Test func backendCommandReducerDeduplicatesJoinForSameContact() {
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(activeOperation: .join(contactID: contactID), lastError: nil),
            event: .joinRequested(request)
        )

        #expect(transition.state.activeOperation == .join(contactID: contactID))
        #expect(transition.effects.isEmpty)
    }

    @Test func backendCommandReducerLeaveFailureClearsOperationAndStoresError() {
        let contactID = UUID()
        let leaveRequest = BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
        let joinedTransition = BackendCommandReducer.reduce(
            state: BackendCommandState.initial,
            event: .leaveRequested(leaveRequest)
        )
        let failedTransition = BackendCommandReducer.reduce(
            state: joinedTransition.state,
            event: .operationFailed("leave failed")
        )

        #expect(joinedTransition.effects == [.leave(leaveRequest)])
        #expect(failedTransition.state.activeOperation == nil)
        #expect(failedTransition.state.lastError == "leave failed")
    }

    @Test func devSelfCheckReducerTracksRunningAndLatestReport() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: true,
            isBackendClientReady: true,
            selectedTarget: nil
        )
        let report = DevSelfCheckReport(
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            targetHandle: nil,
            steps: [DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok")]
        )

        let started = DevSelfCheckReducer.reduce(
            state: .initial,
            event: .runRequested(request)
        )
        let completed = DevSelfCheckReducer.reduce(
            state: started.state,
            event: .runCompleted(report)
        )

        #expect(started.state.isRunning)
        #expect(started.effects == [.run(request)])
        #expect(completed.state.isRunning == false)
        #expect(completed.state.latestReport == report)
    }

    @Test func devSelfCheckRunnerSkipsPeerStepsWithoutSelection() async {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: true,
            isBackendClientReady: true,
            selectedTarget: nil
        )
        let services = DevSelfCheckServices(
            fetchRuntimeConfig: { TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: false) },
            authenticate: { TurboAuthSessionResponse(userId: "user-self", handle: "@self", displayName: "Self") },
            heartbeatPresence: { TurboPresenceHeartbeatResponse(deviceId: "device", userId: "user-self", status: "ok") },
            ensureWebSocketConnected: {},
            waitForWebSocketConnection: {},
            lookupUser: { _ in Issue.record("lookupUser should not run without a selected target"); return TurboUserLookupResponse(userId: "", handle: "", displayName: "") },
            directChannel: { _ in Issue.record("directChannel should not run without a selected target"); return TurboDirectChannelResponse(channelId: "", lowUserId: "", highUserId: "", createdAt: "") },
            channelState: { _ in Issue.record("channelState should not run without a selected target"); return makeChannelState(status: .idle, canTransmit: false) },
            alignmentAction: { _ in .none }
        )

        let outcome = await DevSelfCheckRunner.run(
            request: request,
            services: services
        )

        #expect(outcome.authenticatedUserID == "user-self")
        #expect(outcome.contactUpdate == nil)
        #expect(outcome.channelStateUpdate == nil)
        #expect(outcome.report.isPassing)
        #expect(outcome.report.steps.map(\.id) == [.backendConfig, .runtimeConfig, .authSession, .deviceHeartbeat, .websocket, .peerLookup, .directChannel, .channelState, .sessionAlignment])
        #expect(outcome.report.steps.suffix(4).allSatisfy { $0.status == .skipped })
    }

    @Test func pttSystemPolicyReducerEmitsUploadEffectWhenChannelIsKnown() {
        let transition = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: "channel-1")
        )

        #expect(transition.state.latestTokenHex == "deadbeef")
        #expect(
            transition.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @Test func pttSystemPolicyReducerRecordsUploadFailure() {
        let transition = PTTSystemPolicyReducer.reduce(
            state: PTTSystemPolicyState(latestTokenHex: "deadbeef", lastTokenUploadError: nil),
            event: .tokenUploadFailed("network down")
        )

        #expect(transition.state.latestTokenHex == "deadbeef")
        #expect(transition.state.lastTokenUploadError == "network down")
        #expect(transition.effects.isEmpty)
    }

    @Test func pttSystemDisplayPolicyUsesContactNameForRestoredDescriptor() {
        let channelUUID = UUID()
        let contact = Contact(
            id: UUID(),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        let knownName = PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: channelUUID,
            contacts: [contact],
            fallbackName: "Fallback"
        )
        let fallbackName = PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: UUID(),
            contacts: [contact],
            fallbackName: "Fallback"
        )

        #expect(knownName == "Chat with Avery")
        #expect(fallbackName == "Fallback")
    }

    @Test func transmittablePrimaryActionUsesHoldToTalk() {
        let action = ConversationStateMachine.primaryAction(
            conversationState: .ready,
            isSelectedChannelJoined: true,
            canTransmitNow: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        switch action.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected hold-to-talk primary action when transmission is available")
        }
        #expect(action.label == "Hold To Talk")
        #expect(action.isEnabled)
        switch action.style {
        case .accent:
            break
        case .muted, .active:
            Issue.record("Expected accent styling for hold-to-talk readiness")
        }
    }

    @Test func selfCheckSummaryPrefersFailingStep() {
        let report = DevSelfCheckReport(
            startedAt: .now,
            completedAt: .now,
            targetHandle: "@blake",
            steps: [
                DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok"),
                DevSelfCheckStep(.channelState, status: .failed, detail: "state failed")
            ]
        )

        #expect(report.isPassing == false)
        #expect(report.summary == "Self-check failed at channel state")
    }

    @Test func selfCheckSummaryUsesTargetOnSuccess() {
        let report = DevSelfCheckReport(
            startedAt: .now,
            completedAt: .now,
            targetHandle: "@avery",
            steps: [
                DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok"),
                DevSelfCheckStep(.sessionAlignment, status: .passed, detail: "aligned")
            ]
        )

        #expect(report.isPassing)
        #expect(report.summary == "Self-check passed for @avery")
    }
}

private func makeChannelState(
    status: ConversationState,
    canTransmit: Bool,
    selfJoined: Bool = true,
    peerJoined: Bool = true,
    peerDeviceConnected: Bool = true
) -> TurboChannelStateResponse {
    TurboChannelStateResponse(
        channelId: "channel",
        selfUserId: "self",
        peerUserId: "peer",
        peerHandle: "@peer",
        selfOnline: true,
        peerOnline: true,
        selfJoined: selfJoined,
        peerJoined: peerJoined,
        peerDeviceConnected: peerDeviceConnected,
        hasIncomingRequest: false,
        hasOutgoingRequest: false,
        requestCount: 0,
        activeTransmitterUserId: nil,
        transmitLeaseExpiresAt: nil,
        status: status.rawValue,
        canTransmit: canTransmit
    )
}

private func reduceSelectedPeerState(_ events: [SelectedPeerEvent]) -> SelectedPeerSessionState {
    events.reduce(.initial) { state, event in
        SelectedPeerReducer.reduce(state: state, event: event).state
    }
}

private func makeTransmitRequest() -> TransmitRequestContext {
    TransmitRequestContext(
        contactID: UUID(),
        contactHandle: "@avery",
        backendChannelID: "channel-1",
        remoteUserID: "user-peer",
        channelUUID: UUID(),
        usesLocalHTTPBackend: false,
        backendSupportsWebSocket: true
    )
}

private func makeContactSummary(channelId: String?) -> TurboContactSummaryResponse {
    TurboContactSummaryResponse(
        userId: "user-peer",
        handle: "@avery",
        displayName: "Avery",
        channelId: channelId,
        isOnline: true,
        hasIncomingRequest: false,
        hasOutgoingRequest: false,
        requestCount: 0,
        isActiveConversation: false,
        badgeStatus: "online"
    )
}

private func makeInvite(direction: String) -> TurboInviteResponse {
    TurboInviteResponse(
        inviteId: UUID().uuidString,
        fromUserId: "user-self",
        fromHandle: "@self",
        toUserId: "user-peer",
        toHandle: "@avery",
        channelId: "channel-1",
        status: "pending",
        direction: direction,
        requestCount: 1,
        createdAt: "2026-04-08T00:00:00Z",
        updatedAt: nil,
        targetAvailability: nil,
        shouldAutoJoinPeer: nil,
        accepted: nil,
        pendingJoin: nil
    )
}
