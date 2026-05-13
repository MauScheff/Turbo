import Foundation
import UIKit

extension PTTViewModel {
    var activeIncomingTalkRequest: IncomingTalkRequestSurface? {
        talkRequestSurfaceState.activeIncomingRequest
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

    func markTalkRequestSurfaceOpened(for contactID: UUID, inviteID: String?) {
        clearPendingForegroundTalkRequestSurface(contactID: contactID, inviteID: inviteID)
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .contactOpened(contactID: contactID, inviteID: inviteID)
        )
    }

    func acceptActiveIncomingTalkRequest() {
        guard let activeIncomingTalkRequest,
              let contact = contacts.first(where: { $0.id == activeIncomingTalkRequest.contactID }) else {
            dismissIncomingTalkRequestSurface()
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Foreground talk request banner accepted",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "inviteId": activeIncomingTalkRequest.inviteID,
                "requestCount": "\(activeIncomingTalkRequest.requestCount)",
            ]
        )
        acceptIncomingTalkRequest(
            contact,
            reason: "foreground-banner-accept"
        )
    }

    func openActiveIncomingTalkRequest() {
        acceptActiveIncomingTalkRequest()
    }

    func queuePendingForegroundTalkRequestSurface(
        for contact: Contact,
        inviteID: String,
        requestCount: Int,
        reason: String
    ) {
        let normalizedRequestCount = max(requestCount, 1)
        pendingForegroundTalkRequestSurface = IncomingTalkRequestSurface(
            contactID: contact.id,
            inviteID: inviteID,
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            requestCount: normalizedRequestCount,
            recencyKey: "notification:\(normalizedRequestCount):\(inviteID)"
        )
        pendingForegroundTalkRequestReceivedAt = Date()
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
        guard let pendingSurface = pendingForegroundTalkRequestSurface else { return }
        if let contactID, pendingSurface.contactID != contactID {
            return
        }
        if let inviteID, pendingSurface.inviteID != inviteID {
            return
        }
        pendingForegroundTalkRequestSurface = nil
        pendingForegroundTalkRequestReceivedAt = nil
    }

    func expirePendingForegroundTalkRequestSurfaceIfNeeded(now: Date = Date()) {
        guard let receivedAt = pendingForegroundTalkRequestReceivedAt,
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
        clearPendingForegroundTalkRequestSurface()
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
