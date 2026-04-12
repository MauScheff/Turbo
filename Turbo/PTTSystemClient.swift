import Foundation
import PushToTalk
import AVFAudio

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
struct PTTSystemClientCallbacks {
    let receivedEphemeralPushToken: (Data) -> Void
    let receivedIncomingPush: (UUID, TurboPTTPushPayload) -> Void
    let didJoinChannel: (UUID, String) -> Void
    let didLeaveChannel: (UUID, String) -> Void
    let failedToJoinChannel: (UUID, Error) -> Void
    let failedToLeaveChannel: (UUID, Error) -> Void
    let didBeginTransmitting: (UUID, String) -> Void
    let didEndTransmitting: (UUID, String) -> Void
    let failedToBeginTransmitting: (UUID, Error) -> Void
    let failedToStopTransmitting: (UUID, Error) -> Void
    let didActivateAudioSession: (AVAudioSession) -> Void
    let didDeactivateAudioSession: (AVAudioSession) -> Void
    let descriptorForRestoredChannel: (UUID) -> PTChannelDescriptor
    let restoredChannel: (UUID) -> Void
}

@MainActor
protocol PTTSystemClientProtocol: AnyObject {
    var isReady: Bool { get }
    var modeDescription: String { get }

    func configure(callbacks: PTTSystemClientCallbacks) async throws
    func joinChannel(channelUUID: UUID, name: String) throws
    func leaveChannel(channelUUID: UUID) throws
    func beginTransmitting(channelUUID: UUID) throws
    func stopTransmitting(channelUUID: UUID) throws
    func setActiveRemoteParticipant(name: String?, channelUUID: UUID) async throws
}

@MainActor
private final class ApplePTTSystemClientAdapter: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate {
    let callbacks: PTTSystemClientCallbacks

    init(callbacks: PTTSystemClientCallbacks) {
        self.callbacks = callbacks
    }

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken token: Data) {
        callbacks.receivedEphemeralPushToken(token)
    }

    func handleIncomingPush(channelUUID: UUID, payload: TurboPTTPushPayload) -> PTPushResult {
        callbacks.receivedIncomingPush(channelUUID, payload)
        switch payload.event {
        case .transmitStart:
            return .activeRemoteParticipant(PTParticipant(name: payload.participantName, image: nil))
        case .leaveChannel:
            return .leaveChannel
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
        callbacks.didJoinChannel(channelUUID, String(describing: reason))
    }

    func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
        callbacks.didLeaveChannel(channelUUID, String(describing: reason))
    }

    func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: any Error) {
        callbacks.failedToJoinChannel(channelUUID, error)
    }

    func channelManager(_ channelManager: PTChannelManager, failedToLeaveChannel channelUUID: UUID, error: any Error) {
        callbacks.failedToLeaveChannel(channelUUID, error)
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        callbacks.didBeginTransmitting(channelUUID, String(describing: source))
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        callbacks.didEndTransmitting(channelUUID, String(describing: source))
    }

    func channelManager(_ channelManager: PTChannelManager, failedToBeginTransmittingInChannel channelUUID: UUID, error: any Error) {
        callbacks.failedToBeginTransmitting(channelUUID, error)
    }

    func channelManager(_ channelManager: PTChannelManager, failedToStopTransmittingInChannel channelUUID: UUID, error: any Error) {
        callbacks.failedToStopTransmitting(channelUUID, error)
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        callbacks.didActivateAudioSession(audioSession)
    }

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        callbacks.didDeactivateAudioSession(audioSession)
    }

    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String : Any]) -> PTPushResult {
        if let payload = TurboPTTPushPayload(pushPayload: pushPayload) {
            return handleIncomingPush(channelUUID: channelUUID, payload: payload)
        }
        let fallbackPayload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: pushPayload["channelId"] as? String,
            activeSpeaker: pushPayload["activeSpeaker"] as? String ?? "Remote",
            senderUserId: pushPayload["senderUserId"] as? String,
            senderDeviceId: pushPayload["senderDeviceId"] as? String
        )
        return handleIncomingPush(channelUUID: channelUUID, payload: fallbackPayload)
    }

    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        callbacks.restoredChannel(channelUUID)
        return callbacks.descriptorForRestoredChannel(channelUUID)
    }
}

@MainActor
final class ApplePTTSystemClient: PTTSystemClientProtocol {
    private var manager: PTChannelManager?
    private var adapter: ApplePTTSystemClientAdapter?

    var isReady: Bool {
        manager != nil
    }

    let modeDescription: String = "apple"

    func configure(callbacks: PTTSystemClientCallbacks) async throws {
        guard manager == nil else { return }
        let adapter = ApplePTTSystemClientAdapter(callbacks: callbacks)
        manager = try await PTChannelManager.channelManager(
            delegate: adapter,
            restorationDelegate: adapter
        )
        self.adapter = adapter
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

    func setActiveRemoteParticipant(name: String?, channelUUID: UUID) async throws {
        guard let manager else { throw PTTSystemClientError.notReady }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let participant = name.map { PTParticipant(name: $0, image: nil) }
            manager.setActiveRemoteParticipant(participant, channelUUID: channelUUID) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

@MainActor
final class SimulatorPTTSystemClient: PTTSystemClientProtocol {
    private var callbacks: PTTSystemClientCallbacks?
    private var activeChannelUUID: UUID?
    private var isTransmitting: Bool = false
    private let audioSession = AVAudioSession.sharedInstance()

    var isReady: Bool {
        callbacks != nil
    }

    let modeDescription: String = "simulator"

    func configure(callbacks: PTTSystemClientCallbacks) async throws {
        guard self.callbacks == nil else { return }
        self.callbacks = callbacks
    }

    func joinChannel(channelUUID: UUID, name _: String) throws {
        guard let callbacks else { throw PTTSystemClientError.notReady }
        if let activeChannelUUID, activeChannelUUID != channelUUID {
            let error = NSError(domain: PTChannelErrorDomain, code: 2)
            Task { @MainActor in
                callbacks.failedToJoinChannel(channelUUID, error)
            }
            return
        }
        activeChannelUUID = channelUUID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            callbacks.didJoinChannel(channelUUID, "simulator")
        }
    }

    func leaveChannel(channelUUID: UUID) throws {
        guard let callbacks else { throw PTTSystemClientError.notReady }
        guard activeChannelUUID == channelUUID else {
            let error = NSError(domain: PTChannelErrorDomain, code: 1)
            Task { @MainActor in
                callbacks.failedToLeaveChannel(channelUUID, error)
            }
            return
        }
        activeChannelUUID = nil
        isTransmitting = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            callbacks.didLeaveChannel(channelUUID, "simulator")
        }
    }

    func beginTransmitting(channelUUID: UUID) throws {
        guard let callbacks else { throw PTTSystemClientError.notReady }
        guard activeChannelUUID == channelUUID else {
            let error = NSError(domain: PTChannelErrorDomain, code: 1)
            Task { @MainActor in
                callbacks.failedToBeginTransmitting(channelUUID, error)
            }
            return
        }
        isTransmitting = true
        Task { @MainActor in
            try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            callbacks.didBeginTransmitting(channelUUID, "simulator")
            callbacks.didActivateAudioSession(audioSession)
        }
    }

    func stopTransmitting(channelUUID: UUID) throws {
        guard let callbacks else { throw PTTSystemClientError.notReady }
        guard activeChannelUUID == channelUUID, isTransmitting else {
            let error = NSError(domain: PTChannelErrorDomain, code: 5)
            Task { @MainActor in
                callbacks.failedToStopTransmitting(channelUUID, error)
            }
            return
        }
        isTransmitting = false
        Task { @MainActor in
            callbacks.didEndTransmitting(channelUUID, "simulator")
            callbacks.didDeactivateAudioSession(audioSession)
        }
    }

    func setActiveRemoteParticipant(name _: String?, channelUUID _: UUID) async throws {}
}

@MainActor
func makeDefaultPTTSystemClient() -> any PTTSystemClientProtocol {
    #if targetEnvironment(simulator)
    return SimulatorPTTSystemClient()
    #else
    return ApplePTTSystemClient()
    #endif
}
