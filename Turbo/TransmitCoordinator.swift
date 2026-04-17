import Foundation

struct TransmitRequestContext: Equatable, Sendable {
    let contactID: UUID
    let contactHandle: String
    let backendChannelID: String
    let remoteUserID: String
    let channelUUID: UUID?
    let usesLocalHTTPBackend: Bool
    let backendSupportsWebSocket: Bool
}

struct TransmitTarget: Equatable, Sendable {
    let contactID: UUID
    let userID: String
    let deviceID: String
    let channelID: String
}

enum TransmitPhase: Equatable {
    case idle
    case requesting(contactID: UUID)
    case active(contactID: UUID)
    case stopping(contactID: UUID)
}

struct TransmitSessionState: Equatable {
    var phase: TransmitPhase = .idle
    var isPressingTalk: Bool = false
    var pendingRequest: TransmitRequestContext?
    var activeTarget: TransmitTarget?
    var lastError: String?

    static let initial = TransmitSessionState()
}

enum TransmitEvent: Equatable {
    case pressRequested(TransmitRequestContext)
    case systemPressRequested(TransmitRequestContext)
    case beginSucceeded(TransmitTarget, TransmitRequestContext)
    case beginFailed(String)
    case releaseRequested
    case systemEnded
    case stopCompleted
    case stopFailed(String)
    case renewalFailed(String)
    case websocketDisconnected
    case systemBeginFailed(String)
}

enum TransmitEffect: Equatable {
    case beginTransmit(TransmitRequestContext)
    case activateTransmit(TransmitRequestContext, TransmitTarget)
    case stopTransmit(TransmitTarget)
    case abortTransmit(TransmitTarget)
}

struct TransmitTransition: Equatable {
    var state: TransmitSessionState
    var effects: [TransmitEffect] = []
}

enum TransmitReducer {
    static func reduce(
        state: TransmitSessionState,
        event: TransmitEvent
    ) -> TransmitTransition {
        var nextState = state
        var effects: [TransmitEffect] = []

        switch event {
        case .pressRequested(let request):
            guard canBegin(from: nextState, request: request) else {
                return TransmitTransition(state: nextState)
            }
            nextState.phase = .requesting(contactID: request.contactID)
            nextState.isPressingTalk = true
            nextState.pendingRequest = request
            nextState.lastError = nil
            effects.append(.beginTransmit(request))

        case .systemPressRequested(let request):
            guard canBegin(from: nextState, request: request) else {
                return TransmitTransition(state: nextState)
            }
            nextState.phase = .requesting(contactID: request.contactID)
            nextState.isPressingTalk = true
            nextState.pendingRequest = request
            nextState.lastError = nil
            effects.append(.beginTransmit(request))

        case .beginSucceeded(let target, let request):
            nextState.pendingRequest = nil
            nextState.activeTarget = target
            if nextState.isPressingTalk {
                nextState.phase = .active(contactID: request.contactID)
                effects.append(.activateTransmit(request, target))
            } else {
                nextState.phase = .stopping(contactID: request.contactID)
                effects.append(.stopTransmit(target))
            }

        case .beginFailed(let message):
            nextState.phase = .idle
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            nextState.activeTarget = nil
            nextState.lastError = message

        case .releaseRequested:
            nextState.isPressingTalk = false
            if let activeTarget = nextState.activeTarget {
                nextState.phase = .stopping(contactID: activeTarget.contactID)
                effects.append(.stopTransmit(activeTarget))
            }

        case .systemEnded:
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            switch nextState.phase {
            case .active:
                if let activeTarget = nextState.activeTarget {
                    nextState.phase = .stopping(contactID: activeTarget.contactID)
                    effects.append(.stopTransmit(activeTarget))
                } else {
                    nextState.phase = .idle
                }
            case .requesting:
                nextState.phase = .idle
                nextState.activeTarget = nil
            case .stopping, .idle:
                break
            }

        case .renewalFailed(let message):
            nextState.lastError = message
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            if let activeTarget = nextState.activeTarget {
                nextState.phase = .stopping(contactID: activeTarget.contactID)
                effects.append(.stopTransmit(activeTarget))
            } else {
                nextState.phase = .idle
                nextState.activeTarget = nil
            }

        case .systemBeginFailed(let message):
            nextState.lastError = message
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            if let activeTarget = nextState.activeTarget {
                nextState.phase = .idle
                nextState.activeTarget = nil
                effects.append(.abortTransmit(activeTarget))
            } else {
                nextState.phase = .idle
                nextState.activeTarget = nil
            }

        case .websocketDisconnected:
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            if let activeTarget = nextState.activeTarget {
                nextState.phase = .stopping(contactID: activeTarget.contactID)
                effects.append(.stopTransmit(activeTarget))
            } else {
                nextState.phase = .idle
                nextState.activeTarget = nil
            }

        case .stopCompleted:
            nextState.phase = .idle
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            nextState.activeTarget = nil

        case .stopFailed(let message):
            nextState.phase = .idle
            nextState.isPressingTalk = false
            nextState.pendingRequest = nil
            nextState.activeTarget = nil
            nextState.lastError = message
        }

        return TransmitTransition(state: nextState, effects: effects)
    }

    private static func canBegin(from state: TransmitSessionState, request: TransmitRequestContext) -> Bool {
        switch state.phase {
        case .idle:
            return true
        case .requesting(let contactID), .active(let contactID), .stopping(let contactID):
            return contactID == request.contactID ? false : false
        }
    }
}

@MainActor
final class TransmitCoordinator {
    private(set) var state: TransmitSessionState = .initial
    var effectHandler: (@MainActor (TransmitEffect) async -> Void)?

    func handle(_ event: TransmitEvent) async {
        let transition = TransmitReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    func reset() {
        state = .initial
    }
}
