//
//  PTTViewModel+PTTActions.swift
//  Turbo
//
//  Created by Codex on 08.04.2026.
//

import Foundation
import PushToTalk
import UIKit

extension PTTViewModel {
    func desiredPTTServiceStatus() -> PTServiceStatus? {
        guard pttCoordinator.state.systemChannelUUID != nil else { return nil }

        if usesLocalHTTPBackend {
            return .ready
        }

        guard backendRuntime.isReady else {
            return .unavailable
        }

        if currentApplicationState() != .active {
            return .ready
        }

        return backendRuntime.isWebSocketConnected ? .ready : .connecting
    }

    func systemDescriptorName(for channelUUID: UUID) -> String {
        PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: channelUUID,
            contacts: contacts,
            fallbackName: channelName
        )
    }

    func syncPTTSystemChannelDescriptor(_ channelUUID: UUID, reason: String) {
        let descriptorName = systemDescriptorName(for: channelUUID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pttSystemClient.updateChannelDescriptor(name: descriptorName, channelUUID: channelUUID)
                lastReportedPTTDescriptorName = descriptorName
                lastReportedPTTDescriptorChannelUUID = channelUUID
                lastReportedPTTDescriptorReason = reason
                diagnostics.record(
                    .pushToTalk,
                    message: "Updated PTT channel descriptor",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "name": descriptorName,
                        "reason": reason,
                    ]
                )
            } catch {
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Failed to update PTT channel descriptor",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "name": descriptorName,
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func syncPTTServiceStatus(reason: String) {
        guard let channelUUID = pttCoordinator.state.systemChannelUUID else {
            lastReportedPTTServiceStatus = nil
            lastReportedPTTServiceStatusChannelUUID = nil
            return
        }

        guard let status = desiredPTTServiceStatus() else {
            lastReportedPTTServiceStatus = nil
            lastReportedPTTServiceStatusChannelUUID = nil
            return
        }

        guard lastReportedPTTServiceStatus != status
            || lastReportedPTTServiceStatusChannelUUID != channelUUID else {
            return
        }

        lastReportedPTTServiceStatus = status
        lastReportedPTTServiceStatusChannelUUID = channelUUID
        lastReportedPTTServiceStatusReason = reason

        Task { [weak self] in
            guard let self else { return }
            do {
                try await pttSystemClient.setServiceStatus(status, channelUUID: channelUUID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Updated PTT service status",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "status": String(describing: status),
                        "reason": reason,
                    ]
                )
            } catch {
                if lastReportedPTTServiceStatusChannelUUID == channelUUID {
                    lastReportedPTTServiceStatus = nil
                    lastReportedPTTServiceStatusChannelUUID = nil
                    lastReportedPTTServiceStatusReason = nil
                }
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Failed to update PTT service status",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "status": String(describing: status),
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func syncPTTTransmissionMode(reason: String) {
        guard let channelUUID = pttCoordinator.state.systemChannelUUID else {
            lastReportedPTTTransmissionMode = nil
            lastReportedPTTTransmissionModeChannelUUID = nil
            lastReportedPTTTransmissionModeReason = nil
            return
        }

        let mode = PTTransmissionMode.halfDuplex
        guard lastReportedPTTTransmissionMode != mode
            || lastReportedPTTTransmissionModeChannelUUID != channelUUID else {
            return
        }

        lastReportedPTTTransmissionMode = mode
        lastReportedPTTTransmissionModeChannelUUID = channelUUID
        lastReportedPTTTransmissionModeReason = reason

        Task { [weak self] in
            guard let self else { return }
            do {
                try await pttSystemClient.setTransmissionMode(mode, channelUUID: channelUUID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Updated PTT transmission mode",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "mode": String(describing: mode),
                        "reason": reason,
                        "applicationState": String(describing: UIApplication.shared.applicationState),
                    ]
                )
            } catch {
                if lastReportedPTTTransmissionModeChannelUUID == channelUUID {
                    lastReportedPTTTransmissionMode = nil
                    lastReportedPTTTransmissionModeChannelUUID = nil
                    lastReportedPTTTransmissionModeReason = nil
                }
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Failed to update PTT transmission mode",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "mode": String(describing: mode),
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func syncPTTAccessoryButtonEvents(reason: String) {
        guard let channelUUID = pttCoordinator.state.systemChannelUUID else {
            lastReportedPTTAccessoryButtonEventsChannelUUID = nil
            lastReportedPTTAccessoryButtonEventsReason = nil
            return
        }

        guard lastReportedPTTAccessoryButtonEventsChannelUUID != channelUUID else {
            return
        }

        lastReportedPTTAccessoryButtonEventsChannelUUID = channelUUID
        lastReportedPTTAccessoryButtonEventsReason = reason

        Task { [weak self] in
            guard let self else { return }
            do {
                try await pttSystemClient.setAccessoryButtonEventsEnabled(true, channelUUID: channelUUID)
                diagnostics.record(
                    .pushToTalk,
                    message: "Enabled PTT accessory button events",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                    ]
                )
            } catch {
                if lastReportedPTTAccessoryButtonEventsChannelUUID == channelUUID {
                    lastReportedPTTAccessoryButtonEventsChannelUUID = nil
                    lastReportedPTTAccessoryButtonEventsReason = nil
                }
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Failed to enable PTT accessory button events",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    func setSystemActiveRemoteParticipant(
        name: String?,
        channelUUID: UUID,
        contactID: UUID?,
        reason: String
    ) async throws {
        let startedAt = Date()
        if let contactID, name != nil {
            recordWakeReceiveTiming(
                stage: "active-remote-participant-requested",
                contactID: contactID,
                channelUUID: channelUUID,
                subsystem: .pushToTalk,
                metadata: [
                    "participant": name ?? "none",
                    "reason": reason,
                ],
                ifAbsent: true
            )
        }
        diagnostics.record(
            .pushToTalk,
            message: name == nil
                ? "Requesting active remote participant clear"
                : "Requesting active remote participant set",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactId": contactID?.uuidString ?? "none",
                "participant": name ?? "none",
                "reason": reason,
                "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                "pttTransmissionModeReason": lastReportedPTTTransmissionModeReason ?? "none",
                "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                "applicationState": String(describing: UIApplication.shared.applicationState),
            ]
        )

        do {
            try await pttSystemClient.setActiveRemoteParticipant(name: name, channelUUID: channelUUID)
            if let contactID, name != nil {
                recordWakeReceiveTiming(
                    stage: "active-remote-participant-completed",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    subsystem: .pushToTalk,
                    metadata: [
                        "participant": name ?? "none",
                        "reason": reason,
                        "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    ],
                    ifAbsent: true
                )
            }
            diagnostics.record(
                .pushToTalk,
                message: name == nil
                    ? "Completed active remote participant clear"
                    : "Completed active remote participant set",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactId": contactID?.uuidString ?? "none",
                    "participant": name ?? "none",
                    "reason": reason,
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                ]
            )
        } catch {
            if name == nil && isExpectedPTTRemoteParticipantClearFailure(error) {
                diagnostics.record(
                    .pushToTalk,
                    message: "Active remote participant clear found no active participant",
                    metadata: [
                        "channelUUID": channelUUID.uuidString,
                        "contactId": contactID?.uuidString ?? "none",
                        "participant": "none",
                        "reason": reason,
                        "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                        "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                        "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                        "error": error.localizedDescription,
                    ]
                )
                throw error
            }
            if let contactID, name != nil {
                recordWakeReceiveTiming(
                    stage: "active-remote-participant-failed",
                    contactID: contactID,
                    channelUUID: channelUUID,
                    subsystem: .pushToTalk,
                    metadata: [
                        "participant": name ?? "none",
                        "reason": reason,
                        "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                        "error": error.localizedDescription,
                    ]
                )
            }
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: name == nil
                    ? "Active remote participant clear failed"
                    : "Active remote participant set failed",
                metadata: [
                    "channelUUID": channelUUID.uuidString,
                    "contactId": contactID?.uuidString ?? "none",
                    "participant": name ?? "none",
                    "reason": reason,
                    "durationMs": String(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "pttTransmissionMode": lastReportedPTTTransmissionMode.map(String.init(describing:)) ?? "none",
                    "isPTTAudioSessionActive": String(isPTTAudioSessionActive),
                    "error": error.localizedDescription,
                ]
            )
            throw error
        }
    }

    private func performReconciledTeardown(for contactID: UUID) {
        let backendChannelID = contacts.first { $0.id == contactID }?.backendChannelId
        scheduleDisconnectRecovery(
            contactID: contactID,
            channelUUID: pttCoordinator.state.systemChannelUUID ?? channelUUID(for: contactID),
            backendChannelID: backendChannelID
        )
        if selectedContactId == contactID {
            clearRemoteAudioActivity(for: contactID)
        }
        resetTransmitRuntimeOnly()
        closeMediaSession()
        diagnostics.record(
            .channel,
            message: "Ending local session after peer departure",
            metadata: ["contactId": contactID.uuidString]
        )
        captureDiagnosticsState("session-teardown:start")

        if usesLocalHTTPBackend {
            Task {
                if let contact = contacts.first(where: { $0.id == contactID }),
                   let backendChannelId = contact.backendChannelId {
                    let request = BackendLeaveRequest(contactID: contact.id, backendChannelID: backendChannelId)
                    await backendCommandCoordinator.handle(.leaveRequested(request))
                }
                pttCoordinator.reset()
                syncPTTState()
                resetTransmitSession(closeMediaSession: false)
                sessionCoordinator.clearLeaveAction(for: contactID)
                updateStatusForSelectedContact()
                statusMessage = "Disconnected"
                captureDiagnosticsState("session-teardown:local-finished")
            }
            return
        }

        guard let systemChannelUUID = pttCoordinator.state.systemChannelUUID else {
            pttCoordinator.reset()
            syncPTTState()
            resetTransmitSession(closeMediaSession: false)
            sessionCoordinator.clearLeaveAction(for: contactID)
            replaceDisconnectRecoveryTask(with: nil)
            updateStatusForSelectedContact()
            captureDiagnosticsState("session-teardown:local-reset")
            return
        }

        if isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: systemChannelUUID)
        }
        try? pttSystemClient.leaveChannel(channelUUID: systemChannelUUID)
        statusMessage = "Peer disconnected"
        captureDiagnosticsState("session-teardown:ptt-leave-requested")
    }

    func initializeIfNeeded() async {
        guard !pttSystemClient.isReady else { return }
        refreshMicrophonePermission()
        diagnostics.record(.app, message: "Initializing app")
        captureDiagnosticsState("app-initialize:start")

        do {
            try await pttSystemClient.configure(callbacks: pttSystemCallbacks)
            isReady = true
            diagnostics.record(.pushToTalk, message: "PTT channel manager ready")
            captureDiagnosticsState("app-initialize:ptt-ready")
        } catch {
            statusMessage = "Failed to init: \(error.localizedDescription)"
            diagnostics.record(.pushToTalk, level: .error, message: "PTT init failed", metadata: ["error": error.localizedDescription])
            captureDiagnosticsState("app-initialize:ptt-failed")
            return
        }

        await configureBackendIfNeeded()
        if backendRuntime.isReady, selectedContact == nil {
            statusMessage = "Ready to connect"
        }
    }

    func endSystemSession() {
        guard let activeSystemChannelUUID = pttCoordinator.state.systemChannelUUID else { return }
        sessionCoordinator.markExplicitLeave(contactID: selectedContactId)
        if let selectedContactId {
            clearRemoteAudioActivity(for: selectedContactId)
        }
        diagnostics.record(.channel, message: "Ending system session", metadata: ["channelUUID": activeSystemChannelUUID.uuidString])

        if let contactID = contactId(for: activeSystemChannelUUID),
           let contact = contacts.first(where: { $0.id == contactID }),
           let backendChannelId = contact.backendChannelId {
            Task {
                let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelId)
                await backendCommandCoordinator.handle(.leaveRequested(request))
            }
        }

        try? pttSystemClient.leaveChannel(channelUUID: activeSystemChannelUUID)
        pttCoordinator.reset()
        syncPTTState()
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        updateStatusForSelectedContact()
        captureDiagnosticsState("system-session:end")
    }

    func joinChannel() {
        guard selectedContact != nil else {
            statusMessage = "Pick a contact"
            return
        }
        Task {
            await requestJoinSelectedPeer()
        }
    }

    func disconnect() {
        Task {
            await requestDisconnectSelectedPeer()
        }
    }

    func performDisconnect() {
        let disconnectContactID = selectedContactId
        let disconnectChannelUUID = activeChannelId.flatMap { channelUUID(for: $0) }
        let disconnectBackendChannelID = selectedContact?.backendChannelId
        sessionCoordinator.markExplicitLeave(contactID: disconnectContactID)
        scheduleDisconnectRecovery(
            contactID: disconnectContactID,
            channelUUID: disconnectChannelUUID,
            backendChannelID: disconnectBackendChannelID
        )
        if let disconnectContactID {
            clearRemoteAudioActivity(for: disconnectContactID)
        }
        resetTransmitRuntimeOnly()
        closeMediaSession()
        diagnostics.record(.channel, message: "Disconnect requested", metadata: ["selectedContactId": disconnectContactID?.uuidString ?? "none"])
        captureDiagnosticsState("session-disconnect:start")
        if usesLocalHTTPBackend {
            Task {
                if let contact = selectedContact,
                   let backendChannelId = contact.backendChannelId {
                    let request = BackendLeaveRequest(contactID: contact.id, backendChannelID: backendChannelId)
                    await backendCommandCoordinator.handle(.leaveRequested(request))
                }
                pttCoordinator.reset()
                syncPTTState()
                resetTransmitSession(closeMediaSession: false)
                sessionCoordinator.clearLeaveAction(for: disconnectContactID)
                replaceDisconnectRecoveryTask(with: nil)
                updateStatusForSelectedContact()
                statusMessage = "Disconnected"
                captureDiagnosticsState("session-disconnect:local-finished")
            }
            return
        }

        guard let activeChannelId,
              let channelUUID = channelUUID(for: activeChannelId) else {
            statusMessage = "Disconnected"
            isJoined = false
            sessionCoordinator.clearLeaveAction(for: disconnectContactID)
            replaceDisconnectRecoveryTask(with: nil)
            captureDiagnosticsState("session-disconnect:no-active-channel")
            return
        }

        if isTransmitting {
            try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
        }
        try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        statusMessage = "Disconnecting..."
        captureDiagnosticsState("session-disconnect:ptt-leave-requested")
    }

    private func scheduleDisconnectRecovery(
        contactID: UUID?,
        channelUUID: UUID?,
        backendChannelID: String?
    ) {
        guard let contactID else { return }
        let delayNanoseconds = disconnectRecoveryDelayNanoseconds
        replaceDisconnectRecoveryTask(with: Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            guard self.sessionCoordinator.pendingAction.isLeaveInFlight(for: contactID) else { return }

            let selectedState = self.selectedPeerState(for: contactID)
            self.diagnostics.recordInvariantViolation(
                invariantID: "selected.disconnecting_timeout",
                scope: .local,
                message: "selected peer remained disconnecting after pending leave timeout",
                metadata: [
                    "contactId": contactID.uuidString,
                    "selectedPeerPhase": String(describing: selectedState.phase),
                    "selectedPeerPhaseDetail": String(describing: selectedState.detail),
                    "pendingAction": String(describing: self.sessionCoordinator.pendingAction),
                    "systemSession": String(describing: self.systemSessionState),
                    "backendChannelId": backendChannelID ?? "none",
                ]
            )
            self.diagnostics.record(
                .state,
                message: "Recovering stuck disconnect",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelUUID": channelUUID?.uuidString ?? "none",
                    "backendChannelId": backendChannelID ?? "none",
                ]
            )

            if let retryChannelUUID = channelUUID ?? self.channelUUID(for: contactID) {
                try? self.pttSystemClient.leaveChannel(channelUUID: retryChannelUUID)
            }
            self.tearDownTransmitRuntime(resetCoordinator: true)
            self.closeMediaSession()
            self.pttCoordinator.reset()
            self.syncPTTState()
            self.sessionCoordinator.clearLeaveAction(for: contactID)
            self.backendSyncCoordinator.send(.channelStateCleared(contactID: contactID))
            self.updateStatusForSelectedContact()
            self.captureDiagnosticsState("session-disconnect:self-healed")

            if let backendChannelID {
                let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelID)
                await self.backendCommandCoordinator.handle(.leaveRequested(request))
            } else {
                await self.refreshChannelState(for: contactID)
                await self.refreshContactSummaries()
            }
        })
    }

    func performConnect(to contact: Contact, intent: BackendJoinIntent) {
        let connectOrigin: PendingConnectOrigin =
            relationshipState(for: contact.id).isIncomingRequest ? .acceptingIncomingRequest : .neutral

        if usesLocalHTTPBackend {
            if isJoined, activeChannelId == contact.id {
                return
            }
            sessionCoordinator.queueConnect(contactID: contact.id, origin: connectOrigin)
            captureDiagnosticsState("session-connect:queued-local")
            requestBackendJoin(for: contact, intent: intent)
            return
        }

        if isJoined, activeChannelId == contact.id {
            return
        }

        sessionCoordinator.queueConnect(contactID: contact.id, origin: connectOrigin)
        captureDiagnosticsState("session-connect:queued")

        if isJoined, let activeChannelId, let channelUUID = channelUUID(for: activeChannelId) {
            if isTransmitting {
                try? pttSystemClient.stopTransmitting(channelUUID: channelUUID)
            }
            try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
            statusMessage = "Connecting..."
            captureDiagnosticsState("session-connect:switching-channel")
        } else {
            requestBackendJoin(for: contact, intent: intent)
        }
    }

    func requestJoinSelectedPeer() async {
        syncSelectedPeerSession()
        captureDiagnosticsState("selected-peer:join-requested")
        await selectedPeerCoordinator.handle(.joinRequested)
    }

    func requestDisconnectSelectedPeer() async {
        syncSelectedPeerSession()
        captureDiagnosticsState("selected-peer:disconnect-requested")
        await selectedPeerCoordinator.handle(.disconnectRequested)
    }

    func reconcileSelectedSessionIfNeeded() async {
        guard selectedContact != nil else { return }
        syncSelectedPeerSession()
        await selectedPeerCoordinator.handle(.reconcileRequested)
    }

    func runSelectedPeerEffect(_ effect: SelectedPeerEffect) async {
        switch effect {
        case .requestConnection(let contactID):
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            captureDiagnosticsState("selected-peer-effect:request-connection")
            performConnect(to: contact, intent: .requestConnection)
        case .joinReadyPeer(let contactID):
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            captureDiagnosticsState("selected-peer-effect:join-ready-peer")
            performConnect(to: contact, intent: .joinReadyPeer)
        case .disconnect:
            captureDiagnosticsState("selected-peer-effect:disconnect")
            performDisconnect()
        case .restoreLocalSession(let contactID):
            guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
            diagnostics.record(
                .state,
                message: "Restoring local session to match backend-ready channel",
                metadata: ["contactId": contactID.uuidString, "handle": contact.handle]
            )
            captureDiagnosticsState("selected-peer-effect:restore-local")
            joinPTTChannel(for: contact)
        case .teardownLocalSession(let contactID):
            guard selectedContactId == contactID else { return }
            sessionCoordinator.markReconciledTeardown(contactID: contactID)
            diagnostics.record(
                .state,
                message: "Tearing down invalid local session after system mismatch",
                metadata: ["contactId": contactID.uuidString]
            )
            captureDiagnosticsState("selected-peer-effect:teardown-local")
            performReconciledTeardown(for: contactID)
        case .clearStaleBackendMembership(let contactID):
            guard selectedContactId == contactID,
                  let contact = contacts.first(where: { $0.id == contactID }),
                  let backendChannelId = contact.backendChannelId else { return }
            sessionCoordinator.markReconciledTeardown(contactID: contactID)
            diagnostics.record(
                .state,
                message: "Clearing stale backend membership without local session evidence",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": backendChannelId,
                ]
            )
            captureDiagnosticsState("selected-peer-effect:clear-stale-backend-membership")
            let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelId)
            await backendCommandCoordinator.handle(.leaveRequested(request))
            sessionCoordinator.clearLeaveAction(for: contactID)
            updateStatusForSelectedContact()
        }
    }

    func runPTTEffect(_ effect: PTTEffect) async {
        switch effect {
        case .syncJoinedChannel(let contactID):
            if let contactID {
                await refreshChannelState(for: contactID)
                await refreshContactSummaries()
                if let backendChannelID = contacts.first(where: { $0.id == contactID })?.backendChannelId {
                    await pttSystemPolicyCoordinator.handle(.backendChannelReady(backendChannelID))
                    syncPTTSystemPolicyState()
                }
            } else {
                updateStatusForSelectedContact()
            }
        case .syncLeftChannel(let contactID, let autoRejoinContactID):
            tearDownTransmitRuntime(resetCoordinator: true)
            closeMediaSession()
            let shouldPropagateBackendLeave =
                autoRejoinContactID != nil
                || (contactID.map { sessionCoordinator.pendingAction.isLeaveInFlight(for: $0) } ?? false)

            if shouldPropagateBackendLeave,
               let contactID,
               let contact = contacts.first(where: { $0.id == contactID }),
               let backendChannelId = contact.backendChannelId {
                let request = BackendLeaveRequest(contactID: contactID, backendChannelID: backendChannelId)
                await backendCommandCoordinator.handle(.leaveRequested(request))
            } else if let contactID {
                await refreshChannelState(for: contactID)
                await refreshContactSummaries()
            }
            if let autoRejoinContactID,
               let contact = contacts.first(where: { $0.id == autoRejoinContactID }) {
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    requestBackendJoin(for: contact)
                }
            } else if shouldPropagateBackendLeave {
                backendSyncCoordinator.send(.clearAllChannelStates)
            }
            updateStatusForSelectedContact()
        case .closeMediaSession:
            closeMediaSession()
        case .handleSystemTransmitFailure(let message):
            await transmitCoordinator.handle(.systemBeginFailed(message))
            syncTransmitState()
        }
    }

    func joinPTTChannel(for contact: Contact) {
        guard pttSystemClient.isReady else {
            statusMessage = "Not ready"
            captureDiagnosticsState("ptt-join:not-ready")
            return
        }

        guard !sessionCoordinator.pendingAction.isLeaveInFlight(for: contact.id) else {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored local PTT join while explicit leave is in flight",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "channelUUID": contact.channelId.uuidString,
                    "pendingAction": String(describing: sessionCoordinator.pendingAction),
                ]
            )
            statusMessage = "Disconnecting..."
            captureDiagnosticsState("ptt-join:blocked-by-leave")
            return
        }

        let stalePendingJoinWithoutLocalSessionEvidence =
            sessionCoordinator.pendingJoinContactID == contact.id
            && !systemSessionMatches(contact.id)
            && !(isJoined && activeChannelId == contact.id)
            && pttCoordinator.state.systemChannelUUID == nil

        if sessionCoordinator.pendingJoinContactID == contact.id,
           !stalePendingJoinWithoutLocalSessionEvidence {
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:dedup-pending")
            return
        }

        if stalePendingJoinWithoutLocalSessionEvidence {
            diagnostics.record(
                .pushToTalk,
                message: "Retrying stale pending local join",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "channelUUID": contact.channelId.uuidString,
                ]
            )
            // Preserve the pending local-join projection while we retry so the
            // selected UI cannot briefly fall back to peerReady/connectable.
            captureDiagnosticsState("ptt-join:retry-stale-pending")
        }

        let localSessionAlreadyActive =
            systemSessionMatches(contact.id)
            || (isJoined && activeChannelId == contact.id)
            || pttCoordinator.state.systemChannelUUID == contact.channelId
        if localSessionAlreadyActive {
            sessionCoordinator.clearPendingJoin(for: contact.id)
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:dedup-active")
            return
        }

        sessionCoordinator.queueJoin(contactID: contact.id)
        do {
            try pttSystemClient.joinChannel(channelUUID: contact.channelId, name: "Chat with \(contact.name)")
            statusMessage = "Connecting..."
            captureDiagnosticsState("ptt-join:requested")
        } catch {
            sessionCoordinator.clearPendingJoin(for: contact.id)
            statusMessage = error.localizedDescription
            captureDiagnosticsState("ptt-join:failed-immediate")
        }
    }

    func channelUUID(for contactId: UUID) -> UUID? {
        contacts.first { $0.id == contactId }?.channelId
    }

    func contactId(for channelUUID: UUID) -> UUID? {
        contacts.first { $0.channelId == channelUUID }?.id
    }

    func formatPTTError(_ error: Error) -> String {
        if let channelError = error as? PTChannelError {
            return String(describing: channelError.code)
        }

        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code))"
    }

    func isExpectedPTTStopFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain && nsError.code == 5 {
            return true
        }

        if let channelError = error as? PTChannelError {
            return channelError.code.rawValue == 5
        }

        return false
    }

    func isExpectedPTTRemoteParticipantClearFailure(_ error: Error) -> Bool {
        isExpectedPTTStopFailure(error)
    }

    func isRecoverablePTTChannelUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain && nsError.code == 1 {
            return true
        }

        if let channelError = error as? PTChannelError {
            return channelError.code.rawValue == 1
        }

        return false
    }

    func isRecoverablePTTTransmissionInProgress(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain && nsError.code == 4 {
            return true
        }

        if let channelError = error as? PTChannelError {
            return channelError.code.rawValue == 4
        }

        return false
    }

    func recoverStaleSystemChannel(for channelUUID: UUID, contactID: UUID, reason: String) {
        diagnostics.record(
            .pushToTalk,
            message: "Recovering stale system channel",
            metadata: [
                "channelUUID": channelUUID.uuidString,
                "contactID": contactID.uuidString,
                "reason": reason
            ]
        )
        tearDownTransmitRuntime(resetCoordinator: true)
        closeMediaSession()
        try? pttSystemClient.leaveChannel(channelUUID: channelUUID)
        pttCoordinator.reset()
        syncPTTState()
        sessionCoordinator.clearPendingJoin(for: contactID)
        statusMessage = "Reconnecting..."
        updateStatusForSelectedContact()
        captureDiagnosticsState("ptt-recover-stale-channel")

        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.joinPTTChannel(for: contact)
        }
    }

    func classifyPTTJoinFailure(_ error: Error) -> PTTJoinFailureReason {
        let nsError = error as NSError
        if nsError.domain == PTChannelErrorDomain, nsError.code == 2 {
            return .channelLimitReached
        }
        return .other(message: formatPTTError(error))
    }
}
