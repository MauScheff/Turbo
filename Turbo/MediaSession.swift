import Foundation

enum MediaConnectionState: Equatable {
    case idle
    case preparing
    case connected
    case failed(String)
    case closed
}

protocol MediaSessionDelegate: AnyObject {
    func mediaSession(_ session: MediaSession, didChange state: MediaConnectionState)
}

protocol MediaSession: AnyObject {
    var delegate: MediaSessionDelegate? { get set }
    var state: MediaConnectionState { get }

    func start() async throws
    func startSendingAudio() async throws
    func stopSendingAudio() async throws
    func receiveRemoteAudioChunk(_ payload: String) async
    func close()
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

    func start() async throws {
        guard !isStarted else { return }
        state = .preparing
        isStarted = true
        state = .connected
    }

    func startSendingAudio() async throws {
        if !isStarted {
            try await start()
        }
    }

    func stopSendingAudio() async throws {}

    func receiveRemoteAudioChunk(_ payload: String) async {}

    func close() {
        isStarted = false
        state = .closed
    }
}
