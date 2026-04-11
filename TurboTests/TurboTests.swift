import Foundation
import Testing
import PushToTalk
import AVFAudio
@testable import BeepBeep

struct TurboTests {

    @Test func audioOutputPreferenceCyclesBetweenSpeakerAndPhone() {
        #expect(AudioOutputPreference.speaker.next == .phone)
        #expect(AudioOutputPreference.phone.next == .speaker)
        #expect(AudioOutputPreference.speaker.buttonLabel == "Speaker")
        #expect(AudioOutputPreference.phone.buttonLabel == "Phone")
    }

    @Test func explicitLeaveBlocksAutoRejoin() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.markExplicitLeave(contactID: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func queueJoinDoesNotOverrideExplicitLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.queueJoin(contactID: contactID)

        #expect(coordinator.pendingAction == .explicitLeave(contactID: contactID))
    }

    @Test func reconciledTeardownBlocksAutoRejoinUntilLeaveCompletes() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueConnect(contactID: contactID)
        coordinator.markReconciledTeardown(contactID: contactID)

        #expect(coordinator.pendingAction == .teardown(contactID: contactID))
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func clearLeaveActionResetsMatchingPendingTeardown() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markReconciledTeardown(contactID: contactID)
        coordinator.clearLeaveAction(for: contactID)

        #expect(coordinator == SessionCoordinatorState())
    }

    @Test func clearExplicitLeaveResetsMatchingPendingLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.clearExplicitLeave(for: contactID)

        #expect(coordinator == SessionCoordinatorState())
    }

    @Test func clearExplicitLeaveKeepsOtherPendingLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.clearExplicitLeave(for: UUID())

        #expect(coordinator != SessionCoordinatorState())
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func preservedJoinedChannelRefreshDoesNotClearExplicitLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localSessionEstablished: true,
            localSessionCleared: false
        )

        #expect(coordinator.pendingAction == .explicitLeave(contactID: contactID))
    }

    @Test func nonJoinedChannelRefreshClearsExplicitLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(
                status: .requested,
                canTransmit: false,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            localSessionEstablished: false,
            localSessionCleared: true
        )

        #expect(coordinator == SessionCoordinatorState())
    }

    @Test func backendJoinedStateDoesNotClearPendingJoinBeforeLocalSessionEstablishes() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localSessionEstablished: false,
            localSessionCleared: false
        )

        #expect(coordinator.pendingJoinContactID == contactID)
    }

    @Test func localSessionEstablishmentClearsPendingJoinAfterBackendShowsJoined() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localSessionEstablished: true,
            localSessionCleared: false
        )

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func successfulJoinClearsPendingJoin() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.clearAfterSuccessfulJoin(for: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func clearingPendingJoinWithoutSessionStopsWaitingTransition() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.clearPendingJoin(for: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func queuedConnectSurvivesUntilRejoinAfterLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueConnect(contactID: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.autoRejoinContactID(afterLeaving: nil) == contactID)
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
            localJoinFailure: nil,
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
            localJoinFailure: nil,
            channel: nil
        )

        #expect(ConversationStateMachine.statusMessage(for: context) == "Blake is online")
    }

    @Test func selectedPeerStateUsesDisconnectingStatusWhileExplicitLeaveIsInFlight() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: false,
                systemSessionState: .none,
                pendingAction: .explicitLeave(contactID: contactID),
                localJoinFailure: nil,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Disconnecting...")
        #expect(state.canTransmitNow == false)
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
            localJoinFailure: nil,
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
            localJoinFailure: nil,
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

    @Test func alignedSessionTearsDownWhenPeerLeavesChannel() {
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
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
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

    @Test func alignedWaitingForPeerWithPendingRequestDoesNotTearDown() {
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
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func explicitLeaveStillTearsDownWhenSystemSessionClears() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .explicitLeave(contactID: contactID),
            localJoinFailure: nil,
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
            == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func pendingJoinSuppressesDriftTeardownUntilBackendConfirmsMembership() {
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
            pendingAction: .join(contactID: contactID),
            localJoinFailure: nil,
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

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func channelLimitJoinFailureSuppressesAutomaticRestore() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: PTTJoinFailure(
                contactID: contactID,
                channelUUID: channelUUID,
                reason: .channelLimitReached
            ),
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func activeMatchingSystemSessionSuppressesDuplicateRestore() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
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
            localJoinFailure: nil,
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

    @Test func selectedPeerStateShowsPeerReadyWhenRemoteHasJoinedFirst() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .requested,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: true,
                    requestCount: 1,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.requested.rawValue,
                    canTransmit: false
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .outgoingRequest(requestCount: 1)
        )

        #expect(state.phase == .peerReady)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateShowsPeerReadyAfterInviteHasBeenAccepted() {
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
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true,
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

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .peerReady)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Blake is ready to connect")
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
            localJoinFailure: nil,
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

    @Test func selectedPeerStateSurfacesRecoverableLocalJoinFailure() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: PTTJoinFailure(
                contactID: contactID,
                channelUUID: channelUUID,
                reason: .channelLimitReached
            ),
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        let state = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(state.phase == .localJoinFailed)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Reconnect failed. End session and retry.")
    }

    @Test func selectedPeerStateKeepsRequestSubmissionOutOfWaiting() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .requested,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(contactID: contactID),
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .outgoingRequest(requestCount: 1)
        )

        #expect(state.phase == .requested)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Requested Avery")
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
            localJoinFailure: nil,
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
            localJoinFailure: nil,
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

    @Test func selectedPeerStateShowsReadyWhenPeerDeviceConnectivityLags() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.conversationState == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow == false)
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
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none, localJoinFailure: nil),
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
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .join(contactID: contactID), localJoinFailure: nil),
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
            .localSessionUpdated(isJoined: true, activeChannelID: contactID, pendingAction: .none, localJoinFailure: nil),
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
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none, localJoinFailure: nil),
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
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .join(contactID: contactID), localJoinFailure: nil),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .disconnectRequested)

        #expect(transition.effects == [.disconnect(contactID: contactID)])
    }

    @Test func selectedPeerReducerDisconnectRequestSkipsDuplicateDisconnectDuringExplicitLeave() {
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
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .explicitLeave(contactID: contactID),
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .disconnectRequested)

        #expect(transition.effects.isEmpty)
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
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none, localJoinFailure: nil),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.restoreLocalSession(contactID: contactID)])
    }

    @Test func selectedPeerReducerReconcileRequestSkipsRestoreWhenSystemSessionAlreadyMatches() {
        let contactID = UUID()
        let channelUUID = UUID()
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
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none, localJoinFailure: nil),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedPeerReducerReconcileRequestSkipsDuplicateTeardownDuringExplicitLeave() {
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
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .explicitLeave(contactID: contactID),
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedPeerReducerReconcileRequestSkipsDuplicateTeardownWhileTeardownIsInFlight() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .teardown(contactID: contactID),
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: UUID()), matchesSelectedContact: true)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func peerReadyPrimaryActionAllowsConnect() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .outgoingRequest(requestCount: 1),
                phase: .peerReady,
                statusMessage: "Blake is ready to connect",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: 20
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Connect")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func localJoinFailedPrimaryActionStaysDisabled() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .none,
                phase: .localJoinFailed,
                statusMessage: "Reconnect failed. End session and retry.",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.isEnabled == false)
        #expect(action.style == .muted)
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
            .localSessionUpdated(isJoined: false, activeChannelID: nil, pendingAction: .none, localJoinFailure: nil),
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

    @Test func transmitReducerSystemBeginFailureAbortsWithoutPeerStopSignal() {
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
            event: .systemBeginFailed("PTChannelError(rawValue: 1)")
        )

        #expect(transition.state.phase == .idle)
        #expect(!transition.state.isPressingTalk)
        #expect(transition.state.activeTarget == nil)
        #expect(transition.effects == [.abortTransmit(target)])
    }

    @MainActor
    @Test func backendChannelRefreshPreservesRequestingTransmitLifecycle() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitPhase: .requesting(contactID: contactID),
                systemIsTransmitting: false
            )
        )
    }

    @MainActor
    @Test func backendChannelRefreshDoesNotPreserveIdleTransmitLifecycle() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            !viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitPhase: .idle,
                systemIsTransmitting: false
            )
        )
    }

    @MainActor
    @Test func channelRefreshFailurePreservesJoinedSelectedSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true

        #expect(viewModel.shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID))
    }

    @MainActor
    @Test func channelRefreshFailureDoesNotPreserveIdleSelectedSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID

        #expect(!viewModel.shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID))
    }

    @MainActor
    @Test func liveChannelRegressionPreservesReadySessionWhileReceiving() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.remoteTransmittingContactIDs.insert(contactID)

        let existing = TurboChannelStateResponse(
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
            activeTransmitterUserId: "peer",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.receiving.rawValue,
            canTransmit: false
        )
        let incoming = TurboChannelStateResponse(
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
            status: ConversationState.idle.rawValue,
            canTransmit: false
        )

        #expect(
            viewModel.shouldPreserveLiveChannelState(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        )
    }

    @MainActor
    @Test func idleChannelRegressionDoesNotPreserveAbsentSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        let existing = TurboChannelStateResponse(
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
        let incoming = TurboChannelStateResponse(
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
            status: ConversationState.idle.rawValue,
            canTransmit: false
        )

        #expect(
            !viewModel.shouldPreserveLiveChannelState(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        )
    }

    @MainActor
    @Test func websocketIdleWithoutTransmitDoesNotResetCallSession() {
        let viewModel = PTTViewModel()

        #expect(
            !viewModel.shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: false,
                systemIsTransmitting: false
            )
        )
    }

    @MainActor
    @Test func websocketIdleDuringTransmitStillResetsTransmitSession() {
        let viewModel = PTTViewModel()

        #expect(
            viewModel.shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: true,
                systemIsTransmitting: false
            )
        )
        #expect(
            viewModel.shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: false,
                systemIsTransmitting: true
            )
        )
    }

    @MainActor
    @Test func failedOrClosedMediaSessionIsRecreatedBeforeReuse() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldRecreateMediaSession(connectionState: .failed("send failed")))
        #expect(viewModel.shouldRecreateMediaSession(connectionState: .closed))
        #expect(!viewModel.shouldRecreateMediaSession(connectionState: .connected))
    }

    @Test func mediaRuntimeResetClearsOutgoingAudioRoute() {
        let runtime = MediaRuntimeState()
        runtime.replaceSendAudioChunk(with: { _ in })

        #expect(runtime.hasSendAudioChunk)

        runtime.reset()

        #expect(!runtime.hasSendAudioChunk)
    }

    @MainActor
    @Test func pttStopFailureClassifierTreatsCodeFiveAsExpected() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 5)

        #expect(viewModel.isExpectedPTTStopFailure(error))
    }

    @MainActor
    @Test func pttChannelUnavailableClassifierTreatsCodeOneAsRecoverable() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 1)

        #expect(viewModel.isRecoverablePTTChannelUnavailable(error))
    }

    @Test func selectedPeerStateUsesLocalTransmitWhileBackendRefreshLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
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

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        #expect(selectedPeerState.phase == .transmitting)
    }

    @Test func selectedPeerStateUsesStartingTransmitUntilAudioTransportIsConnected() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
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
                    status: ConversationState.transmitting.rawValue,
                    canTransmit: true
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: true,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .startingTransmit)
        #expect(selectedPeerState.conversationState == .transmitting)
        #expect(selectedPeerState.statusMessage == "Establishing audio...")
        #expect(primaryAction.kind == .holdToTalk)
    }

    @Test func selectedPeerStateUsesWakeReadyWhilePeerDeviceIsNotConnected() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
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
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: false
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .wakeReady)
        #expect(selectedPeerState.conversationState == .ready)
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(selectedPeerState.allowsHoldToTalk)
        #expect(selectedPeerState.statusMessage == "Hold to talk to wake Blake")
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.label == "Hold To Talk")
        #expect(primaryAction.isEnabled)
    }

    @Test func pttWakeRuntimeBuffersAudioUntilActivation() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        #expect(runtime.shouldBufferAudioChunk(for: contactID))
        runtime.bufferAudioChunk("AQI=", for: contactID)
        runtime.bufferAudioChunk("AwQ=", for: contactID)

        let buffered = runtime.takeBufferedAudioChunks(for: contactID)

        #expect(buffered == ["AQI=", "AwQ="])
        #expect(runtime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)

        runtime.markAudioSessionActivated(for: channelUUID)

        #expect(runtime.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(runtime.shouldBufferAudioChunk(for: contactID) == false)
    }

    @Test func provisionalWakeCandidateStillBuffersAudioWithoutConfirmedPush() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload,
                hasConfirmedIncomingPush: false
            )
        )

        #expect(runtime.hasPendingWake(for: contactID))
        #expect(runtime.hasConfirmedIncomingPush(for: contactID) == false)
        #expect(runtime.shouldBufferAudioChunk(for: contactID))
    }

    @Test func interactiveMediaSessionAudioPolicyUsesPlayAndRecord() {
        let appManaged = MediaSessionAudioPolicy.configuration(
            activationMode: .appManaged,
            startupMode: .interactive
        )
        let systemActivated = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .interactive
        )

        #expect(appManaged.category == .playAndRecord)
        #expect(appManaged.mode == .default)
        #expect(appManaged.options == [.defaultToSpeaker, .allowBluetoothHFP])
        #expect(appManaged.shouldActivateSession == true)

        #expect(systemActivated.category == .playAndRecord)
        #expect(systemActivated.mode == .default)
        #expect(systemActivated.options == [.defaultToSpeaker, .allowBluetoothHFP])
        #expect(systemActivated.shouldActivateSession == false)
    }

    @Test func playbackOnlyMediaSessionAudioPolicyUsesPlaybackCategory() {
        let appManaged = MediaSessionAudioPolicy.configuration(
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        let systemActivated = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(appManaged.category == .playback)
        #expect(appManaged.mode == .default)
        #expect(appManaged.options.isEmpty)
        #expect(appManaged.shouldActivateSession == true)

        #expect(systemActivated.category == .playback)
        #expect(systemActivated.mode == .default)
        #expect(systemActivated.options.isEmpty)
        #expect(systemActivated.shouldActivateSession == false)
    }

    @Test func audioChunkSenderUsesUpdatedTransportHandler() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: nil,
            reportFailure: { _ in }
        )

        await sender.updateSendChunk { payload in
            await recorder.append(payload)
        }
        await sender.enqueue("chunk-1")
        await sender.enqueue("chunk-2")

        let payloads = await recorder.payloads
        #expect(payloads == ["chunk-1", "chunk-2"])
    }

    @MainActor
    @Test func incomingAudioChunkWaitsForPTTAudioActivationBeforeCreatingMediaSession() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                )
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["AQI="])
    }

    @MainActor
    @Test func pttAudioActivationCreatesSystemPlaybackSessionAndFlushesBufferedWakeAudio() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        var pendingPush = PendingIncomingPTTPush(
            contactID: contactID,
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        pendingPush.bufferedAudioChunks = ["AQI=", "AwQ="]
        viewModel.pttWakeRuntime.store(pendingPush)

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .systemActivated)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
    }

    @Test func mediaRuntimeDelaysRetryAfterRecentStartFailure() {
        let contactID = UUID()
        let context = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        let runtime = MediaRuntimeState()

        runtime.markStartupInFlight(context)
        runtime.markStartupFailed(context, message: "session activation failed")

        #expect(runtime.connectionState == .failed("session activation failed"))
        #expect(runtime.shouldDelayRetry(for: context, cooldown: 0.75))
        #expect(runtime.shouldDelayRetry(for: context, now: Date().addingTimeInterval(1.0), cooldown: 0.75) == false)
    }

    @Test func selectedPeerStateUsesTransmitSignalWhileReceiverRefreshLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
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

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        #expect(selectedPeerState.phase == .receiving)
    }

    @MainActor
    @Test func activeTransmitTargetMatchesSystemChannel() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-1",
            remoteUserID: "user-blake",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))

        #expect(viewModel.activeTransmitTarget(for: channelUUID) == target)
    }

    @MainActor
    @Test func activeTransmitTargetRejectsMismatchedSystemChannel() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-1",
            remoteUserID: "user-blake",
            channelUUID: UUID(),
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))

        #expect(viewModel.activeTransmitTarget(for: UUID()) == nil)
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

    @Test func pttReducerCapturesJoinFailureReasonAndContact() {
        let contactID = UUID()
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .failedToJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: .channelLimitReached
            )
        )

        #expect(transition.state.isJoined == false)
        #expect(transition.state.lastError == "Channel limit reached")
        #expect(
            transition.state.lastJoinFailure
                == PTTJoinFailure(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    reason: .channelLimitReached
                )
        )
        #expect(transition.effects == [.closeMediaSession])
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

    @Test func backendSyncReducerReconnectRefreshesSelectedSession() {
        let contactID = UUID()

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .webSocketStateChanged(.connected, selectedContactID: contactID)
        )

        #expect(
            transition.effects == [
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

    @Test func backendSyncReducerContactSummaryFailurePreservesLastKnownSnapshot() {
        let contactID = UUID()
        let summary = TurboContactSummaryResponse(
            userId: "user-peer",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel-1",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: true,
            requestCount: 1,
            isActiveConversation: false,
            badgeStatus: "requested"
        )
        var state = BackendSyncSessionState()
        state.syncState.contactSummaries[contactID] = summary

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .contactSummariesFailed("Contact sync failed: internal server error")
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
        #expect(transition.state.syncState.statusMessage == "Contact sync failed: internal server error")
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

    @Test func backendSyncReducerInviteFailurePreservesLastKnownRequests() {
        let contactID = UUID()
        let incomingInvite = makeInvite(direction: "incoming")
        let outgoingInvite = makeInvite(direction: "outgoing")
        let cooldownDeadline = Date(timeIntervalSince1970: 2_000)
        var state = BackendSyncSessionState()
        state.syncState.incomingInvites[contactID] = incomingInvite
        state.syncState.outgoingInvites[contactID] = outgoingInvite
        state.syncState.requestCooldownDeadlines[contactID] = cooldownDeadline

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesFailed("Invite sync failed: internal server error")
        )

        #expect(transition.state.syncState.incomingInvites[contactID] == incomingInvite)
        #expect(transition.state.syncState.outgoingInvites[contactID] == outgoingInvite)
        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == cooldownDeadline)
        #expect(transition.state.syncState.statusMessage == "Invite sync failed: internal server error")
    }

    @MainActor
    @Test func refreshContactSummariesFailurePreservesExistingSelectedContactState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )
        let summary = TurboContactSummaryResponse(
            userId: "user-avery",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel-1",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: true,
            requestCount: 1,
            isActiveConversation: false,
            badgeStatus: "requested"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.trackContact(contactID)
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        await viewModel.refreshContactSummaries()

        #expect(viewModel.selectedContact?.id == contactID)
        #expect(viewModel.contacts.map(\.id) == [contactID])
        #expect(viewModel.contacts.first?.isOnline == true)
        #expect(viewModel.backendSyncCoordinator.state.syncState.contactSummaries[contactID] == summary)
    }

    @MainActor
    @Test func refreshInvitesFailurePreservesExistingSelectedContactState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )
        let incomingInvite = makeInvite(direction: "incoming")
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.trackContact(contactID)
        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [BackendInviteUpdate(contactID: contactID, invite: incomingInvite)],
                outgoing: [],
                now: .now
            )
        )

        await viewModel.refreshInvites()

        #expect(viewModel.selectedContact?.id == contactID)
        #expect(viewModel.contacts.map(\.id) == [contactID])
        #expect(viewModel.backendSyncCoordinator.state.syncState.incomingInvites[contactID] == incomingInvite)
    }

    @Test func backendSyncReducerRetainsChannelStateOnRefreshFailure() {
        let contactID = UUID()
        let existingChannelState = makeChannelState(status: .ready, canTransmit: true)
        var state = BackendSyncSessionState()
        state.syncState.channelStates[contactID] = existingChannelState

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .channelStateFailed(contactID: contactID, message: "Channel sync failed: timeout")
        )

        #expect(transition.state.syncState.channelStates[contactID] == existingChannelState)
        #expect(transition.state.syncState.statusMessage == "Channel sync failed: timeout")
    }

    @Test func backendSyncStatePreservesJoinedMembershipAcrossConnectingRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: joinedChannelState.hasIncomingRequest,
            hasOutgoingRequest: joinedChannelState.hasOutgoingRequest,
            requestCount: joinedChannelState.requestCount,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: "connecting",
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == joinedChannelState)
    }

    @Test func backendSyncStatePreservesJoinedMembershipAcrossIncomingRequestRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 1,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: ConversationState.incomingRequest.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == joinedChannelState)
    }

    @Test func backendSyncStatePreservesPeerReadyAcrossIncomingRequestRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let peerReadyChannelState = TurboChannelStateResponse(
            channelId: "channel-1",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.incomingRequest.rawValue,
            canTransmit: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: peerReadyChannelState.channelId,
            selfUserId: peerReadyChannelState.selfUserId,
            peerUserId: peerReadyChannelState.peerUserId,
            peerHandle: peerReadyChannelState.peerHandle,
            selfOnline: peerReadyChannelState.selfOnline,
            peerOnline: peerReadyChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.incomingRequest.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(peerReadyChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == peerReadyChannelState)
    }

    @Test func backendSyncStatePreservesJoinedMembershipAcrossPeerJoinedConnectingRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: false,
            hasIncomingRequest: joinedChannelState.hasIncomingRequest,
            hasOutgoingRequest: joinedChannelState.hasOutgoingRequest,
            requestCount: joinedChannelState.requestCount,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: "connecting",
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == joinedChannelState)
    }

    @Test func backendSyncStatePreservesJoinedMembershipWhenPeerJoinsBeforeBackendCatchesUp() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 1,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: ConversationState.incomingRequest.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == joinedChannelState)
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
            relationship: .none,
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(activeOperation: .join(request: request), queuedJoinRequest: nil, lastError: nil),
            event: .joinRequested(request)
        )

        #expect(transition.state.activeOperation == .join(request: request))
        #expect(transition.effects.isEmpty)
    }

    @Test func backendCommandReducerQueuesUpdatedJoinForSameContact() {
        let contactID = UUID()
        let inFlightRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let queuedRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(activeOperation: .join(request: inFlightRequest), queuedJoinRequest: nil, lastError: nil),
            event: .joinRequested(queuedRequest)
        )

        #expect(transition.state.activeOperation == .join(request: inFlightRequest))
        #expect(transition.state.queuedJoinRequest == queuedRequest)
        #expect(transition.effects.isEmpty)
    }

    @Test func backendCommandReducerRunsQueuedJoinAfterOperationFinishes() {
        let contactID = UUID()
        let inFlightRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let queuedRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(
                activeOperation: .join(request: inFlightRequest),
                queuedJoinRequest: queuedRequest,
                lastError: nil
            ),
            event: .operationFinished
        )

        #expect(transition.state.activeOperation == .join(request: queuedRequest))
        #expect(transition.state.queuedJoinRequest == nil)
        #expect(transition.effects == [.join(queuedRequest)])
    }

    @MainActor
    @Test func backendJoinExecutionPlanTreatsOutgoingInviteAsRequestOnly() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: nil
        )

        #expect(plan == .requestOnly)
    }

    @MainActor
    @Test func backendJoinExecutionPlanTreatsIncomingInviteAsJoinSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            relationship: .incomingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: makeInvite(direction: "incoming"),
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: nil
        )

        #expect(plan == .joinSession)
    }

    @MainActor
    @Test func backendJoinExecutionPlanPromotesOutgoingInviteWhenPeerAlreadyJoined() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let currentChannel = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: true,
                hasIncomingRequest: false,
                hasOutgoingRequest: true,
                requestCount: 1,
                activeTransmitterUserId: nil,
                transmitLeaseExpiresAt: nil,
                status: ConversationState.requested.rawValue,
                canTransmit: false
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: currentChannel
        )

        #expect(plan == .joinSession)
    }

    @MainActor
    @Test func backendJoinExecutionPlanPromotesPeerReadyChannelWithoutInviteRelationship() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            relationship: .none,
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let currentChannel = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: true,
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

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: currentChannel
        )

        #expect(plan == .joinSession)
    }

    @MainActor
    @Test func inviteMatcherFindsIncomingInviteByHandleWhenCachedInviteIsMissing() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            relationship: .incomingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let invite = TurboInviteResponse(
            inviteId: "invite-1",
            fromUserId: "user-avery",
            fromHandle: "@avery",
            toUserId: "self",
            toHandle: "@blake",
            channelId: "channel-avery",
            status: "pending",
            direction: "incoming",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:00Z",
            updatedAt: nil,
            targetAvailability: nil,
            shouldAutoJoinPeer: nil,
            accepted: nil,
            pendingJoin: nil
        )

        #expect(viewModel.inviteMatchesJoinRequest(invite, request: request, direction: "incoming"))
    }

    @MainActor
    @Test func staleIncomingInviteAcceptFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldIgnoreIncomingInviteAcceptFailure(TurboBackendError.server("invite not found")))
        #expect(viewModel.shouldIgnoreIncomingInviteAcceptFailure(TurboBackendError.server(" Invite Not Found ")) )
    }

    @MainActor
    @Test func staleSupersededOutgoingInviteCancelFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldIgnoreInviteNotFoundFailure(TurboBackendError.server("invite not found")))
        #expect(viewModel.shouldIgnoreInviteNotFoundFailure(TurboBackendError.server(" Invite Not Found ")))
    }

    @MainActor
    @Test func nonStaleIncomingInviteAcceptFailureIsNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldIgnoreIncomingInviteAcceptFailure(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldIgnoreIncomingInviteAcceptFailure(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func unrelatedInviteCancelFailuresAreNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldIgnoreInviteNotFoundFailure(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldIgnoreInviteNotFoundFailure(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func backendJoinChannelNotFoundIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server("channel not found")))
        #expect(viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server(" Channel Not Found ")))
    }

    @MainActor
    @Test func backendJoinMetadataFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server("missing otherUserId or otherHandle")))
        #expect(viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server(" Missing OtherUserId Or OtherHandle ")))
    }

    @MainActor
    @Test func unrelatedBackendJoinFailuresAreNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.invalidResponse))
        #expect(!viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func transmitLeaseLossIsTreatedAsCleanStop() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatTransmitLeaseLossAsStop(TurboBackendError.server("no active transmit state for sender")))
        #expect(!viewModel.shouldTreatTransmitLeaseLossAsStop(TurboBackendError.server("channel already transmitting")))
    }

    @MainActor
    @Test func transmitBeginMembershipLossIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatTransmitBeginMembershipLossAsRecoverable(TurboBackendError.server("not a channel member")))
        #expect(!viewModel.shouldTreatTransmitBeginMembershipLossAsRecoverable(TurboBackendError.server("channel already transmitting")))
    }

    @MainActor
    @Test func inviteMatcherRejectsWrongDirection() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            relationship: .incomingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let invite = TurboInviteResponse(
            inviteId: "invite-1",
            fromUserId: "self",
            fromHandle: "@blake",
            toUserId: "user-avery",
            toHandle: "@avery",
            channelId: "channel-avery",
            status: "pending",
            direction: "outgoing",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:00Z",
            updatedAt: nil,
            targetAvailability: nil,
            shouldAutoJoinPeer: nil,
            accepted: nil,
            pendingJoin: nil
        )

        #expect(viewModel.inviteMatchesJoinRequest(invite, request: request, direction: "incoming") == false)
    }

    @MainActor
    @Test func backendSyncCancellationClassifierAcceptsTaskCancellation() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(CancellationError()))
    }

    @MainActor
    @Test func backendSyncCancellationClassifierAcceptsURLSessionCancellation() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(URLError(.cancelled)))
    }

    @MainActor
    @Test func backendSyncCancellationClassifierRejectsRealBackendFailures() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(TurboBackendError.server("boom")) == false)
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
            microphonePermission: .granted,
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
            microphonePermission: .granted,
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

    @Test func pttSystemPolicyReducerRetriesUploadWhenChannelBecomesKnownLater() {
        let received = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: nil)
        )

        #expect(received.state.latestTokenHex == "deadbeef")
        #expect(received.effects.isEmpty)

        let ready = PTTSystemPolicyReducer.reduce(
            state: received.state,
            event: .backendChannelReady("channel-1")
        )

        #expect(
            ready.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @Test func pttSystemPolicyReducerDoesNotReuploadSameTokenAndChannel() {
        let state = PTTSystemPolicyState(
            latestTokenHex: "deadbeef",
            lastTokenUploadError: nil,
            uploadedTokenHex: "deadbeef",
            uploadedBackendChannelID: "channel-1"
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .backendChannelReady("channel-1")
        )

        #expect(transition.effects.isEmpty)
    }

    @Test func pttWakeRuntimeUsesSystemActivatedModeAfterAudioSessionActivation() {
        let runtime = PTTWakeRuntimeState()
        let contactID = UUID()
        let otherContactID = UUID()
        let channelUUID = UUID()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-1",
                    activeSpeaker: "@blake",
                    senderUserId: "sender",
                    senderDeviceId: "device"
                )
            )
        )

        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)
        runtime.markAudioSessionActivated(for: channelUUID)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(runtime.mediaSessionActivationMode(for: otherContactID) == .appManaged)
        runtime.clear(for: contactID)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)
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

    @Test func pttPushPayloadParsesTransmitStart() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "event": "transmit-start",
                "channelId": "channel-1",
                "activeSpeaker": "@blake",
                "senderUserId": "user-blake",
                "senderDeviceId": "device-blake",
            ]
        )

        #expect(payload?.event == .transmitStart)
        #expect(payload?.channelId == "channel-1")
        #expect(payload?.participantName == "@blake")
    }

    @Test func pttPushPayloadParsesLeaveChannel() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "type": "leave-channel",
                "channelId": "channel-1",
            ]
        )

        #expect(payload?.event == .leaveChannel)
        #expect(payload?.channelId == "channel-1")
    }

    @Test func pttPushPayloadRejectsUnknownEvent() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "event": "unknown-event",
                "channelId": "channel-1",
            ]
        )

        #expect(payload == nil)
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

    @MainActor
    @Test func diagnosticsExportIncludesStateTimeline() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "idle",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedPeerStatus": "Blake is online"
            ]
        )

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "peerReady",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "connecting",
                "backendSelfJoined": "false",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedPeerStatus": "Blake is ready to connect"
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=peerReady")

        #expect(exported.contains("STATE SNAPSHOT"))
        #expect(exported.contains("STATE TIMELINE"))
        #expect(exported.contains("[selected-peer-sync]"))
        #expect(exported.contains("phase=peerReady"))
        #expect(exported.contains("status=Blake is ready to connect"))
    }

    @MainActor
    @Test func simulatorPTTClientJoinsAndTransmits() async throws {
        let recorder = TestPTTCallbackRecorder()
        let client = SimulatorPTTSystemClient()
        let channelID = UUID()

        try await client.configure(callbacks: recorder.callbacks)
        try client.joinChannel(channelUUID: channelID, name: "Avery")
        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(recorder.joinedChannelIDs == [channelID])
        #expect(recorder.joinFailures.isEmpty)

        try client.beginTransmitting(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.didBeginTransmittingChannelIDs == [channelID])

        try client.stopTransmitting(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.didEndTransmittingChannelIDs == [channelID])

        try client.leaveChannel(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.leftChannelIDs == [channelID])
    }

    @MainActor
    @Test func simulatorPTTClientRejectsSecondConcurrentChannel() async throws {
        let recorder = TestPTTCallbackRecorder()
        let client = SimulatorPTTSystemClient()
        let firstChannelID = UUID()
        let secondChannelID = UUID()

        try await client.configure(callbacks: recorder.callbacks)
        try client.joinChannel(channelUUID: firstChannelID, name: "Avery")
        try await Task.sleep(nanoseconds: 250_000_000)

        try client.joinChannel(channelUUID: secondChannelID, name: "Blake")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(recorder.joinedChannelIDs == [firstChannelID])
        #expect(recorder.joinFailures.count == 1)
        #expect(recorder.joinFailures.first?.channelID == secondChannelID)
        #expect((recorder.joinFailures.first?.error as NSError?)?.code == 2)
    }

    @MainActor
    @Test func simulatorBuildUsesStubMediaSessionEvenWhenWebSocketIsAvailable() {
        let session = makeDefaultMediaSession(supportsWebSocket: true) { _ in }

        #if targetEnvironment(simulator)
        #expect(session is StubRelayMediaSession)
        #else
        #expect(session is PCMWebSocketMediaSession)
        #endif
    }

    @MainActor
    @Test func simulatorDistributedJoinScenario() async throws {
        guard let runtimeConfig = loadSimulatorScenarioRuntimeConfig() else {
            return
        }
        let specs = try loadSimulatorScenarioSpecs(runtimeConfig: runtimeConfig)
        for spec in specs {
            try await executeSimulatorScenario(spec)
        }
    }
}

@MainActor
private final class TestPTTCallbackRecorder {
    struct JoinFailure {
        let channelID: UUID
        let error: Error
    }

    var joinedChannelIDs: [UUID] = []
    var leftChannelIDs: [UUID] = []
    var didBeginTransmittingChannelIDs: [UUID] = []
    var didEndTransmittingChannelIDs: [UUID] = []
    var joinFailures: [JoinFailure] = []
    var incomingPushes: [(UUID, TurboPTTPushPayload)] = []

    var callbacks: PTTSystemClientCallbacks {
        PTTSystemClientCallbacks(
            receivedEphemeralPushToken: { _ in },
            receivedIncomingPush: { [weak self] channelID, payload in
                self?.incomingPushes.append((channelID, payload))
            },
            didJoinChannel: { [weak self] channelID, _ in
                self?.joinedChannelIDs.append(channelID)
            },
            didLeaveChannel: { [weak self] channelID, _ in
                self?.leftChannelIDs.append(channelID)
            },
            failedToJoinChannel: { [weak self] channelID, error in
                self?.joinFailures.append(JoinFailure(channelID: channelID, error: error))
            },
            failedToLeaveChannel: { _, _ in },
            didBeginTransmitting: { [weak self] channelID, _ in
                self?.didBeginTransmittingChannelIDs.append(channelID)
            },
            didEndTransmitting: { [weak self] channelID, _ in
                self?.didEndTransmittingChannelIDs.append(channelID)
            },
            failedToBeginTransmitting: { _, _ in },
            failedToStopTransmitting: { _, _ in },
            didActivateAudioSession: { _ in },
            didDeactivateAudioSession: { _ in },
            descriptorForRestoredChannel: { _ in
                PTChannelDescriptor(name: "Restored", image: nil)
            },
            restoredChannel: { _ in }
        )
    }
}

private struct ScenarioFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private struct SimulatorScenarioConfig: Decodable {
    let name: String
    let baseURL: URL
    let participants: [String: SimulatorScenarioParticipant]
    let steps: [SimulatorScenarioStep]
}

private struct SimulatorScenarioParticipant: Decodable {
    let handle: String
    let deviceId: String
}

private struct SimulatorScenarioStep: Decodable {
    let description: String
    let actions: [SimulatorScenarioAction]
    let expectEventually: [String: SimulatorScenarioExpectation]?
}

private struct SimulatorScenarioAction: Decodable {
    let actor: String
    let type: String
    let peer: String?
}

private struct SimulatorScenarioExpectation: Decodable {
    let selectedHandle: String?
    let phase: String?
    let isJoined: Bool?
    let isTransmitting: Bool?
    let canTransmitNow: Bool?
}

private enum SimulatorScenarioPhaseMatch {
    case exact
    case progressed
}

private struct SimulatorScenarioDiagnosticsArtifact: Codable {
    let scenarioName: String
    let handle: String
    let deviceId: String
    let baseURL: String
    let selectedHandle: String?
    let appVersion: String
    let snapshot: String
    let transcript: String
}

private struct SimulatorScenarioRuntimeConfig: Decodable {
    let enabledUntilEpochSeconds: TimeInterval
    let filter: String?
    let baseURL: URL?
    let handleA: String?
    let handleB: String?
    let deviceIDA: String?
    let deviceIDB: String?
}

private let simulatorScenarioRuntimeConfigURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".scenario-runtime-config.json", isDirectory: false)

@MainActor
private func makeSimulatorScenarioViewModel(baseURL: URL, handle: String, deviceID: String) -> PTTViewModel {
    let viewModel = PTTViewModel()
    viewModel.replaceBackendConfig(
        with: TurboBackendConfig(
            baseURL: baseURL,
            devUserHandle: handle,
            deviceID: deviceID
        )
    )
    return viewModel
}

private func loadSimulatorScenarioRuntimeConfig() -> SimulatorScenarioRuntimeConfig? {
    guard
        let data = try? Data(contentsOf: simulatorScenarioRuntimeConfigURL),
        let config = try? JSONDecoder().decode(SimulatorScenarioRuntimeConfig.self, from: data)
    else {
        return nil
    }

    guard Date().timeIntervalSince1970 <= config.enabledUntilEpochSeconds else {
        return nil
    }

    return config
}

private func loadSimulatorScenarioSpecs(runtimeConfig: SimulatorScenarioRuntimeConfig) throws -> [SimulatorScenarioConfig] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenariosDirectory = root.appendingPathComponent("scenarios", isDirectory: true)
    let scenarioFiles =
        try FileManager.default.contentsOfDirectory(at: scenariosDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let decoder = JSONDecoder()
    let allSpecs = try scenarioFiles.map { fileURL in
        let data = try Data(contentsOf: fileURL)
        let spec = try decoder.decode(SimulatorScenarioConfig.self, from: data)
        return applyScenarioRuntimeConfig(runtimeConfig, to: spec)
    }
    guard !allSpecs.isEmpty else {
        throw ScenarioFailure(message: "No simulator scenario specs were found in \(scenariosDirectory.path)")
    }

    let filter = runtimeConfig.filter?
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard let filter, !filter.isEmpty else {
        return allSpecs
    }

    let filtered = allSpecs.filter { spec in
        filter.contains(spec.name)
    }
    guard !filtered.isEmpty else {
        throw ScenarioFailure(
            message: "No simulator scenarios matched filter \(filter.joined(separator: ",")) in \(scenariosDirectory.path)"
        )
    }
    return filtered
}

private func applyScenarioRuntimeConfig(
    _ runtimeConfig: SimulatorScenarioRuntimeConfig,
    to spec: SimulatorScenarioConfig
) -> SimulatorScenarioConfig {
    let overriddenBaseURL = runtimeConfig.baseURL ?? spec.baseURL

    let participantOverrides: [String: (handle: String?, deviceId: String?)] = [
        "a": (
            runtimeConfig.handleA,
            runtimeConfig.deviceIDA
        ),
        "b": (
            runtimeConfig.handleB,
            runtimeConfig.deviceIDB
        ),
    ]

    let overriddenParticipants = Dictionary(uniqueKeysWithValues: spec.participants.map { actor, participant in
        let overrides = participantOverrides[actor] ?? (nil, nil)
        return (
            actor,
            SimulatorScenarioParticipant(
                handle: overrides.handle ?? participant.handle,
                deviceId: overrides.deviceId ?? participant.deviceId
            )
        )
    })

    return SimulatorScenarioConfig(
        name: spec.name,
        baseURL: overriddenBaseURL,
        participants: overriddenParticipants,
        steps: spec.steps
    )
}

@MainActor
private func executeSimulatorScenario(_ spec: SimulatorScenarioConfig) async throws {
    for participant in spec.participants.values {
        try await resetAllDevelopmentState(baseURL: spec.baseURL, handle: participant.handle)
    }

    let viewModels = Dictionary(uniqueKeysWithValues: spec.participants.map { actor, participant in
        (
            actor,
            makeSimulatorScenarioViewModel(
                baseURL: spec.baseURL,
                handle: participant.handle,
                deviceID: participant.deviceId
            )
        )
    })

    let participants = Array(viewModels.values)
    do {
        for participant in participants {
            await participant.initializeIfNeeded()
        }
        try await stabilizeScenario(participants)
        try await waitForScenario(
            "participants become mutually discoverable",
            participants: participants,
            timeoutNanoseconds: 60_000_000_000
        ) {
            await scenarioParticipantsAreDiscoverable(spec: spec, viewModels: viewModels)
        }

        for step in spec.steps {
            for action in step.actions {
                guard let participant = viewModels[action.actor] else {
                    throw ScenarioFailure(message: "Scenario references unknown actor \(action.actor)")
                }

                switch action.type {
                case "openPeer":
                    guard let peerActor = action.peer,
                          let peer = spec.participants[peerActor] else {
                        throw ScenarioFailure(message: "openPeer requires a known peer actor")
                    }
                    await participant.openContact(handle: peer.handle)
                case "connect":
                    participant.joinChannel()
                case "disconnect":
                    participant.disconnect()
                case "declineRequest":
                    await participant.declineIncomingRequestForSelectedContact()
                case "cancelRequest":
                    await participant.cancelOutgoingRequestForSelectedContact()
                case "beginTransmit":
                    participant.beginTransmit()
                case "endTransmit":
                    participant.endTransmit()
                default:
                    throw ScenarioFailure(message: "Unknown scenario action type \(action.type)")
                }
            }

            if scenarioStepRequiresImmediateStabilization(step) {
                try await stabilizeScenario(participants)
            }

            if let expectations = step.expectEventually {
                try await waitForScenario(step.description, participants: participants) {
                    scenarioExpectationsMatch(expectations, viewModels: viewModels)
                }
            }
        }

        try await publishScenarioDiagnosticsArtifacts(spec: spec, viewModels: viewModels)
        await tearDownSimulatorScenarioParticipants(participants)
    } catch {
        try? await publishScenarioDiagnosticsArtifacts(spec: spec, viewModels: viewModels)
        await tearDownSimulatorScenarioParticipants(participants)
        throw error
    }
}

private func scenarioStepRequiresImmediateStabilization(_ step: SimulatorScenarioStep) -> Bool {
    !step.actions.contains { action in
        action.type == "beginTransmit" || action.type == "endTransmit"
    }
}

@MainActor
private func publishScenarioDiagnosticsArtifacts(
    spec: SimulatorScenarioConfig,
    viewModels: [String: PTTViewModel]
) async throws {
    for (actor, participant) in viewModels {
        let expectedDeviceID = spec.participants[actor]?.deviceId ?? "<missing>"
        let expectedHandle = spec.participants[actor]?.handle ?? participant.currentDevUserHandle
        let artifact = SimulatorScenarioDiagnosticsArtifact(
            scenarioName: spec.name,
            handle: expectedHandle,
            deviceId: expectedDeviceID,
            baseURL: spec.baseURL.absoluteString,
            selectedHandle: participant.selectedContact?.handle,
            appVersion: "scenario:\(spec.name)",
            snapshot: participant.diagnosticsSnapshot,
            transcript: participant.diagnosticsTranscript
        )
        try await publishScenarioDiagnosticsArtifact(artifact)
        try await verifyScenarioDiagnosticsArtifactPublished(
            baseURL: spec.baseURL,
            handle: artifact.handle,
            deviceID: artifact.deviceId
        )
    }
}

@MainActor
private func scenarioParticipantsAreDiscoverable(
    spec: SimulatorScenarioConfig,
    viewModels: [String: PTTViewModel]
) async -> Bool {
    for (actor, participant) in viewModels {
        guard let backend = participant.backendServices else { return false }
        for (peerActor, peer) in spec.participants where peerActor != actor {
            do {
                _ = try await backend.lookupUser(handle: peer.handle)
            } catch {
                return false
            }
        }
    }
    return true
}

@MainActor
private func tearDownSimulatorScenarioParticipants(_ participants: [PTTViewModel]) async {
    for participant in participants {
        participant.resetLocalDevState(backendStatus: "Scenario teardown")
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
}

@MainActor
private func scenarioExpectationsMatch(
    _ expectations: [String: SimulatorScenarioExpectation],
    viewModels: [String: PTTViewModel]
) -> Bool {
    for (actor, expected) in expectations {
        guard let participant = viewModels[actor] else { return false }

        if let selectedHandle = expected.selectedHandle {
            guard participant.selectedContact?.handle == selectedHandle else { return false }
        }

        var phaseMatch: SimulatorScenarioPhaseMatch = .exact
        if let phase = expected.phase {
            guard let selectedContact = participant.selectedContact else { return false }
            let actualPhase = participant.selectedPeerState(for: selectedContact.id).phase
            guard let matched = simulatorScenarioPhaseMatch(expected: phase, actual: actualPhase) else {
                return false
            }
            phaseMatch = matched
        }

        if let isJoined = expected.isJoined {
            if !(phaseMatch == .progressed && isJoined == false) && participant.isJoined != isJoined {
                return false
            }
        }

        if let isTransmitting = expected.isTransmitting {
            if !(phaseMatch == .progressed && isTransmitting == false) && participant.isTransmitting != isTransmitting {
                return false
            }
        }

        if let canTransmitNow = expected.canTransmitNow {
            guard let selectedContact = participant.selectedContact else { return false }
            if !(phaseMatch == .progressed && canTransmitNow == false)
                && participant.canTransmitNow(for: selectedContact.id) != canTransmitNow
            {
                return false
            }
        }
    }

    return true
}

private func simulatorScenarioPhaseMatch(
    expected expectedPhase: String,
    actual actualPhase: SelectedPeerPhase
) -> SimulatorScenarioPhaseMatch? {
    let actual = String(describing: actualPhase)
    if actual == expectedPhase {
        return .exact
    }

    guard
        let expectedRank = simulatorScenarioTransientPhaseRank(expectedPhase),
        let actualRank = simulatorScenarioTransientPhaseRank(actual)
    else {
        return nil
    }

    return actualRank >= expectedRank ? .progressed : nil
}

private func simulatorScenarioTransientPhaseRank(_ phase: String) -> Int? {
    switch phase {
    case "requested", "incomingRequest":
        return 0
    case "peerReady", "waitingForPeer":
        return 1
    case "ready":
        return 2
    default:
        return nil
    }
}

private enum DevelopmentResetEndpoint {
    case resetAll
    case resetState

    var path: String {
        switch self {
        case .resetAll:
            return "/v1/dev/reset-all"
        case .resetState:
            return "/v1/dev/reset-state"
        }
    }

    var label: String {
        switch self {
        case .resetAll:
            return "reset-all"
        case .resetState:
            return "reset-state"
        }
    }
}

private func resetAllDevelopmentState(baseURL: URL, handle: String) async throws {
    if shouldUseResetStateOnly(baseURL: baseURL) {
        try await performDevelopmentReset(
            endpoint: .resetState,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 3
        )
        return
    }

    do {
        try await performDevelopmentReset(
            endpoint: .resetAll,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 2
        )
    } catch let error as ScenarioFailure {
        let message = error.message.lowercased()
        let shouldFallbackToResetState =
            message.contains("reset-all")
            && (message.contains("failed") || message.contains("timed out"))
        guard shouldFallbackToResetState else { throw error }

        try await performDevelopmentReset(
            endpoint: .resetState,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 5
        )
    }
}

private func shouldUseResetStateOnly(baseURL: URL) -> Bool {
    guard let host = baseURL.host?.lowercased() else { return false }
    return host != "localhost" && host != "127.0.0.1"
}

private func performDevelopmentReset(
    endpoint: DevelopmentResetEndpoint,
    baseURL: URL,
    handle: String,
    maxAttempts: Int
) async throws {
    let timeoutInterval: TimeInterval = switch endpoint {
    case .resetAll:
        8
    case .resetState:
        12
    }
    for attempt in 1...maxAttempts {
        let url = baseURL.appending(path: endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue(handle, forHTTPHeaderField: "x-turbo-user-handle")
        request.setValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ScenarioFailure(message: "\(endpoint.label) for \(handle) returned a non-HTTP response")
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return
            }

            let payload = String(data: data, encoding: .utf8) ?? "<empty>"
            let isRetriable = httpResponse.statusCode >= 500 && attempt < maxAttempts
            if isRetriable {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                continue
            }

            throw ScenarioFailure(message: "\(endpoint.label) for \(handle) failed: \(httpResponse.statusCode) \(payload)")
        } catch let scenarioFailure as ScenarioFailure {
            throw scenarioFailure
        } catch {
            let isFinalAttempt = attempt == maxAttempts
            if isFinalAttempt {
                throw ScenarioFailure(
                    message: "\(endpoint.label) for \(handle) failed after \(maxAttempts) attempts: \(error.localizedDescription)"
                )
            }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
        }
    }

    throw ScenarioFailure(message: "\(endpoint.label) for \(handle) failed after \(maxAttempts) attempts")
}

@MainActor
private func stabilizeScenario(_ participants: [PTTViewModel]) async throws {
    for participant in participants {
        await participant.refreshContactSummaries()
        await participant.refreshInvites()
        if let selectedContactID = participant.selectedContactId {
            await participant.refreshChannelState(for: selectedContactID)
        }
        participant.updateStatusForSelectedContact()
    }
    try await Task.sleep(nanoseconds: 300_000_000)
}

@MainActor
private func requireSelectedContactID(in viewModel: PTTViewModel, expectedHandle: String) throws -> UUID {
    guard let selectedContact = viewModel.selectedContact else {
        throw ScenarioFailure(message: "Expected selected contact \(expectedHandle), but selection was empty")
    }
    guard selectedContact.handle == expectedHandle else {
        throw ScenarioFailure(
            message: "Expected selected contact \(expectedHandle), got \(selectedContact.handle)"
        )
    }
    return selectedContact.id
}

@MainActor
private func waitForScenario(
    _ description: String,
    participants: [PTTViewModel],
    timeoutNanoseconds: UInt64 = 30_000_000_000,
    pollNanoseconds: UInt64 = 500_000_000,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    let snapshotSummary = scenarioSnapshotSummary(participants)
    throw ScenarioFailure(
        message: "Timed out waiting for scenario step: \(description)\n\(snapshotSummary)"
    )
}

@MainActor
private func scenarioSnapshotSummary(_ participants: [PTTViewModel]) -> String {
    participants.map { participant in
        let selectedContact = participant.selectedContact
        let selectedPeerState = selectedContact.map { participant.selectedPeerState(for: $0.id) }
        let selectedChannelState = selectedContact.flatMap { participant.channelStateByContactID[$0.id] }
        let fields = [
            "devUserHandle=\(participant.currentDevUserHandle)",
            "selectedContact=\(selectedContact?.handle ?? "none")",
            "selectedPeerPhase=\(selectedPeerState.map { String(describing: $0.phase) } ?? "idle")",
            "selectedPeerStatus=\(selectedPeerState?.statusMessage ?? "Ready to connect")",
            "pendingAction=\(String(describing: participant.sessionCoordinator.pendingAction))",
            "isJoined=\(participant.isJoined)",
            "isTransmitting=\(participant.isTransmitting)",
            "backendChannelStatus=\(selectedChannelState?.status ?? "none")",
            "backendSelfJoined=\(selectedChannelState.map { String($0.selfJoined) } ?? "none")",
            "backendPeerJoined=\(selectedChannelState.map { String($0.peerJoined) } ?? "none")",
            "backendPeerDeviceConnected=\(selectedChannelState.map { String($0.peerDeviceConnected) } ?? "none")",
            "systemSession=\(String(describing: participant.systemSessionState))",
            "localJoinFailure=\(participant.pttCoordinator.state.lastJoinFailure.map { String(describing: $0) } ?? "none")",
        ]
        return fields.joined(separator: " ")
    }
    .joined(separator: "\n")
}

private func publishScenarioDiagnosticsArtifact(_ artifact: SimulatorScenarioDiagnosticsArtifact) async throws {
    guard let baseURL = URL(string: artifact.baseURL) else {
        throw ScenarioFailure(message: "Invalid base URL for scenario diagnostics upload: \(artifact.baseURL)")
    }
    let endpointURL = baseURL.appending(path: "/v1/dev/diagnostics")
    let requestPayload: [String: Any?] = [
        "deviceId": artifact.deviceId,
        "appVersion": artifact.appVersion,
        "backendBaseURL": artifact.baseURL,
        "selectedHandle": artifact.selectedHandle,
        "snapshot": artifact.snapshot,
        "transcript": artifact.transcript,
    ]
    let body = try JSONSerialization.data(withJSONObject: requestPayload.compactMapValues { $0 })
    var request = URLRequest(url: endpointURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(artifact.handle, forHTTPHeaderField: "x-turbo-user-handle")
    request.setValue("Bearer \(artifact.handle)", forHTTPHeaderField: "Authorization")
    request.httpBody = body

    let (data, _) = try await performScenarioDiagnosticsRequest(
        request,
        label: "upload",
        handle: artifact.handle,
        deviceID: artifact.deviceId
    )
    let responsePayload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let report = responsePayload?["report"] as? [String: Any]
    let reportedDeviceID = report?["deviceId"] as? String
    guard reportedDeviceID == artifact.deviceId else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw ScenarioFailure(
            message: "Scenario diagnostics upload returned unexpected report for \(artifact.handle) expected \(artifact.deviceId) got \(reportedDeviceID ?? "none"): \(body)"
        )
    }
}

private func verifyScenarioDiagnosticsArtifactPublished(baseURL: URL, handle: String, deviceID: String) async throws {
    let endpointURL = baseURL.appending(path: "/v1/dev/diagnostics/latest/\(deviceID)/")
    var request = URLRequest(url: endpointURL)
    request.httpMethod = "GET"
    request.setValue(handle, forHTTPHeaderField: "x-turbo-user-handle")
    request.setValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")

    let (data, _) = try await performScenarioDiagnosticsRequest(
        request,
        label: "verification",
        handle: handle,
        deviceID: deviceID
    )
    let responsePayload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let report = responsePayload?["report"] as? [String: Any]
    let reportedDeviceID = report?["deviceId"] as? String
    guard reportedDeviceID == deviceID else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw ScenarioFailure(
            message: "Scenario diagnostics verification returned unexpected report for \(handle) expected \(deviceID) got \(reportedDeviceID ?? "none"): \(body)"
        )
    }
}

private func performScenarioDiagnosticsRequest(
    _ request: URLRequest,
    label: String,
    handle: String,
    deviceID: String,
    maxAttempts: Int = 3
) async throws -> (Data, HTTPURLResponse) {
    for attempt in 1...maxAttempts {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ScenarioFailure(
                    message: "Scenario diagnostics \(label) returned a non-HTTP response for \(handle) \(deviceID)"
                )
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return (data, httpResponse)
            }

            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            let isRetriable = httpResponse.statusCode >= 500 && attempt < maxAttempts
            if isRetriable {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
                continue
            }
            throw ScenarioFailure(
                message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID): \(httpResponse.statusCode) \(body)"
            )
        } catch let scenarioFailure as ScenarioFailure {
            throw scenarioFailure
        } catch {
            if attempt == maxAttempts {
                throw ScenarioFailure(
                    message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID) after \(maxAttempts) attempts: \(error.localizedDescription)"
                )
            }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
        }
    }

    throw ScenarioFailure(
        message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID) after \(maxAttempts) attempts"
    )
}

private func makeChannelState(
    status: ConversationState,
    canTransmit: Bool,
    selfJoined: Bool = true,
    peerJoined: Bool = true,
    peerDeviceConnected: Bool = true,
    hasIncomingRequest: Bool = false,
    hasOutgoingRequest: Bool = false
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
        hasIncomingRequest: hasIncomingRequest,
        hasOutgoingRequest: hasOutgoingRequest,
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

private func makeUnreachableBackendConfig() -> TurboBackendConfig {
    TurboBackendConfig(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        devUserHandle: "@self",
        deviceID: "test-device"
    )
}
