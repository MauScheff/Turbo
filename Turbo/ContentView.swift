//
//  ContentView.swift
//  Turbo
//
//  Created by Maurice on 20.03.2026.
//

import SwiftUI

private enum ContentRoute {
    case splash
    case accountChoice
    case profileSetup
    case handleSetup
    case live
}

struct ContentView: View {
    @State private var viewModel: PTTViewModel
    @State private var route: ContentRoute = .splash
    @State private var isShowingAddContactSheet: Bool = false
    @State private var isShowingProfileSheet: Bool = false
    @State private var isShowingDevIdentitySheet: Bool = false
    @State private var isShowingDiagnostics: Bool = false
    @State private var contactDetailsContactID: UUID?
    @State private var draftDevUserHandle: String = ""
    @State private var draftPeerHandle: String = ""
    @State private var draftExistingIdentityReference: String = ""
    @State private var draftProfileName: String = ""
    @State private var draftHandleBody: String = ""
    @State private var draftLocalContactName: String = ""
    @State private var isSavingDevIdentity: Bool = false
    @State private var isSavingProfileName: Bool = false
    @State private var isCreatingIdentity: Bool = false
    @State private var isSigningOut: Bool = false
    @State private var isRestoringIdentity: Bool = false
    @State private var isOpeningPeer: Bool = false
    @State private var isDeletingContact: Bool = false
    @State private var isResettingDevState: Bool = false
    @State private var isUploadingDiagnostics: Bool = false
    @State private var isRequestingMicrophonePermission: Bool = false
    @State private var isRequestingLocalNetworkPermission: Bool = false
    @State private var isRequestingNotificationPermission: Bool = false
    @State private var isRunningDirectQuicDebugAction: Bool = false
    @State private var diagnosticsUploadStatus: String?
    @State private var identityRestoreError: String?
    @State private var handleSetupError: String?
    @State private var contactDeleteError: String?
    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    init(viewModel: PTTViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch route {
            case .splash:
                splashView
            case .accountChoice:
                accountChoiceView
            case .profileSetup:
                profileSetupView
            case .handleSetup:
                handleSetupView
            case .live:
                mainView
            }
        }
        .task {
            await viewModel.initializeIfNeeded()
            if draftProfileName.isEmpty {
                draftProfileName = viewModel.currentProfileName
            }
            if route == .splash, viewModel.hasCompletedIdentityOnboarding {
                route = .live
            }
        }
        .overlay(alignment: .top) {
            if let activeIncomingTalkRequest = viewModel.activeIncomingTalkRequest {
                TurboIncomingTalkRequestBanner(
                    request: activeIncomingTalkRequest,
                    onDismiss: viewModel.dismissIncomingTalkRequestSurface,
                    onAccept: viewModel.acceptActiveIncomingTalkRequest
                )
                .padding(.horizontal)
                .padding(.top, route == .splash ? 18 : 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: viewModel.activeIncomingTalkRequest?.id)
        .onChange(of: viewModel.selectedContactId) { _, _ in
            route = .live
            isShowingAddContactSheet = false
        }
        .onChange(of: viewModel.currentProfileName) { _, newValue in
            if !isSavingProfileName && !isShowingProfileSheet {
                draftProfileName = newValue
            }
        }
        .sheet(isPresented: $isShowingAddContactSheet) {
            TurboAddContactSheet(
                draftReference: $draftPeerHandle,
                currentIdentityHandle: viewModel.currentIdentityHandle,
                currentShareLink: viewModel.currentIdentityShareLink,
                quickPeerHandles: viewModel.quickPeerHandles,
                isOpeningPeer: isOpeningPeer,
                isResettingDevState: isResettingDevState,
                statusMessage: addContactStatusMessage,
                onClose: { isShowingAddContactSheet = false },
                onOpenReference: openPeer
            )
        }
        .sheet(isPresented: $isShowingProfileSheet) {
            TurboProfileSheet(
                draftProfileName: $draftProfileName,
                currentIdentityHandle: viewModel.currentIdentityHandle,
                currentShareLink: viewModel.currentIdentityShareLink,
                isSavingProfileName: isSavingProfileName,
                isSigningOut: isSigningOut,
                showsDeveloperControls: viewModel.developerIdentityControlsEnabled,
                onClose: { isShowingProfileSheet = false },
                onSaveProfileName: saveProfileNameFromSheet,
                onSignOut: signOut,
                onShowDevIdentity: {
                    isShowingProfileSheet = false
                    draftDevUserHandle = viewModel.currentDevUserHandle
                    isShowingDevIdentitySheet = true
                },
                onShowDiagnostics: {
                    isShowingProfileSheet = false
                    isShowingDiagnostics = true
                },
                onRunSelfCheck: {
                    isShowingProfileSheet = false
                    runSelfCheckAndShowDiagnostics()
                },
                onResetDevState: {
                    isShowingProfileSheet = false
                    resetDevState()
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { contactDetailsContactID != nil && detailContact != nil },
                set: { isPresented in
                    if !isPresented {
                        contactDetailsContactID = nil
                        contactDeleteError = nil
                        isDeletingContact = false
                    }
                }
            )
        ) {
            if let detailContact {
                TurboContactDetailSheet(
                    contact: detailContact,
                    draftLocalName: $draftLocalContactName,
                    shareLink: viewModel.contactShareLink(for: detailContact.id) ?? "",
                    did: viewModel.contactDID(for: detailContact.id) ?? "",
                    isDeletingContact: isDeletingContact,
                    deleteErrorMessage: contactDeleteError,
                    onClose: { contactDetailsContactID = nil },
                    onSaveLocalName: saveLocalContactName,
                    onClearLocalName: clearLocalContactName,
                    onDeleteContact: deleteContactFromDetails
                )
            }
        }
        .sheet(isPresented: $isShowingDevIdentitySheet) {
            TurboDevIdentitySheet(
                draftDevUserHandle: $draftDevUserHandle,
                availableDevUserHandles: viewModel.availableDevUserHandles,
                isSaving: isSavingDevIdentity,
                onCancel: { isShowingDevIdentitySheet = false },
                onSave: saveDevIdentity
            )
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            TurboDiagnosticsSheet(
                report: viewModel.latestSelfCheckReport,
                projection: viewModel.stateMachineProjection,
                directQuic: viewModel.developerIdentityControlsEnabled
                    ? viewModel.selectedDirectQuicDiagnosticsSummary
                    : nil,
                microphonePermissionStatus: viewModel.microphonePermissionStatusText,
                needsMicrophonePermission: viewModel.needsMicrophonePermission,
                notificationPermissionStatus: notificationPermissionButtonTitle,
                needsNotificationPermission: viewModel.needsAlertNotificationPermission,
                localNetworkPermissionStatus: viewModel.localNetworkPreflightStatus.detailText,
                logFilePath: viewModel.diagnostics.logFilePath,
                diagnosticsTranscript: viewModel.diagnosticsTranscript,
                entries: viewModel.diagnostics.entries,
                uploadStatus: diagnosticsUploadStatus,
                isUploading: isUploadingDiagnostics,
                isRequestingMicrophonePermission: isRequestingMicrophonePermission,
                isRequestingLocalNetworkPermission: isRequestingLocalNetworkPermission,
                isRequestingNotificationPermission: isRequestingNotificationPermission,
                isRunningDirectQuicDebugAction: isRunningDirectQuicDebugAction,
                onClose: { isShowingDiagnostics = false },
                onUpload: uploadDiagnostics,
                onClear: { viewModel.diagnostics.clear() },
                onRequestMicrophonePermission: requestMicrophonePermission,
                onRequestLocalNetworkPermission: requestLocalNetworkPermission,
                onRequestNotificationPermission: requestNotificationPermission,
                onImportDirectQuicIdentity: importDirectQuicIdentityFromDiagnostics,
                onUseInstalledDirectQuicIdentity: useInstalledDirectQuicIdentityFromDiagnostics,
                onSetRelayOnlyForced: setDirectPathRelayOnlyForced,
                onForceDirectQuicProbe: forceDirectQuicProbeFromDiagnostics,
                onClearDirectQuicRetryBackoff: clearDirectQuicRetryBackoffFromDiagnostics,
                onCancelDirectQuicAttempt: cancelDirectQuicAttemptFromDiagnostics
            )
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
            guard let url = userActivity.webpageURL else { return }
            handleIncomingURL(url)
        }
    }

    private var mainView: some View {
        VStack(spacing: 16) {
            TurboHeaderView(
                statusMessage: viewModel.statusMessage,
                transportPathState: viewModel.mediaTransportPathState,
                transportPathTint: transportPathTint,
                latestErrorText: latestDiagnosticsErrorText,
                microphonePermissionStatus: viewModel.microphonePermissionStatusText,
                needsMicrophonePermission: viewModel.needsMicrophonePermission,
                notificationPermissionStatus: viewModel.alertNotificationAuthorizationStatusText,
                needsNotificationPermission: viewModel.needsAlertNotificationPermission,
                localNetworkPermissionStatus: localNetworkPermissionButtonTitle,
                showsLocalNetworkPermissionControl: viewModel.localNetworkPreflightStatus.shouldShowMainSurfaceControl,
                showsResolvedMicrophoneStatus: viewModel.developerIdentityControlsEnabled,
                showsDebugPermissionControls: viewModel.developerIdentityControlsEnabled,
                showsAddContactButton: !viewModel.contacts.isEmpty,
                showsAudioRoutePicker: viewModel.isJoined,
                onAddContact: {
                    isShowingAddContactSheet = true
                },
                onShowProfile: {
                    draftProfileName = viewModel.currentProfileName
                    isShowingProfileSheet = true
                },
                onRequestMicrophonePermission: requestMicrophonePermission,
                onRequestLocalNetworkPermission: requestLocalNetworkPermission,
                onRequestNotificationPermission: requestNotificationPermission
            )
            if viewModel.contacts.isEmpty, viewModel.activeConversationContact == nil {
                TurboEmptyContactsView(onAddContact: {
                    isShowingAddContactSheet = true
                })
            } else {
                TurboContactListView(
                    selectedContactID: viewModel.selectedContactId,
                    activeContact: viewModel.activeConversationContact,
                    systemSessionSubtitle: systemSessionSubtitle,
                    contactSections: viewModel.contactListSections,
                    activeStatusPill: contactStatusPillModel,
                    itemStatusPill: contactListItemStatusPillModel,
                    activeSubtitle: { viewModel.contactSubtitle(for: $0) },
                    itemSubtitle: contactListItemSubtitle,
                    selectContact: viewModel.selectContact,
                    showContactDetails: showContactDetails,
                    endSystemSession: viewModel.endSystemSession
                )
            }
            TurboTalkControlsView(
                selectedContactID: viewModel.selectedContactId,
                isJoined: viewModel.isJoined,
                activeChannelID: viewModel.activeChannelId,
                isTransmitting: viewModel.isTransmitting,
                isTransmitPressActive: viewModel.isTransmitPressActive,
                selectedPeerState: viewModel.selectedPeerState(for:),
                requestCooldownRemaining: viewModel.requestCooldownRemaining(for:now:),
                joinChannel: viewModel.joinChannel,
                beginTransmit: viewModel.beginTransmit,
                noteTransmitTouchReleased: viewModel.noteTransmitTouchReleased,
                endTransmit: viewModel.endTransmit
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal)
        .padding(.top)
        .padding(.bottom, 2)
    }

    private var transportPathTint: Color {
        switch viewModel.mediaTransportPathState {
        case .relay:
            return .orange
        case .promoting:
            return .blue
        case .direct:
            return .green
        case .recovering:
            return .red
        }
    }

    private var splashView: some View {
        TurboSplashView(
            wordmarkName: wordmarkName,
            hasCompletedOnboarding: viewModel.hasCompletedIdentityOnboarding,
            hasContacts: !viewModel.contacts.isEmpty,
            onContinue: {
                if viewModel.hasCompletedIdentityOnboarding {
                    route = .live
                    if let contact = viewModel.selectedContact {
                        viewModel.selectContact(contact)
                    }
                } else {
                    draftExistingIdentityReference = ""
                    identityRestoreError = nil
                    route = .accountChoice
                }
            }
        )
    }

    private var accountChoiceView: some View {
        TurboIdentityChoiceView(
            wordmarkName: wordmarkName,
            draftExistingIdentityReference: $draftExistingIdentityReference,
            isRestoring: isRestoringIdentity,
            errorMessage: identityRestoreError,
            onChooseNew: {
                draftProfileName = viewModel.currentProfileName
                draftHandleBody = TurboHandle.suggestedEditableBody(from: draftProfileName)
                identityRestoreError = nil
                handleSetupError = nil
                route = .profileSetup
            },
            onRestore: restoreExistingIdentityAndContinue
        )
    }

    private var profileSetupView: some View {
        TurboProfileSetupView(
            wordmarkName: wordmarkName,
            draftProfileName: $draftProfileName,
            isSaving: isSavingProfileName,
            onShuffle: shuffleSuggestedProfileName,
            onContinue: continueToHandleSetup
        )
    }

    private var handleSetupView: some View {
        TurboHandleSetupView(
            wordmarkName: wordmarkName,
            draftHandleBody: $draftHandleBody,
            isSaving: isCreatingIdentity,
            errorMessage: handleSetupError,
            onContinue: createIdentityAndContinue
        )
    }

    private var wordmarkName: String {
        colorScheme == .dark ? "Wordmark-dark" : "Wordmark-light"
    }

    private var latestDiagnosticsErrorText: String? {
        viewModel.topChromeDiagnosticsErrorText
    }

    private var detailContact: Contact? {
        guard let contactDetailsContactID else { return nil }
        return viewModel.contact(for: contactDetailsContactID)
    }

    private var addContactStatusMessage: String? {
        if isOpeningPeer {
            return "Opening contact…"
        }
        guard viewModel.backendCommandCoordinator.state.lastError != nil else { return nil }
        return viewModel.backendStatusMessage
    }

    private func openPeer(_ handle: String) {
        beginOpeningPeer(handle)
    }

    private func showContactDetails(for contact: Contact) {
        contactDetailsContactID = contact.id
        draftLocalContactName = viewModel.contactLocalName(for: contact.id) ?? ""
        contactDeleteError = nil
        isDeletingContact = false
    }

    private func saveLocalContactName() {
        guard let contactDetailsContactID else { return }
        viewModel.updateLocalContactName(draftLocalContactName, for: contactDetailsContactID)
        draftLocalContactName = viewModel.contactLocalName(for: contactDetailsContactID) ?? ""
    }

    private func clearLocalContactName() {
        guard let contactDetailsContactID else { return }
        viewModel.updateLocalContactName(nil, for: contactDetailsContactID)
        draftLocalContactName = ""
    }

    private func deleteContactFromDetails() {
        guard let contactDetailsContactID else { return }
        contactDeleteError = nil
        isDeletingContact = true
        Task {
            let deleted = await viewModel.deleteContact(contactDetailsContactID)
            await MainActor.run {
                isDeletingContact = false
                if deleted {
                    draftLocalContactName = ""
                    contactDeleteError = nil
                    self.contactDetailsContactID = nil
                } else {
                    contactDeleteError = viewModel.backendStatusMessage
                }
            }
        }
    }

    private func beginOpeningPeer(_ handle: String, ensureInitialized: Bool = false) {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHandle.isEmpty else { return }
        draftPeerHandle = trimmedHandle
        isOpeningPeer = true
        Task {
            if ensureInitialized {
                await viewModel.initializeIfNeeded()
            }
            await viewModel.openContact(reference: trimmedHandle)
            await MainActor.run {
                isOpeningPeer = false
                if viewModel.backendCommandCoordinator.state.lastError == nil {
                    draftPeerHandle = ""
                    isShowingAddContactSheet = false
                    route = .live
                }
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let reference = TurboIncomingLink.reference(from: url) else { return }
        route = .live
        isShowingAddContactSheet = false
        beginOpeningPeer(reference, ensureInitialized: true)
    }

    private func contactListItemSubtitle(_ item: ContactListItem) -> String {
        viewModel.contactSubtitle(for: item.contact, requestCount: item.presentation.requestCount)
    }

    private func runSelfCheckAndShowDiagnostics() {
        Task {
            await viewModel.runSelfCheck()
            await MainActor.run {
                isShowingDiagnostics = true
            }
        }
    }

    private func resetDevState() {
        isResettingDevState = true
        Task {
            await viewModel.resetDevEnvironment()
            await MainActor.run {
                draftPeerHandle = ""
                isResettingDevState = false
                route = .live
            }
        }
    }

    private func saveDevIdentity() {
        let updatedHandle = draftDevUserHandle
        isSavingDevIdentity = true
        Task {
            await viewModel.updateDevUserHandle(updatedHandle)
            await MainActor.run {
                isSavingDevIdentity = false
                isShowingDevIdentitySheet = false
            }
        }
    }

    private func uploadDiagnostics() {
        isUploadingDiagnostics = true
        diagnosticsUploadStatus = nil
        Task {
            do {
                let response = try await viewModel.publishDiagnostics()
                await MainActor.run {
                    diagnosticsUploadStatus =
                        "Uploaded for \(response.report.deviceId) at \(response.report.uploadedAt)"
                    isUploadingDiagnostics = false
                }
            } catch {
                await MainActor.run {
                    diagnosticsUploadStatus = "Upload failed: \(error.localizedDescription)"
                    isUploadingDiagnostics = false
                }
            }
        }
    }

    private func requestMicrophonePermission() {
        isRequestingMicrophonePermission = true
        Task {
            await viewModel.requestMicrophonePermission()
            await MainActor.run {
                isRequestingMicrophonePermission = false
            }
        }
    }

    private var localNetworkPermissionButtonTitle: String {
        if isRequestingLocalNetworkPermission {
            return "Checking local network..."
        }
        switch viewModel.localNetworkPreflightStatus {
        case .notRun:
            return "Enable local network"
        case .running:
            return "Checking local network..."
        case .completed:
            return "Local network enabled"
        case .failed:
            return "Retry local network"
        }
    }

    private var notificationPermissionButtonTitle: String {
        if isRequestingNotificationPermission {
            return "Requesting push notifications..."
        }
        if viewModel.needsAlertNotificationPermission {
            return "Enable push notifications"
        }
        return viewModel.alertNotificationAuthorizationStatusText
    }

    private func requestLocalNetworkPermission() {
        isRequestingLocalNetworkPermission = true
        Task {
            await viewModel.requestLocalNetworkPermissionPreflight()
            await MainActor.run {
                isRequestingLocalNetworkPermission = false
            }
        }
    }

    private func requestNotificationPermission() {
        isRequestingNotificationPermission = true
        Task {
            await viewModel.requestAlertNotificationPermissionPreflight()
            await MainActor.run {
                isRequestingNotificationPermission = false
            }
        }
    }

    private func setDirectPathRelayOnlyForced(_ isForced: Bool) {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.setDirectPathRelayOnlyForcedForDebug(isForced)
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func importDirectQuicIdentityFromDiagnostics(fileURL: URL, password: String) {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.importDirectQuicIdentityForDebug(
                from: fileURL,
                password: password
            )
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func useInstalledDirectQuicIdentityFromDiagnostics() {
        isRunningDirectQuicDebugAction = true
        Task {
            await MainActor.run {
                viewModel.adoptInstalledDirectQuicIdentityForDebug()
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func forceDirectQuicProbeFromDiagnostics() {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.forceSelectedDirectQuicProbeForDebug()
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func clearDirectQuicRetryBackoffFromDiagnostics() {
        isRunningDirectQuicDebugAction = true
        Task {
            await MainActor.run {
                viewModel.clearSelectedDirectQuicRetryBackoffForDebug()
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func cancelDirectQuicAttemptFromDiagnostics() {
        isRunningDirectQuicDebugAction = true
        Task {
            await viewModel.cancelSelectedDirectQuicAttemptForDebug()
            await MainActor.run {
                isRunningDirectQuicDebugAction = false
            }
        }
    }

    private func shuffleSuggestedProfileName() {
        draftProfileName = TurboSuggestedProfileName.generate()
    }

    private func restoreExistingIdentityAndContinue() {
        let reference = draftExistingIdentityReference
        isRestoringIdentity = true
        identityRestoreError = nil
        Task {
            let restored = await viewModel.restoreExistingIdentity(from: reference)
            await MainActor.run {
                isRestoringIdentity = false
                if restored {
                    draftProfileName = viewModel.currentProfileName
                    draftHandleBody = TurboHandle.normalizedEditableBody(viewModel.currentIdentityHandle)
                    draftExistingIdentityReference = ""
                    route = .live
                } else {
                    identityRestoreError = "Couldn’t restore that handle."
                }
            }
        }
    }

    private func continueToHandleSetup() {
        draftHandleBody = TurboHandle.suggestedEditableBody(from: draftProfileName)
        handleSetupError = nil
        route = .handleSetup
    }

    private func createIdentityAndContinue() {
        let profileName = draftProfileName
        let handleBody = TurboHandle.normalizedEditableBody(draftHandleBody)
        guard TurboHandle.isValidEditableBody(handleBody) else {
            handleSetupError = "Use 3–20 lowercase letters or numbers."
            return
        }

        isCreatingIdentity = true
        handleSetupError = nil
        Task {
            let created = await viewModel.createFreshIdentity(
                handle: TurboHandle.canonicalHandle(fromEditableBody: handleBody),
                profileName: profileName
            )
            await MainActor.run {
                isCreatingIdentity = false
                if created {
                    draftProfileName = viewModel.currentProfileName
                    draftHandleBody = handleBody
                    route = .live
                } else {
                    handleSetupError =
                        viewModel.backendStatusMessage.isEmpty
                        ? "Couldn’t claim that handle."
                        : viewModel.backendStatusMessage
                }
            }
        }
    }

    private func saveProfileNameFromSheet() {
        let profileName = draftProfileName
        isSavingProfileName = true
        Task {
            await viewModel.updateProfileName(profileName, markOnboardingComplete: true)
            await MainActor.run {
                draftProfileName = viewModel.currentProfileName
                isSavingProfileName = false
            }
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await viewModel.signOutToFreshIdentity()
            await MainActor.run {
                isSigningOut = false
                isShowingProfileSheet = false
                draftPeerHandle = ""
                draftExistingIdentityReference = ""
                draftProfileName = viewModel.currentProfileName
                draftHandleBody = TurboHandle.suggestedEditableBody(from: draftProfileName)
                identityRestoreError = nil
                handleSetupError = nil
                route = .splash
            }
        }
    }

    private var systemSessionSubtitle: String? {
        switch viewModel.systemSessionState {
        case .none:
            return nil
        case .active(let contactID, _):
            return viewModel.contactName(for: contactID).map { "Active with \($0)" } ?? "Active system session"
        case .mismatched:
            return "iOS still holds a session the app cannot reconcile"
        }
    }

    private func contactStatusPillModel(_ contact: Contact) -> ContactStatusPillModel {
        pillModel(
            for: viewModel.contactListItem(for: contact).presentation,
            isActiveConversation: true
        )
    }

    private func contactListItemStatusPillModel(_ item: ContactListItem) -> ContactStatusPillModel {
        pillModel(for: item.presentation)
    }

    private func pillModel(
        for presentation: ContactListPresentation,
        isActiveConversation: Bool = false
    ) -> ContactStatusPillModel {
        switch presentation.availabilityPill {
        case .online:
            return ContactStatusPillModel(
                text: presentation.statusPillText(isActiveConversation: isActiveConversation),
                tint: .green
            )
        case .offline:
            return ContactStatusPillModel(text: presentation.statusPillText(), tint: .gray)
        case .busy:
            return ContactStatusPillModel(text: presentation.statusPillText(), tint: .orange)
        }
    }
}

#Preview {
    ContentView(viewModel: .shared)
}
