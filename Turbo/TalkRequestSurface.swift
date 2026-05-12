import Foundation

struct IncomingTalkRequestSurface: Equatable, Identifiable {
    let contactID: UUID
    let inviteID: String
    let contactName: String
    let contactHandle: String
    let contactIsOnline: Bool
    let requestCount: Int
    let recencyKey: String

    var id: String { inviteID }
}

struct IncomingTalkRequestCandidate: Equatable {
    let surface: IncomingTalkRequestSurface

    init(contact: Contact, invite: TurboInviteResponse) {
        surface = IncomingTalkRequestSurface(
            contactID: contact.id,
            inviteID: invite.inviteId,
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            requestCount: invite.requestCount,
            recencyKey: invite.updatedAt ?? invite.createdAt
        )
    }

    init(contact: Contact, requestCount: Int, source: String) {
        let normalizedRequestCount = max(requestCount, 1)
        surface = IncomingTalkRequestSurface(
            contactID: contact.id,
            inviteID: "\(source):\(contact.id.uuidString):\(normalizedRequestCount)",
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            requestCount: normalizedRequestCount,
            recencyKey: "\(source):\(normalizedRequestCount):\(contact.id.uuidString)"
        )
    }
}

struct TalkRequestSurfaceState: Equatable {
    var activeIncomingRequest: IncomingTalkRequestSurface?
    var surfacedInviteIDs: Set<String> = []
}

enum TalkRequestSurfaceEvent: Equatable {
    case invitesUpdated(
        candidates: [IncomingTalkRequestCandidate],
        selectedContactID: UUID?,
        applicationIsActive: Bool,
        allowsSelectedContact: Bool = false,
        allowsAlreadySurfacedInvite: Bool = false
    )
    case incomingRequestDismissed
    case contactOpened(contactID: UUID, inviteID: String?)
}

enum TalkRequestSurfaceReducer {
    static func reduce(
        state: TalkRequestSurfaceState,
        event: TalkRequestSurfaceEvent
    ) -> TalkRequestSurfaceState {
        var nextState = state

        switch event {
        case .invitesUpdated(
            let candidates,
            let selectedContactID,
            let applicationIsActive,
            let allowsSelectedContact,
            let allowsAlreadySurfacedInvite
        ):
            let activeInviteIDs = Set(candidates.map(\.surface.inviteID))
            nextState.surfacedInviteIDs.formIntersection(activeInviteIDs)

            if let activeIncomingRequest = nextState.activeIncomingRequest,
               !activeInviteIDs.contains(activeIncomingRequest.inviteID) {
                nextState.activeIncomingRequest = nil
            }

            guard applicationIsActive else {
                return nextState
            }

            guard nextState.activeIncomingRequest == nil else {
                return nextState
            }

            let candidate = candidates
                .sorted { lhs, rhs in
                    lhs.surface.recencyKey > rhs.surface.recencyKey
                }
                .first { candidate in
                    (allowsSelectedContact || candidate.surface.contactID != selectedContactID)
                        && (
                            allowsAlreadySurfacedInvite
                                || !nextState.surfacedInviteIDs.contains(candidate.surface.inviteID)
                        )
                }

            if let candidate {
                nextState.activeIncomingRequest = candidate.surface
                nextState.surfacedInviteIDs.insert(candidate.surface.inviteID)
            }

        case .incomingRequestDismissed:
            nextState.activeIncomingRequest = nil

        case .contactOpened(let contactID, let inviteID):
            if let inviteID {
                nextState.surfacedInviteIDs.insert(inviteID)
            }
            if nextState.activeIncomingRequest?.contactID == contactID {
                nextState.activeIncomingRequest = nil
            }
        }

        return nextState
    }
}
