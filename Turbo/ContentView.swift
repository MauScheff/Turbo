//
//  ContentView.swift
//  Turbo
//
//  Created by Maurice on 20.03.2026.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = PTTViewModel()
    @State private var isShowingSplash: Bool = true
    @State private var isShowingDevIdentitySheet: Bool = false
    @State private var isShowingDiagnostics: Bool = false
    @State private var draftDevUserHandle: String = ""
    @State private var draftPeerHandle: String = ""
    @State private var isSavingDevIdentity: Bool = false
    @State private var isOpeningPeer: Bool = false
    @State private var isResettingDevState: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if isShowingSplash {
                splashView
            } else {
                mainView
            }
        }
        .task {
            await viewModel.initializeIfNeeded()
        }
        .onChange(of: viewModel.selectedContactId) { _, _ in
            isShowingSplash = false
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
                logFilePath: viewModel.diagnostics.logFilePath,
                diagnosticsTranscript: viewModel.diagnosticsTranscript,
                entries: viewModel.diagnostics.entries,
                onClose: { isShowingDiagnostics = false },
                onClear: { viewModel.diagnostics.clear() }
            )
        }
    }

    private var mainView: some View {
        VStack(spacing: 16) {
            TurboHeaderView(
                wordmarkName: wordmarkName,
                statusMessage: viewModel.statusMessage,
                backendStatusMessage: viewModel.backendStatusMessage,
                selfCheckSummary: viewModel.latestSelfCheckReport?.summary,
                selfCheckPassing: viewModel.latestSelfCheckReport?.isPassing,
                logFilePath: viewModel.diagnostics.logFilePath,
                latestErrorText: latestDiagnosticsErrorText,
                currentDevUserHandle: viewModel.currentDevUserHandle,
                diagnosticsHasError: viewModel.diagnostics.latestError != nil,
                isRunningSelfCheck: viewModel.isRunningSelfCheck,
                isResettingDevState: isResettingDevState,
                onBack: {
                    viewModel.disconnect()
                    viewModel.resetSelection()
                    isShowingSplash = true
                },
                onShowIdentity: {
                    draftDevUserHandle = viewModel.currentDevUserHandle
                    isShowingDevIdentitySheet = true
                },
                onShowDiagnostics: {
                    isShowingDiagnostics = true
                },
                onRunSelfCheck: runSelfCheckAndShowDiagnostics,
                onResetDevState: resetDevState
            )
            peerLookupBar
            TurboContactListView(
                selectedContactID: viewModel.selectedContactId,
                activeContact: viewModel.selectedContact,
                systemSessionSubtitle: systemSessionSubtitle,
                incomingRequests: incomingRequestItems,
                outgoingRequests: outgoingRequestItems,
                contacts: viewModel.sortedContacts,
                statusPill: contactStatusPillModel,
                selectContact: viewModel.selectContact,
                endSystemSession: viewModel.endSystemSession
            )
            TurboTalkControlsView(
                selectedContactID: viewModel.selectedContactId,
                isJoined: viewModel.isJoined,
                activeChannelID: viewModel.activeChannelId,
                isTransmitting: viewModel.isTransmitting,
                selectedPeerState: viewModel.selectedPeerState(for:),
                requestCooldownRemaining: viewModel.requestCooldownRemaining(for:now:),
                joinChannel: viewModel.joinChannel,
                beginTransmit: viewModel.beginTransmit,
                endTransmit: viewModel.endTransmit
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding()
    }

    private var splashView: some View {
        TurboSplashView(
            wordmarkName: wordmarkName,
            backendStatusMessage: viewModel.backendStatusMessage,
            currentDevUserHandle: viewModel.currentDevUserHandle,
            lookupBar: {
                peerLookupBar
            },
            onShowIdentity: {
                draftDevUserHandle = viewModel.currentDevUserHandle
                isShowingDevIdentitySheet = true
            },
            onConnect: {
                isShowingSplash = false
                if let contact = viewModel.selectedContact {
                    viewModel.selectContact(contact)
                }
            }
        )
    }

    private var peerLookupBar: some View {
        TurboPeerLookupBar(
            draftPeerHandle: $draftPeerHandle,
            quickPeerHandles: viewModel.quickPeerHandles,
            isOpeningPeer: isOpeningPeer,
            isResettingDevState: isResettingDevState,
            openPeer: openPeer
        )
    }

    private var wordmarkName: String {
        colorScheme == .dark ? "Wordmark-dark" : "Wordmark-light"
    }

    private var latestDiagnosticsErrorText: String? {
        guard let latestError = viewModel.diagnostics.latestError else { return nil }
        return "\(latestError.subsystem.rawValue): \(latestError.message)"
    }

    private func openPeer(_ handle: String) {
        isOpeningPeer = true
        Task {
            await viewModel.openContact(handle: handle)
            await MainActor.run {
                isOpeningPeer = false
                isShowingSplash = false
            }
        }
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
                isShowingSplash = false
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

    private var incomingRequestItems: [RequestListItem] {
        viewModel.incomingRequests.map { contact, invite in
            RequestListItem(
                contact: contact,
                title: "Incoming",
                tint: .orange,
                requestCount: invite.requestCount
            )
        }
    }

    private var outgoingRequestItems: [RequestListItem] {
        viewModel.outgoingRequests.map { contact, invite in
            RequestListItem(
                contact: contact,
                title: "Requested",
                tint: .blue,
                requestCount: invite.requestCount
            )
        }
    }

    private func contactStatusPillModel(_ contact: Contact) -> ContactStatusPillModel {
        let isSelected = viewModel.selectedContactId == contact.id
        let conversationState =
            isSelected
            ? viewModel.selectedPeerState(for: contact.id).conversationState
            : viewModel.listConversationState(for: contact.id)
        let summary = viewModel.contactSummary(for: contact.id)

        let text: String

        switch conversationState {
        case .transmitting:
            return ContactStatusPillModel(text: "Talking", tint: .red)
        case .receiving:
            return ContactStatusPillModel(text: "Receiving", tint: .orange)
        case .ready:
            return ContactStatusPillModel(text: "Ready", tint: .green)
        case .waitingForPeer:
            return ContactStatusPillModel(text: "Waiting", tint: .yellow)
        case .requested:
            if let summary, summary.requestCount > 1 {
                text = "Requested \(summary.requestCount)"
            } else {
                text = "Requested"
            }
            return ContactStatusPillModel(text: text, tint: .blue)
        case .incomingRequest:
            if let summary, summary.requestCount > 1 {
                text = "Incoming \(summary.requestCount)"
            } else {
                text = "Incoming"
            }
            return ContactStatusPillModel(text: text, tint: .orange)
        default:
            if contact.isOnline {
                return ContactStatusPillModel(text: "Online", tint: .blue)
            } else {
                return ContactStatusPillModel(text: "Offline", tint: .gray)
            }
        }
    }
}

#Preview {
    ContentView()
}
