import Foundation

struct BackendContactSummaryUpdate: Equatable {
    let contactID: UUID
    let summary: TurboContactSummaryResponse
}

struct BackendInviteUpdate: Equatable {
    let contactID: UUID
    let invite: TurboInviteResponse
}

struct BackendSyncSessionState: Equatable {
    var syncState = BackendSyncState()
}

enum BackendSyncEvent: Equatable {
    case statusMessageUpdated(String)
    case bootstrapCompleted(mode: String, handle: String)
    case bootstrapFailed(String)
    case reset(statusMessage: String)
    case pollRequested(selectedContactID: UUID?)
    case webSocketStateChanged(TurboBackendClient.WebSocketConnectionState, selectedContactID: UUID?)
    case contactSummariesUpdated([BackendContactSummaryUpdate])
    case contactSummariesFailed(String)
    case channelStateUpdated(contactID: UUID, channelState: TurboChannelStateResponse)
    case channelReadinessUpdated(contactID: UUID, readiness: TurboChannelReadinessResponse)
    case channelStateCleared(contactID: UUID)
    case channelStateFailed(contactID: UUID, message: String)
    case clearAllChannelStates
    case invitesUpdated(incoming: [BackendInviteUpdate], outgoing: [BackendInviteUpdate], now: Date)
    case invitesFailed(String)
    case outgoingInviteSeeded(contactID: UUID, invite: TurboInviteResponse, now: Date)
}

enum BackendSyncEffect: Equatable {
    case ensureWebSocketConnected
    case heartbeatPresence
    case refreshContactSummaries
    case refreshInvites
    case refreshChannelState(UUID)
}

struct BackendSyncTransition: Equatable {
    var state: BackendSyncSessionState
    var effects: [BackendSyncEffect] = []
}

enum BackendSyncReducer {
    static func reduce(
        state: BackendSyncSessionState,
        event: BackendSyncEvent
    ) -> BackendSyncTransition {
        var nextState = state
        var effects: [BackendSyncEffect] = []

        switch event {
        case .statusMessageUpdated(let message):
            nextState.syncState.statusMessage = message

        case .bootstrapCompleted(let mode, let handle):
            nextState.syncState.statusMessage = "Backend connected (\(mode)) as \(handle)"

        case .bootstrapFailed(let message):
            nextState.syncState.statusMessage = "Backend unavailable: \(message)"

        case .reset(let statusMessage):
            nextState.syncState.reset(statusMessage: statusMessage)

        case .pollRequested(let selectedContactID):
            effects = [.ensureWebSocketConnected, .heartbeatPresence, .refreshContactSummaries, .refreshInvites]
            if let selectedContactID {
                effects.append(.refreshChannelState(selectedContactID))
            }

        case .webSocketStateChanged(let state, let selectedContactID):
            if state == .connected, let selectedContactID {
                effects.append(contentsOf: [
                    .heartbeatPresence,
                    .refreshContactSummaries,
                    .refreshInvites,
                    .refreshChannelState(selectedContactID),
                ])
            }

        case .contactSummariesUpdated(let updates):
            let summaries = Dictionary(uniqueKeysWithValues: updates.map { ($0.contactID, $0.summary) })
            nextState.syncState.applyContactSummaries(summaries)

        case .contactSummariesFailed(let message):
            nextState.syncState.statusMessage = message

        case .channelStateUpdated(let contactID, let channelState):
            nextState.syncState.applyChannelState(channelState, for: contactID)

        case .channelReadinessUpdated(let contactID, let readiness):
            nextState.syncState.applyChannelReadiness(readiness, for: contactID)

        case .channelStateCleared(let contactID):
            nextState.syncState.clearChannelState(for: contactID)

        case .channelStateFailed(_, let message):
            nextState.syncState.statusMessage = message

        case .clearAllChannelStates:
            nextState.syncState.channelStates = [:]
            nextState.syncState.channelReadiness = [:]

        case .invitesUpdated(let incoming, let outgoing, let now):
            let incomingMap = Dictionary(uniqueKeysWithValues: incoming.map { ($0.contactID, $0.invite) })
            let outgoingMap = Dictionary(uniqueKeysWithValues: outgoing.map { ($0.contactID, $0.invite) })
            nextState.syncState.applyInvites(incoming: incomingMap, outgoing: outgoingMap, now: now)

        case .invitesFailed(let message):
            nextState.syncState.statusMessage = message

        case .outgoingInviteSeeded(let contactID, let invite, let now):
            nextState.syncState.outgoingInvites[contactID] = invite
            nextState.syncState.requestCooldownDeadlines[contactID] = now.addingTimeInterval(30)
        }

        return BackendSyncTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class BackendSyncCoordinator {
    private(set) var state = BackendSyncSessionState()
    var effectHandler: (@MainActor (BackendSyncEffect) async -> Void)?

    func send(_ event: BackendSyncEvent) {
        state = BackendSyncReducer.reduce(state: state, event: event).state
    }

    func handle(_ event: BackendSyncEvent) async {
        let transition = BackendSyncReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }
}
