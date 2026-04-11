import Foundation

enum BackendCommandOperation: Equatable {
    case openPeer(handle: String)
    case join(request: BackendJoinRequest)
    case leave(contactID: UUID)
}

struct BackendJoinRequest: Equatable {
    let contactID: UUID
    let handle: String
    let relationship: PairRelationshipState
    let existingRemoteUserID: String?
    let existingBackendChannelID: String?
    let incomingInvite: TurboInviteResponse?
    let outgoingInvite: TurboInviteResponse?
    let requestCooldownRemaining: Int?
    let usesLocalHTTPBackend: Bool
}

struct BackendLeaveRequest: Equatable {
    let contactID: UUID
    let backendChannelID: String
}

struct BackendCommandState: Equatable {
    var activeOperation: BackendCommandOperation?
    var queuedJoinRequest: BackendJoinRequest?
    var lastError: String?

    static let initial = BackendCommandState()
}

enum BackendCommandEvent: Equatable {
    case openPeerRequested(handle: String)
    case joinRequested(BackendJoinRequest)
    case leaveRequested(BackendLeaveRequest)
    case operationFinished
    case operationFailed(String)
    case reset
}

enum BackendCommandEffect: Equatable {
    case openPeer(handle: String)
    case join(BackendJoinRequest)
    case leave(BackendLeaveRequest)
}

struct BackendCommandTransition: Equatable {
    var state: BackendCommandState
    var effects: [BackendCommandEffect] = []
}

enum BackendCommandReducer {
    static func reduce(
        state: BackendCommandState,
        event: BackendCommandEvent
    ) -> BackendCommandTransition {
        var nextState = state
        var effects: [BackendCommandEffect] = []

        switch event {
        case .openPeerRequested(let handle):
            let operation = BackendCommandOperation.openPeer(handle: handle)
            guard nextState.activeOperation != operation else {
                return BackendCommandTransition(state: nextState)
            }
            nextState.activeOperation = operation
            nextState.lastError = nil
            effects.append(.openPeer(handle: handle))

        case .joinRequested(let request):
            let operation = BackendCommandOperation.join(request: request)
            if case .join(let activeRequest) = nextState.activeOperation,
               activeRequest.contactID == request.contactID {
                if activeRequest == request || nextState.queuedJoinRequest == request {
                    return BackendCommandTransition(state: nextState)
                }
                nextState.queuedJoinRequest = request
                return BackendCommandTransition(state: nextState)
            }
            nextState.activeOperation = operation
            nextState.queuedJoinRequest = nil
            nextState.lastError = nil
            effects.append(.join(request))

        case .leaveRequested(let request):
            let operation = BackendCommandOperation.leave(contactID: request.contactID)
            guard nextState.activeOperation != operation else {
                return BackendCommandTransition(state: nextState)
            }
            nextState.activeOperation = operation
            nextState.lastError = nil
            effects.append(.leave(request))

        case .operationFinished:
            if let queuedJoinRequest = nextState.queuedJoinRequest {
                nextState.activeOperation = .join(request: queuedJoinRequest)
                nextState.queuedJoinRequest = nil
                nextState.lastError = nil
                effects.append(.join(queuedJoinRequest))
            } else {
                nextState.activeOperation = nil
                nextState.lastError = nil
            }

        case .operationFailed(let message):
            if let queuedJoinRequest = nextState.queuedJoinRequest {
                nextState.activeOperation = .join(request: queuedJoinRequest)
                nextState.queuedJoinRequest = nil
                nextState.lastError = nil
                effects.append(.join(queuedJoinRequest))
            } else {
                nextState.activeOperation = nil
                nextState.lastError = message
            }

        case .reset:
            nextState = .initial
        }

        return BackendCommandTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class BackendCommandCoordinator {
    private(set) var state = BackendCommandState.initial
    var effectHandler: (@MainActor (BackendCommandEffect) async -> Void)?

    func send(_ event: BackendCommandEvent) {
        state = BackendCommandReducer.reduce(state: state, event: event).state
    }

    func handle(_ event: BackendCommandEvent) async {
        let transition = BackendCommandReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }
}
