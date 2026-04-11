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

struct MediaSessionAudioConfiguration: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let shouldActivateSession: Bool
}

enum MediaSessionAudioPolicy {
    static func configuration(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) -> MediaSessionAudioConfiguration {
        let shouldActivateSession = activationMode == .appManaged

        switch startupMode {
        case .interactive:
            return MediaSessionAudioConfiguration(
                category: .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP],
                shouldActivateSession: shouldActivateSession
            )
        case .playbackOnly:
            return MediaSessionAudioConfiguration(
                category: .playback,
                mode: .default,
                options: [],
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
    func receiveRemoteAudioChunk(_ payload: String) async
    func close()
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

    func receiveRemoteAudioChunk(_ payload: String) async {}

    func close() {
        isStarted = false
        state = .closed
    }
}
