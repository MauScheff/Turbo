import Foundation
import UIKit
import UserNotifications

extension PTTViewModel {
    var pendingIncomingTalkRequestBadgeCount: Int {
        incomingInviteByContactID.count
    }

    func configureAlertNotificationsIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                let refreshedSettings = await center.notificationSettings()
                notificationAuthorizationStatus = refreshedSettings.authorizationStatus
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notification authorization resolved",
                    metadata: ["granted": granted ? "true" : "false"]
                )
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Alert notification authorization request failed",
                    metadata: ["error": error.localizedDescription]
                )
            }

        case .authorized, .ephemeral, .provisional:
            UIApplication.shared.registerForRemoteNotifications()

        case .denied:
            diagnostics.record(
                .pushToTalk,
                message: "Alert notifications denied",
                metadata: [:]
            )

        @unknown default:
            diagnostics.record(
                .pushToTalk,
                message: "Alert notification authorization unknown",
                metadata: ["status": "\(settings.authorizationStatus.rawValue)"]
            )
        }
    }

    func handleReceivedAlertPushToken(_ token: Data) {
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        alertPushTokenHex = tokenHex
        diagnostics.record(
            .pushToTalk,
            message: "Received alert push token",
            metadata: ["tokenPrefix": String(tokenHex.prefix(8))]
        )
        Task {
            await refreshDeviceRegistrationWithAlertPushTokenIfPossible()
        }
    }

    func handleFailedToRegisterForRemoteNotifications(_ error: Error) {
        diagnostics.record(
            .pushToTalk,
            level: .error,
            message: "Alert push token registration failed",
            metadata: ["error": error.localizedDescription]
        )
    }

    func handleForegroundTalkRequestNotification(userInfo: [AnyHashable: Any]) async {
        diagnostics.record(
            .pushToTalk,
            message: "Foreground talk request notification received",
            metadata: talkRequestNotificationDiagnostics(userInfo: userInfo)
        )
        await refreshInvites()
    }

    func handleTalkRequestNotificationResponse(userInfo: [AnyHashable: Any]) async {
        let metadata = talkRequestNotificationDiagnostics(userInfo: userInfo)
        diagnostics.record(
            .pushToTalk,
            message: "Talk request notification opened",
            metadata: metadata
        )
        await refreshInvites()
        guard let handle = talkRequestNotificationHandle(from: userInfo) else { return }
        if backendServices == nil {
            pendingTalkRequestNotificationHandle = handle
            diagnostics.record(
                .pushToTalk,
                message: "Queued talk request notification open until backend is ready",
                metadata: ["handle": handle]
            )
            return
        }
        await openContact(handle: handle)
    }

    func openPendingTalkRequestNotificationIfNeeded() async {
        guard let handle = pendingTalkRequestNotificationHandle else { return }
        pendingTalkRequestNotificationHandle = nil
        await openContact(handle: handle)
    }

    func refreshDeviceRegistrationWithAlertPushTokenIfPossible() async {
        guard let backend = backendServices else { return }
        do {
            _ = try await backend.registerDevice(
                label: UIDevice.current.name,
                alertPushToken: alertPushTokenHex.isEmpty ? nil : alertPushTokenHex
            )
            diagnostics.record(
                .backend,
                message: "Refreshed device registration with alert push token",
                metadata: ["tokenPrefix": String(alertPushTokenHex.prefix(8))]
            )
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Device registration refresh with alert push token failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func syncTalkRequestNotificationBadge(applicationState: UIApplication.State? = nil) {
        if (applicationState ?? currentApplicationState()) == .active {
            clearTalkRequestNotifications()
            return
        }

        setApplicationBadgeCount(pendingIncomingTalkRequestBadgeCount)
    }

    func clearTalkRequestNotifications() {
        setApplicationBadgeCount(0)
        clearDeliveredNotifications()
    }

    private func talkRequestNotificationHandle(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo["fromHandle"] as? String
    }

    private func talkRequestNotificationDiagnostics(userInfo: [AnyHashable: Any]) -> [String: String] {
        [
            "event": (userInfo["event"] as? String) ?? "unknown",
            "fromHandle": talkRequestNotificationHandle(from: userInfo) ?? "none",
            "inviteId": (userInfo["inviteId"] as? String) ?? "none",
            "channelId": (userInfo["channelId"] as? String) ?? "none",
        ]
    }
}
