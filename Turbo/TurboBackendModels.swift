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
    case waitingForSelf
    case waitingForPeer
    case ready
    case selfTransmitting(activeTransmitterUserId: String?)
    case peerTransmitting(activeTransmitterUserId: String?)
    case unknown(String)

    init(rawValue: String, activeTransmitterUserId: String?) {
        switch rawValue {
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
        case .waitingForSelf, .waitingForPeer, .ready, .unknown:
            return nil
        }
    }

    var conversationState: ConversationState? {
        switch self {
        case .waitingForSelf, .waitingForPeer:
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

    var canTransmit: Bool {
        switch self {
        case .ready:
            return true
        case .waitingForSelf, .waitingForPeer, .selfTransmitting, .peerTransmitting, .unknown:
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
        "ready",
    ]

    var status: RemoteAudioReadinessState {
        switch kind {
        case "ready":
            return .ready
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
                case .ready:
                    return "ready"
                }
            }()),
            peerTargetDeviceId: peerTargetDeviceId
        )
    }
}

struct TurboBackendConfig {
    let baseURL: URL
    let devUserHandle: String
    let deviceID: String

    static func load() -> TurboBackendConfig? {
        guard let rawBaseURL = Bundle.main.object(forInfoDictionaryKey: "TurboBackendBaseURL") as? String,
              let baseURL = URL(string: rawBaseURL),
              let defaultDevUserHandle = Bundle.main.object(forInfoDictionaryKey: "TurboDevUserHandle") as? String,
              !defaultDevUserHandle.isEmpty else {
            return nil
        }

        return TurboBackendConfig(
            baseURL: baseURL,
            devUserHandle: persistedDevUserHandle(defaultValue: defaultDevUserHandle),
            deviceID: persistedDeviceID()
        )
    }

    static func setPersistedDevUserHandle(_ handle: String) {
        let normalized = normalizeDevUserHandle(handle)
        UserDefaults.standard.set(normalized, forKey: "TurboDevUserHandleOverride")
    }

    private static func persistedDevUserHandle(defaultValue: String) -> String {
        let defaults = UserDefaults.standard
        if let override = defaults.string(forKey: "TurboDevUserHandleOverride"),
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizeDevUserHandle(override)
        }
        return normalizeDevUserHandle(defaultValue)
    }

    private static func normalizeDevUserHandle(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "@turbo-ios" }
        return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
    }

    private static func persistedDeviceID() -> String {
        let defaults = UserDefaults.standard
        let key = "TurboDeviceID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let newValue = UIDevice.current.identifierForVendor?.uuidString.lowercased() ?? UUID().uuidString.lowercased()
        defaults.set(newValue, forKey: key)
        return newValue
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
}

enum TurboPTTPushEvent: String, Codable, Equatable {
    case transmitStart = "transmit-start"
    case leaveChannel = "leave-channel"
}

struct TurboPTTPushPayload: Equatable {
    let event: TurboPTTPushEvent
    let channelId: String?
    let activeSpeaker: String?
    let senderUserId: String?
    let senderDeviceId: String?

    var participantName: String {
        activeSpeaker ?? "Remote"
    }

    init(
        event: TurboPTTPushEvent,
        channelId: String?,
        activeSpeaker: String?,
        senderUserId: String?,
        senderDeviceId: String?
    ) {
        self.event = event
        self.channelId = channelId
        self.activeSpeaker = activeSpeaker
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
            senderUserId: pushPayload["senderUserId"] as? String,
            senderDeviceId: pushPayload["senderDeviceId"] as? String
        )
    }
}

struct TurboSignalEnvelope: Codable {
    let type: TurboSignalKind
    let channelId: String
    let fromUserId: String
    let fromDeviceId: String
    let toUserId: String
    let toDeviceId: String
    let payload: String
}

struct TurboAuthSessionResponse: Decodable {
    let userId: String
    let handle: String
    let displayName: String
}

struct TurboBackendRuntimeConfig: Decodable {
    let mode: String
    let supportsWebSocket: Bool
}

struct TurboSeedResponse: Decodable {
    let status: String
    let users: [TurboUserLookupResponse]
}

struct TurboWebSocketStatusNotice: Decodable {
    let status: String
    let deviceId: String?
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
    let displayName: String
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
    let displayName: String
    let isOnline: Bool
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
    let displayName: String
    let channelId: String?
    let isOnline: Bool
    let isActiveConversation: Bool
    private let requestRelationshipPayload: TurboRequestRelationshipPayload
    private let membershipPayload: TurboChannelMembershipPayload
    private let summaryStatusPayload: TurboSummaryStatusPayload

    init(
        userId: String,
        handle: String,
        displayName: String,
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
        self.displayName = displayName
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
        case displayName
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
        displayName = try container.decode(String.self, forKey: .displayName)
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
        transmitLeaseExpiresAt: String?,
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
}

struct TurboChannelReadinessResponse: Decodable, Equatable {
    let channelId: String
    let peerUserId: String
    let selfHasActiveDevice: Bool
    let peerHasActiveDevice: Bool
    let activeTransmitExpiresAt: String?
    private let readinessPayload: TurboChannelReadinessPayload
    private let audioReadinessPayload: TurboChannelAudioReadinessPayload

    init(
        channelId: String,
        peerUserId: String,
        selfHasActiveDevice: Bool,
        peerHasActiveDevice: Bool,
        activeTransmitterUserId: String?,
        activeTransmitExpiresAt: String?,
        status: String,
        readinessPayload: TurboChannelReadinessPayload? = nil,
        audioReadinessPayload: TurboChannelAudioReadinessPayload? = nil
    ) {
        self.channelId = channelId
        self.peerUserId = peerUserId
        self.selfHasActiveDevice = selfHasActiveDevice
        self.peerHasActiveDevice = peerHasActiveDevice
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
    }

    private enum CodingKeys: String, CodingKey {
        case channelId
        case peerUserId
        case selfHasActiveDevice
        case peerHasActiveDevice
        case activeTransmitterUserId
        case activeTransmitExpiresAt
        case status
        case readiness
        case audioReadiness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try container.decode(String.self, forKey: .channelId)
        peerUserId = try container.decode(String.self, forKey: .peerUserId)
        selfHasActiveDevice = try container.decode(Bool.self, forKey: .selfHasActiveDevice)
        peerHasActiveDevice = try container.decode(Bool.self, forKey: .peerHasActiveDevice)
        activeTransmitExpiresAt = try container.decodeIfPresent(String.self, forKey: .activeTransmitExpiresAt)
        readinessPayload = try container.decode(TurboChannelReadinessPayload.self, forKey: .readiness)
        audioReadinessPayload = try container.decode(TurboChannelAudioReadinessPayload.self, forKey: .audioReadiness)
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

    func settingRemoteAudioReadiness(_ status: RemoteAudioReadinessState) -> TurboChannelReadinessResponse {
        TurboChannelReadinessResponse(
            channelId: channelId,
            peerUserId: peerUserId,
            selfHasActiveDevice: selfHasActiveDevice,
            peerHasActiveDevice: peerHasActiveDevice,
            activeTransmitterUserId: activeTransmitterUserId,
            activeTransmitExpiresAt: activeTransmitExpiresAt,
            status: statusKind,
            readinessPayload: readinessPayload,
            audioReadinessPayload: audioReadinessPayload.settingRemoteStatus(status)
        )
    }
}

struct TurboTokenResponse: Decodable {
    let channelId: String
    let token: String
    let status: String
}

struct TurboBeginTransmitResponse: Decodable {
    let channelId: String
    let status: String
    let startedAt: String
    let expiresAt: String
    let targetUserId: String
    let targetDeviceId: String
}

struct TurboRenewTransmitResponse: Decodable {
    let channelId: String
    let status: String
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
