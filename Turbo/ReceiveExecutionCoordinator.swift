import Foundation

enum RemoteReceiveActivitySource: String, Equatable {
    case incomingPush
    case transmitPrepareSignal
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
    var activityGeneration: Int = 0
    var isPeerTransmitting: Bool = true

    var timeoutPhase: RemoteReceiveTimeoutPhase {
        hasReceivedAudioChunk ? .drainingAudio : .awaitingFirstAudioChunk
    }
}

struct ReceiveExecutionSessionState: Equatable {
    var remoteActivityByContactID: [UUID: RemoteReceiveActivityState] = [:]
    var remoteTransmitStoppedContactIDs: Set<UUID> = []

    var remoteTransmittingContactIDs: Set<UUID> {
        Set(
            remoteActivityByContactID.compactMap { contactID, activityState in
                activityState.isPeerTransmitting ? contactID : nil
            }
        )
    }

    mutating func replaceRemoteTransmittingContactIDs(_ contactIDs: Set<UUID>) {
        remoteTransmitStoppedContactIDs.subtract(contactIDs)
        remoteActivityByContactID = contactIDs.reduce(into: [:]) { result, contactID in
            result[contactID] = RemoteReceiveActivityState(
                lastSource: .transmitStartSignal,
                hasReceivedAudioChunk: false,
                activityGeneration: 1
            )
        }
    }
}

enum ReceiveExecutionEvent: Equatable {
    case reset
    case remoteActivityDetected(contactID: UUID, source: RemoteReceiveActivitySource)
    case remoteTransmitStopped(contactID: UUID, preservePlaybackDrain: Bool)
    case silenceTimeoutElapsed(contactID: UUID)
}

enum ReceiveExecutionEffect: Equatable {
    case scheduleRemoteSilenceTimeout(
        contactID: UUID,
        phase: RemoteReceiveTimeoutPhase,
        generation: Int
    )
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
            let previousActivity = nextState.remoteActivityByContactID[contactID]
            let stopAlreadyObserved =
                nextState.remoteTransmitStoppedContactIDs.contains(contactID)
            if source != .audioChunk {
                nextState.remoteTransmitStoppedContactIDs.remove(contactID)
            }
            let continuesPlaybackDrainAfterStop =
                source == .audioChunk
                && (
                    previousActivity?.isPeerTransmitting == false
                    || stopAlreadyObserved
                )
            let startsNewPeerTransmitAfterDrain =
                source != .audioChunk
                && (
                    previousActivity?.isPeerTransmitting == false
                    || stopAlreadyObserved
                )
            let hasReceivedAudioChunk =
                source == .audioChunk
                || (
                    source == .transmitStartSignal
                    && previousActivity?.hasReceivedAudioChunk == true
                    && !startsNewPeerTransmitAfterDrain
                )
            let isPeerTransmitting =
                source == .transmitPrepareSignal
                ? false
                : !continuesPlaybackDrainAfterStop
            let activityState = RemoteReceiveActivityState(
                lastSource: source,
                hasReceivedAudioChunk: hasReceivedAudioChunk,
                activityGeneration: (previousActivity?.activityGeneration ?? 0) + 1,
                isPeerTransmitting: isPeerTransmitting
            )
            nextState.remoteActivityByContactID[contactID] = activityState
            effects.append(
                .scheduleRemoteSilenceTimeout(
                    contactID: contactID,
                    phase: activityState.timeoutPhase,
                    generation: activityState.activityGeneration
                )
            )

        case .remoteTransmitStopped(let contactID, let preservePlaybackDrain):
            nextState.remoteTransmitStoppedContactIDs.insert(contactID)
            guard var activityState = nextState.remoteActivityByContactID[contactID] else {
                break
            }
            if preservePlaybackDrain, activityState.hasReceivedAudioChunk {
                activityState.isPeerTransmitting = false
                activityState.activityGeneration += 1
                nextState.remoteActivityByContactID[contactID] = activityState
                effects.append(
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .drainingAudio,
                        generation: activityState.activityGeneration
                    )
                )
                break
            }
            nextState.remoteActivityByContactID.removeValue(forKey: contactID)
            effects.append(.cancelRemoteSilenceTimeout(contactID: contactID))

        case .silenceTimeoutElapsed(let contactID):
            nextState.remoteActivityByContactID.removeValue(forKey: contactID)
        }

        return ReceiveExecutionTransition(state: nextState, effects: effects)
    }
}

final class ReceiveExecutionRuntimeState {
    var remoteAudioSilenceTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingPlaybackDrainStartedAtNanosecondsByContactID: [UUID: UInt64] = [:]
    private var remoteTransmitStopProjectionGraceStartedAtNanosecondsByContactID: [UUID: UInt64] = [:]

    func pendingPlaybackDrainDeferralElapsedNanoseconds(
        for contactID: UUID,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        if let startedAt = pendingPlaybackDrainStartedAtNanosecondsByContactID[contactID] {
            return nowNanoseconds >= startedAt ? nowNanoseconds - startedAt : 0
        }
        pendingPlaybackDrainStartedAtNanosecondsByContactID[contactID] = nowNanoseconds
        return 0
    }

    func clearPendingPlaybackDrainDeferral(for contactID: UUID) {
        pendingPlaybackDrainStartedAtNanosecondsByContactID[contactID] = nil
    }

    func markRemoteTransmitStopProjectionGrace(
        for contactID: UUID,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        remoteTransmitStopProjectionGraceStartedAtNanosecondsByContactID[contactID] = nowNanoseconds
    }

    func clearRemoteTransmitStopProjectionGrace(for contactID: UUID) {
        remoteTransmitStopProjectionGraceStartedAtNanosecondsByContactID[contactID] = nil
    }

    func remoteTransmitStopProjectionGraceIsActive(
        for contactID: UUID,
        maximumAgeNanoseconds: UInt64,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        guard let startedAt = remoteTransmitStopProjectionGraceStartedAtNanosecondsByContactID[contactID] else {
            return false
        }
        return nowNanoseconds >= startedAt
            ? nowNanoseconds - startedAt <= maximumAgeNanoseconds
            : true
    }

    func replaceRemoteAudioSilenceTask(
        for contactID: UUID,
        with task: Task<Void, Never>?
    ) {
        remoteAudioSilenceTasks[contactID]?.cancel()
        remoteAudioSilenceTasks[contactID] = task
        if task == nil {
            clearPendingPlaybackDrainDeferral(for: contactID)
        }
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
        pendingPlaybackDrainStartedAtNanosecondsByContactID = [:]
        remoteTransmitStopProjectionGraceStartedAtNanosecondsByContactID = [:]
    }
}

@MainActor
final class ReceiveExecutionCoordinator {
    private(set) var state = ReceiveExecutionSessionState()
    var effectHandler: (@MainActor (ReceiveExecutionEffect) -> Void)?
    var transitionReporter: (@MainActor (ReducerTransitionReport) -> Void)?

    func send(_ event: ReceiveExecutionEvent) {
        let previousState = state
        let transition = ReceiveExecutionReducer.reduce(state: state, event: event)
        state = transition.state
        reportTransition(previousState: previousState, event: event, transition: transition)
        for effect in transition.effects {
            effectHandler?(effect)
        }
    }

    func replaceRemoteTransmittingContactIDs(_ contactIDs: Set<UUID>) {
        state.replaceRemoteTransmittingContactIDs(contactIDs)
    }

    private func reportTransition(
        previousState: ReceiveExecutionSessionState,
        event: ReceiveExecutionEvent,
        transition: ReceiveExecutionTransition
    ) {
        transitionReporter?(
            ReducerTransitionReport.make(
                reducerName: "receive-execution",
                event: event,
                previousState: previousState,
                nextState: transition.state,
                effects: transition.effects
            )
        )
    }
}
