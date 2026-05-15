import Foundation
import UIKit

enum TurboRequestRelationship: Equatable {
    case none
    case outgoing(requestCount: Int)
    case incoming(requestCount: Int)
    case mutual(requestCount: Int)

    var requestCount: Int? {
        switch self {
        case .none:
            return nil
        case .outgoing(let requestCount), .incoming(let requestCount), .mutual(let requestCount):
            return requestCount
        }
    }

    var hasIncomingRequest: Bool {
        switch self {
        case .incoming, .mutual:
            return true
        case .none, .outgoing:
            return false
        }
    }

    var hasOutgoingRequest: Bool {
        switch self {
        case .outgoing, .mutual:
            return true
        case .none, .incoming:
            return false
        }
    }

    var removingIncomingRequest: TurboRequestRelationship {
        switch self {
        case .incoming:
            return .none
        case .mutual(let requestCount):
            return .outgoing(requestCount: requestCount)
        case .none, .outgoing:
            return self
        }
    }
}

enum TurboSummaryBadgeStatus: Equatable {
    case offline
    case online
    case requested
    case incoming
    case idle
    case waitingForPeer
    case ready
    case transmitting
    case receiving
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "offline":
            self = .offline
        case "online":
            self = .online
        case "requested":
            self = .requested
        case "incoming":
            self = .incoming
        case "connecting", ConversationState.waitingForPeer.rawValue:
            self = .waitingForPeer
        case "ready", ConversationState.ready.rawValue:
            self = .ready
        case "talking", ConversationState.transmitting.rawValue:
            self = .transmitting
        case "receiving", ConversationState.receiving.rawValue:
            self = .receiving
        case "", ConversationState.idle.rawValue:
            self = .idle
        default:
            self = .unknown(rawValue)
        }
    }

    var conversationState: ConversationState {
        switch self {
        case .offline, .online, .idle, .unknown:
            return .idle
        case .requested:
            return .requested
        case .incoming:
            return .incomingRequest
        case .waitingForPeer:
            return .waitingForPeer
        case .ready:
            return .ready
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        }
    }

    var kind: String {
        switch self {
        case .offline:
            return "offline"
        case .online:
            return "online"
        case .requested:
            return "requested"
        case .incoming:
            return "incoming"
        case .idle:
            return "idle"
        case .waitingForPeer:
            return "waiting-for-peer"
        case .ready:
            return "ready"
        case .transmitting:
            return "transmitting"
        case .receiving:
            return "receiving"
        case .unknown(let rawValue):
            return rawValue
        }
    }
}

enum TurboConversationStatus: Equatable {
    case idle
    case requested
    case incomingRequest
    case connecting
    case waitingForPeer
    case ready
    case selfTransmitting(activeTransmitterUserId: String?)
    case peerTransmitting(activeTransmitterUserId: String?)
    case unknown(String)

    init(rawValue: String, activeTransmitterUserId: String?) {
        switch rawValue {
        case "idle":
            self = .idle
        case "requested":
            self = .requested
        case "incoming-request":
            self = .incomingRequest
        case "connecting":
            self = .connecting
        case ConversationState.waitingForPeer.rawValue:
            self = .waitingForPeer
        case ConversationState.ready.rawValue:
            self = .ready
        case ConversationState.transmitting.rawValue:
            self = .selfTransmitting(activeTransmitterUserId: activeTransmitterUserId)
        case ConversationState.receiving.rawValue:
            self = .peerTransmitting(activeTransmitterUserId: activeTransmitterUserId)
        default:
            self = .unknown(rawValue)
        }
    }

    var activeTransmitterUserId: String? {
        switch self {
        case .selfTransmitting(let activeTransmitterUserId), .peerTransmitting(let activeTransmitterUserId):
            return activeTransmitterUserId
        case .idle, .requested, .incomingRequest, .connecting, .waitingForPeer, .ready, .unknown:
            return nil
        }
    }

    var kind: String {
        switch self {
        case .idle:
            return "idle"
        case .requested:
            return "requested"
        case .incomingRequest:
            return "incoming-request"
        case .connecting:
            return "connecting"
        case .waitingForPeer:
            return "waiting-for-peer"
        case .ready:
            return "ready"
        case .selfTransmitting:
            return "self-transmitting"
        case .peerTransmitting:
            return "peer-transmitting"
        case .unknown(let rawValue):
            return rawValue
        }
    }

    var conversationState: ConversationState? {
        switch self {
        case .idle:
            return .idle
        case .requested:
            return .requested
        case .incomingRequest:
            return .incomingRequest
        case .connecting:
            return nil
        case .waitingForPeer:
            return .waitingForPeer
        case .ready:
            return .ready
        case .selfTransmitting:
            return .transmitting
        case .peerTransmitting:
            return .receiving
        case .unknown:
            return nil
        }
    }
}

enum TurboChannelReadinessStatus: Equatable {
    case inactive
    case waitingForSelf
    case waitingForPeer
    case ready
    case selfTransmitting(activeTransmitterUserId: String?)
    case peerTransmitting(activeTransmitterUserId: String?)
    case unknown(String)

    init(rawValue: String, activeTransmitterUserId: String?) {
        switch rawValue {
        case "inactive":
            self = .inactive
        case "waiting-for-self":
            self = .waitingForSelf
        case "waiting-for-peer", ConversationState.waitingForPeer.rawValue:
            self = .waitingForPeer
        case "ready", ConversationState.ready.rawValue:
            self = .ready
        case "self-transmitting":
            self = .selfTransmitting(activeTransmitterUserId: activeTransmitterUserId)
        case "peer-transmitting":
            self = .peerTransmitting(activeTransmitterUserId: activeTransmitterUserId)
        default:
            self = .unknown(rawValue)
        }
    }

    init?(conversationStatus: TurboConversationStatus, canTransmit: Bool) {
        switch conversationStatus {
        case .waitingForPeer:
            self = .waitingForPeer
        case .ready:
            self = canTransmit ? .ready : .waitingForPeer
        case .selfTransmitting(let activeTransmitterUserId):
            self = .selfTransmitting(activeTransmitterUserId: activeTransmitterUserId)
        case .peerTransmitting(let activeTransmitterUserId):
            self = .peerTransmitting(activeTransmitterUserId: activeTransmitterUserId)
        case .connecting:
            self = .waitingForSelf
        case .idle, .requested, .incomingRequest, .unknown:
            return nil
        }
    }

    var kind: String {
        switch self {
        case .inactive:
            return "inactive"
        case .waitingForSelf:
            return "waiting-for-self"
        case .waitingForPeer:
            return "waiting-for-peer"
        case .ready:
            return "ready"
        case .selfTransmitting:
            return "self-transmitting"
        case .peerTransmitting:
            return "peer-transmitting"
        case .unknown(let rawValue):
            return rawValue
        }
    }

    var activeTransmitterUserId: String? {
        switch self {
        case .selfTransmitting(let activeTransmitterUserId), .peerTransmitting(let activeTransmitterUserId):
            return activeTransmitterUserId
        case .inactive, .waitingForSelf, .waitingForPeer, .ready, .unknown:
            return nil
        }
    }

    var conversationState: ConversationState? {
        switch self {
        case .waitingForSelf, .waitingForPeer:
            return .waitingForPeer
        case .inactive:
            return nil
        case .ready:
            return .ready
        case .selfTransmitting:
            return .transmitting
        case .peerTransmitting:
            return .receiving
        case .unknown:
            return nil
        }
    }

    var canTransmit: Bool {
        switch self {
        case .ready:
            return true
        case .inactive, .waitingForSelf, .waitingForPeer, .selfTransmitting, .peerTransmitting, .unknown:
            return false
        }
    }

    var isPeerTransmitting: Bool {
        if case .peerTransmitting = self {
            return true
        }
        return false
    }
}

enum TurboChannelMembership: Equatable {
    case absent
    case peerOnly(peerDeviceConnected: Bool)
    case selfOnly
    case both(peerDeviceConnected: Bool)

    var hasLocalMembership: Bool {
        switch self {
        case .selfOnly, .both:
            return true
        case .absent, .peerOnly:
            return false
        }
    }

    var hasPeerMembership: Bool {
        switch self {
        case .peerOnly, .both:
            return true
        case .absent, .selfOnly:
            return false
        }
    }

    var peerDeviceConnected: Bool {
        switch self {
        case .peerOnly(let peerDeviceConnected), .both(let peerDeviceConnected):
            return peerDeviceConnected
        case .absent, .selfOnly:
            return false
        }
    }
}

struct TurboRequestRelationshipPayload: Decodable, Equatable {
    let kind: String
    let requestCount: Int?

    init(kind: String, requestCount: Int?) {
        self.kind = kind
        self.requestCount = requestCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard Self.validKinds.contains(kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported requestRelationship kind \(kind)"
            )
        }
        self.kind = kind
        self.requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case requestCount
    }

    private static let validKinds: Set<String> = ["none", "incoming", "outgoing", "mutual"]

    var relationship: TurboRequestRelationship {
        let normalizedRequestCount = max(requestCount ?? 1, 1)
        switch kind {
        case "none":
            return .none
        case "incoming":
            return .incoming(requestCount: normalizedRequestCount)
        case "outgoing":
            return .outgoing(requestCount: normalizedRequestCount)
        case "mutual":
            return .mutual(requestCount: normalizedRequestCount)
        default:
            preconditionFailure("Unsupported requestRelationship kind \(kind)")
        }
    }
}

struct TurboChannelMembershipPayload: Decodable, Equatable {
    let kind: String
    let peerDeviceConnected: Bool?

    init(kind: String, peerDeviceConnected: Bool?) {
        self.kind = kind
        self.peerDeviceConnected = peerDeviceConnected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard Self.validKinds.contains(kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported membership kind \(kind)"
            )
        }
        let peerDeviceConnected = try container.decodeIfPresent(Bool.self, forKey: .peerDeviceConnected)
        if Self.kindsRequiringPeerConnectivity.contains(kind), peerDeviceConnected == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .peerDeviceConnected,
                in: container,
                debugDescription: "membership kind \(kind) requires peerDeviceConnected"
            )
        }
        self.kind = kind
        self.peerDeviceConnected = peerDeviceConnected
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case peerDeviceConnected
    }

    private static let validKinds: Set<String> = ["absent", "self-only", "peer-only", "both"]
    private static let kindsRequiringPeerConnectivity: Set<String> = ["peer-only", "both"]

    var membership: TurboChannelMembership {
        switch kind {
        case "absent":
            return .absent
        case "self-only":
            return .selfOnly
        case "peer-only":
            return .peerOnly(peerDeviceConnected: peerDeviceConnected ?? false)
        case "both":
            return .both(peerDeviceConnected: peerDeviceConnected ?? false)
        default:
            preconditionFailure("Unsupported membership kind \(kind)")
        }
    }
}

struct TurboSummaryStatusPayload: Decodable, Equatable {
    let kind: String
    let activeTransmitterUserId: String?

    init(kind: String, activeTransmitterUserId: String?) {
        self.kind = kind
        self.activeTransmitterUserId = activeTransmitterUserId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard Self.validKinds.contains(kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported summaryStatus kind \(kind)"
            )
        }
        self.kind = kind
        self.activeTransmitterUserId = try container.decodeIfPresent(String.self, forKey: .activeTransmitterUserId)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case activeTransmitterUserId
    }

    private static let validKinds: Set<String> = [
        "offline",
        "online",
        "requested",
        "incoming",
        "connecting",
        "idle",
        "waiting-for-peer",
        "ready",
        "talking",
        "transmitting",
        "receiving"
    ]

    var status: TurboSummaryBadgeStatus {
        TurboSummaryBadgeStatus(rawValue: kind)
    }
}

struct TurboConversationStatusPayload: Decodable, Equatable {
    let kind: String
    let activeTransmitterUserId: String?

    init(kind: String, activeTransmitterUserId: String?) {
        self.kind = kind
        self.activeTransmitterUserId = activeTransmitterUserId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard Self.validKinds.contains(kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported conversationStatus kind \(kind)"
            )
        }
        self.kind = kind
        self.activeTransmitterUserId = try container.decodeIfPresent(String.self, forKey: .activeTransmitterUserId)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case activeTransmitterUserId
    }

    private static let validKinds: Set<String> = [
        "idle",
        "requested",
        "incoming-request",
        "connecting",
        "waiting-for-peer",
        "ready",
        "self-transmitting",
        "peer-transmitting"
    ]

    var status: TurboConversationStatus {
        TurboConversationStatus(rawValue: kind, activeTransmitterUserId: activeTransmitterUserId)
    }
}

struct TurboChannelReadinessPayload: Decodable, Equatable {
    let kind: String
    let activeTransmitterUserId: String?

    init(kind: String, activeTransmitterUserId: String?) {
        self.kind = kind
        self.activeTransmitterUserId = activeTransmitterUserId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard Self.validKinds.contains(kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported readiness kind \(kind)"
            )
        }
        self.kind = kind
        self.activeTransmitterUserId = try container.decodeIfPresent(String.self, forKey: .activeTransmitterUserId)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case activeTransmitterUserId
    }

    private static let validKinds: Set<String> = [
        "inactive",
        "waiting-for-self",
        "waiting-for-peer",
        "ready",
        "self-transmitting",
        "peer-transmitting"
    ]

    var status: TurboChannelReadinessStatus {
        TurboChannelReadinessStatus(rawValue: kind, activeTransmitterUserId: activeTransmitterUserId)
    }
}

struct TurboAudioReadinessStatusPayload: Decodable, Equatable {
    let kind: String

    init(kind: String) {
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard Self.validKinds.contains(kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported audio readiness kind \(kind)"
            )
        }
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    private static let validKinds: Set<String> = [
        "unknown",
        "waiting",
        "wake-capable",
        "ready",
    ]

    var status: RemoteAudioReadinessState {
        switch kind {
        case "ready":
            return .ready
        case "wake-capable":
            return .wakeCapable
        case "waiting":
            return .waiting
        default:
            return .unknown
        }
    }
}

struct TurboChannelAudioReadinessPayload: Decodable, Equatable {
    let selfReadiness: TurboAudioReadinessStatusPayload
    let peerReadiness: TurboAudioReadinessStatusPayload
    let peerTargetDeviceId: String?

    init(
        selfReadiness: TurboAudioReadinessStatusPayload,
        peerReadiness: TurboAudioReadinessStatusPayload,
        peerTargetDeviceId: String?
    ) {
        self.selfReadiness = selfReadiness
        self.peerReadiness = peerReadiness
        self.peerTargetDeviceId = peerTargetDeviceId
    }

    private enum CodingKeys: String, CodingKey {
        case selfReadiness = "self"
        case peerReadiness = "peer"
        case peerTargetDeviceId
    }

    var localStatus: RemoteAudioReadinessState {
        selfReadiness.status
    }

    var remoteStatus: RemoteAudioReadinessState {
        peerReadiness.status
    }

    func settingRemoteStatus(_ status: RemoteAudioReadinessState) -> TurboChannelAudioReadinessPayload {
        TurboChannelAudioReadinessPayload(
            selfReadiness: selfReadiness,
            peerReadiness: TurboAudioReadinessStatusPayload(kind: {
                switch status {
                case .unknown:
                    return "unknown"
                case .waiting:
                    return "waiting"
                case .wakeCapable:
                    return "wake-capable"
                case .ready:
                    return "ready"
                }
            }()),
            peerTargetDeviceId: peerTargetDeviceId
        )
    }
}

struct TurboDirectQuicPeerIdentityPayload: Codable, Equatable {
    let fingerprint: String
    let status: String?
    let createdAt: String?
    let updatedAt: String?

    var activeFingerprint: String? {
        guard status == nil || status == "active" else { return nil }
        return DirectQuicProductionIdentityManager.normalizedFingerprint(fingerprint)
    }
}

typealias TurboMediaEncryptionPeerIdentityPayload = MediaEncryptionPeerIdentityPayload

enum TurboWakeCapabilityStatus: Equatable {
    case unavailable
    case wakeCapable(targetDeviceId: String)

    init(rawKind: String, targetDeviceId: String?) {
        switch (rawKind, targetDeviceId) {
        case ("wake-capable", .some(let targetDeviceId)):
            self = .wakeCapable(targetDeviceId: targetDeviceId)
        default:
            self = .unavailable
        }
    }

    var kind: String {
        switch self {
        case .unavailable:
            return "unavailable"
        case .wakeCapable:
            return "wake-capable"
        }
    }

    var targetDeviceId: String? {
        switch self {
        case .unavailable:
            return nil
        case .wakeCapable(let targetDeviceId):
            return targetDeviceId
        }
    }
}

struct TurboWakeCapabilityStatusPayload: Decodable, Equatable {
    let kind: String
    let targetDeviceId: String?

    init(kind: String, targetDeviceId: String? = nil) {
        self.kind = kind
        self.targetDeviceId = targetDeviceId
    }

    var status: TurboWakeCapabilityStatus {
        TurboWakeCapabilityStatus(rawKind: kind, targetDeviceId: targetDeviceId)
    }
}

struct TurboChannelWakeReadinessPayload: Decodable, Equatable {
    let selfWakeCapability: TurboWakeCapabilityStatusPayload
    let peerWakeCapability: TurboWakeCapabilityStatusPayload

    init(
        selfWakeCapability: TurboWakeCapabilityStatusPayload,
        peerWakeCapability: TurboWakeCapabilityStatusPayload
    ) {
        self.selfWakeCapability = selfWakeCapability
        self.peerWakeCapability = peerWakeCapability
    }

    private enum CodingKeys: String, CodingKey {
        case selfWakeCapability = "self"
        case peerWakeCapability = "peer"
    }

    var localStatus: RemoteWakeCapabilityState {
        selfWakeCapability.status.remoteState
    }

    var remoteStatus: RemoteWakeCapabilityState {
        peerWakeCapability.status.remoteState
    }

    func settingRemoteStatus(_ status: RemoteWakeCapabilityState) -> TurboChannelWakeReadinessPayload {
        TurboChannelWakeReadinessPayload(
            selfWakeCapability: selfWakeCapability,
            peerWakeCapability: TurboWakeCapabilityStatusPayload(
                kind: {
                    switch status {
                    case .unavailable:
                        return "unavailable"
                    case .wakeCapable:
                        return "wake-capable"
                    }
                }(),
                targetDeviceId: {
                    switch status {
                    case .unavailable:
                        return nil
                    case .wakeCapable(let targetDeviceId):
                        return targetDeviceId
                    }
                }()
            )
        )
    }
}

private extension TurboWakeCapabilityStatus {
    var remoteState: RemoteWakeCapabilityState {
        switch self {
        case .unavailable:
            return .unavailable
        case .wakeCapable(let targetDeviceId):
            return .wakeCapable(targetDeviceId: targetDeviceId)
        }
    }
}

struct TurboBackendHTTPTransportConfig: Sendable, Equatable {
    let waitsForConnectivity: Bool
    let requestTimeoutSeconds: TimeInterval
    let resourceTimeoutSeconds: TimeInterval

    static let failFastControlPlane = TurboBackendHTTPTransportConfig(
        waitsForConnectivity: false,
        requestTimeoutSeconds: 10,
        resourceTimeoutSeconds: 10
    )

    static let hostedSimulatorScenario = TurboBackendHTTPTransportConfig(
        waitsForConnectivity: true,
        requestTimeoutSeconds: 30,
        resourceTimeoutSeconds: 30
    )
}

enum TurboControlCommandTransportPolicy: String, Sendable, Equatable, Codable {
    case automatic = "automatic"
    case httpOnly = "http-only"
}

struct TurboBackendConfig: Sendable {
    let baseURL: URL
    let devUserHandle: String
    let deviceID: String
    let httpTransport: TurboBackendHTTPTransportConfig
    let controlCommandTransportPolicy: TurboControlCommandTransportPolicy

    init(
        baseURL: URL,
        devUserHandle: String,
        deviceID: String,
        httpTransport: TurboBackendHTTPTransportConfig = .failFastControlPlane,
        controlCommandTransportPolicy: TurboControlCommandTransportPolicy = .automatic
    ) {
        self.baseURL = baseURL
        self.devUserHandle = devUserHandle
        self.deviceID = deviceID
        self.httpTransport = httpTransport
        self.controlCommandTransportPolicy = controlCommandTransportPolicy
    }

    static func load() -> TurboBackendConfig? {
        guard let rawBaseURL = Bundle.main.object(forInfoDictionaryKey: "TurboBackendBaseURL") as? String,
              let baseURL = URL(string: rawBaseURL) else {
            return nil
        }

        return TurboBackendConfig(
            baseURL: baseURL,
            devUserHandle: persistedDevUserHandle(defaultValue: generatedLocalPublicID()),
            deviceID: persistedDeviceID(),
            controlCommandTransportPolicy: TurboControlCommandTransportDebugOverride.policy() ?? .automatic
        )
    }

    static func setPersistedDevUserHandle(_ handle: String) {
        let normalized = normalizeDevUserHandle(handle)
        let defaults = UserDefaults.standard
        defaults.set(normalized, forKey: "TurboAccountPublicID")
        defaults.set(normalized, forKey: "TurboDevUserHandleOverride")
    }

    static func resetPersistedIdentity() {
        setPersistedDevUserHandle(generatedLocalPublicID())
    }

    private static func persistedDevUserHandle(defaultValue: String) -> String {
        let defaults = UserDefaults.standard
        if let current = defaults.string(forKey: "TurboAccountPublicID"),
           !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizeDevUserHandle(current)
        }
        if let override = defaults.string(forKey: "TurboDevUserHandleOverride"),
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = normalizeDevUserHandle(override)
            defaults.set(normalized, forKey: "TurboAccountPublicID")
            return normalized
        }
        let normalized = normalizeDevUserHandle(defaultValue)
        defaults.set(normalized, forKey: "TurboAccountPublicID")
        return normalized
    }

    private static func generatedLocalPublicID() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "bb-\(raw.prefix(10))"
    }

    private static func normalizeDevUserHandle(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TurboHandle.normalizedStoredHandle(generatedLocalPublicID()) }
        return TurboHandle.normalizedStoredHandle(trimmed)
    }

    private static func persistedDeviceID() -> String {
        let defaults = UserDefaults.standard
        let key = "TurboDeviceID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let newValue = UUID().uuidString.lowercased()
        defaults.set(newValue, forKey: key)
        return newValue
    }
}

enum TurboControlCommandTransportDebugOverride {
    static let storageKey = "TurboDebugControlCommandTransportPolicy"
    static let launchArgument = "-TurboDebugControlCommandTransportPolicy"
    static let environmentKey = "TURBO_DEBUG_CONTROL_COMMAND_TRANSPORT_POLICY"

    static func policy(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> TurboControlCommandTransportPolicy? {
        policy(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaults: defaults
        )
    }

    static func policy(
        arguments: [String],
        environment: [String: String],
        defaults: UserDefaults = .standard
    ) -> TurboControlCommandTransportPolicy? {
        if let launchValue = launchArgumentValue(launchArgument, in: arguments),
           let parsed = parsePolicy(launchValue) {
            return parsed
        }
        if let environmentValue = environment[environmentKey],
           let parsed = parsePolicy(environmentValue) {
            return parsed
        }
        if let storedValue = defaults.string(forKey: storageKey),
           let parsed = parsePolicy(storedValue) {
            return parsed
        }
        return nil
    }

    static func setPolicy(_ policy: TurboControlCommandTransportPolicy?, defaults: UserDefaults = .standard) {
        if let policy {
            defaults.set(policy.rawValue, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private static func parsePolicy(_ rawValue: String) -> TurboControlCommandTransportPolicy? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case TurboControlCommandTransportPolicy.automatic.rawValue:
            return .automatic
        case TurboControlCommandTransportPolicy.httpOnly.rawValue, "http", "http_only":
            return .httpOnly
        default:
            return nil
        }
    }

    private static func launchArgumentValue(_ launchArgument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

enum TurboDirectPathDebugOverride {
    static let storageKey = "TurboDebugForceRelayOnly"
    static let launchArgument = "-TurboDebugForceRelayOnly"
    static let environmentKey = "TURBO_DEBUG_FORCE_RELAY_ONLY"
    static let autoUpgradeDisabledStorageKey = "TurboDebugDisableDirectQuicAutoUpgrade"
    static let autoUpgradeDisabledLaunchArgument = "-TurboDebugDisableDirectQuicAutoUpgrade"
    static let autoUpgradeDisabledEnvironmentKey = "TURBO_DEBUG_DISABLE_DIRECT_QUIC_AUTO_UPGRADE"
    static let transmitStartupPolicyStorageKey = "TurboDebugDirectQuicTransmitStartupPolicy"
    static let transmitStartupPolicyStorageVersionKey = "TurboDebugDirectQuicTransmitStartupPolicyVersion"
    static let transmitStartupPolicyLaunchArgument = "-TurboDebugDirectQuicTransmitStartupPolicy"
    static let transmitStartupPolicyEnvironmentKey = "TURBO_DEBUG_DIRECT_QUIC_TRANSMIT_STARTUP_POLICY"
    private static let transmitStartupPolicyStorageVersion = 3

    static func isRelayOnlyForced(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> Bool {
        isRelayOnlyForced(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaults: defaults
        )
    }

    static func isRelayOnlyForced(
        arguments: [String],
        environment: [String: String],
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let launchArgumentValue = launchArgumentValue(arguments),
           let parsed = parseBoolean(launchArgumentValue) {
            return parsed
        }
        if arguments.contains(launchArgument) {
            return true
        }
        if let environmentValue = environment[environmentKey],
           let parsed = parseBoolean(environmentValue) {
            return parsed
        }
        return defaults.bool(forKey: storageKey)
    }

    static func setRelayOnlyForced(_ isForced: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isForced, forKey: storageKey)
    }

    static func isAutoUpgradeDisabled(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> Bool {
        isAutoUpgradeDisabled(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaults: defaults
        )
    }

    static func isAutoUpgradeDisabled(
        arguments: [String],
        environment: [String: String],
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let launchArgumentValue = launchArgumentValue(autoUpgradeDisabledLaunchArgument, in: arguments),
           let parsed = parseBoolean(launchArgumentValue) {
            return parsed
        }
        if arguments.contains(autoUpgradeDisabledLaunchArgument) {
            return true
        }
        if let environmentValue = environment[autoUpgradeDisabledEnvironmentKey],
           let parsed = parseBoolean(environmentValue) {
            return parsed
        }
        return defaults.bool(forKey: autoUpgradeDisabledStorageKey)
    }

    static func setAutoUpgradeDisabled(_ isDisabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isDisabled, forKey: autoUpgradeDisabledStorageKey)
    }

    static func transmitStartupPolicy(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> DirectQuicTransmitStartupPolicy {
        transmitStartupPolicy(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaults: defaults
        )
    }

    static func transmitStartupPolicy(
        arguments: [String],
        environment: [String: String],
        defaults: UserDefaults = .standard
    ) -> DirectQuicTransmitStartupPolicy {
        if let launchArgumentValue = launchArgumentValue(transmitStartupPolicyLaunchArgument, in: arguments),
           let parsed = DirectQuicTransmitStartupPolicy(rawValue: launchArgumentValue) {
            return parsed
        }
        if let environmentValue = environment[transmitStartupPolicyEnvironmentKey],
           let parsed = DirectQuicTransmitStartupPolicy(rawValue: environmentValue) {
            return parsed
        }
        if let stored = defaults.string(forKey: transmitStartupPolicyStorageKey),
           let parsed = DirectQuicTransmitStartupPolicy(rawValue: stored) {
            if parsed == .speculativeForeground,
               defaults.integer(forKey: transmitStartupPolicyStorageVersionKey) < transmitStartupPolicyStorageVersion {
                defaults.set(
                    DirectQuicTransmitStartupPolicy.appleGated.rawValue,
                    forKey: transmitStartupPolicyStorageKey
                )
                defaults.set(
                    transmitStartupPolicyStorageVersion,
                    forKey: transmitStartupPolicyStorageVersionKey
                )
                return .appleGated
            }
            return parsed
        }
        return .speculativeForeground
    }

    static func setTransmitStartupPolicy(
        _ policy: DirectQuicTransmitStartupPolicy,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(policy.rawValue, forKey: transmitStartupPolicyStorageKey)
        defaults.set(transmitStartupPolicyStorageVersion, forKey: transmitStartupPolicyStorageVersionKey)
    }

    private static func launchArgumentValue(_ arguments: [String]) -> String? {
        launchArgumentValue(launchArgument, in: arguments)
    }

    private static func launchArgumentValue(_ launchArgument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parseBoolean(_ rawValue: String) -> Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

enum TurboMediaRelayDebugOverride {
    static let enabledStorageKey = "TurboDebugMediaRelayEnabled"
    static let enabledLaunchArgument = "-TurboDebugMediaRelayEnabled"
    static let enabledEnvironmentKey = "TURBO_DEBUG_MEDIA_RELAY_ENABLED"
    static let forceStorageKey = "TurboDebugForceMediaRelay"
    static let forceLaunchArgument = "-TurboDebugForceMediaRelay"
    static let forceEnvironmentKey = "TURBO_DEBUG_FORCE_MEDIA_RELAY"
    static let hostStorageKey = "TurboDebugMediaRelayHost"
    static let hostEnvironmentKey = "TURBO_MEDIA_RELAY_HOST"
    static let quicPortStorageKey = "TurboDebugMediaRelayQuicPort"
    static let quicPortEnvironmentKey = "TURBO_MEDIA_RELAY_QUIC_PORT"
    static let tcpPortStorageKey = "TurboDebugMediaRelayTcpPort"
    static let tcpPortEnvironmentKey = "TURBO_MEDIA_RELAY_TCP_PORT"
    static let tokenStorageKey = "TurboDebugMediaRelayToken"
    static let tokenEnvironmentKey = "TURBO_MEDIA_RELAY_TOKEN"

    static func isEnabled(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let override = explicitBooleanValue(
            storageKey: enabledStorageKey,
            launchArgument: enabledLaunchArgument,
            environmentKey: enabledEnvironmentKey,
            processInfo: processInfo,
            defaults: defaults
        ) {
            return override
        }
        return true
    }

    static func isExplicitlyEnabled(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> Bool {
        booleanValue(
            storageKey: enabledStorageKey,
            launchArgument: enabledLaunchArgument,
            environmentKey: enabledEnvironmentKey,
            processInfo: processInfo,
            defaults: defaults
        )
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: enabledStorageKey)
    }

    static func isForced(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> Bool {
        booleanValue(
            storageKey: forceStorageKey,
            launchArgument: forceLaunchArgument,
            environmentKey: forceEnvironmentKey,
            processInfo: processInfo,
            defaults: defaults
        )
    }

    static func setForced(_ isForced: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isForced, forKey: forceStorageKey)
    }

    static func setConfig(
        host: String,
        quicPort: UInt16,
        tcpPort: UInt16,
        token: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(host, forKey: hostStorageKey)
        defaults.set(Int(quicPort), forKey: quicPortStorageKey)
        defaults.set(Int(tcpPort), forKey: tcpPortStorageKey)
        defaults.set(token, forKey: tokenStorageKey)
    }

    static func clearConfig(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hostStorageKey)
        defaults.removeObject(forKey: quicPortStorageKey)
        defaults.removeObject(forKey: tcpPortStorageKey)
        defaults.removeObject(forKey: tokenStorageKey)
    }

    static func config(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard
    ) -> TurboMediaRelayClientConfig? {
        let environment = processInfo.environment
        let host = environment[hostEnvironmentKey]
            ?? defaults.string(forKey: hostStorageKey)
            ?? "relay.beepbeep.to"
        let token = environment[tokenEnvironmentKey]
            ?? defaults.string(forKey: tokenStorageKey)
            ?? ""
        guard !host.isEmpty else { return nil }
        let quicPort = portValue(
            environmentValue: environment[quicPortEnvironmentKey],
            storedValue: defaults.object(forKey: quicPortStorageKey),
            fallback: 9443
        )
        let tcpPort = portValue(
            environmentValue: environment[tcpPortEnvironmentKey],
            storedValue: defaults.object(forKey: tcpPortStorageKey),
            fallback: 9444
        )
        return TurboMediaRelayClientConfig(
            host: host,
            quicPort: quicPort,
            tcpPort: tcpPort,
            token: token
        )
    }

    private static func booleanValue(
        storageKey: String,
        launchArgument: String,
        environmentKey: String,
        processInfo: ProcessInfo,
        defaults: UserDefaults
    ) -> Bool {
        explicitBooleanValue(
            storageKey: storageKey,
            launchArgument: launchArgument,
            environmentKey: environmentKey,
            processInfo: processInfo,
            defaults: defaults
        ) ?? false
    }

    private static func explicitBooleanValue(
        storageKey: String,
        launchArgument: String,
        environmentKey: String,
        processInfo: ProcessInfo,
        defaults: UserDefaults
    ) -> Bool? {
        let arguments = processInfo.arguments
        if let launchArgumentValue = launchArgumentValue(launchArgument, in: arguments),
           let parsed = parseBoolean(launchArgumentValue) {
            return parsed
        }
        if arguments.contains(launchArgument) {
            return true
        }
        if let environmentValue = processInfo.environment[environmentKey],
           let parsed = parseBoolean(environmentValue) {
            return parsed
        }
        guard defaults.object(forKey: storageKey) != nil else { return nil }
        return defaults.bool(forKey: storageKey)
    }

    private static func portValue(
        environmentValue: String?,
        storedValue: Any?,
        fallback: UInt16
    ) -> UInt16 {
        if let environmentValue,
           let parsed = UInt16(environmentValue) {
            return parsed
        }
        if let storedValue = storedValue as? Int,
           let parsed = UInt16(exactly: storedValue) {
            return parsed
        }
        return fallback
    }

    private static func launchArgumentValue(_ launchArgument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parseBoolean(_ rawValue: String) -> Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

enum DirectQuicTransmitStartupPolicy: String, Codable, Equatable, Hashable, Sendable {
    case appleGated = "apple-gated"
    case speculativeForeground = "speculative-foreground"
}

private extension KeyedDecodingContainer {
    func decodeIdentityField(
        publicIdKey: Key,
        legacyHandleKey: Key
    ) throws -> String {
        if let publicId = try decodeIfPresent(String.self, forKey: publicIdKey),
           !publicId.isEmpty {
            return publicId
        }
        return try decode(String.self, forKey: legacyHandleKey)
    }
}

enum TurboSignalKind: String, Codable {
    case offer = "offer"
    case answer = "answer"
    case iceCandidate = "ice-candidate"
    case hangup = "hangup"
    case transmitStart = "transmit-start"
    case transmitStop = "transmit-stop"
    case audioChunk = "audio-chunk"
    case receiverReady = "receiver-ready"
    case receiverNotReady = "receiver-not-ready"
    case directQuicUpgradeRequest = "direct-quic-upgrade-request"
    case selectedPeerPrewarm = "selected-peer-prewarm"

    var isDirectQuicControlSignal: Bool {
        switch self {
        case .offer, .answer, .iceCandidate, .hangup, .directQuicUpgradeRequest:
            return true
        case .transmitStart, .transmitStop, .audioChunk, .receiverReady, .receiverNotReady, .selectedPeerPrewarm:
            return false
        }
    }
}

nonisolated enum TurboDirectQuicRoleIntent: String, Codable, Equatable {
    case dialer
    case listener
    case symmetric
}

nonisolated enum TurboDirectQuicCandidateKind: String, Codable, Equatable {
    case host
    case serverReflexive = "srflx"
    case relay
}

nonisolated struct TurboDirectQuicCandidate: Codable, Equatable {
    let foundation: String
    let component: String
    let transport: String
    let priority: Int
    let kind: TurboDirectQuicCandidateKind
    let address: String
    let port: Int
    let relatedAddress: String?
    let relatedPort: Int?
}

protocol TurboDirectQuicSignalingPayload: Codable {
    nonisolated var protocolVersion: String { get }
}

extension TurboDirectQuicSignalingPayload {
    nonisolated static var expectedProtocolVersion: String { "quic-direct-v1" }

    nonisolated var usesExpectedProtocolVersion: Bool {
        protocolVersion == Self.expectedProtocolVersion
    }
}

nonisolated struct TurboDirectQuicOfferPayload: TurboDirectQuicSignalingPayload, Equatable {
    let protocolVersion: String
    let attemptId: String
    let channelId: String
    let fromDeviceId: String
    let toDeviceId: String
    let quicAlpn: String
    let certificateFingerprint: String
    let candidates: [TurboDirectQuicCandidate]
    let roleIntent: TurboDirectQuicRoleIntent?
    let debugBypass: Bool?

    init(
        protocolVersion: String = Self.expectedProtocolVersion,
        attemptId: String,
        channelId: String,
        fromDeviceId: String,
        toDeviceId: String,
        quicAlpn: String,
        certificateFingerprint: String,
        candidates: [TurboDirectQuicCandidate],
        roleIntent: TurboDirectQuicRoleIntent?,
        debugBypass: Bool? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.attemptId = attemptId
        self.channelId = channelId
        self.fromDeviceId = fromDeviceId
        self.toDeviceId = toDeviceId
        self.quicAlpn = quicAlpn
        self.certificateFingerprint = certificateFingerprint
        self.candidates = candidates
        self.roleIntent = roleIntent
        self.debugBypass = debugBypass
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case attemptId
        case channelId
        case fromDeviceId
        case toDeviceId
        case quicAlpn
        case certificateFingerprint
        case candidates
        case roleIntent
        case debugBypass
    }
}

nonisolated struct TurboDirectQuicAnswerPayload: TurboDirectQuicSignalingPayload, Equatable {
    let protocolVersion: String
    let attemptId: String
    let accepted: Bool
    let certificateFingerprint: String?
    let candidates: [TurboDirectQuicCandidate]
    let rejectionReason: String?

    init(
        protocolVersion: String = Self.expectedProtocolVersion,
        attemptId: String,
        accepted: Bool,
        certificateFingerprint: String? = nil,
        candidates: [TurboDirectQuicCandidate] = [],
        rejectionReason: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.attemptId = attemptId
        self.accepted = accepted
        self.certificateFingerprint = certificateFingerprint
        self.candidates = candidates
        self.rejectionReason = rejectionReason
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case attemptId
        case accepted
        case certificateFingerprint
        case candidates
        case rejectionReason
    }
}

nonisolated struct TurboDirectQuicCandidatePayload: TurboDirectQuicSignalingPayload, Equatable {
    let protocolVersion: String
    let attemptId: String
    let candidate: TurboDirectQuicCandidate?
    let endOfCandidates: Bool

    init(
        protocolVersion: String = Self.expectedProtocolVersion,
        attemptId: String,
        candidate: TurboDirectQuicCandidate?,
        endOfCandidates: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.attemptId = attemptId
        self.candidate = candidate
        self.endOfCandidates = endOfCandidates
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case attemptId
        case candidate
        case endOfCandidates
    }
}

nonisolated struct TurboDirectQuicHangupPayload: TurboDirectQuicSignalingPayload, Equatable {
    let protocolVersion: String
    let attemptId: String
    let reason: String

    init(
        protocolVersion: String = Self.expectedProtocolVersion,
        attemptId: String,
        reason: String
    ) {
        self.protocolVersion = protocolVersion
        self.attemptId = attemptId
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case attemptId
        case reason
    }
}

nonisolated struct TurboDirectQuicUpgradeRequestPayload: TurboDirectQuicSignalingPayload, Equatable {
    let protocolVersion: String
    let requestId: String
    let channelId: String
    let fromDeviceId: String
    let toDeviceId: String
    let reason: String
    let roleIntent: TurboDirectQuicRoleIntent?
    let debugBypass: Bool?

    init(
        protocolVersion: String = Self.expectedProtocolVersion,
        requestId: String,
        channelId: String,
        fromDeviceId: String,
        toDeviceId: String,
        reason: String,
        roleIntent: TurboDirectQuicRoleIntent? = .listener,
        debugBypass: Bool? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.channelId = channelId
        self.fromDeviceId = fromDeviceId
        self.toDeviceId = toDeviceId
        self.reason = reason
        self.roleIntent = roleIntent
        self.debugBypass = debugBypass
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case requestId
        case channelId
        case fromDeviceId
        case toDeviceId
        case reason
        case roleIntent
        case debugBypass
    }
}

nonisolated enum TurboJoinAcceptedControlSignal {
    static let reason = "join-accepted"

    static func matches(_ payload: TurboDirectQuicUpgradeRequestPayload) -> Bool {
        payload.reason == reason
    }
}

struct RecentOutgoingJoinAcceptedToken: Equatable {
    let inviteId: String
    let channelId: String
    let createdAt: Date

    func matches(
        _ payload: TurboDirectQuicUpgradeRequestPayload,
        now: Date = Date(),
        ttl: TimeInterval = 30
    ) -> Bool {
        inviteId == payload.requestId
            && channelId == payload.channelId
            && now.timeIntervalSince(createdAt) <= ttl
    }
}

struct RecentOutgoingRequestEvidence: Equatable {
    let channelId: String
    let requestCount: Int
    let observedAt: Date

    func matches(
        _ payload: TurboDirectQuicUpgradeRequestPayload,
        now: Date = Date(),
        ttl: TimeInterval = 30
    ) -> Bool {
        channelId == payload.channelId
            && now.timeIntervalSince(observedAt) <= ttl
    }
}

enum OptimisticOutgoingRequestPhase: Equatable {
    case cooldownOnly
    case joinTransition
}

struct OptimisticOutgoingRequestEvidence: Equatable {
    let requestCount: Int
    let startedAt: Date
    let cooldownDeadline: Date
    let operationID: String?
    let phase: OptimisticOutgoingRequestPhase

    func isActive(now: Date = Date()) -> Bool {
        now < cooldownDeadline
    }
}

struct RecentPeerDeviceEvidence: Equatable {
    let deviceId: String
    let channelId: String
    let reason: String
    let observedAt: Date

    func isFresh(
        for channelId: String?,
        now: Date = Date(),
        ttl: TimeInterval = 120
    ) -> Bool {
        !deviceId.isEmpty
            && (channelId == nil || self.channelId == channelId)
            && now.timeIntervalSince(observedAt) <= ttl
    }
}

nonisolated struct TurboSelectedPeerPrewarmPayload: Codable, Equatable {
    static let expectedProtocolVersion = "selected-peer-prewarm-v1"

    let protocolVersion: String
    let requestId: String
    let channelId: String
    let fromDeviceId: String
    let toDeviceId: String
    let reason: String

    init(
        protocolVersion: String = Self.expectedProtocolVersion,
        requestId: String,
        channelId: String,
        fromDeviceId: String,
        toDeviceId: String,
        reason: String
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.channelId = channelId
        self.fromDeviceId = fromDeviceId
        self.toDeviceId = toDeviceId
        self.reason = reason
    }

    var usesExpectedProtocolVersion: Bool {
        protocolVersion == Self.expectedProtocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case requestId
        case channelId
        case fromDeviceId
        case toDeviceId
        case reason
    }
}

enum TurboDirectQuicSignalPayload: Equatable {
    case offer(TurboDirectQuicOfferPayload)
    case answer(TurboDirectQuicAnswerPayload)
    case candidate(TurboDirectQuicCandidatePayload)
    case hangup(TurboDirectQuicHangupPayload)

    var attemptId: String {
        switch self {
        case .offer(let payload):
            return payload.attemptId
        case .answer(let payload):
            return payload.attemptId
        case .candidate(let payload):
            return payload.attemptId
        case .hangup(let payload):
            return payload.attemptId
        }
    }
}

enum TurboDirectQuicPayloadError: Error, LocalizedError, Equatable {
    case wrongSignalKind(expected: TurboSignalKind, actual: TurboSignalKind)
    case notDirectQuicSignal(TurboSignalKind)
    case unsupportedProtocolVersion(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .wrongSignalKind(let expected, let actual):
            return "Expected \(expected.rawValue) direct QUIC signal but received \(actual.rawValue)"
        case .notDirectQuicSignal(let signalKind):
            return "\(signalKind.rawValue) is not a direct QUIC signaling message"
        case .unsupportedProtocolVersion(let version):
            return "Unsupported direct QUIC protocol version \(version)"
        case .invalidJSON(let message):
            return "Invalid direct QUIC payload JSON: \(message)"
        }
    }
}

enum TurboSelectedPeerPrewarmPayloadError: Error, LocalizedError, Equatable {
    case wrongSignalKind(expected: TurboSignalKind, actual: TurboSignalKind)
    case unsupportedProtocolVersion(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .wrongSignalKind(let expected, let actual):
            return "Expected \(expected.rawValue) selected peer prewarm signal but received \(actual.rawValue)"
        case .unsupportedProtocolVersion(let version):
            return "Unsupported selected peer prewarm protocol version \(version)"
        case .invalidJSON(let message):
            return "Invalid selected peer prewarm payload JSON: \(message)"
        }
    }
}

enum TurboPTTPushEvent: String, Codable, Equatable {
    case transmitStart = "transmit-start"
    case leaveChannel = "leave-channel"
}

struct TurboPTTPushPayload: Equatable {
    let event: TurboPTTPushEvent
    let channelId: String?
    let activeSpeaker: String?
    let activeSpeakerDisplayName: String?
    let senderUserId: String?
    let senderDeviceId: String?

    var participantName: String {
        activeSpeakerDisplayName ?? activeSpeaker ?? "Remote"
    }

    var notificationTitle: String {
        switch event {
        case .transmitStart:
            return "\(participantName) wants to talk"
        case .leaveChannel:
            return participantName
        }
    }

    init(
        event: TurboPTTPushEvent,
        channelId: String?,
        activeSpeaker: String?,
        activeSpeakerDisplayName: String? = nil,
        senderUserId: String?,
        senderDeviceId: String?
    ) {
        self.event = event
        self.channelId = channelId
        self.activeSpeaker = activeSpeaker
        self.activeSpeakerDisplayName = activeSpeakerDisplayName
        self.senderUserId = senderUserId
        self.senderDeviceId = senderDeviceId
    }

    init?(pushPayload: [String: Any]) {
        let eventText =
            (pushPayload["event"] as? String)
            ?? (pushPayload["type"] as? String)
        guard let eventText,
              let event = TurboPTTPushEvent(rawValue: eventText) else {
            return nil
        }

        self.init(
            event: event,
            channelId: pushPayload["channelId"] as? String,
            activeSpeaker: pushPayload["activeSpeaker"] as? String,
            activeSpeakerDisplayName: pushPayload["activeSpeakerDisplayName"] as? String,
            senderUserId: pushPayload["senderUserId"] as? String,
            senderDeviceId: pushPayload["senderDeviceId"] as? String
        )
    }
}

nonisolated struct TurboSignalEnvelope: Codable, Equatable {
    let type: TurboSignalKind
    let channelId: String
    let fromUserId: String
    let fromDeviceId: String
    let toUserId: String
    let toDeviceId: String
    let sessionId: String?
    let payload: String

    init(
        type: TurboSignalKind,
        channelId: String,
        fromUserId: String,
        fromDeviceId: String,
        toUserId: String,
        toDeviceId: String,
        sessionId: String? = nil,
        payload: String
    ) {
        self.type = type
        self.channelId = channelId
        self.fromUserId = fromUserId
        self.fromDeviceId = fromDeviceId
        self.toUserId = toUserId
        self.toDeviceId = toDeviceId
        self.sessionId = sessionId
        self.payload = payload
    }

    func withSessionId(_ sessionId: String?) -> TurboSignalEnvelope {
        TurboSignalEnvelope(
            type: type,
            channelId: channelId,
            fromUserId: fromUserId,
            fromDeviceId: fromDeviceId,
            toUserId: toUserId,
            toDeviceId: toDeviceId,
            sessionId: sessionId,
            payload: payload
        )
    }

    static func directQuicOffer(
        channelId: String,
        fromUserId: String,
        fromDeviceId: String,
        toUserId: String,
        toDeviceId: String,
        payload: TurboDirectQuicOfferPayload
    ) throws -> TurboSignalEnvelope {
        try makeDirectQuicEnvelope(
            type: .offer,
            channelId: channelId,
            fromUserId: fromUserId,
            fromDeviceId: fromDeviceId,
            toUserId: toUserId,
            toDeviceId: toDeviceId,
            payload: payload
        )
    }

    static func directQuicAnswer(
        channelId: String,
        fromUserId: String,
        fromDeviceId: String,
        toUserId: String,
        toDeviceId: String,
        payload: TurboDirectQuicAnswerPayload
    ) throws -> TurboSignalEnvelope {
        try makeDirectQuicEnvelope(
            type: .answer,
            channelId: channelId,
            fromUserId: fromUserId,
            fromDeviceId: fromDeviceId,
            toUserId: toUserId,
            toDeviceId: toDeviceId,
            payload: payload
        )
    }

    static func directQuicCandidate(
        channelId: String,
        fromUserId: String,
        fromDeviceId: String,
        toUserId: String,
        toDeviceId: String,
        payload: TurboDirectQuicCandidatePayload
    ) throws -> TurboSignalEnvelope {
        try makeDirectQuicEnvelope(
            type: .iceCandidate,
            channelId: channelId,
            fromUserId: fromUserId,
            fromDeviceId: fromDeviceId,
            toUserId: toUserId,
            toDeviceId: toDeviceId,
            payload: payload
        )
    }

    static func directQuicHangup(
        channelId: String,
        fromUserId: String,
        fromDeviceId: String,
        toUserId: String,
        toDeviceId: String,
        payload: TurboDirectQuicHangupPayload
    ) throws -> TurboSignalEnvelope {
        try makeDirectQuicEnvelope(
            type: .hangup,
            channelId: channelId,
            fromUserId: fromUserId,
            fromDeviceId: fromDeviceId,
            toUserId: toUserId,
            toDeviceId: toDeviceId,
            payload: payload
        )
    }

    static func directQuicUpgradeRequest(
        channelId: String,
        fromUserId: String,
        fromDeviceId: String,
        toUserId: String,
        toDeviceId: String,
        payload: TurboDirectQuicUpgradeRequestPayload
    ) throws -> TurboSignalEnvelope {
        try makeDirectQuicEnvelope(
            type: .directQuicUpgradeRequest,
            channelId: channelId,
            fromUserId: fromUserId,
            fromDeviceId: fromDeviceId,
            toUserId: toUserId,
            toDeviceId: toDeviceId,
            payload: payload
        )
    }

    static func selectedPeerPrewarm(
        channelId: String,
        fromUserId: String,
        fromDeviceId: String,
        toUserId: String,
        toDeviceId: String,
        payload: TurboSelectedPeerPrewarmPayload
    ) throws -> TurboSignalEnvelope {
        let encodedPayload = try encodeSelectedPeerPrewarmPayload(payload)
        return TurboSignalEnvelope(
            type: .selectedPeerPrewarm,
            channelId: channelId,
            fromUserId: fromUserId,
            fromDeviceId: fromDeviceId,
            toUserId: toUserId,
            toDeviceId: toDeviceId,
            payload: encodedPayload
        )
    }

    func decodeDirectQuicSignalPayload() throws -> TurboDirectQuicSignalPayload {
        switch type {
        case .offer:
            return .offer(try decodeDirectQuicPayload(TurboDirectQuicOfferPayload.self, expectedKind: .offer))
        case .answer:
            return .answer(try decodeDirectQuicPayload(TurboDirectQuicAnswerPayload.self, expectedKind: .answer))
        case .iceCandidate:
            return .candidate(try decodeDirectQuicPayload(TurboDirectQuicCandidatePayload.self, expectedKind: .iceCandidate))
        case .hangup:
            return .hangup(try decodeDirectQuicPayload(TurboDirectQuicHangupPayload.self, expectedKind: .hangup))
        case .transmitStart, .transmitStop, .audioChunk, .receiverReady, .receiverNotReady, .directQuicUpgradeRequest, .selectedPeerPrewarm:
            throw TurboDirectQuicPayloadError.notDirectQuicSignal(type)
        }
    }

    func decodeDirectQuicUpgradeRequestPayload() throws -> TurboDirectQuicUpgradeRequestPayload {
        try decodeDirectQuicPayload(
            TurboDirectQuicUpgradeRequestPayload.self,
            expectedKind: .directQuicUpgradeRequest
        )
    }

    func decodeSelectedPeerPrewarmPayload() throws -> TurboSelectedPeerPrewarmPayload {
        guard type == .selectedPeerPrewarm else {
            throw TurboSelectedPeerPrewarmPayloadError.wrongSignalKind(
                expected: .selectedPeerPrewarm,
                actual: type
            )
        }
        let data = Data(payload.utf8)
        let decodedPayload: TurboSelectedPeerPrewarmPayload
        do {
            decodedPayload = try JSONDecoder().decode(TurboSelectedPeerPrewarmPayload.self, from: data)
        } catch {
            throw TurboSelectedPeerPrewarmPayloadError.invalidJSON(error.localizedDescription)
        }
        guard decodedPayload.usesExpectedProtocolVersion else {
            throw TurboSelectedPeerPrewarmPayloadError.unsupportedProtocolVersion(decodedPayload.protocolVersion)
        }
        return decodedPayload
    }

    private static func makeDirectQuicEnvelope<Payload: TurboDirectQuicSignalingPayload>(
        type: TurboSignalKind,
        channelId: String,
        fromUserId: String,
        fromDeviceId: String,
        toUserId: String,
        toDeviceId: String,
        payload: Payload
    ) throws -> TurboSignalEnvelope {
        let encodedPayload = try encodeDirectQuicPayload(payload)
        return TurboSignalEnvelope(
            type: type,
            channelId: channelId,
            fromUserId: fromUserId,
            fromDeviceId: fromDeviceId,
            toUserId: toUserId,
            toDeviceId: toDeviceId,
            payload: encodedPayload
        )
    }

    private static func encodeDirectQuicPayload<Payload: TurboDirectQuicSignalingPayload>(
        _ payload: Payload
    ) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TurboDirectQuicPayloadError.invalidJSON("encoded payload was not UTF-8")
        }
        return json
    }

    private static func encodeSelectedPeerPrewarmPayload(
        _ payload: TurboSelectedPeerPrewarmPayload
    ) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TurboSelectedPeerPrewarmPayloadError.invalidJSON("encoded payload was not UTF-8")
        }
        return json
    }


    private func decodeDirectQuicPayload<Payload: TurboDirectQuicSignalingPayload>(
        _ payloadType: Payload.Type,
        expectedKind: TurboSignalKind
    ) throws -> Payload {
        guard type == expectedKind else {
            throw TurboDirectQuicPayloadError.wrongSignalKind(expected: expectedKind, actual: type)
        }
        let data = Data(payload.utf8)
        let decodedPayload: Payload
        do {
            decodedPayload = try JSONDecoder().decode(payloadType, from: data)
        } catch {
            throw TurboDirectQuicPayloadError.invalidJSON(error.localizedDescription)
        }
        guard decodedPayload.usesExpectedProtocolVersion else {
            throw TurboDirectQuicPayloadError.unsupportedProtocolVersion(decodedPayload.protocolVersion)
        }
        return decodedPayload
    }
}

struct TurboAuthSessionResponse: Decodable {
    let userId: String
    let handle: String
    let publicId: String
    let displayName: String
    let profileName: String
    let shareCode: String
    let shareLink: String
    let did: String
    let subjectKind: String

    init(
        userId: String,
        handle: String,
        publicId: String? = nil,
        displayName: String,
        profileName: String? = nil,
        shareCode: String? = nil,
        shareLink: String? = nil,
        did: String? = nil,
        subjectKind: String = "human"
    ) {
        self.userId = userId
        self.handle = handle
        self.publicId = publicId ?? handle
        self.displayName = displayName
        self.profileName = profileName ?? displayName
        self.shareCode = shareCode ?? self.publicId
        self.shareLink = shareLink ?? "https://beepbeep.to/\(TurboHandle.sharePathComponent(from: self.shareCode))"
        self.did = did ?? "did:web:beepbeep.to:id:\(self.publicId)"
        self.subjectKind = subjectKind
    }

    private enum CodingKeys: String, CodingKey {
        case userId
        case handle
        case publicId
        case displayName
        case profileName
        case shareCode
        case shareLink
        case did
        case subjectKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        handle = try container.decode(String.self, forKey: .handle)
        publicId = try container.decodeIdentityField(publicIdKey: .publicId, legacyHandleKey: .handle)
        displayName = try container.decode(String.self, forKey: .displayName)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? displayName
        shareCode = try container.decodeIfPresent(String.self, forKey: .shareCode) ?? publicId
        shareLink = try container.decodeIfPresent(String.self, forKey: .shareLink) ?? "https://beepbeep.to/\(TurboHandle.sharePathComponent(from: shareCode))"
        did = try container.decodeIfPresent(String.self, forKey: .did) ?? "did:web:beepbeep.to:id:\(publicId)"
        subjectKind = try container.decodeIfPresent(String.self, forKey: .subjectKind) ?? "human"
    }
}

struct TurboProfileUpdateRequest: Encodable {
    let profileName: String
}

struct TurboRememberContactResponse: Decodable {
    let status: String
    let otherUserId: String
}

struct TurboForgetContactResponse: Decodable {
    let status: String
    let otherUserId: String
}

struct TurboBackendRuntimeConfig: Decodable {
    let mode: String
    let supportsWebSocket: Bool
    let telemetryEnabled: Bool?
    let supportsDirectQuicUpgrade: Bool
    let supportsDirectQuicProvisioning: Bool
    let supportsMediaEndToEndEncryption: Bool
    let supportsSignalSessionIds: Bool
    let supportsTransmitIds: Bool
    let supportsProjectionEpochs: Bool
    let directQuicPolicy: TurboDirectQuicPolicy?

    init(
        mode: String,
        supportsWebSocket: Bool,
        telemetryEnabled: Bool? = nil,
        supportsDirectQuicUpgrade: Bool = false,
        supportsDirectQuicProvisioning: Bool = false,
        supportsMediaEndToEndEncryption: Bool = false,
        supportsSignalSessionIds: Bool = false,
        supportsTransmitIds: Bool = false,
        supportsProjectionEpochs: Bool = false,
        directQuicPolicy: TurboDirectQuicPolicy? = nil
    ) {
        self.mode = mode
        self.supportsWebSocket = supportsWebSocket
        self.telemetryEnabled = telemetryEnabled
        self.supportsDirectQuicUpgrade = supportsDirectQuicUpgrade
        self.supportsDirectQuicProvisioning = supportsDirectQuicProvisioning
        self.supportsMediaEndToEndEncryption = supportsMediaEndToEndEncryption
        self.supportsSignalSessionIds = supportsSignalSessionIds
        self.supportsTransmitIds = supportsTransmitIds
        self.supportsProjectionEpochs = supportsProjectionEpochs
        self.directQuicPolicy = directQuicPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case supportsWebSocket
        case telemetryEnabled
        case supportsDirectQuicUpgrade
        case supportsDirectQuicProvisioning
        case supportsMediaEndToEndEncryption
        case supportsSignalSessionIds
        case supportsTransmitIds
        case supportsProjectionEpochs
        case directQuicPolicy
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        supportsWebSocket = try container.decode(Bool.self, forKey: .supportsWebSocket)
        telemetryEnabled = try container.decodeIfPresent(Bool.self, forKey: .telemetryEnabled)
        supportsDirectQuicUpgrade = try container.decodeIfPresent(Bool.self, forKey: .supportsDirectQuicUpgrade) ?? false
        supportsDirectQuicProvisioning = try container.decodeIfPresent(Bool.self, forKey: .supportsDirectQuicProvisioning) ?? false
        supportsMediaEndToEndEncryption = try container.decodeIfPresent(Bool.self, forKey: .supportsMediaEndToEndEncryption) ?? false
        supportsSignalSessionIds = try container.decodeIfPresent(Bool.self, forKey: .supportsSignalSessionIds) ?? false
        supportsTransmitIds = try container.decodeIfPresent(Bool.self, forKey: .supportsTransmitIds) ?? false
        supportsProjectionEpochs = try container.decodeIfPresent(Bool.self, forKey: .supportsProjectionEpochs) ?? false
        directQuicPolicy = try container.decodeIfPresent(TurboDirectQuicPolicy.self, forKey: .directQuicPolicy)
    }
}

struct TurboDirectQuicPolicy: Decodable, Equatable {
    let stunServers: [TurboDirectQuicStunServer]?
    let stunProviders: [TurboDirectQuicStunProvider]?
    let turnEnabled: Bool?
    let turnProvider: String?
    let turnPolicyPath: String?
    let turnCredentialTtlSeconds: Int?
    let transportExperimentBucket: String?
    let promotionTimeoutMs: Int?
    let retryBackoffMs: Int?

    init(
        stunServers: [TurboDirectQuicStunServer]? = nil,
        stunProviders: [TurboDirectQuicStunProvider]? = nil,
        turnEnabled: Bool? = nil,
        turnProvider: String? = nil,
        turnPolicyPath: String? = nil,
        turnCredentialTtlSeconds: Int? = nil,
        transportExperimentBucket: String? = nil,
        promotionTimeoutMs: Int? = nil,
        retryBackoffMs: Int? = nil
    ) {
        self.stunServers = stunServers
        self.stunProviders = stunProviders
        self.turnEnabled = turnEnabled
        self.turnProvider = turnProvider
        self.turnPolicyPath = turnPolicyPath
        self.turnCredentialTtlSeconds = turnCredentialTtlSeconds
        self.transportExperimentBucket = transportExperimentBucket
        self.promotionTimeoutMs = promotionTimeoutMs
        self.retryBackoffMs = retryBackoffMs
    }

    var effectiveStunServers: [TurboDirectQuicStunServer] {
        let providerServers = (stunProviders ?? [])
            .filter { $0.enabled != false }
            .flatMap(\.servers)
        if !providerServers.isEmpty {
            return providerServers
        }
        return stunServers ?? []
    }

    var enabledStunProviderNames: [String] {
        (stunProviders ?? [])
            .filter { $0.enabled != false && !$0.servers.isEmpty }
            .map(\.name)
    }
}

nonisolated struct TurboDirectQuicStunProvider: Decodable, Equatable {
    let name: String
    let enabled: Bool?
    let servers: [TurboDirectQuicStunServer]
}

nonisolated struct TurboDirectQuicStunServer: Decodable, Equatable {
    let host: String
    let port: Int?
}

struct TurboDirectQuicIceServerPolicy: Decodable, Equatable {
    let iceServers: [TurboDirectQuicIceServer]
}

struct TurboDirectQuicIceServer: Decodable, Equatable {
    let urls: [String]
    let username: String?
    let credential: String?

    private enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
    }

    init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let urls = try? container.decode([String].self, forKey: .urls) {
            self.urls = urls
        } else {
            self.urls = [try container.decode(String.self, forKey: .urls)]
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
    }
}

struct TurboSeedResponse: Decodable {
    let status: String
    let users: [TurboUserLookupResponse]
}

struct TurboWebSocketStatusNotice: Decodable {
    let status: String
    let deviceId: String?
    let sessionId: String?
    let channelId: String?
    let fromUserId: String?
    let fromDeviceId: String?
    let reason: String?
    let leftAt: String?
}

struct TurboDiagnosticsUploadRequest: Encodable {
    let deviceId: String
    let appVersion: String
    let backendBaseURL: String
    let selectedHandle: String?
    let snapshot: String
    let transcript: String
}

struct TurboPublishedDiagnosticsReport: Decodable {
    let userId: String
    let deviceId: String
    let appVersion: String
    let backendBaseURL: String
    let selectedHandle: String?
    let snapshot: String
    let transcript: String
    let uploadedAt: String
}

struct TurboDiagnosticsUploadResponse: Decodable {
    let status: String
    let report: TurboPublishedDiagnosticsReport
}

struct TurboLatestDiagnosticsResponse: Decodable {
    let status: String
    let report: TurboPublishedDiagnosticsReport
}

struct TurboTelemetryUploadResponse: Decodable {
    let status: String
    let delivered: Bool?
}

struct TurboResetStateResponse: Decodable {
    let status: String
    let clearedTransmitStates: Int
    let clearedPresenceEntries: Int
    let clearedTokenEntries: Int
    let clearedInvites: Int
    let clearedSessions: Int?
    let clearedSockets: Int?
    let clearedChannels: Int?
    let clearedDevices: Int?
    let clearedUsers: Int?
}

struct TurboUserLookupResponse: Decodable {
    let userId: String
    let handle: String
    let publicId: String
    let displayName: String
    let profileName: String
    let shareCode: String
    let shareLink: String
    let did: String
    let subjectKind: String

    init(
        userId: String,
        handle: String,
        publicId: String? = nil,
        displayName: String,
        profileName: String? = nil,
        shareCode: String? = nil,
        shareLink: String? = nil,
        did: String? = nil,
        subjectKind: String = "human"
    ) {
        self.userId = userId
        self.handle = handle
        self.publicId = publicId ?? handle
        self.displayName = displayName
        self.profileName = profileName ?? displayName
        self.shareCode = shareCode ?? self.publicId
        self.shareLink = shareLink ?? "https://beepbeep.to/\(TurboHandle.sharePathComponent(from: self.shareCode))"
        self.did = did ?? "did:web:beepbeep.to:id:\(self.publicId)"
        self.subjectKind = subjectKind
    }

    private enum CodingKeys: String, CodingKey {
        case userId
        case handle
        case publicId
        case displayName
        case profileName
        case shareCode
        case shareLink
        case did
        case subjectKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        handle = try container.decode(String.self, forKey: .handle)
        publicId = try container.decodeIdentityField(publicIdKey: .publicId, legacyHandleKey: .handle)
        displayName = try container.decode(String.self, forKey: .displayName)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? displayName
        shareCode = try container.decodeIfPresent(String.self, forKey: .shareCode) ?? publicId
        shareLink = try container.decodeIfPresent(String.self, forKey: .shareLink) ?? "https://beepbeep.to/\(TurboHandle.sharePathComponent(from: shareCode))"
        did = try container.decodeIfPresent(String.self, forKey: .did) ?? "did:web:beepbeep.to:id:\(publicId)"
        subjectKind = try container.decodeIfPresent(String.self, forKey: .subjectKind) ?? "human"
    }
}

struct TurboDeviceRegistrationResponse: Decodable {
    let deviceId: String
    let userId: String
    let platform: String
    let deviceLabel: String?
    let lastSeenAt: String
}

struct TurboDirectChannelResponse: Decodable {
    let channelId: String
    let lowUserId: String
    let highUserId: String
    let createdAt: String
}

struct TurboPresenceHeartbeatResponse: Decodable {
    let deviceId: String
    let userId: String
    let status: String
}

struct TurboUserPresenceResponse: Decodable {
    let userId: String
    let handle: String
    let publicId: String
    let displayName: String
    let profileName: String
    let shareCode: String
    let shareLink: String
    let did: String
    let subjectKind: String
    let isOnline: Bool

    init(
        userId: String,
        handle: String,
        publicId: String? = nil,
        displayName: String,
        profileName: String? = nil,
        shareCode: String? = nil,
        shareLink: String? = nil,
        did: String? = nil,
        subjectKind: String = "human",
        isOnline: Bool
    ) {
        self.userId = userId
        self.handle = handle
        self.publicId = publicId ?? handle
        self.displayName = displayName
        self.profileName = profileName ?? displayName
        self.shareCode = shareCode ?? self.publicId
        self.shareLink = shareLink ?? "https://beepbeep.to/\(TurboHandle.sharePathComponent(from: self.shareCode))"
        self.did = did ?? "did:web:beepbeep.to:id:\(self.publicId)"
        self.subjectKind = subjectKind
        self.isOnline = isOnline
    }

    private enum CodingKeys: String, CodingKey {
        case userId
        case handle
        case publicId
        case displayName
        case profileName
        case shareCode
        case shareLink
        case did
        case subjectKind
        case isOnline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        handle = try container.decode(String.self, forKey: .handle)
        publicId = try container.decodeIdentityField(publicIdKey: .publicId, legacyHandleKey: .handle)
        displayName = try container.decode(String.self, forKey: .displayName)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? displayName
        shareCode = try container.decodeIfPresent(String.self, forKey: .shareCode) ?? publicId
        shareLink = try container.decodeIfPresent(String.self, forKey: .shareLink) ?? "https://beepbeep.to/\(TurboHandle.sharePathComponent(from: shareCode))"
        did = try container.decodeIfPresent(String.self, forKey: .did) ?? "did:web:beepbeep.to:id:\(publicId)"
        subjectKind = try container.decodeIfPresent(String.self, forKey: .subjectKind) ?? "human"
        isOnline = try container.decode(Bool.self, forKey: .isOnline)
    }
}

struct TurboJoinResponse: Decodable {
    let channelId: String
    let userId: String
    let deviceId: String
    let status: String
}

struct TurboLeaveResponse: Decodable {
    let channelId: String
    let deviceId: String
    let status: String
}

struct TurboContactSummaryResponse: Decodable, Equatable {
    let userId: String
    let handle: String
    let publicId: String
    let displayName: String
    let profileName: String
    let channelId: String?
    let isOnline: Bool
    let isActiveConversation: Bool
    private let requestRelationshipPayload: TurboRequestRelationshipPayload
    private let membershipPayload: TurboChannelMembershipPayload
    private let summaryStatusPayload: TurboSummaryStatusPayload

    init(
        userId: String,
        handle: String,
        publicId: String? = nil,
        displayName: String,
        profileName: String? = nil,
        channelId: String?,
        isOnline: Bool,
        hasIncomingRequest: Bool,
        hasOutgoingRequest: Bool,
        requestCount: Int,
        isActiveConversation: Bool,
        badgeStatus: String,
        requestRelationshipPayload: TurboRequestRelationshipPayload? = nil,
        membershipPayload: TurboChannelMembershipPayload? = nil,
        summaryStatusPayload: TurboSummaryStatusPayload? = nil
    ) {
        self.userId = userId
        self.handle = handle
        self.publicId = publicId ?? handle
        self.displayName = displayName
        self.profileName = profileName ?? displayName
        self.channelId = channelId
        self.isOnline = isOnline
        self.isActiveConversation = isActiveConversation
        self.requestRelationshipPayload = requestRelationshipPayload ?? Self.synthesizedRequestRelationshipPayload(
            hasIncomingRequest: hasIncomingRequest,
            hasOutgoingRequest: hasOutgoingRequest,
            requestCount: requestCount
        )
        self.membershipPayload = membershipPayload ?? Self.synthesizedMembershipPayload(
            channelId: channelId,
            isOnline: isOnline
        )
        self.summaryStatusPayload = summaryStatusPayload ?? TurboSummaryStatusPayload(
            kind: badgeStatus,
            activeTransmitterUserId: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case userId
        case handle
        case publicId
        case displayName
        case profileName
        case channelId
        case isOnline
        case hasIncomingRequest
        case hasOutgoingRequest
        case requestCount
        case isActiveConversation
        case badgeStatus
        case requestRelationship
        case membership
        case summaryStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        handle = try container.decode(String.self, forKey: .handle)
        publicId = try container.decodeIdentityField(publicIdKey: .publicId, legacyHandleKey: .handle)
        displayName = try container.decode(String.self, forKey: .displayName)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? displayName
        channelId = try container.decodeIfPresent(String.self, forKey: .channelId)
        isOnline = try container.decode(Bool.self, forKey: .isOnline)
        isActiveConversation = try container.decode(Bool.self, forKey: .isActiveConversation)
        requestRelationshipPayload = try container.decode(
            TurboRequestRelationshipPayload.self,
            forKey: .requestRelationship
        )
        membershipPayload = try container.decode(
            TurboChannelMembershipPayload.self,
            forKey: .membership
        )
        summaryStatusPayload = try container.decode(
            TurboSummaryStatusPayload.self,
            forKey: .summaryStatus
        )
    }

    private static func synthesizedRequestRelationshipPayload(
        hasIncomingRequest: Bool,
        hasOutgoingRequest: Bool,
        requestCount: Int
    ) -> TurboRequestRelationshipPayload {
        let normalizedRequestCount = max(requestCount, 1)
        let kind: String
        switch (hasIncomingRequest, hasOutgoingRequest) {
        case (true, true):
            kind = "mutual"
        case (true, false):
            kind = "incoming"
        case (false, true):
            kind = "outgoing"
        case (false, false):
            kind = "none"
        }
        return TurboRequestRelationshipPayload(
            kind: kind,
            requestCount: kind == "none" ? nil : normalizedRequestCount
        )
    }

    private static func synthesizedMembershipPayload(
        channelId: String?,
        isOnline: Bool
    ) -> TurboChannelMembershipPayload {
        if channelId == nil {
            return TurboChannelMembershipPayload(kind: "absent", peerDeviceConnected: nil)
        }
        return TurboChannelMembershipPayload(kind: "peer-only", peerDeviceConnected: isOnline)
    }

    var membership: TurboChannelMembership {
        membershipPayload.membership
    }

    var requestRelationship: TurboRequestRelationship {
        requestRelationshipPayload.relationship
    }

    var hasIncomingRequest: Bool {
        requestRelationship.hasIncomingRequest
    }

    var hasOutgoingRequest: Bool {
        requestRelationship.hasOutgoingRequest
    }

    var requestCount: Int {
        requestRelationship.requestCount ?? 0
    }

    var badge: TurboSummaryBadgeStatus {
        summaryStatusPayload.status
    }

    var badgeStatus: String {
        badge.kind
    }

    var badgeKind: String {
        badge.kind
    }
}

struct TurboInviteResponse: Decodable, Hashable, Identifiable {
    let inviteId: String
    let fromUserId: String
    let fromHandle: String?
    let toUserId: String
    let toHandle: String?
    let channelId: String
    let status: String
    let direction: String
    let requestCount: Int
    let createdAt: String
    let updatedAt: String?
    let userIntent: String?
    let targetAvailability: String?
    let shouldAutoJoinPeer: Bool?
    let accepted: Bool?
    let pendingJoin: Bool?

    var id: String { inviteId }
}

struct TurboChannelStateResponse: Decodable, Equatable {
    let channelId: String
    let selfUserId: String
    let peerUserId: String
    let peerHandle: String
    let selfOnline: Bool
    let peerOnline: Bool
    let stateEpoch: String?
    let serverTimestamp: String?
    let activeTransmitId: String?
    let transmitLeaseExpiresAt: String?
    let canTransmit: Bool
    private let membershipPayload: TurboChannelMembershipPayload
    private let requestRelationshipPayload: TurboRequestRelationshipPayload
    private let conversationStatusPayload: TurboConversationStatusPayload

    init(
        channelId: String,
        selfUserId: String,
        peerUserId: String,
        peerHandle: String,
        selfOnline: Bool,
        peerOnline: Bool,
        selfJoined: Bool,
        peerJoined: Bool,
        peerDeviceConnected: Bool,
        hasIncomingRequest: Bool,
        hasOutgoingRequest: Bool,
        requestCount: Int,
        activeTransmitterUserId: String?,
        activeTransmitId: String? = nil,
        transmitLeaseExpiresAt: String?,
        stateEpoch: String? = nil,
        serverTimestamp: String? = nil,
        status: String,
        canTransmit: Bool,
        membershipPayload: TurboChannelMembershipPayload? = nil,
        requestRelationshipPayload: TurboRequestRelationshipPayload? = nil,
        conversationStatusPayload: TurboConversationStatusPayload? = nil
    ) {
        self.channelId = channelId
        self.selfUserId = selfUserId
        self.peerUserId = peerUserId
        self.peerHandle = peerHandle
        self.selfOnline = selfOnline
        self.peerOnline = peerOnline
        self.stateEpoch = stateEpoch
        self.serverTimestamp = serverTimestamp
        self.activeTransmitId = activeTransmitId
        self.transmitLeaseExpiresAt = transmitLeaseExpiresAt
        self.canTransmit = canTransmit
        self.membershipPayload = membershipPayload ?? Self.synthesizedMembershipPayload(
            selfJoined: selfJoined,
            peerJoined: peerJoined,
            peerDeviceConnected: peerDeviceConnected
        )
        self.requestRelationshipPayload = requestRelationshipPayload ?? Self.synthesizedRequestRelationshipPayload(
            hasIncomingRequest: hasIncomingRequest,
            hasOutgoingRequest: hasOutgoingRequest,
            requestCount: requestCount
        )
        self.conversationStatusPayload = conversationStatusPayload ?? TurboConversationStatusPayload(
            kind: status,
            activeTransmitterUserId: activeTransmitterUserId
        )
    }

    private enum CodingKeys: String, CodingKey {
        case channelId
        case selfUserId
        case peerUserId
        case peerHandle
        case selfOnline
        case peerOnline
        case stateEpoch
        case serverTimestamp
        case activeTransmitId
        case selfJoined
        case peerJoined
        case peerDeviceConnected
        case hasIncomingRequest
        case hasOutgoingRequest
        case requestCount
        case activeTransmitterUserId
        case transmitLeaseExpiresAt
        case status
        case canTransmit
        case membership
        case requestRelationship
        case conversationStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try container.decode(String.self, forKey: .channelId)
        selfUserId = try container.decode(String.self, forKey: .selfUserId)
        peerUserId = try container.decode(String.self, forKey: .peerUserId)
        peerHandle = try container.decode(String.self, forKey: .peerHandle)
        selfOnline = try container.decode(Bool.self, forKey: .selfOnline)
        peerOnline = try container.decode(Bool.self, forKey: .peerOnline)
        stateEpoch = try container.decodeIfPresent(String.self, forKey: .stateEpoch)
        serverTimestamp = try container.decodeIfPresent(String.self, forKey: .serverTimestamp)
        activeTransmitId = try container.decodeIfPresent(String.self, forKey: .activeTransmitId)
        transmitLeaseExpiresAt = try container.decodeIfPresent(String.self, forKey: .transmitLeaseExpiresAt)
        canTransmit = try container.decode(Bool.self, forKey: .canTransmit)
        membershipPayload = try container.decode(TurboChannelMembershipPayload.self, forKey: .membership)
        requestRelationshipPayload = try container.decode(
            TurboRequestRelationshipPayload.self,
            forKey: .requestRelationship
        )
        conversationStatusPayload = try container.decode(
            TurboConversationStatusPayload.self,
            forKey: .conversationStatus
        )
    }

    private static func synthesizedMembershipPayload(
        selfJoined: Bool,
        peerJoined: Bool,
        peerDeviceConnected: Bool
    ) -> TurboChannelMembershipPayload {
        let kind: String
        let peerConnectivity: Bool?
        switch (selfJoined, peerJoined) {
        case (false, false):
            kind = "absent"
            peerConnectivity = nil
        case (false, true):
            kind = "peer-only"
            peerConnectivity = peerDeviceConnected
        case (true, false):
            kind = "self-only"
            peerConnectivity = nil
        case (true, true):
            kind = "both"
            peerConnectivity = peerDeviceConnected
        }
        return TurboChannelMembershipPayload(kind: kind, peerDeviceConnected: peerConnectivity)
    }

    private static func synthesizedRequestRelationshipPayload(
        hasIncomingRequest: Bool,
        hasOutgoingRequest: Bool,
        requestCount: Int
    ) -> TurboRequestRelationshipPayload {
        let normalizedRequestCount = max(requestCount, 1)
        let kind: String
        switch (hasIncomingRequest, hasOutgoingRequest) {
        case (true, true):
            kind = "mutual"
        case (true, false):
            kind = "incoming"
        case (false, true):
            kind = "outgoing"
        case (false, false):
            kind = "none"
        }
        return TurboRequestRelationshipPayload(
            kind: kind,
            requestCount: kind == "none" ? nil : normalizedRequestCount
        )
    }

    var membership: TurboChannelMembership {
        membershipPayload.membership
    }

    var requestRelationship: TurboRequestRelationship {
        requestRelationshipPayload.relationship
    }

    var selfJoined: Bool {
        membership.hasLocalMembership
    }

    var peerJoined: Bool {
        membership.hasPeerMembership
    }

    var peerDeviceConnected: Bool {
        membership.peerDeviceConnected
    }

    var hasIncomingRequest: Bool {
        requestRelationship.hasIncomingRequest
    }

    var hasOutgoingRequest: Bool {
        requestRelationship.hasOutgoingRequest
    }

    var requestCount: Int {
        requestRelationship.requestCount ?? 0
    }

    var statusView: TurboConversationStatus {
        conversationStatusPayload.status
    }

    var activeTransmitterUserId: String? {
        statusView.activeTransmitterUserId
    }

    var status: String {
        statusView.kind
    }

    var statusKind: String {
        statusView.kind
    }

    var conversationStatus: ConversationState? {
        statusView.conversationState
    }

    func settingMembership(_ membership: TurboChannelMembership) -> TurboChannelStateResponse {
        TurboChannelStateResponse(
            channelId: channelId,
            selfUserId: selfUserId,
            peerUserId: peerUserId,
            peerHandle: peerHandle,
            selfOnline: selfOnline,
            peerOnline: peerOnline,
            selfJoined: membership.hasLocalMembership,
            peerJoined: membership.hasPeerMembership,
            peerDeviceConnected: membership.peerDeviceConnected,
            hasIncomingRequest: hasIncomingRequest,
            hasOutgoingRequest: hasOutgoingRequest,
            requestCount: requestCount,
            activeTransmitterUserId: activeTransmitterUserId,
            activeTransmitId: activeTransmitId,
            transmitLeaseExpiresAt: transmitLeaseExpiresAt,
            stateEpoch: stateEpoch,
            serverTimestamp: serverTimestamp,
            status: statusKind,
            canTransmit: canTransmit,
            requestRelationshipPayload: requestRelationshipPayload,
            conversationStatusPayload: conversationStatusPayload
        )
    }
}

struct TurboChannelReadinessResponse: Decodable, Equatable {
    let channelId: String
    let peerUserId: String
    let selfHasActiveDevice: Bool
    let peerHasActiveDevice: Bool
    let stateEpoch: String?
    let serverTimestamp: String?
    let activeTransmitId: String?
    let activeTransmitExpiresAt: String?
    private let readinessPayload: TurboChannelReadinessPayload
    private let audioReadinessPayload: TurboChannelAudioReadinessPayload
    private let wakeReadinessPayload: TurboChannelWakeReadinessPayload
    let peerDirectQuicIdentity: TurboDirectQuicPeerIdentityPayload?
    let peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload?

    init(
        channelId: String,
        peerUserId: String,
        selfHasActiveDevice: Bool,
        peerHasActiveDevice: Bool,
        activeTransmitterUserId: String?,
        activeTransmitId: String? = nil,
        activeTransmitExpiresAt: String?,
        stateEpoch: String? = nil,
        serverTimestamp: String? = nil,
        status: String,
        readinessPayload: TurboChannelReadinessPayload? = nil,
        audioReadinessPayload: TurboChannelAudioReadinessPayload? = nil,
        wakeReadinessPayload: TurboChannelWakeReadinessPayload? = nil,
        peerDirectQuicIdentity: TurboDirectQuicPeerIdentityPayload? = nil,
        peerMediaEncryptionIdentity: TurboMediaEncryptionPeerIdentityPayload? = nil
    ) {
        self.channelId = channelId
        self.peerUserId = peerUserId
        self.selfHasActiveDevice = selfHasActiveDevice
        self.peerHasActiveDevice = peerHasActiveDevice
        self.stateEpoch = stateEpoch
        self.serverTimestamp = serverTimestamp
        self.activeTransmitId = activeTransmitId
        self.activeTransmitExpiresAt = activeTransmitExpiresAt
        self.readinessPayload = readinessPayload ?? TurboChannelReadinessPayload(
            kind: status,
            activeTransmitterUserId: activeTransmitterUserId
        )
        self.audioReadinessPayload = audioReadinessPayload ?? TurboChannelAudioReadinessPayload(
            selfReadiness: TurboAudioReadinessStatusPayload(kind: selfHasActiveDevice ? "waiting" : "unknown"),
            peerReadiness: TurboAudioReadinessStatusPayload(kind: peerHasActiveDevice ? "waiting" : "unknown"),
            peerTargetDeviceId: nil
        )
        self.wakeReadinessPayload = wakeReadinessPayload ?? TurboChannelWakeReadinessPayload(
            selfWakeCapability: TurboWakeCapabilityStatusPayload(kind: "unavailable"),
            peerWakeCapability: TurboWakeCapabilityStatusPayload(kind: "unavailable")
        )
        self.peerDirectQuicIdentity = peerDirectQuicIdentity
        self.peerMediaEncryptionIdentity = peerMediaEncryptionIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case channelId
        case peerUserId
        case selfHasActiveDevice
        case peerHasActiveDevice
        case stateEpoch
        case serverTimestamp
        case activeTransmitId
        case activeTransmitterUserId
        case activeTransmitExpiresAt
        case status
        case readiness
        case audioReadiness
        case wakeReadiness
        case peerDirectQuicIdentity
        case peerMediaEncryptionIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try container.decode(String.self, forKey: .channelId)
        peerUserId = try container.decode(String.self, forKey: .peerUserId)
        selfHasActiveDevice = try container.decode(Bool.self, forKey: .selfHasActiveDevice)
        peerHasActiveDevice = try container.decode(Bool.self, forKey: .peerHasActiveDevice)
        stateEpoch = try container.decodeIfPresent(String.self, forKey: .stateEpoch)
        serverTimestamp = try container.decodeIfPresent(String.self, forKey: .serverTimestamp)
        activeTransmitId = try container.decodeIfPresent(String.self, forKey: .activeTransmitId)
        activeTransmitExpiresAt = try container.decodeIfPresent(String.self, forKey: .activeTransmitExpiresAt)
        readinessPayload = try container.decode(TurboChannelReadinessPayload.self, forKey: .readiness)
        audioReadinessPayload = try container.decode(TurboChannelAudioReadinessPayload.self, forKey: .audioReadiness)
        wakeReadinessPayload = try container.decode(TurboChannelWakeReadinessPayload.self, forKey: .wakeReadiness)
        peerDirectQuicIdentity = try container.decodeIfPresent(
            TurboDirectQuicPeerIdentityPayload.self,
            forKey: .peerDirectQuicIdentity
        )
        peerMediaEncryptionIdentity = try container.decodeIfPresent(
            TurboMediaEncryptionPeerIdentityPayload.self,
            forKey: .peerMediaEncryptionIdentity
        )
    }

    var statusView: TurboChannelReadinessStatus {
        readinessPayload.status
    }

    var activeTransmitterUserId: String? {
        statusView.activeTransmitterUserId
    }

    var status: String {
        statusView.kind
    }

    var statusKind: String {
        statusView.kind
    }

    var canTransmit: Bool {
        statusView.canTransmit
    }

    var remoteAudioReadiness: RemoteAudioReadinessState {
        audioReadinessPayload.remoteStatus
    }

    var localAudioReadiness: RemoteAudioReadinessState {
        audioReadinessPayload.localStatus
    }

    var peerTargetDeviceId: String? {
        audioReadinessPayload.peerTargetDeviceId
    }

    var peerDirectQuicFingerprint: String? {
        peerDirectQuicIdentity?.activeFingerprint
    }

    var peerMediaEncryptionRegistration: MediaEncryptionIdentityRegistrationMetadata? {
        peerMediaEncryptionIdentity?.activeRegistration
    }

    var remoteWakeCapability: RemoteWakeCapabilityState {
        wakeReadinessPayload.remoteStatus
    }

    var localWakeCapability: RemoteWakeCapabilityState {
        wakeReadinessPayload.localStatus
    }

    func settingRemoteAudioReadiness(_ status: RemoteAudioReadinessState) -> TurboChannelReadinessResponse {
        TurboChannelReadinessResponse(
            channelId: channelId,
            peerUserId: peerUserId,
            selfHasActiveDevice: selfHasActiveDevice,
            peerHasActiveDevice: peerHasActiveDevice,
            activeTransmitterUserId: activeTransmitterUserId,
            activeTransmitId: activeTransmitId,
            activeTransmitExpiresAt: activeTransmitExpiresAt,
            stateEpoch: stateEpoch,
            serverTimestamp: serverTimestamp,
            status: statusKind,
            readinessPayload: readinessPayload,
            audioReadinessPayload: audioReadinessPayload.settingRemoteStatus(status),
            wakeReadinessPayload: wakeReadinessPayload,
            peerDirectQuicIdentity: peerDirectQuicIdentity,
            peerMediaEncryptionIdentity: peerMediaEncryptionIdentity
        )
    }

    func preservingReadyStatus(from existing: TurboChannelReadinessResponse) -> TurboChannelReadinessResponse {
        TurboChannelReadinessResponse(
            channelId: channelId,
            peerUserId: peerUserId,
            selfHasActiveDevice: true,
            peerHasActiveDevice: peerHasActiveDevice,
            activeTransmitterUserId: existing.activeTransmitterUserId,
            activeTransmitId: existing.activeTransmitId,
            activeTransmitExpiresAt: existing.activeTransmitExpiresAt,
            stateEpoch: stateEpoch,
            serverTimestamp: serverTimestamp,
            status: existing.statusKind,
            readinessPayload: TurboChannelReadinessPayload(
                kind: existing.statusKind,
                activeTransmitterUserId: existing.activeTransmitterUserId
            ),
            audioReadinessPayload: audioReadinessPayload.settingRemoteStatus(existing.remoteAudioReadiness),
            wakeReadinessPayload: wakeReadinessPayload,
            peerDirectQuicIdentity: peerDirectQuicIdentity,
            peerMediaEncryptionIdentity: peerMediaEncryptionIdentity
        )
    }

    func preservingRoutableReadyProjection(from existing: TurboChannelReadinessResponse) -> TurboChannelReadinessResponse {
        TurboChannelReadinessResponse(
            channelId: channelId,
            peerUserId: peerUserId,
            selfHasActiveDevice: existing.selfHasActiveDevice,
            peerHasActiveDevice: existing.peerHasActiveDevice,
            activeTransmitterUserId: existing.activeTransmitterUserId,
            activeTransmitId: existing.activeTransmitId,
            activeTransmitExpiresAt: existing.activeTransmitExpiresAt,
            stateEpoch: stateEpoch,
            serverTimestamp: serverTimestamp,
            status: existing.statusKind,
            readinessPayload: TurboChannelReadinessPayload(
                kind: existing.statusKind,
                activeTransmitterUserId: existing.activeTransmitterUserId
            ),
            audioReadinessPayload: TurboChannelAudioReadinessPayload(
                selfReadiness: TurboAudioReadinessStatusPayload(kind: existing.localAudioReadiness.payloadKind),
                peerReadiness: TurboAudioReadinessStatusPayload(kind: existing.remoteAudioReadiness.payloadKind),
                peerTargetDeviceId: peerTargetDeviceId ?? existing.peerTargetDeviceId
            ),
            wakeReadinessPayload: wakeReadinessPayload,
            peerDirectQuicIdentity: peerDirectQuicIdentity,
            peerMediaEncryptionIdentity: peerMediaEncryptionIdentity
        )
    }

    func settingRemoteWakeCapability(_ status: RemoteWakeCapabilityState) -> TurboChannelReadinessResponse {
        TurboChannelReadinessResponse(
            channelId: channelId,
            peerUserId: peerUserId,
            selfHasActiveDevice: selfHasActiveDevice,
            peerHasActiveDevice: peerHasActiveDevice,
            activeTransmitterUserId: activeTransmitterUserId,
            activeTransmitId: activeTransmitId,
            activeTransmitExpiresAt: activeTransmitExpiresAt,
            stateEpoch: stateEpoch,
            serverTimestamp: serverTimestamp,
            status: statusKind,
            readinessPayload: readinessPayload,
            audioReadinessPayload: audioReadinessPayload,
            wakeReadinessPayload: wakeReadinessPayload.settingRemoteStatus(status),
            peerDirectQuicIdentity: peerDirectQuicIdentity,
            peerMediaEncryptionIdentity: peerMediaEncryptionIdentity
        )
    }
}

private extension RemoteAudioReadinessState {
    var payloadKind: String {
        switch self {
        case .unknown:
            return "unknown"
        case .waiting:
            return "waiting"
        case .wakeCapable:
            return "wake-capable"
        case .ready:
            return "ready"
        }
    }
}

struct TurboTokenResponse: Decodable {
    let channelId: String
    let token: String
    let status: String
}

struct TurboRevokeTokenResponse: Decodable {
    let channelId: String
    let deviceId: String
    let status: String
}

struct TurboReceiverAudioReadinessResponse: Decodable {
    let channelId: String
    let deviceId: String
    let type: String
    let audioReadiness: String
    let status: String
}

struct TurboBeginTransmitResponse: Decodable {
    let channelId: String
    let status: String
    let transmitId: String?
    let startedAt: String
    let expiresAt: String
    let targetUserId: String
    let targetDeviceId: String
}

struct TurboRenewTransmitResponse: Decodable {
    let channelId: String
    let status: String
    let transmitId: String?
    let startedAt: String
    let expiresAt: String
}

struct TurboEndTransmitResponse: Decodable {
    let channelId: String
    let status: String
}

struct TurboErrorResponse: Decodable {
    let error: String
}

enum TurboBackendError: LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case invalidResponseDetails(String)
    case server(String)
    case webSocketUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Backend configuration is missing or invalid."
        case .invalidResponse:
            return "Backend returned an invalid response."
        case .invalidResponseDetails(let details):
            return "Backend returned an invalid response: \(details)"
        case let .server(message):
            return message
        case .webSocketUnavailable:
            return "WebSocket connection is not available."
        }
    }
}
