import Foundation
import Testing
import PushToTalk
import AVFAudio
import UIKit
@testable import BeepBeep

@MainActor
struct TurboTests {

    @Test func audioOutputPreferenceCyclesBetweenSpeakerAndPhone() {
        #expect(AudioOutputPreference.speaker.next == .phone)
        #expect(AudioOutputPreference.phone.next == .speaker)
        #expect(AudioOutputPreference.speaker.buttonLabel == "Speaker")
        #expect(AudioOutputPreference.phone.buttonLabel == "Phone")
    }

    @Test func speakerOverridePlanSkipsOverrideWhenSpeakerAlreadyActive() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.builtInSpeaker]
        )

        #expect(!plan.shouldApplySpeakerOverride)
    }

    @Test func speakerOverridePlanRequestsOverrideWhenReceiverIsActive() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.builtInReceiver]
        )

        #expect(plan.shouldApplySpeakerOverride)
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

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: contactID)))
    }

    @Test func globalExplicitLeaveBlocksAutoRejoin() {
        var coordinator = SessionCoordinatorState()

        coordinator.markExplicitLeave(contactID: nil)

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: nil)))
        #expect(coordinator.autoRejoinContactID(afterLeaving: nil) == nil)
    }

    @Test func selectingContactDoesNotClearGlobalExplicitLeave() {
        var coordinator = SessionCoordinatorState()
        let selectedContactID = UUID()

        coordinator.markExplicitLeave(contactID: nil)
        coordinator.select(contactID: selectedContactID)

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: nil)))
    }

    @Test func reconciledTeardownBlocksAutoRejoinUntilLeaveCompletes() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueConnect(contactID: contactID)
        coordinator.markReconciledTeardown(contactID: contactID)

        #expect(coordinator.pendingAction == .leave(.reconciledTeardown(contactID: contactID)))
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

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: contactID)))
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
            pendingAction: .leave(.explicit(contactID: contactID)),
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
                pendingAction: .leave(.explicit(contactID: contactID)),
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

    @Test func selectedPeerStateWaitsForRemoteAudioReadinessBeforeEnablingTransmit() {
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
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .unknown)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Blake's audio...")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateBecomesReadyWhenRemoteAudioReadinessArrives() {
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
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
    }

    @Test func selectedPeerStateUsesWakeReadyWhenRemoteAudioIsWakeCapableAndBackendWakeIsAvailable() {
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
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .ready,
                        canTransmit: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Blake")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateUsesWakeReadyWhenRemoteAudioIsWakeCapableEvenIfPeerConnectivityLags() {
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
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Blake")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateUsesWakeReadyWhenLocalPrewarmIsColdButRemoteIsWakeCapable() {
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
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .idle,
                localMediaWarmupState: .cold,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Blake")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk)
    }

    @Test func selectedPeerStateWaitsWhenRemoteAudioLooksWakeCapableButBackendWakeIsUnavailable() {
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
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .unavailable
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Blake's audio...")
        #expect(state.canTransmitNow == false)
        #expect(!state.allowsHoldToTalk)
    }

    @Test func incomingReceiverReadySignalUpdatesRemoteReadinessState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .waiting)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "test"
            )
        )

        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .ready)
    }

    @Test func backgroundReceiverNotReadySignalUpdatesRemoteReadinessStateToWakeCapable() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .wakeCapable)
    }

    @MainActor
    @Test func receiverNotReadyBackgroundClosureReleasesLocalInteractivePrewarm() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .wakeCapable)
    }

    @MainActor
    @Test func receiverReadySignalResumesLocalInteractivePrewarmAfterBackgroundClosure() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "media-connected"
            )
        )

        await Task.yield()
        await Task.yield()

        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @Test func fetchedWaitingReadinessPreservesExistingWakeCapableRemoteState() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .waiting,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
    }

    @Test func fetchedWaitingReadinessPreservesExistingWakeCapabilityWhenRefreshDropsIt() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .waiting,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
        #expect(merged?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @Test func fetchedReadyReadinessReplacesExistingWakeCapableRemoteState() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .ready)
    }

    @Test func fetchedWaitingReadinessDoesNotPreserveWakeCapableWhenPeerDeviceIsConnected() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .waiting,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true
        )

        #expect(merged?.remoteAudioReadiness == .waiting)
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

    @Test func alignedSessionDoesNotTearDownOnTransientPeerDeparture() {
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

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
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
            pendingAction: .leave(.explicit(contactID: contactID)),
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
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
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

    @Test func localTransmitSuppressesDriftTeardownDuringBackendWaitingForPeer() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .transmitting,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func peerTransmitSnapshotDoesNotTearDownAlignedLocalSession() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .receiving,
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
                    status: .receiving,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
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
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
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
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
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
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .ready, canTransmit: true),
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
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

    @Test func selectedPeerStateShowsWakeReadyWhenPeerDeviceConnectivityLags() {
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
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.conversationState == .ready)
        #expect(state.statusMessage == "Hold to talk to wake Avery")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateWaitsWhenPeerIsDisconnectedWithoutWakeCapability() {
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
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Avery to reconnect")
        #expect(state.canTransmitNow == false)
    }

    @Test func ensureContactClearsStaleBackendChannelMetadataWhenRefreshedWithoutChannel() {
        let staleChannelID = "channel-stale"
        let existing = [
            Contact(
                id: Contact.stableID(for: "@blake"),
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: staleChannelID),
                backendChannelId: staleChannelID,
                remoteUserId: "user-blake"
            )
        ]

        let result = ContactDirectory.ensureContact(
            handle: "@blake",
            remoteUserId: "user-blake-2",
            channelId: "",
            existingContacts: existing
        )

        let refreshed = try! #require(result.contacts.first)
        #expect(refreshed.remoteUserId == "user-blake-2")
        #expect(refreshed.backendChannelId == nil)
        #expect(refreshed.channelId != ContactDirectory.stableChannelUUID(for: staleChannelID))
    }

    @Test func backendSyncStateClearsStaleChannelStateWhenContactSummaryHasNoChannel() {
        let contactID = UUID()
        var state = BackendSyncState()
        state.channelStates[contactID] = makeChannelState(status: .ready, canTransmit: true)

        state.applyContactSummaries([
            contactID: TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: nil,
                isOnline: true,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "online"
            )
        ])

        #expect(state.channelStates[contactID] == nil)
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
            .localSessionUpdated(
                isJoined: false,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: nil,
                pendingAction: .none,
                localJoinFailure: nil
            ),
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
            .localSessionUpdated(
                isJoined: false,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: nil,
                pendingAction: .connect(.joiningLocal(contactID: contactID)),
                localJoinFailure: nil
            ),
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
            .localSessionUpdated(
                isJoined: true,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: contactID,
                pendingAction: .none,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let waitingState = reduceSelectedPeerState(waitingEvents)
        #expect(waitingState.selectedPeerState.phase == .waitingForPeer)
        #expect(waitingState.selectedPeerState.canTransmitNow == false)

        let joinedState = SelectedPeerReducer.reduce(
            state: waitingState,
            event: .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: UUID()),
                matchesSelectedContact: true
            )
        ).state
        let readyState = SelectedPeerReducer.reduce(
            state: joinedState,
            event: .mediaStateUpdated(.connected)
        ).state
        let receiverReadyState = SelectedPeerReducer.reduce(
            state: readyState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            )
        ).state

        #expect(receiverReadyState.selectedPeerState.phase == .ready)
        #expect(receiverReadyState.selectedPeerState.statusMessage == "Connected")
        #expect(receiverReadyState.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerPrefersTransmitPhaseOverWakeReadyWhileLocallyTransmitting() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                localIsTransmitting: true,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: contactID,
                pendingAction: .none,
                localJoinFailure: nil
            ),
            .localTransmitContextUpdated(
                phase: .active(contactID: contactID),
                systemIsTransmitting: true,
                pttAudioSessionActive: true
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.selectedPeerState.phase == .transmitting)
        #expect(state.selectedPeerState.statusMessage == "Talking to Avery")
    }

    @Test func selectedPeerReducerUsesWakePhaseWhileLocalTransmitIsStillStarting() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                localIsTransmitting: true,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: contactID,
                pendingAction: .none,
                localJoinFailure: nil
            ),
            .localTransmitContextUpdated(
                phase: .active(contactID: contactID),
                systemIsTransmitting: false,
                pttAudioSessionActive: false
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.idle)
        ])

        #expect(state.selectedPeerState.phase == .startingTransmit)
        #expect(state.selectedPeerState.detail == .startingTransmit(stage: .awaitingSystemTransmit))
        #expect(state.selectedPeerState.statusMessage == "Waking Avery...")
    }

    @Test func selectedPeerReducerUsesStoppingStatusWhileExplicitStopIsInFlight() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .transmitting, canTransmit: false),
                    readiness: makeChannelReadiness(
                        status: .selfTransmitting(activeTransmitterUserId: "self"),
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                localIsTransmitting: false,
                localIsStopping: true,
                localRequiresFreshPress: false,
                activeChannelID: contactID,
                pendingAction: .none,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.selectedPeerState.phase == .waitingForPeer)
        #expect(state.selectedPeerState.detail == .waitingForPeer(reason: .localSessionTransition))
        #expect(state.selectedPeerState.statusMessage == "Stopping...")
        #expect(state.selectedPeerState.canTransmitNow == false)
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
            .localSessionUpdated(
                isJoined: false,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: nil,
                pendingAction: .none,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.requestConnection(contactID: contactID)])
    }

    @Test func selectedPeerReducerJoinRequestEmitsJoinReadyPeerForPeerReadySelection() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: nil,
                pendingAction: .none,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.joinReadyPeer(contactID: contactID)])
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
            .localSessionUpdated(
                isJoined: false,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: nil,
                pendingAction: .connect(.joiningLocal(contactID: contactID)),
                localJoinFailure: nil
            ),
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
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: contactID,
                pendingAction: .leave(.explicit(contactID: contactID)),
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
            .localSessionUpdated(
                isJoined: false,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: nil,
                pendingAction: .none,
                localJoinFailure: nil
            ),
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
            .localSessionUpdated(
                isJoined: false,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: nil,
                pendingAction: .none,
                localJoinFailure: nil
            ),
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
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: contactID,
                pendingAction: .leave(.explicit(contactID: contactID)),
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
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: contactID,
                pendingAction: .leave(.reconciledTeardown(contactID: contactID)),
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

    @Test func blockedRequestedPrimaryActionAllowsRequestAgainAfterCooldownExpires() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .outgoingRequest(requestCount: 1),
                phase: .blockedByOtherSession,
                statusMessage: "Another session is active",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Request Again")
        #expect(action.isEnabled)
        #expect(action.style == .muted)
    }

    @Test func blockedRequestedPrimaryActionStaysDisabledDuringCooldown() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .outgoingRequest(requestCount: 1),
                phase: .blockedByOtherSession,
                statusMessage: "Another session is active",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: 12
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Request again in 12s")
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
            .localSessionUpdated(
                isJoined: false,
                localIsTransmitting: false,
                localIsStopping: false,
                localRequiresFreshPress: false,
                activeChannelID: nil,
                pendingAction: .none,
                localJoinFailure: nil
            ),
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

    @Test func relationshipStateRepresentsSimultaneousIncomingAndOutgoingRequests() {
        let relationship = ConversationStateMachine.relationshipState(
            hasIncomingRequest: true,
            hasOutgoingRequest: true,
            requestCount: 2
        )

        #expect(relationship == .mutualRequest(requestCount: 2))
        #expect(relationship.isIncomingRequest)
        #expect(relationship.isOutgoingRequest)
        #expect(relationship.fallbackConversationState == .incomingRequest)
    }

    @Test func selectedPeerStateTreatsMutualRequestsAsAcceptableIncomingRequest() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .incomingRequest,
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
            relationship: .mutualRequest(requestCount: 2)
        )

        #expect(state.phase == .incomingRequest)
        #expect(state.relationship == .mutualRequest(requestCount: 2))
        #expect(state.conversationState == .incomingRequest)
        #expect(state.statusMessage == "Blake wants to talk")
    }

    @Test func contactSummaryTypedProjectionExposesMutualRequestRelationshipAndBadgeState() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel",
            isOnline: true,
            hasIncomingRequest: true,
            hasOutgoingRequest: true,
            requestCount: 2,
            isActiveConversation: true,
            badgeStatus: ConversationState.ready.rawValue
        )

        #expect(summary.requestRelationship == .mutual(requestCount: 2))
        #expect(summary.badge == .ready)
        #expect(summary.badge.conversationState == .ready)
    }

    @Test func channelStateTypedProjectionExposesMembershipAndRequestRelationship() {
        let channelState = TurboChannelStateResponse(
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
            hasOutgoingRequest: true,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.waitingForPeer.rawValue,
            canTransmit: false
        )

        #expect(channelState.membership == .both(peerDeviceConnected: false))
        #expect(channelState.requestRelationship == .outgoing(requestCount: 1))
        #expect(channelState.conversationStatus == .waitingForPeer)
    }

    @Test func contactSummaryDecodesNestedRequestRelationshipProjection() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "requestRelationship": {
                "kind": "mutual",
                "requestCount": 3
              },
              "summaryStatus": {
                "kind": "incoming",
                "activeTransmitterUserId": null
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.requestRelationship == .mutual(requestCount: 3))
        #expect(summary.membership == .peerOnly(peerDeviceConnected: true))
        #expect(summary.badge == .incoming)
        #expect(summary.badgeKind == "incoming")
        #expect(summary.badge.conversationState == .incomingRequest)
    }

    @Test func contactSummaryDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)
            Issue.record("Expected TurboContactSummaryResponse decode to fail without nested contract")
        } catch {
        }
    }

    @Test func contactSummaryDecodeFailsForInvalidNestedRelationshipKind() {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "requestRelationship": {
                "kind": "sideways",
                "requestCount": 3
              },
              "summaryStatus": {
                "kind": "incoming",
                "activeTransmitterUserId": null
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)
            Issue.record("Expected TurboContactSummaryResponse decode to fail for invalid requestRelationship kind")
        } catch {
        }
    }

    @Test func channelStateDecodesNestedMembershipAndRequestRelationshipProjection() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "membership": {
                "kind": "both",
                "peerDeviceConnected": true
              },
              "requestRelationship": {
                "kind": "incoming",
                "requestCount": 4
              },
              "conversationStatus": {
                "kind": "self-transmitting",
                "activeTransmitterUserId": "self"
              },
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true
            }
            """.utf8
        )

        let channelState = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)

        #expect(channelState.membership == .both(peerDeviceConnected: true))
        #expect(channelState.requestRelationship == .incoming(requestCount: 4))
        #expect(channelState.statusView == .selfTransmitting(activeTransmitterUserId: "self"))
        #expect(channelState.statusKind == "self-transmitting")
        #expect(channelState.conversationStatus == .transmitting)
    }

    @Test func channelStateDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)
            Issue.record("Expected TurboChannelStateResponse decode to fail without nested contract")
        } catch {
        }
    }

    @Test func channelStateDecodeFailsForInvalidMembershipPayload() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "membership": {
                "kind": "both"
              },
              "requestRelationship": {
                "kind": "incoming",
                "requestCount": 4
              },
              "conversationStatus": {
                "kind": "self-transmitting",
                "activeTransmitterUserId": "self"
              },
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)
            Issue.record("Expected TurboChannelStateResponse decode to fail for invalid membership payload")
        } catch {
        }
    }

    @Test func channelReadinessDecodesNestedReadinessProjection() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "peerUserId": "peer",
              "selfHasActiveDevice": true,
              "peerHasActiveDevice": true,
              "readiness": {
                "kind": "peer-transmitting",
                "activeTransmitterUserId": "peer"
              },
              "audioReadiness": {
                "self": { "kind": "ready" },
                "peer": { "kind": "waiting" },
                "peerTargetDeviceId": "peer-device"
              },
              "wakeReadiness": {
                "self": { "kind": "wake-capable", "targetDeviceId": "self-device" },
                "peer": { "kind": "wake-capable", "targetDeviceId": "peer-device" }
              },
              "activeTransmitterUserId": "peer",
              "activeTransmitExpiresAt": null,
              "status": "ready"
            }
            """.utf8
        )

        let readiness = try JSONDecoder().decode(TurboChannelReadinessResponse.self, from: data)

        #expect(readiness.statusView == .peerTransmitting(activeTransmitterUserId: "peer"))
        #expect(readiness.statusKind == "peer-transmitting")
        #expect(readiness.canTransmit == false)
        #expect(readiness.remoteAudioReadiness == .waiting)
        #expect(readiness.peerTargetDeviceId == "peer-device")
        #expect(readiness.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @Test func channelReadinessDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "peerUserId": "peer",
              "selfHasActiveDevice": true,
              "peerHasActiveDevice": true,
              "activeTransmitterUserId": "peer",
              "activeTransmitExpiresAt": null,
              "status": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelReadinessResponse.self, from: data)
            Issue.record("Expected TurboChannelReadinessResponse decode to fail without readiness contract")
        } catch {
        }
    }

    @Test func contactSummaryPrefersNestedContractOverLegacyFields() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@peer",
              "displayName": "Peer",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": true,
              "requestCount": 2,
              "isActiveConversation": true,
              "badgeStatus": "requested",
              "requestRelationship": {
                "kind": "incoming",
                "requestCount": 2
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "summaryStatus": {
                "kind": "requested"
              }
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.requestRelationship == .incoming(requestCount: 2))
        #expect(summary.hasIncomingRequest == true)
        #expect(summary.hasOutgoingRequest == false)
        #expect(summary.requestCount == 2)
        #expect(summary.badge == .requested)
        #expect(summary.badgeStatus == "requested")
    }

    @Test func channelStatePrefersNestedContractOverLegacyFields() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@peer",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": true,
              "peerJoined": true,
              "peerDeviceConnected": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true,
              "membership": {
                "kind": "self-only"
              },
              "requestRelationship": {
                "kind": "none"
              },
              "conversationStatus": {
                "kind": "ready"
              }
            }
            """.utf8
        )

        let channelState = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)

        #expect(channelState.membership == .selfOnly)
        #expect(channelState.selfJoined == true)
        #expect(channelState.peerJoined == false)
        #expect(channelState.peerDeviceConnected == false)
        #expect(channelState.requestRelationship == .none)
        #expect(channelState.statusView == .ready)
        #expect(channelState.status == "ready")
    }

    @Test func channelSnapshotPrefersBackendReadinessProjection() {
        let channelState = makeChannelState(status: .ready, canTransmit: true)
        let readiness = makeChannelReadiness(status: .waitingForSelf)

        let snapshot = ChannelReadinessSnapshot(channelState: channelState, readiness: readiness)

        #expect(snapshot.readinessStatus == .waitingForSelf)
        #expect(snapshot.status == .waitingForPeer)
        #expect(snapshot.canTransmit == false)
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

    @Test func transmitReducerSystemPressRequestEmitsBeginEffect() {
        let request = makeTransmitRequest()

        let transition = TransmitReducer.reduce(
            state: .initial,
            event: .systemPressRequested(request)
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

    @Test func transmitReducerSystemEndedWhileActiveEmitsStopEffect() {
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
            event: .systemEnded
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects == [.stopTransmit(target)])
    }

    @Test func transmitReducerSystemEndedDuringStoppingDoesNotDuplicateStopEffect() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let stoppingState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(
                state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
                event: .beginSucceeded(target, request)
            ).state,
            event: .releaseRequested
        ).state

        let transition = TransmitReducer.reduce(
            state: stoppingState,
            event: .systemEnded
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects.isEmpty)
    }

    @Test func transmitRuntimePreservesLatchedTargetWhilePressRemainsActive() {
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(target)

        runtime.syncActiveTarget(nil)

        #expect(runtime.isPressingTalk == true)
        #expect(runtime.activeTarget == target)

        runtime.markPressEnded()
        runtime.syncActiveTarget(nil)

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.activeTarget == nil)
    }

    @Test func transmitRuntimeReconcileIdleStateClearsStalePressAndTarget() {
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(
            TransmitTarget(
                contactID: UUID(),
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel-123"
            )
        )
        runtime.markExplicitStopRequested()

        runtime.reconcileIdleState()

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.activeTarget == nil)
        #expect(runtime.explicitStopRequested == false)
    }

    @Test func transmitRuntimePressEndKeepsLatchedTargetUntilCoordinatorClearsIt() {
        var runtime = TransmitRuntimeState()
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        runtime.markPressBegan()
        runtime.syncActiveTarget(target)

        runtime.markPressEnded()
        runtime.syncActiveTarget(target)

        #expect(runtime.activeTarget == target)
        #expect(runtime.explicitStopRequested == false)
    }

    @Test func transmitRuntimeExplicitStopDoesNotRearmPress() {
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(
            TransmitTarget(
                contactID: UUID(),
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel-123"
            )
        )

        runtime.markExplicitStopRequested()
        runtime.markPressEnded()
        runtime.syncActiveTarget(runtime.activeTarget)

        #expect(runtime.explicitStopRequested)
        #expect(runtime.isPressingTalk == false)
    }

    @Test func transmitRuntimeFinishBeginTaskClearsReferenceWithoutCancellingTask() async {
        var runtime = TransmitRuntimeState()
        let task = Task<Void, Never> {
            await Task.yield()
        }

        runtime.replaceBeginTask(with: task)
        runtime.finishBeginTask()

        #expect(runtime.beginTask == nil)
        #expect(task.isCancelled == false)
        _ = await task.result
    }

    @Test func transmitRuntimeCancelRenewTaskCancelsTaskAndClearsChannel() async {
        var runtime = TransmitRuntimeState()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }

        runtime.replaceRenewTask(with: task, channelID: "channel-123")
        runtime.cancelRenewTask()

        #expect(runtime.renewTask == nil)
        #expect(runtime.renewTaskChannelID == nil)
        #expect(task.isCancelled)
        _ = await task.result
    }

    @MainActor
    @Test func systemTransmitClosesPrewarmedMediaSessionBeforeHandoff() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()

        #expect(viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
    }

    @MainActor
    @Test func systemTransmitDoesNotCloseMediaSessionDuringPTTAudioActivation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()
        viewModel.isPTTAudioSessionActive = true

        #expect(!viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
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
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .requesting(contactID: contactID),
                    isPressActive: true,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
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
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .idle,
                    isPressActive: false,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @MainActor
    @Test func backendChannelRefreshPreservesActiveTransmitLifecycleWhileHoldRemainsPressed() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .active(contactID: contactID),
                    isPressActive: true,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
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
    @Test func websocketIdleDuringTransmitDoesNotResetTransmitSession() {
        let viewModel = PTTViewModel()

        #expect(
            !viewModel.shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: true,
                systemIsTransmitting: false
            )
        )
        #expect(
            !viewModel.shouldResetTransmitSessionOnWebSocketIdle(
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
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: true,
            localPTTAudioSessionActive: true,
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
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: true,
            localPTTAudioSessionActive: true,
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
        #expect(selectedPeerState.detail == .startingTransmit(stage: .awaitingAudioConnection(mediaState: .preparing)))
        #expect(selectedPeerState.statusMessage == "Establishing audio...")
        #expect(primaryAction.kind == .holdToTalk)
    }

    @Test func selectedPeerStateUsesRequestingTransmitStatusBeforeLeaseArrives() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .requesting(contactID: contactID),
            localSystemIsTransmitting: false,
            localPTTAudioSessionActive: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .startingTransmit)
        #expect(selectedPeerState.detail == .startingTransmit(stage: .requestingLease))
        #expect(selectedPeerState.statusMessage == "Requesting transmit...")
    }

    @Test func selectedPeerStateUsesWakeStatusWhileAwaitingSystemTransmitStart() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: false,
            localPTTAudioSessionActive: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .startingTransmit)
        #expect(selectedPeerState.detail == .startingTransmit(stage: .awaitingSystemTransmit))
        #expect(selectedPeerState.statusMessage == "Waking Blake...")
    }

    @Test func selectedPeerStateWaitsForMicrophoneAfterSystemTransmitBegins() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: true,
            localPTTAudioSessionActive: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .startingTransmit)
        #expect(selectedPeerState.detail == .startingTransmit(stage: .awaitingAudioSession))
        #expect(selectedPeerState.statusMessage == "Waiting for microphone...")
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
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
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

    @MainActor
    @Test func conversationContextTreatsLocalPressLatchAsTransmitIntent() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true

        await viewModel.transmitCoordinator.handle(.pressRequested(request))

        let context = viewModel.conversationContext(for: viewModel.contacts[0])

        #expect(context.localIsTransmitting)
        #expect(viewModel.isTransmitting == false)
    }

    @Test func selectedPeerStatePrefersReadyOverWakeWhenRemoteAudioIsReadyButPeerConnectivityLags() {
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
            localMediaWarmupState: .ready,
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
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .ready)
        #expect(selectedPeerState.statusMessage == "Connected")
        #expect(selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerStatePrefersWakeOverRemoteAudioPrewarmWhenPeerConnectivityDrops() {
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
            localMediaWarmupState: .ready,
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
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .wakeReady)
        #expect(selectedPeerState.statusMessage == "Hold to talk to wake Blake")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(selectedPeerState.allowsHoldToTalk)
    }

    @Test func selectedPeerStateRequiresReleaseAfterInterruptedTransmitInsteadOfWakeReady() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            localIsStopping: false,
            localRequiresFreshPress: true,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
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
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
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

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Release and press again.")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.label == "Release To Retry")
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedPeerStatePrefersReceivingOverWakeWhenBackendShowsPeerTransmittingButPeerConnectivityLags() {
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
            localMediaWarmupState: .ready,
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
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .receiving)
        #expect(selectedPeerState.statusMessage == "Blake is talking")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerStateWaitsForSystemWakeActivationBeforeShowingReceiving() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            incomingWakeActivationState: .awaitingSystemActivation,
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
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == SelectedPeerPhase.waitingForPeer)
        #expect(selectedPeerState.detail == SelectedPeerDetail.waitingForPeer(reason: .systemWakeActivation))
        #expect(selectedPeerState.statusMessage == "Waiting for system audio activation...")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerStateWaitsForSystemWakeActivationBeforeShowingReceivingFromBackendProjection() {
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
            localMediaWarmupState: .ready,
            incomingWakeActivationState: .awaitingSystemActivation,
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
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.detail == .waitingForPeer(reason: .systemWakeActivation))
        #expect(selectedPeerState.statusMessage == "Waiting for system audio activation...")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerStateRequiresLocalAudioPrewarmBeforeHoldToTalkIsEnabled() {
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
            mediaState: .preparing,
            localMediaWarmupState: .prewarming,
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
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Preparing audio...")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled == false)
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
        #expect(runtime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)

        runtime.markAudioSessionActivated(for: channelUUID)

        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(runtime.shouldBufferAudioChunk(for: contactID) == false)
    }

    @Test func pttWakeRuntimeTracksIncomingPushAndFallbackStates() {
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
        runtime.confirmIncomingPush(for: channelUUID, payload: payload)
        #expect(runtime.hasConfirmedIncomingPush(for: contactID))
        #expect(runtime.incomingWakeActivationState(for: contactID) == .awaitingSystemActivation)

        runtime.markFallbackDeferredUntilForeground(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivationTimedOutWaitingForForeground)
        runtime.bufferAudioChunk("AQI=", for: contactID)
        #expect(runtime.bufferedAudioChunkCount(for: contactID) == 1)

        runtime.markSystemActivationInterruptedByTransmitEnd(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd)
        #expect(runtime.pendingIncomingPush == nil)
        #expect(runtime.shouldBufferAudioChunk(for: contactID) == false)

        runtime.markAppManagedFallbackStarted(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .appManagedFallback)
    }

    @Test func selectedPeerStateSurfacesMissingSystemWakeActivationExplicitly() {
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
            mediaState: .closed,
            localMediaWarmupState: .cold,
            incomingWakeActivationState: .systemActivationTimedOutWaitingForForeground,
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
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.detail == .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground))
        #expect(selectedPeerState.statusMessage == "Wake received, but system audio never activated. Unlock to resume audio.")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerStateSurfacesInterruptedSystemWakeActivationExplicitly() {
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
            mediaState: .closed,
            localMediaWarmupState: .cold,
            incomingWakeActivationState: .systemActivationInterruptedByTransmitEnd,
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
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.detail == .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground))
        #expect(selectedPeerState.statusMessage == "Wake ended before system audio activated.")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func pttWakeRuntimeTreatsConfirmedMatchingIncomingPushAsDuplicate() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel",
            activeSpeaker: "@blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let runtime = PTTWakeRuntimeState()
        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload,
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        #expect(
            runtime.shouldIgnoreDuplicateIncomingPush(
                for: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )
        #expect(
            !runtime.shouldIgnoreDuplicateIncomingPush(
                for: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel",
                    activeSpeaker: "@blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device-2"
                )
            )
        )
    }

    @Test func pttWakeRuntimeCanResetPlaybackFallbackTaskWithoutClearingPendingWake() {
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

        runtime.replacePlaybackFallbackTask(for: contactID, with: Task { })
        #expect(runtime.hasPlaybackFallbackTask(for: contactID))

        runtime.clearPlaybackFallbackTask(for: contactID)

        #expect(runtime.hasPlaybackFallbackTask(for: contactID) == false)
        #expect(runtime.hasPendingWake(for: contactID))
        #expect(runtime.pendingIncomingPush?.channelUUID == channelUUID)
    }

    @MainActor
    @Test func appActivationResumesInteractiveAudioPrewarmForAlignedSelectedSession() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)

        await viewModel.resumeInteractiveAudioPrewarmIfNeeded(
            reason: "test",
            applicationState: .active
        )

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmRecoversWithoutPTTDeactivationCallback() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
        try? await Task.sleep(nanoseconds: 700_000_000)

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == nil)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmWaitsWhilePTTAudioSessionIsStillActive() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = true

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
        try? await Task.sleep(nanoseconds: 700_000_000)

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmDoesNotRecoverWithoutCallbackWhileBackgrounded() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)

        await viewModel.recoverDeferredInteractivePrewarmWithoutPTTDeactivationIfNeeded(
            for: contactID,
            applicationState: .background
        )

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmDoesNotResumeOnPTTDeactivationWhileBackgrounded() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)

        await viewModel.handleDeactivatedAudioSession(
            AVAudioSession.sharedInstance(),
            applicationState: .background
        )

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
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

    @MainActor
    @Test func foregroundJoinedReceivePrefersAppManagedPlaybackOverSystemActivation() {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.remoteTransmittingContactIDs.insert(contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        #expect(
            viewModel.prefersForegroundAppManagedReceivePlayback(
                for: contactID,
                applicationState: .active
            )
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .active
            ) == false
        )
        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            )
        )
        viewModel.isPTTAudioSessionActive = true
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .background
            )
        )
    }

    @MainActor
    @Test func backgroundWakeSignalPathOnlySetsSystemRemoteParticipantInForeground() {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        #expect(
            viewModel.shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: .active
            )
        )
        #expect(
            viewModel.shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: .background
            ) == false
        )
        #expect(
            viewModel.shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: .inactive
            ) == false
        )
    }

    @MainActor
    @Test func transmitStopSignalPathClearsSystemRemoteParticipantOutsideForeground() {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        #expect(viewModel.shouldClearSystemRemoteParticipantFromSignalPath(for: contactID))
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, source: "test")
        )
        #expect(viewModel.shouldClearSystemRemoteParticipantFromSignalPath(for: contactID) == false)
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

    @Test func playbackOnlyMediaSessionAudioPolicyKeepsPlayAndRecordWithoutActivating() {
        let appManaged = MediaSessionAudioPolicy.configuration(
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        let systemActivated = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(appManaged.category == .playAndRecord)
        #expect(appManaged.mode == .default)
        #expect(appManaged.options == [.defaultToSpeaker, .allowBluetoothHFP])
        #expect(appManaged.shouldActivateSession == false)

        #expect(systemActivated.category == .playAndRecord)
        #expect(systemActivated.mode == .default)
        #expect(systemActivated.options == [.defaultToSpeaker, .allowBluetoothHFP])
        #expect(systemActivated.shouldActivateSession == false)
    }

    @Test func liveTransmitCaptureRouteRefreshRestartsRunningEngineAndTap() {
        let plan = CaptureRouteRefreshPlan.forLiveTransmitRoute(
            engineIsRunning: true,
            inputTapInstalled: true
        )

        #expect(plan.shouldStopEngine)
        #expect(plan.shouldResetEngine)
        #expect(plan.shouldRemoveInputTap)
        #expect(plan.shouldRestartEngine)
    }

    @Test func liveTransmitCaptureRouteRefreshStillReinstallsPathWhenEngineWasIdle() {
        let plan = CaptureRouteRefreshPlan.forLiveTransmitRoute(
            engineIsRunning: false,
            inputTapInstalled: false
        )

        #expect(!plan.shouldStopEngine)
        #expect(!plan.shouldResetEngine)
        #expect(!plan.shouldRemoveInputTap)
        #expect(plan.shouldRestartEngine)
    }

    @Test func transmitStartPlanSkipsRefreshWhenCapturePathIsAlreadyLive() {
        let plan = CaptureTransmitStartPlan.forCurrentCapturePath(
            isCaptureReady: true,
            engineIsRunning: true,
            inputTapInstalled: true,
            hasCaptureConverter: true
        )

        #expect(!plan.shouldRefreshRoute)
    }

    @Test func audioChunkPayloadCodecPreservesLegacySingleChunkPayload() {
        let decoded = AudioChunkPayloadCodec.decode("chunk-1")

        #expect(decoded == ["chunk-1"])
    }

    @Test func audioChunkPayloadCodecRoundTripsBatchedPayloads() {
        let encoded = AudioChunkPayloadCodec.encode(["chunk-1", "chunk-2", "chunk-3"])
        let decoded = AudioChunkPayloadCodec.decode(encoded)

        #expect(decoded == ["chunk-1", "chunk-2", "chunk-3"])
    }

    @Test func playbackBufferReceivePlanStartsNodeWithoutDuplicatingCurrentBuffer() {
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: false,
                playbackIOCycleAvailable: true
            ) == .scheduleAndStartNode
        )
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: true,
                playbackIOCycleAvailable: true
            ) == .scheduleOnly
        )
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: false,
                playbackIOCycleAvailable: false
            ) == .deferUntilIOCycle
        )
    }

    @Test func audioChunkSenderWaitsForShortPacketizationWindowUntilBatchIsFull() {
        #expect(
            AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 1,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 3,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            !AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 4,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            !AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 0,
                maximumPayloadsPerMessage: 4
            )
        )
    }

    @Test func audioChunkSenderBatchesNearbyPayloadsIntoSingleTransportSend() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.append(payload)
            },
            reportFailure: { _ in }
        )

        async let enqueue1: Void = sender.enqueue("chunk-1")
        async let enqueue2: Void = sender.enqueue("chunk-2")
        async let enqueue3: Void = sender.enqueue("chunk-3")
        _ = await (enqueue1, enqueue2, enqueue3)
        try? await Task.sleep(nanoseconds: 500_000_000)

        let transportPayloads = await recorder.payloads
        let deliveredPayloads = transportPayloads.flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads.count == 3)
        #expect(Set(deliveredPayloads) == Set(["chunk-1", "chunk-2", "chunk-3"]))
        #expect(transportPayloads.count < 3)
    }

    @Test func audioChunkSenderBuffersSinglePayloadForShortPacketizationWindow() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }

            func snapshot() -> [String] {
                payloads
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.append(payload)
            },
            reportFailure: { _ in }
        )

        async let enqueue: Void = sender.enqueue("chunk-1")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let transportPayloads = await recorder.snapshot()
        #expect(transportPayloads.isEmpty)

        _ = await enqueue
        try? await Task.sleep(nanoseconds: 300_000_000)

        let flushedPayloads = await recorder.snapshot()
        #expect(flushedPayloads == ["chunk-1"])
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
        try? await Task.sleep(nanoseconds: 500_000_000)

        let transportPayloads = await recorder.payloads
        let deliveredPayloads = transportPayloads.flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads == ["chunk-1", "chunk-2"])
    }

    @Test func audioChunkSenderWaitsBrieflyForLateTransportHandler() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }
        }

        actor FailureRecorder {
            var messages: [String] = []

            func append(_ message: String) {
                messages.append(message)
            }
        }

        let recorder = Recorder()
        let failures = FailureRecorder()
        let sender = AudioChunkSender(
            sendChunk: nil,
            reportFailure: { message in
                await failures.append(message)
            }
        )

        let enqueueTask = Task {
            await sender.enqueue("chunk-late")
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await sender.updateSendChunk { payload in
            await recorder.append(payload)
        }
        await enqueueTask.value

        let payloads = await recorder.payloads
        let failureMessages = await failures.messages
        #expect(payloads == ["chunk-late"])
        #expect(failureMessages.isEmpty)
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
    @Test func receiveTransmitStopDefersInteractiveAudioPrewarmUntilPTTAudioDeactivation() async throws {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.remoteTransmittingContactIDs.insert(contactID)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)

        await viewModel.handleDeactivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func lateAudioChunkAfterTransmitStopDoesNotRearmProvisionalWakeCandidate() async throws {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
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
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd)
        #expect(viewModel.pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID))

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

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
    }

    @MainActor
    @Test func interruptedWakeStateClearsAfterInteractiveMediaRecovers() async throws {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
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
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd)

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
    }

    @MainActor
    @Test func lateAudioChunkAfterPTTDeactivationDoesNotRearmSuppressedWakeCandidate() async throws {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
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
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        await viewModel.handleDeactivatedAudioSession(
            AVAudioSession.sharedInstance(),
            applicationState: .background
        )

        #expect(viewModel.pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID))
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)

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

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
    }

    @MainActor
    @Test func transmitStartWithoutAudioOrStopExpiresRemoteTransmittingLatch() async throws {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-begin"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))

        try await Task.sleep(nanoseconds: 1_700_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
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

    @MainActor
    @Test func pttAudioActivationPreservesExistingAppManagedAudioSessionWhileHandingOffToSystemPlayback() async throws {
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

        let existingSession = RecordingMediaSession()
        viewModel.mediaRuntime.attach(session: existingSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

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
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(existingSession.closedDeactivateAudioSessionFlags == [false])
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func pttAudioActivationCreatesPlaybackBeforeDeferredBackendRefreshFails() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
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
        pendingPush.bufferedAudioChunks = ["AQI="]
        viewModel.pttWakeRuntime.store(pendingPush)

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.diagnosticsTranscript.contains("Deferring wake backend refresh off audio activation critical path"))
        #expect(viewModel.diagnosticsTranscript.contains("Contact sync failed"))

        let messages = viewModel.diagnostics.entries.map(\.message)
        let recreateIndex = messages.lastIndex(of: "Recreating media session after PTT audio activation")
        let deferIndex = messages.lastIndex(of: "Deferring wake backend refresh off audio activation critical path")
        let failureIndex = messages.lastIndex(of: "Contact sync failed")

        #expect(recreateIndex != nil)
        #expect(deferIndex != nil)
        #expect(failureIndex != nil)
        if let recreateIndex, let deferIndex, let failureIndex {
            #expect(recreateIndex > deferIndex)
            #expect(deferIndex > failureIndex)
        }
    }

    @Test func systemActivatedPlaybackOnlyPreservesExistingAudioSessionConfiguration() {
        let configuration = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(configuration.shouldConfigureSession == false)
        #expect(configuration.shouldActivateSession == false)
        #expect(configuration.category == .playAndRecord)
    }

    @MainActor
    @Test func closeMediaSessionPreservesAudioSessionWhileWakeActivationIsPending() {
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

        let existingSession = RecordingMediaSession()
        viewModel.mediaRuntime.attach(session: existingSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
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
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.closeMediaSession()

        #expect(existingSession.closedDeactivateAudioSessionFlags == [false])
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
    }

    @Test func wakePlaybackFallbackRequiresActiveApplicationState() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .active))
        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .inactive) == false)
        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .background) == false)
    }

    @MainActor
    @Test func backgroundTransitionSuspendsIdleForegroundMediaSession() async throws {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.shouldSuspendForegroundMediaForBackgroundTransition(
                applicationState: .inactive
            )
        )

        await viewModel.suspendForegroundMediaForBackgroundTransition(
            reason: "test-background",
            applicationState: .background
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
    }

    @MainActor
    @Test func backgroundTransitionDoesNotSuspendActiveTransmitSession() async throws {
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
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.isTransmitting = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        #expect(
            viewModel.shouldSuspendForegroundMediaForBackgroundTransition(
                applicationState: .background
            ) == false
        )
    }

    @MainActor
    @Test func wakePlaybackFallbackDefersUntilApplicationBecomesActive() async throws {
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

        await viewModel.runWakePlaybackFallbackIfNeeded(
            for: contactID,
            reason: "test-background",
            applicationState: .background
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .awaitingPTTActivation)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["AQI=", "AwQ="])

        await viewModel.resumeBufferedWakePlaybackIfNeeded(
            reason: "test-active",
            applicationState: .active
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .appManagedFallback)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState != .idle)
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

    @Test func selectedPeerStateShowsReceivingFromBackendTransmitWithoutSignalOrReadyAudio() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            incomingWakeActivationState: nil,
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
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .waiting,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        #expect(selectedPeerState.phase == .receiving)
        #expect(selectedPeerState.detail == .receiving)
        #expect(selectedPeerState.statusMessage == "Avery is talking")
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

    @MainActor
    @Test func activeTransmitTargetFallsBackToLatchedRuntimeTargetWhilePressIsHeld() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
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
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncTransmitState()

        #expect(viewModel.transmitCoordinator.state.activeTarget == nil)
        #expect(viewModel.activeTransmitTarget(for: channelUUID) == target)
    }

    @MainActor
    @Test func activateTransmitStartsLeaseRenewalBeforePTTActivationCompletes() async {
        let viewModel = PTTViewModel()
        let channelUUID = UUID()
        let contactID = UUID()

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "user-self",
            mode: "cloud"
        )
        await viewModel.initializeIfNeeded()
        try? viewModel.pttSystemClient.joinChannel(channelUUID: channelUUID, name: "Chat with Avery")
        try? await Task.sleep(nanoseconds: 250_000_000)

        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@avery",
            backendChannelID: "channel-1",
            remoteUserID: "user-avery",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-1"
        )

        await viewModel.runTransmitEffect(.activateTransmit(request, target))

        #expect(viewModel.transmitRuntime.renewTask != nil)
        #expect(viewModel.transmitRuntime.renewTaskChannelID == "channel-1")
        #expect(viewModel.transmitRuntime.renewTaskGeneration == 1)
    }

    @MainActor
    @Test func activateTransmitKeepsExistingLeaseRenewalForSameChannel() async {
        let viewModel = PTTViewModel()
        let channelUUID = UUID()
        let contactID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@avery",
            backendChannelID: "channel-1",
            remoteUserID: "user-avery",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "user-self",
            mode: "cloud"
        )
        await viewModel.initializeIfNeeded()
        try? viewModel.pttSystemClient.joinChannel(channelUUID: channelUUID, name: "Chat with Avery")
        try? await Task.sleep(nanoseconds: 250_000_000)

        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        await viewModel.runTransmitEffect(.activateTransmit(request, target))

        let initialGeneration = viewModel.transmitRuntime.renewTaskGeneration
        #expect(initialGeneration == 1)

        await viewModel.runTransmitEffect(.activateTransmit(request, target))

        #expect(viewModel.transmitRuntime.renewTask != nil)
        #expect(viewModel.transmitRuntime.renewTaskChannelID == "channel-1")
        #expect(viewModel.transmitRuntime.renewTaskGeneration == initialGeneration)
    }

    @MainActor
    @Test func syncTransmitStateClearsStaleIdlePressLatch() async {
        let viewModel = PTTViewModel()
        viewModel.transmitRuntime.markPressBegan()

        viewModel.syncTransmitState()

        #expect(viewModel.isTransmitPressActive == false)
        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitRuntime.activeTarget == nil)
    }

    @MainActor
    @Test func explicitTransmitStopFallbackClearsStaleSystemTransmittingState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                source: "test"
            )
        )
        viewModel.syncPTTState()

        #expect(viewModel.isTransmitting)

        await viewModel.reconcileExplicitTransmitStopIfNeeded(
            target: target,
            source: "test-fallback"
        )

        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(viewModel.isTransmitting == false)
    }

    @MainActor
    @Test func explicitTransmitStopLocalCompletionClearsCoordinatorAfterRelease() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                source: "test"
            )
        )
        await viewModel.transmitCoordinator.handle(
            .beginSucceeded(
                target,
                TransmitRequestContext(
                    contactID: contactID,
                    contactHandle: "@avery",
                    backendChannelID: "channel-avery",
                    remoteUserID: "user-avery",
                    channelUUID: channelUUID,
                    usesLocalHTTPBackend: false,
                    backendSupportsWebSocket: true
                )
            )
        )
        await viewModel.transmitCoordinator.handle(.releaseRequested)
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncPTTState()
        viewModel.syncTransmitState()

        await viewModel.finalizeExplicitTransmitStopLocallyIfNeeded(
            target: target,
            source: "test-local-complete"
        )

        #expect(viewModel.transmitDomainSnapshot.hasTransmitIntent(for: contactID) == false)
        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(viewModel.isTransmitting == false)
        #expect(viewModel.transmitCoordinator.state.activeTarget == nil)
        switch viewModel.transmitCoordinator.state.phase {
        case .idle:
            break
        case .requesting, .active, .stopping:
            Issue.record("Expected transmit coordinator to return to idle after local stop completion")
        }
    }

    @MainActor
    @Test func transmitDomainSnapshotSuppressesTransmitIntentAfterExplicitStop() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.transmitRuntime.markExplicitStopRequested()
        viewModel.syncTransmitState()

        let snapshot = viewModel.transmitDomainSnapshot

        #expect(snapshot.isPressActive == false)
        #expect(snapshot.hasTransmitIntent(for: contactID) == false)
        #expect(snapshot.isStopping(for: contactID))
    }

    @MainActor
    @Test func transmitDomainSnapshotTracksInterruptedHoldUntilRelease() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.transmitRuntime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)

        let interruptedSnapshot = viewModel.transmitDomainSnapshot
        #expect(interruptedSnapshot.requiresFreshPress(for: contactID))
        #expect(interruptedSnapshot.hasTransmitIntent(for: contactID) == false)

        viewModel.transmitRuntime.noteTouchReleased()

        let releasedSnapshot = viewModel.transmitDomainSnapshot
        #expect(releasedSnapshot.requiresFreshPress(for: contactID) == false)
    }

    @Test func transmitRuntimeTracksSystemTransmitDurationAndClearsItOnEnd() {
        var runtime = TransmitRuntimeState()
        let beganAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 101.25)

        runtime.noteSystemTransmitBegan(at: beganAt)

        #expect(runtime.currentSystemTransmitDurationMilliseconds(at: endedAt) == 1250)

        runtime.noteSystemTransmitEnded()

        #expect(runtime.currentSystemTransmitDurationMilliseconds(at: endedAt) == nil)
    }

    @Test func transmitRuntimeTracksPendingSystemTransmitBeginState() {
        var runtime = TransmitRuntimeState()
        let channelUUID = UUID()

        runtime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        #expect(runtime.pendingSystemBeginChannelUUID == channelUUID)
        #expect(runtime.isSystemTransmitBeginPending(channelUUID: channelUUID))

        runtime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)

        #expect(runtime.pendingSystemBeginChannelUUID == nil)
        #expect(runtime.isSystemTransmitBeginPending(channelUUID: channelUUID) == false)
    }

    @MainActor
    @Test func systemTransmitCallbacksClearPendingSystemBeginState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID

        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        viewModel.handleDidBeginTransmitting(channelUUID, source: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitRuntime.pendingSystemBeginChannelUUID == nil)

        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        viewModel.handleFailedToBeginTransmitting(
            channelUUID,
            error: NSError(domain: PTChannelErrorDomain, code: 1)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitRuntime.pendingSystemBeginChannelUUID == nil)
    }

    @MainActor
    @Test func systemTransmitBeginWithoutLocalPressStartsSystemOriginatedTransmitRequest() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "self-user",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.handleDidBeginTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitCoordinator.state.phase == .requesting(contactID: contactID))
        #expect(viewModel.transmitCoordinator.state.isPressingTalk)
        #expect(viewModel.transmitCoordinator.state.pendingRequest?.channelUUID == channelUUID)
        #expect(viewModel.transmitRuntime.isPressingTalk)
    }

    @MainActor
    @Test func systemTransmitEndClearsPendingSystemOriginatedRequestBeforeBackendGrant() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "self-user",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.handleDidBeginTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)
        viewModel.handleDidEndTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitCoordinator.state.phase == .idle)
        #expect(viewModel.transmitCoordinator.state.pendingRequest == nil)
        #expect(viewModel.transmitCoordinator.state.isPressingTalk == false)
    }

    @MainActor
    @Test func resetLocalDevStateClearsVisibleSessionErrorsAndTransientState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.remoteTransmittingContactIDs = [contactID]
        viewModel.remoteAudioSilenceTasks[contactID] = Task {}
        viewModel.statusMessage = "Join failed: stale channel"
        viewModel.diagnostics.record(.media, level: .error, message: "Old error")

        viewModel.resetLocalDevState(backendStatus: "Reconnecting as @blake...")

        #expect(viewModel.selectedContactId == nil)
        #expect(viewModel.contacts.isEmpty)
        #expect(viewModel.remoteTransmittingContactIDs.isEmpty)
        #expect(viewModel.remoteAudioSilenceTasks.isEmpty)
        #expect(viewModel.statusMessage == "Initializing...")
        #expect(viewModel.backendStatusMessage == "Reconnecting as @blake...")
        #expect(viewModel.diagnostics.latestError == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Old error") == false)
    }

    @MainActor
    @Test func explicitTransmitStopFallbackIgnoresMismatchedChannel() async {
        let viewModel = PTTViewModel()
        let joinedContactID = UUID()
        let targetContactID = UUID()
        let joinedChannelUUID = UUID()
        let target = TransmitTarget(
            contactID: targetContactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: joinedContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: joinedChannelUUID,
                backendChannelId: "channel-joined",
                remoteUserId: "user-avery"
            ),
            Contact(
                id: targetContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-avery",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: joinedChannelUUID,
                contactID: joinedContactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: joinedChannelUUID,
                source: "test"
            )
        )
        viewModel.syncPTTState()

        await viewModel.reconcileExplicitTransmitStopIfNeeded(
            target: target,
            source: "test-fallback"
        )

        #expect(viewModel.pttCoordinator.state.isTransmitting)
        #expect(viewModel.isTransmitting)
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

    @MainActor
    @Test func applicationDidBecomeActiveRequestsBackendPollForSelectedContact() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.selectedContactId = contactID

        var capturedEffects: [BackendSyncEffect] = []
        viewModel.backendSyncCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.handleApplicationDidBecomeActive()

        #expect(
            capturedEffects == [
                .ensureWebSocketConnected,
                .heartbeatPresence,
                .refreshContactSummaries,
                .refreshInvites,
                .refreshChannelState(contactID)
            ]
        )
    }

    @MainActor
    @Test func applicationDidBecomeActiveClearsBadgeAndDeliveredNotifications() async {
        let viewModel = PTTViewModel()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }

        await viewModel.handleApplicationDidBecomeActive()

        #expect(badgeCounts == [0])
        #expect(clearNotificationsCallCount == 1)
    }

    @MainActor
    @Test func foregroundPresencePublishingRequiresActiveApplicationState() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .active))
        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .inactive) == false)
        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .background) == false)
    }

    @MainActor
    @Test func talkRequestBadgeCountUsesUniqueIncomingContacts() {
        let viewModel = PTTViewModel()
        let firstContactID = UUID()
        let secondContactID = UUID()

        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [
                    BackendInviteUpdate(
                        contactID: firstContactID,
                        invite: makeInvite(direction: "incoming", requestCount: 3)
                    ),
                    BackendInviteUpdate(
                        contactID: secondContactID,
                        invite: makeInvite(direction: "incoming", requestCount: 1)
                    ),
                ],
                outgoing: [],
                now: .now
            )
        )

        #expect(viewModel.pendingIncomingTalkRequestBadgeCount == 2)
    }

    @MainActor
    @Test func talkRequestBadgeSyncAppliesUniqueIncomingContactCountWhileBackgrounded() {
        let viewModel = PTTViewModel()
        let firstContactID = UUID()
        let secondContactID = UUID()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }

        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [
                    BackendInviteUpdate(
                        contactID: firstContactID,
                        invite: makeInvite(direction: "incoming", requestCount: 4)
                    ),
                    BackendInviteUpdate(
                        contactID: secondContactID,
                        invite: makeInvite(direction: "incoming", requestCount: 1)
                    ),
                ],
                outgoing: [],
                now: .now
            )
        )

        viewModel.syncTalkRequestNotificationBadge(applicationState: .background)

        #expect(badgeCounts == [2])
        #expect(clearNotificationsCallCount == 0)
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

    @Test func backendSyncReducerContactSummaryFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let summary = makeContactSummary(channelId: "channel-1")
        var state = BackendSyncSessionState()
        state.syncState.contactSummaries[contactID] = summary
        state.syncState.hasEstablishedConnection = true
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .contactSummariesFailed("Contact sync failed: internal server error")
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
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
        #expect(transition.state.syncState.requestCooldownSourceKeys[contactID] == "\(invite.inviteId)|\(invite.requestCount)|\(invite.updatedAt ?? invite.createdAt)")
    }

    @Test func backendSyncReducerInviteRefreshDoesNotRestartCooldownForSameOutgoingInvite() {
        let contactID = UUID()
        let invite = makeInvite(direction: "outgoing", inviteId: "invite-1")
        let originalNow = Date(timeIntervalSince1970: 1_000)
        let laterNow = originalNow.addingTimeInterval(31)
        var state = BackendSyncSessionState()
        state.syncState.outgoingInvites[contactID] = invite
        state.syncState.requestCooldownDeadlines[contactID] = originalNow.addingTimeInterval(30)
        state.syncState.requestCooldownSourceKeys[contactID] =
            "\(invite.inviteId)|\(invite.requestCount)|\(invite.updatedAt ?? invite.createdAt)"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesUpdated(
                incoming: [],
                outgoing: [BackendInviteUpdate(contactID: contactID, invite: invite)],
                now: laterNow
            )
        )

        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == nil)
        #expect(transition.state.syncState.requestCooldownSourceKeys[contactID] == "\(invite.inviteId)|\(invite.requestCount)|\(invite.updatedAt ?? invite.createdAt)")
    }

    @Test func backendSyncReducerInviteRefreshRestartsCooldownForUpdatedOutgoingInvite() {
        let contactID = UUID()
        let originalInvite = makeInvite(direction: "outgoing", inviteId: "invite-1")
        let updatedInvite = makeInvite(
            direction: "outgoing",
            inviteId: "invite-1",
            requestCount: 2,
            updatedAt: "2026-04-17T21:00:00Z"
        )
        let originalNow = Date(timeIntervalSince1970: 1_000)
        let laterNow = originalNow.addingTimeInterval(31)
        var state = BackendSyncSessionState()
        state.syncState.outgoingInvites[contactID] = originalInvite
        state.syncState.requestCooldownDeadlines[contactID] = originalNow.addingTimeInterval(30)
        state.syncState.requestCooldownSourceKeys[contactID] =
            "\(originalInvite.inviteId)|\(originalInvite.requestCount)|\(originalInvite.updatedAt ?? originalInvite.createdAt)"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesUpdated(
                incoming: [],
                outgoing: [BackendInviteUpdate(contactID: contactID, invite: updatedInvite)],
                now: laterNow
            )
        )

        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == laterNow.addingTimeInterval(30))
        #expect(transition.state.syncState.requestCooldownSourceKeys[contactID] == "\(updatedInvite.inviteId)|\(updatedInvite.requestCount)|\(updatedInvite.updatedAt ?? updatedInvite.createdAt)")
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

    @Test func backendSyncReducerInviteFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let incomingInvite = makeInvite(direction: "incoming")
        let outgoingInvite = makeInvite(direction: "outgoing")
        let cooldownDeadline = Date(timeIntervalSince1970: 2_000)
        var state = BackendSyncSessionState()
        state.syncState.incomingInvites[contactID] = incomingInvite
        state.syncState.outgoingInvites[contactID] = outgoingInvite
        state.syncState.requestCooldownDeadlines[contactID] = cooldownDeadline
        state.syncState.hasEstablishedConnection = true
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesFailed("Invite sync failed: internal server error")
        )

        #expect(transition.state.syncState.incomingInvites[contactID] == incomingInvite)
        #expect(transition.state.syncState.outgoingInvites[contactID] == outgoingInvite)
        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == cooldownDeadline)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
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
    @Test func trackedPresenceFallbackTargetsIncludeTrackedContactsWithoutSummaries() {
        let viewModel = PTTViewModel()
        let trackedContactID = UUID()
        let summarizedContactID = UUID()

        viewModel.contacts = [
            Contact(
                id: trackedContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            ),
            Contact(
                id: summarizedContactID,
                name: "Casey",
                handle: "@casey",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: "channel-casey",
                remoteUserId: "user-casey"
            )
        ]
        viewModel.trackContact(trackedContactID)
        viewModel.trackContact(summarizedContactID)

        let targets = viewModel.trackedPresenceFallbackTargets(
            excluding: [
                summarizedContactID: TurboContactSummaryResponse(
                    userId: "user-casey",
                    handle: "@casey",
                    displayName: "Casey",
                    channelId: "channel-casey",
                    isOnline: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    isActiveConversation: false,
                    badgeStatus: "online"
                )
            ]
        )

        #expect(targets.count == 1)
        #expect(targets.first?.contactID == trackedContactID)
        #expect(targets.first?.handle == "@blake")
    }

    @Test func backendClientPresenceLookupUsesCanonicalPresenceEndpoint() {
        let path = TurboBackendClient.presenceLookupPath(for: "@blake")

        #expect(path == "/v1/users/by-handle/@blake/presence")
        #expect(path.contains("/presence"))
        #expect(path.contains("/presence/") == false)
    }

    @MainActor
    @Test func contactPresencePresentationUsesSummaryOnlineBadgeForForegroundPeer() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            )
        ]
        let summary = TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: "channel-blake",
                isOnline: true,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "online",
                membershipPayload: TurboChannelMembershipPayload(
                    kind: "peer-only",
                    peerDeviceConnected: false
                )
            )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(viewModel.contactPresencePresentation(for: contactID) == .connected)
    }

    @MainActor
    @Test func contactPresencePresentationTreatsIdleDisconnectedSummaryAsAvailable() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            )
        ]
        let summary = TurboContactSummaryResponse(
            userId: "user-blake",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel-blake",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            isActiveConversation: false,
            badgeStatus: "idle",
            membershipPayload: TurboChannelMembershipPayload(
                kind: "peer-only",
                peerDeviceConnected: false
            )
        )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(viewModel.contactPresencePresentation(for: contactID) == .available)
    }

    @MainActor
    @Test func contactPresencePresentationTreatsFallbackPresenceAsOnlineWithoutSummary() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            )
        ]

        #expect(viewModel.contactPresencePresentation(for: contactID) == .connected)
    }

    @MainActor
    @Test func selectedPeerIdleStatusDoesNotSayOnlineWhenSummaryIsIdleAndMembershipIsDisconnected() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        let summary = TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: "channel-blake",
                isOnline: true,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "idle",
                membershipPayload: TurboChannelMembershipPayload(
                    kind: "peer-only",
                    peerDeviceConnected: false
                )
            )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        let state = viewModel.selectedPeerState(for: contactID)

        #expect(state.phase == .idle)
        #expect(state.statusMessage == "Ready to connect")
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

    @MainActor
    @Test func receiverAudioReadinessPublishDefersWhileWebSocketReconnects() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: "channel-refresh")

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Deferred receiver audio readiness publish until WebSocket reconnects"))
        #expect(!viewModel.diagnosticsTranscript.contains("Receiver audio readiness publish failed"))
    }

    @MainActor
    @Test func receiverAudioReadinessPublishDoesNotRequirePeerDeviceConnectedWhenPeerMembershipExists() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: "channel-refresh")

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Deferred receiver audio readiness publish until WebSocket reconnects"))
        #expect(!viewModel.diagnosticsTranscript.contains("Receiver audio readiness publish failed"))
    }

    @MainActor
    @Test func websocketIdleClearsCachedReceiverAudioReadinessPublications() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let contactID = UUID()
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.localReceiverAudioReadinessPublications[contactID] = ReceiverAudioReadinessPublication(
            isReady: true,
            peerWasRoutable: true
        )

        viewModel.handleWebSocketStateChange(.idle)

        #expect(viewModel.localReceiverAudioReadinessPublications.isEmpty)
    }

    @MainActor
    @Test func selectedPeerStateIgnoresCachedChannelStateWithoutMatchingSummary() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-stale",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: false)
            )
        )

        let state = viewModel.selectedPeerState(for: contactID)

        #expect(state.phase == .idle)
        #expect(state.conversationState == .idle)
        #expect(state.canTransmitNow == false)
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

    @Test func backendSyncReducerChannelFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let existingChannelState = makeChannelState(status: .ready, canTransmit: true)
        var state = BackendSyncSessionState()
        state.syncState.channelStates[contactID] = existingChannelState
        state.syncState.hasEstablishedConnection = true
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .channelStateFailed(contactID: contactID, message: "Channel sync failed: timeout")
        )

        #expect(transition.state.syncState.channelStates[contactID] == existingChannelState)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
    }

    @Test func backendSyncStateAcceptsBackendConnectingRegression() {
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

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateAcceptsBackendIncomingRequestRegression() {
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

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateAcceptsBackendPeerRegression() {
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

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateAcceptsBackendPeerJoinedConnectingRegression() {
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

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateReplacesStaleJoinedMembershipWhenBackendResetsChannel() {
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

        #expect(syncState.channelStates[contactID] == regressedChannelState)
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
            intent: .requestConnection,
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
            intent: .requestConnection,
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
            intent: .requestConnection,
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
            intent: .requestConnection,
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
            intent: .requestConnection,
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
            intent: .requestConnection,
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
            intent: .requestConnection,
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
            intent: .requestConnection,
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
    @Test func backendJoinExecutionPlanPromotesOutgoingInviteWhenPeerIsJoinedButDeviceNotConnected() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
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

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: currentChannel
        )

        #expect(plan == .joinSession)
    }

    @MainActor
    @Test func backendJoinExecutionPlanPromotesPeerReadyChannelWhenPeerHasJoined() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
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
            intent: .requestConnection,
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
            intent: .requestConnection,
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

    @Test func talkRequestSurfaceShowsNewestUnsurfacedInviteWhenAppIsActive() {
        let older = IncomingTalkRequestCandidate(
            contact: Contact(
                id: UUID(),
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            invite: makeInvite(
                direction: "incoming",
                inviteId: "invite-older",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )
        let newer = IncomingTalkRequestCandidate(
            contact: Contact(
                id: UUID(),
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID()
            ),
            invite: makeInvite(
                direction: "incoming",
                inviteId: "invite-newer",
                fromHandle: "@blake",
                createdAt: "2026-04-17T19:02:00Z",
                updatedAt: "2026-04-17T19:02:00Z"
            )
        )

        let nextState = TalkRequestSurfaceReducer.reduce(
            state: TalkRequestSurfaceState(),
            event: .invitesUpdated(
                candidates: [older, newer],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(nextState.activeIncomingRequest?.inviteID == "invite-newer")
        #expect(nextState.surfacedInviteIDs == Set(["invite-newer"]))
    }

    @Test func talkRequestSurfaceDefersUntilAppBecomesActive() {
        let candidate = IncomingTalkRequestCandidate(
            contact: Contact(
                id: UUID(),
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            invite: makeInvite(
                direction: "incoming",
                inviteId: "invite-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )

        let backgroundState = TalkRequestSurfaceReducer.reduce(
            state: TalkRequestSurfaceState(),
            event: .invitesUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: false
            )
        )
        let activeState = TalkRequestSurfaceReducer.reduce(
            state: backgroundState,
            event: .invitesUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(backgroundState.activeIncomingRequest == nil)
        #expect(backgroundState.surfacedInviteIDs.isEmpty)
        #expect(activeState.activeIncomingRequest?.inviteID == "invite-1")
    }

    @Test func openingRequestContactClearsBannerAndMarksInviteSurfaced() {
        let contactID = UUID()
        let inviteID = "invite-1"
        let initialState = TalkRequestSurfaceState(
            activeIncomingRequest: IncomingTalkRequestSurface(
                contactID: contactID,
                inviteID: inviteID,
                contactName: "Avery",
                contactHandle: "@avery",
                requestCount: 1,
                recencyKey: "2026-04-17T19:00:00Z"
            ),
            surfacedInviteIDs: []
        )

        let nextState = TalkRequestSurfaceReducer.reduce(
            state: initialState,
            event: .contactOpened(contactID: contactID, inviteID: inviteID)
        )

        #expect(nextState.activeIncomingRequest == nil)
        #expect(nextState.surfacedInviteIDs == Set([inviteID]))
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
        #expect(
            outcome.report.steps.map(\.id)
                == [
                    .backendConfig,
                    .microphonePermission,
                    .runtimeConfig,
                    .authSession,
                    .deviceHeartbeat,
                    .websocket,
                    .peerLookup,
                    .directChannel,
                    .channelState,
                    .sessionAlignment
                ]
        )
        #expect(outcome.report.steps.first(where: { $0.id == .microphonePermission })?.status == .passed)
        #expect(outcome.report.steps.first(where: { $0.id == .websocket })?.status == .skipped)
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

    @Test func pttSystemPolicyReducerKeepsFailedUploadContextForRetry() {
        let received = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: "channel-1")
        )
        let failed = PTTSystemPolicyReducer.reduce(
            state: received.state,
            event: .tokenUploadFailed("network down")
        )

        #expect(failed.state.latestTokenHex == "deadbeef")
        #expect(failed.state.lastTokenUploadError == "network down")
        #expect(
            failed.state.tokenRegistration
                == .uploadFailed(
                    latestTokenHex: "deadbeef",
                    backendChannelID: "channel-1",
                    attemptedRequest: PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    ),
                    message: "network down"
                )
        )

        let retried = PTTSystemPolicyReducer.reduce(
            state: failed.state,
            event: .backendChannelReady("channel-1")
        )

        #expect(
            retried.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
        #expect(
            retried.state.tokenRegistration
                == .uploadPending(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
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

    @Test func holdToTalkButtonPolicyKeepsActivePresentationWhileGestureIsHeld() {
        let action = ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        )

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: true)

        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected hold-to-talk presentation to remain a hold action")
        }
        #expect(displayAction.label == "Release To Stop")
        #expect(displayAction.isEnabled)
        switch displayAction.style {
        case .active:
            break
        case .accent, .muted:
            Issue.record("Expected active styling while hold gesture remains pressed")
        }
    }

    @Test func holdToTalkButtonPolicyLeavesIdleHoldPresentationUnchanged() {
        let action = ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        )

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: false)

        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected idle hold-to-talk presentation to remain a hold action")
        }
        #expect(displayAction.label == "Hold To Talk")
        #expect(displayAction.isEnabled)
        switch displayAction.style {
        case .accent:
            break
        case .active, .muted:
            Issue.record("Expected accent styling while idle and ready to talk")
        }
    }

    @Test func holdToTalkButtonPolicyKeepsHoldControlMountedWhileGestureIsHeld() {
        let action = ConversationPrimaryAction(
            kind: .connect,
            label: "Connect",
            isEnabled: true,
            style: .accent
        )

        #expect(HoldToTalkButtonPolicy.shouldRenderHoldToTalkControl(action, gestureIsActive: true))
        #expect(!HoldToTalkButtonPolicy.shouldRenderHoldToTalkControl(action, gestureIsActive: false))

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: true)
        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected latched hold control to stay mounted while gesture remains pressed")
        }
        #expect(displayAction.label == "Release To Stop")
    }

    @Test func holdToTalkGestureStateRequiresReleaseAfterMachineEndsHeldPress() {
        var state = HoldToTalkGestureState()

        let didBegin = state.beginIfAllowed(isEnabled: true)
        #expect(didBegin)

        state.handleMachinePressChanged(isActive: false)

        #expect(state.isTrackingTouch == false)
        #expect(state.requiresReleaseBeforeNextPress)
        let blockedBegin = state.beginIfAllowed(isEnabled: true)
        #expect(blockedBegin == false)
    }

    @Test func holdToTalkGestureStateRearmsOnlyAfterTouchEnds() {
        var state = HoldToTalkGestureState()

        let firstBegin = state.beginIfAllowed(isEnabled: true)
        #expect(firstBegin)
        state.handleMachinePressChanged(isActive: false)

        #expect(state.endTouch() == false)
        #expect(state.requiresReleaseBeforeNextPress == false)
        let secondBegin = state.beginIfAllowed(isEnabled: true)
        #expect(secondBegin)
    }

    @Test func transmitRuntimeRequiresFreshPressAfterUnexpectedSystemEndUntilTouchRelease() {
        var runtime = TransmitRuntimeState()
        let contactID = UUID()

        runtime.markPressBegan()
        runtime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.requiresReleaseBeforeNextPress == true)
        #expect(runtime.interruptedContactID == contactID)

        runtime.markPressBegan()
        #expect(runtime.isPressingTalk == false)

        runtime.noteTouchReleased()
        runtime.markPressBegan()
        #expect(runtime.isPressingTalk == true)
        #expect(runtime.requiresReleaseBeforeNextPress == false)
        #expect(runtime.interruptedContactID == nil)
    }

    @Test func transmitRuntimeIdleReconcilePreservesFreshPressBarrierUntilTouchRelease() {
        var runtime = TransmitRuntimeState()
        let contactID = UUID()

        runtime.markPressBegan()
        runtime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)
        runtime.reconcileIdleState()

        #expect(runtime.requiresReleaseBeforeNextPress == true)
        #expect(runtime.interruptedContactID == contactID)

        runtime.noteTouchReleased()

        #expect(runtime.requiresReleaseBeforeNextPress == false)
        #expect(runtime.interruptedContactID == nil)
    }

    @MainActor
    @Test func systemActivatedReceivePlaybackDefersUntilPTTAudioSessionIsActive() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.remoteTransmittingContactIDs = [contactID]
        viewModel.pttCoordinator.send(.didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test"))
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false

        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            )
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .background
            ) == false
        )

        viewModel.isPTTAudioSessionActive = true
        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            ) == false
        )
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
    @Test func diagnosticsLatestErrorClearsWhenBoundedBufferDropsOldError() {
        let store = DiagnosticsStore()
        store.clear()

        store.record(.pushToTalk, level: .error, message: "PTT init failed")
        #expect(store.latestError?.message == "PTT init failed")

        for index in 0..<200 {
            store.record(.app, level: .info, message: "info-\(index)")
        }

        #expect(store.entries.count == 200)
        #expect(store.latestError == nil)
    }

    @MainActor
    @Test func diagnosticsSnapshotIncludesMachineReadableContactProjection() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: TurboContactSummaryResponse(
                        userId: "user-blake",
                        handle: "@blake",
                        displayName: "Blake",
                        channelId: "channel-1",
                        isOnline: true,
                        hasIncomingRequest: false,
                        hasOutgoingRequest: false,
                        requestCount: 0,
                        isActiveConversation: false,
                        badgeStatus: "online"
                    )
                )
            ])
        )

        let snapshot = viewModel.diagnosticsSnapshot

        #expect(snapshot.contains("contact[@blake].isOnline=true"))
        #expect(snapshot.contains("contact[@blake].listState=idle"))
        #expect(snapshot.contains("contact[@blake].badgeStatus=online"))
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
        #expect(recorder.ephemeralPushTokens.count == 1)
        #expect(recorder.ephemeralPushTokens.first?.isEmpty == false)

        try client.beginTransmitting(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.didBeginTransmittingChannelIDs == [channelID])
        #expect(recorder.activatedAudioSessionCategories == [.playAndRecord])

        try client.stopTransmitting(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.didEndTransmittingChannelIDs == [channelID])
        #expect(recorder.deactivatedAudioSessionCategories == [.playAndRecord])

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
        #expect(recorder.ephemeralPushTokens.count == 1)
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

}

@MainActor
struct SimulatorScenarioTests {
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

struct SimulatorScenarioPlannerTests {
    @Test func scenarioPlannerSupportsDelayDropAndDuplicateDelivery() throws {
        let scheduled = try scheduledScenarioActions(
            for: [
                SimulatorScenarioAction(
                    actor: "a",
                    type: "connect",
                    peer: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: 400,
                    repeatCount: nil,
                    repeatIntervalMilliseconds: nil,
                    reorderIndex: nil,
                    drop: nil
                ),
                SimulatorScenarioAction(
                    actor: "b",
                    type: "refreshContactSummaries",
                    peer: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: nil,
                    repeatCount: 2,
                    repeatIntervalMilliseconds: 150,
                    reorderIndex: nil,
                    drop: nil
                ),
                SimulatorScenarioAction(
                    actor: "a",
                    type: "refreshInvites",
                    peer: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: 50,
                    repeatCount: nil,
                    repeatIntervalMilliseconds: nil,
                    reorderIndex: nil,
                    drop: true
                ),
            ]
        )

        #expect(scheduled.count == 3)
        #expect(scheduled.map { $0.actor } == ["b", "b", "a"])
        #expect(scheduled.map { $0.scheduledDelayMilliseconds } == [0, 150, 400])
        #expect(scheduled.map { $0.deliveryIndex } == [0, 1, 0])
        #expect(scheduled.map { $0.action.type } == ["refreshContactSummaries", "refreshContactSummaries", "connect"])
    }

    @Test func scenarioPlannerRejectsNegativeDelay() throws {
        #expect(throws: ScenarioFailure.self) {
            _ = try scheduledScenarioActions(
                for: [
                    SimulatorScenarioAction(
                        actor: "a",
                        type: "connect",
                        peer: nil,
                        route: nil,
                        signalKind: nil,
                        milliseconds: nil,
                        count: nil,
                        delayMilliseconds: -1,
                        repeatCount: nil,
                        repeatIntervalMilliseconds: nil,
                        reorderIndex: nil,
                        drop: nil
                    )
                ]
            )
        }
    }

    @Test func transportFaultRuntimeConsumesHTTPAndSignalRulesDeterministically() {
        let faults = TransportFaultRuntimeState()

        faults.setHTTPDelay(route: .contactSummaries, milliseconds: 250, count: 2)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 250)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 250)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 0)

        faults.setWebSocketSignalDelay(kind: .transmitStart, milliseconds: 400, count: 1)
        faults.duplicateNextWebSocketSignals(kind: .transmitStart, count: 1)
        faults.dropNextWebSocketSignals(kind: .transmitStop, count: 1)
        faults.reorderNextWebSocketSignals(kind: nil, count: 2)

        let startEnvelope = TurboSignalEnvelope(
            type: .transmitStart,
            channelId: "channel",
            fromUserId: "a",
            fromDeviceId: "device-a",
            toUserId: "b",
            toDeviceId: "device-b",
            payload: "{}"
        )
        let stopEnvelope = TurboSignalEnvelope(
            type: .transmitStop,
            channelId: "channel",
            fromUserId: "a",
            fromDeviceId: "device-a",
            toUserId: "b",
            toDeviceId: "device-b",
            payload: "{}"
        )

        switch faults.consumeWebSocketReorderResult(for: startEnvelope) {
        case .buffered:
            break
        case .deliver:
            Issue.record("Expected first reordered websocket signal to be buffered")
        }

        switch faults.consumeWebSocketReorderResult(for: stopEnvelope) {
        case .buffered:
            Issue.record("Expected reordered websocket fault to flush on the second signal")
        case .deliver(let envelopes):
            #expect(envelopes.map(\.type.rawValue) == ["transmit-stop", "transmit-start"])
        }

        let firstTransmitStartPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStart)
        #expect(firstTransmitStartPlan.delayMilliseconds == 400)
        #expect(firstTransmitStartPlan.duplicateDeliveries == 1)
        #expect(firstTransmitStartPlan.shouldDrop == false)

        let secondTransmitStartPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStart)
        #expect(secondTransmitStartPlan.delayMilliseconds == 0)
        #expect(secondTransmitStartPlan.duplicateDeliveries == 0)
        #expect(secondTransmitStartPlan.shouldDrop == false)

        let transmitStopPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStop)
        #expect(transmitStopPlan.delayMilliseconds == 0)
        #expect(transmitStopPlan.duplicateDeliveries == 0)
        #expect(transmitStopPlan.shouldDrop == true)
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
    var activatedAudioSessionCategories: [AVAudioSession.Category] = []
    var deactivatedAudioSessionCategories: [AVAudioSession.Category] = []
    var joinFailures: [JoinFailure] = []
    var incomingPushes: [(UUID, TurboPTTPushPayload)] = []
    var ephemeralPushTokens: [Data] = []

    var callbacks: PTTSystemClientCallbacks {
        PTTSystemClientCallbacks(
            receivedEphemeralPushToken: { [weak self] token in
                self?.ephemeralPushTokens.append(token)
            },
            receivedIncomingPush: { [weak self] channelID, payload in
                self?.incomingPushes.append((channelID, payload))
            },
            willReturnIncomingPushResult: { _, _, _ in },
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
            didActivateAudioSession: { [weak self] session in
                self?.activatedAudioSessionCategories.append(session.category)
            },
            didDeactivateAudioSession: { [weak self] session in
                self?.deactivatedAudioSessionCategories.append(session.category)
            },
            willRequestRestoredChannelDescriptor: { _ in },
            descriptorForRestoredChannel: { _ in
                PTChannelDescriptor(name: "Restored", image: nil)
            },
            restoredChannel: { _ in }
        )
    }
}

private final class RecordingMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?
    private(set) var state: MediaConnectionState = .idle
    private(set) var closedDeactivateAudioSessionFlags: [Bool] = []

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {}

    func start(
        activationMode _: MediaSessionActivationMode,
        startupMode _: MediaSessionStartupMode
    ) async throws {
        state = .connected
        delegate?.mediaSession(self, didChange: .connected)
    }

    func startSendingAudio() async throws {}

    func stopSendingAudio() async throws {}

    func receiveRemoteAudioChunk(_ payload: String) async {}

    func close(deactivateAudioSession: Bool) {
        closedDeactivateAudioSessionFlags.append(deactivateAudioSession)
        state = .closed
        delegate?.mediaSession(self, didChange: .closed)
    }
}

private struct ScenarioFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private struct SimulatorScenarioConfig: Decodable {
    let name: String
    let baseURL: URL
    let requiresLocalBackend: Bool?
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
    let route: String?
    let signalKind: String?
    let milliseconds: Int?
    let count: Int?
    let delayMilliseconds: Int?
    let repeatCount: Int?
    let repeatIntervalMilliseconds: Int?
    let reorderIndex: Int?
    let drop: Bool?
}

private struct SimulatorScenarioExpectation: Decodable {
    let selectedHandle: String?
    let phase: String?
    let selectedStatus: String?
    let isJoined: Bool?
    let isTransmitting: Bool?
    let canTransmitNow: Bool?
    let pttTokenRegistrationKind: String?
    let selected: SimulatorScenarioSelectedExpectation?
    let contacts: [SimulatorScenarioContactExpectation]?
    let backend: SimulatorScenarioBackendExpectation?

    var selectedExpectation: SimulatorScenarioSelectedExpectation? {
        if let selected {
            return selected
        }

        if selectedHandle != nil
            || phase != nil
            || selectedStatus != nil
            || isJoined != nil
            || isTransmitting != nil
            || canTransmitNow != nil
            || pttTokenRegistrationKind != nil
        {
            return SimulatorScenarioSelectedExpectation(
                handle: selectedHandle,
                phase: phase,
                status: selectedStatus,
                isJoined: isJoined,
                isTransmitting: isTransmitting,
                canTransmitNow: canTransmitNow,
                pttTokenRegistrationKind: pttTokenRegistrationKind
            )
        }

        return nil
    }
}

private struct SimulatorScenarioSelectedExpectation: Decodable {
    let handle: String?
    let phase: String?
    let status: String?
    let isJoined: Bool?
    let isTransmitting: Bool?
    let canTransmitNow: Bool?
    let pttTokenRegistrationKind: String?
}

private struct SimulatorScenarioContactExpectation: Decodable {
    let handle: String
    let isOnline: Bool?
    let listState: String?
    let badgeStatus: String?
    let requestRelationship: String?
    let hasIncomingRequest: Bool?
    let hasOutgoingRequest: Bool?
    let requestCount: Int?
}

private struct SimulatorScenarioBackendExpectation: Decodable {
    let channelStatus: String?
    let readiness: String?
    let remoteAudioReadiness: String?
    let remoteWakeCapabilityKind: String?
    let membership: String?
    let requestRelationship: String?
    let selfJoined: Bool?
    let peerJoined: Bool?
    let peerDeviceConnected: Bool?
    let canTransmit: Bool?
    let webSocketConnected: Bool?
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

private struct ScheduledSimulatorScenarioAction {
    let actor: String
    let action: SimulatorScenarioAction
    let scheduledDelayMilliseconds: Int
    let declarationIndex: Int
    let deliveryIndex: Int
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
    viewModel.automaticDiagnosticsPublishEnabled = false
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
        return try runnableScenarioSpecs(
            allSpecs,
            filter: nil,
            baseURLOverride: runtimeConfig.baseURL
        )
    }

    let filtered = try runnableScenarioSpecs(
        allSpecs,
        filter: filter,
        baseURLOverride: runtimeConfig.baseURL
    )
    guard !filtered.isEmpty else {
        throw ScenarioFailure(
            message: "No runnable simulator scenarios matched filter \(filter.joined(separator: ",")) in \(scenariosDirectory.path)"
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
        requiresLocalBackend: spec.requiresLocalBackend,
        participants: overriddenParticipants,
        steps: spec.steps
    )
}

private func runnableScenarioSpecs(
    _ specs: [SimulatorScenarioConfig],
    filter: [String]?,
    baseURLOverride: URL?
) throws -> [SimulatorScenarioConfig] {
    let requestedSpecs: [SimulatorScenarioConfig]
    if let filter, !filter.isEmpty {
        requestedSpecs = specs.filter { filter.contains($0.name) }
        guard !requestedSpecs.isEmpty else {
            throw ScenarioFailure(message: "No simulator scenarios matched filter \(filter.joined(separator: ","))")
        }
    } else {
        requestedSpecs = specs
    }

    var runnable: [SimulatorScenarioConfig] = []
    var localOnlyMismatches: [String] = []

    for spec in requestedSpecs {
        let effectiveBaseURL = baseURLOverride ?? spec.baseURL
        if spec.requiresLocalBackend == true && !scenarioBaseURLIsLocal(effectiveBaseURL) {
            localOnlyMismatches.append(spec.name)
            continue
        }
        runnable.append(spec)
    }

    if let filter, !filter.isEmpty, !localOnlyMismatches.isEmpty {
        throw ScenarioFailure(
            message: "Scenario(s) require a local backend: \(localOnlyMismatches.joined(separator: ", "))"
        )
    }

    return runnable
}

private func scenarioBaseURLIsLocal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

@MainActor
private func executeSimulatorScenario(_ spec: SimulatorScenarioConfig) async throws {
    for participant in spec.participants.values {
        try await resetAllDevelopmentState(baseURL: spec.baseURL, handle: participant.handle)
    }

    var viewModels = Dictionary(uniqueKeysWithValues: spec.participants.map { actor, participant in
        (
            actor,
            makeSimulatorScenarioViewModel(
                baseURL: spec.baseURL,
                handle: participant.handle,
                deviceID: participant.deviceId
            )
        )
    })

    func currentParticipants() -> [PTTViewModel] {
        Array(viewModels.values)
    }

    do {
        for participant in currentParticipants() {
            await participant.initializeIfNeeded()
        }
        try await stabilizeScenario(currentParticipants())
        try await waitForScenario(
            "participants become mutually discoverable",
            participants: currentParticipants(),
            timeoutNanoseconds: 60_000_000_000
        ) {
            await scenarioParticipantsAreDiscoverable(spec: spec, viewModels: viewModels)
        }

        for step in spec.steps {
            let scheduledActions = try scheduledScenarioActions(for: step.actions)
            var elapsedMilliseconds = 0

            for scheduledAction in scheduledActions {
                let delayBeforeDelivery = scheduledAction.scheduledDelayMilliseconds - elapsedMilliseconds
                if delayBeforeDelivery > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delayBeforeDelivery) * 1_000_000)
                    elapsedMilliseconds = scheduledAction.scheduledDelayMilliseconds
                }

                let action = scheduledAction.action
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
                case "ensureDirectChannel":
                    guard let peerActor = action.peer,
                          let peer = spec.participants[peerActor],
                          let backend = participant.backendServices else {
                        throw ScenarioFailure(message: "ensureDirectChannel requires a known peer actor and backend")
                    }
                    _ = try await backend.directChannel(otherHandle: peer.handle)
                    await participant.refreshContactSummaries()
                    if let selectedContactID = participant.selectedContact?.id {
                        await participant.refreshChannelState(for: selectedContactID)
                    }
                case "heartbeatPresence":
                    guard let backend = participant.backendServices else {
                        throw ScenarioFailure(message: "heartbeatPresence requires an initialized backend")
                    }
                    _ = try await backend.heartbeatPresence()
                case "refreshContactSummaries":
                    await participant.refreshContactSummaries()
                case "refreshInvites":
                    await participant.refreshInvites()
                case "refreshChannelState":
                    guard let selectedContactID = participant.selectedContact?.id else {
                        throw ScenarioFailure(message: "refreshChannelState requires a selected contact")
                    }
                    await participant.refreshChannelState(for: selectedContactID)
                case "resetTransportFaults":
                    participant.resetTransportFaults()
                case "setHTTPDelay":
                    guard let routeText = action.route,
                          let route = TransportFaultHTTPRoute(rawValue: routeText) else {
                        throw ScenarioFailure(message: "setHTTPDelay requires a known route")
                    }
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(message: "setHTTPDelay requires a non-negative milliseconds value")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "setHTTPDelay requires count >= 1")
                    }
                    participant.setHTTPTransportDelay(route: route, milliseconds: milliseconds, count: count)
                case "setWebSocketSignalDelay":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "setWebSocketSignalDelay requires a known signalKind")
                    }
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(
                            message: "setWebSocketSignalDelay requires a non-negative milliseconds value"
                        )
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "setWebSocketSignalDelay requires count >= 1")
                    }
                    participant.setIncomingWebSocketSignalDelay(
                        kind: signalKind,
                        milliseconds: milliseconds,
                        count: count
                    )
                case "dropNextWebSocketSignals":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "dropNextWebSocketSignals requires a known signalKind")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "dropNextWebSocketSignals requires count >= 1")
                    }
                    participant.dropNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "duplicateNextWebSocketSignals":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "duplicateNextWebSocketSignals requires a known signalKind")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "duplicateNextWebSocketSignals requires count >= 1")
                    }
                    participant.duplicateNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "reorderNextWebSocketSignals":
                    let signalKind: TurboSignalKind?
                    if let signalKindText = action.signalKind {
                        guard let parsedKind = TurboSignalKind(rawValue: signalKindText) else {
                            throw ScenarioFailure(message: "reorderNextWebSocketSignals requires a known signalKind")
                        }
                        signalKind = parsedKind
                    } else {
                        signalKind = nil
                    }
                    let count = action.count ?? 2
                    guard count >= 2 else {
                        throw ScenarioFailure(message: "reorderNextWebSocketSignals requires count >= 2")
                    }
                    participant.reorderNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "disconnectWebSocket":
                    participant.disconnectBackendWebSocket()
                case "reconnectWebSocket":
                    guard let backend = participant.backendServices, backend.supportsWebSocket else {
                        throw ScenarioFailure(message: "reconnectWebSocket requires an initialized websocket backend")
                    }
                    backend.resumeWebSocket()
                    try await backend.waitForWebSocketConnection()
                case "reconnectBackend":
                    await participant.reconnectBackendControlPlane()
                case "reconcileSelectedSession":
                    await participant.reconcileSelectedSessionIfNeeded()
                case "restartApp":
                    guard let scenarioParticipant = spec.participants[action.actor] else {
                        throw ScenarioFailure(message: "restartApp requires a known participant")
                    }
                    participant.resetLocalDevState(backendStatus: "Scenario restart")
                    let replacement = makeSimulatorScenarioViewModel(
                        baseURL: spec.baseURL,
                        handle: scenarioParticipant.handle,
                        deviceID: scenarioParticipant.deviceId
                    )
                    viewModels[action.actor] = replacement
                    await replacement.initializeIfNeeded()
                    try await stabilizeScenario(currentParticipants())
                    try await waitForScenario(
                        "\(action.actor) restarts and becomes discoverable",
                        participants: currentParticipants(),
                        timeoutNanoseconds: 60_000_000_000
                    ) {
                        await scenarioParticipantsAreDiscoverable(spec: spec, viewModels: viewModels)
                    }
                case "wait":
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(message: "wait requires a non-negative milliseconds value")
                    }
                    try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                default:
                    throw ScenarioFailure(message: "Unknown scenario action type \(action.type)")
                }
            }

            if scenarioStepRequiresImmediateStabilization(step) {
                try await stabilizeScenario(currentParticipants())
            }

            if let expectations = step.expectEventually {
                try await waitForScenario(step.description, participants: currentParticipants()) {
                    scenarioExpectationsMatch(expectations, viewModels: viewModels)
                }
            }
        }

        try await publishScenarioDiagnosticsArtifacts(spec: spec, viewModels: viewModels)
        await tearDownSimulatorScenarioParticipants(currentParticipants())
    } catch {
        try? await publishScenarioDiagnosticsArtifacts(spec: spec, viewModels: viewModels)
        await tearDownSimulatorScenarioParticipants(currentParticipants())
        throw error
    }
}

private func scheduledScenarioActions(
    for actions: [SimulatorScenarioAction]
) throws -> [ScheduledSimulatorScenarioAction] {
    var scheduled: [ScheduledSimulatorScenarioAction] = []

    for (declarationIndex, action) in actions.enumerated() {
        let isDropped = action.drop ?? false
        if isDropped {
            continue
        }

        let initialDelayMilliseconds = action.delayMilliseconds ?? 0
        guard initialDelayMilliseconds >= 0 else {
            throw ScenarioFailure(message: "Scenario action \(action.type) requires a non-negative delayMilliseconds value")
        }

        let repeatCount = action.repeatCount ?? 1
        guard repeatCount >= 1 else {
            throw ScenarioFailure(message: "Scenario action \(action.type) requires repeatCount >= 1")
        }

        let repeatIntervalMilliseconds = action.repeatIntervalMilliseconds ?? 0
        guard repeatIntervalMilliseconds >= 0 else {
            throw ScenarioFailure(
                message: "Scenario action \(action.type) requires a non-negative repeatIntervalMilliseconds value"
            )
        }

        for deliveryIndex in 0..<repeatCount {
            scheduled.append(
                ScheduledSimulatorScenarioAction(
                    actor: action.actor,
                    action: action,
                    scheduledDelayMilliseconds: initialDelayMilliseconds + (deliveryIndex * repeatIntervalMilliseconds),
                    declarationIndex: declarationIndex,
                    deliveryIndex: deliveryIndex
                )
            )
        }
    }

    return scheduled.sorted { lhs, rhs in
        if lhs.scheduledDelayMilliseconds != rhs.scheduledDelayMilliseconds {
            return lhs.scheduledDelayMilliseconds < rhs.scheduledDelayMilliseconds
        }
        if lhs.declarationIndex != rhs.declarationIndex {
            let lhsOrder = lhs.action.reorderIndex ?? lhs.declarationIndex
            let rhsOrder = rhs.action.reorderIndex ?? rhs.declarationIndex
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.declarationIndex < rhs.declarationIndex
        }
        return lhs.deliveryIndex < rhs.deliveryIndex
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
    let scenarioRunID = UUID().uuidString.lowercased()
    for (actor, participant) in viewModels {
        let expectedDeviceID = spec.participants[actor]?.deviceId ?? "<missing>"
        let expectedHandle = spec.participants[actor]?.handle ?? participant.currentDevUserHandle
        let artifact = SimulatorScenarioDiagnosticsArtifact(
            scenarioName: spec.name,
            handle: expectedHandle,
            deviceId: expectedDeviceID,
            baseURL: spec.baseURL.absoluteString,
            selectedHandle: participant.selectedContact?.handle,
            appVersion: "scenario:\(spec.name):\(scenarioRunID):\(expectedDeviceID)",
            snapshot: participant.diagnosticsSnapshot,
            transcript: participant.diagnosticsTranscript
        )
        try await publishScenarioDiagnosticsArtifact(artifact)
        try await verifyScenarioDiagnosticsArtifactPublished(
            baseURL: spec.baseURL,
            handle: artifact.handle,
            deviceID: artifact.deviceId,
            expectedAppVersion: artifact.appVersion
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
        let projection = participant.stateMachineProjection

        if let selected = expected.selectedExpectation,
           !scenarioSelectedExpectationMatches(selected, projection: projection)
        {
            return false
        }

        if let contacts = expected.contacts,
           !scenarioContactExpectationsMatch(contacts, projection: projection)
        {
            return false
        }

        if let backend = expected.backend,
           !scenarioBackendExpectationMatches(backend, projection: projection)
        {
            return false
        }
    }

    return true
}

private func scenarioSelectedExpectationMatches(
    _ expected: SimulatorScenarioSelectedExpectation,
    projection: StateMachineProjection
) -> Bool {
    let selected = projection.selectedSession

    if let handle = expected.handle,
       selected.selectedHandle != handle {
        return false
    }

    var phaseMatch: SimulatorScenarioPhaseMatch = .exact
    if let phase = expected.phase {
        guard let matched = simulatorScenarioPhaseMatch(expected: phase, actual: selected.selectedPhase) else {
            return false
        }
        phaseMatch = matched
    }

    if let status = expected.status,
       selected.statusMessage != status {
        return false
    }

    if let isJoined = expected.isJoined,
       !(phaseMatch == .progressed && isJoined == false) && selected.isJoined != isJoined {
        return false
    }

    if let isTransmitting = expected.isTransmitting,
       !(phaseMatch == .progressed && isTransmitting == false) && selected.isTransmitting != isTransmitting {
        return false
    }

    if let canTransmitNow = expected.canTransmitNow,
       !(phaseMatch == .progressed && canTransmitNow == false) && selected.canTransmitNow != canTransmitNow {
        return false
    }
    if let pttTokenRegistrationKind = expected.pttTokenRegistrationKind,
       selected.pttTokenRegistrationKind != pttTokenRegistrationKind {
        return false
    }

    return true
}

private func scenarioContactExpectationsMatch(
    _ expectedContacts: [SimulatorScenarioContactExpectation],
    projection: StateMachineProjection
) -> Bool {
    for expected in expectedContacts {
        guard let contact = projection.contact(handle: expected.handle) else {
            return false
        }

        if let isOnline = expected.isOnline,
           contact.isOnline != isOnline {
            return false
        }
        if let listState = expected.listState,
           contact.listState != listState {
            return false
        }
        if let badgeStatus = expected.badgeStatus,
           contact.badgeStatus != badgeStatus {
            return false
        }
        if let requestRelationship = expected.requestRelationship,
           contact.requestRelationship != requestRelationship {
            return false
        }
        if let hasIncomingRequest = expected.hasIncomingRequest,
           contact.hasIncomingRequest != hasIncomingRequest {
            return false
        }
        if let hasOutgoingRequest = expected.hasOutgoingRequest,
           contact.hasOutgoingRequest != hasOutgoingRequest {
            return false
        }
        if let requestCount = expected.requestCount,
           contact.requestCount != requestCount {
            return false
        }
    }

    return true
}

private func scenarioBackendExpectationMatches(
    _ expected: SimulatorScenarioBackendExpectation,
    projection: StateMachineProjection
) -> Bool {
    let selected = projection.selectedSession

    if let channelStatus = expected.channelStatus,
       selected.backendChannelStatus != channelStatus {
        return false
    }
    if let readiness = expected.readiness,
       selected.backendReadiness != readiness {
        return false
    }
    if let remoteAudioReadiness = expected.remoteAudioReadiness,
       selected.remoteAudioReadiness != remoteAudioReadiness {
        return false
    }
    if let remoteWakeCapabilityKind = expected.remoteWakeCapabilityKind,
       selected.remoteWakeCapabilityKind != remoteWakeCapabilityKind {
        return false
    }
    if let membership = expected.membership,
       selected.backendMembership != membership {
        return false
    }
    if let requestRelationship = expected.requestRelationship,
       selected.backendRequestRelationship != requestRelationship {
        return false
    }
    if let selfJoined = expected.selfJoined,
       selected.backendSelfJoined != selfJoined {
        return false
    }
    if let peerJoined = expected.peerJoined,
       selected.backendPeerJoined != peerJoined {
        return false
    }
    if let peerDeviceConnected = expected.peerDeviceConnected,
       selected.backendPeerDeviceConnected != peerDeviceConnected {
        return false
    }
    if let canTransmit = expected.canTransmit,
       selected.backendCanTransmit != canTransmit {
        return false
    }
    if let webSocketConnected = expected.webSocketConnected,
       projection.isWebSocketConnected != webSocketConnected {
        return false
    }

    return true
}

private func simulatorScenarioPhaseMatch<Phase: CustomStringConvertible>(
    expected expectedPhase: String,
    actual actualPhase: Phase
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
        let projection = participant.stateMachineProjection
        let fields = [
            "devUserHandle=\(participant.currentDevUserHandle)",
            "selectedContact=\(projection.selectedSession.selectedHandle ?? "none")",
            "selectedPeerPhase=\(projection.selectedSession.selectedPhase)",
            "selectedPeerStatus=\(projection.selectedSession.statusMessage)",
            "pendingAction=\(String(describing: participant.sessionCoordinator.pendingAction))",
            "isJoined=\(projection.selectedSession.isJoined)",
            "isTransmitting=\(projection.selectedSession.isTransmitting)",
            "backendChannelStatus=\(projection.selectedSession.backendChannelStatus ?? "none")",
            "backendSelfJoined=\(projection.selectedSession.backendSelfJoined.map(String.init(describing:)) ?? "none")",
            "backendPeerJoined=\(projection.selectedSession.backendPeerJoined.map(String.init(describing:)) ?? "none")",
            "backendPeerDeviceConnected=\(projection.selectedSession.backendPeerDeviceConnected.map(String.init(describing:)) ?? "none")",
            "systemSession=\(String(describing: participant.systemSessionState))",
            "localJoinFailure=\(participant.pttCoordinator.state.lastJoinFailure.map { String(describing: $0) } ?? "none")",
        ]
        let contactDetails = projection.contacts.map { contact in
            "contact[\(contact.handle)]={online:\(contact.isOnline),list:\(contact.listState),badge:\(contact.badgeStatus ?? "none")}"
        }
        return (fields + contactDetails).joined(separator: " ")
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
    let reportedAppVersion = report?["appVersion"] as? String
    guard reportedDeviceID == artifact.deviceId,
          reportedAppVersion == artifact.appVersion else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw ScenarioFailure(
            message: "Scenario diagnostics upload returned unexpected report for \(artifact.handle) expected device \(artifact.deviceId) appVersion \(artifact.appVersion) got device \(reportedDeviceID ?? "none") appVersion \(reportedAppVersion ?? "none"): \(body)"
        )
    }
}

private func verifyScenarioDiagnosticsArtifactPublished(
    baseURL: URL,
    handle: String,
    deviceID: String,
    expectedAppVersion: String,
    maxAttempts: Int = 10
) async throws {
    let endpointURL = baseURL.appending(path: "/v1/dev/diagnostics/latest/\(deviceID)/")
    for attempt in 1...maxAttempts {
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
        let reportedAppVersion = report?["appVersion"] as? String
        if reportedDeviceID == deviceID,
           reportedAppVersion == expectedAppVersion {
            return
        }
        if attempt < maxAttempts {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            continue
        }

        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw ScenarioFailure(
            message: "Scenario diagnostics verification returned unexpected report for \(handle) expected device \(deviceID) appVersion \(expectedAppVersion) got device \(reportedDeviceID ?? "none") appVersion \(reportedAppVersion ?? "none"): \(body)"
        )
    }

    throw ScenarioFailure(
        message: "Scenario diagnostics verification failed for \(handle) \(deviceID) after \(maxAttempts) attempts"
    )
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

private func makeChannelReadiness(
    status: TurboChannelReadinessStatus,
    selfHasActiveDevice: Bool = true,
    peerHasActiveDevice: Bool = true,
    localAudioReadiness: RemoteAudioReadinessState? = nil,
    remoteAudioReadiness: RemoteAudioReadinessState? = nil,
    localWakeCapability: RemoteWakeCapabilityState = .unavailable,
    remoteWakeCapability: RemoteWakeCapabilityState = .unavailable
) -> TurboChannelReadinessResponse {
    let resolvedLocalAudioReadiness = localAudioReadiness ?? (selfHasActiveDevice ? .ready : .unknown)
    let resolvedRemoteAudioReadiness = remoteAudioReadiness ?? (peerHasActiveDevice ? .ready : .unknown)
    return TurboChannelReadinessResponse(
        channelId: "channel",
        peerUserId: "peer",
        selfHasActiveDevice: selfHasActiveDevice,
        peerHasActiveDevice: peerHasActiveDevice,
        activeTransmitterUserId: status.activeTransmitterUserId,
        activeTransmitExpiresAt: nil,
        status: status.kind,
        audioReadinessPayload: TurboChannelAudioReadinessPayload(
            selfReadiness: TurboAudioReadinessStatusPayload(kind: {
                switch resolvedLocalAudioReadiness {
                case .unknown:
                    return "unknown"
                case .waiting:
                    return "waiting"
                case .wakeCapable:
                    return "wake-capable"
                case .ready:
                    return "ready"
                }
            }()),
            peerReadiness: TurboAudioReadinessStatusPayload(kind: {
                switch resolvedRemoteAudioReadiness {
                case .unknown:
                    return "unknown"
                case .waiting:
                    return "waiting"
                case .wakeCapable:
                    return "wake-capable"
                case .ready:
                    return "ready"
                }
            }()),
            peerTargetDeviceId: peerHasActiveDevice ? "peer-device" : nil
        ),
        wakeReadinessPayload: TurboChannelWakeReadinessPayload(
            selfWakeCapability: TurboWakeCapabilityStatusPayload(
                kind: {
                    switch localWakeCapability {
                    case .unavailable:
                        return "unavailable"
                    case .wakeCapable:
                        return "wake-capable"
                    }
                }(),
                targetDeviceId: {
                    switch localWakeCapability {
                    case .unavailable:
                        return nil
                    case .wakeCapable(let targetDeviceId):
                        return targetDeviceId
                    }
                }()
            ),
            peerWakeCapability: TurboWakeCapabilityStatusPayload(
                kind: {
                    switch remoteWakeCapability {
                    case .unavailable:
                        return "unavailable"
                    case .wakeCapable:
                        return "wake-capable"
                    }
                }(),
                targetDeviceId: {
                    switch remoteWakeCapability {
                    case .unavailable:
                        return nil
                    case .wakeCapable(let targetDeviceId):
                        return targetDeviceId
                    }
                }()
            )
        )
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

private func makeInvite(
    direction: String,
    inviteId: String = UUID().uuidString,
    fromHandle: String = "@self",
    toHandle: String = "@avery",
    requestCount: Int = 1,
    createdAt: String = "2026-04-08T00:00:00Z",
    updatedAt: String? = nil
) -> TurboInviteResponse {
    TurboInviteResponse(
        inviteId: inviteId,
        fromUserId: "user-self",
        fromHandle: fromHandle,
        toUserId: "user-peer",
        toHandle: toHandle,
        channelId: "channel-1",
        status: "pending",
        direction: direction,
        requestCount: requestCount,
        createdAt: createdAt,
        updatedAt: updatedAt,
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
