import Foundation

nonisolated struct TalkRequestKey: Hashable {
    let contactID: UUID
    let requestCount: Int

    init(contactID: UUID, requestCount: Int) {
        self.contactID = contactID
        self.requestCount = max(requestCount, 1)
    }

    var stableID: String {
        "\(contactID.uuidString):\(requestCount)"
    }
}

nonisolated enum TalkRequestSource: String, Hashable {
    case backendInvite
    case relationshipProjection
    case foregroundNotification

    init(surfaceSource: String) {
        switch surfaceSource {
        case "relationship":
            self = .relationshipProjection
        case "notification", "foreground-notification":
            self = .foregroundNotification
        default:
            self = .backendInvite
        }
    }
}

nonisolated struct CanonicalTalkRequest: Equatable, Identifiable {
    let key: TalkRequestKey
    let contactName: String
    let contactHandle: String
    let contactIsOnline: Bool
    let inviteID: String
    let channelID: String?
    let userIntent: String?
    let sentAt: String?
    let sources: Set<TalkRequestSource>
    let recencyKey: String

    var id: String { key.stableID }

    var surface: IncomingTalkRequestSurface {
        IncomingTalkRequestSurface(
            contactID: key.contactID,
            inviteID: inviteID,
            contactName: contactName,
            contactHandle: contactHandle,
            contactIsOnline: contactIsOnline,
            requestCount: key.requestCount,
            recencyKey: recencyKey,
            channelID: channelID,
            userIntent: userIntent,
            sentAt: sentAt
        )
    }

    func merging(_ other: CanonicalTalkRequest) -> CanonicalTalkRequest {
        guard key == other.key else { return self }

        let preferred = presentationPriority >= other.presentationPriority ? self : other
        let fallback = preferred == self ? other : self
        return CanonicalTalkRequest(
            key: key,
            contactName: preferred.contactName,
            contactHandle: preferred.contactHandle,
            contactIsOnline: preferred.contactIsOnline,
            inviteID: preferred.inviteID,
            channelID: preferred.channelID ?? fallback.channelID,
            userIntent: preferred.userIntent ?? fallback.userIntent,
            sentAt: preferred.sentAt ?? fallback.sentAt,
            sources: sources.union(other.sources),
            recencyKey: max(recencyKey, other.recencyKey)
        )
    }

    private var presentationPriority: Int {
        if sources.contains(.backendInvite) { return 3 }
        if sources.contains(.foregroundNotification) { return 2 }
        return 1
    }
}

nonisolated struct IncomingTalkRequestSurface: Equatable, Identifiable {
    let contactID: UUID
    let inviteID: String
    let contactName: String
    let contactHandle: String
    let contactIsOnline: Bool
    let requestCount: Int
    let recencyKey: String
    let channelID: String?
    let userIntent: String?
    let sentAt: String?

    init(
        contactID: UUID,
        inviteID: String,
        contactName: String,
        contactHandle: String,
        contactIsOnline: Bool,
        requestCount: Int,
        recencyKey: String,
        channelID: String? = nil,
        userIntent: String? = nil,
        sentAt: String? = nil
    ) {
        self.contactID = contactID
        self.inviteID = inviteID
        self.contactName = contactName
        self.contactHandle = contactHandle
        self.contactIsOnline = contactIsOnline
        self.requestCount = max(requestCount, 1)
        self.recencyKey = recencyKey
        self.channelID = channelID
        self.userIntent = userIntent
        self.sentAt = sentAt
    }

    var id: String { inviteID }
    var requestKey: TalkRequestKey {
        TalkRequestKey(contactID: contactID, requestCount: requestCount)
    }

    func matchesPresentation(of other: IncomingTalkRequestSurface) -> Bool {
        requestKey == other.requestKey
    }
}

nonisolated struct IncomingTalkRequestCandidate: Equatable {
    let request: CanonicalTalkRequest

    var surface: IncomingTalkRequestSurface {
        request.surface
    }

    nonisolated init(request: CanonicalTalkRequest) {
        self.request = request
    }

    nonisolated init(surface: IncomingTalkRequestSurface, source: TalkRequestSource = .foregroundNotification) {
        request = CanonicalTalkRequest(
            key: surface.requestKey,
            contactName: surface.contactName,
            contactHandle: surface.contactHandle,
            contactIsOnline: surface.contactIsOnline,
            inviteID: surface.inviteID,
            channelID: surface.channelID,
            userIntent: surface.userIntent,
            sentAt: surface.sentAt,
            sources: [source],
            recencyKey: surface.recencyKey
        )
    }

    nonisolated init(contact: Contact, invite: TurboInviteResponse) {
        let requestCount = max(invite.requestCount, 1)
        request = CanonicalTalkRequest(
            key: TalkRequestKey(contactID: contact.id, requestCount: requestCount),
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            inviteID: invite.inviteId,
            channelID: invite.channelId,
            userIntent: invite.userIntent,
            sentAt: invite.createdAt,
            sources: [.backendInvite],
            recencyKey: invite.updatedAt ?? invite.createdAt
        )
    }

    nonisolated init(contact: Contact, requestCount: Int, source: String) {
        let normalizedRequestCount = max(requestCount, 1)
        let requestSource = TalkRequestSource(surfaceSource: source)
        request = CanonicalTalkRequest(
            key: TalkRequestKey(contactID: contact.id, requestCount: normalizedRequestCount),
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            inviteID: "\(source):\(contact.id.uuidString):\(normalizedRequestCount)",
            channelID: contact.backendChannelId,
            userIntent: nil,
            sentAt: nil,
            sources: [requestSource],
            recencyKey: "\(source):\(normalizedRequestCount):\(contact.id.uuidString)"
        )
    }
}

nonisolated struct TalkRequestSurfaceState: Equatable {
    var activeIncomingRequest: IncomingTalkRequestSurface?
    var surfacedInviteIDs: Set<String> = []
    var surfacedRequestKeys: Set<TalkRequestKey> = []
    var pendingForegroundRequest: IncomingTalkRequestSurface?
    var pendingForegroundRequestReceivedAt: Date?
    var pendingAcceptRequest: IncomingTalkRequestSurface?

    func isAccepting(_ surface: IncomingTalkRequestSurface) -> Bool {
        pendingAcceptRequest?.requestKey == surface.requestKey
    }
}

nonisolated enum TalkRequestSurfaceEvent: Equatable {
    case invitesUpdated(
        candidates: [IncomingTalkRequestCandidate],
        selectedContactID: UUID?,
        applicationIsActive: Bool,
        allowsSelectedContact: Bool = false,
        allowsAlreadySurfacedInvite: Bool = false
    )
    case incomingRequestDismissed
    case contactOpened(contactID: UUID, inviteID: String?, requestCount: Int? = nil)
    case pendingForegroundRequestQueued(surface: IncomingTalkRequestSurface, receivedAt: Date)
    case pendingForegroundRequestCleared(contactID: UUID?, inviteID: String?)
    case pendingForegroundRequestExpired(now: Date, lifetime: TimeInterval)
    case incomingRequestAcceptStarted(IncomingTalkRequestSurface)
    case incomingRequestAcceptFinished(IncomingTalkRequestSurface)
}

nonisolated enum TalkRequestSurfaceReducer {
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
            let canonicalCandidates = canonicalize(candidates)
            let sortedCandidates = canonicalCandidates.sorted { lhs, rhs in
                lhs.request.recencyKey > rhs.request.recencyKey
            }
            let activeInviteIDs = Set(canonicalCandidates.map(\.surface.inviteID))
            let activeRequestKeys = Set(canonicalCandidates.map(\.request.key))
            nextState.surfacedInviteIDs.formIntersection(activeInviteIDs)
            nextState.surfacedRequestKeys.formIntersection(activeRequestKeys)

            if let activeIncomingRequest = nextState.activeIncomingRequest,
               let activeCandidate = canonicalCandidates.first(where: { $0.request.key == activeIncomingRequest.requestKey }),
               !activeCandidate.surface.contactIsOnline {
                nextState.activeIncomingRequest = nil
            } else if let activeIncomingRequest = nextState.activeIncomingRequest,
                      !activeRequestKeys.contains(activeIncomingRequest.requestKey) {
                nextState.activeIncomingRequest = nil
            }

            if let activeIncomingRequest = nextState.activeIncomingRequest,
               activeRequestKeys.contains(activeIncomingRequest.requestKey) {
                nextState.surfacedInviteIDs.insert(activeIncomingRequest.inviteID)
                nextState.surfacedRequestKeys.insert(activeIncomingRequest.requestKey)
            }

            guard applicationIsActive else {
                return nextState
            }

            guard nextState.activeIncomingRequest == nil else {
                return nextState
            }

            let candidate = sortedCandidates.first { candidate in
                candidate.surface.contactIsOnline
                    && (allowsSelectedContact || candidate.surface.contactID != selectedContactID)
                    && (
                        allowsAlreadySurfacedInvite
                            || !nextState.surfacedRequestKeys.contains(candidate.request.key)
                    )
            }

            if let candidate {
                nextState.activeIncomingRequest = candidate.surface
                nextState.surfacedInviteIDs.insert(candidate.surface.inviteID)
                nextState.surfacedRequestKeys.insert(candidate.request.key)
            }

        case .incomingRequestDismissed:
            nextState.activeIncomingRequest = nil

        case .contactOpened(let contactID, let inviteID, let requestCount):
            if let activeIncomingRequest = nextState.activeIncomingRequest,
               activeIncomingRequest.contactID == contactID {
                nextState.surfacedRequestKeys.insert(activeIncomingRequest.requestKey)
                nextState.activeIncomingRequest = nil
            }
            if let inviteID {
                nextState.surfacedInviteIDs.insert(inviteID)
            }
            if let requestCount {
                nextState.surfacedRequestKeys.insert(
                    TalkRequestKey(contactID: contactID, requestCount: requestCount)
                )
            }
            if nextState.pendingForegroundRequest?.contactID == contactID,
               inviteID == nil || nextState.pendingForegroundRequest?.inviteID == inviteID {
                nextState.pendingForegroundRequest = nil
                nextState.pendingForegroundRequestReceivedAt = nil
            }

        case .pendingForegroundRequestQueued(let surface, let receivedAt):
            nextState.pendingForegroundRequest = surface
            nextState.pendingForegroundRequestReceivedAt = receivedAt

        case .pendingForegroundRequestCleared(let contactID, let inviteID):
            guard let pendingSurface = nextState.pendingForegroundRequest else {
                return nextState
            }
            if let contactID, pendingSurface.contactID != contactID {
                return nextState
            }
            if let inviteID, pendingSurface.inviteID != inviteID {
                return nextState
            }
            nextState.pendingForegroundRequest = nil
            nextState.pendingForegroundRequestReceivedAt = nil

        case .pendingForegroundRequestExpired(let now, let lifetime):
            guard let receivedAt = nextState.pendingForegroundRequestReceivedAt,
                  now.timeIntervalSince(receivedAt) >= lifetime else {
                return nextState
            }
            nextState.pendingForegroundRequest = nil
            nextState.pendingForegroundRequestReceivedAt = nil

        case .incomingRequestAcceptStarted(let surface):
            guard !nextState.isAccepting(surface) else {
                return nextState
            }
            nextState.pendingAcceptRequest = surface

        case .incomingRequestAcceptFinished(let surface):
            guard nextState.pendingAcceptRequest?.requestKey == surface.requestKey else {
                return nextState
            }
            nextState.pendingAcceptRequest = nil
        }

        return nextState
    }

    private static func canonicalize(
        _ candidates: [IncomingTalkRequestCandidate]
    ) -> [IncomingTalkRequestCandidate] {
        let merged = candidates.reduce(into: [TalkRequestKey: CanonicalTalkRequest]()) { result, candidate in
            if let existing = result[candidate.request.key] {
                result[candidate.request.key] = existing.merging(candidate.request)
            } else {
                result[candidate.request.key] = candidate.request
            }
        }
        return merged.values.map(IncomingTalkRequestCandidate.init(request:))
    }
}
