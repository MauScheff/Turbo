import SwiftUI

struct ContactStatusPillModel {
    let text: String
    let tint: Color
}

struct TurboIncomingTalkRequestBanner: View {
    let request: IncomingTalkRequestSurface
    let onDismiss: () -> Void
    let onAccept: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(request.contactName) wants to talk")
                    .font(.body.weight(.semibold))
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if request.requestCount > 1 {
                Text("\(request.requestCount)x")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.14))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }

            Button("Not now", action: onDismiss)
                .buttonStyle(.bordered)

            Button("Accept", action: onAccept)
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
    }

    private var subtitleText: String {
        if request.requestCount > 1 {
            return "\(request.contactHandle) has asked \(request.requestCount) times."
        }
        return "\(request.contactHandle) sent you a talk request."
    }
}

struct TurboContactListView: View {
    let selectedContactID: UUID?
    let activeContact: Contact?
    let systemSessionSubtitle: String?
    let contactSections: ContactListSections
    let activeStatusPill: (Contact) -> ContactStatusPillModel
    let itemStatusPill: (ContactListItem) -> ContactStatusPillModel
    let activeSubtitle: (Contact) -> String
    let itemSubtitle: (ContactListItem) -> String
    let selectContact: (Contact) -> Void
    let showContactDetails: (Contact) -> Void
    let endSystemSession: () -> Void

    private struct ContactRowRenderIdentity: Hashable {
        let contactID: UUID
        let section: ConversationListSection?
        let isSelected: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear
                            .frame(height: 0)
                            .id("contact-list-top")

                        if let activeContact {
                            sectionHeader("Active", topPadding: 4)
                            TurboContactRow(
                                title: activeContact.name,
                                subtitle: activeSubtitle(activeContact),
                                isSelected: true,
                                pill: activeStatusPill(activeContact),
                                onTap: { selectContact(activeContact) },
                                onLongPress: {
                                    selectContact(activeContact)
                                    showContactDetails(activeContact)
                                }
                            )
                            .id(
                                ContactRowRenderIdentity(
                                    contactID: activeContact.id,
                                    section: nil,
                                    isSelected: true
                                )
                            )
                            if let systemSessionSubtitle {
                                TurboSystemSessionRow(
                                    subtitle: systemSessionSubtitle,
                                    onEndSession: endSystemSession
                                )
                            }
                        } else if let systemSessionSubtitle {
                            sectionHeader("Active", topPadding: 4)
                            TurboSystemSessionRow(
                                subtitle: systemSessionSubtitle,
                                onEndSession: endSystemSession
                            )
                        }

                        contactSection(
                            .wantsToTalk,
                            items: contactSections.wantsToTalk,
                            topPadding: activeContact == nil ? 4 : 8
                        )
                        contactSection(
                            .readyToTalk,
                            items: contactSections.readyToTalk,
                            topPadding: contactSections.wantsToTalk.isEmpty ? 4 : 8
                        )
                        contactSection(
                            .requested,
                            items: contactSections.requested,
                            topPadding: contactSections.readyToTalk.isEmpty ? 4 : 8
                        )
                        contactSection(
                            .contacts,
                            items: contactSections.contacts,
                            topPadding: 4
                        )
                    }
                }
            }
            .onChange(of: selectedContactID) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("contact-list-top", anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, topPadding: CGFloat) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topPadding)
    }

    @ViewBuilder
    private func contactSection(
        _ section: ConversationListSection,
        items: [ContactListItem],
        topPadding: CGFloat
    ) -> some View {
        if !items.isEmpty {
            sectionHeader(section.title, topPadding: topPadding)
            ForEach(items) { item in
                let isSelected = selectedContactID == item.contact.id
                TurboContactRow(
                    title: item.contact.name,
                    subtitle: itemSubtitle(item),
                    isSelected: isSelected,
                    pill: itemStatusPill(item),
                    onTap: { selectContact(item.contact) },
                    onLongPress: {
                        selectContact(item.contact)
                        showContactDetails(item.contact)
                    }
                )
                .id(
                    ContactRowRenderIdentity(
                        contactID: item.contact.id,
                        section: section,
                        isSelected: isSelected
                    )
                )
            }
        }
    }

}
private struct TurboContactRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let pill: ContactStatusPillModel
    let onTap: () -> Void
    let onLongPress: (() -> Void)?

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(pill.text)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(pill.tint.opacity(isSelected ? 0.3 : 0.15))
                    .foregroundStyle(pill.tint)
                    .clipShape(Capsule())
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.blue.opacity(0.12) : Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    onLongPress?()
                }
        )
    }
}

private struct TurboSystemSessionRow: View {
    let subtitle: String
    let onEndSession: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("System PTT Session")
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("End Session", action: onEndSession)
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TurboTalkControlsView: View {
    let selectedContactID: UUID?
    let isJoined: Bool
    let activeChannelID: UUID?
    let isTransmitting: Bool
    let isTransmitPressActive: Bool
    let selectedPeerState: (UUID) -> SelectedPeerState
    let requestCooldownRemaining: (UUID, Date) -> Int?
    let joinChannel: () -> Void
    let beginTransmit: () -> Void
    let noteTransmitTouchReleased: () -> Void
    let endTransmit: () -> Void
    @State private var holdToTalkGestureState = HoldToTalkGestureState()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if let selectedContactID {
                VStack(spacing: 12) {
                    let selectedPeerState = selectedPeerState(selectedContactID)
                    let isSelectedChannelJoined = isJoined && activeChannelID == selectedContactID
                    let cooldownRemaining = requestCooldownRemaining(selectedContactID, timeline.date)
                    let primaryAction = ConversationStateMachine.primaryAction(
                        selectedPeerState: selectedPeerState,
                        isSelectedChannelJoined: isSelectedChannelJoined,
                        isTransmitting: isTransmitting,
                        requestCooldownRemaining: cooldownRemaining
                    )
                    let effectiveGestureIsActive = isTransmitPressActive
                    let displayedPrimaryAction = HoldToTalkButtonPolicy.displayAction(
                        primaryAction,
                        gestureIsActive: effectiveGestureIsActive
                    )
                    let shouldRenderHoldToTalkControl = HoldToTalkButtonPolicy.shouldRenderHoldToTalkControl(
                        primaryAction,
                        gestureIsActive: effectiveGestureIsActive
                    )

                    if shouldRenderHoldToTalkControl {
                        Text(displayedPrimaryAction.label)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(primaryActionTint(displayedPrimaryAction.style))
                                    .opacity(displayedPrimaryAction.isEnabled ? 1 : 0.45)
                            )
                            .contentShape(Capsule(style: .continuous))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        guard holdToTalkGestureState.beginIfAllowed(isEnabled: primaryAction.isEnabled) else { return }
                                        beginTransmit()
                                    }
                                    .onEnded { _ in
                                        noteTransmitTouchReleased()
                                        guard holdToTalkGestureState.endTouch() else { return }
                                        endTransmit()
                                    }
                            )
                            .accessibilityAddTraits(.isButton)
                            .opacity(displayedPrimaryAction.isEnabled ? 1 : 0.8)
                    } else {
                        Button(action: joinChannel) {
                            Text(primaryAction.label)
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 72)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(primaryActionTint(primaryAction.style))
                        .disabled(!primaryAction.isEnabled)
                    }

                }
            }
        }
        .onChange(of: selectedContactID) { _, _ in
            if holdToTalkGestureState.cancel() {
                endTransmit()
            }
        }
        .onChange(of: isTransmitPressActive) { _, isActive in
            holdToTalkGestureState.handleMachinePressChanged(isActive: isActive)
        }
        .onChange(of: isJoined) { _, joined in
            if !joined {
                _ = holdToTalkGestureState.cancel()
            }
        }
        .onDisappear {
            if holdToTalkGestureState.cancel() {
                endTransmit()
            }
        }
    }

    private func primaryActionTint(_ style: ConversationPrimaryActionStyle) -> Color {
        switch style {
        case .accent:
            return .blue
        case .active:
            return .red
        case .muted:
            return .gray
        }
    }
}

struct HoldToTalkGestureState: Equatable {
    var isTrackingTouch = false
    var requiresReleaseBeforeNextPress = false

    mutating func beginIfAllowed(isEnabled: Bool) -> Bool {
        guard isEnabled else { return false }
        guard !isTrackingTouch else { return false }
        guard !requiresReleaseBeforeNextPress else { return false }
        isTrackingTouch = true
        return true
    }

    mutating func endTouch() -> Bool {
        let shouldEndTransmit = isTrackingTouch
        isTrackingTouch = false
        requiresReleaseBeforeNextPress = false
        return shouldEndTransmit
    }

    mutating func handleMachinePressChanged(isActive: Bool) {
        if !isActive && isTrackingTouch {
            isTrackingTouch = false
            requiresReleaseBeforeNextPress = true
        }
    }

    mutating func cancel() -> Bool {
        let shouldEndTransmit = isTrackingTouch
        isTrackingTouch = false
        requiresReleaseBeforeNextPress = false
        return shouldEndTransmit
    }
}

enum HoldToTalkButtonPolicy {
    static func shouldRenderHoldToTalkControl(
        _ primaryAction: ConversationPrimaryAction,
        gestureIsActive: Bool
    ) -> Bool {
        gestureIsActive || primaryAction.kind == .holdToTalk
    }

    static func displayAction(
        _ primaryAction: ConversationPrimaryAction,
        gestureIsActive: Bool
    ) -> ConversationPrimaryAction {
        guard shouldRenderHoldToTalkControl(primaryAction, gestureIsActive: gestureIsActive) else {
            return primaryAction
        }
        guard gestureIsActive else {
            return primaryAction
        }
        return ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Release To Stop",
            isEnabled: primaryAction.isEnabled,
            style: .active
        )
    }
}
