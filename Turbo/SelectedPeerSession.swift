import Foundation

struct SelectedPeerSelection: Equatable {
    let contactID: UUID
    let contactName: String
    let contactIsOnline: Bool
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
    var localJoinFailure: PTTJoinFailure?
    var channel: ChannelReadinessSnapshot?
    var mediaState: MediaConnectionState = .idle
    var incomingWakeActivationState: IncomingWakeActivationState?
    var hadConnectedSessionContinuity = false
    var durableSessionProjection: DurableSessionProjection = .inactive
    var connectedExecutionProjection: ConnectedExecutionProjection?
    var connectedControlPlaneProjection: ConnectedControlPlaneProjection = .unavailable
    var selectedPeerState: SelectedPeerState = .initial
    var reconciliationAction: SessionReconciliationAction = .none

    static let initial = SelectedPeerSessionState()
}

enum SelectedPeerEvent: Equatable {
    case selectedContactChanged(SelectedPeerSelection?)
    case relationshipUpdated(PairRelationshipState)
    case baseStateUpdated(ConversationState)
    case channelUpdated(ChannelReadinessSnapshot?)
    case localSessionUpdated(
        isJoined: Bool,
        activeChannelID: UUID?,
        pendingAction: PendingSessionAction,
        localJoinFailure: PTTJoinFailure?
    )
    case localTransmitUpdated(LocalTransmitProjection)
    case peerSignalTransmittingUpdated(Bool)
    case systemSessionUpdated(SystemPTTSessionState, matchesSelectedContact: Bool)
    case mediaStateUpdated(MediaConnectionState)
    case incomingWakeActivationStateUpdated(IncomingWakeActivationState?)
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
            let localJoinFailure
        ):
            nextState.isJoined = isJoined
            nextState.activeChannelID = activeChannelID
            nextState.pendingAction = pendingAction
            nextState.localJoinFailure = localJoinFailure
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
        case .joinRequested:
            recomputeDerivedState(&nextState)
            if let effect = joinEffect(for: nextState) {
                effects.append(effect)
            }
            return SelectedPeerTransition(state: nextState, effects: effects)
        case .disconnectRequested:
            recomputeDerivedState(&nextState)
            if let effect = disconnectEffect(for: nextState) {
                effects.append(effect)
            }
            return SelectedPeerTransition(state: nextState, effects: effects)
        case .reconcileRequested:
            recomputeDerivedState(&nextState)
            if let effect = reconciliationEffect(for: nextState) {
                effects.append(effect)
            }
            return SelectedPeerTransition(state: nextState, effects: effects)
        }

        recomputeDerivedState(&nextState)
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
            isJoined: state.isJoined,
            localTransmit: state.localTransmit,
            peerSignalIsTransmitting: state.peerSignalIsTransmitting,
            activeChannelID: state.activeChannelID,
            systemSessionMatchesContact: state.systemSessionMatchesContact,
            systemSessionState: state.systemSessionState,
            pendingAction: state.pendingAction,
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
            incomingWakeActivationState: state.incomingWakeActivationState,
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

    private static func shouldProjectWakeReadyForConnectedDegradation(
        state: SelectedPeerSessionState,
        projection: SelectedPeerProjection
    ) -> Bool {
        guard state.hadConnectedSessionContinuity,
              projection.durableSession == .connected,
              projection.connectedExecution == nil,
              state.channel?.membership == .selfOnly,
              case .wakeCapable = state.channel?.remoteWakeCapability,
              case .waitingForPeer(reason: .backendSessionTransition) = projection.selectedPeerState.detail else {
            return false
        }

        return true
    }

    private static func joinEffect(for state: SelectedPeerSessionState) -> SelectedPeerEffect? {
        guard let contactID = state.selection?.contactID else { return nil }

        switch (state.durableSessionProjection, state.selectedPeerState.phase) {
        case (.inactive, .idle), (.inactive, .requested), (.inactive, .incomingRequest):
            return .requestConnection(contactID: contactID)
        case (.inactive, .peerReady):
            return .joinReadyPeer(contactID: contactID)
        case (.transitioning, _), (.connected, _), (.blockedByOtherSession, _), (.systemMismatch, _), (.localJoinFailed, _), (.pendingJoin, _), (.disconnecting, _), (.inactive, _):
            return nil
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
            return .restoreLocalSession(contactID: contactID)
        case (_, .teardownSelectedSession(let contactID)):
            if state.pendingAction.isLeaveInFlight(for: contactID) {
                return nil
            }
            return .teardownLocalSession(contactID: contactID)
        }
    }
}

@MainActor
final class SelectedPeerCoordinator {
    private(set) var state: SelectedPeerSessionState = .initial
    var effectHandler: (@MainActor (SelectedPeerEffect) async -> Void)?

    func send(_ event: SelectedPeerEvent) {
        state = SelectedPeerReducer.reduce(state: state, event: event).state
    }

    func handle(_ event: SelectedPeerEvent) async {
        let transition = SelectedPeerReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
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
