import Foundation
import PushToTalk

enum PTTSystemClientError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "PTT is not ready"
        }
    }
}

@MainActor
final class PTTSystemClient {
    private var manager: PTChannelManager?

    var isReady: Bool {
        manager != nil
    }

    func configure(
        delegate: PTChannelManagerDelegate,
        restorationDelegate: PTChannelRestorationDelegate
    ) async throws {
        guard manager == nil else { return }
        manager = try await PTChannelManager.channelManager(
            delegate: delegate,
            restorationDelegate: restorationDelegate
        )
    }

    func joinChannel(channelUUID: UUID, name: String) throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        let descriptor = PTChannelDescriptor(name: name, image: nil)
        manager.requestJoinChannel(channelUUID: channelUUID, descriptor: descriptor)
    }

    func leaveChannel(channelUUID: UUID) throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        manager.leaveChannel(channelUUID: channelUUID)
    }

    func beginTransmitting(channelUUID: UUID) throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        manager.requestBeginTransmitting(channelUUID: channelUUID)
    }

    func stopTransmitting(channelUUID: UUID) throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        manager.stopTransmitting(channelUUID: channelUUID)
    }
}
