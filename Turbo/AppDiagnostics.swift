import Foundation
import Observation
import OSLog

struct SelectedSessionDiagnosticsSummary: Codable, Equatable {
    let selectedHandle: String?
    let selectedPhase: String
    let selectedPhaseDetail: String
    let relationship: String
    let statusMessage: String
    let canTransmitNow: Bool
    let isJoined: Bool
    let isTransmitting: Bool
    let activeChannelID: String?
    let pendingAction: String
    let reconciliationAction: String
    let hadConnectedSessionContinuity: Bool
    let systemSession: String
    let mediaState: String
    let backendChannelStatus: String?
    let backendReadiness: String?
    let backendMembership: String?
    let backendRequestRelationship: String?
    let backendSelfJoined: Bool?
    let backendPeerJoined: Bool?
    let backendPeerDeviceConnected: Bool?
    let backendActiveTransmitterUserId: String?
    let backendActiveTransmitId: String?
    let backendActiveTransmitExpiresAt: String?
    let backendServerTimestamp: String?
    let remoteAudioReadiness: String?
    let remoteWakeCapability: String?
    let remoteWakeCapabilityKind: String?
    let backendCanTransmit: Bool?
    let firstTalkStartupProfile: String?
    let pttTokenRegistrationKind: String
    let incomingWakeActivationState: String?
    let incomingWakeBufferedChunkCount: Int?
}

struct ContactDiagnosticsSummary: Codable, Equatable, Identifiable {
    let handle: String
    let isOnline: Bool
    let listState: String
    let badgeStatus: String?
    let listSection: String
    let presencePill: String
    let requestRelationship: String
    let hasIncomingRequest: Bool
    let hasOutgoingRequest: Bool
    let requestCount: Int
    let incomingInviteCount: Int?
    let outgoingInviteCount: Int?

    var id: String { handle }
}

struct UIProjectionDiagnostics: Codable, Equatable {
    let route: String
    let callScreenVisible: Bool
    let callScreenContactHandle: String?
    let callScreenRequestedExpanded: Bool
    let callScreenMinimized: Bool
    let primaryActionKind: String?
    let primaryActionLabel: String?
    let primaryActionEnabled: Bool?
    let selectedPeerPhase: String
    let selectedPeerStatus: String

    static let unknown = UIProjectionDiagnostics(
        route: "unknown",
        callScreenVisible: false,
        callScreenContactHandle: nil,
        callScreenRequestedExpanded: false,
        callScreenMinimized: false,
        primaryActionKind: nil,
        primaryActionLabel: nil,
        primaryActionEnabled: nil,
        selectedPeerPhase: "none",
        selectedPeerStatus: "none"
    )

    var fields: [String: String] {
        [
            "uiRoute": route,
            "uiCallScreenVisible": String(callScreenVisible),
            "uiCallScreenContact": callScreenContactHandle ?? "none",
            "uiCallScreenRequestedExpanded": String(callScreenRequestedExpanded),
            "uiCallScreenMinimized": String(callScreenMinimized),
            "uiPrimaryActionKind": primaryActionKind ?? "none",
            "uiPrimaryActionLabel": primaryActionLabel ?? "none",
            "uiPrimaryActionEnabled": primaryActionEnabled.map(String.init(describing:)) ?? "none",
            "uiSelectedPeerPhase": selectedPeerPhase,
            "uiSelectedPeerStatus": selectedPeerStatus,
        ]
    }

    var derivedInvariantCandidates: [DiagnosticsInvariantViolationCandidate] {
        guard callScreenVisible else { return [] }

        var violations: [DiagnosticsInvariantViolationCandidate] = []
        let metadata = fields

        if selectedPeerPhase == "idle" {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "ui.call_screen_visible_for_idle_peer",
                    scope: .local,
                    message: "call screen is visible while selectedPeerPhase=idle",
                    metadata: metadata
                )
            )
        }

        if selectedPeerPhase == "incomingRequest" {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "ui.call_screen_visible_for_incoming_request",
                    scope: .local,
                    message: "call screen is visible for an incoming request before local accept/join evidence exists",
                    metadata: metadata
                )
            )
        }

        if primaryActionKind == "holdToTalk",
           selectedPeerPhase == "idle" || selectedPeerPhase == "requested" || selectedPeerPhase == "incomingRequest" {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "ui.call_screen_talk_action_for_non_live_peer",
                    scope: .local,
                    message: "call screen shows talk action for a non-live selected peer phase",
                    metadata: metadata
                )
            )
        }

        return violations
    }
}

struct LocalSessionDiagnosticsProjection: Codable, Equatable {
    let selectedContactID: String?
    let selectedHandle: String?
    let selectedPeerPhase: String
    let selectedPeerPhaseDetail: String
    let selectedPeerRelationship: String
    let selectedPeerCanTransmit: Bool
    let selectedPeerAutoJoinArmed: Bool
    let isJoined: Bool
    let isTransmitting: Bool
    let activeChannelID: String?
    let systemSession: String
    let systemActiveContactID: String?
    let systemChannelUUID: String?
    let mediaState: String
    let transmitPhase: String
    let transmitActiveContactID: String?
    let transmitPressActive: Bool
    let transmitExplicitStopRequested: Bool
    let transmitSystemTransmitting: Bool
    let incomingWakeActivationState: String?
    let incomingWakeBufferedChunkCount: Int?
    let remoteReceiveActive: Bool
    let remoteReceiveActivityState: String?
    let receiverAudioReadinessState: String?
    let pendingAction: String
    let localJoinAttempt: String?
    let localJoinAttemptIssuedCount: Int
    let reconciliationAction: String
    let hadConnectedSessionContinuity: Bool
    let controlPlaneReconnectGraceActive: Bool
    let backendSignalingJoinRecoveryActive: Bool
    let backendJoinSettling: Bool
    let backendChannelStatus: String?
    let backendReadiness: String?
    let backendSelfJoined: Bool?
    let backendPeerJoined: Bool?
    let backendPeerDeviceConnected: Bool?
    let backendActiveTransmitterUserId: String?
    let backendActiveTransmitId: String?
    let backendActiveTransmitExpiresAt: String?
    let backendServerTimestamp: String?
    let backendCanTransmit: Bool?
    let remoteAudioReadiness: String?
    let remoteWakeCapabilityKind: String?

    var derivedInvariantIDs: [String] {
        derivedInvariantCandidates.map(\.invariantID)
    }

    var derivedInvariantCandidates: [DiagnosticsInvariantViolationCandidate] {
        let phase = selectedPeerPhase
        let phaseDetail = selectedPeerPhaseDetail
        let backendChannelStatusValue = backendChannelStatus ?? "none"
        let backendReadinessValue = backendReadiness ?? "none"
        let remoteWakeCapabilityKindValue = remoteWakeCapabilityKind ?? "unavailable"
        let remoteAudioReadinessValue = remoteAudioReadiness ?? "unknown"
        let systemSessionValue = systemSession
        let localJoinAttemptValue = localJoinAttempt ?? "none"
        let backendActiveTransmitIdValue = backendActiveTransmitId ?? "none"
        let backendActiveTransmitterUserIdValue = backendActiveTransmitterUserId ?? "none"

        var violations: [DiagnosticsInvariantViolationCandidate] = []

        if phase == "ready", isJoined == false {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.ready_without_join",
                    scope: .local,
                    message: "selectedPeerPhase=ready while isJoined=false",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "isJoined": String(isJoined),
                    ]
                )
            )
        }

        if phase == "receiving",
           (isJoined == false || systemSessionValue == "none") {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.receiving_without_joined_session",
                    scope: .local,
                    message: "selectedPeerPhase=receiving without joined local session evidence",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                        "remoteWakeCapabilityKind": remoteWakeCapabilityKindValue,
                    ]
                )
            )
        }

        if phase == "transmitting", isJoined == false {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.live_projection_after_membership_exit",
                    scope: .local,
                    message: "selectedPeerPhase=transmitting after local membership exit",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                    ]
                )
            )
        }

        if ["transmitting", "receiving"].contains(phase),
           let expiry = expiredBackendTransmitLease(graceSeconds: 5.0) {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "transmit.live_projection_after_lease_expiry",
                    scope: .convergence,
                    message: "selectedPeerPhase remained live after backend transmit lease expiry",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendActiveTransmitterUserId": backendActiveTransmitterUserIdValue,
                        "backendActiveTransmitId": backendActiveTransmitIdValue,
                        "backendActiveTransmitExpiresAt": expiry.expiresAt,
                        "backendServerTimestamp": backendServerTimestamp ?? "none",
                        "expiredByMs": String(expiry.expiredByMs),
                        "graceMs": "5000",
                        "transmitPhase": transmitPhase,
                        "remoteReceiveActive": String(remoteReceiveActive),
                    ]
                )
            )
        }

        let backendHasActiveTransmit =
            backendActiveTransmitIdValue != "none"
            || backendChannelStatusValue == "self-transmitting"
            || backendChannelStatusValue == "peer-transmitting"
            || backendReadinessValue == "self-transmitting"
            || backendReadinessValue == "peer-transmitting"
        if backendHasActiveTransmit,
           backendPeerJoined == false,
           remoteWakeCapabilityKindValue != "wake-capable" {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "channel.active_transmit_without_addressable_peer",
                    scope: .backend,
                    message: "backend active transmit has no joined or wake-addressable selected peer",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                        "remoteWakeCapabilityKind": remoteWakeCapabilityKindValue,
                        "backendActiveTransmitterUserId": backendActiveTransmitterUserIdValue,
                        "backendActiveTransmitId": backendActiveTransmitIdValue,
                    ]
                )
            )
        }

        let backendIsSelfTransmitting =
            backendChannelStatusValue == "self-transmitting"
            || backendReadinessValue == "self-transmitting"
        if phase == "ready",
           backendCanTransmit == false,
           !backendIsSelfTransmitting {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.ready_while_backend_cannot_transmit",
                    scope: .backend,
                    message: "selectedPeerPhase=ready while backendCanTransmit=false",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "backendCanTransmit": boolMetadata(backendCanTransmit),
                    ]
                )
            )
        }

        if backendSelfJoined == true, backendPeerJoined == true, backendPeerDeviceConnected == true {
            let notLivePhases = Set(["idle", "requested", "incomingRequest"])
            if notLivePhases.contains(phase) {
                violations.append(
                    DiagnosticsInvariantViolationCandidate(
                        invariantID: "selected.backend_ready_ui_not_live",
                        scope: .backend,
                        message: "backend says both sides are ready, but selectedPeerPhase is still not live",
                        metadata: [
                            "selectedPeerPhase": phase,
                            "backendSelfJoined": boolMetadata(backendSelfJoined),
                            "backendPeerJoined": boolMetadata(backendPeerJoined),
                            "backendPeerDeviceConnected": boolMetadata(backendPeerDeviceConnected),
                        ]
                    )
                )
            }
        }

        let localLiveSessionEvidence = isJoined || systemSessionValue != "none"
        if selectedPeerRelationship == "none",
           pendingAction == "none",
           localLiveSessionEvidence,
           backendSelfJoined == false,
           backendPeerJoined == false,
           [
               "waiting-for-peer",
               "ready",
               "self-transmitting",
               "peer-transmitting",
           ].contains(backendChannelStatusValue),
           [
               "waiting-for-self",
               "waiting-for-peer",
               "ready",
               "self-transmitting",
               "peer-transmitting",
           ].contains(backendReadinessValue) {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.backend_absent_with_live_session_evidence",
                    scope: .backend,
                    message: "backend dropped durable membership while local/system session still had live evidence",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerRelationship": selectedPeerRelationship,
                        "pendingAction": pendingAction,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                        "backendPeerDeviceConnected": boolMetadata(backendPeerDeviceConnected),
                    ]
                )
            )
        }

        if phase == "peerReady",
           selectedPeerRelationship == "none",
           pendingAction == "none",
           isJoined == false,
           systemSessionValue == "none",
           backendSelfJoined == true,
           backendPeerJoined == true,
           [
               "inactive",
               "waiting-for-self",
               "waiting-for-peer",
               "ready",
           ].contains(backendReadinessValue) {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.stale_membership_peer_ready_without_session",
                    scope: .backend,
                    message: "backend retained durable channel membership while selectedPeerPhase is peerReady without a local session",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerRelationship": selectedPeerRelationship,
                        "pendingAction": pendingAction,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                        "backendPeerDeviceConnected": boolMetadata(backendPeerDeviceConnected),
                    ]
                )
            )
        }

        if selectedPeerRelationship == "none",
           pendingAction == "none",
           isJoined == false,
           systemSessionValue == "none",
           backendReadinessValue == "inactive",
           backendSelfJoined == true,
           backendPeerJoined == true,
           backendPeerDeviceConnected == false {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.stale_backend_membership_without_local_session",
                    scope: .backend,
                    message: "backend retained inactive durable channel membership without local session evidence",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerRelationship": selectedPeerRelationship,
                        "pendingAction": pendingAction,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                        "backendPeerDeviceConnected": boolMetadata(backendPeerDeviceConnected),
                    ]
                )
            )
        }

        let pendingLocalJoinWithoutSession =
            pendingAction.contains("joiningLocal(")
            || pendingAction.contains(".joiningLocal(")
        let backendMembershipAbsentForPendingLocalAction =
            backendSelfJoined != true
            && backendPeerJoined != true
            && ![
                "waiting-for-peer",
                "ready",
                "self-transmitting",
                "peer-transmitting",
            ].contains(backendChannelStatusValue)
        if pendingLocalJoinWithoutSession,
           selectedPeerRelationship == "none",
           isJoined == false,
           systemSessionValue == "none",
           !backendJoinSettling,
           backendMembershipAbsentForPendingLocalAction {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.backend_absent_pending_local_action_without_session",
                    scope: .convergence,
                    message: "backend membership is absent, but the selected peer still has a pending local session action without local session evidence",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerRelationship": selectedPeerRelationship,
                        "pendingAction": pendingAction,
                        "localJoinAttempt": localJoinAttemptValue,
                        "localJoinAttemptIssuedCount": String(localJoinAttemptIssuedCount),
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendJoinSettling": String(backendJoinSettling),
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                    ]
                )
            )
        }

        let backendIdleWithoutMembership =
            backendSelfJoined != true
            && backendPeerJoined != true
            && ["idle", "none"].contains(backendChannelStatusValue)
            && ["inactive", "none"].contains(backendReadinessValue)
        if phase == "waitingForPeer",
           phaseDetail.contains("pendingJoin"),
           selectedPeerRelationship == "none",
           selectedPeerAutoJoinArmed == false,
           pendingAction == "none",
           isJoined == false,
           systemSessionValue == "none",
           backendIdleWithoutMembership {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.backend_idle_without_local_evidence_still_connecting",
                    scope: .convergence,
                    message: "backend is idle without local session evidence, but selected peer is still connecting",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerPhaseDetail": phaseDetail,
                        "selectedPeerRelationship": selectedPeerRelationship,
                        "selectedPeerAutoJoinArmed": String(selectedPeerAutoJoinArmed),
                        "pendingAction": pendingAction,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                    ]
                )
            )
        }

        if backendPeerJoined == true, backendSelfJoined == false {
            let disconnectedPhases = Set(["idle", "requested"])
            if disconnectedPhases.contains(phase) {
                violations.append(
                    DiagnosticsInvariantViolationCandidate(
                        invariantID: "selected.peer_joined_ui_not_connectable",
                        scope: .backend,
                        message: "backend says the peer already joined, but selectedPeerPhase is still not connectable",
                        metadata: [
                            "selectedPeerPhase": phase,
                            "backendSelfJoined": boolMetadata(backendSelfJoined),
                            "backendPeerJoined": boolMetadata(backendPeerJoined),
                        ]
                    )
                )
            }
        }

        if backendReadinessValue == "waiting-for-self" {
            let disconnectedPhases = Set(["idle", "requested", "incomingRequest"])
            if disconnectedPhases.contains(phase) {
                violations.append(
                    DiagnosticsInvariantViolationCandidate(
                        invariantID: "selected.waiting_for_self_ui_not_connectable",
                        scope: .backend,
                        message: "backend says the peer is waiting for self, but selectedPeerPhase is still not connectable",
                        metadata: [
                            "selectedPeerPhase": phase,
                            "backendChannelStatus": backendChannelStatusValue,
                            "backendReadiness": backendReadinessValue,
                            "backendSelfJoined": boolMetadata(backendSelfJoined),
                            "backendPeerJoined": boolMetadata(backendPeerJoined),
                        ]
                    )
                )
            }
        }

        let connectableWakeStatuses = Set(["waiting-for-peer", "ready", "transmitting", "receiving"])
        if remoteWakeCapabilityKindValue == "wake-capable",
           connectableWakeStatuses.contains(backendChannelStatusValue) {
            let disconnectedPhases = Set(["idle", "requested"])
            if disconnectedPhases.contains(phase) {
                violations.append(
                    DiagnosticsInvariantViolationCandidate(
                        invariantID: "selected.peer_wake_capable_ui_not_connectable",
                        scope: .backend,
                        message: "backend channel is connectable and peer wake is available, but selectedPeerPhase is still not connectable",
                        metadata: [
                            "selectedPeerPhase": phase,
                            "backendChannelStatus": backendChannelStatusValue,
                            "backendReadiness": backendReadinessValue,
                            "remoteWakeCapabilityKind": remoteWakeCapabilityKindValue,
                        ]
                    )
                )
            }
        }

        if phase == "waitingForPeer",
           isJoined == true,
           hadConnectedSessionContinuity == true,
           systemSessionValue.hasPrefix("active("),
           backendSelfJoined == true,
           backendPeerJoined == true,
           backendPeerDeviceConnected == true,
           backendChannelStatusValue == "waiting-for-peer",
           remoteWakeCapabilityKindValue == "unavailable" {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.joined_session_lost_wake_capability",
                    scope: .backend,
                    message: "joined live session regressed to waiting-for-peer without wake capability",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "remoteWakeCapabilityKind": remoteWakeCapabilityKindValue,
                    ]
                )
            )
        }

        if phase == "waitingForPeer",
           phaseDetail.contains("localAudioPrewarm"),
           isJoined == true,
           hadConnectedSessionContinuity == true,
           systemSessionValue.hasPrefix("active("),
           backendReadinessValue == "ready",
           backendSelfJoined == true,
           backendPeerJoined == true,
           remoteAudioReadinessValue == "wakeCapable",
           remoteWakeCapabilityKindValue == "wake-capable" {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.wake_capable_peer_blocked_on_local_audio_prewarm",
                    scope: .backend,
                    message: "peer is wake-capable, but selectedPeerPhase is still waitingForPeer on local audio prewarm",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerPhaseDetail": phaseDetail,
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                        "remoteWakeCapabilityKind": remoteWakeCapabilityKindValue,
                    ]
                )
            )
        }

        if phase == "waitingForPeer",
           phaseDetail.contains("localSessionTransition"),
           isJoined == true,
           hadConnectedSessionContinuity == true,
           systemSessionValue.hasPrefix("active("),
           backendReadinessValue == "inactive",
           backendSelfJoined == false,
           backendPeerJoined == false {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.backend_inactive_ui_still_joined",
                    scope: .backend,
                    message: "backend says the session is inactive, but selectedPeerPhase is still waitingForPeer on a joined local session",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerPhaseDetail": phaseDetail,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                    ]
                )
            )
        }

        let disconnectingTeardownInFlight =
            phaseDetail.contains("disconnecting")
            || pendingAction.contains("reconciledTeardown(")

        if phase == "waitingForPeer",
           isJoined == true,
           hadConnectedSessionContinuity == true,
           systemSessionValue.hasPrefix("active("),
           !reconciliationAction.hasPrefix("teardownSelectedSession("),
           !disconnectingTeardownInFlight,
           backendSelfJoined == false,
           backendPeerJoined == false {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.backend_membership_absent_ui_still_joined",
                    scope: .backend,
                    message: "backend says channel membership is absent, but selectedPeerPhase is still waitingForPeer on a joined local session",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerPhaseDetail": phaseDetail,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                    ]
                )
            )
        }

        let localSessionEvidenceStillLive =
            systemSessionValue.hasPrefix("active(")
            || mediaState == "connected"

        if phase == "waitingForPeer",
           isJoined == true,
           hadConnectedSessionContinuity == true,
           localSessionEvidenceStillLive,
           !reconciliationAction.hasPrefix("teardownSelectedSession("),
           !disconnectingTeardownInFlight,
           backendChannelStatusValue == "idle",
           backendSelfJoined == false,
           backendPeerJoined == false {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.backend_idle_with_live_session_evidence",
                    scope: .backend,
                    message: "backend regressed to idle while local session evidence remained live",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerPhaseDetail": phaseDetail,
                        "isJoined": String(isJoined),
                        "systemSession": systemSessionValue,
                        "mediaState": mediaState,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                        "hadConnectedSessionContinuity": boolMetadata(hadConnectedSessionContinuity),
                    ]
                )
            )
        }

        if phase == "waitingForPeer",
           phaseDetail.contains("remoteAudioPrewarm"),
           isJoined == true,
           mediaState == "connected",
           systemSessionValue.hasPrefix("active("),
           !backendSignalingJoinRecoveryActive,
           backendReadinessValue == "ready",
           backendSelfJoined == true,
           backendPeerJoined == true,
           backendPeerDeviceConnected == true,
           remoteAudioReadinessValue != "waiting",
           remoteWakeCapabilityKindValue == "wake-capable" {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.backend_ready_missing_remote_audio_signal",
                    scope: .backend,
                    message: "backend says the peer is ready and connected, but selectedPeerPhase is still waitingForPeer on remote audio prewarm",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "selectedPeerPhaseDetail": phaseDetail,
                        "mediaState": mediaState,
                        "systemSession": systemSessionValue,
                        "backendChannelStatus": backendChannelStatusValue,
                        "backendReadiness": backendReadinessValue,
                        "backendSelfJoined": boolMetadata(backendSelfJoined),
                        "backendPeerJoined": boolMetadata(backendPeerJoined),
                        "backendPeerDeviceConnected": boolMetadata(backendPeerDeviceConnected),
                        "remoteAudioReadiness": remoteAudioReadinessValue,
                        "remoteWakeCapabilityKind": remoteWakeCapabilityKindValue,
                    ]
                )
            )
        }

        return violations
    }

    private func expiredBackendTransmitLease(
        graceSeconds: TimeInterval
    ) -> (expiresAt: String, expiredByMs: Int)? {
        guard let backendActiveTransmitExpiresAt,
              let expiration = Self.parseBackendInstant(backendActiveTransmitExpiresAt) else {
            return nil
        }
        let expiredBy = Date().timeIntervalSince(expiration)
        guard expiredBy > graceSeconds else { return nil }
        return (
            expiresAt: backendActiveTransmitExpiresAt,
            expiredByMs: Int(expiredBy * 1_000)
        )
    }

    private static func parseBackendInstant(_ text: String) -> Date? {
        guard text.hasSuffix("Z") else { return nil }
        let withoutZone = String(text.dropLast())
        let parts = withoutZone.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let baseText = String(parts[0]) + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let baseDate = formatter.date(from: baseText) else { return nil }
        guard parts.count == 2 else { return baseDate }

        let fractionalDigits = parts[1].prefix { $0 >= "0" && $0 <= "9" }
        guard !fractionalDigits.isEmpty else { return baseDate }
        let scale = pow(10.0, Double(fractionalDigits.count))
        let fractionalSeconds = (Double(fractionalDigits) ?? 0) / scale
        return baseDate.addingTimeInterval(fractionalSeconds)
    }

    private func boolMetadata(_ value: Bool?) -> String {
        value.map(String.init(describing:)) ?? "none"
    }
}

struct StateMachineProjection: Codable, Equatable {
    let selectedSession: SelectedSessionDiagnosticsSummary
    let localSession: LocalSessionDiagnosticsProjection
    let contacts: [ContactDiagnosticsSummary]
    let isWebSocketConnected: Bool
    let statusMessage: String
    let backendStatusMessage: String

    func contact(handle: String) -> ContactDiagnosticsSummary? {
        contacts.first { $0.handle == handle }
    }
}

struct DirectQuicDiagnosticsSummary: Codable, Equatable {
    let selectedHandle: String?
    let role: String?
    let identityLabel: String?
    let identityStatus: String
    let identitySource: String
    let fingerprint: String?
    let provisioningStatus: String
    let installedIdentityCount: Int
    let relayOnlyOverride: Bool
    let autoUpgradeDisabled: Bool
    let transmitStartupPolicy: DirectQuicTransmitStartupPolicy
    let mediaRelayEnabled: Bool
    let mediaRelayForced: Bool
    let mediaRelayConfigured: Bool
    let mediaRelayHost: String?
    let mediaRelayQuicPort: Int?
    let mediaRelayTcpPort: Int?
    let mediaRelayActive: Bool
    let backendAdvertisesUpgrade: Bool
    let effectiveUpgradeEnabled: Bool
    let transportPathState: MediaTransportPathState
    let localDeviceID: String?
    let peerDeviceID: String?
    let attemptID: String?
    let channelID: String?
    let isDirectActive: Bool
    let remoteCandidateCount: Int
    let remoteEndOfCandidates: Bool
    let attemptStartedAt: Date?
    let lastUpdatedAt: Date?
    let nominatedPathSource: String?
    let nominatedRemoteAddress: String?
    let nominatedRemotePort: Int?
    let nominatedRemoteCandidateKind: String?
    let retryReason: String?
    let retryCategory: String?
    let retryAttemptID: String?
    let retryRemainingMilliseconds: Int?
    let retryBackoffMilliseconds: Int?
    let stunServerCount: Int
    let stunProviderNames: [String]
    let turnEnabled: Bool
    let turnProvider: String?
    let turnPolicyPath: String?
    let turnCredentialTtlSeconds: Int?
    let transportExperimentBucket: String?
    let promotionTimeoutMilliseconds: Int
    let retryBackoffBaseMilliseconds: Int
    let probeControllerReady: Bool
}

struct DiagnosticsEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let appVersion: String
    let deviceId: String
    let handle: String
    let scenarioName: String?
    let scenarioRunId: String?
    let timestamp: Date
    let projection: StateMachineProjection
    let directQuic: DirectQuicDiagnosticsSummary?
    let invariantViolations: [DiagnosticsInvariantViolation]
    let stateCaptures: [DiagnosticsStateCapture]
    let reducerTransitionReports: [ReducerTransitionReport]
}

struct ReducerTransitionReport: Codable, Equatable {
    let reducerName: String
    let eventName: String
    let previousStateSummary: String
    let nextStateSummary: String
    let effectsEmitted: [String]
    let invariantViolationsEmitted: [String]
    let repairIntentsEmitted: [String]
    let correlationIDs: [String: String]

    init(
        reducerName: String,
        eventName: String,
        previousStateSummary: String,
        nextStateSummary: String,
        effectsEmitted: [String] = [],
        invariantViolationsEmitted: [String] = [],
        repairIntentsEmitted: [String] = [],
        correlationIDs: [String: String] = [:]
    ) {
        self.reducerName = reducerName
        self.eventName = eventName
        self.previousStateSummary = previousStateSummary
        self.nextStateSummary = nextStateSummary
        self.effectsEmitted = effectsEmitted
        self.invariantViolationsEmitted = invariantViolationsEmitted
        self.repairIntentsEmitted = repairIntentsEmitted
        self.correlationIDs = correlationIDs
    }

    static func make<State, Event, Effect>(
        reducerName: String,
        event: Event,
        previousState: State,
        nextState: State,
        effects: [Effect],
        invariantViolationsEmitted: [String] = [],
        repairIntentsEmitted explicitRepairIntents: [String] = [],
        correlationIDs explicitCorrelationIDs: [String: String] = [:]
    ) -> ReducerTransitionReport {
        let eventSummary = clipped(String(describing: event))
        let previousSummary = clipped(String(describing: previousState))
        let nextSummary = clipped(String(describing: nextState))
        let effectSummaries = effects.map { clipped(String(describing: $0), limit: 240) }
        let inferredRepairIntents = effectSummaries.filter {
            $0.localizedCaseInsensitiveContains("repair")
        }
        let correlationIDs = extractedCorrelationIDs(
            from: [eventSummary, previousSummary, nextSummary] + effectSummaries
        ).merging(explicitCorrelationIDs) { _, explicit in explicit }

        return ReducerTransitionReport(
            reducerName: reducerName,
            eventName: eventName(from: eventSummary),
            previousStateSummary: previousSummary,
            nextStateSummary: nextSummary,
            effectsEmitted: effectSummaries,
            invariantViolationsEmitted: invariantViolationsEmitted,
            repairIntentsEmitted: explicitRepairIntents + inferredRepairIntents,
            correlationIDs: correlationIDs
        )
    }

    private static func eventName(from eventSummary: String) -> String {
        if let parenIndex = eventSummary.firstIndex(of: "(") {
            return String(eventSummary[..<parenIndex])
        }
        return eventSummary
    }

    private static func clipped(_ value: String, limit: Int = 800) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "..."
    }

    private static func extractedCorrelationIDs(from values: [String]) -> [String: String] {
        var ids: [String: String] = [:]
        for value in values {
            for key in [
                "contactID",
                "contactId",
                "channelUUID",
                "channelID",
                "channelId",
                "attemptID",
                "attemptId",
                "transmitID",
                "transmitId",
                "deviceID",
                "deviceId",
            ] {
                if ids[key] == nil,
                   let extractedValue = extractedCorrelationValue(for: key, in: value) {
                    ids[key] = extractedValue
                }
            }
        }
        return ids
    }

    private static func extractedCorrelationValue(for key: String, in value: String) -> String? {
        for marker in ["\(key): ", "\(key)="] {
            guard let markerRange = value.range(of: marker) else { continue }
            var tail = value[markerRange.upperBound...]
            if tail.hasPrefix("Optional(") {
                tail = tail.dropFirst("Optional(".count)
            }
            if tail.hasPrefix("\"") {
                tail = tail.dropFirst()
                guard let end = tail.firstIndex(of: "\"") else { return nil }
                return String(tail[..<end])
            }
            let end = tail.firstIndex { character in
                character == "," || character == ")" || character == " "
            } ?? tail.endIndex
            let extracted = String(tail[..<end])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return extracted.isEmpty || extracted == "nil" ? nil : extracted
        }
        return nil
    }
}

enum DiagnosticsInvariantScope: String, Codable, CaseIterable {
    case local
    case backend
    case pair
    case convergence
}

struct DiagnosticsInvariantViolation: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let invariantID: String
    let scope: DiagnosticsInvariantScope
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        invariantID: String,
        scope: DiagnosticsInvariantScope,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.invariantID = invariantID
        self.scope = scope
        self.message = message
        self.metadata = metadata
    }
}

enum DiagnosticsLevel: String, Codable, CaseIterable {
    case debug
    case info
    case notice
    case error
}

enum DiagnosticsSubsystem: String, Codable, CaseIterable {
    case app
    case auth
    case backend
    case websocket
    case channel
    case media
    case pushToTalk = "ptt"
    case state
    case invariant
    case selfCheck = "self-check"
}

struct DiagnosticsEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let subsystem: DiagnosticsSubsystem
    let level: DiagnosticsLevel
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        subsystem: DiagnosticsSubsystem,
        level: DiagnosticsLevel,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

struct DiagnosticsStateCapture: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let reason: String
    let changedKeys: [String]
    let fields: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        reason: String,
        changedKeys: [String],
        fields: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.reason = reason
        self.changedKeys = changedKeys
        self.fields = fields
    }

    var summaryLine: String {
        let parts = [
            "selected=\(fields["selectedContact"] ?? "none")",
            "phase=\(fields["selectedPeerPhase"] ?? "unknown")",
            "relationship=\(fields["selectedPeerRelationship"] ?? "unknown")",
            "pending=\(fields["pendingAction"] ?? "none")",
            "continuity=\(fields["hadConnectedSessionContinuity"] ?? "false")",
            "joined=\(fields["isJoined"] ?? "false")",
            "transmitting=\(fields["isTransmitting"] ?? "false")",
            "system=\(fields["systemSession"] ?? "none")",
            "backendChannel=\(fields["backendChannelStatus"] ?? "none")",
            "backendReadiness=\(fields["backendReadiness"] ?? "none")",
            "backendSelfJoined=\(fields["backendSelfJoined"] ?? "none")",
            "backendPeerJoined=\(fields["backendPeerJoined"] ?? "none")",
            "peerDevice=\(fields["backendPeerDeviceConnected"] ?? "none")",
            "peerAudio=\(fields["remoteAudioReadiness"] ?? "unknown")",
            "peerWake=\(fields["remoteWakeCapability"] ?? "unavailable")",
            "wakeActivation=\(fields["incomingWakeActivationState"] ?? "none")",
            "status=\(fields["selectedPeerStatus"] ?? fields["status"] ?? "none")"
        ]
        return parts.joined(separator: " ")
    }
}

@MainActor
@Observable
final class DiagnosticsStore {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Turbo", category: "diagnostics")
    private let entryLimit = 200
    private let stateCaptureLimit = 80
    private let invariantViolationLimit = 80
    private let reducerTransitionReportLimit = 160
    private let diskQueue = DispatchQueue(label: "Turbo.DiagnosticsStore.disk", qos: .utility)
    private let logFileURL: URL?
    private static let iso8601TimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private(set) var entries: [DiagnosticsEntry] = []
    private(set) var stateCaptures: [DiagnosticsStateCapture] = []
    private(set) var invariantViolations: [DiagnosticsInvariantViolation] = []
    private(set) var reducerTransitionReports: [ReducerTransitionReport] = []
    private(set) var latestErrorEntry: DiagnosticsEntry?
    var onHighSignalEvent: ((DiagnosticsHighSignalEvent) -> Void)?

    init() {
        let baseDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let baseDirectory {
            let directory = baseDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("beepbeep-diagnostics.log")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            logFileURL = fileURL
        } else {
            logFileURL = nil
        }
    }

    var latestError: DiagnosticsEntry? {
        latestErrorEntry
    }

    var logFilePath: String? {
        logFileURL?.path
    }

    nonisolated func record(
        _ subsystem: DiagnosticsSubsystem,
        level: DiagnosticsLevel = .info,
        message: String,
        metadata: [String: String] = [:]
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.recordOnMain(
                    subsystem: subsystem,
                    level: level,
                    message: message,
                    metadata: metadata
                )
            }
        } else {
            Task { @MainActor [weak self] in
                self?.recordOnMain(
                    subsystem: subsystem,
                    level: level,
                    message: message,
                    metadata: metadata
                )
            }
        }
    }

    nonisolated func clear() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.clearOnMain()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.clearOnMain()
            }
        }
    }

    nonisolated func captureState(
        reason: String,
        fields: [String: String],
        localSessionProjection: LocalSessionDiagnosticsProjection? = nil,
        uiProjection: UIProjectionDiagnostics? = nil
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.captureStateOnMain(
                    reason: reason,
                    fields: fields,
                    localSessionProjection: localSessionProjection,
                    uiProjection: uiProjection
                )
            }
        } else {
            Task { @MainActor [weak self] in
                self?.captureStateOnMain(
                    reason: reason,
                    fields: fields,
                    localSessionProjection: localSessionProjection,
                    uiProjection: uiProjection
                )
            }
        }
    }

    nonisolated func recordInvariantViolation(
        invariantID: String,
        scope: DiagnosticsInvariantScope,
        message: String,
        metadata: [String: String] = [:]
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.recordInvariantViolationOnMain(
                    invariantID: invariantID,
                    scope: scope,
                    message: message,
                    metadata: metadata
                )
            }
        } else {
            Task { @MainActor [weak self] in
                self?.recordInvariantViolationOnMain(
                    invariantID: invariantID,
                    scope: scope,
                    message: message,
                    metadata: metadata
                )
            }
        }
    }

    nonisolated func recordReducerTransition(_ report: ReducerTransitionReport) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.recordReducerTransitionOnMain(report)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.recordReducerTransitionOnMain(report)
            }
        }
    }

    private func recordOnMain(
        subsystem: DiagnosticsSubsystem,
        level: DiagnosticsLevel,
        message: String,
        metadata: [String: String]
    ) {
        let entry = DiagnosticsEntry(
            subsystem: subsystem,
            level: level,
            message: message,
            metadata: metadata
        )
        entries.insert(entry, at: 0)
        if entries.count > entryLimit {
            entries.removeLast(entries.count - entryLimit)
        }
        refreshLatestErrorEntry(afterRecording: entry)
        logger.log(level: entry.level.osLogType, "\(entry.subsystem.rawValue, privacy: .public): \(entry.message, privacy: .public) \(entry.metadata.formattedForLog, privacy: .public)")
        appendToDisk(entry)
        if entry.level == .error, entry.subsystem != .invariant {
            onHighSignalEvent?(.errorEntry(entry))
        }
    }

    private func clearOnMain() {
        entries.removeAll()
        stateCaptures.removeAll()
        invariantViolations.removeAll()
        reducerTransitionReports.removeAll()
        latestErrorEntry = nil
        guard let logFileURL else { return }
        diskQueue.async {
            try? Data().write(to: logFileURL, options: .atomic)
        }
    }

    private func recordReducerTransitionOnMain(_ report: ReducerTransitionReport) {
        reducerTransitionReports.insert(report, at: 0)
        if reducerTransitionReports.count > reducerTransitionReportLimit {
            reducerTransitionReports.removeLast(reducerTransitionReports.count - reducerTransitionReportLimit)
        }
        for invariantID in report.invariantViolationsEmitted {
            recordInvariantViolationOnMain(
                invariantID: invariantID,
                scope: .local,
                message: "reducer emitted invariant violation",
                metadata: report.correlationIDs.merging(
                    [
                        "reducerName": report.reducerName,
                        "eventName": report.eventName,
                    ],
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }
        logger.debug(
            "transition: \(report.reducerName, privacy: .public) event=\(report.eventName, privacy: .public) effects=\(report.effectsEmitted.count, privacy: .public)"
        )
        appendReducerTransitionToDisk(report)
    }

    private func captureStateOnMain(
        reason: String,
        fields: [String: String],
        localSessionProjection: LocalSessionDiagnosticsProjection?,
        uiProjection: UIProjectionDiagnostics?
    ) {
        if stateCaptures.first?.fields == fields {
            recordInvariantViolationCandidatesOnMain(
                reason: reason,
                candidates: (localSessionProjection?.derivedInvariantCandidates ?? [])
                    + (uiProjection?.derivedInvariantCandidates ?? [])
            )
            return
        }

        let changedKeys = DiagnosticsStore.changedKeys(
            from: stateCaptures.first?.fields ?? [:],
            to: fields
        )

        let capture = DiagnosticsStateCapture(
            reason: reason,
            changedKeys: changedKeys,
            fields: fields
        )
        stateCaptures.insert(capture, at: 0)
        if stateCaptures.count > stateCaptureLimit {
            stateCaptures.removeLast(stateCaptures.count - stateCaptureLimit)
        }
        logger.debug(
            "state: \(reason, privacy: .public) changed=\(changedKeys.joined(separator: ","), privacy: .public) \(capture.summaryLine, privacy: .public)"
        )
        appendStateCaptureToDisk(capture)

        recordInvariantViolationCandidatesOnMain(
            reason: reason,
            candidates: (localSessionProjection?.derivedInvariantCandidates ?? [])
                + (uiProjection?.derivedInvariantCandidates ?? [])
        )
    }

    private func recordInvariantViolationCandidatesOnMain(
        reason: String,
        candidates: [DiagnosticsInvariantViolationCandidate]
    ) {
        for violation in candidates {
            recordInvariantViolationOnMain(
                invariantID: violation.invariantID,
                scope: violation.scope,
                message: violation.message,
                metadata: violation.metadata.merging(
                    [
                        "reason": reason,
                    ],
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }
    }

    private func recordInvariantViolationOnMain(
        invariantID: String,
        scope: DiagnosticsInvariantScope,
        message: String,
        metadata: [String: String]
    ) {
        let violation = DiagnosticsInvariantViolation(
            invariantID: invariantID,
            scope: scope,
            message: message,
            metadata: metadata
        )

        if invariantViolations.first.map({
            $0.invariantID == violation.invariantID &&
                $0.scope == violation.scope &&
                $0.message == violation.message &&
                $0.metadata == violation.metadata
        }) == true {
            return
        }

        invariantViolations.insert(violation, at: 0)
        if invariantViolations.count > invariantViolationLimit {
            invariantViolations.removeLast(invariantViolations.count - invariantViolationLimit)
        }
        onHighSignalEvent?(.invariantViolation(violation))

        var diagnosticMetadata = metadata
        diagnosticMetadata["invariantID"] = invariantID
        diagnosticMetadata["scope"] = scope.rawValue
        recordOnMain(
            subsystem: .invariant,
            level: .error,
            message: message,
            metadata: diagnosticMetadata
        )
    }

    func exportText(snapshot: String? = nil, structuredEnvelopeJSON: String? = nil) -> String {
        var sections: [String] = []
        if let snapshot, !snapshot.isEmpty {
            sections.append("STATE SNAPSHOT\n\(snapshot)")
        }
        if let structuredEnvelopeJSON, !structuredEnvelopeJSON.isEmpty {
            sections.append("STRUCTURED DIAGNOSTICS\n\(structuredEnvelopeJSON)")
        }

        if stateCaptures.isEmpty {
            sections.append("STATE TIMELINE\n<empty>")
        } else {
            let lines = stateCaptures.map { capture in
                let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: capture.timestamp)
                let changed =
                    capture.changedKeys.isEmpty
                    ? "none"
                    : capture.changedKeys.joined(separator: ",")
                return "[\(timestamp)] [\(capture.reason)] changed=\(changed) \(capture.summaryLine)"
            }
            sections.append("STATE TIMELINE\n" + lines.joined(separator: "\n"))
        }

        if invariantViolations.isEmpty {
            sections.append("INVARIANT VIOLATIONS\n<empty>")
        } else {
            let lines = invariantViolations.map { violation in
                let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: violation.timestamp)
                let metadata =
                    violation.metadata.isEmpty
                    ? ""
                    : " " + violation.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                return "[\(timestamp)] [\(violation.invariantID)] [\(violation.scope.rawValue)] \(violation.message)\(metadata)"
            }
            sections.append("INVARIANT VIOLATIONS\n" + lines.joined(separator: "\n"))
        }

        if reducerTransitionReports.isEmpty {
            sections.append("REDUCER TRANSITIONS\n<empty>")
        } else {
            let lines = reducerTransitionReports.map { report in
                let effects =
                    report.effectsEmitted.isEmpty
                    ? "none"
                    : report.effectsEmitted.joined(separator: ",")
                let correlations =
                    report.correlationIDs.isEmpty
                    ? ""
                    : " " + report.correlationIDs.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                let invariants =
                    report.invariantViolationsEmitted.isEmpty
                    ? "none"
                    : report.invariantViolationsEmitted.joined(separator: ",")
                return "[\(report.reducerName)] [\(report.eventName)] effects=\(effects) invariants=\(invariants)\(correlations) from=\(report.previousStateSummary) to=\(report.nextStateSummary)"
            }
            sections.append("REDUCER TRANSITIONS\n" + lines.joined(separator: "\n"))
        }

        if entries.isEmpty {
            sections.append("DIAGNOSTICS\n<empty>")
        } else {
            let lines = entries.map { entry in
                let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: entry.timestamp)
                let metadata =
                    entry.metadata.isEmpty
                    ? ""
                    : " " + entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                return "[\(timestamp)] [\(entry.level.rawValue)] [\(entry.subsystem.rawValue)] \(entry.message)\(metadata)"
            }
            sections.append("DIAGNOSTICS\n" + lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    private func appendToDisk(_ entry: DiagnosticsEntry) {
        let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: entry.timestamp)
        let metadata =
            entry.metadata.isEmpty
            ? ""
            : " " + entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let line = "[\(timestamp)] [\(entry.level.rawValue)] [\(entry.subsystem.rawValue)] \(entry.message)\(metadata)\n"
        appendLineToDisk(line)
    }

    private func appendStateCaptureToDisk(_ capture: DiagnosticsStateCapture) {
        let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: capture.timestamp)
        let changed =
            capture.changedKeys.isEmpty
            ? "none"
            : capture.changedKeys.joined(separator: ",")
        let line = "[\(timestamp)] [state] [\(capture.reason)] changed=\(changed) \(capture.summaryLine)\n"
        appendLineToDisk(line)
    }

    private func appendReducerTransitionToDisk(_ report: ReducerTransitionReport) {
        let effects =
            report.effectsEmitted.isEmpty
            ? "none"
            : report.effectsEmitted.joined(separator: ",")
        let correlations =
            report.correlationIDs.isEmpty
            ? ""
            : " " + report.correlationIDs.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let line = "[transition] [\(report.reducerName)] [\(report.eventName)] effects=\(effects)\(correlations) from=\(report.previousStateSummary) to=\(report.nextStateSummary)\n"
        appendLineToDisk(line)
    }

    private func appendLineToDisk(_ line: String) {
        guard let logFileURL,
              let data = line.data(using: .utf8) else {
            return
        }
        diskQueue.async {
            guard let handle = try? FileHandle(forWritingTo: logFileURL) else {
                return
            }
            defer {
                try? handle.close()
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func changedKeys(from oldFields: [String: String], to newFields: [String: String]) -> [String] {
        Array(Set(oldFields.keys).union(newFields.keys))
            .filter { oldFields[$0] != newFields[$0] }
            .sorted()
    }

    private func refreshLatestErrorEntry(afterRecording entry: DiagnosticsEntry) {
        if entry.level == .error {
            latestErrorEntry = entry
            return
        }

        guard let latestErrorEntry else { return }
        if entries.contains(where: { $0.id == latestErrorEntry.id }) {
            return
        }

        self.latestErrorEntry = entries.first(where: { $0.level == .error })
    }
}

struct DiagnosticsInvariantViolationCandidate: Equatable {
    let invariantID: String
    let scope: DiagnosticsInvariantScope
    let message: String
    let metadata: [String: String]
}

private extension DiagnosticsLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .notice:
            return .default
        case .error:
            return .error
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    var formattedForLog: String {
        guard !isEmpty else { return "" }
        return map { "\($0)=\($1)" }.sorted().joined(separator: " ")
    }
}
