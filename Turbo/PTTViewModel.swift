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
import UserNotifications

private final class BackgroundActivityLease {
    var identifier: UIBackgroundTaskIdentifier = .invalid
    var ended = false
}

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

struct AudioOutputRouteOverridePlan: Equatable {
    let shouldApplySpeakerOverride: Bool

    static func forCurrentRoute(
        preference: AudioOutputPreference,
        category: AVAudioSession.Category,
        outputPortTypes: [AVAudioSession.Port]
    ) -> AudioOutputRouteOverridePlan {
        guard preference == .speaker else {
            return AudioOutputRouteOverridePlan(shouldApplySpeakerOverride: false)
        }
        guard category == .playAndRecord else {
            return AudioOutputRouteOverridePlan(shouldApplySpeakerOverride: false)
        }

        let speakerAlreadyActive = outputPortTypes.contains(.builtInSpeaker)
        return AudioOutputRouteOverridePlan(
            shouldApplySpeakerOverride: !speakerAlreadyActive
        )
    }
}

@MainActor
@Observable
final class PTTViewModel: NSObject, MediaSessionDelegate {
    static let shared = PTTViewModel(pttSystemPolicyDefaults: .standard)

    var isReady: Bool = false
    var isJoined: Bool = false
    var isTransmitting: Bool = false
    var statusMessage: String = "Initializing..."
    var pushTokenHex: String = ""
    var alertPushTokenHex: String = ""
    var contacts: [Contact] = []
    var selectedContactId: UUID?
    var activeChannelId: UUID?
    let diagnostics = DiagnosticsStore()

    let pttSystemClient: any PTTSystemClientProtocol
    @ObservationIgnored
    private let pttSystemPolicyDefaults: UserDefaults?
    let channelName: String = "BeepBeep Prototype"
    var sessionCoordinator = SessionCoordinatorState()
    let backendSyncCoordinator = BackendSyncCoordinator()
    let controlPlaneCoordinator = ControlPlaneCoordinator()
    let receiveExecutionCoordinator = ReceiveExecutionCoordinator()
    let backendCommandCoordinator = BackendCommandCoordinator()
    let pttCoordinator = PTTCoordinator()
    let transmitCoordinator = TransmitCoordinator()
    let transmitTaskCoordinator = TransmitTaskCoordinator()
    let selectedPeerCoordinator = SelectedPeerCoordinator()
    let selfCheckCoordinator = DevSelfCheckCoordinator()
    let pttSystemPolicyCoordinator = PTTSystemPolicyCoordinator()
    var backendRuntime = BackendRuntimeState()
    var talkRequestSurfaceState = TalkRequestSurfaceState()
    var transmitRuntime = TransmitRuntimeState()
    var transmitTaskRuntime = TransmitTaskRuntimeState()
    var pttWakeRuntime = PTTWakeRuntimeState()
    var receiveExecutionRuntime = ReceiveExecutionRuntimeState()
    var mediaRuntime = MediaRuntimeState()
    var isPTTAudioSessionActive: Bool = false
    var backendBootstrapRetryDelayNanoseconds: UInt64 = 2_000_000_000
    var remoteAudioInitialChunkTimeoutNanoseconds: UInt64 = 5_000_000_000
    var remoteAudioSilenceTimeoutNanoseconds: UInt64 = 1_500_000_000
    var lastReportedPTTServiceStatus: PTServiceStatus?
    var lastReportedPTTServiceStatusChannelUUID: UUID?
    var lastReportedPTTServiceStatusReason: String?
    var lastReportedPTTDescriptorName: String?
    var lastReportedPTTDescriptorChannelUUID: UUID?
    var lastReportedPTTDescriptorReason: String?
    private var diagnosticsAutoPublishTask: Task<Void, Never>?
    var automaticDiagnosticsPublishEnabled: Bool = true
    var conversationShortcutPolicy: ConversationShortcutPolicy = .load()
    var microphonePermission: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    var audioOutputPreference: AudioOutputPreference = .loadStored()
    var pendingTalkRequestNotificationHandle: String?
    var applicationStateOverride: UIApplication.State?
    @ObservationIgnored
    var backgroundOfflinePresenceHandler: (@MainActor () async -> Void)?
    @ObservationIgnored
    var backgroundSessionPresenceHandler: (@MainActor () async -> Void)?
    @ObservationIgnored
    var backgroundWebSocketSuspendHandler: (@MainActor () -> Void)?
    @ObservationIgnored
    var beginBackgroundActivity: @MainActor (String, @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier = { name, expiration in
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }
    @ObservationIgnored
    var endBackgroundActivity: @MainActor (UIBackgroundTaskIdentifier) -> Void = { identifier in
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
    @ObservationIgnored
    var setApplicationBadgeCount: @MainActor (Int) -> Void = { count in
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
    @ObservationIgnored
    var clearDeliveredNotifications: @MainActor () -> Void = {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    var localReceiverAudioReadinessPublications: [UUID: ReceiverAudioReadinessPublication] {
        get { controlPlaneCoordinator.state.localReceiverAudioReadinessPublications }
        set { controlPlaneCoordinator.replaceLocalReceiverAudioReadinessPublications(newValue) }
    }

    var remoteTransmittingContactIDs: Set<UUID> {
        get { receiveExecutionCoordinator.state.remoteTransmittingContactIDs }
        set { receiveExecutionCoordinator.replaceRemoteTransmittingContactIDs(newValue) }
    }

    var remoteAudioSilenceTasks: [UUID: Task<Void, Never>] {
        get { receiveExecutionRuntime.remoteAudioSilenceTasks }
        set { receiveExecutionRuntime.replaceRemoteAudioSilenceTasks(newValue) }
    }

    init(
        pttSystemClient: (any PTTSystemClientProtocol)? = nil,
        pttSystemPolicyDefaults: UserDefaults? = nil
    ) {
        self.pttSystemClient = pttSystemClient ?? makeDefaultPTTSystemClient()
        self.pttSystemPolicyDefaults = pttSystemPolicyDefaults
        audioOutputPreference = .speaker
        UserDefaults.standard.set(AudioOutputPreference.speaker.rawValue, forKey: AudioOutputPreference.storageKey)
        super.init()
        diagnostics.onHighSignalEvent = { [weak self] event in
            self?.handleHighSignalDiagnosticsEvent(event)
        }
        selectedPeerCoordinator.effectHandler = { [weak self] effect in
            await self?.runSelectedPeerEffect(effect)
        }
        backendSyncCoordinator.effectHandler = { [weak self] effect in
            await self?.runBackendSyncEffect(effect)
        }
        controlPlaneCoordinator.effectHandler = { [weak self] effect in
            await self?.runControlPlaneEffect(effect)
        }
        receiveExecutionCoordinator.effectHandler = { [weak self] effect in
            self?.runReceiveExecutionEffect(effect)
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
        transmitTaskCoordinator.effectHandler = { [weak self] effect in
            self?.runTransmitTaskEffect(effect)
        }
        pttSystemPolicyCoordinator.stateChangeHandler = { [weak self] state in
            guard let defaults = self?.pttSystemPolicyDefaults else { return }
            PTTSystemPolicyPersistence.store(state, to: defaults)
        }
        registerAudioSessionObservers()
        registerApplicationLifecycleObservers()
        if let defaults = pttSystemPolicyDefaults {
            let restoredPolicyState = PTTSystemPolicyPersistence.load(from: defaults)
            if restoredPolicyState != .initial {
                pttSystemPolicyCoordinator.replaceState(restoredPolicyState)
                syncPTTSystemPolicyState()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func currentApplicationState() -> UIApplication.State {
        applicationStateOverride ?? UIApplication.shared.applicationState
    }

    func shouldPublishForegroundPresence(applicationState: UIApplication.State? = nil) -> Bool {
        (applicationState ?? currentApplicationState()) == .active
    }

    private func performProtectedBackgroundHandoff(
        named name: String,
        operation: @escaping @MainActor () async -> Void
    ) async {
        let lease = BackgroundActivityLease()
        let endLease: @MainActor () -> Void = { [weak self] in
            guard !lease.ended else { return }
            lease.ended = true
            guard lease.identifier != .invalid else { return }
            self?.endBackgroundActivity(lease.identifier)
        }

        lease.identifier = beginBackgroundActivity(name) { [weak self] in
            Task { @MainActor [weak self, endLease, name] in
                self?.diagnostics.record(
                    .app,
                    level: .error,
                    message: "Background handoff expired before completion",
                    metadata: ["name": name]
                )
                endLease()
            }
        }

        await operation()
        endLease()
    }

    /// Debug knob for the requester-side auto-join UX shortcut.
    /// This keeps the shortcut explicit and reversible without changing
    /// the underlying handshake or backend truth.
    func setRequesterAutoJoinOnPeerAcceptanceEnabled(_ enabled: Bool) {
        conversationShortcutPolicy.requesterAutoJoinOnPeerAcceptance = enabled
        ConversationShortcutPolicy.store(conversationShortcutPolicy)
        syncSelectedPeerSession()
    }

    func shouldMaintainBackgroundControlPlane(
        applicationState: UIApplication.State? = nil
    ) -> Bool {
        let state = applicationState ?? currentApplicationState()
        guard state != .active else { return true }

        return hasPendingBeginOrActiveTransmit
            || hasActiveTransmitOrMediaSession
            || isJoined
            || pttCoordinator.state.systemChannelUUID != nil
            || pttWakeRuntime.pendingIncomingPush != nil
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

    var transmitProjection: TransmitProjection {
        TransmitProjection(
            controlPlane: transmitCoordinator.state,
            execution: transmitRuntime.executionState,
            systemChannelUUID: pttCoordinator.state.systemChannelUUID,
            systemActiveContactID: pttCoordinator.state.activeContactID,
            systemIsTransmitting: pttCoordinator.state.isTransmitting
        )
    }

    var transmitDomainSnapshot: TransmitDomainSnapshot {
        transmitProjection.domainSnapshot
    }

    var isTransmitPressActive: Bool {
        transmitDomainSnapshot.isPressActive
    }

    func syncTransmitState() {
        if !isTransmitting,
           !transmitCoordinator.state.isPressingTalk,
           transmitCoordinator.state.phase == .idle,
           !hasPendingBeginOrActiveTransmit {
            transmitRuntime.reconcileIdleState()
        }
        transmitRuntime.syncActiveTarget(transmitCoordinator.state.activeTarget)
        updateStatusForSelectedContact()
        captureDiagnosticsState("transmit-sync")
    }

    func syncPTTSystemPolicyState() {
        pushTokenHex = pttSystemPolicyCoordinator.state.latestTokenHex
        captureDiagnosticsState("ptt-policy-sync")
    }

    func applyAuthenticatedBackendSession(
        client: TurboBackendClient,
        userID: String,
        mode: String,
        telemetryEnabled: Bool = false,
        publicID: String? = nil,
        profileName: String? = nil,
        shareCode: String? = nil,
        shareLink: String? = nil
    ) {
        backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: userID,
            mode: mode,
            telemetryEnabled: telemetryEnabled,
            publicID: publicID,
            profileName: profileName,
            shareCode: shareCode,
            shareLink: shareLink
        )
    }

    func storeAuthenticatedUserID(_ userID: String) {
        backendRuntime.storeAuthenticatedUserID(userID)
    }

    func storeCurrentProfileName(_ profileName: String?) {
        backendRuntime.storeCurrentProfileName(profileName)
    }

    func resetBackendRuntimeForReconnect() {
        backendRuntime.disconnectForReconnect()
        controlPlaneCoordinator.send(.reset)
    }

    func replaceBackendConfig(with config: TurboBackendConfig?) {
        backendRuntime.replaceConfig(with: config)
    }

    func replaceBackendPollTask(with task: Task<Void, Never>?) {
        backendRuntime.replacePollTask(with: task)
    }

    func replaceBackendBootstrapRetryTask(with task: Task<Void, Never>?) {
        backendRuntime.replaceBootstrapRetryTask(with: task)
    }

    func replaceBackendSignalingJoinRecoveryTask(with task: Task<Void, Never>?) {
        backendRuntime.replaceSignalingJoinRecoveryTask(with: task)
    }

    func clearTrackedContacts() {
        backendRuntime.clearTrackedContacts()
    }

    func trackContact(_ contactID: UUID) {
        backendRuntime.track(contactID: contactID)
    }

    func untrackContact(_ contactID: UUID) {
        backendRuntime.untrack(contactID: contactID)
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
        transmitTaskCoordinator.send(.reset)
    }

    func resetTransmitRuntimeOnly() {
        transmitTaskCoordinator.send(.reset)
        transmitRuntime.reset()
    }

    func tearDownTransmitRuntime(resetCoordinator: Bool) {
        transmitTaskCoordinator.send(.reset)
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
            mode: runtime.mode,
            telemetryEnabled: runtime.telemetryEnabled
        )
    }

    var isDirectPathRelayOnlyForced: Bool {
        TurboDirectPathDebugOverride.isRelayOnlyForced()
    }

    var backendAdvertisesDirectQuicUpgrade: Bool {
        backendServices?.supportsDirectQuicUpgrade == true
    }

    var effectiveDirectQuicUpgradeEnabled: Bool {
        backendAdvertisesDirectQuicUpgrade && !isDirectPathRelayOnlyForced
    }

    var selectedDirectQuicDiagnosticsSummary: DirectQuicDiagnosticsSummary {
        let contactID = selectedContactId
        let selectedHandle = selectedContact?.handle
        let attempt = contactID.flatMap { mediaRuntime.directQuicUpgrade.attempt(for: $0) }
        let retryBackoff = contactID.flatMap { mediaRuntime.directQuicUpgrade.retryBackoffState(for: $0) }
        let retryRemainingMilliseconds = contactID.flatMap {
            mediaRuntime.directQuicUpgrade.retryBackoffRemaining(for: $0).map { Int($0 * 1_000) }
        }
        let directQuicPolicy = backendServices?.directQuicPolicy
        let localDeviceID = backendServices?.deviceID
        let peerDeviceID = attempt?.peerDeviceID ?? contactID.flatMap { directQuicPeerDeviceID(for: $0) }
        let identityStatus = DirectQuicIdentityConfiguration.status()
        let installedIdentityCount = DirectQuicIdentityConfiguration.installedIdentityCount()
        let directQuicRole = localDeviceID.flatMap { localDeviceID in
            peerDeviceID.map { peerDeviceID in
                directQuicAttemptRole(
                    localDeviceID: localDeviceID,
                    peerDeviceID: peerDeviceID
                )
            }
        }

        return DirectQuicDiagnosticsSummary(
            selectedHandle: selectedHandle,
            role: directQuicRole.map { role in
                switch role {
                case .listenerOfferer:
                    return "listener-offerer"
                case .dialerAnswerer:
                    return "dialer-answerer"
                }
            },
            identityLabel: identityStatus.resolvedLabel,
            identityStatus: identityStatus.diagnosticsText,
            installedIdentityCount: installedIdentityCount,
            relayOnlyOverride: isDirectPathRelayOnlyForced,
            backendAdvertisesUpgrade: backendAdvertisesDirectQuicUpgrade,
            effectiveUpgradeEnabled: effectiveDirectQuicUpgradeEnabled,
            transportPathState: mediaTransportPathState,
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID,
            attemptID: attempt?.attemptId,
            channelID: attempt?.channelID,
            isDirectActive: attempt?.isDirectActive ?? false,
            remoteCandidateCount: attempt?.remoteCandidateCount ?? 0,
            remoteEndOfCandidates: attempt?.remoteEndOfCandidates ?? false,
            attemptStartedAt: attempt?.startedAt,
            lastUpdatedAt: attempt?.lastUpdatedAt,
            nominatedPathSource: attempt?.nominatedPath?.source.rawValue,
            nominatedRemoteAddress: attempt?.nominatedPath?.remoteAddress,
            nominatedRemotePort: attempt?.nominatedPath?.remotePort,
            nominatedRemoteCandidateKind: attempt?.nominatedPath?.remoteCandidateKind?.rawValue,
            retryReason: retryBackoff?.reason,
            retryCategory: retryBackoff?.category.rawValue,
            retryAttemptID: retryBackoff?.attemptId,
            retryRemainingMilliseconds: retryRemainingMilliseconds,
            retryBackoffMilliseconds: retryBackoff?.milliseconds,
            stunServerCount: directQuicPolicy?.stunServers?.count ?? 0,
            promotionTimeoutMilliseconds: directQuicPromotionTimeoutMilliseconds(),
            retryBackoffBaseMilliseconds: directQuicRetryBackoffMilliseconds(),
            probeControllerReady: mediaRuntime.directQuicProbeController != nil
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
            reset: { [weak self] deactivateAudioSession in
                self?.mediaRuntime.reset(deactivateAudioSession: deactivateAudioSession)
            }
        )
    }

    var mediaConnectionState: MediaConnectionState {
        mediaRuntime.connectionState
    }

    var mediaTransportPathState: MediaTransportPathState {
        mediaRuntime.transportPathState
    }

    var mediaSessionContactID: UUID? {
        mediaRuntime.contactID
    }

    var hasPendingBeginOrActiveTransmit: Bool {
        transmitTaskCoordinator.state.hasPendingBeginOrActiveTarget(
            activeTarget: transmitProjection.activeTarget
        )
    }

    var hasActiveTransmitOrMediaSession: Bool {
        transmitProjection.activeTarget != nil || mediaServices.session() != nil
    }

    var isRunningSelfCheck: Bool {
        selfCheckCoordinator.state.isRunning
    }

    var backendStatusMessage: String {
        get { backendSyncCoordinator.state.syncState.statusMessage }
        set { backendSyncCoordinator.send(.statusMessageUpdated(newValue)) }
    }

    var currentDevUserHandle: String {
        backendRuntime.config?.devUserHandle ?? "bb-local"
    }

    var currentIdentityHandle: String {
        backendRuntime.currentShareCode
            ?? backendRuntime.currentPublicID
            ?? currentDevUserHandle
    }

    var currentContactAliasOwnerKey: String {
        backendRuntime.currentUserID
            ?? backendRuntime.currentPublicID
            ?? currentIdentityHandle
    }

    var currentProfileName: String {
        if let currentProfileName = backendRuntime.currentProfileName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !currentProfileName.isEmpty {
            return currentProfileName
        }
        return TurboIdentityProfileStore.draftProfileName()
    }

    var currentIdentityShareLink: String {
        if let currentShareLink = backendRuntime.currentShareLink,
           !currentShareLink.isEmpty {
            return currentShareLink
        }

        let pathComponent = TurboHandle.sharePathComponent(from: currentIdentityHandle)
        let encodedHandle =
            pathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? pathComponent
        return "https://beepbeep.to/\(encodedHandle)"
    }

    var developerIdentityControlsEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    var hasCompletedIdentityOnboarding: Bool {
        TurboIdentityProfileStore.hasCompletedOnboarding()
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
        guard developerIdentityControlsEnabled else { return [currentDevUserHandle] }
        return Array(
            Set(([currentDevUserHandle] + ContactDirectory.suggestedDevHandles).map(Contact.normalizedHandle))
        ).sorted()
    }

    var quickPeerHandles: [String] {
        guard developerIdentityControlsEnabled else { return [] }
        return ["@avery", "@blake"]
            .map(Contact.normalizedHandle)
            .filter { $0 != currentDevUserHandle }
    }

    var topChromeDiagnosticsErrorText: String? {
        guard let latestError = diagnostics.latestError else { return nil }
        guard shouldSurfaceTopChromeDiagnosticsError(latestError) else { return nil }
        return "\(latestError.subsystem.rawValue): \(latestError.message)"
    }

    var usesLocalHTTPBackend: Bool {
        backendRuntime.mode == "local-http"
    }

    private func shouldSurfaceTopChromeDiagnosticsError(_ entry: DiagnosticsEntry) -> Bool {
        if entry.subsystem == .invariant,
           let invariantID = entry.metadata["invariantID"] {
            let selectedSession = selectedSessionDiagnosticsSummary
            switch invariantID {
            case "selected.wake_capable_peer_blocked_on_local_audio_prewarm":
                return selectedSession.selectedPhase == "waitingForPeer"
                    && selectedSession.selectedPhaseDetail.contains("localAudioPrewarm")
                    && selectedSession.systemSession.hasPrefix("active(")
                    && selectedSession.backendReadiness == "ready"
                    && selectedSession.backendSelfJoined == true
                    && selectedSession.backendPeerJoined == true
                    && selectedSession.remoteAudioReadiness == "wakeCapable"
                    && selectedSession.remoteWakeCapabilityKind == "wake-capable"
            case "selected.backend_ready_missing_remote_audio_signal":
                return selectedSession.selectedPhase == "waitingForPeer"
                    && selectedSession.selectedPhaseDetail.contains("remoteAudioPrewarm")
                    && selectedSession.mediaState == "connected"
                    && selectedSession.backendReadiness == "ready"
                    && selectedSession.backendSelfJoined == true
                    && selectedSession.backendPeerJoined == true
                    && selectedSession.backendPeerDeviceConnected == true
                    && backendRuntime.signalingJoinRecoveryTask == nil
            default:
                break
            }
        }

        switch (entry.subsystem, entry.message) {
        case (.pushToTalk, "PTT init failed"):
            return !pttSystemClient.isReady
        case (.invariant, "backend says the peer is ready and connected, but selectedPeerPhase is still waitingForPeer on remote audio prewarm"):
            let selectedSession = selectedSessionDiagnosticsSummary
            return selectedSession.selectedPhase == "waitingForPeer"
                && selectedSession.selectedPhaseDetail.contains("remoteAudioPrewarm")
                && selectedSession.mediaState == "connected"
                && selectedSession.backendReadiness == "ready"
                && selectedSession.backendSelfJoined == true
                && selectedSession.backendPeerJoined == true
                && selectedSession.backendPeerDeviceConnected == true
                && backendRuntime.signalingJoinRecoveryTask == nil
        default:
            return true
        }
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
            reconciliationAction: String(describing: selectedPeerCoordinator.state.reconciliationAction),
            hadConnectedSessionContinuity: selectedContactId == nil
                ? false
                : selectedPeerCoordinator.state.hadConnectedSessionContinuity,
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
            remoteWakeCapabilityKind: selectedChannelProjection.map {
                switch $0.remoteWakeCapability {
                case .unavailable:
                    return "unavailable"
                case .wakeCapable:
                    return "wake-capable"
                }
            },
            backendCanTransmit: selectedChannelProjection.map(\.canTransmit),
            pttTokenRegistrationKind: pttSystemPolicyCoordinator.state.tokenRegistrationKind,
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
                let listItem = contactListItem(for: contact)
                let relationship = relationshipState(for: contact.id)
                let relationshipDescription: String = switch relationship {
                case .none:
                    "none"
                case .outgoingRequest(let requestCount):
                    "outgoing(requestCount: \(requestCount))"
                case .incomingRequest(let requestCount):
                    "incoming(requestCount: \(requestCount))"
                case .mutualRequest(let requestCount):
                    "mutual(requestCount: \(requestCount))"
                }
                return ContactDiagnosticsSummary(
                    handle: contact.handle,
                    isOnline: summary?.isOnline ?? contact.isOnline,
                    listState: listConversationState(for: contact.id).rawValue,
                    badgeStatus: summary?.badgeKind,
                    listSection: listItem.presentation.section.rawValue,
                    presencePill: listItem.presentation.availabilityPill.rawValue,
                    requestRelationship: relationshipDescription,
                    hasIncomingRequest: relationship.isIncomingRequest,
                    hasOutgoingRequest: relationship.isOutgoingRequest,
                    requestCount: listItem.presentation.requestCount ?? 0,
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
        let directQuic = selectedDirectQuicDiagnosticsSummary
        return [
            "identity": currentDevUserHandle,
            "selectedContact": selectedContact?.handle ?? "none",
            "selectedPeerPhase": selectedSession.selectedPhase,
            "selectedPeerPhaseDetail": selectedSession.selectedPhaseDetail,
            "selectedPeerRelationship": selectedSession.relationship,
            "selectedPeerStatus": selectedSession.statusMessage,
            "selectedPeerCanTransmit": String(selectedSession.canTransmitNow),
            "pendingAction": selectedSession.pendingAction,
            "selectedPeerReconciliationAction": selectedSession.reconciliationAction,
            "selectedPeerAutoJoinEnabled": String(
                conversationShortcutPolicy.requesterAutoJoinOnPeerAcceptance
            ),
            "selectedPeerAutoJoinArmed": String(
                selectedPeerCoordinator.state.requesterAutoJoinOnPeerAcceptanceArmed
            ),
            "hadConnectedSessionContinuity": String(selectedSession.hadConnectedSessionContinuity),
            "backendSignalingJoinRecoveryActive": String(backendRuntime.signalingJoinRecoveryTask != nil),
            "activeChannelId": activeChannelId?.uuidString ?? "none",
            "isJoined": String(isJoined),
            "isTransmitting": String(isTransmitting),
            "isBackendReady": String(backendRuntime.isReady),
            "backendMode": backendRuntime.mode,
            "systemSession": String(describing: systemSessionState),
            "pttClientMode": pttSystemClient.modeDescription,
            "pttTokenRegistration": pttSystemPolicyCoordinator.state.tokenRegistrationDescription,
            "pttTokenRegistrationKind": pttSystemPolicyCoordinator.state.tokenRegistrationKind,
            "pttUploadedBackendChannelId": pttSystemPolicyCoordinator.state.uploadedBackendChannelID ?? "none",
            "pttTokenUploadError": pttSystemPolicyCoordinator.state.lastTokenUploadError ?? "none",
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
            "remoteWakeCapabilityKind": selectedSession.remoteWakeCapabilityKind ?? "unavailable",
            "backendCanTransmit": selectedSession.backendCanTransmit.map(String.init(describing:)) ?? "none",
            "directQuicRelayOnlyOverride": String(directQuic.relayOnlyOverride),
            "directQuicBackendAdvertised": String(directQuic.backendAdvertisesUpgrade),
            "directQuicEnabled": String(directQuic.effectiveUpgradeEnabled),
            "directQuicRole": directQuic.role ?? "none",
            "directQuicIdentityLabel": directQuic.identityLabel ?? "none",
            "directQuicIdentityStatus": directQuic.identityStatus,
            "directQuicInstalledIdentityCount": String(directQuic.installedIdentityCount),
            "directQuicTransportPath": directQuic.transportPathState.rawValue,
            "directQuicLocalDeviceId": directQuic.localDeviceID ?? "none",
            "directQuicPeerDeviceId": directQuic.peerDeviceID ?? "none",
            "directQuicAttemptId": directQuic.attemptID ?? "none",
            "directQuicChannelId": directQuic.channelID ?? "none",
            "directQuicIsActive": String(directQuic.isDirectActive),
            "directQuicRemoteCandidateCount": String(directQuic.remoteCandidateCount),
            "directQuicRemoteEndOfCandidates": String(directQuic.remoteEndOfCandidates),
            "directQuicNominatedPathSource": directQuic.nominatedPathSource ?? "none",
            "directQuicNominatedRemoteAddress": directQuic.nominatedRemoteAddress ?? "none",
            "directQuicNominatedRemotePort": directQuic.nominatedRemotePort.map(String.init) ?? "none",
            "directQuicNominatedRemoteCandidateKind": directQuic.nominatedRemoteCandidateKind ?? "none",
            "directQuicRetryReason": directQuic.retryReason ?? "none",
            "directQuicRetryCategory": directQuic.retryCategory ?? "none",
            "directQuicRetryAttemptId": directQuic.retryAttemptID ?? "none",
            "directQuicRetryRemainingMs": directQuic.retryRemainingMilliseconds.map(String.init) ?? "none",
            "directQuicRetryBackoffMs": directQuic.retryBackoffMilliseconds.map(String.init) ?? "none",
            "directQuicStunServerCount": String(directQuic.stunServerCount),
            "directQuicPromotionTimeoutMs": String(directQuic.promotionTimeoutMilliseconds),
            "directQuicRetryBackoffBaseMs": String(directQuic.retryBackoffBaseMilliseconds),
            "directQuicProbeControllerReady": String(directQuic.probeControllerReady),
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
                "contact[\(summary.handle)].listSection=\(summary.listSection)",
                "contact[\(summary.handle)].presencePill=\(summary.presencePill)",
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
            await self?.handleApplicationDidBecomeActive()
        }
    }

    func handleApplicationDidBecomeActive() async {
        backendServices?.resumeWebSocket()
        clearTalkRequestNotifications()
        reconcileTalkRequestSurface(applicationState: .active)
        await resumeBufferedWakePlaybackIfNeeded(
            reason: "application-became-active",
            applicationState: .active
        )
        await resumeInteractiveAudioPrewarmIfNeeded(
            reason: "application-became-active",
            applicationState: .active
        )
        await backendSyncCoordinator.handle(.pollRequested(selectedContactID: selectedContactId))
    }

    func handleApplicationDidEnterBackground() async {
        let shouldPreserveJoinedSession =
            shouldMaintainBackgroundControlPlane(applicationState: .background)

        if let backgroundWebSocketSuspendHandler {
            backgroundWebSocketSuspendHandler()
        } else {
            backendServices?.suspendWebSocket()
        }

        if shouldPreserveJoinedSession {
            guard backgroundSessionPresenceHandler != nil || backendServices != nil else { return }
            await performProtectedBackgroundHandoff(named: "background-presence") { [weak self] in
                guard let self else { return }
                if let backgroundSessionPresenceHandler {
                    await backgroundSessionPresenceHandler()
                    return
                }
                guard let backend = backendServices else { return }
                do {
                    _ = try await backend.backgroundPresence()
                } catch {
                    diagnostics.record(
                        .backend,
                        level: .error,
                        message: "Background presence publish failed",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
            return
        }

        guard backgroundOfflinePresenceHandler != nil || backendServices != nil else { return }
        await performProtectedBackgroundHandoff(named: "offline-presence") { [weak self] in
            guard let self else { return }
            if let backgroundOfflinePresenceHandler {
                await backgroundOfflinePresenceHandler()
                return
            }
            guard let backend = backendServices else { return }
            do {
                _ = try await backend.offlinePresence()
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Offline presence publish failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
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
            await self.handleApplicationDidEnterBackground()
        }
    }
}
