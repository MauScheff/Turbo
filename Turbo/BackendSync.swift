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
        channelStates[contactID] = channelState
        if !channelState.hasIncomingRequest {
            incomingInvites[contactID] = nil
        }
        if !channelState.hasOutgoingRequest {
            outgoingInvites[contactID] = nil
            requestCooldownDeadlines[contactID] = nil
        }
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
}
