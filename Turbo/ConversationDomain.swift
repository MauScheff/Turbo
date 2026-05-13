import Foundation
import CryptoKit

enum ConversationState: String {
    case idle
    case requested
    case incomingRequest = "incoming-request"
    case waitingForPeer = "waiting-for-peer"
    case ready
    case transmitting = "self-transmitting"
    case receiving = "peer-transmitting"
}

struct Contact: Identifiable, Hashable {
    let id: UUID
    var profileName: String
    var localName: String?
    var handle: String
    var isOnline: Bool
    var channelId: UUID
    var backendChannelId: String?
    var remoteUserId: String?

    init(
        id: UUID,
        name: String,
        handle: String,
        isOnline: Bool,
        channelId: UUID,
        backendChannelId: String? = nil,
        remoteUserId: String? = nil,
        localName: String? = nil
    ) {
        self.init(
            id: id,
            profileName: name,
            localName: localName,
            handle: handle,
            isOnline: isOnline,
            channelId: channelId,
            backendChannelId: backendChannelId,
            remoteUserId: remoteUserId
        )
    }

    init(
        id: UUID,
        profileName: String,
        localName: String? = nil,
        handle: String,
        isOnline: Bool,
        channelId: UUID,
        backendChannelId: String? = nil,
        remoteUserId: String? = nil
    ) {
        self.id = id
        self.profileName = Self.normalizedProfileName(profileName, fallbackHandle: handle)
        self.localName = Self.normalizedLocalName(localName)
        self.handle = handle
        self.isOnline = isOnline
        self.channelId = channelId
        self.backendChannelId = backendChannelId
        self.remoteUserId = remoteUserId
    }

    var name: String {
        get {
            Self.presentedName(
                localName: localName,
                profileName: profileName,
                handle: handle
            )
        }
        set {
            profileName = Self.normalizedProfileName(newValue, fallbackHandle: handle)
        }
    }

    var hasLocalNameOverride: Bool {
        guard let localName else { return false }
        let normalizedLocal = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLocal.isEmpty else { return false }
        return normalizedLocal.localizedCaseInsensitiveCompare(profileName) != .orderedSame
    }

    static func stableID(remoteUserId: String?, fallbackHandle: String) -> UUID {
        let identitySeed: String
        if let remoteUserId, !remoteUserId.isEmpty {
            identitySeed = remoteUserId
        } else {
            identitySeed = normalizedHandle(fallbackHandle)
        }
        let digest = SHA256.hash(data: Data("contact:\(identitySeed)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func stableID(for handle: String) -> UUID {
        stableID(remoteUserId: nil, fallbackHandle: handle)
    }

    static func displayName(for handle: String) -> String {
        let raw = TurboHandle.body(from: handle)
        guard !raw.isEmpty else { return normalizedHandle(handle) }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func normalizedHandle(_ handle: String) -> String {
        TurboHandle.normalizedStoredHandle(handle)
    }

    static func normalizedProfileName(_ profileName: String, fallbackHandle: String) -> String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return displayName(for: fallbackHandle) }
        return trimmed
    }

    static func normalizedLocalName(_ localName: String?) -> String? {
        guard let localName else { return nil }
        let trimmed = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func presentedName(localName: String?, profileName: String, handle: String) -> String {
        normalizedLocalName(localName) ?? normalizedProfileName(profileName, fallbackHandle: handle)
    }
}

enum SystemPTTSessionState: Equatable {
    case none
    case active(contactID: UUID, channelUUID: UUID)
    case mismatched(channelUUID: UUID)
}

enum PendingConnectAction: Equatable {
    case requestingBackend(contactID: UUID)
    case joiningLocal(contactID: UUID)

    var contactID: UUID {
        switch self {
        case .requestingBackend(let contactID), .joiningLocal(let contactID):
            return contactID
        }
    }
}

enum PendingConnectOrigin: Equatable {
    case neutral
    case acceptingIncomingRequest
}

enum PendingLeaveAction: Equatable {
    case explicit(contactID: UUID?)
    case reconciledTeardown(contactID: UUID)
}

enum PendingSessionAction: Equatable {
    case none
    case connect(PendingConnectAction)
    case leave(PendingLeaveAction)

    var pendingConnectContactID: UUID? {
        switch self {
        case .connect(let action):
            return action.contactID
        case .none, .leave:
            return nil
        }
    }

    var pendingJoinContactID: UUID? {
        switch self {
        case .connect(.joiningLocal(let contactID)):
            return contactID
        case .none, .connect(.requestingBackend), .leave:
            return nil
        }
    }

    var pendingTeardownContactID: UUID? {
        guard case .leave(.reconciledTeardown(let contactID)) = self else { return nil }
        return contactID
    }

    var hasAnyLeaveInFlight: Bool {
        switch self {
        case .leave:
            return true
        case .none, .connect:
            return false
        }
    }

    var blocksAutoRejoin: Bool {
        switch self {
        case .leave:
            return true
        case .none, .connect:
            return false
        }
    }

    func isLeaveInFlight(for contactID: UUID) -> Bool {
        switch self {
        case .leave(.explicit(let pendingContactID)):
            return pendingContactID == nil || pendingContactID == contactID
        case .leave(.reconciledTeardown(let pendingContactID)):
            return pendingContactID == contactID
        case .none, .connect:
            return false
        }
    }
}

struct LocalJoinAttempt: Equatable {
    let contactID: UUID
    let channelUUID: UUID
    var issuedCount: Int
    var firstIssuedAt: Date
    var lastIssuedAt: Date
}

struct SessionCoordinatorState: Equatable {
    private(set) var pendingAction: PendingSessionAction = .none
    private(set) var pendingConnectOrigin: PendingConnectOrigin?
    private(set) var localJoinAttempt: LocalJoinAttempt?

    var pendingJoinContactID: UUID? {
        pendingAction.pendingJoinContactID
    }

    mutating func queueConnect(contactID: UUID, origin: PendingConnectOrigin = .neutral) {
        pendingAction = .connect(.requestingBackend(contactID: contactID))
        pendingConnectOrigin = origin
        localJoinAttempt = nil
    }

    mutating func queueJoin(
        contactID: UUID,
        channelUUID: UUID? = nil,
        now: Date = Date()
    ) {
        if case .leave(.explicit(let pendingContactID)) = pendingAction,
           pendingContactID == nil || pendingContactID == contactID {
            return
        }
        pendingAction = .connect(.joiningLocal(contactID: contactID))
        pendingConnectOrigin = nil
        guard let channelUUID else { return }
        if var attempt = localJoinAttempt,
           attempt.contactID == contactID,
           attempt.channelUUID == channelUUID {
            attempt.issuedCount += 1
            attempt.lastIssuedAt = now
            localJoinAttempt = attempt
        } else {
            localJoinAttempt = LocalJoinAttempt(
                contactID: contactID,
                channelUUID: channelUUID,
                issuedCount: 1,
                firstIssuedAt: now,
                lastIssuedAt: now
            )
        }
    }

    mutating func markExplicitLeave(contactID: UUID?) {
        pendingAction = .leave(.explicit(contactID: contactID))
        pendingConnectOrigin = nil
        if contactID == nil || localJoinAttempt?.contactID == contactID {
            localJoinAttempt = nil
        }
    }

    mutating func markReconciledTeardown(contactID: UUID) {
        pendingAction = .leave(.reconciledTeardown(contactID: contactID))
        pendingConnectOrigin = nil
        if localJoinAttempt?.contactID == contactID {
            localJoinAttempt = nil
        }
    }

    mutating func clearAfterSuccessfulJoin(for contactID: UUID) {
        if pendingJoinContactID == contactID {
            pendingAction = .none
            pendingConnectOrigin = nil
        }
        if localJoinAttempt?.contactID == contactID {
            localJoinAttempt = nil
        }
    }

    mutating func clearPendingJoin(for contactID: UUID) {
        if pendingJoinContactID == contactID {
            pendingAction = .none
            pendingConnectOrigin = nil
        }
        if localJoinAttempt?.contactID == contactID {
            localJoinAttempt = nil
        }
    }

    mutating func clearPendingConnect(for contactID: UUID) {
        if pendingAction.pendingConnectContactID == contactID {
            pendingAction = .none
            pendingConnectOrigin = nil
        }
    }

    mutating func clearExplicitLeave(for contactID: UUID?) {
        guard case .leave(.explicit(let pendingContactID)) = pendingAction else { return }
        if pendingContactID == nil || pendingContactID == contactID {
            pendingAction = .none
            pendingConnectOrigin = nil
        }
    }

    mutating func clearLeaveAction(for contactID: UUID?) {
        switch pendingAction {
        case .leave(.explicit(let pendingContactID)):
            if pendingContactID == nil || pendingContactID == contactID {
                pendingAction = .none
                pendingConnectOrigin = nil
            }
        case .leave(.reconciledTeardown(let pendingContactID)):
            if pendingContactID == contactID {
                pendingAction = .none
                pendingConnectOrigin = nil
            }
        case .none, .connect:
            break
        }
    }

    var pendingConnectAcceptedIncomingRequestContactID: UUID? {
        guard pendingConnectOrigin == .acceptingIncomingRequest else { return nil }
        guard case .connect(.requestingBackend(let contactID)) = pendingAction else { return nil }
        return contactID
    }

    mutating func reconcileAfterChannelRefresh(
        for contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        localSessionEstablished: Bool,
        localSessionCleared: Bool
    ) {
        if effectiveChannelState.membership.hasLocalMembership, localSessionEstablished {
            clearAfterSuccessfulJoin(for: contactID)
        } else if !effectiveChannelState.membership.hasLocalMembership, localSessionCleared {
            clearPendingJoin(for: contactID)
            clearLeaveAction(for: contactID)
        }
    }

    mutating func select(contactID: UUID) {
        switch pendingAction {
        case .connect(.joiningLocal(let pendingContactID)) where pendingContactID != contactID:
            pendingAction = .none
            pendingConnectOrigin = nil
            if localJoinAttempt?.contactID == pendingContactID {
                localJoinAttempt = nil
            }
        case .leave(.explicit(let pendingContactID)) where pendingContactID != nil && pendingContactID != contactID:
            pendingAction = .none
            pendingConnectOrigin = nil
        default:
            break
        }
    }

    mutating func reset() {
        pendingAction = .none
        pendingConnectOrigin = nil
        localJoinAttempt = nil
    }

    func autoRejoinContactID(afterLeaving _: UUID?) -> UUID? {
        guard !pendingAction.blocksAutoRejoin else { return nil }
        return pendingAction.pendingConnectContactID
    }
}

enum ConversationPrimaryActionKind: Equatable {
    case connect
    case holdToTalk
}

enum ConversationPrimaryActionStyle: Equatable {
    case accent
    case active
    case muted
}

struct ConversationPrimaryAction: Equatable {
    let kind: ConversationPrimaryActionKind
    let label: String
    let isEnabled: Bool
    let style: ConversationPrimaryActionStyle
}

enum PairRelationshipState: Equatable {
    case none
    case outgoingRequest(requestCount: Int)
    case incomingRequest(requestCount: Int)
    case mutualRequest(requestCount: Int)

    var requestCount: Int? {
        switch self {
        case .none:
            return nil
        case .outgoingRequest(let requestCount), .incomingRequest(let requestCount), .mutualRequest(let requestCount):
            return requestCount
        }
    }

    var isIncomingRequest: Bool {
        switch self {
        case .incomingRequest, .mutualRequest:
            return true
        case .none, .outgoingRequest:
            return false
        }
    }

    var isOutgoingRequest: Bool {
        switch self {
        case .outgoingRequest, .mutualRequest:
            return true
        case .none, .incomingRequest:
            return false
        }
    }

    var fallbackConversationState: ConversationState {
        switch self {
        case .none:
            return .idle
        case .outgoingRequest:
            return .requested
        case .incomingRequest, .mutualRequest:
            return .incomingRequest
        }
    }
}

enum ConversationRequestDirection: Equatable {
    case outgoing
    case incoming
}

enum ConversationDisplayStatus: Equatable {
    case offline
    case online
    case requested(direction: ConversationRequestDirection, requestCount: Int)
    case ready
    case live

    var requestCount: Int? {
        switch self {
        case .requested(_, let requestCount):
            return requestCount
        case .offline, .online, .ready, .live:
            return nil
        }
    }

    var pillText: String {
        switch self {
        case .offline:
            return "Offline"
        case .online:
            return "Online"
        case .requested(let direction, let requestCount):
            let base = switch direction {
            case .outgoing:
                "Requested"
            case .incoming:
                "Incoming"
            }
            guard requestCount > 1 else { return base }
            return "\(base) \(requestCount)"
        case .ready:
            return "Ready"
        case .live:
            return "Live"
        }
    }
}

enum ConversationListSection: String, Equatable {
    case wantsToTalk = "wants-to-talk"
    case readyToTalk = "ready-to-talk"
    case requested
    case contacts

    var title: String {
        switch self {
        case .wantsToTalk:
            return "Inbox"
        case .readyToTalk:
            return "Ready to Talk"
        case .requested:
            return "Requested"
        case .contacts:
            return "Contacts"
        }
    }
}

enum ConversationAvailabilityPill: String, Equatable {
    case online
    case offline
    case busy

    var pillText: String {
        switch self {
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        case .busy:
            return "Busy"
        }
    }
}

struct ContactListPresentation: Equatable {
    let displayStatus: ConversationDisplayStatus
    let section: ConversationListSection
    let availabilityPill: ConversationAvailabilityPill
    let requestCount: Int?

    func statusPillText(isActiveConversation: Bool = false) -> String {
        if isActiveConversation, availabilityPill == .online {
            return "Connected"
        }

        if section == .wantsToTalk, availabilityPill == .online {
            return "Ready"
        }

        return availabilityPill.pillText
    }
}

enum SelectedPeerPhase: Equatable {
    case idle
    case requested
    case incomingRequest
    case peerReady
    case wakeReady
    case waitingForPeer
    case localJoinFailed
    case ready
    case startingTransmit
    case transmitting
    case receiving
    case blockedByOtherSession
    case systemMismatch

    var showsTransportPathBadge: Bool {
        switch self {
        case .ready, .startingTransmit, .transmitting, .receiving:
            return true
        case .idle, .requested, .incomingRequest, .peerReady, .wakeReady, .waitingForPeer,
             .localJoinFailed, .blockedByOtherSession, .systemMismatch:
            return false
        }
    }
}

enum SelectedPeerWaitingReason: Equatable {
    case pendingJoin
    case disconnecting
    case localSessionTransition
    case releaseRequiredAfterInterruptedTransmit
    case localAudioPrewarm
    case systemWakeActivation
    case wakePlaybackDeferredUntilForeground
    case localTransportWarmup
    case remoteAudioPrewarm
    case remoteWakeUnavailable
    case backendSessionTransition
    case peerReadyToConnect
}

enum StartingTransmitStage: Equatable {
    case requestingLease
    case awaitingSystemTransmit
    case awaitingAudioSession
    case awaitingAudioConnection(mediaState: MediaConnectionState)
}

enum LocalTransmitProjection: Equatable {
    case idle
    case stopping
    case releaseRequired
    case starting(StartingTransmitStage)
    case transmitting

    var hasTransmitIntent: Bool {
        switch self {
        case .starting, .transmitting:
            return true
        case .idle, .stopping, .releaseRequired:
            return false
        }
    }

    var preservesConnectedSession: Bool {
        switch self {
        case .stopping, .starting, .transmitting:
            return true
        case .idle, .releaseRequired:
            return false
        }
    }

    var startingTransmitStage: StartingTransmitStage? {
        guard case .starting(let stage) = self else { return nil }
        return stage
    }

    static func legacy(
        isTransmitting: Bool,
        isStopping: Bool,
        requiresFreshPress: Bool,
        transmitPhase: TransmitDomainPhase,
        systemIsTransmitting: Bool,
        pttAudioSessionActive: Bool,
        mediaState: MediaConnectionState
    ) -> LocalTransmitProjection {
        if isStopping {
            return .stopping
        }

        if requiresFreshPress {
            return .releaseRequired
        }

        guard isTransmitting else {
            return .idle
        }

        if !systemIsTransmitting {
            switch transmitPhase {
            case .requesting:
                return .starting(.requestingLease)
            case .idle, .active, .stopping:
                return .starting(.awaitingSystemTransmit)
            }
        }

        guard pttAudioSessionActive else {
            return .starting(.awaitingAudioSession)
        }

        switch mediaState {
        case .connected:
            return .transmitting
        case .preparing, .idle, .closed, .failed:
            return .starting(.awaitingAudioConnection(mediaState: mediaState))
        }
    }
}

enum LocalMediaWarmupState: Equatable {
    case cold
    case prewarming
    case ready
    case failed
}

enum FirstTalkStartupProfile: Equatable {
    case directQuicWarm
    case directQuicWarming
    case relayWarm
    case relayWarming
    case unavailable

    var diagnosticsValue: String {
        switch self {
        case .directQuicWarm:
            return "direct-quic-warm"
        case .directQuicWarming:
            return "direct-quic-warming"
        case .relayWarm:
            return "relay-warm"
        case .relayWarming:
            return "relay-warming"
        case .unavailable:
            return "unavailable"
        }
    }

    var blocksFirstTalkTransmit: Bool {
        switch self {
        case .directQuicWarming, .relayWarming, .unavailable:
            return true
        case .directQuicWarm, .relayWarm:
            return false
        }
    }
}

enum RemoteAudioReadinessState: Equatable {
    case unknown
    case waiting
    case wakeCapable
    case ready
}

enum RemoteWakeCapabilityState: Equatable {
    case unavailable
    case wakeCapable(targetDeviceId: String)
}

enum SelectedPeerDetail: Equatable {
    case idle(isOnline: Bool)
    case requested(requestCount: Int)
    case incomingRequest(requestCount: Int)
    case peerReady
    case wakeReady
    case waitingForPeer(reason: SelectedPeerWaitingReason)
    case localJoinFailed(recoveryMessage: String)
    case ready
    case startingTransmit(stage: StartingTransmitStage)
    case transmitting
    case receiving
    case blockedByOtherSession
    case systemMismatch

    var phase: SelectedPeerPhase {
        switch self {
        case .idle:
            return .idle
        case .requested:
            return .requested
        case .incomingRequest:
            return .incomingRequest
        case .peerReady:
            return .peerReady
        case .wakeReady:
            return .wakeReady
        case .waitingForPeer:
            return .waitingForPeer
        case .localJoinFailed:
            return .localJoinFailed
        case .ready:
            return .ready
        case .startingTransmit:
            return .startingTransmit
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        case .blockedByOtherSession:
            return .blockedByOtherSession
        case .systemMismatch:
            return .systemMismatch
        }
    }
}

struct SelectedPeerState: Equatable {
    let contactID: UUID?
    let contactName: String?
    let relationship: PairRelationshipState
    let detail: SelectedPeerDetail
    let statusMessage: String
    let canTransmitNow: Bool

    init(
        contactID: UUID? = nil,
        contactName: String? = nil,
        relationship: PairRelationshipState,
        detail: SelectedPeerDetail,
        statusMessage: String,
        canTransmitNow: Bool
    ) {
        self.contactID = contactID
        self.contactName = contactName
        self.relationship = relationship
        self.detail = detail
        self.statusMessage = statusMessage
        self.canTransmitNow = canTransmitNow
    }

    init(
        contactID: UUID? = nil,
        contactName: String? = nil,
        relationship: PairRelationshipState,
        phase: SelectedPeerPhase,
        statusMessage: String,
        canTransmitNow: Bool
    ) {
        self.init(
            contactID: contactID,
            contactName: contactName,
            relationship: relationship,
            detail: SelectedPeerState.defaultDetail(for: phase, relationship: relationship, statusMessage: statusMessage),
            statusMessage: statusMessage,
            canTransmitNow: canTransmitNow
        )
    }

    var phase: SelectedPeerPhase {
        detail.phase
    }

    var allowsHoldToTalk: Bool {
        canTransmitNow
            || phase == .ready
            || phase == .wakeReady
            || phase == .transmitting
            || phase == .startingTransmit
    }

    var conversationState: ConversationState {
        switch phase {
        case .idle:
            return relationship.fallbackConversationState
        case .requested, .peerReady:
            return .requested
        case .incomingRequest:
            return .incomingRequest
        case .wakeReady:
            return .ready
        case .waitingForPeer, .localJoinFailed:
            return .waitingForPeer
        case .ready:
            return .ready
        case .startingTransmit:
            return .transmitting
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        case .blockedByOtherSession, .systemMismatch:
            return relationship.fallbackConversationState
        }
    }

    var displayStatus: ConversationDisplayStatus {
        switch detail {
        case .idle(let isOnline):
            return isOnline ? .online : .offline
        case .requested(let requestCount):
            return .requested(direction: .outgoing, requestCount: requestCount)
        case .incomingRequest(let requestCount):
            return .requested(direction: .incoming, requestCount: requestCount)
        case .peerReady:
            return .ready
        case .wakeReady, .ready, .startingTransmit, .transmitting, .receiving:
            return .live
        case .waitingForPeer(reason: .peerReadyToConnect):
            return .ready
        case .waitingForPeer, .localJoinFailed, .blockedByOtherSession, .systemMismatch:
            return .offline
        }
    }

    private static func defaultDetail(
        for phase: SelectedPeerPhase,
        relationship: PairRelationshipState,
        statusMessage: String
    ) -> SelectedPeerDetail {
        switch phase {
        case .idle:
            return .idle(isOnline: false)
        case .requested:
            return .requested(requestCount: relationship.requestCount ?? 1)
        case .incomingRequest:
            return .incomingRequest(requestCount: relationship.requestCount ?? 1)
        case .peerReady:
            return .peerReady
        case .wakeReady:
            return .wakeReady
        case .waitingForPeer:
            return .waitingForPeer(reason: .backendSessionTransition)
        case .localJoinFailed:
            return .localJoinFailed(recoveryMessage: statusMessage)
        case .ready:
            return .ready
        case .startingTransmit:
            return .startingTransmit(stage: .awaitingAudioConnection(mediaState: .preparing))
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        case .blockedByOtherSession:
            return .blockedByOtherSession
        case .systemMismatch:
            return .systemMismatch
        }
    }
}

enum SessionReconciliationAction: Equatable {
    case none
    case restoreLocalSession(contactID: UUID)
    case teardownSelectedSession(contactID: UUID)
    case clearStaleBackendMembership(contactID: UUID)
}

struct ChannelReadinessSnapshot: Equatable {
    let membership: TurboChannelMembership
    let requestRelationship: TurboRequestRelationship
    let canTransmit: Bool
    let status: ConversationState?
    let readinessStatus: TurboChannelReadinessStatus?
    let activeTransmitterUserId: String?
    let activeTransmitId: String?
    let activeTransmitExpiresAt: String?
    let serverTimestamp: String?
    let localHasActiveDevice: Bool
    let localAudioReadiness: RemoteAudioReadinessState
    let remoteAudioReadiness: RemoteAudioReadinessState
    let remoteWakeCapability: RemoteWakeCapabilityState

    init(
        channelState: TurboChannelStateResponse,
        readiness: TurboChannelReadinessResponse? = nil
    ) {
        membership = channelState.membership
        requestRelationship = channelState.requestRelationship
        activeTransmitId = readiness?.activeTransmitId ?? channelState.activeTransmitId
        activeTransmitExpiresAt = readiness?.activeTransmitExpiresAt ?? channelState.transmitLeaseExpiresAt
        serverTimestamp = readiness?.serverTimestamp ?? channelState.serverTimestamp
        localHasActiveDevice = readiness?.selfHasActiveDevice ?? false
        localAudioReadiness = readiness?.localAudioReadiness ?? .unknown
        self.remoteAudioReadiness = readiness?.remoteAudioReadiness ?? .unknown
        self.remoteWakeCapability = readiness?.remoteWakeCapability ?? .unavailable
        if let readiness {
            canTransmit = readiness.canTransmit
            status = readiness.statusView.conversationState
            readinessStatus = readiness.statusView
            activeTransmitterUserId = readiness.statusView.activeTransmitterUserId
        } else {
            canTransmit = channelState.canTransmit
            status = channelState.conversationStatus
            readinessStatus = TurboChannelReadinessStatus(
                conversationStatus: channelState.statusView,
                canTransmit: channelState.canTransmit
            )
            activeTransmitterUserId = channelState.statusView.activeTransmitterUserId
        }
    }

    init(
        membership: TurboChannelMembership,
        requestRelationship: TurboRequestRelationship,
        canTransmit: Bool,
        status: ConversationState?,
        readinessStatus: TurboChannelReadinessStatus?,
        activeTransmitterUserId: String?,
        activeTransmitId: String?,
        activeTransmitExpiresAt: String?,
        serverTimestamp: String?,
        localHasActiveDevice: Bool,
        localAudioReadiness: RemoteAudioReadinessState,
        remoteAudioReadiness: RemoteAudioReadinessState,
        remoteWakeCapability: RemoteWakeCapabilityState
    ) {
        self.membership = membership
        self.requestRelationship = requestRelationship
        self.canTransmit = canTransmit
        self.status = status
        self.readinessStatus = readinessStatus
        self.activeTransmitterUserId = activeTransmitterUserId
        self.activeTransmitId = activeTransmitId
        self.activeTransmitExpiresAt = activeTransmitExpiresAt
        self.serverTimestamp = serverTimestamp
        self.localHasActiveDevice = localHasActiveDevice
        self.localAudioReadiness = localAudioReadiness
        self.remoteAudioReadiness = remoteAudioReadiness
        self.remoteWakeCapability = remoteWakeCapability
    }

    func replacingRequestRelationship(
        _ requestRelationship: TurboRequestRelationship,
        status: ConversationState?
    ) -> ChannelReadinessSnapshot {
        ChannelReadinessSnapshot(
            membership: membership,
            requestRelationship: requestRelationship,
            canTransmit: canTransmit,
            status: status,
            readinessStatus: readinessStatus,
            activeTransmitterUserId: activeTransmitterUserId,
            activeTransmitId: activeTransmitId,
            activeTransmitExpiresAt: activeTransmitExpiresAt,
            serverTimestamp: serverTimestamp,
            localHasActiveDevice: localHasActiveDevice,
            localAudioReadiness: localAudioReadiness,
            remoteAudioReadiness: remoteAudioReadiness,
            remoteWakeCapability: remoteWakeCapability
        )
    }

    var remoteAudioReadyForLiveTransmit: Bool {
        switch remoteAudioReadiness {
        case .ready:
            return true
        case .waiting, .wakeCapable:
            return false
        case .unknown:
            break
        }

        return membership.peerDeviceConnected && readinessStatus == .ready
    }
}

enum LocalSessionReadiness: Equatable {
    case none
    case partial
    case aligned
}

enum BackendChannelReadiness: Equatable {
    case absent
    case peerOnly(peerDeviceConnected: Bool, canTransmit: Bool, readinessStatus: TurboChannelReadinessStatus?)
    case selfOnly(canTransmit: Bool, readinessStatus: TurboChannelReadinessStatus?)
    case both(peerDeviceConnected: Bool, canTransmit: Bool, readinessStatus: TurboChannelReadinessStatus?)

    var status: ConversationState? {
        switch self {
        case .absent:
            return nil
        case .peerOnly(_, _, let readinessStatus), .selfOnly(_, let readinessStatus), .both(_, _, let readinessStatus):
            return readinessStatus?.conversationState
        }
    }

    var readinessStatus: TurboChannelReadinessStatus? {
        switch self {
        case .absent:
            return nil
        case .peerOnly(_, _, let readinessStatus), .selfOnly(_, let readinessStatus), .both(_, _, let readinessStatus):
            return readinessStatus
        }
    }

    var hasLocalMembership: Bool {
        switch self {
        case .selfOnly, .both:
            return true
        case .absent, .peerOnly:
            return false
        }
    }

    var hasPeerMembership: Bool {
        switch self {
        case .peerOnly, .both:
            return true
        case .absent, .selfOnly:
            return false
        }
    }

    var peerDeviceConnected: Bool {
        switch self {
        case .peerOnly(let peerDeviceConnected, _, _), .both(let peerDeviceConnected, _, _):
            return peerDeviceConnected
        case .absent, .selfOnly:
            return false
        }
    }

    var canTransmit: Bool {
        switch self {
        case .absent:
            return false
        case .peerOnly(_, let canTransmit, _), .selfOnly(let canTransmit, _), .both(_, let canTransmit, _):
            return canTransmit
        }
    }
}

struct ConversationDerivationContext: Equatable {
    let contactID: UUID
    let selectedContactID: UUID?
    let baseState: ConversationState
    let relationship: PairRelationshipState
    let contactName: String
    let contactIsOnline: Bool
    let contactPresence: ContactPresencePresentation
    let isJoined: Bool
    let localTransmit: LocalTransmitProjection
    let peerSignalIsTransmitting: Bool
    let activeChannelID: UUID?
    let systemSessionMatchesContact: Bool
    let systemSessionState: SystemPTTSessionState
    let pendingAction: PendingSessionAction
    let pendingConnectAcceptedIncomingRequest: Bool
    let localJoinFailure: PTTJoinFailure?
    let mediaState: MediaConnectionState
    let localMediaWarmupState: LocalMediaWarmupState
    let localRelayTransportReady: Bool
    let directMediaPathActive: Bool
    let firstTalkStartupProfile: FirstTalkStartupProfile
    let incomingWakeActivationState: IncomingWakeActivationState?
    let backendJoinSettling: Bool
    let backendSignalingJoinRecoveryActive: Bool
    let controlPlaneReconnectGraceActive: Bool
    let hadConnectedSessionContinuity: Bool
    let channel: ChannelReadinessSnapshot?

    init(
        contactID: UUID,
        selectedContactID: UUID?,
        baseState: ConversationState,
        relationship: PairRelationshipState = .none,
        contactName: String,
        contactIsOnline: Bool,
        contactPresence: ContactPresencePresentation? = nil,
        isJoined: Bool,
        localTransmit: LocalTransmitProjection? = nil,
        localIsTransmitting: Bool = false,
        localIsStopping: Bool = false,
        localRequiresFreshPress: Bool = false,
        localTransmitPhase: TransmitDomainPhase = .idle,
        localSystemIsTransmitting: Bool = false,
        localPTTAudioSessionActive: Bool = false,
        peerSignalIsTransmitting: Bool = false,
        activeChannelID: UUID?,
        systemSessionMatchesContact: Bool,
        systemSessionState: SystemPTTSessionState,
        pendingAction: PendingSessionAction,
        pendingConnectAcceptedIncomingRequest: Bool = false,
        localJoinFailure: PTTJoinFailure?,
        mediaState: MediaConnectionState = .idle,
        localMediaWarmupState: LocalMediaWarmupState = .cold,
        localRelayTransportReady: Bool = true,
        directMediaPathActive: Bool = false,
        firstTalkStartupProfile: FirstTalkStartupProfile = .relayWarm,
        incomingWakeActivationState: IncomingWakeActivationState? = nil,
        backendJoinSettling: Bool = false,
        backendSignalingJoinRecoveryActive: Bool = false,
        controlPlaneReconnectGraceActive: Bool = false,
        hadConnectedSessionContinuity: Bool = false,
        channel: ChannelReadinessSnapshot?
    ) {
        self.contactID = contactID
        self.selectedContactID = selectedContactID
        self.baseState = baseState
        self.relationship = relationship
        self.contactName = contactName
        self.contactIsOnline = contactIsOnline
        self.contactPresence = contactPresence ?? (contactIsOnline ? .connected : .offline)
        self.isJoined = isJoined
        self.localTransmit = localTransmit ?? LocalTransmitProjection.legacy(
            isTransmitting: localIsTransmitting,
            isStopping: localIsStopping,
            requiresFreshPress: localRequiresFreshPress,
            transmitPhase: localTransmitPhase,
            systemIsTransmitting: localSystemIsTransmitting,
            pttAudioSessionActive: localPTTAudioSessionActive,
            mediaState: mediaState
        )
        self.peerSignalIsTransmitting = peerSignalIsTransmitting
        self.activeChannelID = activeChannelID
        self.systemSessionMatchesContact = systemSessionMatchesContact
        self.systemSessionState = systemSessionState
        self.pendingAction = pendingAction
        self.pendingConnectAcceptedIncomingRequest = pendingConnectAcceptedIncomingRequest
        self.localJoinFailure = localJoinFailure
        self.mediaState = mediaState
        self.localMediaWarmupState = localMediaWarmupState
        self.localRelayTransportReady = localRelayTransportReady
        self.directMediaPathActive = directMediaPathActive
        self.firstTalkStartupProfile = firstTalkStartupProfile
        self.incomingWakeActivationState = incomingWakeActivationState
        self.backendJoinSettling = backendJoinSettling
        self.backendSignalingJoinRecoveryActive = backendSignalingJoinRecoveryActive
        self.controlPlaneReconnectGraceActive = controlPlaneReconnectGraceActive
        self.hadConnectedSessionContinuity = hadConnectedSessionContinuity
        self.channel = channel
    }

    var idleAvailabilityStatusMessage: String {
        switch contactPresence {
        case .connected:
            return "\(contactName) is online"
        case .reachable:
            return "Ready to connect"
        case .offline:
            return "Ready to connect"
        }
    }

    var connectionAttemptStatusMessage: String {
        switch contactPresence {
        case .offline:
            return "Waiting for \(contactName) to reconnect"
        case .connected, .reachable:
            return "Connecting..."
        }
    }

    var remoteAudioReadinessState: RemoteAudioReadinessState {
        channel?.remoteAudioReadiness ?? .unknown
    }

    var remoteWakeCapabilityState: RemoteWakeCapabilityState {
        channel?.remoteWakeCapability ?? .unavailable
    }

    var localIsTransmitting: Bool {
        localTransmit.hasTransmitIntent
    }

    var localIsStopping: Bool {
        localTransmit == .stopping
    }

    var localRequiresFreshPress: Bool {
        localTransmit == .releaseRequired
    }

    var explicitLeaveRequested: Bool {
        switch pendingAction {
        case .leave(.explicit(let contactID)):
            return contactID == nil || contactID == self.contactID
        case .none, .connect, .leave(.reconciledTeardown):
            return false
        }
    }

    var backendShowsConnectablePeerRecovery: Bool {
        guard !backendMembershipIsStaleWithoutLocalSessionEvidence else { return false }
        guard let channel else { return false }
        if channel.membership.hasPeerMembership {
            return true
        }
        return channel.canTransmit
    }

    var backendShowsWakeCapablePeerRecovery: Bool {
        guard let channel else { return false }
        guard !channel.membership.hasPeerMembership else { return false }
        guard !channel.canTransmit else { return false }
        if case .wakeCapable = channel.remoteWakeCapability {
            return true
        }
        return false
    }

    var backendExplicitlyInactiveWithoutMembership: Bool {
        guard !backendJoinSettling else { return false }
        guard let channel else { return false }
        guard channel.membership == .absent else { return false }
        return channel.readinessStatus == .inactive
    }

    var channelHasRequestRelationship: Bool {
        guard relationship == .none else { return true }
        guard let relationship = channel?.requestRelationship else { return false }
        return relationship != .none
    }

    var pendingJoinHasTerminalBackendMembershipLoss: Bool {
        guard !backendJoinSettling else { return false }
        guard pendingAction.pendingJoinContactID == contactID else { return false }
        guard localSessionReadiness != .none else { return false }
        guard let channel else { return false }
        guard channel.membership == .absent else { return false }
        guard channel.requestRelationship == .none else { return false }
        guard !explicitLeaveRequested else { return false }
        guard !peerSignalIsTransmitting else { return false }
        if channel.readinessStatus == .inactive {
            return true
        }
        if channel.status == .idle {
            return true
        }
        return !channel.canTransmit
    }

    var remoteAudioRecoveryAvailable: Bool {
        switch remoteAudioReadinessState {
        case .wakeCapable, .ready:
            return true
        case .unknown, .waiting:
            return false
        }
    }

    var wakeRecoveryInFlight: Bool {
        switch incomingWakeActivationState {
        case .signalBuffered, .awaitingSystemActivation, .appManagedFallback, .systemActivated:
            return systemSessionMatchesContact
        case .systemActivationTimedOutWaitingForForeground, .systemActivationInterruptedByTransmitEnd, .none:
            return false
        }
    }

    var shouldTreatSystemMismatchAsRecoverable: Bool {
        guard case .mismatched = systemSessionState else { return false }
        guard !explicitLeaveRequested else { return false }
        if systemMismatchChannelMatchesContact {
            return true
        }
        if unattributedJoinedSystemMismatch,
           !backendExplicitlyInactiveWithoutMembership {
            return true
        }
        if hadConnectedSessionContinuity {
            return true
        }
        if pendingAction.pendingJoinContactID == contactID {
            return true
        }
        if localSessionReadiness != .none {
            if channelHasRequestRelationship {
                return true
            }
            switch backendChannelReadiness {
            case .selfOnly, .both:
                return true
            case .absent, .peerOnly:
                break
            }
        }
        return false
    }

    var systemMismatchChannelMatchesContact: Bool {
        guard case .mismatched = systemSessionState else { return false }
        return systemSessionMatchesContact
    }

    var unattributedJoinedSystemMismatch: Bool {
        guard case .mismatched = systemSessionState else { return false }
        return isJoined && activeChannelID == nil
    }

    var pendingJoinIsStaleWithoutLocalSessionEvidence: Bool {
        guard pendingAction.pendingJoinContactID == contactID else { return false }
        guard localSessionReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected,
              readinessStatus == .ready else {
            return false
        }
        return true
    }

    var pendingBackendConnectIsReadyForLocalRestore: Bool {
        guard pendingAction.pendingConnectContactID == contactID else { return false }
        guard pendingAction.pendingJoinContactID == nil else { return false }
        guard localSessionReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected else {
            return false
        }
        return readinessStatus == .waitingForSelf || readinessStatus == .ready
    }

    var backendMembershipIsStaleWithoutLocalSessionEvidence: Bool {
        guard localSessionReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard activeChannelID == nil else { return false }
        guard pendingAction == .none else { return false }
        guard !explicitLeaveRequested else { return false }
        guard channel?.requestRelationship == TurboRequestRelationship.none else { return false }
        guard remoteAudioReadinessState != .waiting else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness else {
            return false
        }
        guard !peerDeviceConnected else { return false }
        return readinessStatus == .inactive
    }

    var backendMembershipCanRestoreMissingLocalSession: Bool {
        guard localSessionReadiness == .none else { return false }
        guard systemSessionState == .none else { return false }
        guard activeChannelID == nil else { return false }
        guard pendingAction == .none else { return false }
        guard !explicitLeaveRequested else { return false }
        guard channel?.requestRelationship == TurboRequestRelationship.none else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected,
              readinessStatus == .waitingForSelf else {
            return false
        }
        return true
    }

    var backendReadyAutoRestoreAllowed: Bool {
        if pendingBackendConnectIsReadyForLocalRestore {
            return true
        }
        if pendingAction.pendingJoinContactID == contactID {
            return true
        }
        if backendMembershipCanRestoreMissingLocalSession {
            return true
        }
        if backendReadyMembershipHasCurrentDeviceEvidence {
            return true
        }
        return hadConnectedSessionContinuity
    }

    var backendReadyMembershipHasCurrentDeviceEvidence: Bool {
        guard let channel else { return false }
        guard channel.localHasActiveDevice else { return false }
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected,
              readinessStatus == .ready else {
            return false
        }
        return true
    }
}

enum DurableSessionProjection: Equatable {
    case inactive
    case transitioning
    case connected
    case blockedByOtherSession
    case systemMismatch
    case localJoinFailed(recoveryMessage: String)
    case pendingJoin
    case disconnecting

    var localSessionPresent: Bool {
        switch self {
        case .transitioning, .connected, .disconnecting:
            return true
        case .inactive, .blockedByOtherSession, .systemMismatch, .localJoinFailed, .pendingJoin:
            return false
        }
    }
}

enum ConnectedExecutionProjection: Equatable {
    case wakeActivating
    case wakeDeferredUntilForeground(message: String)
    case stopping
    case releaseRequired
    case startingTransmit(StartingTransmitStage)
    case transmitting
}

enum ConnectedControlPlaneProjection: Equatable {
    case unavailable
    case wakeReady
    case waiting(reason: SelectedPeerWaitingReason, statusMessage: String)
    case ready
    case transmitting
    case receiving
}

struct SelectedPeerProjection: Equatable {
    let durableSession: DurableSessionProjection
    let connectedExecution: ConnectedExecutionProjection?
    let connectedControlPlane: ConnectedControlPlaneProjection
    let selectedPeerState: SelectedPeerState
    let reconciliationAction: SessionReconciliationAction
}

enum ConversationStateMachine {
    static func relationshipState(
        hasIncomingRequest: Bool,
        hasOutgoingRequest: Bool,
        requestCount: Int
    ) -> PairRelationshipState {
        let normalizedCount = max(requestCount, 1)
        if hasIncomingRequest && hasOutgoingRequest {
            return .mutualRequest(requestCount: normalizedCount)
        }
        if hasIncomingRequest {
            return .incomingRequest(requestCount: normalizedCount)
        }
        if hasOutgoingRequest {
            return .outgoingRequest(requestCount: normalizedCount)
        }
        return .none
    }

    static func effectiveState(for context: ConversationDerivationContext) -> ConversationState {
        guard context.selectedContactID == context.contactID else {
            return context.baseState
        }

        switch context.baseState {
        case .ready, .transmitting, .receiving:
            guard context.localSessionReadiness == .aligned else {
                return .waitingForPeer
            }
            guard case .both(let peerDeviceConnected, let canTransmit, _) = context.backendChannelReadiness,
                  peerDeviceConnected else {
                return .waitingForPeer
            }
            if !canTransmit && context.baseState != .receiving {
                return .waitingForPeer
            }
            return context.baseState
        case .idle, .requested, .incomingRequest, .waitingForPeer:
            return context.baseState
        }
    }

    static func selectedPeerState(
        for context: ConversationDerivationContext,
        relationship: PairRelationshipState
    ) -> SelectedPeerState {
        projection(for: context, relationship: relationship).selectedPeerState
    }

    static func projection(
        for context: ConversationDerivationContext,
        relationship: PairRelationshipState
    ) -> SelectedPeerProjection {
        let canTransmitNow = context.canTransmitNow
        let makeState: (SelectedPeerDetail, String, Bool) -> SelectedPeerState = { detail, statusMessage, canTransmitNow in
            SelectedPeerState(
                contactID: context.contactID,
                contactName: context.contactName,
                relationship: relationship,
                detail: detail,
                statusMessage: statusMessage,
                canTransmitNow: canTransmitNow
            )
        }

        let durableSession = context.durableSessionProjection
        let connectedExecution = context.connectedExecutionProjection
        let connectedControlPlane = context.connectedControlPlaneProjection
        let fallbackState: () -> SelectedPeerState = {
            let localSessionActive = durableSession.localSessionPresent

            if context.backendMembershipIsStaleWithoutLocalSessionEvidence {
                return makeState(
                    .idle(isOnline: context.contactIsOnline),
                    context.idleAvailabilityStatusMessage,
                    false
                )
            }

            if !localSessionActive, context.pendingConnectAcceptedIncomingRequest {
                return makeState(
                    .waitingForPeer(reason: .pendingJoin),
                    context.connectionAttemptStatusMessage,
                    false
                )
            }

            if !localSessionActive, context.backendJoinSettling {
                return makeState(
                    .waitingForPeer(reason: .backendSessionTransition),
                    context.connectionAttemptStatusMessage,
                    false
                )
            }

            switch context.backendChannelReadiness {
            case .peerOnly:
                if !localSessionActive {
                    return makeState(.peerReady, "\(context.contactName) is ready to connect", false)
                }
            case .selfOnly:
                if localSessionActive
                    || (
                        context.backendChannelReadiness.hasLocalMembership
                            && context.backendReadyAutoRestoreAllowed
                    ) {
                    return makeState(
                        .waitingForPeer(reason: .backendSessionTransition),
                        context.connectionAttemptStatusMessage,
                        false
                    )
                }
            case .both:
                if localSessionActive
                    || (
                        context.backendChannelReadiness.hasLocalMembership
                            && context.backendReadyAutoRestoreAllowed
                    ) {
                    let reason: SelectedPeerWaitingReason =
                        context.backendChannelReadiness.hasLocalMembership
                        ? .peerReadyToConnect
                        : .backendSessionTransition
                    return makeState(
                        .waitingForPeer(reason: reason),
                        context.connectionAttemptStatusMessage,
                        false
                    )
                }
            case .absent:
                break
            }

            // After backend resets or lagging summary refreshes, the backend can
            // still report a durable channel status before membership fields are
            // repopulated. Treat that as a connectable recovery state instead of
            // falling all the way back to idle/requested.
            if !localSessionActive,
               !context.backendChannelReadiness.hasLocalMembership,
               context.channel?.readinessStatus == .waitingForSelf {
                return makeState(.peerReady, "\(context.contactName) is ready to connect", false)
            }

            if !localSessionActive,
               context.backendChannelReadiness.hasLocalMembership,
               context.backendChannelReadiness.hasPeerMembership,
               context.channel?.readinessStatus == .inactive {
                return makeState(.peerReady, "\(context.contactName) is ready to connect", false)
            }

            if let channelStatus = context.channel?.status,
               context.backendShowsConnectablePeerRecovery
                || (!localSessionActive && context.backendShowsWakeCapablePeerRecovery) {
                switch channelStatus {
                case .waitingForPeer, .ready, .transmitting, .receiving:
                    if !localSessionActive {
                        return makeState(.peerReady, "\(context.contactName) is ready to connect", false)
                    }
                    return makeState(
                        .waitingForPeer(reason: .backendSessionTransition),
                        context.connectionAttemptStatusMessage,
                        false
                    )
                case .idle, .requested, .incomingRequest:
                    break
                }
            }

            if localSessionActive {
                return makeState(
                    .waitingForPeer(reason: .localSessionTransition),
                    context.connectionAttemptStatusMessage,
                    false
                )
            }

            switch relationship {
            case .incomingRequest, .mutualRequest:
                return makeState(
                    .incomingRequest(requestCount: relationship.requestCount ?? 1),
                    "\(context.contactName) wants to talk",
                    false
                )
            case .outgoingRequest:
                return makeState(
                    .requested(requestCount: relationship.requestCount ?? 1),
                    "Requested \(context.contactName)",
                    false
                )
            case .none:
                return makeState(
                    .idle(isOnline: context.contactIsOnline),
                    context.idleAvailabilityStatusMessage,
                    false
                )
            }
        }

        let selectedPeerState: SelectedPeerState = {
            switch durableSession {
            case .blockedByOtherSession:
                return makeState(.blockedByOtherSession, "Another session is active", false)
            case .systemMismatch:
                return makeState(.systemMismatch, "System session mismatch", false)
            case .localJoinFailed(let recoveryMessage):
                return makeState(
                    .localJoinFailed(recoveryMessage: recoveryMessage),
                    recoveryMessage,
                    false
                )
            case .pendingJoin:
                return makeState(
                    .waitingForPeer(reason: .pendingJoin),
                    context.connectionAttemptStatusMessage,
                    false
                )
            case .disconnecting:
                return makeState(.waitingForPeer(reason: .disconnecting), "Disconnecting...", false)
            case .connected:
                if let liveSessionState = connectedSelectedPeerState(
                    contactName: context.contactName,
                    connectedExecution: connectedExecution,
                    connectedControlPlane: connectedControlPlane,
                    durableSession: durableSession
                ) {
                    return makeState(liveSessionState.detail, liveSessionState.statusMessage, canTransmitNow)
                }
                return fallbackState()
            case .inactive, .transitioning:
                return fallbackState()
            }
        }()

        return SelectedPeerProjection(
            durableSession: durableSession,
            connectedExecution: connectedExecution,
            connectedControlPlane: connectedControlPlane,
            selectedPeerState: selectedPeerState,
            reconciliationAction: reconcileAction(for: context)
        )
    }

    static func listConversationState(for summary: TurboContactSummaryResponse) -> ConversationState {
        switch summary.requestRelationship {
        case .incoming, .outgoing, .mutual:
            let relationship = relationshipState(
                hasIncomingRequest: summary.requestRelationship.hasIncomingRequest,
                hasOutgoingRequest: summary.requestRelationship.hasOutgoingRequest,
                requestCount: summary.requestRelationship.requestCount ?? 0
            )
            return relationship.fallbackConversationState
        case .none:
            break
        }

        return summary.badge.conversationState
    }

    static func displayStatus(
        for conversationState: ConversationState,
        requestCount: Int?,
        presence: ContactPresencePresentation
    ) -> ConversationDisplayStatus {
        switch conversationState {
        case .requested:
            return .requested(direction: .outgoing, requestCount: max(requestCount ?? 1, 1))
        case .incomingRequest:
            return .requested(direction: .incoming, requestCount: max(requestCount ?? 1, 1))
        case .waitingForPeer:
            return .ready
        case .ready, .transmitting, .receiving:
            return .live
        case .idle:
            return presence == .connected ? .online : .offline
        }
    }

    static func contactListSection(for displayStatus: ConversationDisplayStatus) -> ConversationListSection {
        switch displayStatus {
        case .requested(let direction, _):
            switch direction {
            case .incoming:
                return .wantsToTalk
            case .outgoing:
                return .requested
            }
        case .ready, .live:
            return .readyToTalk
        case .offline, .online:
            return .contacts
        }
    }

    static func availabilityPill(
        for presence: ContactPresencePresentation,
        isBusy: Bool = false
    ) -> ConversationAvailabilityPill {
        if isBusy {
            return .busy
        }

        switch presence {
        case .connected, .reachable:
            return .online
        case .offline:
            return .offline
        }
    }

    static func contactListPresentation(
        for conversationState: ConversationState,
        requestCount: Int?,
        presence: ContactPresencePresentation,
        isBusy: Bool = false
    ) -> ContactListPresentation {
        let displayStatus = displayStatus(
            for: conversationState,
            requestCount: requestCount,
            presence: presence
        )
        return ContactListPresentation(
            displayStatus: displayStatus,
            section: contactListSection(for: displayStatus),
            availabilityPill: availabilityPill(for: presence, isBusy: isBusy),
            requestCount: displayStatus.requestCount
        )
    }

    static func statusMessage(for context: ConversationDerivationContext) -> String {
        let effectiveState = effectiveState(for: context)

        guard context.selectedContactID == context.contactID else {
            switch context.systemSessionState {
            case .none:
                return "Ready to connect"
            case .active:
                return "System session active"
            case .mismatched:
                return "System session mismatch"
            }
        }

        switch context.systemSessionState {
        case .active(let activeContactID, _) where activeContactID != context.contactID:
            return "Another session is active"
        case .mismatched:
            return "System session mismatch"
        default:
            break
        }

        if context.pendingAction.pendingJoinContactID == context.contactID {
            return "Connecting..."
        }

        switch effectiveState {
        case .idle:
            return context.idleAvailabilityStatusMessage
        case .requested:
            return "Requested \(context.contactName)"
        case .incomingRequest:
            return "\(context.contactName) wants to talk"
        case .waitingForPeer:
            if context.channel?.membership.hasLocalMembership == true {
                return "Connecting..."
            }
            return "Waiting for \(context.contactName)"
        case .ready:
            return context.canTransmitNow ? "Connected" : "Connecting..."
        case .transmitting:
            return "Talking to \(context.contactName)"
        case .receiving:
            return "\(context.contactName) is talking"
        }
    }

    static func talkButtonLabel(
        conversationState: ConversationState?,
        isSelectedChannelJoined: Bool,
        requestCooldownRemaining: Int?
    ) -> String {
        switch conversationState {
        case .incomingRequest:
            return "Accept"
        case .requested:
            if let requestCooldownRemaining {
                return "Ask again in \(requestCooldownRemaining)s"
            }
            return "Ask Again"
        case .waitingForPeer:
            return "Waiting for Peer"
        case .transmitting:
            return "Talking"
        case .receiving:
            return "Receiving"
        case .ready:
            return "Hold To Talk"
        case .idle, .none:
            return isSelectedChannelJoined ? "Waiting for Peer" : "Ask to Talk"
        }
    }

    static func primaryAction(
        conversationState: ConversationState?,
        isSelectedChannelJoined: Bool,
        canTransmitNow: Bool,
        isTransmitting: Bool,
        requestCooldownRemaining: Int?
    ) -> ConversationPrimaryAction {
        let label = talkButtonLabel(
            conversationState: conversationState,
            isSelectedChannelJoined: isSelectedChannelJoined,
            requestCooldownRemaining: requestCooldownRemaining
        )

        if canTransmitNow || conversationState == .transmitting {
            return ConversationPrimaryAction(
                kind: .holdToTalk,
                label: label,
                isEnabled: true,
                style: isTransmitting ? .active : .accent
            )
        }

        switch conversationState {
        case .incomingRequest:
            return ConversationPrimaryAction(kind: .connect, label: label, isEnabled: true, style: .accent)
        case .requested:
            return ConversationPrimaryAction(
                kind: .connect,
                label: label,
                isEnabled: requestCooldownRemaining == nil,
                style: requestCooldownRemaining == nil ? .accent : .muted
            )
        case .waitingForPeer, .receiving:
            return ConversationPrimaryAction(kind: .connect, label: label, isEnabled: false, style: .muted)
        case .idle, .ready, .none:
            return ConversationPrimaryAction(kind: .connect, label: label, isEnabled: true, style: .accent)
        case .transmitting:
            return ConversationPrimaryAction(kind: .holdToTalk, label: label, isEnabled: true, style: .active)
        }
    }

    static func primaryAction(
        selectedPeerState: SelectedPeerState,
        isSelectedChannelJoined: Bool,
        isTransmitting: Bool,
        requestCooldownRemaining: Int?
    ) -> ConversationPrimaryAction {
        switch selectedPeerState.phase {
        case .blockedByOtherSession, .systemMismatch:
            if selectedPeerState.conversationState == .requested {
                return ConversationPrimaryAction(
                    kind: .connect,
                    label: talkButtonLabel(
                        conversationState: .requested,
                        isSelectedChannelJoined: isSelectedChannelJoined,
                        requestCooldownRemaining: requestCooldownRemaining
                    ),
                    isEnabled: requestCooldownRemaining == nil,
                    style: .muted
                )
            }
            return ConversationPrimaryAction(
                kind: .connect,
                label: talkButtonLabel(
                    conversationState: selectedPeerState.conversationState,
                    isSelectedChannelJoined: isSelectedChannelJoined,
                    requestCooldownRemaining: requestCooldownRemaining
                ),
                isEnabled: false,
                style: .muted
            )
        case .peerReady:
            return ConversationPrimaryAction(
                kind: .connect,
                label: "Connect",
                isEnabled: true,
                style: .accent
            )
        case .wakeReady:
            return ConversationPrimaryAction(
                kind: .holdToTalk,
                label: "Hold To Talk",
                isEnabled: selectedPeerState.allowsHoldToTalk,
                style: .accent
            )
        case .localJoinFailed:
            return ConversationPrimaryAction(
                kind: .connect,
                label: "Try Again",
                isEnabled: true,
                style: .accent
            )
        case .waitingForPeer:
            if case .waitingForPeer(reason: .pendingJoin) = selectedPeerState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Connecting...",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .backendSessionTransition) = selectedPeerState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Connecting...",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .localSessionTransition) = selectedPeerState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Connecting...",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .peerReadyToConnect) = selectedPeerState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Connecting...",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .localAudioPrewarm) = selectedPeerState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Hold To Talk",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .localTransportWarmup) = selectedPeerState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Hold To Talk",
                    isEnabled: false,
                    style: .muted
                )
            }
            if case .waitingForPeer(reason: .releaseRequiredAfterInterruptedTransmit) = selectedPeerState.detail {
                return ConversationPrimaryAction(
                    kind: .holdToTalk,
                    label: "Release To Retry",
                    isEnabled: false,
                    style: .muted
                )
            }
            return primaryAction(
                conversationState: selectedPeerState.conversationState,
                isSelectedChannelJoined: isSelectedChannelJoined,
                canTransmitNow: selectedPeerState.canTransmitNow,
                isTransmitting: isTransmitting,
                requestCooldownRemaining: requestCooldownRemaining
            )
        case .ready:
            return ConversationPrimaryAction(
                kind: .holdToTalk,
                label: "Hold To Talk",
                isEnabled: selectedPeerState.allowsHoldToTalk,
                style: .accent
            )
        case .requested:
            return ConversationPrimaryAction(
                kind: .connect,
                label: talkButtonLabel(
                    conversationState: .requested,
                    isSelectedChannelJoined: isSelectedChannelJoined,
                    requestCooldownRemaining: requestCooldownRemaining
                ),
                isEnabled: false,
                style: .muted
            )
        case .idle, .incomingRequest, .startingTransmit, .transmitting, .receiving:
            return primaryAction(
                conversationState: selectedPeerState.conversationState,
                isSelectedChannelJoined: isSelectedChannelJoined,
                canTransmitNow: selectedPeerState.canTransmitNow,
                isTransmitting: isTransmitting,
                requestCooldownRemaining: requestCooldownRemaining
            )
        }
    }

    static func shouldShowCallScreen(
        selectedPeerState: SelectedPeerState,
        requestedExpanded: Bool
    ) -> Bool {
        if selectedPeerState.detail == .waitingForPeer(reason: .disconnecting) {
            return false
        }

        switch selectedPeerState.phase {
        case .waitingForPeer, .localJoinFailed, .ready, .wakeReady,
             .startingTransmit, .transmitting, .receiving,
             .blockedByOtherSession, .systemMismatch:
            return true
        case .peerReady:
            return requestedExpanded
        case .incomingRequest:
            return false
        case .requested:
            return false
        case .idle:
            return false
        }
    }

    static func reconciliationAction(for context: ConversationDerivationContext) -> SessionReconciliationAction {
        reconcileAction(for: context)
    }

    private static func reconcileAction(
        for context: ConversationDerivationContext
    ) -> SessionReconciliationAction {
        guard context.selectedContactID == context.contactID else {
            return .none
        }

        if context.pendingAction.pendingJoinContactID == context.contactID,
           !context.pendingJoinHasTerminalBackendMembershipLoss,
           !context.pendingJoinIsStaleWithoutLocalSessionEvidence {
            return .none
        }

        if context.pendingAction.pendingTeardownContactID == context.contactID {
            return .none
        }

        if let localJoinFailure = context.localJoinFailure,
           localJoinFailure.contactID == context.contactID,
           localJoinFailure.reason.blocksAutomaticRestore {
            return .none
        }

        let explicitLeaveRequested = context.explicitLeaveRequested

        switch context.durableSessionProjection {
        case .systemMismatch:
            return .teardownSelectedSession(contactID: context.contactID)
        case .inactive, .transitioning, .connected, .blockedByOtherSession, .localJoinFailed, .pendingJoin, .disconnecting:
            break
        }

        let localSessionActive = context.durableSessionProjection.localSessionPresent

        if context.localTransmit.preservesConnectedSession && localSessionActive {
            return .none
        }

        if explicitLeaveRequested,
           context.systemSessionState == .none,
           localSessionActive {
            return .teardownSelectedSession(contactID: context.contactID)
        }

        if context.wakeRecoveryInFlight && localSessionActive {
            return .none
        }

        if context.backendMembershipIsStaleWithoutLocalSessionEvidence {
            return .clearStaleBackendMembership(contactID: context.contactID)
        }

        switch context.backendChannelReadiness {
        case .absent:
            if localSessionActive,
               context.channel != nil,
               !context.backendJoinSettling,
               !context.systemMismatchChannelMatchesContact,
               !context.unattributedJoinedSystemMismatch,
               !context.channelHasRequestRelationship,
               !context.peerSignalIsTransmitting,
               !explicitLeaveRequested {
                return .teardownSelectedSession(contactID: context.contactID)
            }
            return .none
        case .peerOnly, .selfOnly, .both:
            break
        }

        let localRestoreInFlight =
            context.localSessionReadiness != .none
            || (
                context.pendingAction.pendingJoinContactID == context.contactID
                    && !context.pendingJoinIsStaleWithoutLocalSessionEvidence
            )

        if case .both(let peerDeviceConnected, _, _) = context.backendChannelReadiness,
           peerDeviceConnected,
           context.localSessionReadiness != .aligned,
           !localRestoreInFlight,
           context.backendReadyAutoRestoreAllowed,
           !explicitLeaveRequested {
            return .restoreLocalSession(contactID: context.contactID)
        }

        return .none
    }
}

private extension ConversationStateMachine {
    static func connectedSelectedPeerState(
        contactName: String,
        connectedExecution: ConnectedExecutionProjection?,
        connectedControlPlane: ConnectedControlPlaneProjection,
        durableSession: DurableSessionProjection
    ) -> (detail: SelectedPeerDetail, statusMessage: String)? {
        guard durableSession == .connected else {
            return nil
        }

        if let executionProjection = connectedExecution {
            switch executionProjection {
            case .wakeActivating:
                return (
                    .waitingForPeer(reason: .systemWakeActivation),
                    "Waiting for system audio activation..."
                )
            case .wakeDeferredUntilForeground(let message):
                return (
                    .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground),
                    message
                )
            case .stopping:
                return (
                    .ready,
                    "Connected"
                )
            case .releaseRequired:
                return (
                    .waitingForPeer(reason: .releaseRequiredAfterInterruptedTransmit),
                    "Release and press again."
                )
            case .startingTransmit(let stage):
                switch stage {
                case .requestingLease, .awaitingSystemTransmit, .awaitingAudioSession:
                    return (.startingTransmit(stage: stage), "Connecting...")
                case .awaitingAudioConnection(let mediaState):
                    switch mediaState {
                    case .failed:
                        return (.startingTransmit(stage: stage), "Audio unavailable")
                    case .preparing, .idle, .closed:
                        return (.startingTransmit(stage: stage), "Connecting...")
                    case .connected:
                        return (.transmitting, "Talking to \(contactName)")
                    }
                }
            case .transmitting:
                return (.transmitting, "Talking to \(contactName)")
            }
        }

        switch connectedControlPlane {
        case .unavailable:
            return nil
        case .wakeReady:
            return (.wakeReady, "Hold to talk to wake \(contactName)")
        case .waiting(let reason, let statusMessage):
            return (.waitingForPeer(reason: reason), statusMessage)
        case .ready:
            return (.ready, "Connected")
        case .transmitting:
            return (.transmitting, "Talking to \(contactName)")
        case .receiving:
            return (.receiving, "\(contactName) is talking")
        }
    }
}

private extension ConversationDerivationContext {
    var durableSessionProjection: DurableSessionProjection {
        switch systemSessionState {
        case .active(let activeContactID, _) where activeContactID != contactID:
            return .blockedByOtherSession
        case .mismatched:
            if shouldTreatSystemMismatchAsRecoverable {
                return .transitioning
            }
            return .systemMismatch
        case .none, .active:
            break
        }

        if let localJoinFailure,
           localJoinFailure.contactID == contactID,
           localJoinFailure.reason.blocksAutomaticRestore {
            return .localJoinFailed(recoveryMessage: localJoinFailure.reason.recoveryMessage)
        }

        if pendingAction.isLeaveInFlight(for: contactID) {
            return .disconnecting
        }

        if pendingJoinHasTerminalBackendMembershipLoss {
            return .disconnecting
        }

        if pendingAction.pendingJoinContactID == contactID {
            return .pendingJoin
        }

        if backendExplicitlyInactiveWithoutMembership,
           localSessionReadiness != .none {
            return .disconnecting
        }

        switch localSessionReadiness {
        case .none:
            return .inactive
        case .partial:
            return .transitioning
        case .aligned:
            return .connected
        }
    }

    var connectedExecutionProjection: ConnectedExecutionProjection? {
        guard durableSessionProjection == .connected else { return nil }

        if let incomingWakeActivationState {
            switch incomingWakeActivationState {
            case .signalBuffered, .awaitingSystemActivation:
                return .wakeActivating
            case .systemActivationTimedOutWaitingForForeground:
                return .wakeDeferredUntilForeground(
                    message: "Wake received, but system audio never activated. Unlock to resume audio."
                )
            case .systemActivationInterruptedByTransmitEnd:
                return .wakeDeferredUntilForeground(
                    message: "Wake ended before system audio activated."
                )
            case .appManagedFallback, .systemActivated:
                break
            }
        }

        if localIsStopping {
            return .stopping
        }

        if localRequiresFreshPress {
            return .releaseRequired
        }

        switch localTransmit {
        case .starting(let stage):
            return .startingTransmit(stage)
        case .transmitting:
            return .transmitting
        case .idle, .stopping, .releaseRequired:
            break
        }

        return nil
    }

    var connectedControlPlaneProjection: ConnectedControlPlaneProjection {
        guard durableSessionProjection == .connected,
              case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              let readinessStatus else {
            return .unavailable
        }

        let shouldPreferWakeReadyDespiteStalePeerConnectivity: Bool = {
            guard case .wakeCapable = remoteWakeCapabilityState,
                  hadConnectedSessionContinuity,
                  !peerDeviceConnected,
                  !canTransmit else {
                return false
            }

            switch readinessStatus {
            case .waitingForSelf, .waitingForPeer:
                switch remoteAudioReadinessState {
                case .wakeCapable, .unknown:
                    return true
                case .ready, .waiting:
                    return false
                }
            case .inactive, .ready, .selfTransmitting, .peerTransmitting, .unknown:
                return false
            }
        }()

        let effectivePeerDeviceConnected =
            peerDeviceConnected
            || directMediaPathActive
            || remoteAudioReadinessState == .ready
            || peerSignalIsTransmitting
            || readinessStatus.isTransmitActive
            || readinessStatus == .ready

        let sessionTransmitReady = effectivePeerDeviceConnected
        if sessionTransmitReady && peerSignalIsTransmitting {
            return .receiving
        }
        if shouldPreferWakeReadyDespiteStalePeerConnectivity {
            guard directMediaPathActive || localRelayTransportReady else {
                return .waiting(reason: .localTransportWarmup, statusMessage: "Connecting...")
            }
            return .wakeReady
        }

        let authoritativeBackendReady = backendReadyAuthoritativelySatisfiesRemoteAudio
        let authoritativeRecoveryReady =
            authoritativeBackendReady
            || backendReadyAuthoritativelySatisfiesWakeCapability

        if peerReadyHintOptimisticallySatisfiesConnectedUI {
            return .ready
        }

        if backendSignalingJoinRecoveryActive,
           !shouldPreserveConnectedReadinessDuringControlPlaneTransition,
           !authoritativeRecoveryReady {
            return .waiting(reason: .backendSessionTransition, statusMessage: "Connecting...")
        }

        if shouldPreserveConnectedReadinessDuringControlPlaneTransition,
           controlPlaneReconnectGraceActive,
           canTransmit {
            return .ready
        }

        if shouldPreserveConnectedReadinessDuringControlPlaneTransition,
           !canTransmit {
            return .waiting(reason: .backendSessionTransition, statusMessage: "Connecting...")
        }

        if sessionTransmitReady && canTransmit {
            guard directMediaPathActive || localRelayTransportReady else {
                return .waiting(reason: .localTransportWarmup, statusMessage: "Connecting...")
            }

            if directMediaPathActive {
                if remoteAudioReadinessState == .wakeCapable,
                   case .wakeCapable = remoteWakeCapabilityState,
                   !authoritativeBackendReady {
                    return .wakeReady
                }
                return .ready
            }

            if firstTalkStartupProfile == .directQuicWarming {
                return .waiting(reason: .localTransportWarmup, statusMessage: "Connecting...")
            }

            switch localMediaWarmupState {
            case .cold:
                if remoteAudioReadinessState == .wakeCapable,
                   case .wakeCapable = remoteWakeCapabilityState {
                    return .wakeReady
                }
                return .waiting(reason: .localAudioPrewarm, statusMessage: "Connecting...")
            case .prewarming:
                if remoteAudioReadinessState == .wakeCapable,
                   case .wakeCapable = remoteWakeCapabilityState {
                    return .wakeReady
                }
                return .waiting(reason: .localAudioPrewarm, statusMessage: "Connecting...")
            case .failed:
                return .waiting(reason: .localAudioPrewarm, statusMessage: "Audio unavailable")
            case .ready:
                break
            }

            if remoteAudioReadinessState == .wakeCapable,
               case .wakeCapable = remoteWakeCapabilityState {
                return .wakeReady
            }

            if authoritativeBackendReady {
                return .ready
            }

            switch remoteAudioReadinessState {
            case .ready:
                break
            case .wakeCapable:
                return .waiting(
                    reason: .remoteAudioPrewarm,
                    statusMessage: "Waiting for \(contactName)'s audio..."
                )
            case .waiting, .unknown:
                return .waiting(
                    reason: .remoteAudioPrewarm,
                    statusMessage: "Waiting for \(contactName)'s audio..."
                )
            }
        }

        if !effectivePeerDeviceConnected {
            switch remoteWakeCapabilityState {
            case .wakeCapable:
                if hadConnectedSessionContinuity {
                    return .wakeReady
                }
                return .waiting(
                    reason: .backendSessionTransition,
                    statusMessage: "Connecting..."
                )
            case .unavailable:
                return .waiting(
                    reason: .remoteWakeUnavailable,
                    statusMessage: "Waiting for \(contactName) to reconnect"
                )
            }
        }

        switch readinessStatus {
        case .peerTransmitting:
            guard sessionTransmitReady else {
                return .waiting(reason: .backendSessionTransition, statusMessage: "Connecting...")
            }
            return .receiving
        case .selfTransmitting:
            guard sessionTransmitReady else {
                return .waiting(reason: .backendSessionTransition, statusMessage: "Connecting...")
            }
            return .transmitting
        case .ready where canTransmit:
            return .ready
        case .waitingForSelf, .waitingForPeer, .ready:
            return .waiting(reason: .backendSessionTransition, statusMessage: "Connecting...")
        case .inactive, .unknown:
            return .unavailable
        }
    }

    var shouldPreserveConnectedReadinessDuringControlPlaneTransition: Bool {
        guard hadConnectedSessionContinuity,
              localSessionReadiness == .aligned,
              (directMediaPathActive || localRelayTransportReady),
              case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness,
              peerDeviceConnected else {
            return false
        }

        switch readinessStatus {
        case .waitingForSelf, .waitingForPeer:
            return true
        case .ready:
            return backendSignalingJoinRecoveryActive || controlPlaneReconnectGraceActive
        case .inactive, .selfTransmitting, .peerTransmitting, .unknown, .none:
            return false
        }
    }

    var effectivePeerDeviceConnectedForTransmit: Bool {
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness else {
            return false
        }

        return peerDeviceConnected
            || directMediaPathActive
            || remoteAudioReadinessState == .ready
            || peerSignalIsTransmitting
            || readinessStatus?.isTransmitActive == true
            || readinessStatus == .ready
    }

    var localSessionReadiness: LocalSessionReadiness {
        let hasAnyLocalSessionSignal =
            systemSessionMatchesContact
            || isJoined
            || activeChannelID == contactID
        guard hasAnyLocalSessionSignal else {
            return .none
        }

        let isAligned =
            systemSessionMatchesContact
            && isJoined
            && activeChannelID == contactID
        return isAligned ? .aligned : .partial
    }

    var backendChannelReadiness: BackendChannelReadiness {
        guard let channel else { return .absent }

        switch channel.membership {
        case .absent:
            return .absent
        case .peerOnly(let peerDeviceConnected):
            return .peerOnly(
                peerDeviceConnected: peerDeviceConnected,
                canTransmit: channel.canTransmit,
                readinessStatus: channel.readinessStatus
            )
        case .selfOnly:
            return .selfOnly(
                canTransmit: channel.canTransmit,
                readinessStatus: channel.readinessStatus
            )
        case .both(let peerDeviceConnected):
            return .both(
                peerDeviceConnected: peerDeviceConnected,
                canTransmit: channel.canTransmit,
                readinessStatus: channel.readinessStatus
            )
        }
    }

    var canTransmitNow: Bool {
        guard selectedContactID == contactID,
              localSessionReadiness == .aligned,
              localTransmit == .idle,
              (!backendSignalingJoinRecoveryActive || backendReadyAuthoritativelySatisfiesRemoteAudio),
              case .both(_, let canTransmit, _) = backendChannelReadiness,
              effectivePeerDeviceConnectedForTransmit else {
            return false
        }
        guard !firstTalkStartupProfile.blocksFirstTalkTransmit else {
            return false
        }
        let localMediaReadyForTransmit = localMediaWarmupState == .ready || directMediaPathActive
        let localTransportReadyForTransmit = directMediaPathActive || localRelayTransportReady
        return canTransmit
            && localMediaReadyForTransmit
            && localTransportReadyForTransmit
            && remoteAudioReadyForTransmit
    }

    var remoteAudioReadyForTransmit: Bool {
        if directMediaPathActive {
            if remoteAudioReadinessState == .wakeCapable,
               case .wakeCapable = remoteWakeCapabilityState {
                return backendReadyAuthoritativelySatisfiesRemoteAudio
            }
            return true
        }

        guard effectivePeerDeviceConnectedForTransmit else {
            return false
        }

        switch remoteAudioReadinessState {
        case .ready:
            return true
        case .wakeCapable, .waiting, .unknown:
            return backendReadyAuthoritativelySatisfiesRemoteAudio
        }
    }

    var backendReadyAuthoritativelySatisfiesRemoteAudio: Bool {
        guard case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              readinessStatus == .ready,
              peerDeviceConnected,
              canTransmit else {
            return false
        }

        switch remoteWakeCapabilityState {
        case .wakeCapable:
            return remoteAudioReadinessState == .ready
        case .unavailable:
            return remoteAudioReadinessState == .ready
        }
    }

    var backendReadyAuthoritativelySatisfiesWakeCapability: Bool {
        guard case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              readinessStatus == .ready,
              peerDeviceConnected,
              canTransmit,
              remoteAudioReadinessState == .wakeCapable,
              case .wakeCapable = remoteWakeCapabilityState else {
            return false
        }

        return true
    }

    var peerReadyHintOptimisticallySatisfiesConnectedUI: Bool {
        guard localSessionReadiness == .aligned else { return false }
        guard localMediaWarmupState == .ready || directMediaPathActive else { return false }
        guard directMediaPathActive || localRelayTransportReady else { return false }
        guard remoteAudioReadinessState == .ready,
              case .wakeCapable = remoteWakeCapabilityState else {
            return false
        }
        guard case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = backendChannelReadiness,
              canTransmit,
              peerDeviceConnected || directMediaPathActive else {
            return false
        }

        switch readinessStatus {
        case .waitingForSelf, .waitingForPeer, .ready:
            return true
        case .inactive, .selfTransmitting, .peerTransmitting, .unknown, .none:
            return false
        }
    }

    var startingTransmitStage: StartingTransmitStage? {
        localTransmit.startingTransmitStage
    }
}

private extension TurboChannelReadinessStatus {
    var isTransmitActive: Bool {
        switch self {
        case .selfTransmitting, .peerTransmitting:
            return true
        case .inactive, .waitingForSelf, .waitingForPeer, .ready, .unknown:
            return false
        }
    }
}

enum ContactDirectory {
    static let suggestedDevHandles: [String] = [
        "@turbo-ios",
        "@alice",
        "@bob",
        "@avery",
        "@blake",
        "@casey",
        "@devin",
        "@elliot",
        "@finley",
        "@gray",
        "@harper",
        "@indigo",
        "@jules",
        "@kai",
        "@logan",
        "@maya",
        "@noel",
        "@orion",
        "@parker",
        "@quinn",
        "@riley",
        "@sasha",
        "@tatum",
    ]

    static func ensureContact(
        handle: String,
        remoteUserId: String,
        channelId: String,
        displayName: String? = nil,
        localName: String? = nil,
        existingContacts: [Contact]
    ) -> (contacts: [Contact], contactID: UUID) {
        let normalizedHandle = Contact.normalizedHandle(handle)
        let stableID = Contact.stableID(remoteUserId: remoteUserId, fallbackHandle: normalizedHandle)
        let stableChannelID = channelId.isEmpty ? nil : stableChannelUUID(for: channelId)
        let normalizedLocalName = Contact.normalizedLocalName(localName)

        var contacts = existingContacts
        if let index = contacts.firstIndex(where: {
            ($0.remoteUserId != nil && $0.remoteUserId == remoteUserId)
                || Contact.normalizedHandle($0.handle) == normalizedHandle
        }) {
            if let displayName {
                contacts[index].profileName = Contact.normalizedProfileName(
                    displayName,
                    fallbackHandle: normalizedHandle
                )
            }
            contacts[index].localName = normalizedLocalName
            contacts[index].handle = normalizedHandle
            contacts[index].remoteUserId = remoteUserId
            if let stableChannelID {
                contacts[index].backendChannelId = channelId
                contacts[index].channelId = stableChannelID
            } else if contacts[index].backendChannelId != nil {
                contacts[index].backendChannelId = nil
                contacts[index].channelId = UUID()
            }
            return (contacts, contacts[index].id)
        }

        let normalizedProfileName =
            Contact.normalizedProfileName(displayName ?? "", fallbackHandle: normalizedHandle)

        contacts.append(
            Contact(
                id: stableID,
                profileName: normalizedProfileName,
                localName: normalizedLocalName,
                handle: normalizedHandle,
                isOnline: false,
                channelId: stableChannelID ?? UUID(),
                backendChannelId: channelId.isEmpty ? nil : channelId,
                remoteUserId: remoteUserId
            )
        )
        contacts.sort { $0.handle < $1.handle }
        return (contacts, stableID)
    }

    static func retainedContacts(
        existingContacts: [Contact],
        authoritativeContactIDs: Set<UUID>
    ) -> [Contact] {
        existingContacts
            .filter { authoritativeContactIDs.contains($0.id) }
            .sorted { $0.handle < $1.handle }
    }

    static func authoritativeContactIDs(
        trackedContactIDs: Set<UUID>,
        summaryContactIDs: Set<UUID>,
        selectedContactID: UUID?,
        activeChannelID: UUID?,
        mediaSessionContactID: UUID?,
        pendingJoinContactID: UUID?,
        inviteContactIDs: Set<UUID>
    ) -> Set<UUID> {
        var ids = trackedContactIDs
            .union(summaryContactIDs)
            .union(inviteContactIDs)
        if let selectedContactID {
            ids.insert(selectedContactID)
        }
        if let activeChannelID {
            ids.insert(activeChannelID)
        }
        if let mediaSessionContactID {
            ids.insert(mediaSessionContactID)
        }
        if let pendingJoinContactID {
            ids.insert(pendingJoinContactID)
        }
        return ids
    }

    static func stableChannelUUID(for backendChannelID: String) -> UUID {
        let digest = SHA256.hash(data: Data("channel:\(backendChannelID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
