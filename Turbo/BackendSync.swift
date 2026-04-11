import Foundation

struct BackendSyncState: Equatable {
    var statusMessage: String = "Backend not configured"
    var contactSummaries: [UUID: TurboContactSummaryResponse] = [:]
    var channelStates: [UUID: TurboChannelStateResponse] = [:]
    var incomingInvites: [UUID: TurboInviteResponse] = [:]
    var outgoingInvites: [UUID: TurboInviteResponse] = [:]
    var requestCooldownDeadlines: [UUID: Date] = [:]

    mutating func applyContactSummaries(_ summaries: [UUID: TurboContactSummaryResponse]) {
        contactSummaries = summaries
    }

    mutating func clearContactSummaries() {
        contactSummaries = [:]
    }

    mutating func applyChannelState(_ channelState: TurboChannelStateResponse, for contactID: UUID) {
        let effectiveChannelState = Self.effectiveChannelState(
            existing: channelStates[contactID],
            incoming: channelState
        )
        channelStates[contactID] = effectiveChannelState
        if !effectiveChannelState.hasIncomingRequest {
            incomingInvites[contactID] = nil
        }
        if !effectiveChannelState.hasOutgoingRequest {
            outgoingInvites[contactID] = nil
            requestCooldownDeadlines[contactID] = nil
        }
    }

    static func effectiveChannelState(
        existing: TurboChannelStateResponse?,
        incoming: TurboChannelStateResponse
    ) -> TurboChannelStateResponse {
        guard let existing else { return incoming }
        guard shouldPreserveJoinedMembership(existing: existing, incoming: incoming) else {
            return incoming
        }
        return existing
    }

    mutating func clearChannelState(for contactID: UUID) {
        channelStates[contactID] = nil
    }

    mutating func applyInvites(
        incoming: [UUID: TurboInviteResponse],
        outgoing: [UUID: TurboInviteResponse],
        now: Date = .now
    ) {
        incomingInvites = incoming
        outgoingInvites = outgoing
        requestCooldownDeadlines = requestCooldownDeadlines.filter { outgoing.keys.contains($0.key) && $0.value > now }
        for contactID in outgoing.keys where requestCooldownDeadlines[contactID] == nil {
            requestCooldownDeadlines[contactID] = now.addingTimeInterval(30)
        }
    }

    mutating func clearInvites() {
        incomingInvites = [:]
        outgoingInvites = [:]
        requestCooldownDeadlines = [:]
    }

    mutating func reset(statusMessage: String) {
        self.statusMessage = statusMessage
        contactSummaries = [:]
        channelStates = [:]
        incomingInvites = [:]
        outgoingInvites = [:]
        requestCooldownDeadlines = [:]
    }

    var requestContactIDs: Set<UUID> {
        let summaryIncoming = contactSummaries.compactMap { contactID, summary in
            summary.hasIncomingRequest ? contactID : nil
        }
        let summaryOutgoing = contactSummaries.compactMap { contactID, summary in
            summary.hasOutgoingRequest ? contactID : nil
        }
        return Set(summaryIncoming)
            .union(summaryOutgoing)
            .union(incomingInvites.keys)
            .union(outgoingInvites.keys)
    }

    private static func shouldPreserveJoinedMembership(
        existing: TurboChannelStateResponse,
        incoming: TurboChannelStateResponse
    ) -> Bool {
        let transientStatuses = [
            "connecting",
            ConversationState.requested.rawValue,
            ConversationState.incomingRequest.rawValue,
            ConversationState.waitingForPeer.rawValue,
        ]
        let preservesLocalMembership = existing.channelId == incoming.channelId
            && existing.selfJoined
            && !incoming.selfJoined
            && transientStatuses.contains(incoming.status)
        let preservesObservedPeerMembership = existing.channelId == incoming.channelId
            && !existing.selfJoined
            && existing.peerJoined
            && existing.peerDeviceConnected
            && !incoming.selfJoined
            && !incoming.peerJoined
            && !incoming.peerDeviceConnected
            && transientStatuses.contains(incoming.status)
        return preservesLocalMembership || preservesObservedPeerMembership
    }
}
