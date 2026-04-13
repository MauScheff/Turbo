//
//  PTTViewModelRuntime.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation

final class BackendRuntimeState {
    var pollTask: Task<Void, Never>?
    var config = TurboBackendConfig.load()
    var client: TurboBackendClient?
    var currentUserID: String?
    var isReady: Bool = false
    var mode: String = "unknown"
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
        mode: String
    ) {
        self.client = client
        currentUserID = userID
        isReady = true
        self.mode = mode
    }

    func disconnectForReconnect() {
        client?.disconnectWebSocket()
        client = nil
        currentUserID = nil
        isReady = false
        mode = "unknown"
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

    func storeAuthenticatedUserID(_ userID: String) {
        currentUserID = userID
    }

    func track(contactID: UUID) {
        trackedContactIDs.insert(contactID)
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

struct TransmitRuntimeState {
    var activeTarget: TransmitTarget?
    var beginTask: Task<Void, Never>?
    var renewTask: Task<Void, Never>?
    var isPressingTalk: Bool = false
    var unexpectedSystemEndRetryCount: Int = 0

    var hasPendingBeginOrActiveTarget: Bool {
        beginTask != nil || activeTarget != nil
    }

    mutating func sync(activeTarget: TransmitTarget?, isPressingTalk: Bool) {
        self.activeTarget = activeTarget
        self.isPressingTalk = isPressingTalk
        if activeTarget == nil || !isPressingTalk {
            unexpectedSystemEndRetryCount = 0
        }
    }

    mutating func replaceBeginTask(with task: Task<Void, Never>?) {
        beginTask?.cancel()
        beginTask = task
    }

    mutating func replaceRenewTask(with task: Task<Void, Never>?) {
        renewTask?.cancel()
        renewTask = task
    }

    mutating func clearPendingWork() {
        replaceBeginTask(with: nil)
        replaceRenewTask(with: nil)
    }

    func shouldRetryUnexpectedSystemEnd(maxRetries: Int) -> Bool {
        isPressingTalk && activeTarget != nil && unexpectedSystemEndRetryCount < maxRetries
    }

    mutating func markUnexpectedSystemEndRetry() {
        unexpectedSystemEndRetryCount += 1
    }

    mutating func clearUnexpectedSystemEndRetry() {
        unexpectedSystemEndRetryCount = 0
    }

    mutating func reset() {
        isPressingTalk = false
        activeTarget = nil
        unexpectedSystemEndRetryCount = 0
        clearPendingWork()
    }
}

enum IncomingWakePlaybackMode: Equatable {
    case awaitingPTTActivation
    case appManagedFallback
    case systemActivated
}

struct PendingIncomingPTTPush: Equatable {
    let contactID: UUID
    let channelUUID: UUID
    let payload: TurboPTTPushPayload
    var hasConfirmedIncomingPush: Bool = false
    var playbackMode: IncomingWakePlaybackMode = .awaitingPTTActivation
    var bufferedAudioChunks: [String] = []
}

final class PTTWakeRuntimeState {
    private let maximumBufferedAudioChunks = 12
    var pendingIncomingPush: PendingIncomingPTTPush?
    private var playbackFallbackTasks: [UUID: Task<Void, Never>] = [:]

    func store(_ push: PendingIncomingPTTPush) {
        pendingIncomingPush = push
    }

    func confirmIncomingPush(for channelUUID: UUID, payload: TurboPTTPushPayload) {
        guard var pendingIncomingPush,
              pendingIncomingPush.channelUUID == channelUUID else {
            return
        }
        pendingIncomingPush.hasConfirmedIncomingPush = true
        pendingIncomingPush = PendingIncomingPTTPush(
            contactID: pendingIncomingPush.contactID,
            channelUUID: pendingIncomingPush.channelUUID,
            payload: payload,
            hasConfirmedIncomingPush: true,
            playbackMode: pendingIncomingPush.playbackMode,
            bufferedAudioChunks: pendingIncomingPush.bufferedAudioChunks
        )
        self.pendingIncomingPush = pendingIncomingPush
    }

    func markAudioSessionActivated(for channelUUID: UUID) {
        guard var pendingIncomingPush,
              pendingIncomingPush.channelUUID == channelUUID else {
            return
        }
        pendingIncomingPush.playbackMode = .systemActivated
        self.pendingIncomingPush = pendingIncomingPush
    }

    func markAppManagedFallbackStarted(for contactID: UUID) {
        guard var pendingIncomingPush,
              pendingIncomingPush.contactID == contactID else {
            return
        }
        pendingIncomingPush.playbackMode = .appManagedFallback
        self.pendingIncomingPush = pendingIncomingPush
    }

    func shouldBufferAudioChunk(for contactID: UUID) -> Bool {
        guard let pendingIncomingPush else { return false }
        return pendingIncomingPush.contactID == contactID
            && pendingIncomingPush.playbackMode == .awaitingPTTActivation
    }

    func hasPendingWake(for contactID: UUID) -> Bool {
        pendingIncomingPush?.contactID == contactID
    }

    func hasConfirmedIncomingPush(for contactID: UUID) -> Bool {
        guard let pendingIncomingPush,
              pendingIncomingPush.contactID == contactID else {
            return false
        }
        return pendingIncomingPush.hasConfirmedIncomingPush
    }

    func bufferAudioChunk(_ payload: String, for contactID: UUID) {
        guard var pendingIncomingPush,
              pendingIncomingPush.contactID == contactID else {
            return
        }
        pendingIncomingPush.bufferedAudioChunks.append(payload)
        if pendingIncomingPush.bufferedAudioChunks.count > maximumBufferedAudioChunks {
            pendingIncomingPush.bufferedAudioChunks.removeFirst(
                pendingIncomingPush.bufferedAudioChunks.count - maximumBufferedAudioChunks
            )
        }
        self.pendingIncomingPush = pendingIncomingPush
    }

    func takeBufferedAudioChunks(for contactID: UUID) -> [String] {
        guard var pendingIncomingPush,
              pendingIncomingPush.contactID == contactID else {
            return []
        }
        let bufferedAudioChunks = pendingIncomingPush.bufferedAudioChunks
        pendingIncomingPush.bufferedAudioChunks.removeAll(keepingCapacity: false)
        self.pendingIncomingPush = pendingIncomingPush
        return bufferedAudioChunks
    }

    func bufferedAudioChunkCount(for contactID: UUID) -> Int {
        guard let pendingIncomingPush,
              pendingIncomingPush.contactID == contactID else {
            return 0
        }
        return pendingIncomingPush.bufferedAudioChunks.count
    }

    func replacePlaybackFallbackTask(for contactID: UUID, with task: Task<Void, Never>?) {
        playbackFallbackTasks[contactID]?.cancel()
        if let task {
            playbackFallbackTasks[contactID] = task
        } else {
            playbackFallbackTasks.removeValue(forKey: contactID)
        }
    }

    func hasPlaybackFallbackTask(for contactID: UUID) -> Bool {
        playbackFallbackTasks[contactID] != nil
    }

    func clear(for contactID: UUID) {
        replacePlaybackFallbackTask(for: contactID, with: nil)
        guard pendingIncomingPush?.contactID == contactID else { return }
        pendingIncomingPush = nil
    }

    func clearAll() {
        for contactID in playbackFallbackTasks.keys {
            replacePlaybackFallbackTask(for: contactID, with: nil)
        }
        pendingIncomingPush = nil
    }

    func mediaSessionActivationMode(for contactID: UUID) -> MediaSessionActivationMode {
        guard let pendingIncomingPush,
              pendingIncomingPush.contactID == contactID else {
            return .appManaged
        }
        switch pendingIncomingPush.playbackMode {
        case .systemActivated:
            return .systemActivated
        case .awaitingPTTActivation, .appManagedFallback:
            return .appManaged
        }
    }
}

final class MediaRuntimeState {
    var session: MediaSession?
    var contactID: UUID?
    var connectionState: MediaConnectionState = .idle
    var sendAudioChunk: (@Sendable (String) async throws -> Void)?
    var startupState: MediaSessionStartupState = .idle
    var pendingInteractivePrewarmAfterAudioDeactivationContactID: UUID?

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

    func reset() {
        session?.close()
        session = nil
        contactID = nil
        connectionState = .idle
        sendAudioChunk = nil
        startupState = .idle
    }

    func requestInteractivePrewarmAfterAudioDeactivation(for contactID: UUID) {
        pendingInteractivePrewarmAfterAudioDeactivationContactID = contactID
    }

    func takePendingInteractivePrewarmAfterAudioDeactivationContactID() -> UUID? {
        defer { pendingInteractivePrewarmAfterAudioDeactivationContactID = nil }
        return pendingInteractivePrewarmAfterAudioDeactivationContactID
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

struct BackendServices {
    let client: TurboBackendClient
    let currentUserID: String?
    let mode: String

    var supportsWebSocket: Bool { client.supportsWebSocket }
    var isWebSocketConnected: Bool { client.isWebSocketConnected }
    var deviceID: String { client.deviceID }
    var usesLocalHTTPBackend: Bool { mode == "local-http" }

    func fetchRuntimeConfig() async throws -> TurboBackendRuntimeConfig {
        try await client.fetchRuntimeConfig()
    }

    func authenticate() async throws -> TurboAuthSessionResponse {
        try await client.authenticate()
    }

    func registerDevice(label: String?) async throws -> TurboDeviceRegistrationResponse {
        try await client.registerDevice(label: label)
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

    func heartbeatPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await client.heartbeatPresence()
    }

    func lookupUser(handle: String) async throws -> TurboUserLookupResponse {
        try await client.lookupUser(handle: handle)
    }

    func lookupPresence(handle: String) async throws -> TurboUserPresenceResponse {
        try await client.lookupPresence(handle: handle)
    }

    func contactSummaries() async throws -> [TurboContactSummaryResponse] {
        try await client.contactSummaries()
    }

    func directChannel(otherHandle: String) async throws -> TurboDirectChannelResponse {
        try await client.directChannel(otherHandle: otherHandle)
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

    func createInvite(otherHandle: String) async throws -> TurboInviteResponse {
        try await client.createInvite(otherHandle: otherHandle)
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

    func uploadEphemeralToken(channelId: String, token: String) async throws -> TurboTokenResponse {
        try await client.uploadEphemeralToken(channelId: channelId, token: token)
    }

    func beginTransmit(channelId: String) async throws -> TurboBeginTransmitResponse {
        try await client.beginTransmit(channelId: channelId)
    }

    func endTransmit(channelId: String) async throws -> TurboEndTransmitResponse {
        try await client.endTransmit(channelId: channelId)
    }

    func renewTransmit(channelId: String) async throws -> TurboRenewTransmitResponse {
        try await client.renewTransmit(channelId: channelId)
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
struct TransmitServices {
    let hasPendingBeginOrActiveTarget: () -> Bool
    let activeTarget: () -> TransmitTarget?
    let replaceBeginTask: (Task<Void, Never>?) -> Void
    let replaceRenewTask: (Task<Void, Never>?) -> Void
    let clearPendingWork: () -> Void
    let reset: () -> Void
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
    let reset: () -> Void
}
