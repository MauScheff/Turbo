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
        talkRequestSurfaceState = TalkRequestSurfaceReducer.reduce(
            state: talkRequestSurfaceState,
            event: .incomingRequestDismissed
        )
    }

    func markTalkRequestSurfaceOpened(for contactID: UUID, inviteID: String?) {
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
        acceptIncomingTalkRequest(
            contact,
            reason: "foreground-banner-accept"
        )
    }

    func openActiveIncomingTalkRequest() {
        acceptActiveIncomingTalkRequest()
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
