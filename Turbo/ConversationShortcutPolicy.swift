import Foundation

/// Client-only UX shortcuts layered on top of the underlying handshake state machine.
/// Keep these switches explicit and persisted so they can be disabled during debugging
/// without changing backend truth or reducer semantics.
struct ConversationShortcutPolicy: Equatable {
    static let requesterAutoJoinOnPeerAcceptanceStorageKey =
        "turbo.shortcuts.requesterAutoJoinOnPeerAcceptance"

    var requesterAutoJoinOnPeerAcceptance: Bool = true

    static func load(from defaults: UserDefaults = .standard) -> ConversationShortcutPolicy {
        guard defaults.object(forKey: requesterAutoJoinOnPeerAcceptanceStorageKey) != nil else {
            return ConversationShortcutPolicy()
        }

        return ConversationShortcutPolicy(
            requesterAutoJoinOnPeerAcceptance: defaults.bool(
                forKey: requesterAutoJoinOnPeerAcceptanceStorageKey
            )
        )
    }

    static func store(_ policy: ConversationShortcutPolicy, to defaults: UserDefaults = .standard) {
        defaults.set(
            policy.requesterAutoJoinOnPeerAcceptance,
            forKey: requesterAutoJoinOnPeerAcceptanceStorageKey
        )
    }
}
