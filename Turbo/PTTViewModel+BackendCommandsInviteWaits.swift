//
//  PTTViewModel+BackendCommandsInviteWaits.swift
//  Turbo
//
//  Created by Codex on 13.05.2026.
//

import Foundation

extension PTTViewModel {
    func waitForAcceptedIncomingInviteToDisappear(
        _ acceptedInvite: TurboInviteResponse,
        request: BackendJoinRequest,
        backend: BackendServices
    ) async {
        for attempt in 1 ... 20 {
            do {
                let incomingInvites = try await backend.incomingInvites()
                let stillPending = incomingInvites.contains { $0.inviteId == acceptedInvite.inviteId }
                if !stillPending {
                    diagnostics.record(
                        .backend,
                        message: "Incoming invite acceptance became visible",
                        metadata: [
                            "contactId": request.contactID.uuidString,
                            "handle": request.handle,
                            "attempt": "\(attempt)",
                        ]
                    )
                    return
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "Incoming invite acceptance visibility check failed",
                    metadata: [
                        "contactId": request.contactID.uuidString,
                        "handle": request.handle,
                        "attempt": "\(attempt)",
                        "error": error.localizedDescription,
                    ]
                )
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        diagnostics.record(
            .backend,
            message: "Incoming invite acceptance still pending after visibility wait",
            metadata: [
                "contactId": request.contactID.uuidString,
                "handle": request.handle,
                "inviteId": acceptedInvite.inviteId,
            ]
        )
    }

    func shouldIgnoreInviteNotFoundFailure(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "invite not found"
    }

    func shouldIgnoreIncomingInviteAcceptFailure(_ error: Error) -> Bool {
        shouldIgnoreInviteNotFoundFailure(error)
    }

    func waitForInviteToDisappear(
        inviteID: String,
        contactID: UUID,
        handle: String,
        label: String,
        fetchInvites: @escaping () async throws -> [TurboInviteResponse]
    ) async {
        for attempt in 1 ... 20 {
            do {
                let invites = try await fetchInvites()
                let stillPresent = invites.contains { $0.inviteId == inviteID }
                if !stillPresent {
                    diagnostics.record(
                        .backend,
                        message: "\(label) became visible",
                        metadata: [
                            "contactId": contactID.uuidString,
                            "handle": handle,
                            "attempt": "\(attempt)",
                            "inviteId": inviteID
                        ]
                    )
                    return
                }
            } catch {
                diagnostics.record(
                    .backend,
                    level: .error,
                    message: "\(label) visibility check failed",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "handle": handle,
                        "attempt": "\(attempt)",
                        "inviteId": inviteID,
                        "error": error.localizedDescription
                    ]
                )
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        diagnostics.record(
            .backend,
            message: "\(label) still pending after visibility wait",
            metadata: [
                "contactId": contactID.uuidString,
                "handle": handle,
                "inviteId": inviteID
            ]
        )
    }

    func shouldTreatBackendJoinChannelNotFoundAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel not found"
    }

    func shouldTreatBackendJoinMetadataFailureAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "missing otheruserid or otherhandle"
    }

    func shouldTreatBackendJoinDisconnectedSessionAsRecoverable(_ error: Error) -> Bool {
        guard case let TurboBackendError.server(message) = error else { return false }
        return message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "device session not connected"
    }

    func shouldProceedWithBackendJoinWithoutWebSocket(_ error: Error) -> Bool {
        guard case .webSocketUnavailable = error as? TurboBackendError else { return false }
        return true
    }
}
