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
                await self.publishActiveCallContextIfNeeded(reason: "network-change")
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
                await self?.publishActiveCallContextIfNeeded(reason: "poll")
                await self?.syncActiveCallTelemetryIfNeeded(reason: .telemetryRefresh)
            }
        }
    }

    func startCallTelemetryOutputVolumeObserver(audioSession: AVAudioSession = .sharedInstance()) {
        guard callTelemetryOutputVolumeObservation == nil else { return }
        callTelemetryOutputVolumeObservation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.currentLocalCallTelemetry(includeAudio: self.activeChannelId != nil)
                await self.publishActiveCallContextIfNeeded(reason: "volume-change")
                await self.syncActiveCallTelemetryIfNeeded(reason: .telemetryRefresh)
            }
        }
    }

    func syncActiveCallTelemetryIfNeeded(reason: ReceiverAudioReadinessReason) async {
        guard let contactID = activeChannelId else { return }
        let hasPublishedReceiverState = localReceiverAudioReadinessPublications[contactID] != nil
        guard desiredLocalReceiverAudioReadiness(for: contactID) || hasPublishedReceiverState else { return }
        await publishActiveCallContextIfNeeded(reason: reason.wireValue)
        await syncLocalReceiverAudioReadinessSignal(for: contactID, reason: reason)
    }

    func publishActiveCallContextIfNeeded(reason: String) async {
        guard let contactID = activeChannelId else { return }
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let backendChannelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId,
              let currentUserID = backend.currentUserID else {
            return
        }

        let telemetry = currentLocalCallTelemetry(
            includeAudio: desiredLocalReceiverAudioReadiness(for: contactID)
                || localReceiverAudioReadinessPublications[contactID] != nil
        )
        guard telemetry.hasVisibleContext else { return }
        guard lastPublishedCallContextByContactID[contactID] != telemetry else { return }
        guard let payloadData = try? JSONEncoder().encode(telemetry),
              let payload = String(data: payloadData, encoding: .utf8) else {
            return
        }

        let targetDeviceID = receiverAudioReadinessTargetDeviceID(for: contactID)
        do {
            try await backend.sendSignal(
                TurboSignalEnvelope(
                    type: .callContext,
                    channelId: backendChannelID,
                    fromUserId: currentUserID,
                    fromDeviceId: backend.deviceID,
                    toUserId: remoteUserID,
                    toDeviceId: targetDeviceID,
                    payload: payload
                )
            )
            lastPublishedCallContextByContactID[contactID] = telemetry
            diagnostics.record(
                .media,
                message: "Published call context",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "audioRoute": telemetry.audio?.routeName ?? "none",
                    "volumePercent": telemetry.audio.map { String($0.volumePercent) } ?? "none",
                    "network": telemetry.connection?.displayName ?? "none",
                ]
            )
        } catch {
            diagnostics.record(
                .media,
                message: "Failed to publish call context",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func applyPeerCallContextPayload(
        _ payload: String,
        for contactID: UUID,
        source: String
    ) {
        guard let data = payload.data(using: .utf8),
              let telemetry = try? JSONDecoder().decode(CallPeerTelemetry.self, from: data) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Ignored invalid peer call context",
                metadata: [
                    "contactId": contactID.uuidString,
                    "source": source,
                    "payloadLength": String(payload.count),
                ]
            )
            return
        }
        applyPeerCallTelemetry(telemetry, for: contactID, source: source)
    }
}
