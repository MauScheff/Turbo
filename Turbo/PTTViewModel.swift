//
//  PTTViewModel.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import Observation
import PushToTalk
import AVFAudio
import UIKit

enum AudioOutputPreference: String, Equatable {
    case speaker
    case phone

    static let storageKey = "turbo.audioOutputPreference"

    static func loadStored() -> AudioOutputPreference {
        .speaker
    }

    var next: AudioOutputPreference {
        switch self {
        case .speaker:
            return .phone
        case .phone:
            return .speaker
        }
    }

    var buttonLabel: String {
        switch self {
        case .speaker:
            return "Speaker"
        case .phone:
            return "Phone"
        }
    }
}

@MainActor
@Observable
final class PTTViewModel: NSObject, MediaSessionDelegate {
    var isReady: Bool = false
    var isJoined: Bool = false
    var isTransmitting: Bool = false
    var statusMessage: String = "Initializing..."
    var pushTokenHex: String = ""
    var contacts: [Contact] = []
    var selectedContactId: UUID?
    var activeChannelId: UUID?
    let diagnostics = DiagnosticsStore()

    let pttSystemClient: any PTTSystemClientProtocol
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
    var pttWakeRuntime = PTTWakeRuntimeState()
    var mediaRuntime = MediaRuntimeState()
    var localReceiverAudioReadinessPublications: [UUID: ReceiverAudioReadinessPublication] = [:]
    var remoteTransmittingContactIDs: Set<UUID> = []
    var remoteAudioSilenceTasks: [UUID: Task<Void, Never>] = [:]
    private var diagnosticsAutoPublishTask: Task<Void, Never>?
    var automaticDiagnosticsPublishEnabled: Bool = true
    var microphonePermission: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    var audioOutputPreference: AudioOutputPreference = .loadStored()

    override init() {
        pttSystemClient = makeDefaultPTTSystemClient()
        audioOutputPreference = .speaker
        UserDefaults.standard.set(AudioOutputPreference.speaker.rawValue, forKey: AudioOutputPreference.storageKey)
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
        registerAudioSessionObservers()
        registerApplicationLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func syncPTTState() {
        let previousActiveChannelID = activeChannelId
        activeChannelId = pttCoordinator.state.activeContactID
        isJoined = pttCoordinator.state.isJoined
        isTransmitting = pttCoordinator.state.isTransmitting
        captureDiagnosticsState("ptt-sync")
        let readinessContactIDs = Set(
            [previousActiveChannelID, activeChannelId, mediaSessionContactID].compactMap { $0 }
        )
        for contactID in readinessContactIDs {
            Task {
                await syncLocalReceiverAudioReadinessSignal(for: contactID, reason: "ptt-sync")
            }
        }
    }

    var pendingJoinContactId: UUID? {
        sessionCoordinator.pendingJoinContactID
    }

    func syncTransmitState() {
        transmitRuntime.sync(
            activeTarget: transmitCoordinator.state.activeTarget,
            isPressingTalk: transmitCoordinator.state.isPressingTalk
        )
        captureDiagnosticsState("transmit-sync")
    }

    func syncPTTSystemPolicyState() {
        pushTokenHex = pttSystemPolicyCoordinator.state.latestTokenHex
        captureDiagnosticsState("ptt-policy-sync")
    }

    func applyAuthenticatedBackendSession(
        client: TurboBackendClient,
        userID: String,
        mode: String
    ) {
        backendRuntime.applyAuthenticatedSession(client: client, userID: userID, mode: mode)
    }

    func storeAuthenticatedUserID(_ userID: String) {
        backendRuntime.storeAuthenticatedUserID(userID)
    }

    func resetBackendRuntimeForReconnect() {
        backendRuntime.disconnectForReconnect()
        localReceiverAudioReadinessPublications = [:]
    }

    func replaceBackendConfig(with config: TurboBackendConfig?) {
        backendRuntime.replaceConfig(with: config)
    }

    func replaceBackendPollTask(with task: Task<Void, Never>?) {
        backendRuntime.replacePollTask(with: task)
    }

    func clearTrackedContacts() {
        backendRuntime.clearTrackedContacts()
    }

    func trackContact(_ contactID: UUID) {
        backendRuntime.track(contactID: contactID)
    }

    func resetTransportFaults() {
        backendRuntime.transportFaults.reset()
        diagnostics.record(.backend, message: "Reset transport fault injection state")
    }

    func setHTTPTransportDelay(route: TransportFaultHTTPRoute, milliseconds: Int, count: Int) {
        backendRuntime.transportFaults.setHTTPDelay(route: route, milliseconds: milliseconds, count: count)
        diagnostics.record(
            .backend,
            message: "Configured HTTP transport delay",
            metadata: ["route": route.rawValue, "milliseconds": "\(milliseconds)", "count": "\(count)"]
        )
    }

    func setIncomingWebSocketSignalDelay(kind: TurboSignalKind, milliseconds: Int, count: Int) {
        backendRuntime.transportFaults.setWebSocketSignalDelay(
            kind: kind,
            milliseconds: milliseconds,
            count: count
        )
        diagnostics.record(
            .websocket,
            message: "Configured websocket signal delay",
            metadata: ["type": kind.rawValue, "milliseconds": "\(milliseconds)", "count": "\(count)"]
        )
    }

    func dropNextIncomingWebSocketSignals(kind: TurboSignalKind, count: Int) {
        backendRuntime.transportFaults.dropNextWebSocketSignals(kind: kind, count: count)
        diagnostics.record(
            .websocket,
            message: "Configured websocket signal drop",
            metadata: ["type": kind.rawValue, "count": "\(count)"]
        )
    }

    func duplicateNextIncomingWebSocketSignals(kind: TurboSignalKind, count: Int) {
        backendRuntime.transportFaults.duplicateNextWebSocketSignals(kind: kind, count: count)
        diagnostics.record(
            .websocket,
            message: "Configured websocket signal duplication",
            metadata: ["type": kind.rawValue, "count": "\(count)"]
        )
    }

    func reorderNextIncomingWebSocketSignals(kind: TurboSignalKind?, count: Int) {
        backendRuntime.transportFaults.reorderNextWebSocketSignals(kind: kind, count: count)
        diagnostics.record(
            .websocket,
            message: "Configured websocket signal reorder",
            metadata: ["type": kind?.rawValue ?? "any", "count": "\(count)"]
        )
    }

    func cancelPendingTransmitWork() {
        transmitRuntime.clearPendingWork()
    }

    func resetTransmitRuntimeOnly() {
        transmitRuntime.reset()
    }

    func tearDownTransmitRuntime(resetCoordinator: Bool) {
        transmitRuntime.reset()
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

    var backendConfig: TurboBackendConfig? {
        backendRuntime.config
    }

    var hasBackendConfig: Bool {
        backendConfig != nil
    }

    var backendServices: BackendServices? {
        let runtime = backendRuntime
        guard let client = runtime.client else { return nil }
        return BackendServices(
            client: client,
            currentUserID: runtime.currentUserID,
            mode: runtime.mode
        )
    }

    var latestSelfCheckReport: DevSelfCheckReport? {
        selfCheckCoordinator.state.latestReport
    }

    var hasPendingBackendPollTask: Bool {
        backendRuntime.pollTask != nil
    }

    var trackedContactIDs: Set<UUID> {
        backendRuntime.trackedContactIDs
    }

    var transmitServices: TransmitServices {
        TransmitServices(
            hasPendingBeginOrActiveTarget: { [weak self] in
                self?.transmitRuntime.hasPendingBeginOrActiveTarget ?? false
            },
            activeTarget: { [weak self] in
                self?.transmitRuntime.activeTarget
            },
            replaceBeginTask: { [weak self] task in
                self?.transmitRuntime.replaceBeginTask(with: task)
            },
            replaceRenewTask: { [weak self] task in
                self?.transmitRuntime.replaceRenewTask(with: task)
            },
            clearPendingWork: { [weak self] in
                self?.transmitRuntime.clearPendingWork()
            },
            reset: { [weak self] in
                self?.transmitRuntime.reset()
            }
        )
    }

    var mediaServices: MediaServices {
        MediaServices(
            session: { [weak self] in
                self?.mediaRuntime.session
            },
            contactID: { [weak self] in
                self?.mediaRuntime.contactID
            },
            hasSession: { [weak self] in
                self?.mediaRuntime.hasSession ?? false
            },
            sendAudioChunk: { [weak self] in
                self?.mediaRuntime.sendAudioChunk
            },
            attach: { [weak self] session, contactID in
                self?.mediaRuntime.attach(session: session, contactID: contactID)
            },
            updateConnectionState: { [weak self] state in
                self?.mediaRuntime.updateConnectionState(state)
            },
            isStartupInFlight: { [weak self] context in
                self?.mediaRuntime.isStartupInFlight(for: context) ?? false
            },
            shouldDelayRetry: { [weak self] context, cooldown in
                self?.mediaRuntime.shouldDelayRetry(for: context, cooldown: cooldown) ?? false
            },
            markStartupInFlight: { [weak self] context in
                self?.mediaRuntime.markStartupInFlight(context)
            },
            markStartupSucceeded: { [weak self] in
                self?.mediaRuntime.markStartupSucceeded()
            },
            markStartupFailed: { [weak self] context, message in
                self?.mediaRuntime.markStartupFailed(context, message: message)
            },
            replaceSendAudioChunk: { [weak self] handler in
                self?.mediaRuntime.replaceSendAudioChunk(with: handler)
            },
            reset: { [weak self] in
                self?.mediaRuntime.reset()
            }
        )
    }

    var mediaConnectionState: MediaConnectionState {
        mediaRuntime.connectionState
    }

    var mediaSessionContactID: UUID? {
        mediaRuntime.contactID
    }

    var hasActiveTransmitOrMediaSession: Bool {
        transmitServices.activeTarget() != nil || mediaServices.session() != nil
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

    var appVersionDescription: String {
        let shortVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        let buildNumber =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? shortVersion
        return shortVersion == buildNumber ? shortVersion : "\(shortVersion) (\(buildNumber))"
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

    var selectedSessionDiagnosticsSummary: SelectedSessionDiagnosticsSummary {
        let selectedState: SelectedPeerState
        let selectedChannelProjection: ChannelReadinessSnapshot?
        if let selectedContactId {
            selectedState = selectedPeerState(for: selectedContactId)
            selectedChannelProjection = self.selectedChannelSnapshot(for: selectedContactId)
        } else {
            selectedState = SelectedPeerState(
                relationship: .none,
                phase: .idle,
                statusMessage: "Ready to connect",
                canTransmitNow: false
            )
            selectedChannelProjection = nil
        }

        return SelectedSessionDiagnosticsSummary(
            selectedHandle: selectedContact?.handle,
            selectedPhase: String(describing: selectedState.phase),
            selectedPhaseDetail: String(describing: selectedState.detail),
            relationship: String(describing: selectedState.relationship),
            statusMessage: selectedState.statusMessage,
            canTransmitNow: selectedState.canTransmitNow,
            isJoined: isJoined,
            isTransmitting: isTransmitting,
            activeChannelID: activeChannelId?.uuidString,
            pendingAction: String(describing: sessionCoordinator.pendingAction),
            systemSession: String(describing: systemSessionState),
            mediaState: String(describing: mediaRuntime.connectionState),
            backendChannelStatus: selectedChannelProjection?.status?.rawValue,
            backendReadiness: selectedChannelProjection?.readinessStatus?.kind,
            backendMembership: selectedChannelProjection.map { String(describing: $0.membership) },
            backendRequestRelationship: selectedChannelProjection.map { String(describing: $0.requestRelationship) },
            backendSelfJoined: selectedChannelProjection.map { $0.membership.hasLocalMembership },
            backendPeerJoined: selectedChannelProjection.map { $0.membership.hasPeerMembership },
            backendPeerDeviceConnected: selectedChannelProjection.map { $0.membership.peerDeviceConnected },
            remoteAudioReadiness: selectedChannelProjection.map { String(describing: $0.remoteAudioReadiness) },
            remoteWakeCapability: selectedChannelProjection.map { String(describing: $0.remoteWakeCapability) },
            backendCanTransmit: selectedChannelProjection.map(\.canTransmit),
            incomingWakeActivationState: selectedContact.flatMap { contact in
                pttWakeRuntime.incomingWakeActivationState(for: contact.id).map { String(describing: $0) }
            },
            incomingWakeBufferedChunkCount: selectedContact.map {
                pttWakeRuntime.bufferedAudioChunkCount(for: $0.id)
            }
        )
    }

    var contactDiagnosticsSummaries: [ContactDiagnosticsSummary] {
        contacts
            .filter { $0.handle != currentDevUserHandle }
            .sorted { $0.handle < $1.handle }
            .map { contact in
                let summary = contactSummaryByContactID[contact.id]
                return ContactDiagnosticsSummary(
                    handle: contact.handle,
                    isOnline: summary?.isOnline ?? contact.isOnline,
                    listState: listConversationState(for: contact.id).rawValue,
                    badgeStatus: summary?.badgeKind,
                    requestRelationship: String(describing: summary?.requestRelationship ?? .none),
                    hasIncomingRequest: summary?.requestRelationship.hasIncomingRequest ?? false,
                    hasOutgoingRequest: summary?.requestRelationship.hasOutgoingRequest ?? false,
                    requestCount: summary?.requestRelationship.requestCount ?? 0,
                    incomingInviteCount: incomingInviteByContactID[contact.id]?.requestCount,
                    outgoingInviteCount: outgoingInviteByContactID[contact.id]?.requestCount
                )
            }
    }

    var stateMachineProjection: StateMachineProjection {
        StateMachineProjection(
            selectedSession: selectedSessionDiagnosticsSummary,
            contacts: contactDiagnosticsSummaries,
            isWebSocketConnected: backendRuntime.isWebSocketConnected,
            statusMessage: statusMessage,
            backendStatusMessage: backendStatusMessage
        )
    }

    var diagnosticsStateFields: [String: String] {
        let projection = stateMachineProjection
        let selectedSession = projection.selectedSession
        return [
            "identity": currentDevUserHandle,
            "selectedContact": selectedContact?.handle ?? "none",
            "selectedPeerPhase": selectedSession.selectedPhase,
            "selectedPeerPhaseDetail": selectedSession.selectedPhaseDetail,
            "selectedPeerRelationship": selectedSession.relationship,
            "selectedPeerStatus": selectedSession.statusMessage,
            "selectedPeerCanTransmit": String(selectedSession.canTransmitNow),
            "pendingAction": selectedSession.pendingAction,
            "activeChannelId": activeChannelId?.uuidString ?? "none",
            "isJoined": String(isJoined),
            "isTransmitting": String(isTransmitting),
            "isBackendReady": String(backendRuntime.isReady),
            "backendMode": backendRuntime.mode,
            "systemSession": String(describing: systemSessionState),
            "pttClientMode": pttSystemClient.modeDescription,
            "pendingIncomingPush": pttWakeRuntime.pendingIncomingPush.map { push in
                "\(push.payload.event.rawValue):\(contacts.first(where: { $0.id == push.contactID })?.handle ?? push.contactID.uuidString)"
            } ?? "none",
            "pendingIncomingPushActivated": pttWakeRuntime.pendingIncomingPush.map {
                String($0.playbackMode == .systemActivated)
            } ?? "false",
            "incomingWakeActivationState": selectedSession.incomingWakeActivationState ?? "none",
            "incomingWakeBufferedChunkCount": selectedSession.incomingWakeBufferedChunkCount.map(String.init(describing:)) ?? "0",
            "localJoinFailure": pttCoordinator.state.lastJoinFailure.map(String.init(describing:)) ?? "none",
            "websocket": backendRuntime.isWebSocketConnected ? "connected" : "disconnected",
            "mediaState": String(describing: mediaRuntime.connectionState),
            "backendChannelStatus": selectedSession.backendChannelStatus ?? "none",
            "backendReadiness": selectedSession.backendReadiness ?? "none",
            "backendMembership": selectedSession.backendMembership ?? "none",
            "backendRequestRelationship": selectedSession.backendRequestRelationship ?? "none",
            "backendSelfJoined": selectedSession.backendSelfJoined.map(String.init(describing:)) ?? "none",
            "backendPeerJoined": selectedSession.backendPeerJoined.map(String.init(describing:)) ?? "none",
            "backendPeerDeviceConnected": selectedSession.backendPeerDeviceConnected.map(String.init(describing:)) ?? "none",
            "remoteAudioReadiness": selectedSession.remoteAudioReadiness ?? "unknown",
            "remoteWakeCapability": selectedSession.remoteWakeCapability ?? "unavailable",
            "backendCanTransmit": selectedSession.backendCanTransmit.map(String.init(describing:)) ?? "none",
            "status": statusMessage,
            "backendStatus": backendStatusMessage
        ]
    }

    var diagnosticsSnapshot: String {
        let coreLines = diagnosticsStateFields.keys.sorted().map { "\($0)=\(diagnosticsStateFields[$0] ?? "")" }
        let contactLines = stateMachineProjection.contacts.flatMap { summary in
            [
                "contact[\(summary.handle)].isOnline=\(summary.isOnline)",
                "contact[\(summary.handle)].listState=\(summary.listState)",
                "contact[\(summary.handle)].badgeStatus=\(summary.badgeStatus ?? "none")",
                "contact[\(summary.handle)].requestRelationship=\(summary.requestRelationship)",
                "contact[\(summary.handle)].hasIncomingRequest=\(summary.hasIncomingRequest)",
                "contact[\(summary.handle)].hasOutgoingRequest=\(summary.hasOutgoingRequest)",
                "contact[\(summary.handle)].requestCount=\(summary.requestCount)",
                "contact[\(summary.handle)].incomingInviteCount=\(summary.incomingInviteCount.map(String.init(describing:)) ?? "none")",
                "contact[\(summary.handle)].outgoingInviteCount=\(summary.outgoingInviteCount.map(String.init(describing:)) ?? "none")",
            ]
        }
        return (coreLines + contactLines).joined(separator: "\n")
    }

    var diagnosticsTranscript: String {
        diagnostics.exportText(snapshot: diagnosticsSnapshot)
    }

    func captureDiagnosticsState(_ reason: String) {
        diagnostics.captureState(reason: reason, fields: diagnosticsStateFields)
        scheduleAutomaticDiagnosticsPublish(trigger: reason)
    }

    func scheduleAutomaticDiagnosticsPublish(trigger: String) {
#if DEBUG
        guard automaticDiagnosticsPublishEnabled else { return }
        guard backendServices != nil, backendConfig != nil else { return }
        diagnosticsAutoPublishTask?.cancel()
        diagnosticsAutoPublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            _ = try? await self.publishDiagnosticsIfPossible(trigger: trigger, recordSuccess: false)
        }
#endif
    }

    func cancelAutomaticDiagnosticsPublish() {
        diagnosticsAutoPublishTask?.cancel()
        diagnosticsAutoPublishTask = nil
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

    func canBeginTransmit(for contactID: UUID) -> Bool {
        guard selectedContactId == contactID else { return false }
        return selectedPeerState(for: contactID).allowsHoldToTalk
    }

    func receiveRemoteAudioChunk(_ payload: String) async {
        await mediaServices.session()?.receiveRemoteAudioChunk(payload)
    }

    func refreshMicrophonePermission() {
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    var microphonePermissionStatusText: String {
        switch microphonePermission {
        case .granted:
            return "Microphone enabled"
        case .denied:
            return "Microphone denied"
        case .undetermined:
            return "Microphone not requested"
        @unknown default:
            return "Microphone unknown"
        }
    }

    var needsMicrophonePermission: Bool {
        microphonePermission != .granted
    }

    func requestMicrophonePermission() async {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.refreshMicrophonePermission()
                    self?.diagnostics.record(
                        .app,
                        message: "Microphone permission resolved",
                        metadata: ["granted": granted ? "true" : "false"]
                    )
                    self?.captureDiagnosticsState("microphone-permission")
                    continuation.resume()
                }
            }
        }
    }

    private func registerAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChangeNotification(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionMediaServicesResetNotification(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    private func registerApplicationLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActiveNotification(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillResignActiveNotification(_:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidEnterBackgroundNotification(_:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func handleAudioSessionInterruptionNotification(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let rawType = (info[AVAudioSessionInterruptionTypeKey] as? UInt).map(String.init) ?? "unknown"
        let rawOptions = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(String.init) ?? "0"
        diagnostics.record(
            .media,
            message: "Audio session interruption notification",
            metadata: audioSessionDiagnostics().merging(
                [
                    "type": rawType,
                    "options": rawOptions
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
    }

    @objc private func handleAudioSessionRouteChangeNotification(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let rawReason = (info[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "unknown"
        diagnostics.record(
            .media,
            message: "Audio session route change notification",
            metadata: audioSessionDiagnostics().merging(
                ["reason": rawReason],
                uniquingKeysWith: { _, new in new }
            )
        )
    }

    @objc private func handleAudioSessionMediaServicesResetNotification(_ notification: Notification) {
        let _ = notification
        diagnostics.record(
            .media,
            message: "Audio session media services were reset",
            metadata: audioSessionDiagnostics()
        )
    }

    @objc private func handleApplicationDidBecomeActiveNotification(_ notification: Notification) {
        let _ = notification
        diagnostics.record(
            .app,
            message: "Application became active",
            metadata: [:]
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resumeBufferedWakePlaybackIfNeeded(
                reason: "application-became-active",
                applicationState: .active
            )
        }
    }

    @objc private func handleApplicationWillResignActiveNotification(_ notification: Notification) {
        let _ = notification
        diagnostics.record(
            .app,
            message: "Application will resign active",
            metadata: [:]
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.suspendForegroundMediaForBackgroundTransition(
                reason: "application-will-resign-active",
                applicationState: .inactive
            )
        }
    }

    @objc private func handleApplicationDidEnterBackgroundNotification(_ notification: Notification) {
        let _ = notification
        diagnostics.record(
            .app,
            message: "Application entered background",
            metadata: [:]
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.suspendForegroundMediaForBackgroundTransition(
                reason: "application-did-enter-background",
                applicationState: .background
            )
        }
    }
}
