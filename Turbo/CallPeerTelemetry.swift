import AVFAudio
import Foundation
import Network

enum CallNetworkInterface: String, Codable, Equatable {
    case wifi
    case cellular
    case wired
    case other
    case unavailable
    case unknown

    var displayName: String? {
        switch self {
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            return "Cellular"
        case .wired:
            return "Wired"
        case .other:
            return "Network"
        case .unavailable:
            return "Offline"
        case .unknown:
            return nil
        }
    }

    nonisolated static func from(path: NWPath) -> CallNetworkInterface {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.other) || path.usesInterfaceType(.loopback) { return .other }
        return .unknown
    }
}

struct CallPeerTelemetry: Codable, Equatable {
    struct Audio: Codable, Equatable {
        let routeName: String
        let volumePercent: Int

        static func current(audioSession: AVAudioSession = .sharedInstance()) -> Audio {
            let outputs = audioSession.currentRoute.outputs
            let routeName = routeName(from: outputs)
            let volume = min(max(Double(audioSession.outputVolume), 0), 1)
            return Audio(
                routeName: routeName,
                volumePercent: Int((volume * 100).rounded())
            )
        }

        private static func routeName(from outputs: [AVAudioSessionPortDescription]) -> String {
            if let bluetooth = outputs.first(where: { $0.portType.isBluetoothOutput }) {
                return bluetooth.portName.isEmpty ? "Bluetooth" : bluetooth.portName
            }
            if let headphones = outputs.first(where: { $0.portType.isHeadphoneOutput }) {
                return headphones.portName.isEmpty ? "Headphones" : headphones.portName
            }
            if outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                return "Speaker"
            }
            if outputs.contains(where: { $0.portType == .builtInReceiver }) {
                return "Earpiece"
            }
            if let airPlay = outputs.first(where: { $0.portType == .airPlay }) {
                return airPlay.portName.isEmpty ? "AirPlay" : airPlay.portName
            }
            return "Audio"
        }
    }

    struct Connection: Codable, Equatable {
        let interface: CallNetworkInterface

        var displayName: String? {
            interface.displayName
        }
    }

    let audio: Audio?
    let connection: Connection?

    var hasVisibleContext: Bool {
        audio != nil || connection?.displayName != nil
    }

    static func current(
        includeAudio: Bool,
        networkInterface: CallNetworkInterface
    ) -> CallPeerTelemetry {
        CallPeerTelemetry(
            audio: includeAudio ? Audio.current() : nil,
            connection: networkInterface.displayName.map { _ in Connection(interface: networkInterface) }
        )
    }
}

struct ReceiverAudioReadinessSignalPayload: Codable, Equatable {
    let version: Int
    let reason: String
    let telemetry: CallPeerTelemetry?

    init(
        version: Int = 1,
        reason: String,
        telemetry: CallPeerTelemetry?
    ) {
        self.version = version
        self.reason = reason
        self.telemetry = telemetry
    }

    static func decode(from payload: String) -> ReceiverAudioReadinessSignalPayload {
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ReceiverAudioReadinessSignalPayload.self, from: data) else {
            return ReceiverAudioReadinessSignalPayload(reason: payload, telemetry: nil)
        }
        return decoded
    }

    func wirePayload() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let encoded = String(data: data, encoding: .utf8) else {
            return reason
        }
        return encoded
    }
}

private extension AVAudioSession.Port {
    var isBluetoothOutput: Bool {
        self == .bluetoothA2DP || self == .bluetoothHFP || self == .bluetoothLE
    }

    var isHeadphoneOutput: Bool {
        self == .headphones || self == .usbAudio || self == .carAudio
    }
}
