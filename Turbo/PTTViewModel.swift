//
//  PTTViewModel.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import Observation
import PushToTalk

struct BackendRuntimeState {
    var pollTask: Task<Void, Never>?
    var config = TurboBackendConfig.load()
    var client: TurboBackendClient?
    var currentUserID: String?
    var isReady: Bool = false
    var mode: String = "unknown"
    var trackedContactIDs: Set<UUID> = []
}

struct TransmitRuntimeState {
    var activeTarget: TransmitTarget?
    var beginTask: Task<Void, Never>?
    var renewTask: Task<Void, Never>?
    var isPressingTalk: Bool = false
}

struct MediaRuntimeState {
    var session: MediaSession?
    var contactID: UUID?
    var connectionState: MediaConnectionState = .idle
}

@MainActor
@Observable
final class PTTViewModel: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate, MediaSessionDelegate {
    var isReady: Bool = false
    var isJoined: Bool = false
    var isTransmitting: Bool = false
    var statusMessage: String = "Initializing..."
    var pushTokenHex: String = ""
    var contacts: [Contact] = []
    var selectedContactId: UUID?
    var activeChannelId: UUID?
    let diagnostics = DiagnosticsStore()

    let pttSystemClient = PTTSystemClient()
    let channelName: String = "BeepBeep Prototype"
    var sessionCoordinator = SessionCoordinatorState()
    let backendSyncCoordinator = BackendSyncCoordinator()
    let backendCommandCoordinator = BackendCommandCoordinator()
    let pttCoordinator = PTTCoordinator()
    let transmitCoordinator = TransmitCoordinator()
    let selectedPeerCoordinator = SelectedPeerCoordinator()
    let selfCheckCoordinator = DevSelfCheckCoordinator()
    let pttSystemPolicyCoordinator = PTTSystemPolicyCoordinator()
    var backendRuntime = BackendRuntimeState()
    var transmitRuntime = TransmitRuntimeState()
    var mediaRuntime = MediaRuntimeState()

    override init() {
        super.init()
        selectedPeerCoordinator.effectHandler = { [weak self] effect in
            await self?.runSelectedPeerEffect(effect)
        }
        backendSyncCoordinator.effectHandler = { [weak self] effect in
            await self?.runBackendSyncEffect(effect)
        }
        backendCommandCoordinator.effectHandler = { [weak self] effect in
            await self?.runBackendCommandEffect(effect)
        }
        selfCheckCoordinator.effectHandler = { [weak self] effect in
            await self?.runSelfCheckEffect(effect)
        }
        pttSystemPolicyCoordinator.effectHandler = { [weak self] effect in
            await self?.runPTTSystemPolicyEffect(effect)
        }
        pttCoordinator.effectHandler = { [weak self] effect in
            await self?.runPTTEffect(effect)
        }
        transmitCoordinator.effectHandler = { [weak self] effect in
            await self?.runTransmitEffect(effect)
        }
    }

    func syncPTTState() {
        activeChannelId = pttCoordinator.state.activeContactID
        isJoined = pttCoordinator.state.isJoined
        isTransmitting = pttCoordinator.state.isTransmitting
    }

    var pendingJoinContactId: UUID? {
        sessionCoordinator.pendingJoinContactID
    }

    func syncTransmitState() {
        transmitRuntime.activeTarget = transmitCoordinator.state.activeTarget
        transmitRuntime.isPressingTalk = transmitCoordinator.state.isPressingTalk
    }

    func syncPTTSystemPolicyState() {
        pushTokenHex = pttSystemPolicyCoordinator.state.latestTokenHex
    }

    func applyAuthenticatedBackendSession(
        client: TurboBackendClient,
        userID: String,
        mode: String
    ) {
        backendRuntime.client = client
        backendRuntime.currentUserID = userID
        backendRuntime.isReady = true
        backendRuntime.mode = mode
    }

    func resetBackendRuntimeForReconnect() {
        backendRuntime.client?.disconnectWebSocket()
        backendRuntime.client = nil
        backendRuntime.currentUserID = nil
        backendRuntime.isReady = false
        backendRuntime.mode = "unknown"
        backendRuntime.pollTask?.cancel()
        backendRuntime.pollTask = nil
    }

    func clearTrackedContacts() {
        backendRuntime.trackedContactIDs = []
    }

    func cancelPendingTransmitWork() {
        transmitRuntime.beginTask?.cancel()
        transmitRuntime.beginTask = nil
        transmitRuntime.renewTask?.cancel()
        transmitRuntime.renewTask = nil
    }

    func tearDownTransmitRuntime(resetCoordinator: Bool) {
        transmitRuntime.isPressingTalk = false
        transmitRuntime.activeTarget = nil
        cancelPendingTransmitWork()
        if resetCoordinator {
            transmitCoordinator.reset()
            syncTransmitState()
        }
    }

    func resetTransmitSession(closeMediaSession shouldCloseMediaSession: Bool) {
        isTransmitting = false
        tearDownTransmitRuntime(resetCoordinator: true)
        if shouldCloseMediaSession {
            closeMediaSession()
        }
    }

    var selectedContact: Contact? {
        guard let selectedContactId else { return nil }
        return contacts.first { $0.id == selectedContactId }
    }

    var latestSelfCheckReport: DevSelfCheckReport? {
        selfCheckCoordinator.state.latestReport
    }

    var isRunningSelfCheck: Bool {
        selfCheckCoordinator.state.isRunning
    }

    var backendStatusMessage: String {
        get { backendSyncCoordinator.state.syncState.statusMessage }
        set { backendSyncCoordinator.send(.statusMessageUpdated(newValue)) }
    }

    var currentDevUserHandle: String {
        backendRuntime.config?.devUserHandle ?? "@turbo-ios"
    }

    var availableDevUserHandles: [String] {
        Array(Set(([currentDevUserHandle] + ContactDirectory.suggestedDevHandles).map(Contact.normalizedHandle))).sorted()
    }

    var quickPeerHandles: [String] {
        ["@avery", "@blake"]
            .map(Contact.normalizedHandle)
            .filter { $0 != currentDevUserHandle }
    }

    var usesLocalHTTPBackend: Bool {
        backendRuntime.mode == "local-http"
    }

    var diagnosticsSnapshot: String {
        [
            "identity=\(currentDevUserHandle)",
            "selectedContact=\(selectedContact?.handle ?? "none")",
            "activeChannelId=\(activeChannelId?.uuidString ?? "none")",
            "isJoined=\(isJoined)",
            "isTransmitting=\(isTransmitting)",
            "isBackendReady=\(backendRuntime.isReady)",
            "backendMode=\(backendRuntime.mode)",
            "systemSession=\(String(describing: systemSessionState))",
            "websocket=\(backendRuntime.client?.isWebSocketConnected == true ? "connected" : "disconnected")",
            "mediaState=\(String(describing: mediaRuntime.connectionState))",
            "status=\(statusMessage)",
            "backendStatus=\(backendStatusMessage)"
        ].joined(separator: "\n")
    }

    var diagnosticsTranscript: String {
        diagnostics.exportText(snapshot: diagnosticsSnapshot)
    }

    var selectedChannelState: TurboChannelStateResponse? {
        guard let selectedContactId else { return nil }
        return channelStateByContactID[selectedContactId]
    }

    var systemSessionState: SystemPTTSessionState {
        pttCoordinator.state.systemSessionState
    }

    func canTransmitNow(for contactID: UUID) -> Bool {
        guard selectedContactId == contactID else { return false }
        return selectedPeerState(for: contactID).canTransmitNow
    }
}
