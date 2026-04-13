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
    var activeChannelID: UUID?
    var systemSessionMatchesContact: Bool = false
    var systemSessionState: SystemPTTSessionState = .none
    var pendingAction: PendingSessionAction = .none
    var localJoinFailure: PTTJoinFailure?
    var channel: ChannelReadinessSnapshot?
    var mediaState: MediaConnectionState = .idle
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
    case systemSessionUpdated(SystemPTTSessionState, matchesSelectedContact: Bool)
    case mediaStateUpdated(MediaConnectionState)
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
            nextState = selection.map { selection in
                var resetState = SelectedPeerSessionState.initial
                resetState.selection = selection
                return resetState
            } ?? .initial
        case .relationshipUpdated(let relationship):
            nextState.relationship = relationship
        case .baseStateUpdated(let baseState):
            nextState.baseState = baseState
        case .channelUpdated(let channel):
            nextState.channel = channel
        case .localSessionUpdated(let isJoined, let activeChannelID, let pendingAction, let localJoinFailure):
            nextState.isJoined = isJoined
            nextState.activeChannelID = activeChannelID
            nextState.pendingAction = pendingAction
            nextState.localJoinFailure = localJoinFailure
        case .systemSessionUpdated(let systemSessionState, let matchesSelectedContact):
            nextState.systemSessionState = systemSessionState
            nextState.systemSessionMatchesContact = matchesSelectedContact
        case .mediaStateUpdated(let mediaState):
            nextState.mediaState = mediaState
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
            state.selectedPeerState = .initial
            state.reconciliationAction = .none
            return
        }

        let context = ConversationDerivationContext(
            contactID: selection.contactID,
            selectedContactID: selection.contactID,
            baseState: state.baseState,
            contactName: selection.contactName,
            contactIsOnline: selection.contactIsOnline,
            isJoined: state.isJoined,
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
            channel: state.channel
        )

        state.selectedPeerState = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: state.relationship
        )
        state.reconciliationAction = ConversationStateMachine.reconciliationAction(for: context)
    }

    private static func joinEffect(for state: SelectedPeerSessionState) -> SelectedPeerEffect? {
        guard let contactID = state.selection?.contactID else { return nil }

        switch state.selectedPeerState.phase {
        case .idle, .requested, .incomingRequest:
            return .requestConnection(contactID: contactID)
        case .peerReady:
            return .joinReadyPeer(contactID: contactID)
        case .wakeReady, .waitingForPeer, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving, .blockedByOtherSession, .systemMismatch:
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
        switch state.reconciliationAction {
        case .none:
            return nil
        case .restoreLocalSession(let contactID):
            return .restoreLocalSession(contactID: contactID)
        case .teardownSelectedSession(let contactID):
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
