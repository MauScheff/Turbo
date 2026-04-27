import Foundation

extension PTTViewModel {
    private var defaultDirectQuicPromotionTimeoutMilliseconds: Int { 2_500 }
    private var defaultDirectQuicRetryBackoffMilliseconds: Int { 15_000 }

    func directQuicAttemptRole(
        localDeviceID: String,
        peerDeviceID: String
    ) -> DirectQuicAttemptRole {
        DirectQuicAttemptRole.resolve(
            localDeviceID: localDeviceID,
            peerDeviceID: peerDeviceID
        )
    }

    func directQuicPeerDeviceID(
        for contactID: UUID,
        fallback: String? = nil
    ) -> String? {
        channelReadinessByContactID[contactID]?.peerTargetDeviceId
            ?? fallback
    }

    func shouldUseDirectQuicTransport(for contactID: UUID) -> Bool {
        guard mediaRuntime.directQuicProbeController != nil else { return false }
        return mediaRuntime.directQuicUpgrade.attempt(for: contactID)?.isDirectActive == true
    }

    func directQuicAttempt(
        for contactID: UUID,
        matching attemptID: String? = nil
    ) -> DirectQuicUpgradeAttempt? {
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            return nil
        }
        guard let attemptID else { return attempt }
        return attempt.attemptId == attemptID ? attempt : nil
    }

    func directQuicExpectedPeerCertificateFingerprint(
        for attempt: DirectQuicUpgradeAttempt
    ) -> String? {
        if let answerFingerprint = attempt.remoteAnswer?.certificateFingerprint,
           !answerFingerprint.isEmpty {
            return answerFingerprint
        }
        if let offerFingerprint = attempt.remoteOffer?.certificateFingerprint,
           !offerFingerprint.isEmpty {
            return offerFingerprint
        }
        return nil
    }

    func directQuicCandidateBatchToProbe(
        for attempt: DirectQuicUpgradeAttempt,
        payload: TurboDirectQuicCandidatePayload
    ) -> [TurboDirectQuicCandidate] {
        if let candidate = payload.candidate {
            return [candidate]
        }
        if payload.endOfCandidates {
            return attempt.remoteCandidates
        }
        return []
    }

    func directQuicProbeController() -> DirectQuicProbeController {
        if let existing = mediaRuntime.directQuicProbeController {
            return existing
        }
        let controller = DirectQuicProbeController(
            reportEvent: { [weak self] message, metadata in
                guard let self else { return }
                await MainActor.run {
                    self.diagnostics.record(.media, message: message, metadata: metadata)
                }
            }
        )
        mediaRuntime.directQuicProbeController = controller
        return controller
    }

    func directQuicPromotionTimeoutMilliseconds() -> Int {
        let configured = backendServices?.directQuicPolicy?.promotionTimeoutMs
            ?? defaultDirectQuicPromotionTimeoutMilliseconds
        return max(configured, 250)
    }

    func directQuicRetryBackoffMilliseconds() -> Int {
        let configured = backendServices?.directQuicPolicy?.retryBackoffMs
            ?? defaultDirectQuicRetryBackoffMilliseconds
        return max(configured, 0)
    }

    func directQuicRetryBackoffRequest(
        reason: String,
        attemptID: String? = nil
    ) -> DirectQuicRetryBackoffRequest? {
        let baseMilliseconds = directQuicRetryBackoffMilliseconds()
        let resolvedMilliseconds = DirectQuicRetryBackoffPolicy.milliseconds(
            baseMilliseconds: baseMilliseconds,
            reason: reason
        )
        guard resolvedMilliseconds > 0 else { return nil }
        return DirectQuicRetryBackoffRequest(
            milliseconds: resolvedMilliseconds,
            reason: reason,
            category: DirectQuicRetryBackoffPolicy.category(for: reason),
            attemptId: attemptID
        )
    }

    func directQuicStunServers() -> [TurboDirectQuicStunServer] {
        backendServices?.directQuicPolicy?.stunServers ?? []
    }

    func preferredDirectQuicIdentityLabel() -> String {
        DirectQuicIdentityConfiguration.preferredLabel(
            deviceID: backendServices?.deviceID,
            fallbackHandle: currentIdentityHandle
        )
    }

    func cancelDirectQuicPromotionTimeout() {
        mediaRuntime.replaceDirectQuicPromotionTimeoutTask(with: nil)
    }

    func importDirectQuicIdentityForDebug(
        from fileURL: URL,
        password: String
    ) async {
        let resolvedLabel = preferredDirectQuicIdentityLabel()
        let didAccessSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let pkcs12Data = try Data(contentsOf: fileURL)
            try DirectQuicIdentityConfiguration.importPKCS12Identity(
                data: pkcs12Data,
                password: password,
                label: resolvedLabel
            )
            DirectQuicIdentityConfiguration.setResolvedLabel(resolvedLabel)
            diagnostics.record(
                .media,
                message: "Direct QUIC identity imported from diagnostics",
                metadata: [
                    "file": fileURL.lastPathComponent,
                    "label": resolvedLabel,
                    "selectedContact": selectedContact?.handle ?? "none",
                ]
            )
            statusMessage = "Direct QUIC identity imported"
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC identity import failed",
                metadata: [
                    "file": fileURL.lastPathComponent,
                    "label": resolvedLabel,
                    "error": error.localizedDescription,
                ]
            )
            statusMessage = error.localizedDescription
        }

        captureDiagnosticsState("direct-quic:identity-import")
    }

    func adoptInstalledDirectQuicIdentityForDebug() {
        let resolvedLabel = preferredDirectQuicIdentityLabel()

        do {
            let fingerprint = try DirectQuicIdentityConfiguration.adoptInstalledIdentity(
                label: resolvedLabel
            )
            diagnostics.record(
                .media,
                message: "Direct QUIC installed identity adopted from diagnostics",
                metadata: [
                    "label": resolvedLabel,
                    "fingerprint": fingerprint,
                    "installedIdentityCount": String(
                        DirectQuicIdentityConfiguration.installedIdentityCount()
                    ),
                ]
            )
            statusMessage = "Direct QUIC installed identity adopted"
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC installed identity adoption failed",
                metadata: [
                    "label": resolvedLabel,
                    "error": error.localizedDescription,
                    "installedIdentityCount": String(
                        DirectQuicIdentityConfiguration.installedIdentityCount()
                    ),
                ]
            )
            statusMessage = error.localizedDescription
        }

        captureDiagnosticsState("direct-quic:identity-adopt-installed")
    }

    func setDirectPathRelayOnlyForcedForDebug(_ isForced: Bool) async {
        let previousValue = isDirectPathRelayOnlyForced
        TurboDirectPathDebugOverride.setRelayOnlyForced(isForced)

        diagnostics.record(
            .media,
            message: "Direct QUIC relay-only override updated from diagnostics",
            metadata: [
                "selectedContact": selectedContact?.handle ?? "none",
                "previousValue": String(previousValue),
                "newValue": String(isForced),
            ]
        )

        if isForced {
            await cancelSelectedDirectQuicAttemptForDebug(reason: "debug-force-relay-only")
        }

        statusMessage = isForced
            ? "Direct path upgrade disabled for debugging"
            : "Direct path upgrade enabled"
        captureDiagnosticsState("direct-quic:debug-relay-only")
    }

    func forceSelectedDirectQuicProbeForDebug() async {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC debug probe skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-force-probe:no-selection")
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC debug probe requested",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "relayOnlyOverride": String(isDirectPathRelayOnlyForced),
                "backendAdvertised": String(backendAdvertisesDirectQuicUpgrade),
                "directQuicEnabled": String(effectiveDirectQuicUpgradeEnabled),
                "existingAttempt": String(
                    mediaRuntime.directQuicUpgrade.attempt(for: selectedContact.id) != nil
                ),
            ]
        )
        captureDiagnosticsState("direct-quic:debug-force-probe:requested")
        await maybeStartDirectQuicProbe(
            for: selectedContact.id,
            allowDebugBypassWithoutBackendAdvertisement: true
        )
        captureDiagnosticsState("direct-quic:debug-force-probe:completed")
    }

    func clearSelectedDirectQuicRetryBackoffForDebug() {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC retry backoff clear skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-clear-backoff:no-selection")
            return
        }

        let previousBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: selectedContact.id)
        mediaRuntime.directQuicUpgrade.clearRetryBackoff(for: selectedContact.id)
        diagnostics.record(
            .media,
            message: previousBackoff == nil
                ? "Direct QUIC retry backoff was already clear"
                : "Direct QUIC retry backoff cleared from diagnostics",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "previousReason": previousBackoff?.reason ?? "none",
                "previousCategory": previousBackoff?.category.rawValue ?? "none",
                "previousAttemptId": previousBackoff?.attemptId ?? "none",
                "previousBackoffMs": previousBackoff.map { String($0.milliseconds) } ?? "none",
            ]
        )
        captureDiagnosticsState("direct-quic:debug-clear-backoff")
    }

    func cancelSelectedDirectQuicAttemptForDebug(
        reason: String = "debug-cancel"
    ) async {
        guard let selectedContact else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC debug cancel skipped because no contact is selected"
            )
            captureDiagnosticsState("direct-quic:debug-cancel:no-selection")
            return
        }
        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: selectedContact.id) else {
            diagnostics.record(
                .media,
                message: "Direct QUIC debug cancel skipped because there is no active attempt",
                metadata: [
                    "contactId": selectedContact.id.uuidString,
                    "handle": selectedContact.handle,
                    "reason": reason,
                ]
            )
            captureDiagnosticsState("direct-quic:debug-cancel:no-attempt")
            return
        }

        cancelDirectQuicPromotionTimeout()
        await sendDirectQuicHangup(
            for: selectedContact.id,
            attempt: attempt,
            reason: reason
        )
        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: selectedContact.id,
            fallbackReason: reason,
            retryBackoff: nil
        )
        applyDirectQuicUpgradeTransition(fallback, for: selectedContact.id)
        mediaRuntime.directQuicProbeController?.cancel(reason: reason)
        mediaRuntime.directQuicProbeController = nil
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == selectedContact.id {
            configureOutgoingAudioRoute(target: activeTarget)
        }
        diagnostics.record(
            .media,
            message: "Direct QUIC attempt cancelled from diagnostics",
            metadata: [
                "contactId": selectedContact.id.uuidString,
                "handle": selectedContact.handle,
                "attemptId": attempt.attemptId,
                "reason": reason,
                "wasDirectActive": String(attempt.isDirectActive),
            ]
        )
        captureDiagnosticsState("direct-quic:debug-cancel")
    }

    func scheduleDirectQuicPromotionTimeout(
        contactID: UUID,
        attemptID: String
    ) {
        let timeoutMilliseconds = directQuicPromotionTimeoutMilliseconds()
        mediaRuntime.replaceDirectQuicPromotionTimeoutTask(with: Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.handleDirectQuicPromotionTimeout(
                contactID: contactID,
                attemptID: attemptID,
                timeoutMilliseconds: timeoutMilliseconds
            )
        })
    }

    func handleDirectQuicPromotionTimeout(
        contactID: UUID,
        attemptID: String,
        timeoutMilliseconds: Int
    ) async {
        guard let activeAttempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID),
              activeAttempt.attemptId == attemptID else {
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC promotion timed out",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": activeAttempt.channelID,
                "attemptId": attemptID,
                "timeoutMilliseconds": "\(timeoutMilliseconds)",
            ]
        )
        await finishDirectQuicAttempt(
            for: contactID,
            reason: "promotion-timeout",
            sendHangup: true,
            applyRetryBackoff: true
        )
    }

    func finishDirectQuicAttempt(
        for contactID: UUID,
        reason: String,
        sendHangup: Bool,
        applyRetryBackoff: Bool
    ) async {
        cancelDirectQuicPromotionTimeout()

        guard let attempt = mediaRuntime.directQuicUpgrade.attempt(for: contactID) else {
            mediaRuntime.directQuicProbeController?.cancel(reason: reason)
            mediaRuntime.directQuicProbeController = nil
            return
        }

        if sendHangup {
            await sendDirectQuicHangup(
                for: contactID,
                attempt: attempt,
                reason: reason
            )
        }

        let retryBackoff = applyRetryBackoff
            ? directQuicRetryBackoffRequest(
                reason: reason,
                attemptID: attempt.attemptId
            )
            : nil

        let fallback = mediaRuntime.directQuicUpgrade.clearAttempt(
            for: contactID,
            fallbackReason: reason,
            retryBackoff: retryBackoff
        )
        applyDirectQuicUpgradeTransition(fallback, for: contactID)
        mediaRuntime.directQuicProbeController?.cancel(reason: reason)
        mediaRuntime.directQuicProbeController = nil
    }

    func activateDirectQuicMediaPath(
        for contactID: UUID,
        attemptID: String
    ) async {
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID) else {
            return
        }
        guard let controller = mediaRuntime.directQuicProbeController else { return }
        guard let nominatedPath = controller.nominatedPath(matching: attemptID) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC activation skipped because no nominated path is available",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                ]
            )
            return
        }

        do {
            try await controller.activateMediaTransport(
                onIncomingAudioPayload: { [weak self] payload in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleIncomingDirectQuicAudioPayload(
                            payload,
                            contactID: contactID,
                            attemptID: attemptID
                        )
                    }
                },
                onPathLost: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleDirectQuicMediaPathLost(
                            for: contactID,
                            attemptID: attemptID,
                            reason: reason
                        )
                    }
                }
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Failed to activate direct QUIC media path",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attemptID,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "activation-failed",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        guard let transition = mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: attemptID,
            nominatedPath: nominatedPath
        ) else {
            return
        }

        diagnostics.record(
            .media,
            message: "Direct QUIC media path activated",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attemptID,
                "nominatedPathSource": nominatedPath.source.rawValue,
                "nominatedRemoteAddress": nominatedPath.remoteAddress,
                "nominatedRemotePort": "\(nominatedPath.remotePort)",
                "nominatedRemoteCandidateKind": nominatedPath.remoteCandidateKind?.rawValue ?? "observed",
            ]
        )
        cancelDirectQuicPromotionTimeout()
        applyDirectQuicUpgradeTransition(transition, for: contactID)
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            configureOutgoingAudioRoute(target: activeTarget)
        }
    }

    func handleIncomingDirectQuicAudioPayload(
        _ payload: String,
        contactID: UUID,
        attemptID: String
    ) async {
        guard let attempt = directQuicAttempt(for: contactID, matching: attemptID) else {
            return
        }
        let remoteUserID = contacts.first(where: { $0.id == contactID })?.remoteUserId ?? ""
        let fromDeviceID = attempt.peerDeviceID ?? "direct-quic"

        diagnostics.record(
            .media,
            message: "Direct QUIC audio payload received",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": attempt.channelID,
                "attemptId": attemptID,
                "fromDeviceId": fromDeviceID,
            ]
        )
        await handleIncomingAudioPayload(
            payload,
            channelID: attempt.channelID,
            fromUserID: remoteUserID,
            fromDeviceID: fromDeviceID,
            contactID: contactID
        )
    }

    func handleDirectQuicMediaPathLost(
        for contactID: UUID,
        attemptID: String,
        reason: String
    ) async {
        diagnostics.record(
            .media,
            level: .error,
            message: "Direct QUIC media path lost",
            metadata: [
                "contactId": contactID.uuidString,
                "attemptId": attemptID,
                "reason": reason,
                "failureCategory": DirectQuicRetryBackoffPolicy.category(for: reason).rawValue,
            ]
        )
        mediaRuntime.directQuicUpgrade.applyRetryBackoff(
            for: contactID,
            request: directQuicRetryBackoffRequest(
                reason: reason,
                attemptID: attemptID
            )
        )

        if let recovering = mediaRuntime.directQuicUpgrade.markDirectPathLost(
            for: contactID,
            reason: reason
        ) {
            applyDirectQuicUpgradeTransition(recovering, for: contactID)
            applyDirectQuicUpgradeTransition(
                .fellBackToRelay(previousAttemptId: recovering.attemptId, reason: reason),
                for: contactID
            )
        }

        mediaRuntime.directQuicProbeController?.cancel(reason: "path-lost")
        mediaRuntime.directQuicProbeController = nil
        if let activeTarget = transmitProjection.activeTarget,
           activeTarget.contactID == contactID {
            configureOutgoingAudioRoute(target: activeTarget)
        }
    }

    func sendDirectQuicHangup(
        for contactID: UUID,
        attempt: DirectQuicUpgradeAttempt,
        reason: String
    ) async {
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let remoteUserID = contact.remoteUserId else {
            return
        }
        let peerDeviceID = attempt.peerDeviceID
            ?? directQuicPeerDeviceID(for: contactID)
            ?? attempt.remoteOffer?.fromDeviceId
        guard let peerDeviceID, !peerDeviceID.isEmpty else {
            diagnostics.record(
                .websocket,
                message: "Skipped direct QUIC hangup because peer device is unknown",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "reason": reason,
                ]
            )
            return
        }

        do {
            try await backend.waitForWebSocketConnection()
            let envelope = try TurboSignalEnvelope.directQuicHangup(
                channelId: attempt.channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: TurboDirectQuicHangupPayload(
                    attemptId: attempt.attemptId,
                    reason: reason
                )
            )
            try await backend.sendSignal(envelope)
            diagnostics.record(
                .websocket,
                message: "Direct QUIC hangup sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC hangup send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": attempt.channelID,
                    "attemptId": attempt.attemptId,
                    "peerDeviceId": peerDeviceID,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func sendDirectQuicCandidateSignals(
        channelID: String,
        contactID: UUID,
        remoteUserID: String,
        remoteDeviceID: String,
        attemptID: String,
        candidates: [TurboDirectQuicCandidate],
        endOfCandidates: Bool
    ) async {
        guard let backend = backendServices else { return }

        do {
            try await backend.waitForWebSocketConnection()
            for candidate in candidates {
                let envelope = try TurboSignalEnvelope.directQuicCandidate(
                    channelId: channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: remoteUserID,
                    toDeviceId: remoteDeviceID,
                    payload: TurboDirectQuicCandidatePayload(
                        attemptId: attemptID,
                        candidate: candidate
                    )
                )
                try await backend.sendSignal(envelope)
            }
            if endOfCandidates {
                let envelope = try TurboSignalEnvelope.directQuicCandidate(
                    channelId: channelID,
                    fromUserId: backend.currentUserID ?? "",
                    fromDeviceId: backend.deviceID,
                    toUserId: remoteUserID,
                    toDeviceId: remoteDeviceID,
                    payload: TurboDirectQuicCandidatePayload(
                        attemptId: attemptID,
                        candidate: nil,
                        endOfCandidates: true
                    )
                )
                try await backend.sendSignal(envelope)
            }
            diagnostics.record(
                .websocket,
                message: "Direct QUIC candidates sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "endOfCandidates": String(endOfCandidates),
                    "peerDeviceId": remoteDeviceID,
                ]
            )
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC candidate send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "endOfCandidates": String(endOfCandidates),
                    "peerDeviceId": remoteDeviceID,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func continueDirectQuicPromotionIfNeeded(
        for contactID: UUID,
        attemptID: String,
        expectedPeerCertificateFingerprint: String,
        candidates: [TurboDirectQuicCandidate],
        trigger: String
    ) async {
        guard !candidates.isEmpty else { return }
        guard directQuicAttempt(for: contactID, matching: attemptID)?.isDirectActive != true else {
            return
        }
        guard let controller = mediaRuntime.directQuicProbeController else { return }

        do {
            let outcome = try await controller.probeRemoteCandidatesIfNeeded(
                attemptId: attemptID,
                expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
                candidates: candidates
            )
            guard outcome.didEstablishPath else {
                let metadata: [String: String] = [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "viableCandidateCount": "\(outcome.viableCandidateCount)",
                    "newlyAttemptedCandidateCount": "\(outcome.newlyAttemptedCandidateCount)",
                    "trigger": trigger,
                    "disposition": outcome.disposition.rawValue,
                    "lastError": outcome.lastErrorDescription ?? "none",
                ]
                let message: String
                switch outcome.disposition {
                case .alreadyConnected, .pathEstablished:
                    message = "Direct QUIC remote candidate probe established path"
                case .noViableCandidates:
                    message = "Direct QUIC promotion ignored remote candidates without viable UDP addresses"
                case .noNewCandidates:
                    message = "Direct QUIC promotion is waiting because remote candidates were already attempted"
                case .probeAlreadyInFlight:
                    message = "Direct QUIC promotion probe is already in flight"
                case .batchExhausted:
                    message = "Direct QUIC remote candidate probe batch exhausted without nomination"
                }
                diagnostics.record(
                    .media,
                    level: outcome.disposition == .batchExhausted ? .error : .info,
                    message: message,
                    metadata: metadata
                )
                return
            }

            diagnostics.record(
                .media,
                message: "Direct QUIC remote candidate probe established path",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "viableCandidateCount": "\(outcome.viableCandidateCount)",
                    "newlyAttemptedCandidateCount": "\(outcome.newlyAttemptedCandidateCount)",
                    "trigger": trigger,
                    "disposition": outcome.disposition.rawValue,
                ]
            )
            await activateDirectQuicMediaPath(
                for: contactID,
                attemptID: attemptID
            )
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC remote candidate probe failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "attemptId": attemptID,
                    "candidateCount": "\(candidates.count)",
                    "trigger": trigger,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func maybeStartDirectQuicProbe(
        for contactID: UUID,
        allowDebugBypassWithoutBackendAdvertisement: Bool = false
    ) async {
        let isUpgradeAllowed =
            !isDirectPathRelayOnlyForced
            && (
                backendAdvertisesDirectQuicUpgrade
                    || allowDebugBypassWithoutBackendAdvertisement
            )
        guard isUpgradeAllowed else { return }
        guard let backend = backendServices else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        guard let channelID = contact.backendChannelId,
              let remoteUserID = contact.remoteUserId else {
            return
        }
        if allowDebugBypassWithoutBackendAdvertisement,
           !backendAdvertisesDirectQuicUpgrade {
            diagnostics.record(
                .media,
                message: "Direct QUIC debug probe bypassed backend capability gate",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "handle": contact.handle,
                ]
            )
        }
        guard mediaConnectionState == .connected else { return }
        guard mediaRuntime.directQuicUpgrade.attempt(for: contactID) == nil else { return }
        if let retryBackoff = mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID),
           let retryRemaining = mediaRuntime.directQuicUpgrade.retryBackoffRemaining(for: contactID) {
            diagnostics.record(
                .media,
                message: "Skipped direct QUIC probe during retry backoff",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "retryRemainingMs": "\(Int(retryRemaining * 1_000))",
                    "retryReason": retryBackoff.reason,
                    "retryCategory": retryBackoff.category.rawValue,
                    "retryAttemptId": retryBackoff.attemptId ?? "",
                    "retryBackoffMs": "\(retryBackoff.milliseconds)",
                ]
            )
            return
        }

        guard let peerDeviceID = directQuicPeerDeviceID(for: contactID) else {
            diagnostics.record(
                .media,
                message: "Skipped direct QUIC probe because peer target device is unknown",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                ]
            )
            return
        }

        let role = directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: peerDeviceID
        )
        guard role == .listenerOfferer else { return }

        let attemptID = UUID().uuidString.lowercased()
        let transition = mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: channelID,
            attemptID: attemptID,
            peerDeviceID: peerDeviceID
        )
        applyDirectQuicUpgradeTransition(transition, for: contactID)

        do {
            let preparedOffer = try await directQuicProbeController().prepareListenerOffer(
                attemptId: attemptID,
                stunServers: directQuicStunServers()
            )
            let offerPayload = TurboDirectQuicOfferPayload(
                attemptId: attemptID,
                channelId: channelID,
                fromDeviceId: backend.deviceID,
                toDeviceId: peerDeviceID,
                quicAlpn: preparedOffer.quicAlpn,
                certificateFingerprint: preparedOffer.certificateFingerprint,
                candidates: preparedOffer.candidates,
                roleIntent: .listener
            )
            try await backend.waitForWebSocketConnection()
            let envelope = try TurboSignalEnvelope.directQuicOffer(
                channelId: channelID,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: remoteUserID,
                toDeviceId: peerDeviceID,
                payload: offerPayload
            )
            try await backend.sendSignal(envelope)
            diagnostics.record(
                .websocket,
                message: "Direct QUIC offer sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "attemptId": attemptID,
                    "candidateCount": "\(preparedOffer.candidates.count)",
                    "peerDeviceId": peerDeviceID,
                ]
            )
            scheduleDirectQuicPromotionTimeout(contactID: contactID, attemptID: attemptID)
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC offer preparation failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "peerDeviceId": peerDeviceID,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "offer-failed",
                sendHangup: false,
                applyRetryBackoff: true
            )
        }
    }

    func handleDirectQuicSignal(
        _ signal: TurboDirectQuicSignalPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        switch signal {
        case .offer(let payload):
            await respondToDirectQuicOffer(
                payload,
                envelope: envelope,
                contactID: contactID
            )
        case .answer(let payload):
            await handleDirectQuicAnswer(
                payload,
                envelope: envelope,
                contactID: contactID
            )
        case .candidate(let payload):
            guard let attempt = directQuicAttempt(for: contactID, matching: payload.attemptId) else {
                return
            }
            if payload.endOfCandidates {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC remote candidate trickle completed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": attempt.channelID,
                        "attemptId": payload.attemptId,
                        "remoteCandidateCount": "\(attempt.remoteCandidateCount)",
                    ]
                )
            }
            guard let expectedPeerCertificateFingerprint = directQuicExpectedPeerCertificateFingerprint(
                for: attempt
            ) else {
                return
            }
            let candidatesToProbe = directQuicCandidateBatchToProbe(
                for: attempt,
                payload: payload
            )
            await continueDirectQuicPromotionIfNeeded(
                for: contactID,
                attemptID: payload.attemptId,
                expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
                candidates: candidatesToProbe,
                trigger: payload.endOfCandidates ? "end-of-candidates" : "trickle-candidate"
            )
        case .hangup(let payload):
            let isRecoveringActivePath =
                mediaRuntime.transportPathState == .direct
                || mediaRuntime.transportPathState == .recovering
            if directQuicAttempt(for: contactID)?.isDirectActive == true {
                await handleDirectQuicMediaPathLost(
                    for: contactID,
                    attemptID: payload.attemptId,
                    reason: payload.reason
                )
                return
            }
            cancelDirectQuicPromotionTimeout()
            mediaRuntime.directQuicUpgrade.applyRetryBackoff(
                for: contactID,
                request: directQuicRetryBackoffRequest(
                    reason: payload.reason,
                    attemptID: payload.attemptId
                )
            )
            mediaRuntime.directQuicProbeController?.cancel(reason: payload.reason)
            mediaRuntime.directQuicProbeController = nil
            if isRecoveringActivePath {
                applyDirectQuicUpgradeTransition(
                    .fellBackToRelay(
                        previousAttemptId: payload.attemptId,
                        reason: payload.reason
                    ),
                    for: contactID
                )
                if let activeTarget = transmitProjection.activeTarget,
                   activeTarget.contactID == contactID {
                    configureOutgoingAudioRoute(target: activeTarget)
                }
            }
        }
    }

    func respondToDirectQuicOffer(
        _ offer: TurboDirectQuicOfferPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        guard let backend = backendServices else { return }

        let role = directQuicAttemptRole(
            localDeviceID: backend.deviceID,
            peerDeviceID: envelope.fromDeviceId
        )
        guard role == .dialerAnswerer else {
            diagnostics.record(
                .websocket,
                message: "Ignored direct QUIC offer because local role is not dialer",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "localDeviceId": backend.deviceID,
                    "peerDeviceId": envelope.fromDeviceId,
                ]
            )
            return
        }

        let answerPayload: TurboDirectQuicAnswerPayload
        let directPathEstablished: Bool
        do {
            let preparedConnection = try await directQuicProbeController().connect(
                using: offer,
                stunServers: directQuicStunServers()
            )
            directPathEstablished = preparedConnection.didEstablishPath
            answerPayload = TurboDirectQuicAnswerPayload(
                attemptId: offer.attemptId,
                accepted: true,
                certificateFingerprint: preparedConnection.certificateFingerprint,
                candidates: preparedConnection.candidates
            )
            if preparedConnection.didEstablishPath {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC proof established; promoting media path",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "attemptId": offer.attemptId,
                        "localCandidateCount": "\(preparedConnection.candidates.count)",
                    ]
                )
            } else {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC initial dial failed; awaiting late offerer candidates",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "attemptId": offer.attemptId,
                        "localCandidateCount": "\(preparedConnection.candidates.count)",
                        "error": preparedConnection.lastFailureReason ?? "unknown",
                    ]
                )
            }
        } catch {
            directPathEstablished = false
            answerPayload = TurboDirectQuicAnswerPayload(
                attemptId: offer.attemptId,
                accepted: false,
                rejectionReason: error.localizedDescription
            )
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC probe connect failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            let relayFallback = mediaRuntime.directQuicUpgrade.clearAttempt(
                for: contactID,
                fallbackReason: "probe-connect-failed",
                retryBackoff: directQuicRetryBackoffRequest(
                    reason: "probe-connect-failed",
                    attemptID: offer.attemptId
                )
            )
            applyDirectQuicUpgradeTransition(relayFallback, for: contactID)
            mediaRuntime.directQuicProbeController?.cancel(reason: "connect-failed")
            mediaRuntime.directQuicProbeController = nil
        }

        do {
            try await backend.waitForWebSocketConnection()
            let answerEnvelope = try TurboSignalEnvelope.directQuicAnswer(
                channelId: envelope.channelId,
                fromUserId: backend.currentUserID ?? "",
                fromDeviceId: backend.deviceID,
                toUserId: envelope.fromUserId,
                toDeviceId: envelope.fromDeviceId,
                payload: answerPayload
            )
            try await backend.sendSignal(answerEnvelope)
            diagnostics.record(
                .websocket,
                message: "Direct QUIC answer sent",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "accepted": String(answerPayload.accepted),
                ]
            )
            if answerPayload.accepted {
                await sendDirectQuicCandidateSignals(
                    channelID: envelope.channelId,
                    contactID: contactID,
                    remoteUserID: envelope.fromUserId,
                    remoteDeviceID: envelope.fromDeviceId,
                    attemptID: offer.attemptId,
                    candidates: answerPayload.candidates,
                    endOfCandidates: true
                )
                if directPathEstablished {
                    await activateDirectQuicMediaPath(
                        for: contactID,
                        attemptID: offer.attemptId
                    )
                } else {
                    scheduleDirectQuicPromotionTimeout(
                        contactID: contactID,
                        attemptID: offer.attemptId
                    )
                }
            } else {
                mediaRuntime.directQuicProbeController?.cancel(reason: "answer-sent")
                mediaRuntime.directQuicProbeController = nil
            }
        } catch {
            diagnostics.record(
                .websocket,
                level: .error,
                message: "Direct QUIC answer send failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": offer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "answer-send-failed",
                sendHangup: false,
                applyRetryBackoff: true
            )
        }
    }

    func handleDirectQuicAnswer(
        _ answer: TurboDirectQuicAnswerPayload,
        envelope: TurboSignalEnvelope,
        contactID: UUID
    ) async {
        if !answer.accepted {
            cancelDirectQuicPromotionTimeout()
            let rejectionReason = answer.rejectionReason ?? "answer-rejected"
            mediaRuntime.directQuicUpgrade.applyRetryBackoff(
                for: contactID,
                request: directQuicRetryBackoffRequest(
                    reason: rejectionReason,
                    attemptID: answer.attemptId
                )
            )
            mediaRuntime.directQuicProbeController?.cancel(
                reason: rejectionReason
            )
            mediaRuntime.directQuicProbeController = nil
            return
        }

        guard let controller = mediaRuntime.directQuicProbeController else {
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "missing-probe-controller",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }
        guard let expectedPeerCertificateFingerprint = answer.certificateFingerprint,
              !expectedPeerCertificateFingerprint.isEmpty else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC answer missing peer certificate fingerprint",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": answer.attemptId,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "missing-peer-certificate-fingerprint",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        let localCandidatesToRetrickle = controller.preparedLocalCandidates(
            matching: answer.attemptId
        )
        if !localCandidatesToRetrickle.isEmpty {
            await sendDirectQuicCandidateSignals(
                channelID: envelope.channelId,
                contactID: contactID,
                remoteUserID: envelope.fromUserId,
                remoteDeviceID: envelope.fromDeviceId,
                attemptID: answer.attemptId,
                candidates: localCandidatesToRetrickle,
                endOfCandidates: true
            )
        }

        do {
            if try controller.verifyConnectedPeerCertificateFingerprintIfAvailable(
                expectedPeerCertificateFingerprint
            ) {
                diagnostics.record(
                    .media,
                    message: "Direct QUIC listener received successful probe answer",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": envelope.channelId,
                        "attemptId": answer.attemptId,
                        "peerCertificateFingerprint": expectedPeerCertificateFingerprint,
                        "peerCandidateCount": "\(answer.candidates.count)",
                    ]
                )
                await activateDirectQuicMediaPath(
                    for: contactID,
                    attemptID: answer.attemptId
                )
                return
            }
        } catch {
            diagnostics.record(
                .media,
                level: .error,
                message: "Direct QUIC answer peer certificate fingerprint verification failed",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": envelope.channelId,
                    "attemptId": answer.attemptId,
                    "error": error.localizedDescription,
                ]
            )
            await finishDirectQuicAttempt(
                for: contactID,
                reason: "peer-certificate-fingerprint-mismatch",
                sendHangup: true,
                applyRetryBackoff: true
            )
            return
        }

        let remoteCandidates = directQuicAttempt(
            for: contactID,
            matching: answer.attemptId
        )?.remoteCandidates ?? answer.candidates
        diagnostics.record(
            .media,
            message: "Direct QUIC answer accepted; continuing promotion with remote candidates",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": envelope.channelId,
                "attemptId": answer.attemptId,
                "peerCertificateFingerprint": expectedPeerCertificateFingerprint,
                "peerCandidateCount": "\(remoteCandidates.count)",
            ]
        )
        scheduleDirectQuicPromotionTimeout(
            contactID: contactID,
            attemptID: answer.attemptId
        )
        await continueDirectQuicPromotionIfNeeded(
            for: contactID,
            attemptID: answer.attemptId,
            expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
            candidates: remoteCandidates,
            trigger: "accepted-answer"
        )
    }
}
