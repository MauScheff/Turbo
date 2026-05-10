import Foundation

struct SelectedPeerSelection: Equatable {
    let contactID: UUID
    let contactName: String
    let contactIsOnline: Bool
    let contactPresence: ContactPresencePresentation

    init(
        contactID: UUID,
        contactName: String,
        contactIsOnline: Bool,
        contactPresence: ContactPresencePresentation? = nil
    ) {
        self.contactID = contactID
        self.contactName = contactName
        self.contactIsOnline = contactIsOnline
        self.contactPresence = contactPresence ?? (contactIsOnline ? .connected : .offline)
    }
}

struct SelectedPeerSessionState: Equatable {
    var selection: SelectedPeerSelection?
    var relationship: PairRelationshipState = .none
    var baseState: ConversationState = .idle
    var isJoined: Bool = false
    var localTransmit: LocalTransmitProjection = .idle
    var peerSignalIsTransmitting: Bool = false
    var activeChannelID: UUID?
    var systemSessionMatchesContact: Bool = false
    var systemSessionState: SystemPTTSessionState = .none
    var pendingAction: PendingSessionAction = .none
    var pendingConnectAcceptedIncomingRequest = false
    var requesterAutoJoinOnPeerAcceptanceEnabled = true
    var requesterAutoJoinOnPeerAcceptanceArmed = false
    var requesterAutoJoinOnPeerAcceptanceDispatchInFlight = false
    var requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
    var localRestoreDispatchInFlightContactID: UUID?
    var localJoinFailure: PTTJoinFailure?
    var channel: ChannelReadinessSnapshot?
    var mediaState: MediaConnectionState = .idle
    var localRelayTransportReady = true
    var directMediaPathActive = false
    var firstTalkStartupProfile: FirstTalkStartupProfile = .relayWarm
    var incomingWakeActivationState: IncomingWakeActivationState?
    var backendSignalingJoinRecoveryActive = false
    var controlPlaneReconnectGraceActive = false
    var hadConnectedSessionContinuity = false
    var durableSessionProjection: DurableSessionProjection = .inactive
    var connectedExecutionProjection: ConnectedExecutionProjection?
    var connectedControlPlaneProjection: ConnectedControlPlaneProjection = .unavailable
    var selectedPeerState: SelectedPeerState = .initial
    var reconciliationAction: SessionReconciliationAction = .none
    var interruptedConnectionAttemptContactID: UUID?

    static let initial = SelectedPeerSessionState()
}

struct SelectedPeerSyncSnapshot: Equatable {
    let selection: SelectedPeerSelection
    let relationship: PairRelationshipState
    let baseState: ConversationState
    let channel: ChannelReadinessSnapshot?
    let isJoined: Bool
    let activeChannelID: UUID?
    let pendingAction: PendingSessionAction
    let pendingConnectAcceptedIncomingRequest: Bool
    let requesterAutoJoinOnPeerAcceptanceEnabled: Bool
    let localTransmit: LocalTransmitProjection
    let peerSignalIsTransmitting: Bool
    let systemSessionState: SystemPTTSessionState
    let systemSessionMatchesContact: Bool
    let mediaState: MediaConnectionState
    let localRelayTransportReady: Bool
    let directMediaPathActive: Bool
    let firstTalkStartupProfile: FirstTalkStartupProfile
    let incomingWakeActivationState: IncomingWakeActivationState?
    let backendSignalingJoinRecoveryActive: Bool
    let controlPlaneReconnectGraceActive: Bool
    let localJoinFailure: PTTJoinFailure?

    init(
        selection: SelectedPeerSelection,
        relationship: PairRelationshipState,
        baseState: ConversationState,
        channel: ChannelReadinessSnapshot?,
        isJoined: Bool,
        activeChannelID: UUID?,
        pendingAction: PendingSessionAction,
        pendingConnectAcceptedIncomingRequest: Bool,
        requesterAutoJoinOnPeerAcceptanceEnabled: Bool,
        localTransmit: LocalTransmitProjection,
        peerSignalIsTransmitting: Bool,
        systemSessionState: SystemPTTSessionState,
        systemSessionMatchesContact: Bool,
        mediaState: MediaConnectionState,
        localRelayTransportReady: Bool,
        directMediaPathActive: Bool,
        firstTalkStartupProfile: FirstTalkStartupProfile = .relayWarm,
        incomingWakeActivationState: IncomingWakeActivationState?,
        backendSignalingJoinRecoveryActive: Bool = false,
        controlPlaneReconnectGraceActive: Bool = false,
        localJoinFailure: PTTJoinFailure?
    ) {
        self.selection = selection
        self.relationship = relationship
        self.baseState = baseState
        self.channel = channel
        self.isJoined = isJoined
        self.activeChannelID = activeChannelID
        self.pendingAction = pendingAction
        self.pendingConnectAcceptedIncomingRequest = pendingConnectAcceptedIncomingRequest
        self.requesterAutoJoinOnPeerAcceptanceEnabled = requesterAutoJoinOnPeerAcceptanceEnabled
        self.localTransmit = localTransmit
        self.peerSignalIsTransmitting = peerSignalIsTransmitting
        self.systemSessionState = systemSessionState
        self.systemSessionMatchesContact = systemSessionMatchesContact
        self.mediaState = mediaState
        self.localRelayTransportReady = localRelayTransportReady
        self.directMediaPathActive = directMediaPathActive
        self.firstTalkStartupProfile = firstTalkStartupProfile
        self.incomingWakeActivationState = incomingWakeActivationState
        self.backendSignalingJoinRecoveryActive = backendSignalingJoinRecoveryActive
        self.controlPlaneReconnectGraceActive = controlPlaneReconnectGraceActive
        self.localJoinFailure = localJoinFailure
    }
}

enum SelectedPeerEvent: Equatable {
    case syncUpdated(SelectedPeerSyncSnapshot)
    case selectedContactChanged(SelectedPeerSelection?)
    case relationshipUpdated(PairRelationshipState)
    case baseStateUpdated(ConversationState)
    case channelUpdated(ChannelReadinessSnapshot?)
    case localSessionUpdated(
        isJoined: Bool,
        activeChannelID: UUID?,
        pendingAction: PendingSessionAction,
        pendingConnectAcceptedIncomingRequest: Bool,
        localJoinFailure: PTTJoinFailure?
    )
    case shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: Bool)
    case localTransmitUpdated(LocalTransmitProjection)
    case peerSignalTransmittingUpdated(Bool)
    case systemSessionUpdated(SystemPTTSessionState, matchesSelectedContact: Bool)
    case mediaStateUpdated(MediaConnectionState)
    case incomingWakeActivationStateUpdated(IncomingWakeActivationState?)
    case requesterAutoJoinCancelled(contactID: UUID)
    case connectionAttemptTimedOut(contactID: UUID)
    case joinRequested
    case disconnectRequested
    case reconcileRequested
}

enum SelectedPeerEffect: Equatable {
    case requestConnection(contactID: UUID)
    case joinReadyPeer(contactID: UUID)
    case disconnect(contactID: UUID)
    case restoreLocalSession(contactID: UUID)
    case teardownLocalSession(contactID: UUID)
    case clearStaleBackendMembership(contactID: UUID)
}

struct SelectedPeerTransition: Equatable {
    var state: SelectedPeerSessionState
    var effects: [SelectedPeerEffect] = []
}

enum SelectedPeerReducer {
    static func reduce(
        state: SelectedPeerSessionState,
        event: SelectedPeerEvent
    ) -> SelectedPeerTransition {
        var nextState = state
        var effects: [SelectedPeerEffect] = []

        switch event {
        case .syncUpdated(let snapshot):
            if nextState.selection?.contactID == snapshot.selection.contactID {
                nextState.selection = snapshot.selection
            } else {
                var resetState = SelectedPeerSessionState.initial
                resetState.selection = snapshot.selection
                nextState = resetState
            }
            nextState.relationship = snapshot.relationship
            nextState.baseState = snapshot.baseState
            nextState.channel = snapshot.channel
            applyLocalSessionUpdate(
                to: &nextState,
                isJoined: snapshot.isJoined,
                activeChannelID: snapshot.activeChannelID,
                pendingAction: snapshot.pendingAction,
                pendingConnectAcceptedIncomingRequest: snapshot.pendingConnectAcceptedIncomingRequest,
                localJoinFailure: snapshot.localJoinFailure
            )
            applyShortcutPolicyUpdate(
                to: &nextState,
                requesterAutoJoinOnPeerAcceptanceEnabled: snapshot.requesterAutoJoinOnPeerAcceptanceEnabled
            )
            nextState.localTransmit = snapshot.localTransmit
            nextState.peerSignalIsTransmitting = snapshot.peerSignalIsTransmitting
            nextState.systemSessionState = snapshot.systemSessionState
            nextState.systemSessionMatchesContact = snapshot.systemSessionMatchesContact
            nextState.mediaState = snapshot.mediaState
            nextState.localRelayTransportReady = snapshot.localRelayTransportReady
            nextState.directMediaPathActive = snapshot.directMediaPathActive
            nextState.firstTalkStartupProfile = snapshot.firstTalkStartupProfile
            nextState.incomingWakeActivationState = snapshot.incomingWakeActivationState
            nextState.backendSignalingJoinRecoveryActive = snapshot.backendSignalingJoinRecoveryActive
            nextState.controlPlaneReconnectGraceActive = snapshot.controlPlaneReconnectGraceActive
        case .selectedContactChanged(let selection):
            switch selection {
            case .none:
                nextState = .initial
            case .some(let selection):
                if nextState.selection?.contactID == selection.contactID {
                    nextState.selection = selection
                } else {
                    var resetState = SelectedPeerSessionState.initial
                    resetState.selection = selection
                    nextState = resetState
                }
            }
        case .relationshipUpdated(let relationship):
            nextState.relationship = relationship
        case .baseStateUpdated(let baseState):
            nextState.baseState = baseState
        case .channelUpdated(let channel):
            nextState.channel = channel
        case .localSessionUpdated(
            let isJoined,
            let activeChannelID,
            let pendingAction,
            let pendingConnectAcceptedIncomingRequest,
            let localJoinFailure
        ):
            applyLocalSessionUpdate(
                to: &nextState,
                isJoined: isJoined,
                activeChannelID: activeChannelID,
                pendingAction: pendingAction,
                pendingConnectAcceptedIncomingRequest: pendingConnectAcceptedIncomingRequest,
                localJoinFailure: localJoinFailure
            )
        case .shortcutPolicyUpdated(let requesterAutoJoinOnPeerAcceptanceEnabled):
            applyShortcutPolicyUpdate(
                to: &nextState,
                requesterAutoJoinOnPeerAcceptanceEnabled: requesterAutoJoinOnPeerAcceptanceEnabled
            )
        case .localTransmitUpdated(let localTransmit):
            nextState.localTransmit = localTransmit
        case .peerSignalTransmittingUpdated(let peerSignalIsTransmitting):
            nextState.peerSignalIsTransmitting = peerSignalIsTransmitting
        case .systemSessionUpdated(let systemSessionState, let matchesSelectedContact):
            nextState.systemSessionState = systemSessionState
            nextState.systemSessionMatchesContact = matchesSelectedContact
        case .mediaStateUpdated(let mediaState):
            nextState.mediaState = mediaState
        case .incomingWakeActivationStateUpdated(let incomingWakeActivationState):
            nextState.incomingWakeActivationState = incomingWakeActivationState
        case .requesterAutoJoinCancelled(let contactID):
            if nextState.selection?.contactID == contactID {
                nextState.requesterAutoJoinOnPeerAcceptanceArmed = false
                nextState.requesterAutoJoinOnPeerAcceptanceDispatchInFlight = false
                nextState.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
            }
        case .connectionAttemptTimedOut(let contactID):
            guard nextState.selection?.contactID == contactID,
                  isInterruptibleConnectionAttempt(nextState.selectedPeerState) else {
                return SelectedPeerTransition(state: nextState)
            }
            nextState.requesterAutoJoinOnPeerAcceptanceArmed = false
            nextState.requesterAutoJoinOnPeerAcceptanceDispatchInFlight = false
            nextState.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
            nextState.interruptedConnectionAttemptContactID = contactID
            recomputeDerivedState(&nextState)
            return SelectedPeerTransition(state: nextState)
        case .joinRequested:
            recomputeDerivedState(&nextState)
            if let effect = joinEffect(for: nextState) {
                nextState.interruptedConnectionAttemptContactID = nil
                if shouldArmRequesterAutoJoinShortcut(state: nextState, effect: effect) {
                    nextState.requesterAutoJoinOnPeerAcceptanceArmed = true
                    nextState.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
                } else if case .joinReadyPeer = effect {
                    nextState.requesterAutoJoinOnPeerAcceptanceArmed = false
                    nextState.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
                }
                effects.append(effect)
            }
            return SelectedPeerTransition(state: nextState, effects: effects)
        case .disconnectRequested:
            nextState.interruptedConnectionAttemptContactID = nil
            recomputeDerivedState(&nextState)
            if let effect = disconnectEffect(for: nextState) {
                effects.append(effect)
            }
            return SelectedPeerTransition(state: nextState, effects: effects)
        case .reconcileRequested:
            recomputeDerivedState(&nextState)
            if let effect = reconciliationEffect(for: nextState) {
                if case .restoreLocalSession(let contactID) = effect {
                    nextState.localRestoreDispatchInFlightContactID = contactID
                }
                effects.append(effect)
            }
            return SelectedPeerTransition(state: nextState, effects: effects)
        }

        recomputeDerivedState(&nextState)
        if shouldArmRequesterAutoJoinForOutstandingOutgoingRequest(state: nextState) {
            nextState.requesterAutoJoinOnPeerAcceptanceArmed = true
            nextState.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = true
        } else if nextState.relationship.isOutgoingRequest,
                  nextState.requesterAutoJoinOnPeerAcceptanceArmed {
            nextState.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = true
        }
        if shouldClearRequesterAutoJoinShortcut(state: nextState) {
            nextState.requesterAutoJoinOnPeerAcceptanceArmed = false
            nextState.requesterAutoJoinOnPeerAcceptanceDispatchInFlight = false
            nextState.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
        }
        if let effect = autoJoinReadyPeerEffect(for: nextState) {
            nextState.requesterAutoJoinOnPeerAcceptanceArmed = false
            nextState.requesterAutoJoinOnPeerAcceptanceDispatchInFlight = true
            nextState.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
            if let selection = nextState.selection {
                nextState.selectedPeerState = SelectedPeerState(
                    contactID: selection.contactID,
                    contactName: selection.contactName,
                    relationship: nextState.relationship,
                    detail: .waitingForPeer(reason: .pendingJoin),
                    statusMessage: "Connecting...",
                    canTransmitNow: false
                )
            }
            effects.append(effect)
        } else if shouldProjectRequesterAutoJoinConnecting(state: nextState),
                  let selection = nextState.selection {
            nextState.selectedPeerState = SelectedPeerState(
                contactID: selection.contactID,
                contactName: selection.contactName,
                relationship: nextState.relationship,
                detail: .waitingForPeer(reason: .pendingJoin),
                statusMessage: "Connecting...",
                canTransmitNow: false
            )
        }
        return SelectedPeerTransition(state: nextState, effects: effects)
    }

    private static func recomputeDerivedState(_ state: inout SelectedPeerSessionState) {
        guard let selection = state.selection else {
            state.hadConnectedSessionContinuity = false
            state.durableSessionProjection = .inactive
            state.connectedExecutionProjection = nil
            state.connectedControlPlaneProjection = .unavailable
            state.selectedPeerState = .initial
            state.reconciliationAction = .none
            return
        }

        let hadConnectedSessionContinuity = state.hadConnectedSessionContinuity

        let context = ConversationDerivationContext(
            contactID: selection.contactID,
            selectedContactID: selection.contactID,
            baseState: state.baseState,
            contactName: selection.contactName,
            contactIsOnline: selection.contactIsOnline,
            contactPresence: selection.contactPresence,
            isJoined: state.isJoined,
            localTransmit: state.localTransmit,
            peerSignalIsTransmitting: state.peerSignalIsTransmitting,
            activeChannelID: state.activeChannelID,
            systemSessionMatchesContact: state.systemSessionMatchesContact,
            systemSessionState: state.systemSessionState,
            pendingAction: state.pendingAction,
            pendingConnectAcceptedIncomingRequest: state.pendingConnectAcceptedIncomingRequest,
            localJoinFailure: state.localJoinFailure,
            mediaState: state.mediaState,
            localMediaWarmupState: {
                switch state.mediaState {
                case .idle, .closed:
                    return .cold
                case .preparing:
                    return .prewarming
                case .connected:
                    return .ready
                case .failed:
                    return .failed
                }
            }(),
            localRelayTransportReady: state.localRelayTransportReady,
            directMediaPathActive: state.directMediaPathActive,
            firstTalkStartupProfile: state.firstTalkStartupProfile,
            incomingWakeActivationState: state.incomingWakeActivationState,
            backendSignalingJoinRecoveryActive: state.backendSignalingJoinRecoveryActive,
            controlPlaneReconnectGraceActive: state.controlPlaneReconnectGraceActive,
            hadConnectedSessionContinuity: hadConnectedSessionContinuity,
            channel: state.channel
        )

        let projection = ConversationStateMachine.projection(
            for: context,
            relationship: state.relationship
        )
        state.hadConnectedSessionContinuity = updatedConnectedSessionContinuity(
            previous: hadConnectedSessionContinuity,
            projection: projection,
            channel: state.channel
        )
        state.durableSessionProjection = projection.durableSession
        state.connectedExecutionProjection = projection.connectedExecution
        state.connectedControlPlaneProjection = projection.connectedControlPlane
        state.selectedPeerState = projection.selectedPeerState
        state.reconciliationAction = projection.reconciliationAction
        clearCompletedLocalRestoreDispatchIfNeeded(&state)
        clearCompletedInterruptedConnectionAttemptIfNeeded(&state)

        if shouldProjectWakeReadyForConnectedDegradation(
            state: state,
            projection: projection
        ) {
            state.connectedControlPlaneProjection = .wakeReady
            state.selectedPeerState = SelectedPeerState(
                contactID: selection.contactID,
                contactName: selection.contactName,
                relationship: state.relationship,
                detail: .wakeReady,
                statusMessage: "Hold to talk to wake \(selection.contactName)",
                canTransmitNow: false
            )
        }

        if let interruptedContactID = state.interruptedConnectionAttemptContactID,
           interruptedContactID == selection.contactID,
           shouldProjectInterruptedConnectionAttempt(state) {
            state.selectedPeerState = SelectedPeerState(
                contactID: selection.contactID,
                contactName: selection.contactName,
                relationship: state.relationship,
                detail: .localJoinFailed(recoveryMessage: "Connection interrupted"),
                statusMessage: "Connection interrupted",
                canTransmitNow: false
            )
        }
    }

    private static func applyLocalSessionUpdate(
        to state: inout SelectedPeerSessionState,
        isJoined: Bool,
        activeChannelID: UUID?,
        pendingAction: PendingSessionAction,
        pendingConnectAcceptedIncomingRequest: Bool,
        localJoinFailure: PTTJoinFailure?
    ) {
        state.isJoined = isJoined
        state.activeChannelID = activeChannelID
        state.pendingAction = pendingAction
        state.pendingConnectAcceptedIncomingRequest = pendingConnectAcceptedIncomingRequest
        state.localJoinFailure = localJoinFailure
        if isJoined || activeChannelID != nil {
            state.interruptedConnectionAttemptContactID = nil
            state.requesterAutoJoinOnPeerAcceptanceArmed = false
            state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight = false
            state.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
        } else if pendingAction.pendingJoinContactID != nil {
            state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight = false
        }
    }

    private static func clearCompletedLocalRestoreDispatchIfNeeded(
        _ state: inout SelectedPeerSessionState
    ) {
        guard let contactID = state.localRestoreDispatchInFlightContactID else { return }
        guard state.selection?.contactID == contactID else {
            state.localRestoreDispatchInFlightContactID = nil
            return
        }

        if state.isJoined
            || state.activeChannelID == contactID
            || state.systemSessionMatchesContact
            || state.localJoinFailure?.contactID == contactID
            || state.pendingAction.isLeaveInFlight(for: contactID) {
            state.localRestoreDispatchInFlightContactID = nil
            return
        }

        guard case .restoreLocalSession(let actionContactID) = state.reconciliationAction,
              actionContactID == contactID else {
            state.localRestoreDispatchInFlightContactID = nil
            return
        }
    }

    private static func clearCompletedInterruptedConnectionAttemptIfNeeded(
        _ state: inout SelectedPeerSessionState
    ) {
        guard let contactID = state.interruptedConnectionAttemptContactID else { return }
        guard state.selection?.contactID == contactID else {
            state.interruptedConnectionAttemptContactID = nil
            return
        }

        if state.isJoined
            || state.activeChannelID == contactID
            || state.systemSessionMatchesContact
            || state.durableSessionProjection == .connected {
            state.interruptedConnectionAttemptContactID = nil
            return
        }

        switch state.selectedPeerState.phase {
        case .idle, .requested, .incomingRequest, .peerReady, .wakeReady, .ready,
             .startingTransmit, .transmitting, .receiving, .blockedByOtherSession,
             .systemMismatch:
            state.interruptedConnectionAttemptContactID = nil
        case .waitingForPeer, .localJoinFailed:
            break
        }
    }

    private static func applyShortcutPolicyUpdate(
        to state: inout SelectedPeerSessionState,
        requesterAutoJoinOnPeerAcceptanceEnabled: Bool
    ) {
        state.requesterAutoJoinOnPeerAcceptanceEnabled = requesterAutoJoinOnPeerAcceptanceEnabled
        if !requesterAutoJoinOnPeerAcceptanceEnabled {
            state.requesterAutoJoinOnPeerAcceptanceArmed = false
            state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight = false
            state.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest = false
        }
    }

    private static func updatedConnectedSessionContinuity(
        previous: Bool,
        projection: SelectedPeerProjection,
        channel: ChannelReadinessSnapshot?
    ) -> Bool {
        if projection.durableSession == .inactive,
           channel?.membership.hasLocalMembership != true {
            switch projection.selectedPeerState.phase {
            case .idle, .requested, .incomingRequest, .peerReady:
                return false
            case .waitingForPeer, .wakeReady, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
                break
            }
        }

        if projection.durableSession == .connected {
            switch projection.selectedPeerState.phase {
            case .wakeReady, .ready, .startingTransmit, .transmitting, .receiving:
                return true
            case .idle, .requested, .incomingRequest, .peerReady, .waitingForPeer, .localJoinFailed, .blockedByOtherSession, .systemMismatch:
                break
            }
        }

        return previous
    }

    private static func shouldClearRequesterAutoJoinShortcut(
        state: SelectedPeerSessionState
    ) -> Bool {
        guard state.requesterAutoJoinOnPeerAcceptanceArmed
                || state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight else { return false }
        guard state.pendingAction.pendingConnectContactID == nil else { return false }
        guard state.pendingAction.pendingJoinContactID == nil else { return false }
        guard !state.pendingConnectAcceptedIncomingRequest else { return false }
        guard state.durableSessionProjection == .inactive else { return false }
        guard state.relationship == .none else { return false }
        if let channel = state.channel {
            guard !channelStillShowsOutstandingRequest(channel) else { return false }
            guard channel.membership == .absent else { return false }
            if state.requesterAutoJoinOnPeerAcceptanceArmed,
               !state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight {
                // Acceptance can briefly project as relationship=none with idle channel
                // before peer readiness appears; keep the requester latch through that gap.
                return false
            }
        } else if state.requesterAutoJoinOnPeerAcceptanceArmed,
                  !state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight,
                  !state.requesterAutoJoinOnPeerAcceptanceObservedOutgoingRequest {
            return false
        }
        return true
    }

    private static func channelStillShowsOutstandingRequest(
        _ channel: ChannelReadinessSnapshot
    ) -> Bool {
        if channel.requestRelationship != .none {
            return true
        }
        switch channel.status {
        case .requested, .incomingRequest:
            return true
        case .idle, .waitingForPeer, .ready, .transmitting, .receiving, .none:
            return false
        }
    }

    private static func shouldProjectWakeReadyForConnectedDegradation(
        state: SelectedPeerSessionState,
        projection: SelectedPeerProjection
    ) -> Bool {
        guard state.hadConnectedSessionContinuity,
              projection.durableSession == .connected,
              projection.connectedExecution == nil,
              (state.directMediaPathActive || state.localRelayTransportReady),
              state.channel?.membership == .selfOnly,
              case .wakeCapable = state.channel?.remoteWakeCapability,
              case .waitingForPeer(reason: .backendSessionTransition) = projection.selectedPeerState.detail else {
            return false
        }

        return true
    }

    private static func joinEffect(for state: SelectedPeerSessionState) -> SelectedPeerEffect? {
        guard let contactID = state.selection?.contactID else { return nil }

        if state.interruptedConnectionAttemptContactID == contactID {
            if state.channel?.membership.hasPeerMembership == true {
                return .joinReadyPeer(contactID: contactID)
            }
            return .requestConnection(contactID: contactID)
        }

        switch (state.durableSessionProjection, state.selectedPeerState.phase) {
        case (.inactive, .idle), (.inactive, .requested), (.inactive, .incomingRequest):
            return .requestConnection(contactID: contactID)
        case (.inactive, .peerReady):
            return .joinReadyPeer(contactID: contactID)
        case (.transitioning, _), (.connected, _), (.blockedByOtherSession, _), (.systemMismatch, _), (.localJoinFailed, _), (.pendingJoin, _), (.disconnecting, _), (.inactive, _):
            return nil
        }
    }

    private static func isInterruptibleConnectionAttempt(
        _ selectedPeerState: SelectedPeerState
    ) -> Bool {
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

    private static func shouldProjectInterruptedConnectionAttempt(
        _ state: SelectedPeerSessionState
    ) -> Bool {
        guard let contactID = state.selection?.contactID else { return false }
        guard state.interruptedConnectionAttemptContactID == contactID else { return false }
        guard !state.isJoined, state.activeChannelID == nil else { return false }
        guard state.systemSessionState == .none else { return false }
        switch state.selectedPeerState.detail {
        case .waitingForPeer(reason: .pendingJoin),
             .waitingForPeer(reason: .backendSessionTransition),
             .waitingForPeer(reason: .localSessionTransition),
             .waitingForPeer(reason: .peerReadyToConnect):
            return true
        case .localJoinFailed:
            return true
        case .idle, .requested, .incomingRequest, .peerReady, .wakeReady,
             .waitingForPeer, .ready, .startingTransmit, .transmitting,
             .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }

    private static func shouldArmRequesterAutoJoinShortcut(
        state: SelectedPeerSessionState,
        effect: SelectedPeerEffect
    ) -> Bool {
        guard state.requesterAutoJoinOnPeerAcceptanceEnabled else { return false }
        guard case .requestConnection = effect else { return false }
        switch state.selectedPeerState.phase {
        case .idle, .requested:
            return true
        case .incomingRequest, .peerReady, .waitingForPeer, .wakeReady, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }

    private static func shouldArmRequesterAutoJoinForOutstandingOutgoingRequest(
        state: SelectedPeerSessionState
    ) -> Bool {
        guard state.requesterAutoJoinOnPeerAcceptanceEnabled else { return false }
        guard !state.requesterAutoJoinOnPeerAcceptanceArmed else { return false }
        guard !state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight else { return false }
        guard state.relationship.isOutgoingRequest else { return false }
        guard state.selection != nil else { return false }
        guard state.pendingAction.pendingConnectContactID == nil else { return false }
        guard state.pendingAction.pendingJoinContactID == nil else { return false }
        guard !state.pendingConnectAcceptedIncomingRequest else { return false }
        guard state.durableSessionProjection == .inactive else { return false }
        guard !state.isJoined, state.activeChannelID == nil else { return false }

        switch state.selectedPeerState.phase {
        case .idle, .requested, .peerReady:
            return true
        case .incomingRequest, .waitingForPeer, .wakeReady, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }

    private static func autoJoinReadyPeerEffect(for state: SelectedPeerSessionState) -> SelectedPeerEffect? {
        guard state.requesterAutoJoinOnPeerAcceptanceEnabled else { return nil }
        guard state.requesterAutoJoinOnPeerAcceptanceArmed else { return nil }
        guard state.pendingAction.pendingConnectContactID == nil else { return nil }
        guard state.pendingAction.pendingJoinContactID == nil else { return nil }
        guard state.durableSessionProjection == .inactive else { return nil }
        guard state.selection?.contactID == state.selectedPeerState.contactID else { return nil }
        guard state.selectedPeerState.phase == .peerReady else { return nil }
        guard let contactID = state.selection?.contactID else { return nil }
        return .joinReadyPeer(contactID: contactID)
    }

    private static func shouldProjectRequesterAutoJoinConnecting(
        state: SelectedPeerSessionState
    ) -> Bool {
        guard state.requesterAutoJoinOnPeerAcceptanceEnabled else { return false }
        guard state.requesterAutoJoinOnPeerAcceptanceArmed
                || state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight else { return false }
        if state.requesterAutoJoinOnPeerAcceptanceArmed {
            guard state.pendingAction.pendingConnectContactID == nil else { return false }
            guard state.pendingAction.pendingJoinContactID == nil else { return false }
        }
        guard state.durableSessionProjection == .inactive else { return false }

        switch state.selectedPeerState.detail {
        case .peerReady, .waitingForPeer(reason: .peerReadyToConnect):
            return true
        case .idle:
            return !state.relationship.isOutgoingRequest
        case .requested, .incomingRequest, .waitingForPeer, .wakeReady, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }

    private static func disconnectEffect(for state: SelectedPeerSessionState) -> SelectedPeerEffect? {
        guard let contactID = state.selection?.contactID else { return nil }

        if state.pendingAction.isLeaveInFlight(for: contactID) {
            return nil
        }

        let hasLocalOrSystemSession =
            state.isJoined
            || state.activeChannelID == contactID
            || state.systemSessionState != .none
            || state.pendingAction.pendingJoinContactID == contactID

        guard hasLocalOrSystemSession else { return nil }
        return .disconnect(contactID: contactID)
    }

    private static func reconciliationEffect(for state: SelectedPeerSessionState) -> SelectedPeerEffect? {
        switch (state.durableSessionProjection, state.reconciliationAction) {
        case (_, .none):
            return nil
        case (.connected, .restoreLocalSession), (.disconnecting, .restoreLocalSession):
            return nil
        case (_, .restoreLocalSession(let contactID)):
            if state.localRestoreDispatchInFlightContactID == contactID {
                return nil
            }
            return .restoreLocalSession(contactID: contactID)
        case (_, .teardownSelectedSession(let contactID)):
            if state.pendingAction.isLeaveInFlight(for: contactID) {
                return nil
            }
            return .teardownLocalSession(contactID: contactID)
        case (_, .clearStaleBackendMembership(let contactID)):
            if state.pendingAction.isLeaveInFlight(for: contactID) {
                return nil
            }
            return .clearStaleBackendMembership(contactID: contactID)
        }
    }
}

@MainActor
final class SelectedPeerCoordinator {
    private(set) var state: SelectedPeerSessionState = .initial
    var effectHandler: (@MainActor (SelectedPeerEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?
    private var queuedEffectTask: Task<Void, Never>?

    func reset() {
        queuedEffectTask?.cancel()
        queuedEffectTask = nil
        state = .initial
    }

    func send(_ event: SelectedPeerEvent) {
        let previousState = state
        let transition = SelectedPeerReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        enqueueEffects(transition.effects)
    }

    func handle(_ event: SelectedPeerEvent) async {
        let previousState = state
        let transition = SelectedPeerReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        await runEffects(transition.effects)
    }

    private func reportTransition(
        previousState: SelectedPeerSessionState,
        event: SelectedPeerEvent,
        transition: SelectedPeerTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "selected-peer-session",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }

    private func enqueueEffects(_ effects: [SelectedPeerEffect]) {
        guard !effects.isEmpty else { return }
        let previousTask = queuedEffectTask
        queuedEffectTask = Task { @MainActor [effects] in
            _ = await previousTask?.value
            await self.runEffects(effects)
        }
    }

    private func runEffects(_ effects: [SelectedPeerEffect]) async {
        guard !effects.isEmpty else { return }
        for effect in effects {
            await effectHandler?(effect)
        }
    }
}

private extension SelectedPeerState {
    static let initial = SelectedPeerState(
        relationship: .none,
        phase: .idle,
        statusMessage: "Ready to connect",
        canTransmitNow: false
    )
}
