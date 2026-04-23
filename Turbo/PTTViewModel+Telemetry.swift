import Foundation
import UIKit

extension PTTViewModel {
    func handleHighSignalDiagnosticsEvent(_ event: DiagnosticsHighSignalEvent) {
        switch event {
        case .errorEntry(let entry):
            sendTelemetryEvent(
                eventName: "ios.error.\(entry.subsystem.rawValue)",
                severity: TurboTelemetrySeverity(diagnosticsLevel: entry.level),
                phase: diagnosticsStateFields["selectedPeerPhase"],
                reason: entry.subsystem.rawValue,
                message: entry.message,
                invariantID: entry.metadata["invariantID"],
                metadata: entry.metadata,
                alert: shouldAlertForDiagnosticsEntry(entry)
            )
        case .invariantViolation(let violation):
            sendTelemetryEvent(
                eventName: "ios.invariant.violation",
                severity: .error,
                phase: diagnosticsStateFields["selectedPeerPhase"],
                reason: violation.scope.rawValue,
                message: violation.message,
                invariantID: violation.invariantID,
                metadata: violation.metadata,
                alert: true
            )
        }
    }

    func sendTelemetryEvent(
        eventName: String,
        severity: TurboTelemetrySeverity = .info,
        phase: String? = nil,
        reason: String? = nil,
        message: String? = nil,
        invariantID: String? = nil,
        metadata: [String: String] = [:],
        alert: Bool = false,
        peerHandle: String? = nil,
        channelId: String? = nil
    ) {
        guard let backend = backendServices, backend.telemetryEnabled else { return }
        let payload = TurboTelemetryEventRequest(
            eventName: eventName,
            source: "ios",
            severity: severity.rawValue,
            userId: backend.currentUserID,
            userHandle: currentDevUserHandle,
            deviceId: backend.deviceID,
            sessionId: nil,
            channelId: channelId ?? selectedContact?.backendChannelId,
            peerUserId: selectedContact?.remoteUserId,
            peerHandle: peerHandle ?? selectedContact?.handle,
            appVersion: appVersionDescription,
            backendVersion: nil,
            invariantId: invariantID,
            phase: phase ?? diagnosticsStateFields["selectedPeerPhase"],
            reason: reason,
            message: message,
            metadata: baseTelemetryMetadata().merging(metadata, uniquingKeysWith: { _, new in new }),
            devTraffic: isDevTelemetryTraffic,
            alert: alert
        )

        Task { @MainActor [weak self] in
            do {
                _ = try await backend.uploadTelemetry(payload)
            } catch {
                self?.diagnostics.record(
                    .app,
                    level: .notice,
                    message: "Telemetry upload failed",
                    metadata: [
                        "eventName": eventName,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    private func baseTelemetryMetadata() -> [String: String] {
        [
            "applicationState": String(describing: currentApplicationState()),
            "backendMode": backendRuntime.mode,
            "isJoined": String(isJoined),
            "isTransmitting": String(isTransmitting),
            "selectedHandle": selectedContact?.handle ?? "none",
            "iosVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model,
        ]
    }

    private func shouldAlertForDiagnosticsEntry(_ entry: DiagnosticsEntry) -> Bool {
        switch entry.subsystem {
        case .selfCheck:
            return false
        default:
            return entry.level == .error
        }
    }

    private var isDevTelemetryTraffic: Bool {
#if DEBUG
        true
#else
        backendRuntime.mode != "cloud"
#endif
    }
}
