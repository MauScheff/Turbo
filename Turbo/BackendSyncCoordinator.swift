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
    case invitesPartiallyUpdated(incoming: [BackendInviteUpdate]?, outgoing: [BackendInviteUpdate]?, now: Date)
    case invitesFailed(String)
    case outgoingInviteSeeded(contactID: UUID, invite: TurboInviteResponse, now: Date)
    case incomingRequestHandled(contactID: UUID, invite: TurboInviteResponse?, requestCount: Int, now: Date)
}

enum BackendSyncEffect: Equatable {
    case bootstrapIfNeeded
    case ensureWebSocketConnected
    case heartbeatPresence
    case refreshContactSummaries
    case refreshInvites
    case refreshChannelState(UUID)
    case refreshForegroundControlPlane(selectedContactID: UUID?)
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
            nextState.syncState.hasEstablishedConnection = true
            nextState.syncState.statusMessage = "Backend connected (\(mode)) as \(handle)"

        case .bootstrapFailed(let message):
            nextState.syncState.hasEstablishedConnection = false
            nextState.syncState.statusMessage = "Backend unavailable: \(message)"

        case .reset(let statusMessage):
            nextState.syncState.reset(statusMessage: statusMessage)

        case .pollRequested(let selectedContactID):
            if nextState.syncState.hasEstablishedConnection {
                effects = [
                    .ensureWebSocketConnected,
                    .heartbeatPresence,
                    .refreshForegroundControlPlane(selectedContactID: selectedContactID),
                ]
            } else {
                effects = [.bootstrapIfNeeded]
            }

        case .webSocketStateChanged(let state, let selectedContactID):
            switch state {
            case .idle:
                nextState.syncState.invalidateRemoteReceiverReadinessAfterWebSocketIdle()
                if nextState.syncState.hasEstablishedConnection {
                    effects.append(contentsOf: [
                        .ensureWebSocketConnected,
                        .refreshForegroundControlPlane(selectedContactID: selectedContactID),
                    ])
                }
            case .connecting:
                break
            case .connected:
                effects.append(contentsOf: [
                    .heartbeatPresence,
                    .refreshForegroundControlPlane(selectedContactID: selectedContactID),
                ])
            }

        case .contactSummariesUpdated(let updates):
            let summaries = Dictionary(uniqueKeysWithValues: updates.map { ($0.contactID, $0.summary) })
            nextState.syncState.applyContactSummaries(summaries)

        case .contactSummariesFailed(let message):
            nextState.syncState.applyRecoverableSyncFailureStatus(message)

        case .channelStateUpdated(let contactID, let channelState):
            nextState.syncState.applyChannelState(channelState, for: contactID)

        case .channelReadinessUpdated(let contactID, let readiness):
            nextState.syncState.applyChannelReadiness(readiness, for: contactID)

        case .channelStateCleared(let contactID):
            nextState.syncState.clearChannelState(for: contactID)

        case .channelStateFailed(_, let message):
            nextState.syncState.applyRecoverableSyncFailureStatus(message)

        case .clearAllChannelStates:
            nextState.syncState.channelStates = [:]
            nextState.syncState.channelReadiness = [:]

        case .invitesUpdated(let incoming, let outgoing, let now):
            let incomingMap = Dictionary(uniqueKeysWithValues: incoming.map { ($0.contactID, $0.invite) })
            let outgoingMap = Dictionary(uniqueKeysWithValues: outgoing.map { ($0.contactID, $0.invite) })
            nextState.syncState.applyInvites(incoming: incomingMap, outgoing: outgoingMap, now: now)

        case .invitesPartiallyUpdated(let incoming, let outgoing, let now):
            let incomingMap = incoming.map {
                Dictionary(uniqueKeysWithValues: $0.map { ($0.contactID, $0.invite) })
            }
            let outgoingMap = outgoing.map {
                Dictionary(uniqueKeysWithValues: $0.map { ($0.contactID, $0.invite) })
            }
            nextState.syncState.applyPartialInvites(incoming: incomingMap, outgoing: outgoingMap, now: now)

        case .invitesFailed(let message):
            nextState.syncState.applyRecoverableSyncFailureStatus(message)

        case .outgoingInviteSeeded(let contactID, let invite, let now):
            nextState.syncState.outgoingInvites[contactID] = invite
            nextState.syncState.requestCooldownDeadlines[contactID] = now.addingTimeInterval(30)
            nextState.syncState.requestCooldownSourceKeys[contactID] =
                "\(invite.inviteId)|\(invite.requestCount)|\(invite.updatedAt ?? invite.createdAt)"

        case .incomingRequestHandled(let contactID, let invite, let requestCount, _):
            nextState.syncState.markIncomingRequestHandled(
                contactID: contactID,
                invite: invite,
                requestCount: requestCount
            )
        }

        return BackendSyncTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class BackendSyncCoordinator {
    private(set) var state = BackendSyncSessionState()
    var effectHandler: (@MainActor (BackendSyncEffect) async -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?

    func send(_ event: BackendSyncEvent) {
        let previousState = state
        let transition = BackendSyncReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
    }

    func handle(_ event: BackendSyncEvent) async {
        let previousState = state
        let transition = BackendSyncReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    private func reportTransition(
        previousState: BackendSyncSessionState,
        event: BackendSyncEvent,
        transition: BackendSyncTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "backend-sync",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }
}
