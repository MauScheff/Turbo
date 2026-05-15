import Foundation

enum TalkRequestNotificationIntentAction: String, Equatable {
    case open
    case accept
    case notNow
}

struct TalkRequestNotificationIntent: Equatable {
    let action: TalkRequestNotificationIntentAction
    let inviteID: String?
    let handle: String
    let channelID: String?
    let userIntent: String?
    let sentAt: String?
    let deepLink: URL?

    init?(
        action: TalkRequestNotificationIntentAction,
        userInfo: [AnyHashable: Any]
    ) {
        guard let handle = userInfo["fromHandle"] as? String,
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        self.action = action
        self.inviteID = userInfo["inviteId"] as? String
        self.handle = handle
        self.channelID = userInfo["channelId"] as? String
        self.userIntent = userInfo["userIntent"] as? String
        self.sentAt = (userInfo["sentAt"] as? String) ?? (userInfo["createdAt"] as? String)
        self.deepLink = (userInfo["deepLink"] as? String).flatMap(URL.init(string:))
    }

    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "event": "talk-request",
            "fromHandle": handle,
        ]
        if let inviteID {
            info["inviteId"] = inviteID
        }
        if let channelID {
            info["channelId"] = channelID
        }
        if let userIntent {
            info["userIntent"] = userIntent
        }
        if let sentAt {
            info["sentAt"] = sentAt
        }
        if let deepLink {
            info["deepLink"] = deepLink.absoluteString
        }
        return info
    }
}

enum ConversationOpenIntentAction: String, Equatable {
    case open
    case accept
    case end
}

struct ConversationOpenIntent: Equatable {
    let reference: String
    let inviteID: String?
    let channelID: String?
    let action: ConversationOpenIntentAction

    init?(
        reference: String?,
        inviteID: String? = nil,
        channelID: String? = nil,
        action: ConversationOpenIntentAction = .open
    ) {
        guard let reference,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.reference = reference
        self.inviteID = inviteID
        self.channelID = channelID
        self.action = action
    }
}
