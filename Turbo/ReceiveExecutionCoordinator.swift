import Foundation

enum RemoteReceiveActivitySource: String, Equatable {
    case incomingPush
    case transmitStartSignal
    case audioChunk
}

enum RemoteReceiveTimeoutPhase: String, Equatable {
    case awaitingFirstAudioChunk
    case drainingAudio
}

struct RemoteReceiveActivityState: Equatable {
    var lastSource: RemoteReceiveActivitySource
    var hasReceivedAudioChunk: Bool

    var timeoutPhase: RemoteReceiveTimeoutPhase {
        hasReceivedAudioChunk ? .drainingAudio : .awaitingFirstAudioChunk
    }
}

struct ReceiveExecutionSessionState: Equatable {
    var remoteActivityByContactID: [UUID: RemoteReceiveActivityState] = [:]

    var remoteTransmittingContactIDs: Set<UUID> {
        Set(remoteActivityByContactID.keys)
    }

    mutating func replaceRemoteTransmittingContactIDs(_ contactIDs: Set<UUID>) {
        remoteActivityByContactID = contactIDs.reduce(into: [:]) { result, contactID in
            result[contactID] = RemoteReceiveActivityState(
                lastSource: .transmitStartSignal,
                hasReceivedAudioChunk: false
            )
        }
    }
}

enum ReceiveExecutionEvent: Equatable {
    case reset
    case remoteActivityDetected(contactID: UUID, source: RemoteReceiveActivitySource)
    case remoteTransmitStopped(contactID: UUID)
    case silenceTimeoutElapsed(contactID: UUID)
}

enum ReceiveExecutionEffect: Equatable {
    case scheduleRemoteSilenceTimeout(contactID: UUID, phase: RemoteReceiveTimeoutPhase)
    case cancelRemoteSilenceTimeout(contactID: UUID)
    case cancelAllRemoteSilenceTimeouts
}

struct ReceiveExecutionTransition: Equatable {
    var state: ReceiveExecutionSessionState
    var effects: [ReceiveExecutionEffect] = []
}

enum ReceiveExecutionReducer {
    static func reduce(
        state: ReceiveExecutionSessionState,
        event: ReceiveExecutionEvent
    ) -> ReceiveExecutionTransition {
        var nextState = state
        var effects: [ReceiveExecutionEffect] = []

        switch event {
        case .reset:
            if !nextState.remoteActivityByContactID.isEmpty {
                effects.append(.cancelAllRemoteSilenceTimeouts)
            }
            nextState = ReceiveExecutionSessionState()

        case .remoteActivityDetected(let contactID, let source):
            let hasReceivedAudioChunk =
                (nextState.remoteActivityByContactID[contactID]?.hasReceivedAudioChunk ?? false)
                || source == .audioChunk
            let activityState = RemoteReceiveActivityState(
                lastSource: source,
                hasReceivedAudioChunk: hasReceivedAudioChunk
            )
            nextState.remoteActivityByContactID[contactID] = activityState
            effects.append(
                .scheduleRemoteSilenceTimeout(
                    contactID: contactID,
                    phase: activityState.timeoutPhase
                )
            )

        case .remoteTransmitStopped(let contactID):
            guard nextState.remoteActivityByContactID.removeValue(forKey: contactID) != nil else {
                break
            }
            effects.append(.cancelRemoteSilenceTimeout(contactID: contactID))

        case .silenceTimeoutElapsed(let contactID):
            nextState.remoteActivityByContactID.removeValue(forKey: contactID)
        }

        return ReceiveExecutionTransition(state: nextState, effects: effects)
    }
}

final class ReceiveExecutionRuntimeState {
    var remoteAudioSilenceTasks: [UUID: Task<Void, Never>] = [:]

    func replaceRemoteAudioSilenceTask(
        for contactID: UUID,
        with task: Task<Void, Never>?
    ) {
        remoteAudioSilenceTasks[contactID]?.cancel()
        remoteAudioSilenceTasks[contactID] = task
    }

    func replaceRemoteAudioSilenceTasks(_ tasks: [UUID: Task<Void, Never>]) {
        for task in remoteAudioSilenceTasks.values {
            task.cancel()
        }
        remoteAudioSilenceTasks = tasks
    }

    func cancelAllRemoteAudioSilenceTasks() {
        for task in remoteAudioSilenceTasks.values {
            task.cancel()
        }
        remoteAudioSilenceTasks = [:]
    }
}

@MainActor
final class ReceiveExecutionCoordinator {
    private(set) var state = ReceiveExecutionSessionState()
    var effectHandler: (@MainActor (ReceiveExecutionEffect) -> Void)?

    func send(_ event: ReceiveExecutionEvent) {
        let transition = ReceiveExecutionReducer.reduce(state: state, event: event)
        state = transition.state
        for effect in transition.effects {
            effectHandler?(effect)
        }
    }

    func replaceRemoteTransmittingContactIDs(_ contactIDs: Set<UUID>) {
        state.replaceRemoteTransmittingContactIDs(contactIDs)
    }
}
