import Foundation

struct BackendSyncState: Equatable {
    var statusMessage: String = "Starting backend..."
    var hasEstablishedConnection: Bool = false
    var contactSummaries: [UUID: TurboContactSummaryResponse] = [:]
    var channelStates: [UUID: TurboChannelStateResponse] = [:]
    var channelReadiness: [UUID: TurboChannelReadinessResponse] = [:]
    var incomingInvites: [UUID: TurboInviteResponse] = [:]
    var outgoingInvites: [UUID: TurboInviteResponse] = [:]
    var requestCooldownDeadlines: [UUID: Date] = [:]

    mutating func applyContactSummaries(_ summaries: [UUID: TurboContactSummaryResponse]) {
        contactSummaries = summaries
        let contactsWithLiveChannels: Set<UUID> = Set(
            summaries.compactMap { contactID, summary in
                guard let channelID = summary.channelId, !channelID.isEmpty else { return nil }
                return contactID
            }
        )
        channelStates = channelStates.filter { contactsWithLiveChannels.contains($0.key) }
        channelReadiness = channelReadiness.filter { contactsWithLiveChannels.contains($0.key) }
    }

    mutating func clearContactSummaries() {
        contactSummaries = [:]
    }

    mutating func applyChannelState(_ channelState: TurboChannelStateResponse, for contactID: UUID) {
        channelStates[contactID] = channelState
        if !channelState.requestRelationship.hasIncomingRequest {
            incomingInvites[contactID] = nil
        }
        if !channelState.requestRelationship.hasOutgoingRequest {
            outgoingInvites[contactID] = nil
            requestCooldownDeadlines[contactID] = nil
        }
    }

    mutating func applyChannelReadiness(_ readiness: TurboChannelReadinessResponse, for contactID: UUID) {
        channelReadiness[contactID] = readiness
    }

    mutating func clearChannelState(for contactID: UUID) {
        channelStates[contactID] = nil
        channelReadiness[contactID] = nil
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
        hasEstablishedConnection = false
        contactSummaries = [:]
        channelStates = [:]
        channelReadiness = [:]
        incomingInvites = [:]
        outgoingInvites = [:]
        requestCooldownDeadlines = [:]
    }

    mutating func applyRecoverableSyncFailureStatus(_ message: String) {
        guard hasEstablishedConnection else {
            statusMessage = message
            return
        }

        guard !isReconnectStatusMessage else { return }
        statusMessage = "Connected (retrying sync)"
    }

    var isReconnectStatusMessage: Bool {
        statusMessage == "Connecting WebSocket..." || statusMessage == "Reconnecting WebSocket..."
    }

    var requestContactIDs: Set<UUID> {
        let summaryIncoming = contactSummaries.compactMap { contactID, summary in
            summary.requestRelationship.hasIncomingRequest ? contactID : nil
        }
        let summaryOutgoing = contactSummaries.compactMap { contactID, summary in
            summary.requestRelationship.hasOutgoingRequest ? contactID : nil
        }
        return Set(summaryIncoming)
            .union(summaryOutgoing)
            .union(incomingInvites.keys)
            .union(outgoingInvites.keys)
    }
}
