import CryptoKit
import Foundation

extension PTTViewModel {
    func provisionMediaEncryptionIdentityForRegistration(
        deviceID: String
    ) -> MediaEncryptionIdentityRegistrationMetadata? {
        mediaEncryptionProvisioningStatus = "provisioning"
        do {
            let identity = try MediaEncryptionIdentityManager.provisionIdentity(deviceID: deviceID)
            mediaEncryptionLocalIdentity = identity
            mediaEncryptionProvisioningStatus = "ready"
            diagnostics.record(
                .media,
                message: "Media encryption identity provisioned",
                metadata: [
                    "deviceId": deviceID,
                    "scheme": identity.registration.scheme,
                    "fingerprint": identity.registration.fingerprint,
                ]
            )
            return identity.registration
        } catch {
            mediaEncryptionProvisioningStatus = "failed"
            diagnostics.record(
                .media,
                level: .error,
                message: "Media encryption identity provisioning failed",
                metadata: [
                    "deviceId": deviceID,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }

    func currentMediaEncryptionIdentityRegistrationMetadata() -> MediaEncryptionIdentityRegistrationMetadata? {
        guard let backend = backendServices else { return mediaEncryptionLocalIdentity?.registration }
        if let existing = mediaEncryptionLocalIdentity,
           existing.registration.fingerprint == MediaEncryptionIdentityManager.fingerprint(
            forPublicKey: existing.privateKey.publicKey.rawRepresentation
           ) {
            return existing.registration
        }
        return provisionMediaEncryptionIdentityForRegistration(deviceID: backend.deviceID)
    }

    func configureMediaEncryptionSessionIfPossible(
        contactID: UUID,
        channelID: String,
        peerDeviceID: String?
    ) {
        guard let localIdentity = mediaEncryptionLocalIdentity else {
            mediaRuntime.setMediaEncryptionSession(nil, for: contactID)
            diagnostics.record(
                .media,
                message: "Media E2EE unavailable because local identity is missing",
                metadata: ["contactId": contactID.uuidString, "channelId": channelID]
            )
            return
        }
        guard let peerDeviceID,
              let peerIdentity = channelReadinessByContactID[contactID]?.peerMediaEncryptionRegistration else {
            mediaRuntime.setMediaEncryptionSession(nil, for: contactID)
            return
        }
        let session = MediaEncryptionSession(
            channelID: channelID,
            localDeviceID: backendServices?.deviceID ?? "",
            peerDeviceID: peerDeviceID,
            localFingerprint: localIdentity.registration.fingerprint,
            peerFingerprint: peerIdentity.fingerprint,
            localPrivateKey: localIdentity.privateKey,
            peerIdentity: peerIdentity
        )
        mediaRuntime.setMediaEncryptionSession(session, for: contactID)
        diagnostics.record(
            .media,
            message: "Configured media E2EE session",
            metadata: [
                "contactId": contactID.uuidString,
                "channelId": channelID,
                "peerDeviceId": peerDeviceID,
                "scheme": peerIdentity.scheme,
                "keyId": session.keyID,
            ]
        )
    }

    func sealOutgoingMediaPayloadIfPossible(
        _ payload: String,
        target: TransmitTarget
    ) throws -> String {
        var session = mediaRuntime.mediaEncryptionSession(for: target.contactID)
        if session == nil, isMediaEncryptionRequired(for: target.contactID) {
            configureMediaEncryptionSessionIfPossible(
                contactID: target.contactID,
                channelID: target.channelID,
                peerDeviceID: target.deviceID
            )
            session = mediaRuntime.mediaEncryptionSession(for: target.contactID)
        }
        guard let session else {
            guard isMediaEncryptionRequired(for: target.contactID) else {
                return payload
            }
            diagnostics.recordInvariantViolation(
                invariantID: "media.e2ee_required_outgoing_session_missing",
                scope: .local,
                message: "outgoing audio could not be sealed while media E2EE is required",
                metadata: [
                    "contactId": target.contactID.uuidString,
                    "channelId": target.channelID,
                    "toDeviceId": target.deviceID,
                ]
            )
            throw MediaEndToEndEncryptionError.requiredSessionUnavailable
        }
        let context = session.context(
            senderDeviceID: session.localDeviceID,
            receiverDeviceID: session.peerDeviceID
        )
        let key = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: session.localPrivateKey,
            peerIdentity: session.peerIdentity,
            context: context
        )
        let sequenceNumber = mediaRuntime.nextMediaEncryptionSendSequence(for: target.contactID)
        return try MediaEndToEndEncryption.sealTransportPayload(
            payload,
            using: key,
            keyID: session.keyID,
            sequenceNumber: sequenceNumber,
            context: context
        )
    }

    func openIncomingMediaPayloadIfPossible(
        _ payload: String,
        channelID: String,
        fromDeviceID: String,
        contactID: UUID
    ) throws -> String? {
        guard MediaEncryptedAudioPacket.isEncodedPacket(payload) else {
            if isMediaEncryptionRequired(for: contactID) {
                diagnostics.recordInvariantViolation(
                    invariantID: "media.e2ee_required_plaintext_audio",
                    scope: .local,
                    message: "plaintext audio arrived while media E2EE is required",
                    metadata: [
                        "contactId": contactID.uuidString,
                        "channelId": channelID,
                        "fromDeviceId": fromDeviceID,
                    ]
                )
                return nil
            }
            return payload
        }
        guard let session = mediaRuntime.mediaEncryptionSession(for: contactID) else {
            diagnostics.record(
                .media,
                level: .error,
                message: "Encrypted media payload arrived without an E2EE session",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                ]
            )
            return nil
        }
        let packet = try MediaEndToEndEncryption.decodePacket(payload)
        let context = session.context(
            senderDeviceID: session.peerDeviceID,
            receiverDeviceID: session.localDeviceID
        )
        let key = try MediaEndToEndEncryption.deriveSymmetricKey(
            localPrivateKey: session.localPrivateKey,
            peerIdentity: session.peerIdentity,
            context: context
        )
        let opened = try MediaEndToEndEncryption.openTransportPayload(
            payload,
            using: key,
            context: context
        )
        guard mediaRuntime.acceptMediaEncryptionReceiveSequence(
            packet.sequenceNumber,
            for: contactID
        ) else {
            diagnostics.recordInvariantViolation(
                invariantID: "media.e2ee_replayed_audio_packet",
                scope: .local,
                message: "encrypted audio packet sequence was replayed or reordered",
                metadata: [
                    "contactId": contactID.uuidString,
                    "channelId": channelID,
                    "fromDeviceId": fromDeviceID,
                    "sequenceNumber": String(packet.sequenceNumber),
                ]
            )
            return nil
        }
        return opened
    }

    private func isMediaEncryptionRequired(for contactID: UUID) -> Bool {
        channelReadinessByContactID[contactID]?.peerMediaEncryptionRegistration != nil
    }
}
