import Foundation
import UIKit
import UserNotifications

enum AlertNotificationPermissionAction: Equatable {
    case observeOnly
    case requestAuthorization
    case registerForRemoteNotifications
}

enum AlertNotificationPermissionPolicy {
    static func startupAction(for status: UNAuthorizationStatus) -> AlertNotificationPermissionAction {
        switch status {
        case .authorized, .ephemeral, .provisional:
            return .registerForRemoteNotifications
        case .notDetermined, .denied:
            return .observeOnly
        @unknown default:
            return .observeOnly
        }
    }

    static func explicitRequestAction(for status: UNAuthorizationStatus) -> AlertNotificationPermissionAction {
        switch status {
        case .notDetermined:
            return .requestAuthorization
        case .authorized, .ephemeral, .provisional:
            return .registerForRemoteNotifications
        case .denied:
            return .observeOnly
        @unknown default:
            return .observeOnly
        }
    }
}

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
        guard hasLoadedNotificationAuthorizationStatus else {
            return false
        }

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
        hasLoadedNotificationAuthorizationStatus = true

        switch AlertNotificationPermissionPolicy.startupAction(for: settings.authorizationStatus) {
        case .registerForRemoteNotifications:
            UIApplication.shared.registerForRemoteNotifications()

        case .observeOnly:
            switch settings.authorizationStatus {
            case .notDetermined:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notification authorization not requested yet",
                    metadata: ["requestPolicy": "deferred-until-user-action"]
                )

            case .denied:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notifications denied",
                    metadata: [:]
                )

            case .authorized, .ephemeral, .provisional:
                break

            @unknown default:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notification authorization unknown",
                    metadata: ["status": "\(settings.authorizationStatus.rawValue)"]
                )
            }

        case .requestAuthorization:
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Startup notification policy attempted to request authorization",
                metadata: ["status": "\(settings.authorizationStatus.rawValue)"]
            )
        }
    }

    func requestAlertNotificationPermissionPreflight() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
        hasLoadedNotificationAuthorizationStatus = true

        switch AlertNotificationPermissionPolicy.explicitRequestAction(for: settings.authorizationStatus) {
        case .requestAuthorization:
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

        case .registerForRemoteNotifications:
            UIApplication.shared.registerForRemoteNotifications()

        case .observeOnly:
            switch settings.authorizationStatus {
            case .denied:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notifications denied",
                    metadata: [:]
                )

            case .notDetermined, .authorized, .ephemeral, .provisional:
                break

            @unknown default:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notification authorization unknown",
                    metadata: ["status": "\(settings.authorizationStatus.rawValue)"]
                )
            }
        }

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
        clearTalkRequestNotifications()
        diagnostics.record(
            .pushToTalk,
            message: "Foreground talk request notification received",
            metadata: talkRequestNotificationDiagnostics(userInfo: userInfo)
        )
        if let handle = talkRequestNotificationHandle(from: userInfo),
           let contact = openCachedTalkRequestContactFromNotification(
               handle: handle,
               reason: "foreground-notification-immediate"
           ) {
            maybeQueuePendingForegroundTalkRequestSurface(
                contact: contact,
                userInfo: userInfo,
                reason: "foreground-notification-immediate"
            )
        }
        await refreshRequestStateAfterTalkRequestNotification(userInfo: userInfo, reason: "foreground-notification")
        reconcileTalkRequestSurface(
            applicationState: .active,
            allowsSelectedContact: true,
            allowsAlreadySurfacedInvite: true
        )
        await prewarmForegroundTalkRequestNotificationContactIfIdle(
            userInfo: userInfo,
            reason: "foreground-notification"
        )
    }

    func handleTalkRequestNotificationResponse(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) async {
        switch actionIdentifier {
        case TurboNotificationCategory.acceptTalkRequestAction:
            await handleTalkRequestNotificationAcceptResponse(userInfo: userInfo)
        case TurboNotificationCategory.notNowTalkRequestAction:
            await handleTalkRequestNotificationNotNowResponse(userInfo: userInfo)
        default:
            await handleTalkRequestNotificationResponse(userInfo: userInfo)
        }
    }

    func handleTalkRequestNotificationResponse(userInfo: [AnyHashable: Any]) async {
        let metadata = talkRequestNotificationDiagnostics(userInfo: userInfo)
        clearTalkRequestNotifications()
        diagnostics.record(
            .pushToTalk,
            message: "Talk request notification opened",
            metadata: metadata
        )
        await openTalkRequestNotification(
            userInfo: userInfo,
            reason: "notification-open",
            shouldAccept: true
        )
    }

    func handleTalkRequestNotificationAcceptResponse(userInfo: [AnyHashable: Any]) async {
        let metadata = talkRequestNotificationDiagnostics(userInfo: userInfo)
        clearTalkRequestNotifications()
        diagnostics.record(
            .pushToTalk,
            message: "Talk request notification accepted",
            metadata: metadata
        )
        await openTalkRequestNotification(
            userInfo: userInfo,
            reason: "notification-accept",
            shouldAccept: true
        )
    }

    func handleTalkRequestNotificationNotNowResponse(userInfo: [AnyHashable: Any]) async {
        let metadata = talkRequestNotificationDiagnostics(userInfo: userInfo)
        clearTalkRequestNotifications()
        diagnostics.record(
            .pushToTalk,
            message: "Talk request notification declined",
            metadata: metadata
        )
        await refreshContactSummaries()
        await refreshInvites()

        guard let backend = backendServices else {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Cannot decline talk request notification before backend is ready",
                metadata: metadata
            )
            return
        }

        let inviteID = (userInfo["inviteId"] as? String)
            ?? talkRequestNotificationHandle(from: userInfo)
                .flatMap { contactMatchingNormalizedHandle($0) }
                .flatMap { incomingInviteByContactID[$0.id]?.inviteId }
        guard let inviteID else {
            diagnostics.record(
                .pushToTalk,
                level: .notice,
                message: "Cannot decline talk request notification without invite",
                metadata: metadata
            )
            return
        }

        do {
            if let handle = talkRequestNotificationHandle(from: userInfo),
               let contact = contactMatchingNormalizedHandle(handle) {
                markIncomingRequestHandledLocally(
                    contactID: contact.id,
                    invite: incomingInviteByContactID[contact.id],
                    relationship: relationshipState(for: contact.id),
                    reason: "decline-notification"
                )
            }
            _ = try await backend.declineInvite(inviteId: inviteID)
            await refreshInvites()
            await refreshContactSummaries()
            clearTalkRequestNotifications()
            if let handle = talkRequestNotificationHandle(from: userInfo),
               let contact = contactMatchingNormalizedHandle(handle) {
                markTalkRequestSurfaceOpened(for: contact.id, inviteID: inviteID)
            }
            captureDiagnosticsState("talk-request:notification-not-now")
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Decline talk request notification failed",
                metadata: metadata.merging(
                    ["error": error.localizedDescription],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
    }

    func openTalkRequestNotification(
        userInfo: [AnyHashable: Any],
        reason: String,
        shouldAccept: Bool
    ) async {
        guard let handle = talkRequestNotificationHandle(from: userInfo) else { return }
        let immediateContact = openCachedTalkRequestContactFromNotification(
            handle: handle,
            reason: "\(reason)-immediate"
        )
        let joinedFromCachedIncomingRequest = shouldAccept
            && backendServices != nil
            && immediateContact.map {
                acceptIncomingTalkRequest(
                    $0,
                    reason: "\(reason)-cached-accept",
                    allowsJoin: true
                )
            } == true
        await refreshRequestStateAfterTalkRequestNotification(userInfo: userInfo, reason: reason)
        if let openedContact = contactMatchingNormalizedHandle(handle) ?? immediateContact {
            markTalkRequestSurfaceOpened(
                for: openedContact.id,
                inviteID: userInfo["inviteId"] as? String,
                requestCount: relationshipState(for: openedContact.id).requestCount
            )
        }
        if joinedFromCachedIncomingRequest {
            return
        }
        let shouldJoin = openTalkRequestFromNotification(
            handle: handle,
            reason: reason,
            allowsJoin: shouldAccept && backendServices != nil,
            cachedContact: immediateContact
        )
        if backendServices == nil {
            pendingTalkRequestNotificationHandle = handle
            pendingTalkRequestNotificationShouldJoin = shouldAccept
            diagnostics.record(
                .pushToTalk,
                message: "Queued talk request notification open until backend is ready",
                metadata: ["handle": handle, "shouldAccept": String(shouldAccept)]
            )
            return
        }
        if shouldAccept && !shouldJoin {
            await openContact(reference: handle)
        }
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
                clearPendingForegroundTalkRequestSurface(contactID: contact.id)
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
            maybeQueuePendingForegroundTalkRequestSurface(
                contact: contact,
                userInfo: userInfo,
                reason: reason
            )
            recordTalkRequestProjectionInvariant(
                handle: handle,
                reason: reason,
                message: "foreground talk-request notification was not projected as an incoming request after request-state refresh"
            )
            scheduleTalkRequestProjectionRecovery(userInfo: userInfo, reason: reason)
            return
        }

        clearPendingForegroundTalkRequestSurface(
            contactID: contact.id,
            inviteID: (userInfo["inviteId"] as? String)
        )
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
        let shouldJoin = pendingTalkRequestNotificationShouldJoin
        pendingTalkRequestNotificationShouldJoin = false
        await refreshRequestStateAfterTalkRequestNotification(
            userInfo: ["event": "talk-request", "fromHandle": handle],
            reason: "pending-notification-open"
        )
        let didJoin = openTalkRequestFromNotification(
            handle: handle,
            reason: "pending-notification-open",
            allowsJoin: shouldJoin
        )
        if !didJoin {
            await openContact(reference: handle)
        }
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

    @discardableResult
    private func openTalkRequestFromNotification(
        handle: String,
        reason: String,
        allowsJoin: Bool = true,
        cachedContact: Contact? = nil
    ) -> Bool {
        guard let contact = contactMatchingNormalizedHandle(handle) ?? cachedContact else {
            return false
        }

        diagnostics.record(
            .pushToTalk,
            message: allowsJoin
                ? "Accepting talk request from notification"
                : "Opening talk request from notification",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        return acceptIncomingTalkRequest(
            contact,
            reason: reason,
            allowsJoin: allowsJoin
        )
    }

    @discardableResult
    private func openCachedTalkRequestContactFromNotification(
        handle: String,
        reason: String
    ) -> Contact? {
        guard let contact = contactMatchingNormalizedHandle(handle) else {
            return nil
        }
        openCachedTalkRequestContact(contact, reason: reason)
        return contact
    }

    private func openCachedTalkRequestContact(_ contact: Contact, reason: String) {
        diagnostics.record(
            .pushToTalk,
            message: "Selected contact from talk request notification",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        selectContact(contact, reason: reason)
        let relationship = relationshipState(for: contact.id)
        guard relationship.isIncomingRequest else {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored cached talk request notification expansion without incoming request",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                    "relationship": String(describing: relationship),
                ]
            )
            return
        }
        guard contact.isOnline else {
            return
        }
        requestExpandedCall(for: contact)
    }

    private func maybeQueuePendingForegroundTalkRequestSurface(
        contact: Contact,
        userInfo: [AnyHashable: Any],
        reason: String
    ) {
        guard !relationshipState(for: contact.id).isIncomingRequest else {
            clearPendingForegroundTalkRequestSurface(contactID: contact.id)
            return
        }
        guard !talkRequestNotificationAlreadyHandled(for: contact.id) else {
            clearPendingForegroundTalkRequestSurface(contactID: contact.id)
            return
        }
        guard let inviteID = userInfo["inviteId"] as? String, !inviteID.isEmpty else {
            return
        }
        let requestCount = incomingInviteByContactID[contact.id]?.requestCount
            ?? relationshipState(for: contact.id).requestCount
            ?? 1
        queuePendingForegroundTalkRequestSurface(
            for: contact,
            inviteID: inviteID,
            requestCount: requestCount,
            userIntent: userInfo["userIntent"] as? String,
            sentAt: (userInfo["sentAt"] as? String) ?? (userInfo["createdAt"] as? String),
            reason: reason
        )
    }

    func requestExpandedCall(for contact: Contact) {
        requestedExpandedCallContactID = contact.id
        requestedExpandedCallSequence += 1
    }

    private func talkRequestNotificationDiagnostics(userInfo: [AnyHashable: Any]) -> [String: String] {
        [
            "event": (userInfo["event"] as? String) ?? "unknown",
            "fromHandle": talkRequestNotificationHandle(from: userInfo) ?? "none",
            "inviteId": (userInfo["inviteId"] as? String) ?? "none",
            "channelId": (userInfo["channelId"] as? String) ?? "none",
            "userIntent": (userInfo["userIntent"] as? String) ?? "none",
            "sentAt": ((userInfo["sentAt"] as? String) ?? (userInfo["createdAt"] as? String)) ?? "none",
            "deepLink": (userInfo["deepLink"] as? String) ?? "none",
        ]
    }

    private func prewarmForegroundTalkRequestNotificationContactIfIdle(
        userInfo: [AnyHashable: Any],
        reason: String
    ) async {
        guard let handle = talkRequestNotificationHandle(from: userInfo),
              let contact = contactMatchingNormalizedHandle(handle) else {
            return
        }
        let inviteID = (userInfo["inviteId"] as? String)
            ?? incomingInviteByContactID[contact.id]?.inviteId
        guard relationshipState(for: contact.id).isIncomingRequest else { return }
        if let inviteID,
           foregroundTalkRequestNotificationPrewarmedInviteIDs.contains(inviteID) {
            diagnostics.record(
                .media,
                message: "Foreground talk request notification prewarm skipped",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "inviteId": inviteID,
                    "reason": reason,
                    "blockReason": "duplicate-invite",
                ]
            )
            return
        }
        guard foregroundTalkRequestNotificationPrewarmBlockReason(for: contact.id) == nil else {
            diagnostics.record(
                .media,
                message: "Foreground talk request notification prewarm skipped",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "inviteId": inviteID ?? "none",
                    "reason": reason,
                    "blockReason": foregroundTalkRequestNotificationPrewarmBlockReason(for: contact.id) ?? "unknown",
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Foreground talk request notification prewarm started",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "inviteId": inviteID ?? "none",
                "reason": reason,
            ]
        )

        precreateSelectedContactMediaShellIfNeeded(
            for: contact.id,
            reason: reason
        )
        await publishSelectedPeerPrewarmHintIfPossible(
            for: contact.id,
            reason: reason
        )
        await prewarmForegroundTalkRequestDirectQuicIfPossible(
            for: contact.id,
            reason: reason
        )

        diagnostics.record(
            .media,
            message: "Foreground talk request notification prewarm completed",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "inviteId": inviteID ?? "none",
                "reason": reason,
            ]
        )
        if let inviteID {
            foregroundTalkRequestNotificationPrewarmedInviteIDs.insert(inviteID)
        }
    }

    private func foregroundTalkRequestNotificationPrewarmBlockReason(for contactID: UUID) -> String? {
        if isJoined || activeChannelId != nil {
            return "active-channel"
        }
        if mediaSessionContactID != nil || isPTTAudioSessionActive {
            return "active-media-session"
        }
        if isTransmitting || transmitCoordinator.state.isPressingTalk {
            return "active-transmit"
        }
        guard contacts.contains(where: { $0.id == contactID }) else {
            return "contact-missing"
        }
        return nil
    }

    private func prewarmForegroundTalkRequestDirectQuicIfPossible(
        for contactID: UUID,
        reason: String
    ) async {
        let prewarmReason = "foreground-notification-direct-quic-prewarm-\(reason)"
        if let blockReason = directQuicSelectionPrewarmBlockReason(
            for: contactID,
            requireSelectedContact: false
        ) {
            if blockReason == "relay-only-forced" {
                return
            }
            diagnostics.record(
                .media,
                message: "Foreground talk request Direct QUIC prewarm skipped",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": blockReason,
                ]
            )
            if blockReason == "not-listener-offerer" {
                await requestRemoteDirectQuicOfferIfPossible(
                    for: contactID,
                    reason: prewarmReason
                )
            }
            return
        }

        diagnostics.record(
            .media,
            message: "Foreground talk request Direct QUIC prewarm requested",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
            ]
        )
        await maybeStartDirectQuicProbe(for: contactID)
    }
}
