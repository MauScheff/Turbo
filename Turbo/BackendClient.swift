import Foundation

@MainActor
final class TurboBackendClient: NSObject, URLSessionWebSocketDelegate {
    enum WebSocketConnectionState: Equatable {
        case idle
        case connecting
        case connected
    }

    private let config: TurboBackendConfig
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Control-plane requests should fail fast; reconnection is handled explicitly.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var runtimeConfig: TurboBackendRuntimeConfig?
    private var webSocketConnectionState: WebSocketConnectionState = .idle
    private var shouldMaintainWebSocket = false
    private var isWebSocketSuspended = false
    private let webSocketConnectTimeoutNanoseconds: UInt64 = 5_000_000_000

    var onSignal: (@MainActor (TurboSignalEnvelope) -> Void)?
    var onServerNotice: (@MainActor (String) -> Void)?
    var onWebSocketStateChange: (@MainActor (WebSocketConnectionState) -> Void)?

    init(config: TurboBackendConfig) {
        self.config = config
    }

    var deviceID: String { config.deviceID }
    var devUserHandle: String { config.devUserHandle }
    var supportsWebSocket: Bool { runtimeConfig?.supportsWebSocket ?? false }
    var modeDescription: String { runtimeConfig?.mode ?? "unknown" }
    var isWebSocketConnected: Bool { webSocketConnectionState == .connected }

    func fetchRuntimeConfig() async throws -> TurboBackendRuntimeConfig {
        let response: TurboBackendRuntimeConfig = try await request(path: "/v1/config")
        runtimeConfig = response
        return response
    }

    func setRuntimeConfigForTesting(_ config: TurboBackendRuntimeConfig) {
        runtimeConfig = config
    }

    func authenticate() async throws -> TurboAuthSessionResponse {
        try await request(path: "/v1/auth/session", method: "POST")
    }

    func seedDevUsers() async throws -> TurboSeedResponse {
        try await request(path: "/v1/dev/seed", method: "POST")
    }

    func resetDevState() async throws -> TurboResetStateResponse {
        try await request(path: "/v1/dev/reset-state", method: "POST")
    }

    func resetAllDevState() async throws -> TurboResetStateResponse {
        try await request(path: "/v1/dev/reset-all", method: "POST")
    }

    func uploadDiagnostics(_ payload: TurboDiagnosticsUploadRequest) async throws -> TurboDiagnosticsUploadResponse {
        try await request(path: "/v1/dev/diagnostics", method: "POST", body: payload)
    }

    func latestDiagnostics(deviceId: String) async throws -> TurboLatestDiagnosticsResponse {
        let escapedDeviceID = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId
        return try await request(path: "/v1/dev/diagnostics/latest/\(escapedDeviceID)/")
    }

    func uploadTelemetry(_ payload: TurboTelemetryEventRequest) async throws -> TurboTelemetryUploadResponse {
        try await request(path: "/v1/telemetry/events", method: "POST", body: payload)
    }

    func registerDevice(label: String?, alertPushToken: String?) async throws -> TurboDeviceRegistrationResponse {
        try await request(
            path: "/v1/devices/register",
            method: "POST",
            body: TurboRegisterDeviceRequest(
                deviceId: config.deviceID,
                deviceLabel: label,
                alertPushToken: alertPushToken
            )
        )
    }

    func lookupUser(handle: String) async throws -> TurboUserLookupResponse {
        try await request(path: "/v1/users/by-handle/\(handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)")
    }

    func lookupPresence(handle: String) async throws -> TurboUserPresenceResponse {
        try await request(path: Self.presenceLookupPath(for: handle))
    }

    func heartbeatPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await request(
            path: "/v1/presence/heartbeat",
            method: "POST",
            body: TurboChannelDeviceRequest(deviceId: config.deviceID)
        )
    }

    func offlinePresence() async throws -> TurboPresenceHeartbeatResponse {
        try await request(
            path: "/v1/presence/offline",
            method: "POST",
            body: TurboChannelDeviceRequest(deviceId: config.deviceID)
        )
    }

    func backgroundPresence() async throws -> TurboPresenceHeartbeatResponse {
        try await request(
            path: "/v1/presence/background",
            method: "POST",
            body: TurboChannelDeviceRequest(deviceId: config.deviceID)
        )
    }

    func contactSummaries() async throws -> [TurboContactSummaryResponse] {
        try await request(
            path: "/v1/contacts/summaries/\(config.deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.deviceID)"
        )
    }

    func directChannel(otherHandle: String) async throws -> TurboDirectChannelResponse {
        try await request(
            path: "/v1/channels/direct",
            method: "POST",
            body: TurboDirectChannelRequest(otherHandle: otherHandle)
        )
    }

    func joinChannel(channelId: String) async throws -> TurboJoinResponse {
        try await request(
            path: "/v1/channels/\(channelId)/join",
            method: "POST",
            body: TurboChannelDeviceRequest(deviceId: config.deviceID)
        )
    }

    func leaveChannel(channelId: String) async throws -> TurboLeaveResponse {
        try await request(
            path: "/v1/channels/\(channelId)/leave",
            method: "POST",
            body: TurboChannelDeviceRequest(deviceId: config.deviceID)
        )
    }

    func channelState(channelId: String) async throws -> TurboChannelStateResponse {
        try await request(
            path: "/v1/channels/\(channelId)/state/\(config.deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.deviceID)"
        )
    }

    func channelReadiness(channelId: String) async throws -> TurboChannelReadinessResponse {
        try await request(
            path: "/v1/channels/\(channelId)/readiness/\(config.deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.deviceID)"
        )
    }

    func createInvite(otherHandle: String) async throws -> TurboInviteResponse {
        try await request(
            path: "/v1/invites",
            method: "POST",
            body: TurboCreateInviteRequest(otherHandle: otherHandle, deviceId: config.deviceID)
        )
    }

    func incomingInvites() async throws -> [TurboInviteResponse] {
        try await request(path: "/v1/invites/incoming")
    }

    func outgoingInvites() async throws -> [TurboInviteResponse] {
        try await request(path: "/v1/invites/outgoing")
    }

    func acceptInvite(inviteId: String) async throws -> TurboInviteResponse {
        try await request(path: "/v1/invites/\(inviteId)/accept", method: "POST")
    }

    func declineInvite(inviteId: String) async throws -> TurboInviteResponse {
        try await request(path: "/v1/invites/\(inviteId)/decline", method: "POST")
    }

    func cancelInvite(inviteId: String) async throws -> TurboInviteResponse {
        try await request(path: "/v1/invites/\(inviteId)/cancel", method: "POST")
    }

    func uploadEphemeralToken(channelId: String, token: String) async throws -> TurboTokenResponse {
        try await request(
            path: "/v1/channels/\(channelId)/ephemeral-token",
            method: "POST",
            body: TurboEphemeralTokenRequest(deviceId: config.deviceID, token: token)
        )
    }

    func beginTransmit(channelId: String) async throws -> TurboBeginTransmitResponse {
        try await request(
            path: "/v1/channels/\(channelId)/begin-transmit",
            method: "POST",
            body: TurboChannelDeviceRequest(deviceId: config.deviceID)
        )
    }

    func endTransmit(channelId: String) async throws -> TurboEndTransmitResponse {
        try await request(
            path: "/v1/channels/\(channelId)/end-transmit",
            method: "POST",
            body: TurboChannelDeviceRequest(deviceId: config.deviceID)
        )
    }

    func renewTransmit(channelId: String) async throws -> TurboRenewTransmitResponse {
        try await request(
            path: "/v1/channels/\(channelId)/renew-transmit",
            method: "POST",
            body: TurboChannelDeviceRequest(deviceId: config.deviceID)
        )
    }

    func connectWebSocket() {
        guard supportsWebSocket else { return }
        guard !isWebSocketSuspended else { return }
        shouldMaintainWebSocket = true
        reconnectTask?.cancel()
        reconnectTask = nil
        guard webSocketTask == nil else { return }
        guard webSocketConnectionState == .idle else { return }
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path =
            basePath.isEmpty
            ? "/v1/ws"
            : "/\(basePath)/v1/ws"
        components.queryItems = [URLQueryItem(name: "deviceId", value: config.deviceID)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.addValue(config.devUserHandle, forHTTPHeaderField: "x-turbo-user-handle")
        request.addValue("Bearer \(config.devUserHandle)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        setWebSocketConnectionState(.connecting)
        webSocketTask = task
        scheduleConnectTimeout(for: task)
        task.resume()
    }

    func disconnectWebSocket() {
        shouldMaintainWebSocket = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        setWebSocketConnectionState(.idle)
    }

    func suspendWebSocket() {
        isWebSocketSuspended = true
        disconnectWebSocket()
    }

    func resumeWebSocket() {
        isWebSocketSuspended = false
        ensureWebSocketConnected()
    }

    func forceReconnectWebSocket() {
        guard supportsWebSocket else { return }
        isWebSocketSuspended = false
        disconnectWebSocket()
        connectWebSocket()
    }

    func ensureWebSocketConnected() {
        guard supportsWebSocket else { return }
        guard !isWebSocketSuspended else { return }
        if webSocketConnectionState == .connected || webSocketConnectionState == .connecting {
            return
        }
        connectWebSocket()
    }

    func waitForWebSocketConnection() async throws {
        guard supportsWebSocket else { return }
        ensureWebSocketConnected()
        for _ in 0 ..< 20 {
            if webSocketConnectionState == .connected {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TurboBackendError.webSocketUnavailable
    }

    func sendSignal(_ envelope: TurboSignalEnvelope) async throws {
        guard supportsWebSocket else {
            throw TurboBackendError.webSocketUnavailable
        }
        if webSocketConnectionState != .connected || webSocketTask == nil {
            try await waitForWebSocketConnection()
        }
        guard webSocketConnectionState == .connected, let webSocketTask else {
            throw TurboBackendError.webSocketUnavailable
        }
        let data = try JSONEncoder().encode(envelope)
        let text = String(decoding: data, as: UTF8.self)
        try await webSocketTask.send(.string(text))
    }

    func setWebSocketConnectionStateForTesting(_ state: WebSocketConnectionState) {
        webSocketConnectionState = state
    }

    private func listenForMessages() async {
        guard let webSocketTask else { return }

        do {
            while !Task.isCancelled {
                let message = try await webSocketTask.receive()
                switch message {
                case let .string(text):
                    if let data = text.data(using: .utf8),
                       let envelope = try? JSONDecoder().decode(TurboSignalEnvelope.self, from: data) {
                        onSignal?(envelope)
                    } else if let data = text.data(using: .utf8),
                              let notice = try? JSONDecoder().decode(TurboWebSocketStatusNotice.self, from: data) {
                        if notice.status != "connected" {
                            onServerNotice?("WebSocket \(notice.status)")
                        }
                    } else if let data = text.data(using: .utf8),
                              let error = try? JSONDecoder().decode(TurboErrorResponse.self, from: data) {
                        onServerNotice?(error.error)
                    } else {
                        onServerNotice?(text)
                    }
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        onServerNotice?(text)
                    }
                @unknown default:
                    onServerNotice?("Received unknown websocket message")
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.receiveTask = nil
            self.webSocketTask = nil
            self.setWebSocketConnectionState(.idle)
            let reason = "WebSocket disconnected: \(error.localizedDescription)"
            onServerNotice?(reason)
            scheduleReconnect(reason: reason)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.webSocketTask === webSocketTask else { return }
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.setWebSocketConnectionState(.connected)
            self.onServerNotice?("WebSocket connected")
            self.receiveTask?.cancel()
            self.receiveTask = Task { [weak self] in
                await self?.listenForMessages()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.webSocketTask === webSocketTask else { return }
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.webSocketTask = nil
            self.setWebSocketConnectionState(.idle)
            if closeCode != .normalClosure {
                let reason = "WebSocket disconnected: closed with code \(closeCode.rawValue)"
                self.onServerNotice?(reason)
                self.scheduleReconnect(reason: reason)
            }
        }
    }

    private func setWebSocketConnectionState(_ state: WebSocketConnectionState) {
        guard webSocketConnectionState != state else { return }
        webSocketConnectionState = state
        onWebSocketStateChange?(state)
    }

    private func scheduleReconnect(reason: String) {
        guard supportsWebSocket, shouldMaintainWebSocket else { return }
        guard reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            guard self.shouldMaintainWebSocket else { return }
            self.reconnectTask = nil
            self.onServerNotice?("\(reason). Reconnecting…")
            self.connectWebSocket()
        }
    }

    private func scheduleConnectTimeout(for task: URLSessionWebSocketTask) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.webSocketConnectTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            guard self.webSocketTask === task else { return }
            guard self.webSocketConnectionState == .connecting else { return }
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.webSocketTask = nil
            self.setWebSocketConnectionState(.idle)
            task.cancel(with: .goingAway, reason: nil)
            self.onServerNotice?("WebSocket connect timed out")
            self.connectTimeoutTask = nil
            self.scheduleReconnect(reason: "WebSocket connect timed out")
        }
    }

    static func presenceLookupPath(for handle: String) -> String {
        let escapedHandle = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        return "/v1/users/by-handle/\(escapedHandle)/presence"
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String = "GET",
        body: Body? = nil
    ) async throws -> Response {
        let url = config.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue(config.devUserHandle, forHTTPHeaderField: "x-turbo-user-handle")
        request.addValue("Bearer \(config.devUserHandle)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TurboBackendError.invalidResponse
        }

        if 200 ..< 300 ~= http.statusCode {
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                onServerNotice?("Invalid response for \(method) \(path): \(error.localizedDescription) body=\(body)")
                throw TurboBackendError.invalidResponseDetails(
                    "\(method) \(path) decode failed: \(error.localizedDescription) body=\(body)"
                )
            }
        }

        if let error = try? JSONDecoder().decode(TurboErrorResponse.self, from: data) {
            throw TurboBackendError.server(error.error)
        }

        throw TurboBackendError.server(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET"
    ) async throws -> Response {
        try await request(path: path, method: method, body: Optional<TurboEmptyRequest>.none as TurboEmptyRequest?)
    }
}

private struct TurboEmptyRequest: Encodable {}

private struct TurboRegisterDeviceRequest: Encodable {
    let deviceId: String
    let deviceLabel: String?
    let alertPushToken: String?
}

private struct TurboDirectChannelRequest: Encodable {
    let otherHandle: String
}

private struct TurboCreateInviteRequest: Encodable {
    let otherHandle: String
    let deviceId: String
}

private struct TurboChannelDeviceRequest: Encodable {
    let deviceId: String
}

private struct TurboEphemeralTokenRequest: Encodable {
    let deviceId: String
    let token: String
}
