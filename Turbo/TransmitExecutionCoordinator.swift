import Foundation

enum TransmitPressState: Equatable {
    case idle
    case pressing
    case releaseRequired(interruptedContactID: UUID?)

    var isPressingTalk: Bool {
        guard case .pressing = self else { return false }
        return true
    }

    var requiresReleaseBeforeNextPress: Bool {
        guard case .releaseRequired = self else { return false }
        return true
    }

    var interruptedContactID: UUID? {
        guard case .releaseRequired(let interruptedContactID) = self else { return nil }
        return interruptedContactID
    }
}

enum TransmitStopIntentState: Equatable {
    case none
    case explicitStopRequested

    var explicitStopRequested: Bool {
        self == .explicitStopRequested
    }
}

enum SystemTransmitExecutionState: Equatable {
    case idle
    case beginPending(channelUUID: UUID)
    case transmitting(startedAt: Date)

    var pendingSystemBeginChannelUUID: UUID? {
        guard case .beginPending(let channelUUID) = self else { return nil }
        return channelUUID
    }

    var lastSystemTransmitBeganAt: Date? {
        guard case .transmitting(let startedAt) = self else { return nil }
        return startedAt
    }
}

enum SystemTransmitEndDisposition: Equatable {
    case none
    case implicitRelease
    case requireFreshPress(contactID: UUID?)
}

struct TransmitExecutionSessionState: Equatable {
    var latchedTarget: TransmitTarget?
    var pressState: TransmitPressState = .idle
    var stopIntent: TransmitStopIntentState = .none
    var systemTransmitState: SystemTransmitExecutionState = .idle

    static let initial = TransmitExecutionSessionState()

    var activeTarget: TransmitTarget? { latchedTarget }
    var isPressingTalk: Bool { pressState.isPressingTalk }
    var explicitStopRequested: Bool { stopIntent.explicitStopRequested }
    var requiresReleaseBeforeNextPress: Bool { pressState.requiresReleaseBeforeNextPress }
    var interruptedContactID: UUID? { pressState.interruptedContactID }
    var pendingSystemBeginChannelUUID: UUID? { systemTransmitState.pendingSystemBeginChannelUUID }
    var lastSystemTransmitBeganAt: Date? { systemTransmitState.lastSystemTransmitBeganAt }
}

enum TransmitExecutionEvent: Equatable {
    case syncActiveTarget(TransmitTarget?)
    case markPressBegan
    case markPressEnded
    case markExplicitStopRequested
    case markUnexpectedSystemEndRequiresRelease(contactID: UUID?)
    case noteSystemTransmitBegan(Date)
    case noteSystemTransmitEnded
    case noteSystemTransmitBeginRequested(channelUUID: UUID)
    case clearPendingSystemTransmitBegin(channelUUID: UUID?)
    case noteTouchReleased
    case reconcileIdleState
    case reset
    case handleSystemTransmitEnded(applicationStateIsActive: Bool, matchingActiveTarget: TransmitTarget?)
}

enum TransmitExecutionEffect: Equatable {
    case handledSystemTransmitEnded(SystemTransmitEndDisposition)
}

struct TransmitExecutionTransition: Equatable {
    var state: TransmitExecutionSessionState
    var effects: [TransmitExecutionEffect] = []
}

enum TransmitExecutionReducer {
    static func reduce(
        state: TransmitExecutionSessionState,
        event: TransmitExecutionEvent
    ) -> TransmitExecutionTransition {
        var nextState = state
        var effects: [TransmitExecutionEffect] = []

        switch event {
        case .syncActiveTarget(let activeTarget):
            syncLatchedTarget(&nextState, activeTarget)

        case .markPressBegan:
            guard !nextState.requiresReleaseBeforeNextPress else { break }
            nextState.pressState = .pressing
            nextState.stopIntent = .none

        case .markPressEnded:
            guard case .pressing = nextState.pressState else { break }
            nextState.pressState = .idle

        case .markExplicitStopRequested:
            nextState.stopIntent = .explicitStopRequested

        case .markUnexpectedSystemEndRequiresRelease(let contactID):
            nextState.pressState = .releaseRequired(interruptedContactID: contactID)

        case .noteSystemTransmitBegan(let beganAt):
            nextState.systemTransmitState = .transmitting(startedAt: beganAt)

        case .noteSystemTransmitEnded:
            nextState.systemTransmitState = .idle

        case .noteSystemTransmitBeginRequested(let channelUUID):
            nextState.systemTransmitState = .beginPending(channelUUID: channelUUID)

        case .clearPendingSystemTransmitBegin(let channelUUID):
            guard case .beginPending(let pendingChannelUUID) = nextState.systemTransmitState else { break }
            guard channelUUID == nil || pendingChannelUUID == channelUUID else { break }
            nextState.systemTransmitState = .idle

        case .noteTouchReleased:
            guard nextState.requiresReleaseBeforeNextPress else { break }
            nextState.pressState = .idle

        case .reconcileIdleState:
            nextState.stopIntent = .none
            nextState.systemTransmitState = .idle
            if case .pressing = nextState.pressState {
                nextState.pressState = .idle
            }
            nextState.latchedTarget = nil

        case .reset:
            nextState = .initial

        case .handleSystemTransmitEnded(let applicationStateIsActive, let matchingActiveTarget):
            let disposition: SystemTransmitEndDisposition
            if !applicationStateIsActive,
               !nextState.explicitStopRequested,
               matchingActiveTarget != nil,
               nextState.isPressingTalk {
                nextState.pressState = .idle
                syncLatchedTarget(&nextState, matchingActiveTarget)
                disposition = .implicitRelease
            } else if !nextState.explicitStopRequested,
                      matchingActiveTarget != nil,
                      nextState.isPressingTalk {
                nextState.pressState = .releaseRequired(
                    interruptedContactID: matchingActiveTarget?.contactID
                )
                syncLatchedTarget(&nextState, matchingActiveTarget)
                disposition = .requireFreshPress(contactID: matchingActiveTarget?.contactID)
            } else {
                disposition = .none
            }
            nextState.systemTransmitState = .idle
            effects.append(.handledSystemTransmitEnded(disposition))
        }

        return TransmitExecutionTransition(state: nextState, effects: effects)
    }

    private static func syncLatchedTarget(
        _ state: inout TransmitExecutionSessionState,
        _ activeTarget: TransmitTarget?
    ) {
        if let activeTarget {
            state.latchedTarget = activeTarget
        } else if !state.isPressingTalk {
            state.latchedTarget = nil
        }
    }
}
