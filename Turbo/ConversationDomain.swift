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

enum PendingSessionAction: Equatable {
    case none
    case connect(contactID: UUID)
    case join(contactID: UUID)
    case explicitLeave(contactID: UUID?)
    case teardown(contactID: UUID)

    var pendingConnectContactID: UUID? {
        switch self {
        case .connect(let contactID), .join(let contactID):
            return contactID
        case .none, .explicitLeave, .teardown:
            return nil
        }
    }

    var pendingJoinContactID: UUID? {
        switch self {
        case .join(let contactID):
            return contactID
        case .none, .connect, .explicitLeave, .teardown:
            return nil
        }
    }

    var pendingTeardownContactID: UUID? {
        guard case .teardown(let contactID) = self else { return nil }
        return contactID
    }

    var blocksAutoRejoin: Bool {
        switch self {
        case .explicitLeave, .teardown:
            return true
        case .none, .connect, .join:
            return false
        }
    }

    func isLeaveInFlight(for contactID: UUID) -> Bool {
        switch self {
        case .explicitLeave(let pendingContactID):
            return pendingContactID == nil || pendingContactID == contactID
        case .teardown(let pendingContactID):
            return pendingContactID == contactID
        case .none, .connect, .join:
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
        pendingAction = .connect(contactID: contactID)
    }

    mutating func queueJoin(contactID: UUID) {
        if case .explicitLeave(let pendingContactID) = pendingAction,
           pendingContactID == nil || pendingContactID == contactID {
            return
        }
        pendingAction = .join(contactID: contactID)
    }

    mutating func markExplicitLeave(contactID: UUID?) {
        pendingAction = .explicitLeave(contactID: contactID)
    }

    mutating func markReconciledTeardown(contactID: UUID) {
        pendingAction = .teardown(contactID: contactID)
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
        guard case .explicitLeave(let pendingContactID) = pendingAction else { return }
        if pendingContactID == nil || pendingContactID == contactID {
            pendingAction = .none
        }
    }

    mutating func clearLeaveAction(for contactID: UUID?) {
        switch pendingAction {
        case .explicitLeave(let pendingContactID):
            if pendingContactID == nil || pendingContactID == contactID {
                pendingAction = .none
            }
        case .teardown(let pendingContactID):
            if pendingContactID == contactID {
                pendingAction = .none
            }
        case .none, .connect, .join:
            break
        }
    }

    mutating func reconcileAfterChannelRefresh(
        for contactID: UUID,
        effectiveChannelState: TurboChannelStateResponse,
        localSessionEstablished: Bool,
        localSessionCleared: Bool
    ) {
        if effectiveChannelState.selfJoined, localSessionEstablished {
            clearAfterSuccessfulJoin(for: contactID)
        } else if !effectiveChannelState.selfJoined, localSessionCleared {
            clearExplicitLeave(for: contactID)
        }
    }

    mutating func select(contactID: UUID) {
        switch pendingAction {
        case .join(let pendingContactID) where pendingContactID != contactID:
            pendingAction = .none
        case .explicitLeave(let pendingContactID) where pendingContactID != contactID:
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

    var isIncomingRequest: Bool {
        if case .incomingRequest = self {
            return true
        }
        return false
    }

    var isOutgoingRequest: Bool {
        if case .outgoingRequest = self {
            return true
        }
        return false
    }

    var fallbackConversationState: ConversationState {
        switch self {
        case .none:
            return .idle
        case .outgoingRequest:
            return .requested
        case .incomingRequest:
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

struct SelectedPeerState: Equatable {
    let relationship: PairRelationshipState
    let phase: SelectedPeerPhase
    let statusMessage: String
    let canTransmitNow: Bool

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
}

enum SessionReconciliationAction: Equatable {
    case none
    case restoreLocalSession(contactID: UUID)
    case teardownSelectedSession(contactID: UUID)
}

struct ChannelReadinessSnapshot: Equatable {
    let selfJoined: Bool
    let peerJoined: Bool
    let peerDeviceConnected: Bool
    let hasIncomingRequest: Bool
    let hasOutgoingRequest: Bool
    let canTransmit: Bool
    let status: ConversationState?

    init(channelState: TurboChannelStateResponse) {
        selfJoined = channelState.selfJoined
        peerJoined = channelState.peerJoined
        peerDeviceConnected = channelState.peerDeviceConnected
        hasIncomingRequest = channelState.hasIncomingRequest
        hasOutgoingRequest = channelState.hasOutgoingRequest
        canTransmit = channelState.canTransmit
        status = ConversationState(rawValue: channelState.status)
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
    let peerSignalIsTransmitting: Bool
    let activeChannelID: UUID?
    let systemSessionMatchesContact: Bool
    let systemSessionState: SystemPTTSessionState
    let pendingAction: PendingSessionAction
    let localJoinFailure: PTTJoinFailure?
    let mediaState: MediaConnectionState
    let channel: ChannelReadinessSnapshot?

    init(
        contactID: UUID,
        selectedContactID: UUID?,
        baseState: ConversationState,
        contactName: String,
        contactIsOnline: Bool,
        isJoined: Bool,
        localIsTransmitting: Bool = false,
        peerSignalIsTransmitting: Bool = false,
        activeChannelID: UUID?,
        systemSessionMatchesContact: Bool,
        systemSessionState: SystemPTTSessionState,
        pendingAction: PendingSessionAction,
        localJoinFailure: PTTJoinFailure?,
        mediaState: MediaConnectionState = .idle,
        channel: ChannelReadinessSnapshot?
    ) {
        self.contactID = contactID
        self.selectedContactID = selectedContactID
        self.baseState = baseState
        self.contactName = contactName
        self.contactIsOnline = contactIsOnline
        self.isJoined = isJoined
        self.localIsTransmitting = localIsTransmitting
        self.peerSignalIsTransmitting = peerSignalIsTransmitting
        self.activeChannelID = activeChannelID
        self.systemSessionMatchesContact = systemSessionMatchesContact
        self.systemSessionState = systemSessionState
        self.pendingAction = pendingAction
        self.localJoinFailure = localJoinFailure
        self.mediaState = mediaState
        self.channel = channel
    }
}

enum ConversationStateMachine {
    static func relationshipState(
        hasIncomingRequest: Bool,
        hasOutgoingRequest: Bool,
        requestCount: Int
    ) -> PairRelationshipState {
        let normalizedCount = max(requestCount, 1)
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
            guard let channel = context.channel else {
                return .waitingForPeer
            }
            let sessionReady =
                context.systemSessionMatchesContact
                && context.isJoined
                && context.activeChannelID == context.contactID
                && channel.selfJoined
                && channel.peerJoined
                && channel.peerDeviceConnected
            guard sessionReady else {
                return .waitingForPeer
            }
            if !channel.canTransmit && context.baseState != .receiving {
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

        switch context.systemSessionState {
        case .active(let activeContactID, _) where activeContactID != context.contactID:
            return SelectedPeerState(
                relationship: relationship,
                phase: .blockedByOtherSession,
                statusMessage: "Another session is active",
                canTransmitNow: false
            )
        case .mismatched:
            return SelectedPeerState(
                relationship: relationship,
                phase: .systemMismatch,
                statusMessage: "System session mismatch",
                canTransmitNow: false
            )
        case .none, .active:
            break
        }

        if let localJoinFailure = context.localJoinFailure,
           localJoinFailure.contactID == context.contactID,
           localJoinFailure.reason.blocksAutomaticRestore {
            return SelectedPeerState(
                relationship: relationship,
                phase: .localJoinFailed,
                statusMessage: localJoinFailure.reason.recoveryMessage,
                canTransmitNow: false
            )
        }

        if context.pendingAction.pendingJoinContactID == context.contactID {
            return SelectedPeerState(
                relationship: relationship,
                phase: .waitingForPeer,
                statusMessage: "Connecting...",
                canTransmitNow: false
            )
        }

        let localSessionActive =
            context.systemSessionMatchesContact
            || context.activeChannelID == context.contactID
            || (context.isJoined && context.selectedContactID == context.contactID)

        if leaveInFlight && localSessionActive {
            return SelectedPeerState(
                relationship: relationship,
                phase: .waitingForPeer,
                statusMessage: "Disconnecting...",
                canTransmitNow: false
            )
        }

        if let channel = context.channel,
           let liveSessionState = liveSelectedSessionState(for: context, channel: channel) {
            return SelectedPeerState(
                relationship: relationship,
                phase: liveSessionState.phase,
                statusMessage: liveSessionState.statusMessage,
                canTransmitNow: canTransmitNow
            )
        }

        if let channel = context.channel {
            let peerReadyToConnect =
                !localSessionActive
                && !channel.selfJoined
                && channel.peerJoined
            if peerReadyToConnect {
                return SelectedPeerState(
                    relationship: relationship,
                    phase: .peerReady,
                    statusMessage: "\(context.contactName) is ready to connect",
                    canTransmitNow: false
                )
            }

            let sessionTransitionInFlight =
                localSessionActive
                || channel.selfJoined
            if sessionTransitionInFlight {
                return SelectedPeerState(
                    relationship: relationship,
                    phase: .waitingForPeer,
                    statusMessage: "Connecting...",
                    canTransmitNow: false
                )
            }
        } else if localSessionActive {
            return SelectedPeerState(
                relationship: relationship,
                phase: .waitingForPeer,
                statusMessage: "Connecting...",
                canTransmitNow: false
            )
        }

        switch relationship {
        case .incomingRequest:
            return SelectedPeerState(
                relationship: relationship,
                phase: .incomingRequest,
                statusMessage: "\(context.contactName) wants to talk",
                canTransmitNow: false
            )
        case .outgoingRequest:
            return SelectedPeerState(
                relationship: relationship,
                phase: .requested,
                statusMessage: "Requested \(context.contactName)",
                canTransmitNow: false
            )
        case .none:
            return SelectedPeerState(
                relationship: relationship,
                phase: .idle,
                statusMessage: context.contactIsOnline ? "\(context.contactName) is online" : "Ready to connect",
                canTransmitNow: false
            )
        }
    }

    static func listConversationState(for summary: TurboContactSummaryResponse) -> ConversationState {
        let relationship = relationshipState(
            hasIncomingRequest: summary.hasIncomingRequest,
            hasOutgoingRequest: summary.hasOutgoingRequest,
            requestCount: summary.requestCount
        )

        switch relationship {
        case .incomingRequest, .outgoingRequest:
            return relationship.fallbackConversationState
        case .none:
            break
        }

        switch summary.badgeStatus {
        case "connecting", ConversationState.waitingForPeer.rawValue:
            return .waitingForPeer
        case "ready", ConversationState.ready.rawValue:
            return .ready
        case "talking", ConversationState.transmitting.rawValue:
            return .transmitting
        case "receiving", ConversationState.receiving.rawValue:
            return .receiving
        default:
            return .idle
        }
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
            if context.channel?.selfJoined == true {
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
        case .idle, .requested, .incomingRequest, .waitingForPeer, .localJoinFailed, .ready, .startingTransmit, .transmitting, .receiving:
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
        if case .explicitLeave(let contactID) = context.pendingAction {
            explicitLeaveRequested = contactID == nil || contactID == context.contactID
        } else {
            explicitLeaveRequested = false
        }

        switch context.systemSessionState {
        case .mismatched:
            return .teardownSelectedSession(contactID: context.contactID)
        case .none, .active:
            break
        }

        let localSessionActive =
            context.systemSessionMatchesContact
            || context.isJoined
            || context.activeChannelID == context.contactID

        if explicitLeaveRequested,
           context.systemSessionState == .none,
           localSessionActive {
            return .teardownSelectedSession(contactID: context.contactID)
        }

        guard let channel = context.channel else {
            return localSessionActive ? .teardownSelectedSession(contactID: context.contactID) : .none
        }

        let localSessionAligned =
            context.systemSessionMatchesContact
            && context.isJoined
            && context.activeChannelID == context.contactID

        let localRestoreInFlight =
            context.systemSessionMatchesContact
            || context.pendingAction.pendingJoinContactID == context.contactID

        let backendSessionReady =
            channel.selfJoined
            && channel.peerJoined
            && channel.peerDeviceConnected

        if backendSessionReady && !localSessionAligned && !localRestoreInFlight && !explicitLeaveRequested {
            return .restoreLocalSession(contactID: context.contactID)
        }

        let peerDepartedFromAlignedSession =
            localSessionAligned
            && channel.selfJoined
            && !channel.peerJoined
            && !channel.hasIncomingRequest
            && !channel.hasOutgoingRequest
            && channel.status == .waitingForPeer

        if peerDepartedFromAlignedSession {
            return .teardownSelectedSession(contactID: context.contactID)
        }

        if !channel.selfJoined && localSessionActive {
            return .teardownSelectedSession(contactID: context.contactID)
        }

        return .none
    }
}

private extension ConversationStateMachine {
    static func liveSelectedSessionState(
        for context: ConversationDerivationContext,
        channel: ChannelReadinessSnapshot
    ) -> (phase: SelectedPeerPhase, statusMessage: String)? {
        let sessionConnected =
            context.systemSessionMatchesContact
            && context.isJoined
            && context.activeChannelID == context.contactID
            && channel.selfJoined
            && channel.peerJoined
        let sessionTransmitReady = sessionConnected && channel.peerDeviceConnected

        guard sessionConnected, let channelStatus = channel.status else {
            return nil
        }

        if sessionTransmitReady && context.localIsTransmitting {
            switch context.mediaState {
            case .connected:
                return (.transmitting, "Talking to \(context.contactName)")
            case .preparing, .idle, .closed:
                return (.startingTransmit, "Establishing audio...")
            case .failed:
                return (.startingTransmit, "Audio unavailable")
            }
        }

        if sessionTransmitReady && context.peerSignalIsTransmitting {
            return (.receiving, "\(context.contactName) is talking")
        }

        if sessionConnected && !channel.peerDeviceConnected {
            return (.wakeReady, "Hold to talk to wake \(context.contactName)")
        }

        switch channelStatus {
        case .receiving where sessionTransmitReady:
            return (.receiving, "\(context.contactName) is talking")
        case .transmitting where sessionTransmitReady:
            switch context.mediaState {
            case .connected:
                return (.transmitting, "Talking to \(context.contactName)")
            case .preparing, .idle, .closed:
                return (.startingTransmit, "Establishing audio...")
            case .failed:
                return (.startingTransmit, "Audio unavailable")
            }
        case .ready where channel.canTransmit:
            return (.ready, "Connected")
        case .waitingForPeer, .ready:
            return (.waitingForPeer, "Establishing connection...")
        case .idle, .requested, .incomingRequest, .receiving, .transmitting:
            return nil
        }
    }
}

private extension ConversationDerivationContext {
    var canTransmitNow: Bool {
        guard let channel else { return false }
        return selectedContactID == contactID
            && systemSessionMatchesContact
            && isJoined
            && activeChannelID == contactID
            && channel.canTransmit
    }
}

enum ContactDirectory {
    static let suggestedDevHandles: [String] = [
        "@turbo-ios",
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
