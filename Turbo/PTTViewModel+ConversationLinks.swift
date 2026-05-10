import Foundation

extension PTTViewModel {
    func handleConversationOpenIntent(_ intent: ConversationOpenIntent) async {
        var userInfo: [AnyHashable: Any] = [
            "event": "talk-request",
            "fromHandle": intent.reference,
        ]
        if let inviteID = intent.inviteID {
            userInfo["inviteId"] = inviteID
        }
        if let channelID = intent.channelID {
            userInfo["channelId"] = channelID
        }

        switch intent.action {
        case .open:
            if let contact = contactMatchingNormalizedHandleForLink(intent.reference) {
                openCachedConversationContact(contact, reason: "conversation-link-open")
            } else {
                await openContact(reference: intent.reference)
            }

        case .accept:
            await handleTalkRequestNotificationAcceptResponse(userInfo: userInfo)

        case .end:
            if let contact = contactMatchingNormalizedHandleForLink(intent.reference) {
                selectContact(contact)
                requestExpandedCall(for: contact)
                await requestDisconnectSelectedPeer()
            } else {
                await openContact(reference: intent.reference)
            }
        }
    }

    private func contactMatchingNormalizedHandleForLink(_ handle: String) -> Contact? {
        let normalizedHandle = Contact.normalizedHandle(handle)
        return contacts.first { Contact.normalizedHandle($0.handle) == normalizedHandle }
    }

    private func openCachedConversationContact(_ contact: Contact, reason: String) {
        diagnostics.record(
            .app,
            message: "Selected contact from conversation link",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        selectContact(contact)
        requestExpandedCall(for: contact)
    }
}
