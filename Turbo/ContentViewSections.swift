import SwiftUI

struct RequestListItem: Identifiable {
    let contact: Contact
    let title: String
    let tint: Color
    let requestCount: Int

    var id: UUID { contact.id }
}

struct ContactStatusPillModel {
    let text: String
    let tint: Color
}

struct TurboContactListView: View {
    let selectedContactID: UUID?
    let activeContact: Contact?
    let systemSessionSubtitle: String?
    let incomingRequests: [RequestListItem]
    let outgoingRequests: [RequestListItem]
    let contacts: [Contact]
    let statusPill: (Contact) -> ContactStatusPillModel
    let selectContact: (Contact) -> Void
    let endSystemSession: () -> Void

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
                                contact: activeContact,
                                isSelected: true,
                                pill: statusPill(activeContact),
                                onTap: { selectContact(activeContact) }
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

                        if !incomingRequests.isEmpty {
                            sectionHeader("Requests", topPadding: activeContact == nil ? 4 : 8)
                            ForEach(incomingRequests) { item in
                                TurboRequestRow(
                                    item: item,
                                    onTap: { selectContact(item.contact) }
                                )
                            }
                        }

                        if !outgoingRequests.isEmpty {
                            sectionHeader("Requested", topPadding: incomingRequests.isEmpty ? 4 : 8)
                            ForEach(outgoingRequests) { item in
                                TurboRequestRow(
                                    item: item,
                                    onTap: { selectContact(item.contact) }
                                )
                            }
                        }

                        sectionHeader("Contacts", topPadding: 4)
                        ForEach(contacts) { contact in
                            TurboContactRow(
                                contact: contact,
                                isSelected: selectedContactID == contact.id,
                                pill: statusPill(contact),
                                onTap: { selectContact(contact) }
                            )
                        }
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
}

private struct TurboRequestRow: View {
    let item: RequestListItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.contact.name)
                        .font(.body.weight(.semibold))
                    Text(item.contact.handle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(requestBadgeText(title: item.title, requestCount: item.requestCount))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(item.tint.opacity(0.15))
                    .foregroundStyle(item.tint)
                    .clipShape(Capsule())
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct TurboContactRow: View {
    let contact: Contact
    let isSelected: Bool
    let pill: ContactStatusPillModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.body.weight(.semibold))
                    Text(contact.handle)
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
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(primaryActionTint(displayedPrimaryAction.style))
                                    .opacity(displayedPrimaryAction.isEnabled ? 1 : 0.45)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

                    if isSelectedChannelJoined {
                        HStack(spacing: 12) {
                            Text("Audio Route")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            AudioRoutePickerButton()
                                .frame(width: 96, height: 36)
                                .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 4)
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

private func requestBadgeText(title: String, requestCount: Int) -> String {
    guard requestCount > 1 else { return title }
    return "\(title) · \(requestCount)"
}
