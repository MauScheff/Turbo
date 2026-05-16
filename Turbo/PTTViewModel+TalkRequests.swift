import Foundation
import UIKit

extension PTTViewModel {
    var activeIncomingTalkRequest: IncomingTalkRequestSurface? {
        talkRequestSurfaceState.activeIncomingRequest
    }

    var pendingForegroundTalkRequestSurface: IncomingTalkRequestSurface? {
        talkRequestSurfaceState.pendingForegroundRequest
    }

    var pendingForegroundTalkRequestAcceptSurface: IncomingTalkRequestSurface? {
        talkRequestSurfaceState.pendingAcceptRequest
    }

    func reconcileTalkRequestSurface(
        applicationState: UIApplication.State? = nil,
        allowsSelectedContact: Bool = false,
        allowsAlreadySurfacedInvite: Bool = false
    ) {
        let resolvedApplicationState = applicationState ?? currentApplicationState()
        expirePendingForegroundTalkRequestSurfaceIfNeeded()
        let candidates: [IncomingTalkRequestCandidate] = contacts.compactMap { contact in
            guard contact.handle != currentDevUserHandle else { return nil }
            guard !talkRequestNotificationAlreadyHandled(for: contact.id) else { return nil }
            if let invite = incomingInviteByContactID[contact.id] {
                return IncomingTalkRequestCandidate(contact: contact, invite: invite)
            }
            let relationship = relationshipState(for: contact.id)
            guard relationship.isIncomingRequest else { return nil }
            return IncomingTalkRequestCandidate(
                contact: contact,
                requestCount: relationship.requestCount ?? 1,
                source: "relationship"
            )
        } + contacts.compactMap { contact in
            guard let pendingSurface = pendingForegroundTalkRequestSurface,
                  pendingSurface.contactID == contact.id,
                  pendingSurface.contactHandle == contact.handle,
                  contact.handle != currentDevUserHandle else {
                return nil
            }
            guard incomingInviteByContactID[contact.id] == nil else {
                clearPendingForegroundTalkRequestSurface(contactID: contact.id)
                return nil
            }
            let relationship = relationshipState(for: contact.id)
            guard !relationship.isIncomingRequest else {
                clearPendingForegroundTalkRequestSurface(contactID: contact.id)
                return nil
            }
            guard !talkRequestNotificationAlreadyHandled(for: contact.id) else {
                clearPendingForegroundTalkRequestSurface(contactID: contact.id)
                return nil
            }
            return IncomingTalkRequestCandidate(surface: pendingSurface)
        }

        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .invitesUpdated(
                candidates: candidates,
                selectedContactID: selectedContactId,
                applicationIsActive: resolvedApplicationState == .active,
                allowsSelectedContact: allowsSelectedContact,
                allowsAlreadySurfacedInvite: allowsAlreadySurfacedInvite
            )
        )
        completePendingForegroundTalkRequestAcceptIfReady(reason: "surface-reconcile")
    }

    func dismissIncomingTalkRequestSurface() {
        if let activeIncomingTalkRequest {
            clearPendingForegroundTalkRequestSurface(contactID: activeIncomingTalkRequest.contactID)
        }
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .incomingRequestDismissed
        )
    }

    func markTalkRequestSurfaceOpened(
        for contactID: UUID,
        inviteID: String?,
        requestCount: Int? = nil
    ) {
        clearPendingForegroundTalkRequestSurface(contactID: contactID, inviteID: inviteID)
        let resolvedRequestCount = requestCount ?? relationshipState(for: contactID).requestCount
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .contactOpened(
                contactID: contactID,
                inviteID: inviteID,
                requestCount: resolvedRequestCount
            )
        )
    }

    func acceptActiveIncomingTalkRequest() {
        guard let activeIncomingTalkRequest else {
            dismissIncomingTalkRequestSurface()
            return
        }
        acceptIncomingTalkRequestSurface(activeIncomingTalkRequest)
    }

    func acceptIncomingTalkRequestSurface(_ surface: IncomingTalkRequestSurface) {
        if talkRequestSurfaceState.isAccepting(surface) {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored repeated foreground talk request banner accept",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "inviteId": surface.inviteID,
                    "acceptIntentState": "in-flight",
                ]
            )
            return
        }
        guard !talkRequestNotificationAlreadyHandled(for: surface.contactID) else {
            markTalkRequestSurfaceOpened(
                for: surface.contactID,
                inviteID: surface.inviteID
            )
            diagnostics.record(
                .pushToTalk,
                message: "Ignored repeated foreground talk request banner accept",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "inviteId": surface.inviteID,
                    "acceptIntentState": "already-handled",
                ]
            )
            return
        }
        guard let contact = contacts.first(where: { $0.id == surface.contactID }) else {
            diagnostics.record(
                .pushToTalk,
                level: .notice,
                message: "Ignored foreground talk request banner accept without local contact",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "handle": surface.contactHandle,
                    "inviteId": surface.inviteID,
                ]
            )
            return
        }
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .incomingRequestAcceptStarted(surface)
        )
        markTalkRequestSurfaceOpened(
            for: surface.contactID,
            inviteID: surface.inviteID
        )
        diagnostics.record(
            .pushToTalk,
            message: "Foreground talk request banner accept tapped",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "inviteId": surface.inviteID,
                "requestCount": "\(surface.requestCount)",
                "acceptIntentState": "pending",
            ]
        )
        guard !completePendingForegroundTalkRequestAcceptIfReady(
            reason: "foreground-banner-accept"
        ) else {
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Queued foreground talk request banner accept until incoming request projects",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "inviteId": surface.inviteID,
                "relationship": String(describing: relationshipState(for: contact.id)),
            ]
        )
        Task { @MainActor [weak self] in
            await self?.resolvePendingForegroundTalkRequestAccept(surface)
        }
    }

    @discardableResult
    func completePendingForegroundTalkRequestAcceptIfReady(reason: String) -> Bool {
        guard let surface = pendingForegroundTalkRequestAcceptSurface else { return false }
        if talkRequestNotificationAlreadyHandled(for: surface.contactID) {
            finishPendingForegroundTalkRequestAccept(surface)
            markTalkRequestSurfaceOpened(for: surface.contactID, inviteID: surface.inviteID)
            diagnostics.record(
                .pushToTalk,
                message: "Completed pending foreground talk request banner accept from existing join intent",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "inviteId": surface.inviteID,
                    "reason": reason,
                ]
            )
            return true
        }
        guard let contact = contacts.first(where: { $0.id == surface.contactID }) else {
            finishPendingForegroundTalkRequestAccept(surface)
            diagnostics.record(
                .pushToTalk,
                level: .notice,
                message: "Dropped pending foreground talk request banner accept without local contact",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "handle": surface.contactHandle,
                    "inviteId": surface.inviteID,
                    "reason": reason,
                ]
            )
            return true
        }
        guard relationshipState(for: contact.id).isIncomingRequest else {
            return false
        }
        diagnostics.record(
            .pushToTalk,
            message: "Completing pending foreground talk request banner accept",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "inviteId": surface.inviteID,
                "requestCount": "\(surface.requestCount)",
                "reason": reason,
            ]
        )
        let didAccept = acceptIncomingTalkRequest(
            contact,
            reason: reason
        )
        guard didAccept else { return false }
        finishPendingForegroundTalkRequestAccept(surface)
        markTalkRequestSurfaceOpened(for: surface.contactID, inviteID: surface.inviteID)
        diagnostics.record(
            .pushToTalk,
            message: "Foreground talk request banner accepted",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "inviteId": surface.inviteID,
                "requestCount": "\(surface.requestCount)",
                "acceptIntentState": "completed",
            ]
        )
        return true
    }

    private func finishPendingForegroundTalkRequestAccept(_ surface: IncomingTalkRequestSurface) {
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .incomingRequestAcceptFinished(surface)
        )
    }

    private func resolvePendingForegroundTalkRequestAccept(
        _ surface: IncomingTalkRequestSurface
    ) async {
        let userInfo = foregroundTalkRequestUserInfo(from: surface)
        await refreshRequestStateAfterTalkRequestNotification(
            userInfo: userInfo,
            reason: "foreground-banner-accept"
        )
        guard !completePendingForegroundTalkRequestAcceptIfReady(
            reason: "foreground-banner-accept-refreshed"
        ) else {
            return
        }
        try? await Task.sleep(nanoseconds: 750_000_000)
        await refreshRequestStateAfterTalkRequestNotification(
            userInfo: userInfo,
            reason: "foreground-banner-accept-retry"
        )
        guard !completePendingForegroundTalkRequestAcceptIfReady(
            reason: "foreground-banner-accept-retry"
        ) else {
            return
        }
        if pendingForegroundTalkRequestAcceptSurface?.requestKey == surface.requestKey {
            finishPendingForegroundTalkRequestAccept(surface)
        }
        diagnostics.record(
            .pushToTalk,
            level: .notice,
            message: "Pending foreground talk request banner accept is still waiting for incoming request projection",
            metadata: [
                "contactId": surface.contactID.uuidString,
                "handle": surface.contactHandle,
                "inviteId": surface.inviteID,
                "relationship": contacts.first(where: { $0.id == surface.contactID })
                    .map { String(describing: relationshipState(for: $0.id)) } ?? "missing-contact",
            ]
        )
    }

    private func foregroundTalkRequestUserInfo(
        from surface: IncomingTalkRequestSurface
    ) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "event": "talk-request",
            "fromHandle": surface.contactHandle,
            "inviteId": surface.inviteID,
        ]
        if let channelID = surface.channelID {
            userInfo["channelId"] = channelID
        }
        if let userIntent = surface.userIntent {
            userInfo["userIntent"] = userIntent
        }
        if let sentAt = surface.sentAt {
            userInfo["sentAt"] = sentAt
        }
        return userInfo
    }

    func openActiveIncomingTalkRequest() {
        acceptActiveIncomingTalkRequest()
    }

    func queuePendingForegroundTalkRequestSurface(
        for contact: Contact,
        inviteID: String,
        requestCount: Int,
        userIntent: String? = nil,
        sentAt: String? = nil,
        reason: String
    ) {
        let normalizedRequestCount = max(requestCount, 1)
        let surface = IncomingTalkRequestSurface(
            contactID: contact.id,
            inviteID: inviteID,
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            requestCount: normalizedRequestCount,
            recencyKey: "notification:\(normalizedRequestCount):\(inviteID)",
            channelID: contact.backendChannelId,
            userIntent: userIntent,
            sentAt: sentAt
        )
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .pendingForegroundRequestQueued(
                surface: surface,
                receivedAt: Date()
            )
        )
        diagnostics.record(
            .pushToTalk,
            message: "Queued pending foreground talk request surface from notification",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "inviteId": inviteID,
                "reason": reason,
                "requestCount": "\(normalizedRequestCount)",
            ]
        )
    }

    func clearPendingForegroundTalkRequestSurface(contactID: UUID? = nil, inviteID: String? = nil) {
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .pendingForegroundRequestCleared(contactID: contactID, inviteID: inviteID)
        )
    }

    func expirePendingForegroundTalkRequestSurfaceIfNeeded(now: Date = Date()) {
        guard let receivedAt = talkRequestSurfaceState.pendingForegroundRequestReceivedAt,
              let pendingSurface = pendingForegroundTalkRequestSurface else {
            return
        }
        guard now.timeIntervalSince(receivedAt) >= pendingForegroundTalkRequestLifetime else {
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Expired pending foreground talk request surface",
            metadata: [
                "contactId": pendingSurface.contactID.uuidString,
                "handle": pendingSurface.contactHandle,
                "inviteId": pendingSurface.inviteID,
            ]
        )
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .pendingForegroundRequestExpired(
                now: now,
                lifetime: pendingForegroundTalkRequestLifetime
            )
        )
    }

    @discardableResult
    func acceptIncomingTalkRequest(
        _ contact: Contact,
        reason: String,
        allowsJoin: Bool = true
    ) -> Bool {
        selectContact(contact, reason: reason)
        let relationship = relationshipState(for: contact.id)
        guard relationship.isIncomingRequest else {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored talk request accept without incoming request",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                    "relationship": String(describing: relationship),
                ]
            )
            return false
        }
        guard contact.isOnline else {
            return false
        }
        if requestedExpandedCallContactID != contact.id {
            requestExpandedCall(for: contact)
        }
        guard allowsJoin else {
            return false
        }
        performConnect(to: contact, intent: .requestConnection)
        return true
    }
}
