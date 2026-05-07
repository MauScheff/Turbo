import Foundation
import AVFAudio

enum MediaConnectionState: Equatable {
    case idle
    case preparing
    case connected
    case failed(String)
    case closed
}

enum MediaSessionActivationMode: Equatable {
    case appManaged
    case systemActivated
}

enum MediaSessionStartupMode: Equatable {
    case interactive
    case playbackOnly
}

enum MediaSessionPlaybackProfile: Equatable {
    case lowLatency
    case relayJitterBuffered
}

struct MediaSessionAudioConfiguration: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let shouldConfigureSession: Bool
    let shouldActivateSession: Bool
}

enum MediaSessionAudioPolicy {
    static let routeCapableOptions: AVAudioSession.CategoryOptions = [
        .defaultToSpeaker,
        .allowBluetoothHFP,
        .allowBluetoothA2DP,
    ]

    static func configuration(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) -> MediaSessionAudioConfiguration {
        // Keep the category aligned with Apple's PTT guidance, but only let
        // app-managed interactive sessions activate the audio session directly.
        let shouldActivateSession = activationMode == .appManaged && startupMode == .interactive
        let shouldConfigureSession = !(activationMode == .systemActivated && startupMode == .playbackOnly)

        switch startupMode {
        case .interactive:
            return MediaSessionAudioConfiguration(
                category: .playAndRecord,
                mode: .default,
                options: routeCapableOptions,
                shouldConfigureSession: shouldConfigureSession,
                shouldActivateSession: shouldActivateSession
            )
        case .playbackOnly:
            return MediaSessionAudioConfiguration(
                category: .playAndRecord,
                mode: .default,
                options: routeCapableOptions,
                shouldConfigureSession: shouldConfigureSession,
                shouldActivateSession: shouldActivateSession
            )
        }
    }
}

protocol MediaSessionDelegate: AnyObject {
    func mediaSession(_ session: MediaSession, didChange state: MediaConnectionState)
}

protocol MediaSession: AnyObject {
    var delegate: MediaSessionDelegate? { get set }
    var state: MediaConnectionState { get }

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?)
    func start(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) async throws
    func startSendingAudio() async throws
    func stopSendingAudio() async throws
    func abortSendingAudio() async
    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile: MediaSessionPlaybackProfile
    ) async
    func audioRouteDidChange() async
    func hasPendingPlayback() -> Bool
    func close(deactivateAudioSession: Bool)
}

extension MediaSession {
    func receiveRemoteAudioChunk(_ payload: String) async {
        await receiveRemoteAudioChunk(payload, playbackProfile: .lowLatency)
    }

    func close() {
        close(deactivateAudioSession: true)
    }

    func abortSendingAudio() async {
        try? await stopSendingAudio()
    }
}

func makeDefaultMediaSession(
    supportsWebSocket: Bool,
    sendAudioChunk: (@Sendable (String) async throws -> Void)?,
    reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil
) -> any MediaSession {
    #if targetEnvironment(simulator)
    // Simulator scenarios validate control-plane behavior, not real audio I/O.
    return StubRelayMediaSession()
    #else
    if supportsWebSocket {
        return PCMWebSocketMediaSession(sendAudioChunk: sendAudioChunk, reportEvent: reportEvent)
    }
    return StubRelayMediaSession()
    #endif
}

final class StubRelayMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?

    private(set) var state: MediaConnectionState = .idle {
        didSet {
            guard oldValue != state else { return }
            delegate?.mediaSession(self, didChange: state)
        }
    }

    private var isStarted = false

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {}

    func start(
        activationMode _: MediaSessionActivationMode,
        startupMode _: MediaSessionStartupMode
    ) async throws {
        guard !isStarted else { return }
        state = .preparing
        isStarted = true
        state = .connected
    }

    func startSendingAudio() async throws {
        if !isStarted {
            try await start(activationMode: .appManaged, startupMode: .interactive)
        }
    }

    func stopSendingAudio() async throws {}

    func abortSendingAudio() async {}

    func receiveRemoteAudioChunk(
        _ payload: String,
        playbackProfile _: MediaSessionPlaybackProfile
    ) async {}

    func audioRouteDidChange() async {}

    func hasPendingPlayback() -> Bool { false }

    func close(deactivateAudioSession _: Bool) {
        isStarted = false
        state = .closed
    }
}
