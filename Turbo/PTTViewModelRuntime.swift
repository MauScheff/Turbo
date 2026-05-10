//
//  PTTViewModelRuntime.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import CryptoKit
import Foundation

final class BackendRuntimeState {
    var pollTask: Task<Void, Never>?
    var bootstrapRetryTask: Task<Void, Never>?
    var signalingJoinRecoveryTask: Task<Void, Never>?
    var config = TurboBackendConfig.load()
    var client: TurboBackendClient?
    var currentUserID: String?
    var currentPublicID: String?
    var currentShareCode: String?
    var currentShareLink: String?
    var currentProfileName: String?
    var isReady: Bool = false
    var mode: String = "unknown"
    var telemetryEnabled: Bool = false
    var trackedContactIDs: Set<UUID> = []
    var transportFaults = TransportFaultRuntimeState()

    var hasClient: Bool {
        client != nil
    }

    var isWebSocketConnected: Bool {
        client?.isWebSocketConnected == true
    }

    func applyAuthenticatedSession(
        client: TurboBackendClient,
        userID: String,
        mode: String,
        telemetryEnabled: Bool,
        publicID: String? = nil,
        profileName: String? = nil,
        shareCode: String? = nil,
        shareLink: String? = nil
    ) {
        self.client = client
        currentUserID = userID
        currentPublicID = publicID
        currentProfileName = profileName
        currentShareCode = shareCode ?? publicID
        currentShareLink = shareLink
        isReady = true
        self.mode = mode
        self.telemetryEnabled = telemetryEnabled
    }

    func disconnectForReconnect() {
        client?.disconnectWebSocket()
        client = nil
        currentUserID = nil
        currentPublicID = nil
        currentShareCode = nil
        currentShareLink = nil
        currentProfileName = nil
        isReady = false
        mode = "unknown"
        telemetryEnabled = false
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = nil
        signalingJoinRecoveryTask?.cancel()
        signalingJoinRecoveryTask = nil
        pollTask?.cancel()
        pollTask = nil
    }

    func replaceConfig(with config: TurboBackendConfig?) {
        self.config = config
    }

    func replacePollTask(with task: Task<Void, Never>?) {
        pollTask?.cancel()
        pollTask = task
    }

    func replaceBootstrapRetryTask(with task: Task<Void, Never>?) {
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = task
    }

    func replaceSignalingJoinRecoveryTask(with task: Task<Void, Never>?) {
        signalingJoinRecoveryTask?.cancel()
        signalingJoinRecoveryTask = task
    }

    func storeAuthenticatedUserID(_ userID: String) {
        currentUserID = userID
    }

    func storeCurrentProfileName(_ profileName: String?) {
        currentProfileName = profileName
    }

    func track(contactID: UUID) {
        trackedContactIDs.insert(contactID)
    }

    func untrack(contactID: UUID) {
        trackedContactIDs.remove(contactID)
    }

    func clearTrackedContacts() {
        trackedContactIDs = []
    }
}

enum TransportFaultHTTPRoute: String, CaseIterable {
    case contactSummaries = "contact-summaries"
    case incomingInvites = "incoming-invites"
    case outgoingInvites = "outgoing-invites"
    case channelState = "channel-state"
    case channelReadiness = "channel-readiness"
    case renewTransmit = "renew-transmit"
}

struct TransportFaultSignalDeliveryPlan: Equatable {
    let delayMilliseconds: Int
    let duplicateDeliveries: Int
    let shouldDrop: Bool
}

enum TransportFaultWebSocketReorderResult {
    case deliver([TurboSignalEnvelope])
    case buffered
}

final class TransportFaultRuntimeState {
    private struct DelayRule: Equatable {
        let milliseconds: Int
        var remainingMatches: Int
    }

    private struct WebSocketReorderRule {
        let kind: TurboSignalKind?
        let count: Int
        var buffered: [TurboSignalEnvelope] = []
    }

    private var httpDelayRules: [TransportFaultHTTPRoute: DelayRule] = [:]
    private var webSocketDelayRules: [TurboSignalKind: DelayRule] = [:]
    private var webSocketDropCounts: [TurboSignalKind: Int] = [:]
    private var webSocketDuplicateCounts: [TurboSignalKind: Int] = [:]
    private var webSocketReorderRule: WebSocketReorderRule?

    func reset() {
        httpDelayRules = [:]
        webSocketDelayRules = [:]
        webSocketDropCounts = [:]
        webSocketDuplicateCounts = [:]
        webSocketReorderRule = nil
    }

    func setHTTPDelay(route: TransportFaultHTTPRoute, milliseconds: Int, count: Int) {
        precondition(milliseconds >= 0, "HTTP delay must be non-negative")
        precondition(count >= 1, "HTTP delay count must be at least 1")
        httpDelayRules[route] = DelayRule(milliseconds: milliseconds, remainingMatches: count)
    }

    func consumeHTTPDelay(for route: TransportFaultHTTPRoute) -> Int {
        consumeDelay(from: &httpDelayRules, key: route)
    }

    func setWebSocketSignalDelay(kind: TurboSignalKind, milliseconds: Int, count: Int) {
        precondition(milliseconds >= 0, "WebSocket signal delay must be non-negative")
        precondition(count >= 1, "WebSocket signal delay count must be at least 1")
        webSocketDelayRules[kind] = DelayRule(milliseconds: milliseconds, remainingMatches: count)
    }

    func dropNextWebSocketSignals(kind: TurboSignalKind, count: Int) {
        precondition(count >= 1, "Dropped signal count must be at least 1")
        webSocketDropCounts[kind] = count
    }

    func duplicateNextWebSocketSignals(kind: TurboSignalKind, count: Int) {
        precondition(count >= 1, "Duplicated signal count must be at least 1")
        webSocketDuplicateCounts[kind] = count
    }

    func reorderNextWebSocketSignals(kind: TurboSignalKind?, count: Int) {
        precondition(count >= 2, "Reordered signal count must be at least 2")
        webSocketReorderRule = WebSocketReorderRule(kind: kind, count: count)
    }

    func consumeWebSocketReorderResult(for envelope: TurboSignalEnvelope) -> TransportFaultWebSocketReorderResult {
        guard var rule = webSocketReorderRule else {
            return .deliver([envelope])
        }

        if let kind = rule.kind, envelope.type != kind {
            return .deliver([envelope])
        }

        rule.buffered.append(envelope)
        if rule.buffered.count < rule.count {
            webSocketReorderRule = rule
            return .buffered
        }

        webSocketReorderRule = nil
        return .deliver(rule.buffered.reversed())
    }

    func consumeWebSocketSignalDeliveryPlan(for kind: TurboSignalKind) -> TransportFaultSignalDeliveryPlan {
        if consumeCount(from: &webSocketDropCounts, key: kind) {
            return TransportFaultSignalDeliveryPlan(
                delayMilliseconds: 0,
                duplicateDeliveries: 0,
                shouldDrop: true
            )
        }

        let delayMilliseconds = consumeDelay(from: &webSocketDelayRules, key: kind)
        let duplicateDeliveries = consumeCount(from: &webSocketDuplicateCounts, key: kind) ? 1 : 0

        return TransportFaultSignalDeliveryPlan(
            delayMilliseconds: delayMilliseconds,
            duplicateDeliveries: duplicateDeliveries,
            shouldDrop: false
        )
    }

    private func consumeDelay<Key: Hashable>(
        from rules: inout [Key: DelayRule],
        key: Key
    ) -> Int {
        guard var rule = rules[key] else { return 0 }
        let milliseconds = rule.milliseconds
        rule.remainingMatches -= 1
        if rule.remainingMatches <= 0 {
            rules.removeValue(forKey: key)
        } else {
            rules[key] = rule
        }
        return milliseconds
    }

    private func consumeCount<Key: Hashable>(
        from counts: inout [Key: Int],
        key: Key
    ) -> Bool {
        guard let remaining = counts[key], remaining > 0 else {
            return false
        }
        if remaining == 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = remaining - 1
        }
        return true
    }
}

struct TransmitStartupTimingState {
    private(set) var pressRequestedAt: Date?
    private(set) var contactID: UUID?
    private(set) var channelUUID: UUID?
    private(set) var backendChannelID: String?
    private(set) var source: String?
    private(set) var stageElapsedMillisecondsByName: [String: Int] = [:]

    mutating func start(
        contactID: UUID,
        channelUUID: UUID?,
        backendChannelID: String,
        source: String,
        at date: Date = Date()
    ) {
        pressRequestedAt = date
        self.contactID = contactID
        self.channelUUID = channelUUID
        self.backendChannelID = backendChannelID
        self.source = source
        stageElapsedMillisecondsByName = [:]
    }

    func elapsedMilliseconds(at date: Date = Date()) -> Int? {
        guard let pressRequestedAt else { return nil }
        return Int(date.timeIntervalSince(pressRequestedAt) * 1000)
    }

    mutating func noteStage(_ stage: String, at date: Date = Date()) -> Int? {
        guard let elapsed = elapsedMilliseconds(at: date) else { return nil }
        stageElapsedMillisecondsByName[stage] = elapsed
        return elapsed
    }

    mutating func noteStageIfAbsent(_ stage: String, at date: Date = Date()) -> Int? {
        if let existing = stageElapsedMillisecondsByName[stage] {
            return existing
        }
        return noteStage(stage, at: date)
    }

    func elapsedMilliseconds(for stage: String) -> Int? {
        stageElapsedMillisecondsByName[stage]
    }

    mutating func reset() {
        pressRequestedAt = nil
        contactID = nil
        channelUUID = nil
        backendChannelID = nil
        source = nil
        stageElapsedMillisecondsByName = [:]
    }
}

struct TransmitRuntimeState {
    private(set) var executionState: TransmitExecutionSessionState = .initial

    var activeTarget: TransmitTarget? {
        executionState.activeTarget
    }

    var pendingSystemBeginChannelUUID: UUID? {
        executionState.pendingSystemBeginChannelUUID
    }

    var isPressingTalk: Bool {
        executionState.isPressingTalk
    }

    var explicitStopRequested: Bool {
        executionState.explicitStopRequested
    }

    var requiresReleaseBeforeNextPress: Bool {
        executionState.requiresReleaseBeforeNextPress
    }

    var interruptedContactID: UUID? {
        executionState.interruptedContactID
    }

    var lastSystemTransmitBeganAt: Date? {
        executionState.lastSystemTransmitBeganAt
    }

    var hasSystemTransmitLifecycle: Bool {
        executionState.hasSystemTransmitLifecycle
    }

    var isSystemTransmitting: Bool {
        executionState.isSystemTransmitting
    }

    var shouldAwaitInitialOutboundAudioSendGate: Bool {
        executionState.initialOutboundAudioSendGateState.shouldAwaitInitialRemoteReady
    }

    mutating func syncActiveTarget(_ activeTarget: TransmitTarget?) {
        reduce(.syncActiveTarget(activeTarget))
    }

    mutating func markPressBegan() {
        reduce(.markPressBegan)
    }

    mutating func markPressEnded() {
        reduce(.markPressEnded)
    }

    mutating func markUnexpectedSystemEndRequiresRelease(contactID: UUID?) {
        reduce(.markUnexpectedSystemEndRequiresRelease(contactID: contactID))
    }

    mutating func noteSystemTransmitBegan(at date: Date = Date()) {
        reduce(.noteSystemTransmitBegan(date))
    }

    mutating func noteSystemTransmitEnded() {
        reduce(.noteSystemTransmitEnded)
    }

    mutating func noteSystemTransmitBeginRequested(channelUUID: UUID) {
        reduce(.noteSystemTransmitBeginRequested(channelUUID: channelUUID))
    }

    mutating func clearPendingSystemTransmitBegin(channelUUID: UUID? = nil) {
        reduce(.clearPendingSystemTransmitBegin(channelUUID: channelUUID))
    }

    func isSystemTransmitBeginPending(channelUUID: UUID) -> Bool {
        pendingSystemBeginChannelUUID == channelUUID
    }

    mutating func beginSystemTransmitActivationIfNeeded(channelUUID: UUID) -> Bool {
        switch executionState.systemTransmitActivationState {
        case .idle:
            reduce(.beginSystemTransmitActivation(channelUUID: channelUUID))
            return true
        case .activating(let existingChannelUUID), .activated(let existingChannelUUID):
            guard existingChannelUUID != channelUUID else { return false }
            reduce(.beginSystemTransmitActivation(channelUUID: channelUUID))
            return true
        }
    }

    mutating func noteSystemTransmitActivationCompleted(channelUUID: UUID) {
        reduce(.markSystemTransmitActivationCompleted(channelUUID: channelUUID))
    }

    mutating func clearSystemTransmitActivation(channelUUID: UUID? = nil) {
        reduce(.clearSystemTransmitActivation(channelUUID: channelUUID))
    }

    func currentSystemTransmitDurationMilliseconds(at date: Date = Date()) -> Int? {
        guard let lastSystemTransmitBeganAt else { return nil }
        return Int(date.timeIntervalSince(lastSystemTransmitBeganAt) * 1000)
    }

    mutating func noteTouchReleased() {
        reduce(.noteTouchReleased)
    }

    mutating func reconcileIdleState() {
        reduce(.reconcileIdleState)
    }

    mutating func markExplicitStopRequested() {
        reduce(.markExplicitStopRequested)
    }

    mutating func takeShouldAwaitInitialOutboundAudioSendGate() -> Bool {
        let shouldAwait = shouldAwaitInitialOutboundAudioSendGate
        guard shouldAwait else { return false }
        reduce(.consumeInitialOutboundAudioSendGate)
        return true
    }

    mutating func reset() {
        reduce(.reset)
    }

    mutating func handleSystemTransmitEnded(
        applicationStateIsActive: Bool,
        matchingActiveTarget: TransmitTarget?
    ) -> SystemTransmitEndDisposition {
        let effects = reduce(
            .handleSystemTransmitEnded(
                applicationStateIsActive: applicationStateIsActive,
                matchingActiveTarget: matchingActiveTarget
            )
        )
        guard case .handledSystemTransmitEnded(let disposition)? = effects.last else {
            return .none
        }
        return disposition
    }

    @discardableResult
    private mutating func reduce(_ event: TransmitExecutionEvent) -> [TransmitExecutionEffect] {
        let transition = TransmitExecutionReducer.reduce(
            state: executionState,
            event: event
        )
        executionState = transition.state
        return transition.effects
    }
}

enum TransmitDomainPhase: Equatable {
    case idle
    case requesting(contactID: UUID)
    case active(contactID: UUID)
    case stopping(contactID: UUID)
}

struct TransmitDomainSnapshot: Equatable {
    let phase: TransmitDomainPhase
    let isPressActive: Bool
    let explicitStopRequested: Bool
    let isSystemTransmitting: Bool
    let activeTarget: TransmitTarget?
    let interruptedContactID: UUID?
    let requiresReleaseBeforeNextPress: Bool

    var activeContactID: UUID? {
        switch phase {
        case .idle:
            return nil
        case .requesting(let contactID), .active(let contactID), .stopping(let contactID):
            return contactID
        }
    }

    func hasTransmitIntent(for contactID: UUID) -> Bool {
        guard !explicitStopRequested else { return false }
        switch phase {
        case .requesting(let activeContactID), .active(let activeContactID):
            return activeContactID == contactID
        case .idle, .stopping:
            return false
        }
    }

    func isStopping(for contactID: UUID) -> Bool {
        guard explicitStopRequested else { return false }
        switch phase {
        case .stopping(let activeContactID):
            return activeContactID == contactID
        case .idle, .requesting, .active:
            return false
        }
    }

    func requiresFreshPress(for contactID: UUID) -> Bool {
        requiresReleaseBeforeNextPress && interruptedContactID == contactID
    }

    func localTransmitProjection(
        for contactID: UUID,
        mediaState: MediaConnectionState,
        pttAudioSessionActive: Bool
    ) -> LocalTransmitProjection {
        LocalTransmitProjection.legacy(
            isTransmitting: hasTransmitIntent(for: contactID),
            isStopping: isStopping(for: contactID),
            requiresFreshPress: requiresFreshPress(for: contactID),
            transmitPhase: phase,
            systemIsTransmitting: isSystemTransmitting,
            pttAudioSessionActive: pttAudioSessionActive,
            mediaState: mediaState
        )
    }
}

struct TransmitProjection: Equatable {
    let controlPlane: TransmitSessionState
    let execution: TransmitExecutionSessionState
    let systemChannelUUID: UUID?
    let systemActiveContactID: UUID?
    let systemIsTransmitting: Bool

    var activeTarget: TransmitTarget? {
        controlPlane.activeTarget ?? execution.activeTarget
    }

    var fallbackContactID: UUID? {
        activeTarget?.contactID
            ?? (systemIsTransmitting ? systemActiveContactID : nil)
    }

    var domainPhase: TransmitDomainPhase {
        if execution.explicitStopRequested, let contactID = fallbackContactID {
            return .stopping(contactID: contactID)
        }

        if systemIsTransmitting, let contactID = systemActiveContactID ?? fallbackContactID {
            return .active(contactID: contactID)
        }

        switch controlPlane.phase {
        case .idle:
            if let contactID = fallbackContactID, execution.isPressingTalk {
                return .requesting(contactID: contactID)
            }
            return .idle
        case .requesting(let contactID):
            return .requesting(contactID: contactID)
        case .active(let contactID):
            return execution.explicitStopRequested ? .stopping(contactID: contactID) : .active(contactID: contactID)
        case .stopping(let contactID):
            return .stopping(contactID: contactID)
        }
    }

    var domainSnapshot: TransmitDomainSnapshot {
        TransmitDomainSnapshot(
            phase: domainPhase,
            isPressActive: !execution.explicitStopRequested && (execution.isPressingTalk || controlPlane.isPressingTalk),
            explicitStopRequested: execution.explicitStopRequested,
            isSystemTransmitting: systemIsTransmitting,
            activeTarget: activeTarget,
            interruptedContactID: execution.interruptedContactID,
            requiresReleaseBeforeNextPress: execution.requiresReleaseBeforeNextPress
        )
    }

    func activeTarget(
        for systemChannelUUID: UUID,
        channelUUIDForContact: (UUID) -> UUID?
    ) -> TransmitTarget? {
        guard let activeTarget else { return nil }
        guard channelUUIDForContact(activeTarget.contactID) == systemChannelUUID else { return nil }
        return activeTarget
    }

    func hasPendingLifecycle(
        for systemChannelUUID: UUID,
        channelUUIDForContact: (UUID) -> UUID?
    ) -> Bool {
        if activeTarget(for: systemChannelUUID, channelUUIDForContact: channelUUIDForContact) != nil {
            return true
        }
        return controlPlane.pendingRequest?.channelUUID == systemChannelUUID
    }
}

enum IncomingRelayAudioDiagnosticDisposition: Equatable {
    case detailed
    case suppressedNotice
    case suppressed
}

struct PendingEncryptedAudioPayload: Equatable {
    let payload: String
    let channelID: String
    let fromUserID: String
    let fromDeviceID: String
    let transport: IncomingAudioPayloadTransport
    let receivedAt: Date
}

struct FirstTalkDirectQuicGrace: Equatable {
    let channelID: String
    let startedAt: Date
    var expired: Bool
}

struct MediaEncryptionSession {
    let channelID: String
    let localDeviceID: String
    let peerDeviceID: String
    let localFingerprint: String
    let peerFingerprint: String
    let localPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let peerIdentity: MediaEncryptionIdentityRegistrationMetadata

    var keyID: String {
        MediaEndToEndEncryption.keyID(
            localFingerprint: localFingerprint,
            peerFingerprint: peerFingerprint,
            channelID: channelID
        )
    }

    func context(senderDeviceID: String, receiverDeviceID: String) -> MediaEncryptionContext {
        MediaEncryptionContext(
            channelID: channelID,
            sessionID: MediaEndToEndEncryption.sessionID(channelID: channelID),
            senderDeviceID: senderDeviceID,
            receiverDeviceID: receiverDeviceID
        )
    }
}

final class MediaRuntimeState {
    var session: MediaSession?
    var contactID: UUID?
    var connectionState: MediaConnectionState = .idle
    var transportPathState: MediaTransportPathState = .relay
    let directQuicUpgrade = DirectQuicUpgradeRuntimeState()
    var directQuicProbeController: DirectQuicProbeController?
    var directQuicPromotionTimeoutTask: Task<Void, Never>?
    var directQuicAutoProbeTask: Task<Void, Never>?
    private var firstTalkDirectQuicGraceEntries: [(contactID: UUID, grace: FirstTalkDirectQuicGrace)] = []
    private var firstTalkDirectQuicGraceExpiryTasks: [(contactID: UUID, task: Task<Void, Never>)] = []
    var sendAudioChunk: (@Sendable (String) async throws -> Void)?
    var startupState: MediaSessionStartupState = .idle
    var pendingInteractivePrewarmAfterAudioDeactivationContactID: UUID?
    var interactivePrewarmRecoveryTask: Task<Void, Never>?
    private var outboundReceiverPrewarmRequestIDByContactID: [UUID: String] = [:]
    private var handledReceiverPrewarmRequestIDs: Set<String> = []
    private(set) var receiverPrewarmAckRequestIDByContactID: [UUID: String] = [:]
    private var receiverPrewarmAckReceivedAtByContactID: [UUID: Date] = [:]
    private var directQuicUpgradeRequestSentAtByContactID: [UUID: Date] = [:]
    private(set) var directQuicWarmPongIDByContactID: [UUID: String] = [:]
    private var directQuicWarmPongReceivedAtByContactID: [UUID: Date] = [:]
    private var incomingRelayAudioDetailedReportsRemainingByContactID: [UUID: Int] = [:]
    private var incomingRelayAudioSuppressionReportedContactIDs: Set<UUID> = []
    private var mediaEncryptionSessionsByContactID: [UUID: MediaEncryptionSession] = [:]
    private var mediaEncryptionSendSequenceByContactID: [UUID: UInt64] = [:]
    private var mediaEncryptionReceiveSequenceByContactID: [UUID: UInt64] = [:]
    private var mediaEncryptionPlaintextFallbackLogKeys: Set<String> = []
    private var pendingEncryptedAudioPayloadsByContactID: [UUID: [PendingEncryptedAudioPayload]] = [:]
    private var encryptedAudioRecoveryTasksByContactID: [UUID: Task<Void, Never>] = [:]

    var hasSession: Bool {
        session != nil
    }

    var hasSendAudioChunk: Bool {
        sendAudioChunk != nil
    }

    func attach(session: MediaSession, contactID: UUID) {
        self.session = session
        self.contactID = contactID
    }

    func updateConnectionState(_ state: MediaConnectionState) {
        connectionState = state
        switch state {
        case .connected, .closed, .idle:
            startupState = .idle
        case .failed(let message):
            if case .starting(let context) = startupState {
                startupState = .failed(
                    MediaSessionStartupFailure(
                        context: context,
                        message: message,
                        occurredAt: Date()
                    )
                )
            }
        case .preparing:
            break
        }
    }

    func replaceSendAudioChunk(with handler: (@Sendable (String) async throws -> Void)?) {
        sendAudioChunk = handler
    }

    func markStartupInFlight(_ context: MediaSessionStartupContext) {
        startupState = .starting(context)
        connectionState = .preparing
    }

    func markStartupSucceeded() {
        startupState = .idle
        connectionState = .connected
    }

    func markStartupFailed(
        _ context: MediaSessionStartupContext,
        message: String
    ) {
        startupState = .failed(
            MediaSessionStartupFailure(
                context: context,
                message: message,
                occurredAt: Date()
            )
        )
        connectionState = .failed(message)
    }

    func isStartupInFlight(for context: MediaSessionStartupContext) -> Bool {
        guard case .starting(let activeContext) = startupState else { return false }
        return activeContext == context
    }

    func shouldDelayRetry(
        for context: MediaSessionStartupContext,
        now: Date = Date(),
        cooldown: TimeInterval
    ) -> Bool {
        guard case .failed(let failure) = startupState else { return false }
        guard failure.context == context else { return false }
        return now.timeIntervalSince(failure.occurredAt) < cooldown
    }

    func reset(
        deactivateAudioSession: Bool = true,
        preserveDirectQuic: Bool = false
    ) {
        interactivePrewarmRecoveryTask?.cancel()
        interactivePrewarmRecoveryTask = nil
        if !preserveDirectQuic {
            directQuicPromotionTimeoutTask?.cancel()
            directQuicPromotionTimeoutTask = nil
            directQuicAutoProbeTask?.cancel()
            directQuicAutoProbeTask = nil
            directQuicProbeController?.cancel(reason: "media-runtime-reset")
            directQuicProbeController = nil
        }
        firstTalkDirectQuicGraceExpiryTasks.forEach { $0.task.cancel() }
        firstTalkDirectQuicGraceExpiryTasks = []
        session?.close(deactivateAudioSession: deactivateAudioSession)
        session = nil
        contactID = nil
        connectionState = .idle
        if !preserveDirectQuic {
            transportPathState = .relay
            directQuicUpgrade.reset()
            outboundReceiverPrewarmRequestIDByContactID = [:]
            handledReceiverPrewarmRequestIDs = []
            receiverPrewarmAckRequestIDByContactID = [:]
            receiverPrewarmAckReceivedAtByContactID = [:]
            directQuicUpgradeRequestSentAtByContactID = [:]
            directQuicWarmPongIDByContactID = [:]
            directQuicWarmPongReceivedAtByContactID = [:]
        }
        firstTalkDirectQuicGraceEntries = []
        incomingRelayAudioDetailedReportsRemainingByContactID = [:]
        incomingRelayAudioSuppressionReportedContactIDs = []
        sendAudioChunk = nil
        startupState = .idle
        pendingEncryptedAudioPayloadsByContactID = [:]
        encryptedAudioRecoveryTasksByContactID.values.forEach { $0.cancel() }
        encryptedAudioRecoveryTasksByContactID = [:]
    }

    func resetIncomingRelayAudioDiagnostics(
        for contactID: UUID,
        detailedReportLimit: Int = 3
    ) {
        incomingRelayAudioDetailedReportsRemainingByContactID[contactID] = max(0, detailedReportLimit)
        incomingRelayAudioSuppressionReportedContactIDs.remove(contactID)
    }

    func consumeIncomingRelayAudioDiagnosticDisposition(
        for contactID: UUID,
        detailedReportLimit: Int = 3
    ) -> IncomingRelayAudioDiagnosticDisposition {
        let currentRemaining =
            incomingRelayAudioDetailedReportsRemainingByContactID[contactID]
            ?? max(0, detailedReportLimit)
        if currentRemaining > 0 {
            incomingRelayAudioDetailedReportsRemainingByContactID[contactID] = currentRemaining - 1
            return .detailed
        }

        if incomingRelayAudioSuppressionReportedContactIDs.insert(contactID).inserted {
            return .suppressedNotice
        }
        return .suppressed
    }

    func shouldSendDirectQuicUpgradeRequest(
        for contactID: UUID,
        minimumInterval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let sentAt = directQuicUpgradeRequestSentAtByContactID[contactID] else {
            return true
        }
        return now.timeIntervalSince(sentAt) >= minimumInterval
    }

    func markDirectQuicUpgradeRequestSent(for contactID: UUID, at date: Date = Date()) {
        directQuicUpgradeRequestSentAtByContactID[contactID] = date
    }

    func clearDirectQuicUpgradeRequestThrottle(for contactID: UUID) {
        directQuicUpgradeRequestSentAtByContactID.removeValue(forKey: contactID)
    }

    func requestInteractivePrewarmAfterAudioDeactivation(for contactID: UUID) {
        pendingInteractivePrewarmAfterAudioDeactivationContactID = contactID
    }

    func takePendingInteractivePrewarmAfterAudioDeactivationContactID() -> UUID? {
        defer { pendingInteractivePrewarmAfterAudioDeactivationContactID = nil }
        return pendingInteractivePrewarmAfterAudioDeactivationContactID
    }

    func replaceInteractivePrewarmRecoveryTask(with task: Task<Void, Never>?) {
        interactivePrewarmRecoveryTask?.cancel()
        interactivePrewarmRecoveryTask = task
    }

    func replaceDirectQuicPromotionTimeoutTask(with task: Task<Void, Never>?) {
        directQuicPromotionTimeoutTask?.cancel()
        directQuicPromotionTimeoutTask = task
    }

    func replaceDirectQuicAutoProbeTask(with task: Task<Void, Never>?) {
        directQuicAutoProbeTask?.cancel()
        directQuicAutoProbeTask = task
    }

    func firstTalkDirectQuicGrace(
        for contactID: UUID,
        channelID: String
    ) -> FirstTalkDirectQuicGrace? {
        guard let grace = firstTalkDirectQuicGraceEntries.first(where: { $0.contactID == contactID })?.grace,
              grace.channelID == channelID else {
            return nil
        }
        return grace
    }

    func markFirstTalkDirectQuicGraceStartedIfNeeded(
        for contactID: UUID,
        channelID: String,
        now: Date = Date()
    ) -> FirstTalkDirectQuicGrace {
        if let existing = firstTalkDirectQuicGrace(
            for: contactID,
            channelID: channelID
        ) {
            return existing
        }
        clearFirstTalkDirectQuicGrace(for: contactID)
        let grace = FirstTalkDirectQuicGrace(
            channelID: channelID,
            startedAt: now,
            expired: false
        )
        firstTalkDirectQuicGraceEntries.append((contactID: contactID, grace: grace))
        return grace
    }

    func expireFirstTalkDirectQuicGrace(
        for contactID: UUID,
        channelID: String
    ) {
        guard var grace = firstTalkDirectQuicGrace(
            for: contactID,
            channelID: channelID
        ) else {
            return
        }
        grace.expired = true
        if let index = firstTalkDirectQuicGraceEntries.firstIndex(where: { $0.contactID == contactID }) {
            firstTalkDirectQuicGraceEntries[index] = (contactID: contactID, grace: grace)
        }
        firstTalkDirectQuicGraceExpiryTasks.removeAll { $0.contactID == contactID }
    }

    func replaceFirstTalkDirectQuicGraceExpiryTask(
        for contactID: UUID,
        with task: Task<Void, Never>?
    ) {
        if let index = firstTalkDirectQuicGraceExpiryTasks.firstIndex(where: { $0.contactID == contactID }) {
            firstTalkDirectQuicGraceExpiryTasks[index].task.cancel()
            firstTalkDirectQuicGraceExpiryTasks.remove(at: index)
        }
        if let task {
            firstTalkDirectQuicGraceExpiryTasks.append((contactID: contactID, task: task))
        }
    }

    func hasFirstTalkDirectQuicGraceExpiryTask(for contactID: UUID) -> Bool {
        firstTalkDirectQuicGraceExpiryTasks.contains { $0.contactID == contactID }
    }

    func clearFirstTalkDirectQuicGrace(for contactID: UUID) {
        firstTalkDirectQuicGraceEntries.removeAll { $0.contactID == contactID }
        if let index = firstTalkDirectQuicGraceExpiryTasks.firstIndex(where: { $0.contactID == contactID }) {
            firstTalkDirectQuicGraceExpiryTasks[index].task.cancel()
            firstTalkDirectQuicGraceExpiryTasks.remove(at: index)
        }
    }

    func updateTransportPathState(_ state: MediaTransportPathState) {
        transportPathState = state
    }

    func replaceDirectQuicProbeController(with controller: DirectQuicProbeController?) {
        directQuicProbeController?.cancel(reason: "replaced")
        directQuicProbeController = controller
    }

    func receiverPrewarmRequestID(for contactID: UUID) -> String {
        if let existing = outboundReceiverPrewarmRequestIDByContactID[contactID] {
            return existing
        }
        let requestID = UUID().uuidString.lowercased()
        outboundReceiverPrewarmRequestIDByContactID[contactID] = requestID
        return requestID
    }

    func replaceReceiverPrewarmRequestID(for contactID: UUID, requestID: String) {
        outboundReceiverPrewarmRequestIDByContactID[contactID] = requestID
        receiverPrewarmAckRequestIDByContactID[contactID] = nil
        receiverPrewarmAckReceivedAtByContactID[contactID] = nil
        directQuicWarmPongIDByContactID[contactID] = nil
        directQuicWarmPongReceivedAtByContactID[contactID] = nil
    }

    func receiverPrewarmRequestIsAcknowledged(
        for contactID: UUID,
        maximumAge: TimeInterval? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let requestID = outboundReceiverPrewarmRequestIDByContactID[contactID],
              let ackRequestID = receiverPrewarmAckRequestIDByContactID[contactID] else {
            return false
        }
        guard requestID == ackRequestID else { return false }
        if let maximumAge {
            guard let receivedAt = receiverPrewarmAckReceivedAtByContactID[contactID] else {
                return false
            }
            return now.timeIntervalSince(receivedAt) <= maximumAge
        }
        return true
    }

    func hasReceiverPrewarmRequest(for contactID: UUID) -> Bool {
        outboundReceiverPrewarmRequestIDByContactID[contactID] != nil
    }

    func markReceiverPrewarmRequestHandled(_ requestID: String) -> Bool {
        handledReceiverPrewarmRequestIDs.insert(requestID).inserted
    }

    func markReceiverPrewarmAckReceived(
        contactID: UUID,
        requestID: String,
        receivedAt: Date = Date()
    ) {
        receiverPrewarmAckRequestIDByContactID[contactID] = requestID
        receiverPrewarmAckReceivedAtByContactID[contactID] = receivedAt
    }

    func markDirectQuicWarmPongReceived(
        contactID: UUID,
        pingID: String?,
        receivedAt: Date = Date()
    ) {
        directQuicWarmPongIDByContactID[contactID] = pingID ?? ""
        directQuicWarmPongReceivedAtByContactID[contactID] = receivedAt
    }

    func directQuicWarmPongIsFresh(
        for contactID: UUID,
        maximumAge: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard directQuicWarmPongIDByContactID[contactID] != nil,
              let receivedAt = directQuicWarmPongReceivedAtByContactID[contactID] else {
            return false
        }
        return now.timeIntervalSince(receivedAt) <= maximumAge
    }

    func clearReceiverPrewarmState(for contactID: UUID) {
        outboundReceiverPrewarmRequestIDByContactID[contactID] = nil
        receiverPrewarmAckRequestIDByContactID[contactID] = nil
        receiverPrewarmAckReceivedAtByContactID[contactID] = nil
        directQuicWarmPongIDByContactID[contactID] = nil
        directQuicWarmPongReceivedAtByContactID[contactID] = nil
    }

    func setMediaEncryptionSession(_ session: MediaEncryptionSession?, for contactID: UUID) {
        mediaEncryptionSessionsByContactID[contactID] = session
        mediaEncryptionSendSequenceByContactID[contactID] = 0
        mediaEncryptionReceiveSequenceByContactID[contactID] = nil
    }

    func mediaEncryptionSession(for contactID: UUID) -> MediaEncryptionSession? {
        mediaEncryptionSessionsByContactID[contactID]
    }

    func resetMediaEncryptionState() {
        mediaEncryptionSessionsByContactID = [:]
        mediaEncryptionSendSequenceByContactID = [:]
        mediaEncryptionReceiveSequenceByContactID = [:]
        mediaEncryptionPlaintextFallbackLogKeys = []
        pendingEncryptedAudioPayloadsByContactID = [:]
        encryptedAudioRecoveryTasksByContactID.values.forEach { $0.cancel() }
        encryptedAudioRecoveryTasksByContactID = [:]
    }

    func takeShouldLogMediaEncryptionPlaintextFallback(
        contactID: UUID,
        direction: String
    ) -> Bool {
        mediaEncryptionPlaintextFallbackLogKeys.insert("\(direction):\(contactID.uuidString)").inserted
    }

    func nextMediaEncryptionSendSequence(for contactID: UUID) -> UInt64 {
        let sequence = mediaEncryptionSendSequenceByContactID[contactID] ?? 0
        mediaEncryptionSendSequenceByContactID[contactID] = sequence + 1
        return sequence
    }

    func resetMediaEncryptionReceiveSequence(for contactID: UUID) {
        mediaEncryptionReceiveSequenceByContactID[contactID] = nil
    }

    func acceptMediaEncryptionReceiveSequence(
        _ sequenceNumber: UInt64,
        for contactID: UUID
    ) -> Bool {
        guard let lastSequence = mediaEncryptionReceiveSequenceByContactID[contactID] else {
            mediaEncryptionReceiveSequenceByContactID[contactID] = sequenceNumber
            return true
        }
        guard sequenceNumber > lastSequence else { return false }
        mediaEncryptionReceiveSequenceByContactID[contactID] = sequenceNumber
        return true
    }

    func enqueuePendingEncryptedAudioPayload(
        _ payload: PendingEncryptedAudioPayload,
        for contactID: UUID,
        maxCount: Int
    ) -> Int {
        var pending = pendingEncryptedAudioPayloadsByContactID[contactID] ?? []
        pending.append(payload)
        if pending.count > maxCount {
            pending.removeFirst(pending.count - maxCount)
        }
        pendingEncryptedAudioPayloadsByContactID[contactID] = pending
        return pending.count
    }

    func drainPendingEncryptedAudioPayloads(for contactID: UUID) -> [PendingEncryptedAudioPayload] {
        let pending = pendingEncryptedAudioPayloadsByContactID[contactID] ?? []
        pendingEncryptedAudioPayloadsByContactID[contactID] = nil
        return pending
    }

    func pendingEncryptedAudioPayloads(for contactID: UUID) -> [PendingEncryptedAudioPayload] {
        pendingEncryptedAudioPayloadsByContactID[contactID] ?? []
    }

    func discardPendingEncryptedAudioPayloads(for contactID: UUID) -> Int {
        let count = pendingEncryptedAudioPayloadsByContactID[contactID]?.count ?? 0
        pendingEncryptedAudioPayloadsByContactID[contactID] = nil
        return count
    }

    func hasEncryptedAudioRecoveryTask(for contactID: UUID) -> Bool {
        encryptedAudioRecoveryTasksByContactID[contactID] != nil
    }

    func replaceEncryptedAudioRecoveryTask(
        for contactID: UUID,
        with task: Task<Void, Never>?
    ) {
        encryptedAudioRecoveryTasksByContactID[contactID]?.cancel()
        encryptedAudioRecoveryTasksByContactID[contactID] = task
    }

    func clearEncryptedAudioRecoveryTask(for contactID: UUID) {
        encryptedAudioRecoveryTasksByContactID[contactID] = nil
    }
}

enum MediaTransportPathState: String, Codable, Equatable {
    case relay
    case promoting
    case direct
    case recovering

    var label: String {
        switch self {
        case .relay:
            return "Relayed"
        case .promoting:
            return "Promoting"
        case .direct:
            return "Direct"
        case .recovering:
            return "Recovering"
        }
    }

    var showsSecureIcon: Bool {
        switch self {
        case .relay, .direct:
            return true
        case .promoting, .recovering:
            return false
        }
    }
}

struct FirstTalkReadinessProjection: Equatable {
    let localMediaWarm: Bool
    let receiverWarm: Bool
    let transportWarm: Bool

    var isReady: Bool {
        localMediaWarm && receiverWarm && transportWarm
    }
}

struct MediaSessionStartupContext: Equatable {
    let contactID: UUID
    let activationMode: MediaSessionActivationMode
    let startupMode: MediaSessionStartupMode
}

struct MediaSessionStartupFailure: Equatable {
    let context: MediaSessionStartupContext
    let message: String
    let occurredAt: Date
}

enum MediaSessionStartupState: Equatable {
    case idle
    case starting(MediaSessionStartupContext)
    case failed(MediaSessionStartupFailure)
}

enum ReceiverAudioReadinessPublicationBasis: Equatable {
    case lifecycle
    case channelRefresh
}

struct ReceiverAudioReadinessPublication: Equatable {
    let isReady: Bool
    let peerWasRoutable: Bool
    let basis: ReceiverAudioReadinessPublicationBasis
    let telemetry: CallPeerTelemetry?
}

struct BackendServices {
    let client: TurboBackendClient
    let criticalHTTPClient: TurboBackendCriticalHTTPClient
    let currentUserID: String?
    let mode: String
    let telemetryEnabled: Bool

    var supportsWebSocket: Bool { client.supportsWebSocket }
    var supportsDirectQuicUpgrade: Bool { client.supportsDirectQuicUpgrade }
    var supportsMediaEndToEndEncryption: Bool { client.supportsMediaEndToEndEncryption }
    var supportsSignalSessionIds: Bool { client.supportsSignalSessionIds }
    var supportsTransmitIds: Bool { client.supportsTransmitIds }
    var supportsProjectionEpochs: Bool { client.supportsProjectionEpochs }
    var isWebSocketConnected: Bool { client.isWebSocketConnected }
    var deviceID: String { client.deviceID }
    var usesLocalHTTPBackend: Bool { mode == "local-http" }
    var directQuicPolicy: TurboDirectQuicPolicy? { client.directQuicPolicy }

    func fetchRuntimeConfig() async throws -> TurboBackendRuntimeConfig {
        try await client.fetchRuntimeConfig()
    }

    func authenticate() async throws -> TurboAuthSessionResponse {
        try await client.authenticate()
    }

    func registerDevice(
        label: String?,
        alertPushToken: String?,
        alertPushEnvironment: TurboAPNSEnvironment?,
        directQuicIdentity: DirectQuicIdentityRegistrationMetadata? = nil,
        mediaEncryptionIdentity: MediaEncryptionIdentityRegistrationMetadata? = nil
    ) async throws -> TurboDeviceRegistrationResponse {
        try await client.registerDevice(
            label: label,
            alertPushToken: alertPushToken,
            alertPushEnvironment: alertPushEnvironment,
            directQuicIdentity: directQuicIdentity,
            mediaEncryptionIdentity: mediaEncryptionIdentity
        )
    }

    func resetDevState() async throws -> TurboResetStateResponse {
        try await client.resetDevState()
    }

    func resetAllDevState() async throws -> TurboResetStateResponse {
        try await client.resetAllDevState()
    }

    func seedDevUsers() async throws -> TurboSeedResponse {
        try await client.seedDevUsers()
    }

    func uploadDiagnostics(_ payload: TurboDiagnosticsUploadRequest) async throws -> TurboDiagnosticsUploadResponse {
        try await client.uploadDiagnostics(payload)
    }

    func latestDiagnostics(deviceId: String) async throws -> TurboLatestDiagnosticsResponse {
        try await client.latestDiagnostics(deviceId: deviceId)
    }

    func uploadTelemetry(_ payload: TurboTelemetryEventRequest) async throws -> TurboTelemetryUploadResponse {
        try await client.uploadTelemetry(payload)
    }

    func heartbeatPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await client.heartbeatPresence()
    }

    func offlinePresence() async throws -> TurboPresenceHeartbeatResponse {
        try await client.offlinePresence()
    }

    func backgroundPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await client.backgroundPresence()
    }

    func lookupUser(handle: String) async throws -> TurboUserLookupResponse {
        try await client.lookupUser(handle: handle)
    }

    func resolveIdentity(reference: String) async throws -> TurboUserLookupResponse {
        try await client.resolveIdentity(reference: reference)
    }

    func rememberContact(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboRememberContactResponse {
        try await client.rememberContact(otherHandle: otherHandle, otherUserId: otherUserId)
    }

    func forgetContact(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboForgetContactResponse {
        try await client.forgetContact(otherHandle: otherHandle, otherUserId: otherUserId)
    }

    func lookupPresence(handle: String) async throws -> TurboUserPresenceResponse {
        try await client.lookupPresence(handle: handle)
    }

    func contactSummaries() async throws -> [TurboContactSummaryResponse] {
        try await client.contactSummaries()
    }

    func directChannel(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboDirectChannelResponse {
        try await client.directChannel(otherHandle: otherHandle, otherUserId: otherUserId)
    }

    func joinChannel(channelId: String) async throws -> TurboJoinResponse {
        try await client.joinChannel(channelId: channelId)
    }

    func leaveChannel(channelId: String) async throws -> TurboLeaveResponse {
        try await client.leaveChannel(channelId: channelId)
    }

    func channelState(channelId: String) async throws -> TurboChannelStateResponse {
        try await client.channelState(channelId: channelId)
    }

    func channelReadiness(channelId: String) async throws -> TurboChannelReadinessResponse {
        try await client.channelReadiness(channelId: channelId)
    }

    func createInvite(
        otherHandle: String? = nil,
        otherUserId: String? = nil
    ) async throws -> TurboInviteResponse {
        try await client.createInvite(otherHandle: otherHandle, otherUserId: otherUserId)
    }

    func incomingInvites() async throws -> [TurboInviteResponse] {
        try await client.incomingInvites()
    }

    func outgoingInvites() async throws -> [TurboInviteResponse] {
        try await client.outgoingInvites()
    }

    func acceptInvite(inviteId: String) async throws -> TurboInviteResponse {
        try await client.acceptInvite(inviteId: inviteId)
    }

    func declineInvite(inviteId: String) async throws -> TurboInviteResponse {
        try await client.declineInvite(inviteId: inviteId)
    }

    func cancelInvite(inviteId: String) async throws -> TurboInviteResponse {
        try await client.cancelInvite(inviteId: inviteId)
    }

    func uploadEphemeralToken(
        channelId: String,
        token: String,
        apnsEnvironment: TurboAPNSEnvironment
    ) async throws -> TurboTokenResponse {
        try await client.uploadEphemeralToken(
            channelId: channelId,
            token: token,
            apnsEnvironment: apnsEnvironment
        )
    }

    func beginTransmit(channelId: String) async throws -> TurboBeginTransmitResponse {
        try await criticalHTTPClient.beginTransmit(channelId: channelId)
    }

    func endTransmit(channelId: String, transmitId: String? = nil) async throws -> TurboEndTransmitResponse {
        try await client.endTransmit(channelId: channelId, transmitId: transmitId)
    }

    func renewTransmit(channelId: String, transmitId: String? = nil) async throws -> TurboRenewTransmitResponse {
        try await client.renewTransmit(channelId: channelId, transmitId: transmitId)
    }

    func connectWebSocket() {
        client.connectWebSocket()
    }

    func disconnectWebSocket() {
        client.disconnectWebSocket()
    }

    func suspendWebSocket() {
        client.suspendWebSocket()
    }

    func resumeWebSocket() {
        client.resumeWebSocket()
    }

    func forceReconnectWebSocket() {
        client.forceReconnectWebSocket()
    }

    func ensureWebSocketConnected() {
        client.ensureWebSocketConnected()
    }

    func waitForWebSocketConnection() async throws {
        try await client.waitForWebSocketConnection()
    }

    func sendSignal(_ envelope: TurboSignalEnvelope) async throws {
        try await client.sendSignal(envelope)
    }
}

@MainActor
struct MediaServices {
    let session: () -> MediaSession?
    let contactID: () -> UUID?
    let hasSession: () -> Bool
    let sendAudioChunk: () -> (@Sendable (String) async throws -> Void)?
    let attach: (MediaSession, UUID) -> Void
    let updateConnectionState: (MediaConnectionState) -> Void
    let isStartupInFlight: (MediaSessionStartupContext) -> Bool
    let shouldDelayRetry: (MediaSessionStartupContext, TimeInterval) -> Bool
    let markStartupInFlight: (MediaSessionStartupContext) -> Void
    let markStartupSucceeded: () -> Void
    let markStartupFailed: (MediaSessionStartupContext, String) -> Void
    let replaceSendAudioChunk: ((@Sendable (String) async throws -> Void)?) -> Void
    let reset: (Bool, Bool) -> Void
}
