import Foundation
import UIKit
import UserNotifications

extension PTTViewModel {
    var pendingIncomingTalkRequestBadgeCount: Int {
        incomingInviteByContactID.count
    }

    var alertNotificationAuthorizationStatusText: String {
        switch notificationAuthorizationStatus {
        case .notDetermined:
            return "Push notifications not requested"
        case .denied:
            return "Push notifications denied"
        case .authorized:
            return "Push notifications enabled"
        case .provisional:
            return "Push notifications provisional"
        case .ephemeral:
            return "Push notifications ephemeral"
        @unknown default:
            return "Push notifications unknown"
        }
    }

    var needsAlertNotificationPermission: Bool {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return false
        case .notDetermined, .denied:
            return true
        @unknown default:
            return true
        }
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

    func requestAlertNotificationPermissionPreflight() async {
        await configureAlertNotificationsIfNeeded()
        captureDiagnosticsState("alert-notification-permission")
    }

    func requestLocalNetworkPermissionPreflight() async {
        await localNetworkPermissionPreflight.run(
            diagnostics: diagnostics,
            stateDidChange: { [weak self] status in
                self?.localNetworkPreflightStatus = status
            }
        )
        captureDiagnosticsState("local-network-permission")
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
        await refreshRequestStateAfterTalkRequestNotification(userInfo: userInfo, reason: "foreground-notification")
    }

    func handleTalkRequestNotificationResponse(userInfo: [AnyHashable: Any]) async {
        let metadata = talkRequestNotificationDiagnostics(userInfo: userInfo)
        diagnostics.record(
            .pushToTalk,
            message: "Talk request notification opened",
            metadata: metadata
        )
        await refreshRequestStateAfterTalkRequestNotification(userInfo: userInfo, reason: "notification-open")
        guard let handle = talkRequestNotificationHandle(from: userInfo) else { return }
        selectContactMatchingNotificationHandle(handle, reason: "notification-open")
        if backendServices == nil {
            pendingTalkRequestNotificationHandle = handle
            diagnostics.record(
                .pushToTalk,
                message: "Queued talk request notification open until backend is ready",
                metadata: ["handle": handle]
            )
            return
        }
        await openContact(reference: handle)
    }

    func refreshRequestStateAfterTalkRequestNotification(
        userInfo: [AnyHashable: Any],
        reason: String
    ) async {
        await refreshContactSummaries()
        await refreshInvites()
        captureDiagnosticsState("talk-request:\(reason):request-state-refreshed")

        guard let handle = talkRequestNotificationHandle(from: userInfo) else { return }
        guard let contact = contactMatchingNormalizedHandle(handle) else {
            recordTalkRequestProjectionInvariant(
                handle: handle,
                reason: reason,
                message: "foreground talk-request notification did not resolve to a local contact after request-state refresh"
            )
            scheduleTalkRequestProjectionRecovery(userInfo: userInfo, reason: reason)
            return
        }

        guard relationshipState(for: contact.id).isIncomingRequest else {
            guard !talkRequestNotificationAlreadyHandled(for: contact.id) else {
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored stale foreground talk request notification after request was already handled",
                    metadata: [
                        "handle": handle,
                        "reason": reason,
                        "pendingAction": String(describing: sessionCoordinator.pendingAction),
                        "isJoined": String(isJoined && activeChannelId == contact.id),
                        "backendSelfJoined": String(selectedChannelSnapshot(for: contact.id)?.membership.hasLocalMembership ?? false),
                    ]
                )
                return
            }
            recordTalkRequestProjectionInvariant(
                handle: handle,
                reason: reason,
                message: "foreground talk-request notification was not projected as an incoming request after request-state refresh"
            )
            scheduleTalkRequestProjectionRecovery(userInfo: userInfo, reason: reason)
            return
        }
    }

    func talkRequestNotificationAlreadyHandled(for contactID: UUID) -> Bool {
        if sessionCoordinator.pendingAction.pendingConnectContactID == contactID {
            return true
        }
        if isJoined, activeChannelId == contactID {
            return true
        }
        if selectedChannelSnapshot(for: contactID)?.membership.hasLocalMembership == true {
            return true
        }
        return false
    }

    private func scheduleTalkRequestProjectionRecovery(
        userInfo: [AnyHashable: Any],
        reason: String
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self else { return }
            await self.refreshContactSummaries()
            await self.refreshInvites()
            self.captureDiagnosticsState("talk-request:\(reason):projection-recovery")
        }
    }

    private func recordTalkRequestProjectionInvariant(
        handle: String,
        reason: String,
        message: String
    ) {
        diagnostics.recordInvariantViolation(
            invariantID: "request.foreground_notification_not_projected",
            scope: .local,
            message: message,
            metadata: [
                "handle": handle,
                "reason": reason,
                "selectedContact": selectedContact?.handle ?? "none",
                "selectedPeerRelationship": selectedSessionDiagnosticsSummary.relationship,
            ]
        )
    }

    private func contactMatchingNormalizedHandle(_ handle: String) -> Contact? {
        let normalizedHandle = Contact.normalizedHandle(handle)
        return contacts.first { Contact.normalizedHandle($0.handle) == normalizedHandle }
    }

    func openPendingTalkRequestNotificationIfNeeded() async {
        guard let handle = pendingTalkRequestNotificationHandle else { return }
        pendingTalkRequestNotificationHandle = nil
        selectContactMatchingNotificationHandle(handle, reason: "pending-notification-open")
        await openContact(reference: handle)
    }

    func refreshDeviceRegistrationWithAlertPushTokenIfPossible() async {
        guard let backend = backendServices else { return }
        do {
            _ = try await backend.registerDevice(
                label: UIDevice.current.name,
                alertPushToken: alertPushTokenHex.isEmpty ? nil : alertPushTokenHex,
                alertPushEnvironment: alertPushTokenHex.isEmpty
                    ? nil
                    : TurboAPNSEnvironmentResolver.current(),
                directQuicIdentity: currentDirectQuicIdentityRegistrationMetadata(),
                mediaEncryptionIdentity: currentMediaEncryptionIdentityRegistrationMetadata()
            )
            diagnostics.record(
                .backend,
                message: "Refreshed device registration with alert push token",
                metadata: [
                    "tokenPrefix": String(alertPushTokenHex.prefix(8)),
                    "apnsEnvironment": TurboAPNSEnvironmentResolver.current().rawValue,
                ]
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
