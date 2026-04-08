import Foundation

struct PTTTokenUploadRequest: Equatable {
    let backendChannelID: String
    let tokenHex: String
}

struct PTTSystemPolicyState: Equatable {
    var latestTokenHex: String = ""
    var lastTokenUploadError: String?

    static let initial = PTTSystemPolicyState()
}

enum PTTSystemPolicyEvent: Equatable {
    case ephemeralTokenReceived(tokenHex: String, backendChannelID: String?)
    case tokenUploadFinished
    case tokenUploadFailed(String)
    case reset
}

enum PTTSystemPolicyEffect: Equatable {
    case uploadEphemeralToken(PTTTokenUploadRequest)
}

struct PTTSystemPolicyTransition: Equatable {
    var state: PTTSystemPolicyState
    var effects: [PTTSystemPolicyEffect] = []
}

enum PTTSystemPolicyReducer {
    static func reduce(
        state: PTTSystemPolicyState,
        event: PTTSystemPolicyEvent
    ) -> PTTSystemPolicyTransition {
        var nextState = state
        var effects: [PTTSystemPolicyEffect] = []

        switch event {
        case .ephemeralTokenReceived(let tokenHex, let backendChannelID):
            nextState.latestTokenHex = tokenHex
            nextState.lastTokenUploadError = nil
            if let backendChannelID {
                effects.append(
                    .uploadEphemeralToken(
                        PTTTokenUploadRequest(
                            backendChannelID: backendChannelID,
                            tokenHex: tokenHex
                        )
                    )
                )
            }

        case .tokenUploadFinished:
            nextState.lastTokenUploadError = nil

        case .tokenUploadFailed(let message):
            nextState.lastTokenUploadError = message

        case .reset:
            nextState = .initial
        }

        return PTTSystemPolicyTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class PTTSystemPolicyCoordinator {
    private(set) var state = PTTSystemPolicyState.initial
    var effectHandler: (@MainActor (PTTSystemPolicyEffect) async -> Void)?

    func send(_ event: PTTSystemPolicyEvent) {
        state = PTTSystemPolicyReducer.reduce(state: state, event: event).state
    }

    func handle(_ event: PTTSystemPolicyEvent) async {
        let transition = PTTSystemPolicyReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }
}

enum PTTSystemDisplayPolicy {
    static func pushTokenHex(from token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    static func restoredDescriptorName(
        channelUUID: UUID,
        contacts: [Contact],
        fallbackName: String
    ) -> String {
        if let contact = contacts.first(where: { $0.channelId == channelUUID }) {
            return "Chat with \(contact.name)"
        }
        return fallbackName
    }
}
