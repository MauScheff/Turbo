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
            guard contact.handle != currentDevUserHandle,
                  let invite = incomingInviteByContactID[contact.id] else { return nil }
            return IncomingTalkRequestCandidate(contact: contact, invite: invite)
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
        selectContact(contact)
        guard contact.isOnline else {
            return
        }
        requestExpandedCall(for: contact)
        requestBackendJoin(for: contact)
    }

    func openActiveIncomingTalkRequest() {
        acceptActiveIncomingTalkRequest()
    }
}
