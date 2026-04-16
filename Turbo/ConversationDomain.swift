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
    let name: String
    let handle: String
    var isOnline: Bool
    var channelId: UUID
    var backendChannelId: String?
    var remoteUserId: String?

    static func stableID(for handle: String) -> UUID {
        let digest = SHA256.hash(data: Data("contact:\(normalizedHandle(handle))".utf8))
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

    static func displayName(for handle: String) -> String {
        let raw = normalizedHandle(handle).dropFirst()
        guard !raw.isEmpty else { return normalizedHandle(handle) }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func normalizedHandle(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "@turbo-ios" }
        return trimmed.hasPrefix("@") ? trimmed.lowercased() : "@\(trimmed.lowercased())"
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

struct SessionCoordinatorState: Equatable {
    private(set) var pendingAction: PendingSessionAction = .none

    var pendingJoinContactID: UUID? {
        pendingAction.pendingJoinContactID
    }

    mutating func queueConnect(contactID: UUID) {
        pendingAction = .connect(.requestingBackend(contactID: contactID))
    }

    mutating func queueJoin(contactID: UUID) {
        if case .leave(.explicit(let pendingContactID)) = pendingAction,
           pendingContactID == nil || pendingContactID == contactID {
            return
        }
        pendingAction = .connect(.joiningLocal(contactID: contactID))
    }

    mutating func markExplicitLeave(contactID: UUID?) {
        pendingAction = .leave(.explicit(contactID: contactID))
    }

    mutating func markReconciledTeardown(contactID: UUID) {
        pendingAction = .leave(.reconciledTeardown(contactID: contactID))
    }

    mutating func clearAfterSuccessfulJoin(for contactID: UUID) {
        if pendingJoinContactID == contactID {
            pendingAction = .none
        }
    }

    mutating func clearPendingJoin(for contactID: UUID) {
        if pendingJoinContactID == contactID {
            pendingAction = .none
        }
    }

    mutating func clearPendingConnect(for contactID: UUID) {
        if pendingAction.pendingConnectContactID == contactID {
            pendingAction = .none
        }
    }

    mutating func clearExplicitLeave(for contactID: UUID?) {
        guard case .leave(.explicit(let pendingContactID)) = pendingAction else { return }
        if pendingContactID == nil || pendingContactID == contactID {
            pendingAction = .none
        }
    }

    mutating func clearLeaveAction(for contactID: UUID?) {
        switch pendingAction {
        case .leave(.explicit(let pendingContactID)):
            if pendingContactID == nil || pendingContactID == contactID {
                pendingAction = .none
            }
        case .leave(.reconciledTeardown(let pendingContactID)):
            if pendingContactID == contactID {
                pendingAction = .none
            }
        case .none, .connect:
            break
        }
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
            clearExplicitLeave(for: contactID)
        }
    }

    mutating func select(contactID: UUID) {
        switch pendingAction {
        case .connect(.joiningLocal(let pendingContactID)) where pendingContactID != contactID:
            pendingAction = .none
        case .leave(.explicit(let pendingContactID)) where pendingContactID != nil && pendingContactID != contactID:
            pendingAction = .none
        default:
            break
        }
    }

    mutating func reset() {
        pendingAction = .none
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
}

enum SelectedPeerWaitingReason: Equatable {
    case pendingJoin
    case disconnecting
    case localSessionTransition
    case releaseRequiredAfterInterruptedTransmit
    case localAudioPrewarm
    case systemWakeActivation
    case wakePlaybackDeferredUntilForeground
    case remoteAudioPrewarm
    case remoteWakeUnavailable
    case backendSessionTransition
    case peerReadyToConnect
}

enum LocalMediaWarmupState: Equatable {
    case cold
    case prewarming
    case ready
    case failed
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
    case startingTransmit(mediaState: MediaConnectionState)
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
        canTransmitNow || phase == .wakeReady || phase == .transmitting || phase == .startingTransmit
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
            return .startingTransmit(mediaState: .preparing)
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
}

struct ChannelReadinessSnapshot: Equatable {
    let membership: TurboChannelMembership
    let requestRelationship: TurboRequestRelationship
    let canTransmit: Bool
    let status: ConversationState?
    let readinessStatus: TurboChannelReadinessStatus?
    let activeTransmitterUserId: String?
    let remoteAudioReadiness: RemoteAudioReadinessState
    let remoteWakeCapability: RemoteWakeCapabilityState

    init(
        channelState: TurboChannelStateResponse,
        readiness: TurboChannelReadinessResponse? = nil
    ) {
        membership = channelState.membership
        requestRelationship = channelState.requestRelationship
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
    let contactName: String
    let contactIsOnline: Bool
    let isJoined: Bool
    let localIsTransmitting: Bool
    let localIsStopping: Bool
    let localRequiresFreshPress: Bool
    let peerSignalIsTransmitting: Bool
    let activeChannelID: UUID?
    let systemSessionMatchesContact: Bool
    let systemSessionState: SystemPTTSessionState
    let pendingAction: PendingSessionAction
    let localJoinFailure: PTTJoinFailure?
    let mediaState: MediaConnectionState
    let localMediaWarmupState: LocalMediaWarmupState
    let incomingWakeActivationState: IncomingWakeActivationState?
    let channel: ChannelReadinessSnapshot?

    init(
        contactID: UUID,
        selectedContactID: UUID?,
        baseState: ConversationState,
        contactName: String,
        contactIsOnline: Bool,
        isJoined: Bool,
        localIsTransmitting: Bool = false,
        localIsStopping: Bool = false,
        localRequiresFreshPress: Bool = false,
        peerSignalIsTransmitting: Bool = false,
        activeChannelID: UUID?,
        systemSessionMatchesContact: Bool,
        systemSessionState: SystemPTTSessionState,
        pendingAction: PendingSessionAction,
        localJoinFailure: PTTJoinFailure?,
        mediaState: MediaConnectionState = .idle,
        localMediaWarmupState: LocalMediaWarmupState = .cold,
        incomingWakeActivationState: IncomingWakeActivationState? = nil,
        channel: ChannelReadinessSnapshot?
    ) {
        self.contactID = contactID
        self.selectedContactID = selectedContactID
        self.baseState = baseState
        self.contactName = contactName
        self.contactIsOnline = contactIsOnline
        self.isJoined = isJoined
        self.localIsTransmitting = localIsTransmitting
        self.localIsStopping = localIsStopping
        self.localRequiresFreshPress = localRequiresFreshPress
        self.peerSignalIsTransmitting = peerSignalIsTransmitting
        self.activeChannelID = activeChannelID
        self.systemSessionMatchesContact = systemSessionMatchesContact
        self.systemSessionState = systemSessionState
        self.pendingAction = pendingAction
        self.localJoinFailure = localJoinFailure
        self.mediaState = mediaState
        self.localMediaWarmupState = localMediaWarmupState
        self.incomingWakeActivationState = incomingWakeActivationState
        self.channel = channel
    }

    var remoteAudioReadinessState: RemoteAudioReadinessState {
        channel?.remoteAudioReadiness ?? .unknown
    }

    var remoteWakeCapabilityState: RemoteWakeCapabilityState {
        channel?.remoteWakeCapability ?? .unavailable
    }
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
        let canTransmitNow = context.canTransmitNow
        let leaveInFlight = context.pendingAction.isLeaveInFlight(for: context.contactID)
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

        switch context.systemSessionState {
        case .active(let activeContactID, _) where activeContactID != context.contactID:
            return makeState(.blockedByOtherSession, "Another session is active", false)
        case .mismatched:
            return makeState(.systemMismatch, "System session mismatch", false)
        case .none, .active:
            break
        }

        if let localJoinFailure = context.localJoinFailure,
           localJoinFailure.contactID == context.contactID,
           localJoinFailure.reason.blocksAutomaticRestore {
            return makeState(
                .localJoinFailed(recoveryMessage: localJoinFailure.reason.recoveryMessage),
                localJoinFailure.reason.recoveryMessage,
                false
            )
        }

        if context.pendingAction.pendingJoinContactID == context.contactID {
            return makeState(.waitingForPeer(reason: .pendingJoin), "Connecting...", false)
        }

        let localSessionActive = context.localSessionReadiness != .none

        if leaveInFlight && localSessionActive {
            return makeState(.waitingForPeer(reason: .disconnecting), "Disconnecting...", false)
        }

        if let liveSessionState = liveSelectedSessionState(for: context) {
            return makeState(liveSessionState.detail, liveSessionState.statusMessage, canTransmitNow)
        }

        switch context.backendChannelReadiness {
        case .peerOnly:
            if !localSessionActive {
                return makeState(.peerReady, "\(context.contactName) is ready to connect", false)
            }
        case .selfOnly, .both:
            if localSessionActive || context.backendChannelReadiness.hasLocalMembership {
                let reason: SelectedPeerWaitingReason = context.backendChannelReadiness.hasLocalMembership ? .peerReadyToConnect : .backendSessionTransition
                return makeState(.waitingForPeer(reason: reason), "Connecting...", false)
            }
        case .absent:
            break
        }

        if localSessionActive {
            return makeState(.waitingForPeer(reason: .localSessionTransition), "Connecting...", false)
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
                context.contactIsOnline ? "\(context.contactName) is online" : "Ready to connect",
                false
            )
        }
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
            return context.contactIsOnline ? "\(context.contactName) is online" : "Ready to connect"
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
            return "Join Request"
        case .requested:
            if let requestCooldownRemaining {
                return "Request again in \(requestCooldownRemaining)s"
            }
            return "Request Again"
        case .waitingForPeer:
            return "Waiting for Peer"
        case .transmitting:
            return "Talking"
        case .receiving:
            return "Receiving"
        case .ready:
            return "Hold To Talk"
        case .idle, .none:
            return isSelectedChannelJoined ? "Waiting for Peer" : "Connect"
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
                style: .muted
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
        case .waitingForPeer:
            if case .waitingForPeer(reason: .localAudioPrewarm) = selectedPeerState.detail {
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
        case .idle, .requested, .incomingRequest, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving:
            return primaryAction(
                conversationState: selectedPeerState.conversationState,
                isSelectedChannelJoined: isSelectedChannelJoined,
                canTransmitNow: selectedPeerState.canTransmitNow,
                isTransmitting: isTransmitting,
                requestCooldownRemaining: requestCooldownRemaining
            )
        }
    }

    static func reconciliationAction(for context: ConversationDerivationContext) -> SessionReconciliationAction {
        guard context.selectedContactID == context.contactID else {
            return .none
        }

        if context.pendingAction.pendingJoinContactID == context.contactID {
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

        let explicitLeaveRequested: Bool
        switch context.pendingAction {
        case .leave(.explicit(let contactID)):
            explicitLeaveRequested = contactID == nil || contactID == context.contactID
        case .none, .connect, .leave(.reconciledTeardown):
            explicitLeaveRequested = false
        }

        switch context.systemSessionState {
        case .mismatched:
            return .teardownSelectedSession(contactID: context.contactID)
        case .none, .active:
            break
        }

        let localSessionActive = context.localSessionReadiness != .none

        if (context.localIsTransmitting || context.localIsStopping) && localSessionActive {
            return .none
        }

        if explicitLeaveRequested,
           context.systemSessionState == .none,
           localSessionActive {
            return .teardownSelectedSession(contactID: context.contactID)
        }

        switch context.backendChannelReadiness {
        case .absent:
            return localSessionActive ? .teardownSelectedSession(contactID: context.contactID) : .none
        case .peerOnly, .selfOnly, .both:
            break
        }

        let localRestoreInFlight =
            context.localSessionReadiness != .none
            || context.pendingAction.pendingJoinContactID == context.contactID

        if case .both(let peerDeviceConnected, _, _) = context.backendChannelReadiness,
           peerDeviceConnected,
           context.localSessionReadiness != .aligned,
           !localRestoreInFlight,
           !explicitLeaveRequested {
            return .restoreLocalSession(contactID: context.contactID)
        }

        if !context.backendChannelReadiness.hasLocalMembership && localSessionActive {
            let backendSessionClearlyGone =
                !context.backendChannelReadiness.hasPeerMembership
                && context.backendChannelReadiness.peerDeviceConnected == false
                && context.backendChannelReadiness.readinessStatus?.isPeerTransmitting != true

            if backendSessionClearlyGone {
                return .teardownSelectedSession(contactID: context.contactID)
            }
        }

        return .none
    }
}

private extension ConversationStateMachine {
    static func liveSelectedSessionState(
        for context: ConversationDerivationContext
    ) -> (detail: SelectedPeerDetail, statusMessage: String)? {
        guard context.localSessionReadiness == .aligned,
              case .both(let peerDeviceConnected, let canTransmit, let readinessStatus) = context.backendChannelReadiness,
              let readinessStatus else {
            return nil
        }

        let effectivePeerDeviceConnected =
            peerDeviceConnected
            || context.remoteAudioReadinessState == .ready
            || context.peerSignalIsTransmitting
            || readinessStatus.isTransmitActive
            || readinessStatus == .ready

        let sessionTransmitReady = effectivePeerDeviceConnected

        if let incomingWakeActivationState = context.incomingWakeActivationState {
            switch incomingWakeActivationState {
            case .signalBuffered, .awaitingSystemActivation:
                return (
                    .waitingForPeer(reason: .systemWakeActivation),
                    "Waiting for system audio activation..."
                )
            case .systemActivationTimedOutWaitingForForeground:
                return (
                    .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground),
                    "Wake received, but system audio never activated. Unlock to resume audio."
                )
            case .systemActivationInterruptedByTransmitEnd:
                return (
                    .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground),
                    "Wake ended before system audio activated."
                )
            case .appManagedFallback, .systemActivated:
                break
            }
        }

        if context.localIsStopping {
            return (
                .waitingForPeer(reason: .localSessionTransition),
                "Stopping..."
            )
        }

        if context.localRequiresFreshPress {
            return (
                .waitingForPeer(reason: .releaseRequiredAfterInterruptedTransmit),
                "Release and press again."
            )
        }

        if sessionTransmitReady && context.localIsTransmitting {
            switch context.mediaState {
            case .connected:
                return (.transmitting, "Talking to \(context.contactName)")
            case .preparing, .idle, .closed:
                return (.startingTransmit(mediaState: context.mediaState), "Establishing audio...")
            case .failed:
                return (.startingTransmit(mediaState: context.mediaState), "Audio unavailable")
            }
        }

        if sessionTransmitReady && context.peerSignalIsTransmitting {
            return (.receiving, "\(context.contactName) is talking")
        }

        if sessionTransmitReady && canTransmit {
            switch context.localMediaWarmupState {
            case .cold, .prewarming:
                return (.waitingForPeer(reason: .localAudioPrewarm), "Preparing audio...")
            case .failed:
                return (.waitingForPeer(reason: .localAudioPrewarm), "Audio unavailable")
            case .ready:
                break
            }
            switch context.remoteAudioReadinessState {
            case .ready:
                break
            case .wakeCapable:
                if case .wakeCapable = context.remoteWakeCapabilityState {
                    return (.wakeReady, "Hold to talk to wake \(context.contactName)")
                }
                return (.waitingForPeer(reason: .remoteAudioPrewarm), "Waiting for \(context.contactName)'s audio...")
            case .waiting, .unknown:
                if !peerDeviceConnected,
                   case .wakeCapable = context.remoteWakeCapabilityState {
                    return (.wakeReady, "Hold to talk to wake \(context.contactName)")
                }
                return (.waitingForPeer(reason: .remoteAudioPrewarm), "Waiting for \(context.contactName)'s audio...")
            }
        }

        if !effectivePeerDeviceConnected {
            switch context.remoteWakeCapabilityState {
            case .wakeCapable:
                return (.wakeReady, "Hold to talk to wake \(context.contactName)")
            case .unavailable:
                return (.waitingForPeer(reason: .remoteWakeUnavailable), "Waiting for \(context.contactName) to reconnect")
            }
        }

        switch readinessStatus {
        case .peerTransmitting:
            guard sessionTransmitReady else {
                return (.waitingForPeer(reason: .backendSessionTransition), "Establishing connection...")
            }
            return (.receiving, "\(context.contactName) is talking")
        case .selfTransmitting:
            guard sessionTransmitReady else {
                return (.waitingForPeer(reason: .backendSessionTransition), "Establishing connection...")
            }
            switch context.mediaState {
            case .connected:
                return (.transmitting, "Talking to \(context.contactName)")
            case .preparing, .idle, .closed:
                return (.startingTransmit(mediaState: context.mediaState), "Establishing audio...")
            case .failed:
                return (.startingTransmit(mediaState: context.mediaState), "Audio unavailable")
            }
        case .ready where canTransmit:
            return (.ready, "Connected")
        case .waitingForSelf, .waitingForPeer, .ready:
            return (.waitingForPeer(reason: .backendSessionTransition), "Establishing connection...")
        case .unknown:
            return nil
        }
    }
}

private extension ConversationDerivationContext {
    var effectivePeerDeviceConnectedForTransmit: Bool {
        guard case .both(let peerDeviceConnected, _, let readinessStatus) = backendChannelReadiness else {
            return false
        }

        return peerDeviceConnected
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
              case .both(_, let canTransmit, _) = backendChannelReadiness,
              effectivePeerDeviceConnectedForTransmit else {
            return false
        }
        return canTransmit
            && localMediaWarmupState == .ready
            && remoteAudioReadinessState == .ready
    }
}

private extension TurboChannelReadinessStatus {
    var isTransmitActive: Bool {
        switch self {
        case .selfTransmitting, .peerTransmitting:
            return true
        case .waitingForSelf, .waitingForPeer, .ready, .unknown:
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
        existingContacts: [Contact]
    ) -> (contacts: [Contact], contactID: UUID) {
        let normalizedHandle = Contact.normalizedHandle(handle)
        let stableID = Contact.stableID(for: normalizedHandle)
        let stableChannelID = channelId.isEmpty ? nil : stableChannelUUID(for: channelId)

        var contacts = existingContacts
        if let index = contacts.firstIndex(where: { Contact.normalizedHandle($0.handle) == normalizedHandle }) {
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

        contacts.append(
            Contact(
                id: stableID,
                name: Contact.displayName(for: normalizedHandle),
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
        selectedContactID: UUID?,
        activeChannelID: UUID?,
        mediaSessionContactID: UUID?,
        pendingJoinContactID: UUID?,
        inviteContactIDs: Set<UUID>
    ) -> Set<UUID> {
        var ids = trackedContactIDs.union(inviteContactIDs)
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
