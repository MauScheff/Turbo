import Foundation
import UIKit

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
    let hasIncomingRequest: Bool
    let hasOutgoingRequest: Bool
    let requestCount: Int
    let isActiveConversation: Bool
    let badgeStatus: String
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
    let selfJoined: Bool
    let peerJoined: Bool
    let peerDeviceConnected: Bool
    let hasIncomingRequest: Bool
    let hasOutgoingRequest: Bool
    let requestCount: Int
    let activeTransmitterUserId: String?
    let transmitLeaseExpiresAt: String?
    let status: String
    let canTransmit: Bool
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
    case server(String)
    case webSocketUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Backend configuration is missing or invalid."
        case .invalidResponse:
            return "Backend returned an invalid response."
        case let .server(message):
            return message
        case .webSocketUnavailable:
            return "WebSocket connection is not available."
        }
    }
}
