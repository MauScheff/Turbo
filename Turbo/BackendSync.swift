import Foundation

struct BackendSyncState: Equatable {
    var statusMessage: String = "Starting backend..."
    var hasEstablishedConnection: Bool = false
    var contactSummaries: [UUID: TurboContactSummaryResponse] = [:]
    var channelStates: [UUID: TurboChannelStateResponse] = [:]
    var channelReadiness: [UUID: TurboChannelReadinessResponse] = [:]
    var incomingInvites: [UUID: TurboInviteResponse] = [:]
    var outgoingInvites: [UUID: TurboInviteResponse] = [:]
    var handledIncomingInviteSourceKeys: [UUID: Set<String>] = [:]
    var handledIncomingRequestCounts: [UUID: Int] = [:]
    var requestCooldownDeadlines: [UUID: Date] = [:]
    var requestCooldownSourceKeys: [UUID: String] = [:]

    static func inviteSourceKey(for invite: TurboInviteResponse) -> String {
        "\(invite.inviteId)|\(invite.requestCount)|\(invite.updatedAt ?? invite.createdAt)"
    }

    private func requestCooldownSourceKey(for invite: TurboInviteResponse) -> String {
        Self.inviteSourceKey(for: invite)
    }

    private func handledIncomingRequestCount(for contactID: UUID) -> Int {
        handledIncomingRequestCounts[contactID] ?? 0
    }

    func incomingInviteIsHandled(_ invite: TurboInviteResponse, for contactID: UUID) -> Bool {
        let sourceKey = Self.inviteSourceKey(for: invite)
        if handledIncomingInviteSourceKeys[contactID]?.contains(sourceKey) == true {
            return true
        }
        if handledIncomingInviteSourceKeys[contactID]?.isEmpty == false {
            return false
        }
        return invite.requestCount <= handledIncomingRequestCount(for: contactID)
    }

    private func visibleIncomingInvites(
        from incoming: [UUID: TurboInviteResponse]
    ) -> [UUID: TurboInviteResponse] {
        incoming.filter { contactID, invite in
            !incomingInviteIsHandled(invite, for: contactID)
        }
    }

    func visibleIncomingInvite(for contactID: UUID) -> TurboInviteResponse? {
        guard let invite = incomingInvites[contactID],
              !incomingInviteIsHandled(invite, for: contactID) else {
            return nil
        }
        return invite
    }

    func visibleIncomingInvitesByContactID() -> [UUID: TurboInviteResponse] {
        visibleIncomingInvites(from: incomingInvites)
    }

    func summaryIncomingRequestIsHandled(for contactID: UUID) -> Bool {
        guard let requestCount = contactSummaries[contactID]?.requestRelationship.requestCount else {
            return false
        }
        return requestCount <= handledIncomingRequestCount(for: contactID)
    }

    mutating func markIncomingRequestHandled(
        contactID: UUID,
        invite: TurboInviteResponse?,
        requestCount: Int
    ) {
        let normalizedRequestCount = max(requestCount, invite?.requestCount ?? 0)
        if normalizedRequestCount > 0 {
            handledIncomingRequestCounts[contactID] = max(
                handledIncomingRequestCount(for: contactID),
                normalizedRequestCount
            )
        }

        if let invite {
            handledIncomingInviteSourceKeys[contactID, default: []].insert(Self.inviteSourceKey(for: invite))
        }

        if let currentInvite = incomingInvites[contactID],
           incomingInviteIsHandled(currentInvite, for: contactID) {
            incomingInvites[contactID] = nil
        }
    }

    private func shouldApplyProjectionEpoch(incoming: String?, existing: String?) -> Bool {
        guard let incoming else { return true }
        guard let existing else { return true }
        return incoming >= existing
    }

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

        for (contactID, summary) in summaries {
            if !summary.requestRelationship.hasIncomingRequest {
                handledIncomingInviteSourceKeys[contactID] = nil
                handledIncomingRequestCounts[contactID] = nil
            }

            guard summary.membership == .absent,
                  let summaryChannelID = summary.channelId,
                  let existingChannelState = channelStates[contactID],
                  existingChannelState.channelId == summaryChannelID else {
                continue
            }

            let existingChannelStateLooksActive =
                existingChannelState.membership.hasLocalMembership
                || existingChannelState.membership.hasPeerMembership
                || existingChannelState.membership.peerDeviceConnected
                || {
                    switch existingChannelState.conversationStatus {
                    case .waitingForPeer, .ready, .transmitting, .receiving:
                        return true
                    case .idle, .requested, .incomingRequest, nil:
                        return false
                    }
                }()

            guard !existingChannelStateLooksActive else {
                continue
            }

            channelStates[contactID] = existingChannelState.settingMembership(.absent)
            channelReadiness[contactID] = nil
        }
    }

    mutating func clearContactSummaries() {
        contactSummaries = [:]
    }

    mutating func applyChannelState(_ channelState: TurboChannelStateResponse, for contactID: UUID) {
        guard shouldApplyProjectionEpoch(
            incoming: channelState.stateEpoch,
            existing: channelStates[contactID]?.stateEpoch
        ) else {
            return
        }
        channelStates[contactID] = channelState
        if channelState.membership == .absent {
            channelReadiness[contactID] = nil
        }
        if !channelState.requestRelationship.hasIncomingRequest {
            incomingInvites[contactID] = nil
        }
        if !channelState.requestRelationship.hasOutgoingRequest {
            outgoingInvites[contactID] = nil
            requestCooldownDeadlines[contactID] = nil
            requestCooldownSourceKeys[contactID] = nil
        }
    }

    mutating func applyChannelReadiness(_ readiness: TurboChannelReadinessResponse, for contactID: UUID) {
        if channelStates[contactID]?.membership == .absent,
           readiness.peerTargetDeviceId == nil {
            channelReadiness[contactID] = nil
            return
        }
        guard shouldApplyProjectionEpoch(
            incoming: readiness.stateEpoch,
            existing: channelReadiness[contactID]?.stateEpoch
        ) else {
            return
        }
        channelReadiness[contactID] = readiness
    }

    mutating func invalidateRemoteReceiverReadinessAfterWebSocketIdle() {
        channelReadiness = channelReadiness.mapValues { readiness in
            guard readiness.remoteAudioReadiness == .ready else { return readiness }

            let downgradedReadiness: RemoteAudioReadinessState
            switch readiness.remoteWakeCapability {
            case .wakeCapable:
                downgradedReadiness = .waiting
            case .unavailable:
                downgradedReadiness = .unknown
            }

            return readiness.settingRemoteAudioReadiness(downgradedReadiness)
        }
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
        incomingInvites = visibleIncomingInvites(from: incoming)
        outgoingInvites = outgoing
        reconcileOutgoingInviteCooldowns(now: now)
    }

    mutating func applyPartialInvites(
        incoming: [UUID: TurboInviteResponse]?,
        outgoing: [UUID: TurboInviteResponse]?,
        now: Date = .now
    ) {
        if let incoming {
            incomingInvites = visibleIncomingInvites(from: incoming)
        }
        if let outgoing {
            outgoingInvites = outgoing
        }
        reconcileOutgoingInviteCooldowns(now: now)
    }

    private mutating func reconcileOutgoingInviteCooldowns(now: Date) {
        requestCooldownDeadlines = requestCooldownDeadlines.filter { outgoingInvites.keys.contains($0.key) && $0.value > now }
        requestCooldownSourceKeys = requestCooldownSourceKeys.filter { outgoingInvites.keys.contains($0.key) }

        for (contactID, invite) in outgoingInvites {
            let sourceKey = requestCooldownSourceKey(for: invite)
            if requestCooldownSourceKeys[contactID] != sourceKey {
                requestCooldownDeadlines[contactID] = now.addingTimeInterval(30)
            }
            requestCooldownSourceKeys[contactID] = sourceKey
        }
    }

    mutating func clearInvites() {
        incomingInvites = [:]
        outgoingInvites = [:]
        handledIncomingInviteSourceKeys = [:]
        handledIncomingRequestCounts = [:]
        requestCooldownDeadlines = [:]
        requestCooldownSourceKeys = [:]
    }

    mutating func reset(statusMessage: String) {
        self.statusMessage = statusMessage
        hasEstablishedConnection = false
        contactSummaries = [:]
        channelStates = [:]
        channelReadiness = [:]
        incomingInvites = [:]
        outgoingInvites = [:]
        handledIncomingInviteSourceKeys = [:]
        handledIncomingRequestCounts = [:]
        requestCooldownDeadlines = [:]
        requestCooldownSourceKeys = [:]
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
            summary.requestRelationship.hasIncomingRequest
                && !summaryIncomingRequestIsHandled(for: contactID)
                ? contactID
                : nil
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
