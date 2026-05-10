import AVFAudio
import Foundation
import Network

extension PTTViewModel {
    func callPeerTelemetry(for contactID: UUID) -> CallPeerTelemetry? {
        callPeerTelemetryByContactID[contactID]
    }

    func currentLocalCallTelemetry(includeAudio: Bool) -> CallPeerTelemetry {
        let telemetry = CallPeerTelemetry.current(
            includeAudio: includeAudio,
            networkInterface: localCallNetworkInterface
        )
        if localCallTelemetry != telemetry {
            localCallTelemetry = telemetry
        }
        return telemetry
    }

    func applyPeerCallTelemetry(
        _ telemetry: CallPeerTelemetry?,
        for contactID: UUID,
        source: String
    ) {
        guard let telemetry else { return }
        guard callPeerTelemetryByContactID[contactID] != telemetry else { return }
        callPeerTelemetryByContactID[contactID] = telemetry
        diagnostics.record(
            .media,
            message: "Updated peer call telemetry",
            metadata: [
                "contactId": contactID.uuidString,
                "source": source,
                "audioRoute": telemetry.audio?.routeName ?? "none",
                "volumePercent": telemetry.audio.map { String($0.volumePercent) } ?? "none",
                "network": telemetry.connection?.displayName ?? "none",
            ]
        )
    }

    func startCallTelemetryNetworkMonitor() {
        guard callTelemetryNetworkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interface = CallNetworkInterface.from(path: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.localCallNetworkInterface != interface else { return }
                self.localCallNetworkInterface = interface
                _ = self.currentLocalCallTelemetry(includeAudio: self.activeChannelId != nil)
                await self.syncActiveCallTelemetryIfNeeded(reason: .networkChange)
            }
        }
        callTelemetryNetworkMonitor = monitor
        monitor.start(queue: callTelemetryNetworkQueue)
    }

    func startCallTelemetryPolling() {
        guard callTelemetryPollTask == nil else { return }
        callTelemetryPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                _ = self?.currentLocalCallTelemetry(includeAudio: self?.activeChannelId != nil)
                await self?.syncActiveCallTelemetryIfNeeded(reason: .telemetryRefresh)
            }
        }
    }

    func syncActiveCallTelemetryIfNeeded(reason: ReceiverAudioReadinessReason) async {
        guard let contactID = activeChannelId else { return }
        let hasPublishedReceiverState = localReceiverAudioReadinessPublications[contactID] != nil
        guard desiredLocalReceiverAudioReadiness(for: contactID) || hasPublishedReceiverState else { return }
        await syncLocalReceiverAudioReadinessSignal(for: contactID, reason: reason)
    }
}
