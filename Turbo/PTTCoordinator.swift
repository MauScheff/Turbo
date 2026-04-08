import Foundation

struct PTTSessionState: Equatable {
    var systemChannelUUID: UUID?
    var activeContactID: UUID?
    var isJoined: Bool = false
    var isTransmitting: Bool = false
    var lastError: String?

    static let initial = PTTSessionState()

    var systemSessionState: SystemPTTSessionState {
        guard let systemChannelUUID else { return .none }
        guard let activeContactID else {
            return .mismatched(channelUUID: systemChannelUUID)
        }
        return .active(contactID: activeContactID, channelUUID: systemChannelUUID)
    }
}

enum PTTEvent: Equatable {
    case restoredChannel(channelUUID: UUID, contactID: UUID?)
    case didJoinChannel(channelUUID: UUID, contactID: UUID?, reason: String)
    case didLeaveChannel(channelUUID: UUID, contactID: UUID?, reason: String, autoRejoinContactID: UUID?)
    case failedToJoinChannel(channelUUID: UUID, message: String)
    case failedToLeaveChannel(channelUUID: UUID, message: String)
    case didBeginTransmitting(channelUUID: UUID, source: String)
    case didEndTransmitting(channelUUID: UUID, source: String)
    case failedToBeginTransmitting(channelUUID: UUID, message: String)
    case failedToStopTransmitting(channelUUID: UUID, message: String)
    case reset
}

enum PTTEffect: Equatable {
    case syncJoinedChannel(contactID: UUID?)
    case syncLeftChannel(contactID: UUID?, autoRejoinContactID: UUID?)
    case closeMediaSession
    case handleSystemTransmitFailure(String)
}

struct PTTTransition: Equatable {
    var state: PTTSessionState
    var effects: [PTTEffect] = []
}

enum PTTReducer {
    static func reduce(
        state: PTTSessionState,
        event: PTTEvent
    ) -> PTTTransition {
        var nextState = state
        var effects: [PTTEffect] = []

        switch event {
        case .restoredChannel(let channelUUID, let contactID):
            nextState.systemChannelUUID = channelUUID
            nextState.activeContactID = contactID
            nextState.lastError = nil

        case .didJoinChannel(let channelUUID, let contactID, _):
            nextState.systemChannelUUID = channelUUID
            nextState.activeContactID = contactID
            nextState.isJoined = true
            nextState.lastError = nil
            effects.append(.syncJoinedChannel(contactID: contactID))

        case .didLeaveChannel(let channelUUID, let contactID, _, let autoRejoinContactID):
            if nextState.systemChannelUUID == channelUUID {
                nextState.systemChannelUUID = nil
            }
            nextState.activeContactID = nil
            nextState.isJoined = false
            nextState.isTransmitting = false
            nextState.lastError = nil
            effects.append(.syncLeftChannel(contactID: contactID, autoRejoinContactID: autoRejoinContactID))

        case .failedToJoinChannel(_, let message):
            nextState.isJoined = false
            nextState.isTransmitting = false
            nextState.lastError = message
            effects.append(.closeMediaSession)

        case .failedToLeaveChannel(_, let message):
            nextState.lastError = message

        case .didBeginTransmitting:
            nextState.isTransmitting = true
            nextState.lastError = nil

        case .didEndTransmitting:
            nextState.isTransmitting = false

        case .failedToBeginTransmitting(_, let message):
            nextState.isTransmitting = false
            nextState.lastError = message
            effects.append(.handleSystemTransmitFailure(message))

        case .failedToStopTransmitting(_, let message):
            nextState.lastError = message

        case .reset:
            nextState = .initial
        }

        return PTTTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class PTTCoordinator {
    private(set) var state: PTTSessionState = .initial
    var effectHandler: (@MainActor (PTTEffect) async -> Void)?

    func send(_ event: PTTEvent) {
        state = PTTReducer.reduce(state: state, event: event).state
    }

    func handle(_ event: PTTEvent) async {
        let transition = PTTReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    func reset() {
        state = .initial
    }
}
