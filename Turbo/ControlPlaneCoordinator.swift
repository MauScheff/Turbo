import Foundation

struct ReceiverAudioReadinessIntent: Equatable {
    let contactID: UUID
    let contactHandle: String
    let backendChannelID: String
    let remoteUserID: String
    let currentUserID: String
    let deviceID: String
    let isReady: Bool
    let reason: String

    var publicationBasis: ReceiverAudioReadinessPublicationBasis {
        reason == "channel-refresh" ? .channelRefresh : .lifecycle
    }

    var publishedState: ReceiverAudioReadinessPublication {
        ReceiverAudioReadinessPublication(
            isReady: isReady,
            peerWasRoutable: true,
            basis: publicationBasis
        )
    }

    var suppressedState: ReceiverAudioReadinessPublication {
        ReceiverAudioReadinessPublication(
            isReady: isReady,
            peerWasRoutable: false,
            basis: publicationBasis
        )
    }
}

enum ReceiverAudioReadinessControlState: Equatable {
    case suppressed(ReceiverAudioReadinessPublication)
    case deferred(ReceiverAudioReadinessIntent)
    case published(ReceiverAudioReadinessPublication)

    var cachedPublication: ReceiverAudioReadinessPublication? {
        switch self {
        case .suppressed(let publication), .published(let publication):
            return publication
        case .deferred:
            return nil
        }
    }

    var deferredIntent: ReceiverAudioReadinessIntent? {
        guard case .deferred(let intent) = self else { return nil }
        return intent
    }
}

struct ControlPlaneSessionState: Equatable {
    var receiverAudioReadinessStates: [UUID: ReceiverAudioReadinessControlState] = [:]
    var postWakeRepairContactIDs: Set<UUID> = []

    var localReceiverAudioReadinessPublications: [UUID: ReceiverAudioReadinessPublication] {
        receiverAudioReadinessStates.reduce(into: [:]) { result, entry in
            guard let publication = entry.value.cachedPublication else { return }
            result[entry.key] = publication
        }
    }

    mutating func replaceLocalReceiverAudioReadinessPublications(
        _ publications: [UUID: ReceiverAudioReadinessPublication]
    ) {
        receiverAudioReadinessStates = publications.reduce(into: [:]) { result, entry in
            if entry.value.peerWasRoutable {
                result[entry.key] = .published(entry.value)
            } else {
                result[entry.key] = .suppressed(entry.value)
            }
        }
    }

    mutating func clearCachedReceiverAudioReadinessPublicationsPreservingDeferred() {
        receiverAudioReadinessStates = receiverAudioReadinessStates.compactMapValues { state in
            switch state {
            case .deferred:
                return state
            case .suppressed, .published:
                return nil
            }
        }
    }
}

enum ControlPlaneEvent: Equatable {
    case reset
    case receiverAudioReadinessSyncRequested(
        ReceiverAudioReadinessIntent,
        peerIsRoutable: Bool,
        webSocketConnected: Bool
    )
    case receiverAudioReadinessPublished(ReceiverAudioReadinessIntent)
    case receiverAudioReadinessDeferred(ReceiverAudioReadinessIntent)
    case receiverAudioReadinessContextUnavailable(contactID: UUID)
    case receiverAudioReadinessCacheCleared(contactID: UUID?)
    case webSocketStateChanged(TurboBackendClient.WebSocketConnectionState)
    case postWakeRepairRequested(contactID: UUID)
    case postWakeRepairFinished(contactID: UUID)
}

enum ControlPlaneEffect: Equatable {
    case deferReceiverAudioReadinessUntilReconnect(ReceiverAudioReadinessIntent)
    case publishReceiverAudioReadiness(ReceiverAudioReadinessIntent)
    case performPostWakeRepair(contactID: UUID)
}

struct ControlPlaneTransition: Equatable {
    var state: ControlPlaneSessionState
    var effects: [ControlPlaneEffect] = []
}

enum ControlPlaneReducer {
    static func reduce(
        state: ControlPlaneSessionState,
        event: ControlPlaneEvent
    ) -> ControlPlaneTransition {
        var nextState = state
        var effects: [ControlPlaneEffect] = []

        switch event {
        case .reset:
            nextState = ControlPlaneSessionState()

        case .receiverAudioReadinessSyncRequested(let intent, let peerIsRoutable, let webSocketConnected):
            if !peerIsRoutable {
                nextState.receiverAudioReadinessStates[intent.contactID] = .suppressed(intent.suppressedState)
                break
            }

            if case .published(let publication)? = nextState.receiverAudioReadinessStates[intent.contactID],
               publication == intent.publishedState {
                break
            }

            if !webSocketConnected {
                nextState.receiverAudioReadinessStates[intent.contactID] = .deferred(intent)
                effects.append(.deferReceiverAudioReadinessUntilReconnect(intent))
                break
            }

            effects.append(.publishReceiverAudioReadiness(intent))

        case .receiverAudioReadinessPublished(let intent):
            nextState.receiverAudioReadinessStates[intent.contactID] = .published(intent.publishedState)

        case .receiverAudioReadinessDeferred(let intent):
            nextState.receiverAudioReadinessStates[intent.contactID] = .deferred(intent)
            effects.append(.deferReceiverAudioReadinessUntilReconnect(intent))

        case .receiverAudioReadinessContextUnavailable(let contactID):
            nextState.receiverAudioReadinessStates[contactID] = nil

        case .receiverAudioReadinessCacheCleared(let contactID):
            if let contactID {
                nextState.receiverAudioReadinessStates[contactID] = nil
            } else {
                nextState.clearCachedReceiverAudioReadinessPublicationsPreservingDeferred()
            }

        case .webSocketStateChanged(let state):
            switch state {
            case .idle:
                nextState.clearCachedReceiverAudioReadinessPublicationsPreservingDeferred()
            case .connecting:
                break
            case .connected:
                for deferred in nextState.receiverAudioReadinessStates.values.compactMap(\.deferredIntent) {
                    effects.append(.publishReceiverAudioReadiness(deferred))
                }
            }

        case .postWakeRepairRequested(let contactID):
            guard !nextState.postWakeRepairContactIDs.contains(contactID) else { break }
            nextState.postWakeRepairContactIDs.insert(contactID)
            effects.append(.performPostWakeRepair(contactID: contactID))

        case .postWakeRepairFinished(let contactID):
            nextState.postWakeRepairContactIDs.remove(contactID)
        }

        return ControlPlaneTransition(state: nextState, effects: effects)
    }
}

@MainActor
final class ControlPlaneCoordinator {
    private(set) var state = ControlPlaneSessionState()
    var effectHandler: (@MainActor (ControlPlaneEffect) async -> Void)?

    func send(_ event: ControlPlaneEvent) {
        state = ControlPlaneReducer.reduce(state: state, event: event).state
    }

    func handle(_ event: ControlPlaneEvent) async {
        let transition = ControlPlaneReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            await effectHandler?(effect)
        }
    }

    func replaceLocalReceiverAudioReadinessPublications(
        _ publications: [UUID: ReceiverAudioReadinessPublication]
    ) {
        state.replaceLocalReceiverAudioReadinessPublications(publications)
    }
}
