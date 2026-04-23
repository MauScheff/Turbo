//
//  ContentView.swift
//  Turbo
//
//  Created by Maurice on 20.03.2026.
//

import SwiftUI

private enum ContentRoute {
    case splash
    case profileSetup
    case live
}

struct ContentView: View {
    @State private var viewModel: PTTViewModel
    @State private var route: ContentRoute = .splash
    @State private var isShowingAddContactSheet: Bool = false
    @State private var isShowingProfileSheet: Bool = false
    @State private var isShowingDevIdentitySheet: Bool = false
    @State private var isShowingDiagnostics: Bool = false
    @State private var draftDevUserHandle: String = ""
    @State private var draftPeerHandle: String = ""
    @State private var draftProfileName: String = ""
    @State private var isSavingDevIdentity: Bool = false
    @State private var isSavingProfileName: Bool = false
    @State private var isSigningOut: Bool = false
    @State private var isOpeningPeer: Bool = false
    @State private var isResettingDevState: Bool = false
    @State private var isUploadingDiagnostics: Bool = false
    @State private var isRequestingMicrophonePermission: Bool = false
    @State private var diagnosticsUploadStatus: String?
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
            case .profileSetup:
                profileSetupView
            case .live:
                mainView
            }
        }
        .task {
            await viewModel.initializeIfNeeded()
            if draftProfileName.isEmpty {
                draftProfileName = viewModel.currentProfileName
            }
        }
        .overlay(alignment: .top) {
            if let activeIncomingTalkRequest = viewModel.activeIncomingTalkRequest {
                TurboIncomingTalkRequestBanner(
                    request: activeIncomingTalkRequest,
                    onDismiss: viewModel.dismissIncomingTalkRequestSurface,
                    onOpen: viewModel.openActiveIncomingTalkRequest
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
                currentIdentityCode: viewModel.currentIdentityCode,
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
                currentIdentityCode: viewModel.currentIdentityCode,
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
                microphonePermissionStatus: viewModel.microphonePermissionStatusText,
                needsMicrophonePermission: viewModel.needsMicrophonePermission,
                logFilePath: viewModel.diagnostics.logFilePath,
                diagnosticsTranscript: viewModel.diagnosticsTranscript,
                entries: viewModel.diagnostics.entries,
                uploadStatus: diagnosticsUploadStatus,
                isUploading: isUploadingDiagnostics,
                isRequestingMicrophonePermission: isRequestingMicrophonePermission,
                onClose: { isShowingDiagnostics = false },
                onUpload: uploadDiagnostics,
                onClear: { viewModel.diagnostics.clear() },
                onRequestMicrophonePermission: requestMicrophonePermission
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
                wordmarkName: wordmarkName,
                statusMessage: viewModel.statusMessage,
                latestErrorText: latestDiagnosticsErrorText,
                microphonePermissionStatus: viewModel.microphonePermissionStatusText,
                needsMicrophonePermission: viewModel.needsMicrophonePermission,
                onAddContact: {
                    isShowingAddContactSheet = true
                },
                onShowProfile: {
                    draftProfileName = viewModel.currentProfileName
                    isShowingProfileSheet = true
                },
                onRequestMicrophonePermission: requestMicrophonePermission
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
                    selectContact: viewModel.selectContact,
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
        .padding()
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
                    draftProfileName = viewModel.currentProfileName
                    route = .profileSetup
                }
            }
        )
    }

    private var profileSetupView: some View {
        TurboProfileSetupView(
            wordmarkName: wordmarkName,
            draftProfileName: $draftProfileName,
            isSaving: isSavingProfileName,
            onShuffle: shuffleSuggestedProfileName,
            onContinue: saveProfileNameAndContinue
        )
    }

    private var wordmarkName: String {
        colorScheme == .dark ? "Wordmark-dark" : "Wordmark-light"
    }

    private var latestDiagnosticsErrorText: String? {
        viewModel.topChromeDiagnosticsErrorText
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

    private func shuffleSuggestedProfileName() {
        draftProfileName = TurboSuggestedProfileName.generate()
    }

    private func saveProfileNameAndContinue() {
        let profileName = draftProfileName
        isSavingProfileName = true
        Task {
            await viewModel.updateProfileName(profileName, markOnboardingComplete: true)
            await MainActor.run {
                draftProfileName = viewModel.currentProfileName
                isSavingProfileName = false
                route = .live
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
                draftProfileName = viewModel.currentProfileName
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
