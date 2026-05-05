import Foundation
import Testing
import PushToTalk
import AVFAudio
import UIKit
@testable import BeepBeep

@MainActor
struct TurboTests {
    private func makeDirectQuicNominatedPath(
        attemptID: String = "attempt-1"
    ) -> DirectQuicNominatedPath {
        DirectQuicNominatedPath(
            attemptId: attemptID,
            source: .outboundProbe,
            localPort: 50_000,
            remoteAddress: "203.0.113.20",
            remotePort: 54_321,
            remoteCandidateKind: .serverReflexive
        )
    }

    @Test func audioOutputPreferenceCyclesBetweenSpeakerAndPhone() {
        #expect(AudioOutputPreference.speaker.next == .phone)
        #expect(AudioOutputPreference.phone.next == .speaker)
        #expect(AudioOutputPreference.speaker.buttonLabel == "Speaker")
        #expect(AudioOutputPreference.phone.buttonLabel == "Phone")
    }

    @Test func mediaAudioRouteOptionsAllowCallAndStereoBluetooth() {
        #expect(MediaSessionAudioPolicy.routeCapableOptions.contains(.defaultToSpeaker))
        #expect(MediaSessionAudioPolicy.routeCapableOptions.contains(.allowBluetoothHFP))
        #expect(MediaSessionAudioPolicy.routeCapableOptions.contains(.allowBluetoothA2DP))
    }

    @Test func suggestedProfileNameUsesTwoWordsWithoutDigits() {
        for _ in 0..<32 {
            let candidate = TurboSuggestedProfileName.generate()
            let parts = candidate.split(separator: " ")
            #expect(parts.count == 2)
            #expect(candidate.contains(where: \.isNumber) == false)
        }
    }

    @Test func incomingLinkPublicIDParsesHandleLinkAndDid() {
        #expect(TurboIncomingLink.publicID(from: "maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "@maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://beepbeep.to/maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://beepbeep.to/@maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "https://beepbeep.to/p/maurice") == "@maurice")
        #expect(TurboIncomingLink.publicID(from: "did:web:beepbeep.to:id:maurice") == "@maurice")
    }

    @Test func identityProfileStoreNormalizesWhitespace() {
        let normalized = TurboIdentityProfileStore.normalizedProfileName("  Sunny Otter  ")
        #expect(normalized == "Sunny Otter")
    }

    @Test func handleSuggestionUsesOnlyLowercaseLettersAndNumbers() {
        let suggested = TurboHandle.suggestedEditableBody(from: "Lively Sparrow")
        #expect(suggested == "livelysparrow")
        #expect(TurboHandle.isValidEditableBody(suggested))
    }

    @Test func contactDisplayNamePrefersLocalOverride() {
        var contact = Contact(
            id: UUID(),
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            localName: "Studio Blake"
        )

        #expect(contact.name == "Studio Blake")
        #expect(contact.hasLocalNameOverride)

        contact.localName = nil

        #expect(contact.name == "Blake")
        #expect(contact.hasLocalNameOverride == false)
    }

    @Test func contactAliasStoreScopesAliasesByOwner() {
        let contactID = UUID()
        let firstOwner = "owner-a-\(UUID().uuidString)"
        let secondOwner = "owner-b-\(UUID().uuidString)"

        let stored = TurboContactAliasStore.storeLocalName("  Harbor Blake  ", for: contactID, ownerKey: firstOwner)
        #expect(stored == "Harbor Blake")
        #expect(TurboContactAliasStore.localName(for: contactID, ownerKey: firstOwner) == "Harbor Blake")
        #expect(TurboContactAliasStore.localName(for: contactID, ownerKey: secondOwner) == nil)

        let cleared = TurboContactAliasStore.storeLocalName(nil, for: contactID, ownerKey: firstOwner)
        #expect(cleared == nil)
        #expect(TurboContactAliasStore.localName(for: contactID, ownerKey: firstOwner) == nil)
    }

    @Test func telemetryEventRequestEncodesMetadataTextAndFlagsAsStrings() throws {
        let payload = TurboTelemetryEventRequest(
            eventName: "ios.invariant.violation",
            source: "ios",
            severity: "error",
            metadata: [
                "beta": "2",
                "alpha": "1",
            ],
            devTraffic: true,
            alert: true
        )

        let data = try JSONEncoder().encode(payload)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let json = rawObject as? [String: String]

        #expect(json?["eventName"] == "ios.invariant.violation")
        #expect(json?["source"] == "ios")
        #expect(json?["severity"] == "error")
        #expect(json?["devTraffic"] == "true")
        #expect(json?["alert"] == "true")
        #expect(json?["metadataText"] == #"{"alpha":"1","beta":"2"}"#)
    }

    @Test func telemetryEventRequestPrefersExplicitMetadataText() throws {
        let payload = TurboTelemetryEventRequest(
            eventName: "ios.error.backend",
            source: "ios",
            severity: "error",
            metadata: ["ignored": "value"],
            metadataText: "{\"prebuilt\":\"payload\"}",
            alert: false
        )

        let data = try JSONEncoder().encode(payload)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let json = rawObject as? [String: String]

        #expect(json?["metadataText"] == #"{"prebuilt":"payload"}"#)
        #expect(json?["devTraffic"] == "false")
        #expect(json?["alert"] == "false")
    }

    @Test func apnsEnvironmentResolverUsesInfoPlistValueWhenPresent() {
        #expect(
            TurboAPNSEnvironmentResolver.resolve(
                infoPlistValue: "development",
                fallback: .production
            ) == .development
        )
        #expect(
            TurboAPNSEnvironmentResolver.resolve(
                infoPlistValue: "production",
                fallback: .development
            ) == .production
        )
    }

    @Test func apnsEnvironmentResolverFallsBackForMissingOrInvalidInfoPlistValue() {
        #expect(
            TurboAPNSEnvironmentResolver.resolve(
                infoPlistValue: nil,
                fallback: .development
            ) == .development
        )
        #expect(
            TurboAPNSEnvironmentResolver.resolve(
                infoPlistValue: "sandbox",
                fallback: .production
            ) == .production
        )
    }

    @Test func backendRuntimeConfigDecodesDirectQuicCapabilityAndPolicy() throws {
        let json = """
        {
          "mode": "cloud",
          "supportsWebSocket": true,
          "telemetryEnabled": true,
          "supportsDirectQuicUpgrade": true,
          "supportsDirectQuicProvisioning": true,
          "directQuicPolicy": {
            "stunServers": [
              { "host": "stun1.example.com", "port": 3478 },
              { "host": "stun2.example.com" }
            ],
            "promotionTimeoutMs": 2500,
            "retryBackoffMs": 15000
          }
        }
        """

        let config = try JSONDecoder().decode(
            TurboBackendRuntimeConfig.self,
            from: Data(json.utf8)
        )

        #expect(config.mode == "cloud")
        #expect(config.supportsWebSocket)
        #expect(config.telemetryEnabled == true)
        #expect(config.supportsDirectQuicUpgrade == true)
        #expect(config.supportsDirectQuicProvisioning == true)
        #expect(
            config.directQuicPolicy
                == TurboDirectQuicPolicy(
                    stunServers: [
                        TurboDirectQuicStunServer(host: "stun1.example.com", port: 3478),
                        TurboDirectQuicStunServer(host: "stun2.example.com", port: nil),
                    ],
                    promotionTimeoutMs: 2500,
                    retryBackoffMs: 15000
                )
        )
    }

    @Test func directQuicStunCodecParsesXorMappedAddressResponse() throws {
        let transactionID = Data([
            0x63, 0x61, 0x66, 0x65,
            0x62, 0x61, 0x62, 0x65,
            0x12, 0x34, 0x56, 0x78,
        ])
        let mappedPort: UInt16 = 54_321
        let mappedAddress = [UInt8(203), 0, 113, 20]
        let xoredPort = mappedPort ^ 0x2112
        let xoredAddress = zip(
            mappedAddress,
            [UInt8(0x21), 0x12, 0xA4, 0x42]
        ).map { $0 ^ $1 }

        var response = Data()
        response.append(contentsOf: UInt16(0x0101).bigEndianBytes)
        response.append(contentsOf: UInt16(12).bigEndianBytes)
        response.append(contentsOf: UInt32(0x2112A442).bigEndianBytes)
        response.append(transactionID)
        response.append(contentsOf: UInt16(0x0020).bigEndianBytes)
        response.append(contentsOf: UInt16(8).bigEndianBytes)
        response.append(0x00)
        response.append(0x01)
        response.append(contentsOf: xoredPort.bigEndianBytes)
        response.append(contentsOf: xoredAddress)

        let parsed = try DirectQuicStunCodec.parseBindingResponse(
            response,
            expectedTransactionID: transactionID
        )

        #expect(parsed == DirectQuicStunMappedAddress(address: "203.0.113.20", port: 54_321))
    }

    @Test func directPathDebugOverridePrefersLaunchArgumentsOverEnvironmentAndDefaults() {
        let suiteName = "TurboTests.direct-path-debug-override.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: TurboDirectPathDebugOverride.storageKey)

        #expect(
            TurboDirectPathDebugOverride.isRelayOnlyForced(
                arguments: [TurboDirectPathDebugOverride.launchArgument, "true"],
                environment: [TurboDirectPathDebugOverride.environmentKey: "false"],
                defaults: defaults
            )
        )
        #expect(
            TurboDirectPathDebugOverride.isRelayOnlyForced(
                arguments: [TurboDirectPathDebugOverride.launchArgument, "false"],
                environment: [TurboDirectPathDebugOverride.environmentKey: "true"],
                defaults: defaults
            ) == false
        )
    }

    @Test func directPathDebugOverrideFallsBackFromEnvironmentToDefaults() {
        let suiteName = "TurboTests.direct-path-debug-defaults.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: TurboDirectPathDebugOverride.storageKey)

        #expect(
            TurboDirectPathDebugOverride.isRelayOnlyForced(
                arguments: [],
                environment: [TurboDirectPathDebugOverride.environmentKey: "false"],
                defaults: defaults
            ) == false
        )
        #expect(
            TurboDirectPathDebugOverride.isRelayOnlyForced(
                arguments: [],
                environment: [:],
                defaults: defaults
            )
        )
    }

    @Test func directPathDebugOverrideSupportsAutoUpgradeDisableFlag() {
        let suiteName = "TurboTests.direct-quic-auto-upgrade-override.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: TurboDirectPathDebugOverride.autoUpgradeDisabledStorageKey)

        #expect(
            TurboDirectPathDebugOverride.isAutoUpgradeDisabled(
                arguments: [
                    TurboDirectPathDebugOverride.autoUpgradeDisabledLaunchArgument,
                    "false",
                ],
                environment: [TurboDirectPathDebugOverride.autoUpgradeDisabledEnvironmentKey: "true"],
                defaults: defaults
            ) == false
        )
        #expect(
            TurboDirectPathDebugOverride.isAutoUpgradeDisabled(
                arguments: [],
                environment: [TurboDirectPathDebugOverride.autoUpgradeDisabledEnvironmentKey: "false"],
                defaults: defaults
            ) == false
        )
        #expect(
            TurboDirectPathDebugOverride.isAutoUpgradeDisabled(
                arguments: [],
                environment: [:],
                defaults: defaults
            )
        )
    }

    @Test func directPathDebugOverrideSupportsTransmitStartupPolicyFlag() {
        let suiteName = "TurboTests.direct-quic-transmit-startup-policy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(
            TurboDirectPathDebugOverride.transmitStartupPolicy(
                arguments: [],
                environment: [:],
                defaults: defaults
            ) == .appleGated
        )

        defaults.set(
            DirectQuicTransmitStartupPolicy.speculativeForeground.rawValue,
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        defaults.removeObject(forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageVersionKey)
        #expect(
            TurboDirectPathDebugOverride.transmitStartupPolicy(
                arguments: [],
                environment: [:],
                defaults: defaults
            ) == .appleGated
        )
        #expect(
            defaults.string(forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey)
                == DirectQuicTransmitStartupPolicy.appleGated.rawValue
        )

        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated, defaults: defaults)
        #expect(
            TurboDirectPathDebugOverride.transmitStartupPolicy(
                arguments: [],
                environment: [:],
                defaults: defaults
            ) == .appleGated
        )

        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground, defaults: defaults)
        #expect(
            TurboDirectPathDebugOverride.transmitStartupPolicy(
                arguments: [],
                environment: [:],
                defaults: defaults
            ) == .speculativeForeground
        )
        #expect(
            TurboDirectPathDebugOverride.transmitStartupPolicy(
                arguments: [
                    TurboDirectPathDebugOverride.transmitStartupPolicyLaunchArgument,
                    DirectQuicTransmitStartupPolicy.appleGated.rawValue,
                ],
                environment: [
                    TurboDirectPathDebugOverride.transmitStartupPolicyEnvironmentKey:
                        DirectQuicTransmitStartupPolicy.speculativeForeground.rawValue,
                ],
                defaults: defaults
            ) == .appleGated
        )
    }

    @Test func directQuicIdentityConfigurationPrefersLaunchEnvironmentDefaultsThenBundle() {
        let suiteName = "TurboTests.direct-quic-identity.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("defaults-label", forKey: DirectQuicIdentityConfiguration.storageKey)

        #expect(
            DirectQuicIdentityConfiguration.resolvedLabel(
                arguments: [DirectQuicIdentityConfiguration.launchArgument, "launch-label"],
                environment: [DirectQuicIdentityConfiguration.environmentKey: "env-label"],
                defaults: defaults,
                bundleInfo: [DirectQuicIdentityConfiguration.infoPlistKey: "bundle-label"]
            ) == "launch-label"
        )
        #expect(
            DirectQuicIdentityConfiguration.resolvedLabel(
                arguments: [],
                environment: [DirectQuicIdentityConfiguration.environmentKey: "env-label"],
                defaults: defaults,
                bundleInfo: [DirectQuicIdentityConfiguration.infoPlistKey: "bundle-label"]
            ) == "env-label"
        )
        #expect(
            DirectQuicIdentityConfiguration.resolvedLabel(
                arguments: [],
                environment: [:],
                defaults: defaults,
                bundleInfo: [DirectQuicIdentityConfiguration.infoPlistKey: "bundle-label"]
            ) == "defaults-label"
        )
        defaults.removeObject(forKey: DirectQuicIdentityConfiguration.storageKey)
        #expect(
            DirectQuicIdentityConfiguration.resolvedLabel(
                arguments: [],
                environment: [:],
                defaults: defaults,
                bundleInfo: [DirectQuicIdentityConfiguration.infoPlistKey: "bundle-label"]
            ) == "bundle-label"
        )
    }

    @Test func directQuicIdentityConfigurationPreferredLabelUsesDeviceIDAndSanitizesFallback() {
        #expect(
            DirectQuicIdentityConfiguration.preferredLabel(
                deviceID: "ABC-123",
                fallbackHandle: "@ignored"
            ) == "turbo.direct-quic.identity.abc-123"
        )
        #expect(
            DirectQuicIdentityConfiguration.preferredLabel(
                deviceID: nil,
                fallbackHandle: "@Drift Sparrow"
            ) == "turbo.direct-quic.identity.drift-sparrow"
        )
    }

    @Test func directQuicProductionFingerprintNormalizationRejectsMalformedValues() {
        let uppercase = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        #expect(
            DirectQuicProductionIdentityManager.normalizedFingerprint(uppercase)
                == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        #expect(DirectQuicProductionIdentityManager.normalizedFingerprint("sha256:bad") == nil)
        #expect(
            DirectQuicProductionIdentityManager.normalizedFingerprint(
                "sha256:gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"
            ) == nil
        )
    }

    @Test func channelReadinessDecodesBackendPeerDirectQuicIdentity() throws {
        let json = """
        {
          "channelId": "channel-1",
          "peerUserId": "peer-user",
          "selfHasActiveDevice": true,
          "peerHasActiveDevice": true,
          "readiness": { "kind": "ready" },
          "audioReadiness": {
            "self": { "kind": "ready" },
            "peer": { "kind": "ready" },
            "peerTargetDeviceId": "peer-device"
          },
          "wakeReadiness": {
            "self": { "kind": "unavailable" },
            "peer": { "kind": "unavailable" }
          },
          "peerDirectQuicIdentity": {
            "fingerprint": "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "certificateDerBase64": "AQID",
            "status": "active"
          }
        }
        """

        let readiness = try JSONDecoder().decode(
            TurboChannelReadinessResponse.self,
            from: Data(json.utf8)
        )

        #expect(readiness.peerTargetDeviceId == "peer-device")
        #expect(
            readiness.peerDirectQuicFingerprint
                == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
    }

    @MainActor
    @Test func directQuicAttemptRoleUsesStableDeviceOrdering() {
        let viewModel = PTTViewModel()

        #expect(
            viewModel.directQuicAttemptRole(
                localDeviceID: "device-a",
                peerDeviceID: "device-b"
            ) == .listenerOfferer
        )
        #expect(
            viewModel.directQuicAttemptRole(
                localDeviceID: "device-z",
                peerDeviceID: "device-b"
            ) == .dialerAnswerer
        )
    }

    @MainActor
    @Test func directQuicExpectedPeerCertificateFingerprintPrefersAnswerThenOffer() {
        let contactID = UUID()
        let viewModel = PTTViewModel()
        let candidate = TurboDirectQuicCandidate(
            foundation: "host-a",
            component: "media",
            transport: "udp",
            priority: 100,
            kind: .host,
            address: "203.0.113.10",
            port: 4433,
            relatedAddress: nil,
            relatedPort: nil
        )
        let offerOnlyAttempt = DirectQuicUpgradeAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptId: "attempt-1",
            peerDeviceID: "peer-device",
            startedAt: .distantPast,
            lastUpdatedAt: .distantPast,
            isDirectActive: false,
            remoteOffer: TurboDirectQuicOfferPayload(
                attemptId: "attempt-1",
                channelId: "channel-1",
                fromDeviceId: "peer-device",
                toDeviceId: "local-device",
                quicAlpn: "turbo-ptt",
                certificateFingerprint: "sha256:offer",
                candidates: [candidate],
                roleIntent: .listener
            ),
            remoteAnswer: nil,
            remoteCandidates: [candidate],
            remoteCandidateCount: 1,
            remoteEndOfCandidates: false,
            lastHangupReason: nil
        )
        let answeredAttempt = DirectQuicUpgradeAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptId: "attempt-1",
            peerDeviceID: "peer-device",
            startedAt: .distantPast,
            lastUpdatedAt: .distantPast,
            isDirectActive: false,
            remoteOffer: offerOnlyAttempt.remoteOffer,
            remoteAnswer: TurboDirectQuicAnswerPayload(
                attemptId: "attempt-1",
                accepted: true,
                certificateFingerprint: "sha256:answer",
                candidates: [candidate]
            ),
            remoteCandidates: [candidate],
            remoteCandidateCount: 1,
            remoteEndOfCandidates: false,
            lastHangupReason: nil
        )

        #expect(
            viewModel.directQuicExpectedPeerCertificateFingerprint(for: offerOnlyAttempt)
            == "sha256:offer"
        )
        #expect(
            viewModel.directQuicExpectedPeerCertificateFingerprint(for: answeredAttempt)
            == "sha256:answer"
        )
    }

    @MainActor
    @Test func directQuicCandidateBatchUsesTrickledCandidateOrFallsBackToAccumulatedCandidates() {
        let contactID = UUID()
        let viewModel = PTTViewModel()
        let firstCandidate = TurboDirectQuicCandidate(
            foundation: "host-a",
            component: "media",
            transport: "udp",
            priority: 100,
            kind: .host,
            address: "203.0.113.10",
            port: 4433,
            relatedAddress: nil,
            relatedPort: nil
        )
        let secondCandidate = TurboDirectQuicCandidate(
            foundation: "srflx-b",
            component: "media",
            transport: "udp",
            priority: 99,
            kind: .serverReflexive,
            address: "198.51.100.22",
            port: 51820,
            relatedAddress: "10.0.0.2",
            relatedPort: 4433
        )
        let attempt = DirectQuicUpgradeAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptId: "attempt-1",
            peerDeviceID: "peer-device",
            startedAt: .distantPast,
            lastUpdatedAt: .distantPast,
            isDirectActive: false,
            remoteOffer: nil,
            remoteAnswer: nil,
            remoteCandidates: [firstCandidate, secondCandidate],
            remoteCandidateCount: 2,
            remoteEndOfCandidates: false,
            lastHangupReason: nil
        )

        #expect(
            viewModel.directQuicCandidateBatchToProbe(
                for: attempt,
                payload: TurboDirectQuicCandidatePayload(
                    attemptId: "attempt-1",
                    candidate: secondCandidate
                )
            ) == [secondCandidate]
        )
        #expect(
            viewModel.directQuicCandidateBatchToProbe(
                for: attempt,
                payload: TurboDirectQuicCandidatePayload(
                    attemptId: "attempt-1",
                    candidate: nil,
                    endOfCandidates: true
                )
            ) == [firstCandidate, secondCandidate]
        )
    }

    @Test func directQuicProbeBatchSelectionDistinguishesInFlightViableAndDuplicateCandidates() {
        let viableCandidate = TurboDirectQuicCandidate(
            foundation: "srflx-a",
            component: "media",
            transport: "udp",
            priority: 100,
            kind: .serverReflexive,
            address: "198.51.100.40",
            port: 51820,
            relatedAddress: "10.0.0.4",
            relatedPort: 4433
        )
        let invalidCandidate = TurboDirectQuicCandidate(
            foundation: "tcp-a",
            component: "media",
            transport: "tcp",
            priority: 50,
            kind: .host,
            address: "203.0.113.11",
            port: 4433,
            relatedAddress: nil,
            relatedPort: nil
        )

        let inFlight = DirectQuicProbeController.selectCandidatesForProbeBatch(
            inputCandidates: [viableCandidate],
            attemptedCandidateKeys: [],
            probeInFlight: true
        )
        let noViable = DirectQuicProbeController.selectCandidatesForProbeBatch(
            inputCandidates: [invalidCandidate],
            attemptedCandidateKeys: [],
            probeInFlight: false
        )
        let noNew = DirectQuicProbeController.selectCandidatesForProbeBatch(
            inputCandidates: [viableCandidate],
            attemptedCandidateKeys: [DirectQuicProbeController.candidateKey(viableCandidate)],
            probeInFlight: false
        )
        let ready = DirectQuicProbeController.selectCandidatesForProbeBatch(
            inputCandidates: [invalidCandidate, viableCandidate],
            attemptedCandidateKeys: [],
            probeInFlight: false
        )

        #expect(inFlight == .immediate(
            DirectQuicCandidateProbeOutcome(
                disposition: .probeAlreadyInFlight,
                inputCandidateCount: 1,
                viableCandidateCount: 1,
                newlyAttemptedCandidateCount: 0,
                lastErrorDescription: nil
            )
        ))
        #expect(noViable == .immediate(
            DirectQuicCandidateProbeOutcome(
                disposition: .noViableCandidates,
                inputCandidateCount: 1,
                viableCandidateCount: 0,
                newlyAttemptedCandidateCount: 0,
                lastErrorDescription: nil
            )
        ))
        #expect(noNew == .immediate(
            DirectQuicCandidateProbeOutcome(
                disposition: .noNewCandidates,
                inputCandidateCount: 1,
                viableCandidateCount: 1,
                newlyAttemptedCandidateCount: 0,
                lastErrorDescription: nil
            )
        ))
        #expect(ready == .ready([viableCandidate], viableCandidateCount: 1))
    }

    @Test func directQuicOfferEnvelopeRoundTripsTypedPayload() throws {
        let candidate = TurboDirectQuicCandidate(
            foundation: "host-a",
            component: "rtp",
            transport: "udp",
            priority: 100,
            kind: .host,
            address: "203.0.113.10",
            port: 4433,
            relatedAddress: nil,
            relatedPort: nil
        )
        let payload = TurboDirectQuicOfferPayload(
            attemptId: "attempt-1",
            channelId: "channel-1",
            fromDeviceId: "local-device",
            toDeviceId: "remote-device",
            quicAlpn: "turbo-ptt",
            certificateFingerprint: "sha256:abc123",
            candidates: [candidate],
            roleIntent: .symmetric,
            debugBypass: true
        )
        let envelope = try TurboSignalEnvelope.directQuicOffer(
            channelId: "channel-1",
            fromUserId: "user-a",
            fromDeviceId: "local-device",
            toUserId: "user-b",
            toDeviceId: "remote-device",
            payload: payload
        )

        let decoded = try envelope.decodeDirectQuicSignalPayload()

        #expect(envelope.type == .offer)
        #expect(decoded == .offer(payload))
    }

    @MainActor
    @Test func directQuicDebugBypassOfferCanEnterWhenBackendCapabilityIsDisabled() throws {
        let contactID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: false
            )
        )

        let viewModel = PTTViewModel()
        viewModel.backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: true
        )

        let offer = TurboDirectQuicOfferPayload(
            attemptId: "attempt-1",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: client.deviceID,
            quicAlpn: "turbo-ptt",
            certificateFingerprint: "sha256:abc123",
            candidates: [],
            roleIntent: .listener,
            debugBypass: true
        )
        let envelope = try TurboSignalEnvelope.directQuicOffer(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: client.deviceID,
            payload: offer
        )

        #expect(
            viewModel.shouldAcceptIncomingDirectQuicSignal(
                .offer(offer),
                envelope: envelope,
                contactID: contactID
            )
        )
    }

    @MainActor
    @Test func directQuicOfferWithoutDebugBypassStaysBlockedWhenBackendCapabilityIsDisabled() throws {
        let contactID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: false
            )
        )

        let viewModel = PTTViewModel()
        viewModel.backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: true
        )

        let offer = TurboDirectQuicOfferPayload(
            attemptId: "attempt-1",
            channelId: "channel-1",
            fromDeviceId: "peer-device",
            toDeviceId: client.deviceID,
            quicAlpn: "turbo-ptt",
            certificateFingerprint: "sha256:abc123",
            candidates: [],
            roleIntent: .listener
        )
        let envelope = try TurboSignalEnvelope.directQuicOffer(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: client.deviceID,
            payload: offer
        )

        #expect(
            !viewModel.shouldAcceptIncomingDirectQuicSignal(
                .offer(offer),
                envelope: envelope,
                contactID: contactID
            )
        )
    }

    @MainActor
    @Test func directQuicFollowupSignalForExistingAttemptCanEnterWhenBackendCapabilityIsDisabled() throws {
        let contactID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: false
            )
        )

        let viewModel = PTTViewModel()
        viewModel.backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: true
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )

        let answer = TurboDirectQuicAnswerPayload(
            attemptId: "attempt-1",
            accepted: true,
            certificateFingerprint: "sha256:def456",
            candidates: []
        )
        let envelope = try TurboSignalEnvelope.directQuicAnswer(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: client.deviceID,
            payload: answer
        )

        #expect(
            viewModel.shouldAcceptIncomingDirectQuicSignal(
                .answer(answer),
                envelope: envelope,
                contactID: contactID
            )
        )
    }

    @MainActor
    @Test func directQuicProductionSignalRequiresBackendPeerFingerprintWhenEnabled() throws {
        let contactID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )

        let viewModel = PTTViewModel()
        viewModel.backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: true
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )

        let answer = TurboDirectQuicAnswerPayload(
            attemptId: "attempt-1",
            accepted: true,
            certificateFingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            candidates: []
        )
        let envelope = try TurboSignalEnvelope.directQuicAnswer(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: client.deviceID,
            payload: answer
        )

        #expect(
            !viewModel.shouldAcceptIncomingDirectQuicSignal(
                .answer(answer),
                envelope: envelope,
                contactID: contactID
            )
        )
    }

    @MainActor
    @Test func directQuicProductionSignalRequiresMatchingBackendPeerFingerprint() throws {
        let contactID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )

        let viewModel = PTTViewModel()
        viewModel.backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: true
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerDirectQuicIdentity: TurboDirectQuicPeerIdentityPayload(
                        fingerprint: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                        certificateDerBase64: "AQID",
                        status: "active",
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )

        let answer = TurboDirectQuicAnswerPayload(
            attemptId: "attempt-1",
            accepted: true,
            certificateFingerprint: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            candidates: []
        )
        let envelope = try TurboSignalEnvelope.directQuicAnswer(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: client.deviceID,
            payload: answer
        )

        #expect(
            !viewModel.shouldAcceptIncomingDirectQuicSignal(
                .answer(answer),
                envelope: envelope,
                contactID: contactID
            )
        )
    }

    @MainActor
    @Test func directQuicProductionSignalAcceptsMatchingBackendPeerFingerprint() throws {
        let contactID = UUID()
        let fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )

        let viewModel = PTTViewModel()
        viewModel.backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: true
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerDirectQuicIdentity: TurboDirectQuicPeerIdentityPayload(
                        fingerprint: fingerprint.uppercased(),
                        certificateDerBase64: "AQID",
                        status: "active",
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )

        let answer = TurboDirectQuicAnswerPayload(
            attemptId: "attempt-1",
            accepted: true,
            certificateFingerprint: fingerprint,
            candidates: []
        )
        let envelope = try TurboSignalEnvelope.directQuicAnswer(
            channelId: "channel-1",
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: client.deviceID,
            payload: answer
        )

        #expect(
            viewModel.shouldAcceptIncomingDirectQuicSignal(
                .answer(answer),
                envelope: envelope,
                contactID: contactID
            )
        )
    }

    @Test func directQuicAnswerEnvelopeRoundTripsCertificateFingerprint() throws {
        let payload = TurboDirectQuicAnswerPayload(
            attemptId: "attempt-1",
            accepted: true,
            certificateFingerprint: "sha256:def456",
            candidates: []
        )
        let envelope = try TurboSignalEnvelope.directQuicAnswer(
            channelId: "channel-1",
            fromUserId: "user-b",
            fromDeviceId: "remote-device",
            toUserId: "user-a",
            toDeviceId: "local-device",
            payload: payload
        )

        let decoded = try envelope.decodeDirectQuicSignalPayload()

        #expect(envelope.type == .answer)
        #expect(decoded == .answer(payload))
    }

    @Test func directQuicPayloadRejectsUnsupportedProtocolVersion() throws {
        let envelope = TurboSignalEnvelope(
            type: .answer,
            channelId: "channel-1",
            fromUserId: "user-a",
            fromDeviceId: "local-device",
            toUserId: "user-b",
            toDeviceId: "remote-device",
            payload: """
            {"protocol":"quic-direct-v2","attemptId":"attempt-1","accepted":true,"candidates":[]}
            """
        )

        #expect(throws: TurboDirectQuicPayloadError.self) {
            _ = try envelope.decodeDirectQuicSignalPayload()
        }
    }

    @Test func directQuicUpgradeRuntimeTracksPromotionAndFallback() {
        let contactID = UUID()
        let candidate = TurboDirectQuicCandidate(
            foundation: "srflx-a",
            component: "rtp",
            transport: "udp",
            priority: 101,
            kind: .serverReflexive,
            address: "198.51.100.20",
            port: 51820,
            relatedAddress: "10.0.0.2",
            relatedPort: 51820
        )
        let runtime = DirectQuicUpgradeRuntimeState()

        let promotion = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .offer(
                TurboDirectQuicOfferPayload(
                    attemptId: "attempt-1",
                    channelId: "channel-1",
                    fromDeviceId: "remote-device",
                    toDeviceId: "local-device",
                    quicAlpn: "turbo-ptt",
                    certificateFingerprint: "sha256:def456",
                    candidates: [candidate],
                    roleIntent: .dialer
                )
            )
        )

        #expect(promotion.pathState == .promoting)
        #expect(runtime.attempt(for: contactID)?.remoteCandidateCount == 1)

        let fallback = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .hangup(
                TurboDirectQuicHangupPayload(
                    attemptId: "attempt-1",
                    reason: "probe-timeout"
                )
            )
        )

        #expect(fallback.pathState == .relay)
        #expect(runtime.attempt(for: contactID) == nil)
    }

    @Test func directQuicUpgradeRuntimeDeduplicatesRemoteCandidatesAndTracksEndOfCandidates() {
        let contactID = UUID()
        let candidate = TurboDirectQuicCandidate(
            foundation: "srflx-a",
            component: "media",
            transport: "udp",
            priority: 101,
            kind: .serverReflexive,
            address: "198.51.100.20",
            port: 51820,
            relatedAddress: "10.0.0.2",
            relatedPort: 51820
        )
        let runtime = DirectQuicUpgradeRuntimeState()

        _ = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .answer(
                TurboDirectQuicAnswerPayload(
                    attemptId: "attempt-1",
                    accepted: true,
                    certificateFingerprint: "sha256:def456",
                    candidates: [candidate]
                )
            )
        )
        _ = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .candidate(
                TurboDirectQuicCandidatePayload(
                    attemptId: "attempt-1",
                    candidate: candidate
                )
            )
        )
        _ = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .candidate(
                TurboDirectQuicCandidatePayload(
                    attemptId: "attempt-1",
                    candidate: nil,
                    endOfCandidates: true
                )
            )
        )

        let attempt = runtime.attempt(for: contactID)
        #expect(attempt?.remoteCandidates == [candidate])
        #expect(attempt?.remoteCandidateCount == 1)
        #expect(attempt?.remoteEndOfCandidates == true)
    }

    @Test func directQuicUpgradeRuntimeMarksRecoveringWhenActiveDirectPathIsLost() {
        let contactID = UUID()
        let runtime = DirectQuicUpgradeRuntimeState()

        _ = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .answer(
                TurboDirectQuicAnswerPayload(
                    attemptId: "attempt-1",
                    accepted: true,
                    certificateFingerprint: "sha256:def456",
                    candidates: []
                )
            )
        )

        let direct = runtime.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        #expect(runtime.attempt(for: contactID)?.nominatedPath == makeDirectQuicNominatedPath())

        let recovering = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .hangup(
                TurboDirectQuicHangupPayload(
                    attemptId: "attempt-1",
                    reason: "path-lost"
                )
            )
        )

        #expect(direct?.pathState == .direct)
        #expect(recovering.pathState == .recovering)
        #expect(recovering.reason == "path-lost")
    }

    @Test func directQuicUpgradeRuntimePreservesDirectPathForLateCandidateUpdates() {
        let contactID = UUID()
        let runtime = DirectQuicUpgradeRuntimeState()
        let candidate = TurboDirectQuicCandidate(
            foundation: "host-a",
            component: "media",
            transport: "udp",
            priority: 100,
            kind: .host,
            address: "192.168.1.20",
            port: 51820,
            relatedAddress: nil,
            relatedPort: nil
        )

        _ = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .answer(
                TurboDirectQuicAnswerPayload(
                    attemptId: "attempt-1",
                    accepted: true,
                    certificateFingerprint: "sha256:def456",
                    candidates: []
                )
            )
        )
        let direct = runtime.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        let lateCandidate = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .candidate(
                TurboDirectQuicCandidatePayload(
                    attemptId: "attempt-1",
                    candidate: candidate,
                    endOfCandidates: true
                )
            )
        )

        #expect(direct?.pathState == .direct)
        #expect(lateCandidate.pathState == MediaTransportPathState.direct)
        #expect(runtime.attempt(for: contactID)?.isDirectActive == true)
        #expect(runtime.attempt(for: contactID)?.remoteEndOfCandidates == true)
    }

    @Test func directQuicUpgradeRuntimeFallsBackOnRejectedAnswer() {
        let contactID = UUID()
        let runtime = DirectQuicUpgradeRuntimeState()
        let begin = runtime.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        let fallback = runtime.observeIncomingSignal(
            contactID: contactID,
            channelID: "channel-1",
            signal: .answer(
                TurboDirectQuicAnswerPayload(
                    attemptId: "attempt-1",
                    accepted: false,
                    rejectionReason: "identity-missing"
                )
            )
        )

        #expect(begin.pathState == .promoting)
        #expect(fallback.pathState == .relay)
        #expect(fallback.reason == "identity-missing")
        #expect(runtime.attempt(for: contactID) == nil)
    }

    @Test func directQuicUpgradeRuntimeAppliesRetryBackoffAfterFallback() {
        let contactID = UUID()
        let runtime = DirectQuicUpgradeRuntimeState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        _ = runtime.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device",
            now: start
        )
        let fallback = runtime.clearAttempt(
            for: contactID,
            fallbackReason: "promotion-timeout",
            retryBackoff: DirectQuicRetryBackoffRequest(
                milliseconds: 15_000,
                reason: "promotion-timeout",
                category: .connectivity,
                attemptId: "attempt-1"
            ),
            now: start
        )

        #expect(fallback.pathState == .relay)
        #expect(runtime.canBeginLocalAttempt(for: contactID, now: start.addingTimeInterval(5)) == false)
        #expect(runtime.retryBackoffRemaining(for: contactID, now: start.addingTimeInterval(5)) != nil)
        #expect(
            runtime.retryBackoffState(for: contactID, now: start.addingTimeInterval(5))
                == DirectQuicRetryBackoffState(
                    notBefore: start.addingTimeInterval(15),
                    milliseconds: 15_000,
                    reason: "promotion-timeout",
                    category: .connectivity,
                    attemptId: "attempt-1"
                )
        )
        #expect(runtime.canBeginLocalAttempt(for: contactID, now: start.addingTimeInterval(16)))
        #expect(runtime.retryBackoffRemaining(for: contactID, now: start.addingTimeInterval(16)) == nil)
    }

    @Test func directQuicRetryBackoffPolicyElevatesSecurityAndPeerRejectionReasons() {
        #expect(
            DirectQuicRetryBackoffPolicy.category(for: "promotion-timeout") == .connectivity
        )
        #expect(
            DirectQuicRetryBackoffPolicy.category(for: "peer-certificate-fingerprint-mismatch") == .security
        )
        #expect(
            DirectQuicRetryBackoffPolicy.category(for: "identity-missing") == .peerRejected
        )
        #expect(
            DirectQuicRetryBackoffPolicy.milliseconds(
                baseMilliseconds: 15_000,
                reason: "promotion-timeout"
            ) == 15_000
        )
        #expect(
            DirectQuicRetryBackoffPolicy.milliseconds(
                baseMilliseconds: 15_000,
                reason: "answer-send-failed"
            ) == 30_000
        )
        #expect(
            DirectQuicRetryBackoffPolicy.milliseconds(
                baseMilliseconds: 15_000,
                reason: "peer-certificate-fingerprint-mismatch"
            ) == 60_000
        )
    }

    @Test func directQuicUpgradeRuntimeCanClearRetryBackoffWithoutResettingAttempts() {
        let contactID = UUID()
        let runtime = DirectQuicUpgradeRuntimeState()
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        _ = runtime.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-2",
            attemptID: "attempt-2",
            peerDeviceID: "peer-device",
            now: start
        )
        runtime.applyRetryBackoff(
            for: contactID,
            request: DirectQuicRetryBackoffRequest(
                milliseconds: 15_000,
                reason: "promotion-timeout",
                category: .connectivity,
                attemptId: "attempt-2"
            ),
            now: start
        )

        runtime.clearRetryBackoff(for: contactID)

        #expect(runtime.attempt(for: contactID)?.attemptId == "attempt-2")
        #expect(runtime.retryBackoffState(for: contactID, now: start.addingTimeInterval(1)) == nil)
        #expect(runtime.retryBackoffRemaining(for: contactID, now: start.addingTimeInterval(1)) == nil)
    }

    @Test func directQuicUpgradeRuntimeResetsFastConnectivityRetryCountAfterActivation() {
        let contactID = UUID()
        let runtime = DirectQuicUpgradeRuntimeState()

        #expect(runtime.consumeFastConnectivityRetry(for: contactID, maxAttempts: 2) == 1)
        #expect(runtime.consumeFastConnectivityRetry(for: contactID, maxAttempts: 2) == 2)
        #expect(runtime.consumeFastConnectivityRetry(for: contactID, maxAttempts: 2) == nil)

        _ = runtime.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        _ = runtime.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )

        #expect(runtime.fastConnectivityRetryCount(for: contactID) == 0)
        #expect(runtime.consumeFastConnectivityRetry(for: contactID, maxAttempts: 2) == 1)
    }

    @Test func directQuicWireCodecRoundTripsDelimitedMessages() throws {
        let encodedHello = try DirectQuicWireCodec.encode(.probeHello)
        let encodedAudio = try DirectQuicWireCodec.encode(.audioChunk("payload-1"))
        var buffer = encodedHello + encodedAudio

        let decoded = try DirectQuicWireCodec.decodeAvailable(from: &buffer)

        #expect(decoded == [.probeHello, .audioChunk("payload-1")])
        #expect(buffer.isEmpty)
    }

    @Test func directQuicWireCodecRoundTripsReceiverPrewarmAndWarmPingMessages() throws {
        let payload = DirectQuicReceiverPrewarmPayload(
            requestId: "request-1",
            channelId: "channel-1",
            fromDeviceId: "device-a",
            reason: "test",
            directQuicAttemptId: "attempt-1"
        )
        let encodedRequest = try DirectQuicWireCodec.encode(.receiverPrewarmRequest(payload))
        let encodedAck = try DirectQuicWireCodec.encode(.receiverPrewarmAck(payload))
        let encodedPing = try DirectQuicWireCodec.encode(.warmPing("ping-1"))
        var buffer = encodedRequest + encodedAck + encodedPing

        let decoded = try DirectQuicWireCodec.decodeAvailable(from: &buffer)

        #expect(decoded.count == 3)
        #expect(decoded[0].kind == .receiverPrewarmRequest)
        #expect(try DirectQuicReceiverPrewarmPayloadCodec.decode(decoded[0].payload) == payload)
        #expect(decoded[1].kind == .receiverPrewarmAck)
        #expect(try DirectQuicReceiverPrewarmPayloadCodec.decode(decoded[1].payload) == payload)
        #expect(decoded[2] == .warmPing("ping-1"))
        #expect(buffer.isEmpty)
    }

    @Test func directQuicWireCodecRoundTripsPathClosingMessage() throws {
        let payload = DirectQuicPathClosingPayload(
            attemptId: "attempt-1",
            reason: "app-background-media-closed"
        )
        let encoded = try DirectQuicWireCodec.encode(.pathClosing(payload))
        var buffer = encoded

        let decoded = try DirectQuicWireCodec.decodeAvailable(from: &buffer)

        #expect(decoded.count == 1)
        #expect(decoded[0].kind == .pathClosing)
        #expect(try DirectQuicPathClosingPayloadCodec.decode(decoded[0].payload) == payload)
        #expect(buffer.isEmpty)
    }

    @Test func mediaRuntimeReceiverPrewarmRequestHandlingIsIdempotent() {
        let runtime = MediaRuntimeState()

        #expect(runtime.markReceiverPrewarmRequestHandled("request-1"))
        #expect(!runtime.markReceiverPrewarmRequestHandled("request-1"))
        #expect(runtime.markReceiverPrewarmRequestHandled("request-2"))
    }

    @Test func directQuicWireCodecLeavesPartialFrameBuffered() throws {
        let encoded = try DirectQuicWireCodec.encode(.audioChunk("payload-2"))
        let splitIndex = encoded.index(before: encoded.endIndex)
        var buffer = Data(encoded[..<splitIndex])

        let initialDecode = try DirectQuicWireCodec.decodeAvailable(from: &buffer)
        #expect(initialDecode.isEmpty)
        buffer.append(encoded[splitIndex...])

        let completedDecode = try DirectQuicWireCodec.decodeAvailable(from: &buffer)
        #expect(completedDecode == [.audioChunk("payload-2")])
        #expect(buffer.isEmpty)
    }

    @Test func directQuicWireCodecRoundTripsConsentMessages() throws {
        let encodedPing = try DirectQuicWireCodec.encode(.consentPing("ping-1"))
        let encodedAck = try DirectQuicWireCodec.encode(.consentAck("ping-1"))
        var buffer = encodedPing + encodedAck

        let decoded = try DirectQuicWireCodec.decodeAvailable(from: &buffer)

        #expect(decoded == [.consentPing("ping-1"), .consentAck("ping-1")])
        #expect(buffer.isEmpty)
    }

    @MainActor
    @Test func directQuicTransportSelectionRequiresActivePathAndController() {
        let contactID = UUID()
        let viewModel = PTTViewModel()

        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID) == false)

        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID) == false)

        _ = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))
    }

    @MainActor
    @Test func directQuicForegroundPathLossUsesShortRetryBackoff() async {
        let contactID = UUID()
        let viewModel = PTTViewModel()

        viewModel.applicationStateOverride = .active
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )

        await viewModel.handleDirectQuicMediaPathLost(
            for: contactID,
            attemptID: "attempt-1",
            reason: "consent-timeout"
        )

        #expect(
            viewModel.mediaRuntime.directQuicUpgrade.retryBackoffState(for: contactID)?.milliseconds == 1_000
        )
        #expect(viewModel.diagnostics.latestError == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Direct QUIC media path lost"
            )
        )
    }

    @MainActor
    @Test func directQuicForegroundPromotionConnectivityFailuresUseTwoFastRetries() {
        let contactID = UUID()
        let viewModel = PTTViewModel()

        viewModel.applicationStateOverride = .active
        viewModel.selectedContactId = contactID

        let first = viewModel.directQuicPromotionRetryBackoffRequest(
            for: contactID,
            reason: "promotion-timeout",
            attemptID: "attempt-1"
        )
        let second = viewModel.directQuicPromotionRetryBackoffRequest(
            for: contactID,
            reason: "promotion-timeout",
            attemptID: "attempt-2"
        )
        let third = viewModel.directQuicPromotionRetryBackoffRequest(
            for: contactID,
            reason: "promotion-timeout",
            attemptID: "attempt-3"
        )

        #expect(first?.milliseconds == 1_000)
        #expect(second?.milliseconds == 1_000)
        #expect(third?.milliseconds == 15_000)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Using fast direct QUIC promotion retry"
            )
        )
    }

    @MainActor
    @Test func directQuicAutomaticProbeReadinessDoesNotRequireRelayMediaConnection() {
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "device-a"
            )
        )
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
        #expect(viewModel.automaticDirectQuicProbeBlockReason(for: contactID) == nil)
        #expect(viewModel.shouldRequestAutomaticDirectQuicProbe(for: contactID))
    }

    @MainActor
    @Test func directQuicAutoUpgradeDisableBlocksAutomaticProbeWithoutDisablingManualUpgrade() {
        TurboDirectPathDebugOverride.setRelayOnlyForced(false)
        TurboDirectPathDebugOverride.setAutoUpgradeDisabled(true)
        defer {
            TurboDirectPathDebugOverride.setAutoUpgradeDisabled(false)
            TurboDirectPathDebugOverride.setRelayOnlyForced(false)
        }

        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "device-a"
            )
        )
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        #expect(viewModel.automaticDirectQuicProbeBlockReason(for: contactID) == "auto-upgrade-disabled")
        #expect(!viewModel.shouldRequestAutomaticDirectQuicProbe(for: contactID))
        #expect(viewModel.effectiveDirectQuicUpgradeEnabled)
        #expect(viewModel.selectedDirectQuicDiagnosticsSummary.autoUpgradeDisabled)
        #expect(!viewModel.selectedDirectQuicDiagnosticsSummary.relayOnlyOverride)
    }

    @MainActor
    @Test func directQuicAutomaticProbeIsNoopForAnswererRole() {
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "test-device"
            )
        )
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        #expect(viewModel.automaticDirectQuicProbeBlockReason(for: contactID) == "not-listener-offerer")
        #expect(!viewModel.shouldRequestAutomaticDirectQuicProbe(for: contactID))
    }

    @MainActor
    @Test func directQuicReceiverPrewarmAckMarksFirstTalkReceiverWarm() {
        let contactID = UUID()
        let viewModel = PTTViewModel()
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .waiting
                )
            )
        )

        let payload = DirectQuicReceiverPrewarmPayload(
            requestId: "request-1",
            channelId: "channel",
            fromDeviceId: "peer-device",
            reason: "test",
            directQuicAttemptId: "attempt-1"
        )
        viewModel.handleDirectQuicReceiverPrewarmAck(
            payload,
            contactID: contactID,
            attemptID: "attempt-1"
        )

        #expect(viewModel.mediaRuntime.receiverPrewarmAckRequestIDByContactID[contactID] == "request-1")
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .ready)
        #expect(viewModel.firstTalkReadiness(for: contactID).receiverWarm)
    }

    @MainActor
    @Test func directQuicReceiverPrewarmRequestDoesNotCreateTransmitState() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        let payload = DirectQuicReceiverPrewarmPayload(
            requestId: "request-1",
            channelId: "channel",
            fromDeviceId: "peer-device",
            reason: "test",
            directQuicAttemptId: "attempt-1"
        )
        await viewModel.handleIncomingDirectQuicReceiverPrewarmRequest(
            payload,
            contactID: contactID,
            attemptID: "attempt-1"
        )

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(!viewModel.isTransmitting)
        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Direct QUIC receiver prewarm request received"
            )
        )
    }

    @MainActor
    @Test func provisionalDirectQuicAudioRouteCanBeConfiguredBeforeBackendLease() {
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(
            config: TurboBackendConfig(
                baseURL: URL(string: "http://127.0.0.1:9")!,
                devUserHandle: "@self",
                deviceID: "device-a"
            )
        )
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )
        let viewModel = PTTViewModel()
        viewModel.applyAuthenticatedBackendSession(
            client: client,
            userID: "user-self",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        let configured = viewModel.configureProvisionalDirectQuicOutgoingAudioRouteIfPossible(
            for: request,
            reason: "test"
        )

        #expect(configured)
        #expect(viewModel.mediaRuntime.hasSendAudioChunk)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Configured provisional Direct QUIC outgoing audio route"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Configured outgoing audio transport"
            )
        )
    }

    @MainActor
    @Test func transmitStartupTimingSummaryIncludesFirstAudioStages() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.recordTransmitStartupTiming(
            stage: "system-handoff-requested",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel"
        )
        viewModel.recordTransmitStartupTiming(
            stage: "system-audio-session-activated",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel"
        )
        viewModel.recordTransmitStartupTimingForMediaEvent(
            "Captured local audio buffer",
            metadata: ["frameLength": "4800"]
        )
        viewModel.recordTransmitStartupTimingForMediaEvent(
            "Delivered outbound audio transport payload",
            metadata: ["decodedChunkCount": "1"]
        )
        viewModel.recordTransmitStartupTimingSummary(
            reason: "test",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel"
        )

        let summary = viewModel.diagnostics.entries.first {
            $0.message == "Transmit startup timing summary"
        }
        #expect(summary != nil)
        #expect(summary?.metadata["reason"] == "test")
        #expect(summary?.metadata["system-audio-session-activatedMs"] != nil)
        #expect(summary?.metadata["first-audio-capturedMs"] != nil)
        #expect(summary?.metadata["first-audio-deliveredMs"] != nil)
        #expect(summary?.metadata["appleActivationDeltaMs"] != nil)
        #expect(summary?.metadata["firstAudioTransportDeltaMs"] != nil)
    }

    @MainActor
    @Test func directQuicHangupFromActivePathFallsBackToRelay() async throws {
        let contactID = UUID()
        let channelID = "channel-1"
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )

        let viewModel = PTTViewModel()
        viewModel.backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: true
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: channelID,
                remoteUserId: "user-peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: channelID,
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        _ = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        viewModel.mediaRuntime.updateTransportPathState(.direct)

        let envelope = try TurboSignalEnvelope.directQuicHangup(
            channelId: channelID,
            fromUserId: "user-peer",
            fromDeviceId: "peer-device",
            toUserId: "user-self",
            toDeviceId: client.deviceID,
            payload: TurboDirectQuicHangupPayload(
                attemptId: "attempt-1",
                reason: "peer-ended"
            )
        )

        viewModel.handleIncomingDirectQuicControlSignal(envelope, contactID: contactID)
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.mediaTransportPathState == .relay)
        #expect(viewModel.mediaRuntime.directQuicUpgrade.attempt(for: contactID) == nil)
        #expect(viewModel.mediaRuntime.directQuicProbeController == nil)
    }

    @MainActor
    @Test func directQuicAcceptedAnswerWithoutPeerFingerprintFallsBackToRelay() async {
        let contactID = UUID()
        let channelID = "channel-1"
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )

        let viewModel = PTTViewModel()
        viewModel.backendRuntime.applyAuthenticatedSession(
            client: client,
            userID: "user-self",
            mode: "cloud",
            telemetryEnabled: true
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: channelID,
                remoteUserId: "user-peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: channelID,
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        viewModel.mediaRuntime.updateTransportPathState(.promoting)

        await viewModel.handleDirectQuicAnswer(
            TurboDirectQuicAnswerPayload(
                attemptId: "attempt-1",
                accepted: true,
                certificateFingerprint: nil,
                candidates: []
            ),
            envelope: TurboSignalEnvelope(
                type: .answer,
                channelId: channelID,
                fromUserId: "user-peer",
                fromDeviceId: "peer-device",
                toUserId: "user-self",
                toDeviceId: client.deviceID,
                payload: #"{"protocol":"quic-direct-v1","attemptId":"attempt-1","accepted":true,"candidates":[]}"#
            ),
            contactID: contactID
        )

        #expect(viewModel.mediaTransportPathState == .relay)
        #expect(viewModel.mediaRuntime.directQuicUpgrade.attempt(for: contactID) == nil)
        #expect(viewModel.mediaRuntime.directQuicProbeController == nil)
    }

    @Test func speakerOverridePlanSkipsOverrideWhenSpeakerAlreadyActive() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.builtInSpeaker]
        )

        #expect(!plan.shouldApplySpeakerOverride)
    }

    @Test func speakerOverridePlanRequestsOverrideWhenReceiverIsActive() {
        let plan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.builtInReceiver]
        )

        #expect(plan.shouldApplySpeakerOverride)
    }

    @Test func speakerOverridePlanPreservesBluetoothRoute() {
        let hfpPlan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.bluetoothHFP]
        )
        let a2dpPlan = AudioOutputRouteOverridePlan.forCurrentRoute(
            preference: .speaker,
            category: .playAndRecord,
            outputPortTypes: [.bluetoothA2DP]
        )

        #expect(!hfpPlan.shouldApplySpeakerOverride)
        #expect(!a2dpPlan.shouldApplySpeakerOverride)
    }

    @Test func explicitLeaveBlocksAutoRejoin() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.markExplicitLeave(contactID: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func queueJoinDoesNotOverrideExplicitLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.queueJoin(contactID: contactID)

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: contactID)))
    }

    @Test func globalExplicitLeaveBlocksAutoRejoin() {
        var coordinator = SessionCoordinatorState()

        coordinator.markExplicitLeave(contactID: nil)

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: nil)))
        #expect(coordinator.autoRejoinContactID(afterLeaving: nil) == nil)
    }

    @Test func selectingContactDoesNotClearGlobalExplicitLeave() {
        var coordinator = SessionCoordinatorState()
        let selectedContactID = UUID()

        coordinator.markExplicitLeave(contactID: nil)
        coordinator.select(contactID: selectedContactID)

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: nil)))
    }

    @Test func reconciledTeardownBlocksAutoRejoinUntilLeaveCompletes() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueConnect(contactID: contactID)
        coordinator.markReconciledTeardown(contactID: contactID)

        #expect(coordinator.pendingAction == .leave(.reconciledTeardown(contactID: contactID)))
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func clearLeaveActionResetsMatchingPendingTeardown() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markReconciledTeardown(contactID: contactID)
        coordinator.clearLeaveAction(for: contactID)

        #expect(coordinator == SessionCoordinatorState())
    }

    @Test func clearExplicitLeaveResetsMatchingPendingLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.clearExplicitLeave(for: contactID)

        #expect(coordinator == SessionCoordinatorState())
    }

    @Test func clearExplicitLeaveKeepsOtherPendingLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.clearExplicitLeave(for: UUID())

        #expect(coordinator != SessionCoordinatorState())
        #expect(coordinator.autoRejoinContactID(afterLeaving: contactID) == nil)
    }

    @Test func preservedJoinedChannelRefreshDoesNotClearExplicitLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localSessionEstablished: true,
            localSessionCleared: false
        )

        #expect(coordinator.pendingAction == .leave(.explicit(contactID: contactID)))
    }

    @Test func nonJoinedChannelRefreshClearsExplicitLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.markExplicitLeave(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(
                status: .requested,
                canTransmit: false,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: true
            ),
            localSessionEstablished: false,
            localSessionCleared: true
        )

        #expect(coordinator == SessionCoordinatorState())
    }

    @Test func backendJoinedStateDoesNotClearPendingJoinBeforeLocalSessionEstablishes() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localSessionEstablished: false,
            localSessionCleared: false
        )

        #expect(coordinator.pendingJoinContactID == contactID)
    }

    @Test func localSessionEstablishmentClearsPendingJoinAfterBackendShowsJoined() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.reconcileAfterChannelRefresh(
            for: contactID,
            effectiveChannelState: makeChannelState(status: .ready, canTransmit: true),
            localSessionEstablished: true,
            localSessionCleared: false
        )

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func successfulJoinClearsPendingJoin() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.clearAfterSuccessfulJoin(for: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func clearingPendingJoinWithoutSessionStopsWaitingTransition() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueJoin(contactID: contactID)
        coordinator.clearPendingJoin(for: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func queuedConnectSurvivesUntilRejoinAfterLeave() {
        var coordinator = SessionCoordinatorState()
        let contactID = UUID()

        coordinator.queueConnect(contactID: contactID)

        #expect(coordinator.pendingJoinContactID == nil)
        #expect(coordinator.autoRejoinContactID(afterLeaving: nil) == contactID)
    }

    @Test func selectingContactDoesNotQueueJoin() {
        var coordinator = SessionCoordinatorState()
        let selectedContactID = UUID()
        let pendingContactID = UUID()

        coordinator.queueJoin(contactID: pendingContactID)
        coordinator.select(contactID: selectedContactID)

        #expect(coordinator.pendingJoinContactID == nil)
    }

    @Test func effectiveStateRequiresSystemAndPeerReadiness() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.effectiveState(for: context) == .waitingForPeer)
    }

    @Test func statusMessageReturnsOnlineAfterExplicitLeave() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .leave(.explicit(contactID: contactID)),
            localJoinFailure: nil,
            channel: nil
        )

        #expect(ConversationStateMachine.statusMessage(for: context) == "Blake is online")
    }

    @Test func selectedPeerStateUsesDisconnectingStatusWhileExplicitLeaveIsInFlight() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: false,
                systemSessionState: .none,
                pendingAction: .leave(.explicit(contactID: contactID)),
                localJoinFailure: nil,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Disconnecting...")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateWaitsForRemoteAudioReadinessBeforeEnablingTransmit() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .ready,
                        canTransmit: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .unknown)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Blake's audio...")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateBecomesReadyWhenRemoteAudioReadinessArrives() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
    }

    @Test func selectedPeerStateWaitsForRelayTransportBeforeEnablingTransmit() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                localRelayTransportReady: false,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.detail == .waitingForPeer(reason: .localTransportWarmup))
        #expect(state.statusMessage == "Connecting...")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk == false)
    }

    @Test func selectedPeerStateTreatsDirectPathAsWarmTransport() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                localRelayTransportReady: false,
                directMediaPathActive: true,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
    }

    @MainActor
    @Test func selectedPeerStateUsesWebSocketConnectionForRelayTransportReadiness() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.updateConnectionState(.connected)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        let coldState = viewModel.selectedPeerState(for: contactID)

        #expect(coldState.detail == .waitingForPeer(reason: .localTransportWarmup))
        #expect(coldState.canTransmitNow == false)

        client.setWebSocketConnectionStateForTesting(.connected)

        let warmState = viewModel.selectedPeerState(for: contactID)

        #expect(warmState.phase == .ready)
        #expect(warmState.canTransmitNow)
    }

    @Test func selectedPeerStateWaitsForRemoteAudioWhenWakeCapabilityIsAvailableButRemoteAudioIsNotReady() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .ready,
                        canTransmit: true,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Blake's audio...")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateTrustsBackendReadyWhenRemoteWakeMetadataLags() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
        #expect(state.allowsHoldToTalk)
    }

    @Test func selectedPeerStateWaitsWhenBackendPeerConnectivityLagsDuringBackgrounding() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .idle,
                localMediaWarmupState: .cold,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .waitingForPeer, canTransmit: false),
                    readiness: makeChannelReadiness(
                        status: .waitingForPeer,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Establishing connection...")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateUsesWakeReadyWhenPeerDeviceIsConnectedAndRemotePublishesWakeCapability() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .idle,
                localMediaWarmupState: .cold,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.statusMessage == "Hold to talk to wake Blake")
        #expect(state.canTransmitNow == false)
        #expect(state.allowsHoldToTalk)
    }

    @Test func selectedPeerStateWaitsForRemoteAudioReadinessWhenWakeCapabilityIsUnavailable() {
        let contactID = UUID()
        let state = ConversationStateMachine.selectedPeerState(
            for: ConversationDerivationContext(
                contactID: contactID,
                selectedContactID: contactID,
                baseState: .ready,
                contactName: "Blake",
                contactIsOnline: true,
                isJoined: true,
                activeChannelID: contactID,
                systemSessionMatchesContact: true,
                systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
                pendingAction: .none,
                localJoinFailure: nil,
                mediaState: .connected,
                localMediaWarmupState: .ready,
                channel: ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .unavailable
                    )
                )
            ),
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Blake's audio...")
        #expect(!state.canTransmitNow)
        #expect(!state.allowsHoldToTalk)
    }

    @Test func incomingReceiverReadySignalUpdatesRemoteReadinessState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .waiting)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "test"
            )
        )

        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .ready)
    }

    @Test func backgroundReceiverNotReadySignalUpdatesRemoteReadinessStateToWakeCapable() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .wakeCapable)
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @MainActor
    @Test func backgroundReceiverNotReadySignalRetiresDirectQuicPath() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )
        _ = viewModel.directQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .wakeCapable)

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(!viewModel.shouldUseDirectQuicTransport(for: contactID))
    }

    @MainActor
    @Test func directQuicPathClosingRetiresDirectQuicPathImmediately() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))

        await viewModel.handleIncomingDirectQuicPathClosing(
            DirectQuicPathClosingPayload(
                attemptId: "attempt-1",
                reason: "app-background-media-closed"
            ),
            contactID: contactID,
            attemptID: "attempt-1"
        )

        #expect(!viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(viewModel.diagnosticsTranscript.contains("Direct QUIC path closing received"))
    }

    @MainActor
    @Test func receiverNotReadyBackgroundClosureReleasesLocalInteractivePrewarm() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteAudioReadiness == .wakeCapable)
        #expect(viewModel.channelReadinessByContactID[contactID]?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @MainActor
    @Test func receiverReadySignalResumesLocalInteractivePrewarmAfterBackgroundClosure() async {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverNotReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "app-background-media-closed"
            )
        )

        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "media-connected"
            )
        )

        await Task.yield()
        await Task.yield()

        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @MainActor
    @Test func receiverReadySignalReassertsLocalReceiverReadinessAfterLifecyclePublish() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .waiting,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        var capturedEffects: [ControlPlaneEffect] = []
        viewModel.controlPlaneCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }
        viewModel.localReceiverAudioReadinessPublications[contactID] = ReceiverAudioReadinessPublication(
            isReady: true,
            peerWasRoutable: true,
            basis: .lifecycle
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .receiverReady,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "media-connected"
            )
        )

        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(
            capturedEffects.contains(
                .publishReceiverAudioReadiness(
                    ReceiverAudioReadinessIntent(
                        contactID: contactID,
                        contactHandle: "@blake",
                        backendChannelID: "channel-123",
                        remoteUserID: "peer-user",
                        currentUserID: "self-user",
                        deviceID: client.deviceID,
                        isReady: true,
                        reason: "channel-refresh"
                    )
                )
            )
        )
    }

    @Test func fetchedWaitingReadinessPreservesExistingWakeCapableRemoteState() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .waiting,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
    }

    @Test func fetchedWaitingReadinessPreservesExistingWakeCapabilityWhenRefreshDropsIt() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .waiting,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
        #expect(merged?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @Test func fetchedUnknownReadinessPreservesExistingWakeCapableRemoteState() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
        #expect(merged?.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @Test func fetchedReadyReadinessReplacesExistingWakeCapableRemoteState() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false
        )

        #expect(merged?.remoteAudioReadiness == .ready)
    }

    @Test func fetchedWaitingReadinessDoesNotPreserveWakeCapableWhenPeerDeviceIsConnectedAndBackendIsStillReady() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )
        let fetched = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .waiting,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true
        )

        #expect(merged?.remoteAudioReadiness == .waiting)
    }

    @Test func fetchedWaitingReadinessPreservesWakeCapableWhenPeerConnectivityLagsDuringBackgroundTransition() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )
        let fetched = makeChannelReadiness(
            status: .waitingForPeer,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
        #expect(merged?.remoteWakeCapability == .wakeCapable(targetDeviceId: "device-1"))
    }

    @Test func fetchedWaitingReadinessPreservesWakeCapableWhenLocalSessionRemainsRoutableAfterPeerBackgrounds() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .waitingForPeer,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )
        let fetched = makeChannelReadiness(
            status: .waitingForPeer,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true,
            existingSessionWasRoutable: true
        )

        #expect(merged?.remoteAudioReadiness == .wakeCapable)
        #expect(merged?.remoteWakeCapability == .wakeCapable(targetDeviceId: "device-1"))
    }

    @MainActor
    @Test func effectiveLiveMembershipPreservesWakeCapableFallbackWhenRefreshDropsPeerMembership() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        let existingChannelState = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let regressedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let effectiveChannelState = viewModel.effectiveChannelStatePreservingLiveMembership(
            contactID: contactID,
            existing: existingChannelState,
            incoming: regressedChannelState
        )

        let existingReadiness = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )
        let fetchedReadiness = makeChannelReadiness(
            status: .waitingForPeer,
            peerHasActiveDevice: false,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existingReadiness,
            fetched: fetchedReadiness,
            peerDeviceConnected: effectiveChannelState.membership.peerDeviceConnected,
            peerMembershipPresent: effectiveChannelState.membership.hasPeerMembership,
            existingSessionWasRoutable: true
        )

        #expect(effectiveChannelState.membership == .both(peerDeviceConnected: true))
        #expect(merged?.remoteAudioReadiness == .wakeCapable)
        #expect(merged?.remoteWakeCapability == .wakeCapable(targetDeviceId: "device-1"))
    }

    @Test func fetchedWaitingReadinessDoesNotPreserveStaleWakeCapableWhenExistingSessionWasNotRoutable() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .waitingForPeer,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "device-1")
        )
        let fetched = makeChannelReadiness(
            status: .waitingForPeer,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: true
        )

        #expect(merged?.remoteAudioReadiness == .unknown)
        #expect(merged?.remoteWakeCapability == .unavailable)
    }

    @Test func fetchedUnknownReadinessDoesNotPreserveWakeCapableWhenPeerMembershipIsGone() {
        let viewModel = PTTViewModel()
        let existing = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )
        let fetched = makeChannelReadiness(
            status: .waitingForSelf,
            peerHasActiveDevice: false,
            remoteAudioReadiness: .unknown,
            remoteWakeCapability: .unavailable
        )

        let merged = viewModel.mergedChannelReadinessPreservingWakeCapableFallback(
            existing: existing,
            fetched: fetched,
            peerDeviceConnected: false,
            peerMembershipPresent: false
        )

        #expect(merged?.remoteAudioReadiness == .unknown)
        #expect(merged?.remoteWakeCapability == .unavailable)
    }

    @Test func retainedContactsOnlyKeepAuthoritativeIDs() {
        let avery = Contact(
            id: Contact.stableID(for: "@avery"),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-avery",
            remoteUserId: "user-avery"
        )
        let blake = Contact(
            id: Contact.stableID(for: "@blake"),
            name: "Blake",
            handle: "@blake",
            isOnline: false,
            channelId: UUID(),
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
        )
        let tatum = Contact(
            id: Contact.stableID(for: "@tatum"),
            name: "Tatum",
            handle: "@tatum",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-tatum",
            remoteUserId: "user-tatum"
        )

        let contacts = ContactDirectory.retainedContacts(
            existingContacts: [tatum, blake, avery],
            authoritativeContactIDs: [avery.id, blake.id]
        )

        #expect(contacts.map(\.handle) == ["@avery", "@blake"])
    }

    @Test func authoritativeContactIDsIncludeTrackedSummaryInviteAndActivePeers() {
        let tracked = Set([UUID(), UUID()])
        let summary = UUID()
        let selected = UUID()
        let active = UUID()
        let media = UUID()
        let pending = UUID()
        let invite = UUID()

        let ids = ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: tracked,
            summaryContactIDs: [summary],
            selectedContactID: selected,
            activeChannelID: active,
            mediaSessionContactID: media,
            pendingJoinContactID: pending,
            inviteContactIDs: [invite]
        )

        #expect(ids == tracked.union([summary, selected, active, media, pending, invite]))
    }

    @Test func summaryContactsRemainAuthoritativeWithoutTracking() {
        let summaryOnly = UUID()

        let ids = ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: [],
            summaryContactIDs: [summaryOnly],
            selectedContactID: nil,
            activeChannelID: nil,
            mediaSessionContactID: nil,
            pendingJoinContactID: nil,
            inviteContactIDs: []
        )

        #expect(ids == [summaryOnly])
    }

    @Test func requestContactsRemainAuthoritativeWithoutTracking() {
        let inviteOnly = UUID()

        let ids = ContactDirectory.authoritativeContactIDs(
            trackedContactIDs: [],
            summaryContactIDs: [],
            selectedContactID: nil,
            activeChannelID: nil,
            mediaSessionContactID: nil,
            pendingJoinContactID: nil,
            inviteContactIDs: [inviteOnly]
        )

        #expect(ids == [inviteOnly])
    }

    @Test func backendReadyWithoutLocalSessionDoesNotAutoRestoreWithoutContinuity() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func staleLocalSessionWithoutBackendMembershipTearsDownEvenWhenWakeRecoveryRemainsAvailable() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func wakeActivatedSessionSuppressesDriftTeardownWhileBackendMembershipRecovers() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            incomingWakeActivationState: .systemActivated,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func alignedSessionDoesNotTearDownOnTransientPeerDeparture() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func alignedWaitingForPeerWithPendingRequestDoesNotTearDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func explicitLeaveStillTearsDownWhenSystemSessionClears() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .leave(.explicit(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func recoverableSystemMismatchWithConnectedSessionContinuityDoesNotTearDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedSessionContinuity: true,
            channel: nil
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.durableSession == .transitioning)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedPeerState.phase == .waitingForPeer)
        #expect(projection.selectedPeerState.statusMessage == "Connecting...")
    }

    @Test func pendingJoinSystemMismatchDoesNotTearDownDuringInitialJoin() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.durableSession == .transitioning)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedPeerState.phase == .waitingForPeer)
        #expect(projection.selectedPeerState.statusMessage == "Connecting...")
    }

    @Test func selfJoinedSystemMismatchDoesNotTearDownWhileBackendMembershipStillExists() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.durableSession == .transitioning)
        #expect(projection.reconciliationAction == .none)
        #expect(projection.selectedPeerState.phase == .waitingForPeer)
        #expect(projection.selectedPeerState.statusMessage == "Connecting...")
    }

    @Test func backendInactiveAbsenceWithConnectedSessionContinuityAndWakeCapabilityTearsDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.durableSession == .disconnecting)
        #expect(projection.selectedPeerState.phase == .waitingForPeer)
        #expect(
            projection.selectedPeerState.detail
                == .waitingForPeer(reason: .disconnecting)
        )
        #expect(projection.selectedPeerState.statusMessage == "Disconnecting...")
        #expect(
            projection.reconciliationAction
            == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func terminalSystemMismatchWithoutConnectedSessionContinuityStillTearsDown() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .mismatched(channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.durableSession == .systemMismatch)
        #expect(
            projection.reconciliationAction
                == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func backendAbsenceDoesNotTearDownExplicitlyConnectedLocalSession() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func terminalBackendAbsenceTearsDownConnectedLocalSessionWhenWakeRecoveryIsUnavailable() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func terminalBackendAbsenceTearsDownConnectedLocalSessionWhenOnlyStaleWakeTokenRemains() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func terminalBackendAbsenceTearsDownConnectedLocalSessionDespiteStaleReadyProjection() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
            == .teardownSelectedSession(contactID: contactID)
        )
    }

    @Test func pendingJoinSuppressesDriftTeardownUntilBackendConfirmsMembership() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func stalePendingJoinAllowsRestoreWhenBackendReadyButNoLocalSessionExists() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .restoreLocalSession(contactID: contactID)
        )
    }

    @Test func backendReadyWithoutLocalContinuityDoesNotAutoRestoreUnilaterally() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
        #expect(
            ConversationStateMachine.projection(for: context, relationship: .none).selectedPeerState.phase
                == .peerReady
        )
    }

    @Test func backendReadyWithConnectedSessionContinuityStillAllowsRestore() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                == .restoreLocalSession(contactID: contactID)
        )
    }

    @Test func explicitLeaveWithConnectedSessionContinuitySuppressesAutoRestore() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .leave(.explicit(contactID: contactID)),
            localJoinFailure: nil,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        #expect(
            ConversationStateMachine.reconciliationAction(for: context)
                != .restoreLocalSession(contactID: contactID)
        )
    }

    @Test func channelLimitJoinFailureSuppressesAutomaticRestore() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: PTTJoinFailure(
                contactID: contactID,
                channelUUID: channelUUID,
                reason: .channelLimitReached
            ),
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func activeMatchingSystemSessionSuppressesDuplicateRestore() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func localTransmitSuppressesDriftTeardownDuringBackendWaitingForPeer() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .transmitting,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func peerTransmitSnapshotDoesNotTearDownAlignedLocalSession() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .receiving,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .receiving,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )

        #expect(ConversationStateMachine.reconciliationAction(for: context) == .none)
    }

    @Test func suggestedDevHandlesIncludeCorePeers() {
        #expect(ContactDirectory.suggestedDevHandles.contains("@avery"))
        #expect(ContactDirectory.suggestedDevHandles.contains("@blake"))
        #expect(ContactDirectory.suggestedDevHandles.contains("@turbo-ios"))
    }

    @Test func waitingForPeerPrimaryActionIsDisabled() {
        let action = ConversationStateMachine.primaryAction(
            conversationState: .waitingForPeer,
            isSelectedChannelJoined: true,
            canTransmitNow: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        switch action.kind {
        case .connect:
            break
        case .holdToTalk:
            Issue.record("Expected connect primary action while waiting for peer")
        }
        #expect(action.label == "Waiting for Peer")
        #expect(action.isEnabled == false)
        switch action.style {
        case .muted:
            break
        case .accent, .active:
            Issue.record("Expected muted styling while waiting for peer")
        }
    }

    @Test func idlePrimaryActionUsesRequestLabelWhenTapWillSendRequest() {
        let action = ConversationStateMachine.primaryAction(
            conversationState: .idle,
            isSelectedChannelJoined: false,
            canTransmitNow: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        switch action.kind {
        case .connect:
            break
        case .holdToTalk:
            Issue.record("Expected connect-style primary action while idle")
        }
        #expect(action.label == "Request")
        #expect(action.isEnabled)
        switch action.style {
        case .accent:
            break
        case .muted, .active:
            Issue.record("Expected accent styling for idle request action")
        }
    }

    @Test func selectedPeerStateKeepsOutgoingRequestOutOfWaitingWithoutSessionTransition() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .outgoingRequest(requestCount: 2)
        )

        #expect(state.phase == .requested)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Requested Blake")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateShowsPeerReadyWhenRemoteHasJoinedFirst() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .requested,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: true,
                    requestCount: 1,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.requested.rawValue,
                    canTransmit: false
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .outgoingRequest(requestCount: 1)
        )

        #expect(state.phase == .peerReady)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateShowsPeerReadyAfterInviteHasBeenAccepted() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: true
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .peerReady)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateShowsOnlineWhenRecoverableChannelExistsWithoutMembership() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .idle)
        #expect(state.conversationState == .idle)
        #expect(state.statusMessage == "Blake is online")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateShowsPeerReadyWhenBackendReadinessWaitsForSelfWithoutMembership() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .peerReady)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateShowsPeerReadyWhenWakeCapableRecoveryExistsWithoutMembership() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .peerReady)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateShowsPeerReadyWhenMembershipExistsButReadinessIsInactive() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .inactive,
                    selfHasActiveDevice: false,
                    peerHasActiveDevice: false
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .peerReady)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Blake is ready to connect")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerIdleStateUsesReadyToConnectStatusForBackgroundReachablePeer() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: false,
            contactPresence: .reachable,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .idle)
        #expect(state.statusMessage == "Ready to connect")
    }

    @Test func selectedPeerIdleDisplayStatusUsesOfflineForBackgroundReachablePeer() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Blake",
            contactIsOnline: false,
            contactPresence: .reachable,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.displayStatus == .offline)
    }

    @Test func selectedPeerReadyAndLiveStatesMapToProductStatuses() {
        let readyState = SelectedPeerState(
            relationship: .none,
            detail: .peerReady,
            statusMessage: "Blake is ready to connect",
            canTransmitNow: false
        )
        let liveState = SelectedPeerState(
            relationship: .none,
            detail: .ready,
            statusMessage: "Connected",
            canTransmitNow: true
        )

        #expect(readyState.displayStatus == .ready)
        #expect(liveState.displayStatus == .live)
    }

    @Test func listDisplayStatusUsesReadyForWaitingPeerAndLiveForJoinedSession() {
        #expect(
            ConversationStateMachine.displayStatus(
                for: .waitingForPeer,
                requestCount: nil,
                presence: .offline
            ) == .ready
        )
        #expect(
            ConversationStateMachine.displayStatus(
                for: .ready,
                requestCount: nil,
                presence: .connected
            ) == .live
        )
    }

    @Test func contactListPresentationUsesDedicatedSectionsWithSimplifiedAvailabilityPills() {
        let incoming = ConversationStateMachine.contactListPresentation(
            for: .incomingRequest,
            requestCount: 2,
            presence: .connected
        )
        let ready = ConversationStateMachine.contactListPresentation(
            for: .ready,
            requestCount: nil,
            presence: .reachable
        )
        let requested = ConversationStateMachine.contactListPresentation(
            for: .requested,
            requestCount: 1,
            presence: .connected
        )
        let offline = ConversationStateMachine.contactListPresentation(
            for: .idle,
            requestCount: nil,
            presence: .offline
        )

        #expect(incoming.section == .wantsToTalk)
        #expect(incoming.availabilityPill == .online)
        #expect(incoming.statusPillText() == "Ready")
        #expect(ready.section == .readyToTalk)
        #expect(ready.availabilityPill == .online)
        #expect(ready.statusPillText() == "Online")
        #expect(ready.statusPillText(isActiveConversation: true) == "Connected")
        #expect(requested.section == .requested)
        #expect(requested.availabilityPill == .online)
        #expect(requested.statusPillText() == "Online")
        #expect(offline.section == .contacts)
        #expect(offline.availabilityPill == .offline)
        #expect(offline.statusPillText() == "Offline")
    }

    @Test func selectedPeerStateUsesWaitingDuringPendingJoin() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.joiningLocal(contactID: contactID)),
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Connecting...")
    }

    @Test func selectedPeerStateSurfacesRecoverableLocalJoinFailure() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: PTTJoinFailure(
                contactID: contactID,
                channelUUID: channelUUID,
                reason: .channelLimitReached
            ),
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        let state = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(state.phase == .localJoinFailed)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Reconnect failed. End session and retry.")
    }

    @Test func selectedPeerStateKeepsRequestSubmissionOutOfWaiting() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .requested,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .outgoingRequest(requestCount: 1)
        )

        #expect(state.phase == .requested)
        #expect(state.conversationState == .requested)
        #expect(state.statusMessage == "Requested Avery")
    }

    @Test func selectedPeerStatePreservesConnectingWhileAcceptedIncomingRequestIsStillJoining() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .idle,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            pendingConnectAcceptedIncomingRequest: true,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Connecting...")
        #expect(!state.canTransmitNow)
    }

    @Test func selectedPeerStateSkipsPeerReadyWhileAcceptedIncomingRequestIsStillJoining() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .connect(.requestingBackend(contactID: contactID)),
            pendingConnectAcceptedIncomingRequest: true,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForSelf,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.statusMessage == "Connecting...")
        #expect(!state.canTransmitNow)
    }

    @Test func selectedPeerStateDoesNotReportReadyUntilLocalSessionAligns() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.conversationState == .waitingForPeer)
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateAllowsTransmitWhenSessionIsFullyAligned() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .ready, canTransmit: true),
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .ready)
        #expect(state.conversationState == .ready)
        #expect(state.statusMessage == "Connected")
        #expect(state.canTransmitNow)
    }

    @Test func selectedPeerStateShowsWakeReadyWhenPeerDeviceConnectivityLagsAfterConnectedContinuity() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .wakeReady)
        #expect(state.conversationState == .ready)
        #expect(state.statusMessage == "Hold to talk to wake Avery")
        #expect(state.canTransmitNow == false)
    }

    @Test func selectedPeerStateWaitsWhenPeerIsDisconnectedWithoutWakeCapability() {
        let contactID = UUID()
        let channelUUID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: channelUUID),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .unavailable
                )
            )
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .none
        )

        #expect(state.phase == .waitingForPeer)
        #expect(state.statusMessage == "Waiting for Avery to reconnect")
        #expect(state.canTransmitNow == false)
    }

    @Test func ensureContactClearsStaleBackendChannelMetadataWhenRefreshedWithoutChannel() {
        let staleChannelID = "channel-stale"
        let existing = [
            Contact(
                id: Contact.stableID(for: "@blake"),
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: staleChannelID),
                backendChannelId: staleChannelID,
                remoteUserId: "user-blake"
            )
        ]

        let result = ContactDirectory.ensureContact(
            handle: "@blake",
            remoteUserId: "user-blake-2",
            channelId: "",
            existingContacts: existing
        )

        let refreshed = try! #require(result.contacts.first)
        #expect(refreshed.remoteUserId == "user-blake-2")
        #expect(refreshed.backendChannelId == nil)
        #expect(refreshed.channelId != ContactDirectory.stableChannelUUID(for: staleChannelID))
    }

    @Test func contactStableIDUsesRemoteUserIdAcrossPublicIdChanges() {
        let original = Contact.stableID(remoteUserId: "user-blake", fallbackHandle: "@blake")
        let renamed = Contact.stableID(remoteUserId: "user-blake", fallbackHandle: "maurice")
        let fallbackOnly = Contact.stableID(remoteUserId: nil, fallbackHandle: "@blake")

        #expect(original == renamed)
        #expect(original != fallbackOnly)
    }

    @Test func ensureContactMatchesExistingRemoteUserWhenPublicIdChanges() {
        let existingContactID = Contact.stableID(remoteUserId: "user-blake", fallbackHandle: "@blake")
        let existing = [
            Contact(
                id: existingContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            )
        ]

        let result = ContactDirectory.ensureContact(
            handle: "maurice",
            remoteUserId: "user-blake",
            channelId: "",
            displayName: "Maurice",
            existingContacts: existing
        )

        let refreshed = try! #require(result.contacts.first)
        #expect(result.contacts.count == 1)
        #expect(result.contactID == existingContactID)
        #expect(refreshed.id == existingContactID)
        #expect(refreshed.handle == "@maurice")
        #expect(refreshed.name == "Maurice")
        #expect(refreshed.remoteUserId == "user-blake")
    }

    @Test func ensureContactPreservesExistingProfileNameWhenRefreshOmitsDisplayName() {
        let existingContactID = Contact.stableID(remoteUserId: "user-blake", fallbackHandle: "@blake")
        let existing = [
            Contact(
                id: existingContactID,
                profileName: "Lively Sparrow",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            )
        ]

        let result = ContactDirectory.ensureContact(
            handle: "@blake",
            remoteUserId: "user-blake",
            channelId: "",
            displayName: nil,
            existingContacts: existing
        )

        let refreshed = try! #require(result.contacts.first)
        #expect(result.contacts.count == 1)
        #expect(refreshed.id == existingContactID)
        #expect(refreshed.profileName == "Lively Sparrow")
        #expect(refreshed.name == "Lively Sparrow")
    }

    @Test func backendSyncStateClearsStaleChannelStateWhenContactSummaryHasNoChannel() {
        let contactID = UUID()
        var state = BackendSyncState()
        state.channelStates[contactID] = makeChannelState(status: .ready, canTransmit: true)

        state.applyContactSummaries([
            contactID: TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: nil,
                isOnline: true,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "online"
            )
        ])

        #expect(state.channelStates[contactID] == nil)
    }

    @Test func backendSyncPartialInviteUpdatePreservesUnfetchedDirection() {
        let incomingContactID = UUID()
        let outgoingContactID = UUID()
        var state = BackendSyncSessionState()
        let outgoingInvite = makeInvite(direction: "outgoing", inviteId: "outgoing-1")
        let incomingInvite = makeInvite(
            direction: "incoming",
            inviteId: "incoming-1",
            fromHandle: "@blake",
            toHandle: "@self"
        )

        state.syncState.applyInvites(
            incoming: [:],
            outgoing: [outgoingContactID: outgoingInvite],
            now: .now
        )

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesPartiallyUpdated(
                incoming: [BackendInviteUpdate(contactID: incomingContactID, invite: incomingInvite)],
                outgoing: nil,
                now: .now
            )
        )

        #expect(transition.state.syncState.incomingInvites[incomingContactID]?.inviteId == "incoming-1")
        #expect(transition.state.syncState.outgoingInvites[outgoingContactID]?.inviteId == "outgoing-1")
        #expect(transition.state.syncState.requestContactIDs == [incomingContactID, outgoingContactID])
    }

    @Test func backendSyncPartialOutgoingUpdatePreservesIncomingRequestProjection() {
        let incomingContactID = UUID()
        let outgoingContactID = UUID()
        var state = BackendSyncSessionState()
        let incomingInvite = makeInvite(
            direction: "incoming",
            inviteId: "incoming-1",
            fromHandle: "@blake",
            toHandle: "@self"
        )
        let outgoingInvite = makeInvite(direction: "outgoing", inviteId: "outgoing-1")

        state.syncState.applyInvites(
            incoming: [incomingContactID: incomingInvite],
            outgoing: [:],
            now: .now
        )

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesPartiallyUpdated(
                incoming: nil,
                outgoing: [BackendInviteUpdate(contactID: outgoingContactID, invite: outgoingInvite)],
                now: .now
            )
        )

        #expect(transition.state.syncState.incomingInvites[incomingContactID]?.inviteId == "incoming-1")
        #expect(transition.state.syncState.outgoingInvites[outgoingContactID]?.inviteId == "outgoing-1")
        #expect(transition.state.syncState.requestContactIDs == [incomingContactID, outgoingContactID])
    }

    @Test func selectedPeerReducerKeepsOutgoingRequestRequestedUntilRealTransitionStarts() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let events: [SelectedPeerEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingRequest(requestCount: 2)),
            .baseStateUpdated(.requested),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let state = reduceSelectedPeerState(events)

        #expect(state.selectedPeerState.phase == .requested)
        #expect(state.selectedPeerState.conversationState == .requested)
        #expect(state.selectedPeerState.statusMessage == "Requested Blake")
    }

    @Test func selectedPeerReducerUsesWaitingForPendingJoin() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let events: [SelectedPeerEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .connect(.joiningLocal(contactID: contactID)),
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let state = reduceSelectedPeerState(events)

        #expect(state.selectedPeerState.phase == .waitingForPeer)
        #expect(state.selectedPeerState.statusMessage == "Connecting...")
    }

    @Test func selectedPeerReducerUsesBackendReadyOnlyAfterLocalAlignment() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let waitingEvents: [SelectedPeerEvent] = [
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ]

        let waitingState = reduceSelectedPeerState(waitingEvents)
        #expect(waitingState.selectedPeerState.phase == .waitingForPeer)
        #expect(waitingState.selectedPeerState.canTransmitNow == false)

        let joinedState = SelectedPeerReducer.reduce(
            state: waitingState,
            event: .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: UUID()),
                matchesSelectedContact: true
            )
        ).state
        let readyState = SelectedPeerReducer.reduce(
            state: joinedState,
            event: .mediaStateUpdated(.connected)
        ).state
        let receiverReadyState = SelectedPeerReducer.reduce(
            state: readyState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
                )
            )
        ).state

        #expect(receiverReadyState.selectedPeerState.phase == .ready)
        #expect(receiverReadyState.selectedPeerState.statusMessage == "Connected")
        #expect(receiverReadyState.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerDegradesPreviouslyConnectedSessionToWakeReadyOnSelfOnlyDrift() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let readyState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        #expect(readyState.selectedPeerState.phase == .ready)
        #expect(readyState.hadConnectedSessionContinuity)

        let degradedState = SelectedPeerReducer.reduce(
            state: readyState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForPeer,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            )
        ).state

        #expect(degradedState.selectedPeerState.phase == .wakeReady)
        #expect(degradedState.selectedPeerState.statusMessage == "Hold to talk to wake Avery")
        #expect(degradedState.selectedPeerState.canTransmitNow == false)
        #expect(degradedState.connectedControlPlaneProjection == .wakeReady)
    }

    @Test func selectedPeerReducerPreservesConnectedContinuityAcrossSelectionRefreshes() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let readyState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        #expect(readyState.hadConnectedSessionContinuity)

        let refreshedState = SelectedPeerReducer.reduce(
            state: readyState,
            event: .selectedContactChanged(
                SelectedPeerSelection(
                    contactID: contactID,
                    contactName: "Avery",
                    contactIsOnline: true
                )
            )
        ).state

        #expect(refreshedState.hadConnectedSessionContinuity)
        #expect(refreshedState.selectedPeerState.phase == .ready)
        #expect(refreshedState.selectedPeerState.statusMessage == "Connected")
    }

    @Test func selectedPeerReducerKeepsSelfOnlyHandshakeWaitingBeforeAnyConnectedSessionExists() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForPeer,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.hadConnectedSessionContinuity == false)
        #expect(state.selectedPeerState.phase == .waitingForPeer)
        #expect(state.selectedPeerState.statusMessage == "Connecting...")
        #expect(state.connectedControlPlaneProjection == .unavailable)
    }

    @Test func selectedPeerReducerPrefersTransmitPhaseOverWakeReadyWhileLocallyTransmitting() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.transmitting),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.selectedPeerState.phase == .transmitting)
        #expect(state.selectedPeerState.statusMessage == "Talking to Avery")
    }

    @Test func selectedPeerReducerStoresLayeredProjectionForConnectedTransmit() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .transmitting, canTransmit: false),
                    readiness: makeChannelReadiness(
                        status: .selfTransmitting(activeTransmitterUserId: "self"),
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.transmitting),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.durableSessionProjection == .connected)
        #expect(state.connectedExecutionProjection == .transmitting)
        #expect(state.connectedControlPlaneProjection == .transmitting)
        #expect(state.selectedPeerState.phase == .transmitting)
    }

    @Test func selectedPeerReducerUsesWakePhaseWhileLocalTransmitIsStillStarting() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .ready, canTransmit: true),
                    readiness: makeChannelReadiness(
                        status: .ready,
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.starting(.awaitingSystemTransmit)),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.idle)
        ])

        #expect(state.selectedPeerState.phase == .startingTransmit)
        #expect(state.selectedPeerState.detail == .startingTransmit(stage: .awaitingSystemTransmit))
        #expect(state.selectedPeerState.statusMessage == "Waking Avery...")
    }

    @Test func selectedPeerReducerKeepsTransmitPhaseWhilePeerConnectivityDriftsMidTransmit() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .transmitting,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .selfTransmitting(activeTransmitterUserId: "self"),
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.transmitting),
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: channelUUID),
                matchesSelectedContact: true
            ),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.selectedPeerState.phase == SelectedPeerPhase.transmitting)
        #expect(state.selectedPeerState.statusMessage == "Talking to Avery")
    }

    @Test func selectedPeerReducerUsesStoppingStatusWhileExplicitStopIsInFlight() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(status: .transmitting, canTransmit: false),
                    readiness: makeChannelReadiness(
                        status: .selfTransmitting(activeTransmitterUserId: "self"),
                        remoteAudioReadiness: .wakeCapable,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .localTransmitUpdated(.stopping),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true),
            .mediaStateUpdated(.connected)
        ])

        #expect(state.selectedPeerState.phase == .waitingForPeer)
        #expect(state.selectedPeerState.detail == .waitingForPeer(reason: .localSessionTransition))
        #expect(state.selectedPeerState.statusMessage == "Stopping...")
        #expect(state.selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerReducerJoinRequestEmitsConnectForJoinableSelection() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.outgoingRequest(requestCount: 1)),
            .baseStateUpdated(.requested),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.requestConnection(contactID: contactID)])
    }

    @Test func selectedPeerReducerJoinRequestEmitsJoinReadyPeerForPeerReadySelection() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.joinReadyPeer(contactID: contactID)])
    }

    @Test func selectedPeerReducerArmsRequesterAutoJoinShortcutForOutgoingRequest() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.requestConnection(contactID: contactID)])
        #expect(transition.state.requesterAutoJoinOnPeerAcceptanceArmed)
    }

    @Test func selectedPeerReducerDoesNotArmRequesterAutoJoinShortcutWhenAcceptingIncomingRequest() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.incomingRequest(requestCount: 1)),
            .baseStateUpdated(.incomingRequest),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.requestConnection(contactID: contactID)])
        #expect(!transition.state.requesterAutoJoinOnPeerAcceptanceArmed)
    }

    @Test func selectedPeerReducerAutoJoinsPeerReadyWhenRequesterShortcutIsArmed() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let transition = SelectedPeerReducer.reduce(
            state: armedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(transition.effects == [.joinReadyPeer(contactID: contactID)])
        #expect(!transition.state.requesterAutoJoinOnPeerAcceptanceArmed)
        #expect(transition.state.selectedPeerState.phase == .waitingForPeer)
        #expect(transition.state.selectedPeerState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerDoesNotAutoJoinPeerReadyWhenRequesterShortcutIsDisabled() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        var seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: false),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])
        seededState.requesterAutoJoinOnPeerAcceptanceArmed = true

        let transition = SelectedPeerReducer.reduce(
            state: seededState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(transition.effects.isEmpty)
        #expect(transition.state.selectedPeerState.phase == .peerReady)
    }

    @Test func selectedPeerReducerKeepsConnectingWhileRequesterAutoJoinAwaitingAcceptanceVisibility() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let transition = SelectedPeerReducer.reduce(
            state: armedState,
            event: .relationshipUpdated(.none)
        )

        #expect(transition.effects.isEmpty)
        #expect(transition.state.selectedPeerState.phase == .waitingForPeer)
        #expect(transition.state.selectedPeerState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerClearsRequesterAutoJoinShortcutWhenBackendFallsBackToAbsentChannelWithoutRequest() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        var armedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state
        armedState.requesterAutoJoinOnPeerAcceptanceDispatchInFlight = true

        let transition = SelectedPeerReducer.reduce(
            state: armedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .idle,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(!transition.state.requesterAutoJoinOnPeerAcceptanceArmed)
        #expect(!transition.state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight)
        #expect(transition.effects.isEmpty)
        #expect(transition.state.selectedPeerState.phase == .idle)
        #expect(transition.state.selectedPeerState.statusMessage == "Blake is online")
    }

    @Test func selectedPeerReducerKeepsRequesterAutoJoinArmedAcrossAcceptedButNotYetPeerReadyGap() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let requestedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state
        let armedState = SelectedPeerReducer.reduce(
            state: requestedState,
            event: .relationshipUpdated(.none)
        ).state

        let acceptedButNotYetPeerReady = SelectedPeerReducer.reduce(
            state: armedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .idle,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(acceptedButNotYetPeerReady.effects.isEmpty)
        #expect(acceptedButNotYetPeerReady.state.requesterAutoJoinOnPeerAcceptanceArmed)
        #expect(!acceptedButNotYetPeerReady.state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight)
        #expect(acceptedButNotYetPeerReady.state.selectedPeerState.phase == .waitingForPeer)
        #expect(acceptedButNotYetPeerReady.state.selectedPeerState.statusMessage == "Connecting...")
    }

    @Test func selectedPeerReducerSkipsPeerReadyFlashWhileRequesterAutoJoinIsArmed() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let acceptedState = SelectedPeerReducer.reduce(
            state: armedState,
            event: .relationshipUpdated(.none)
        ).state

        let transition = SelectedPeerReducer.reduce(
            state: acceptedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(transition.effects == [.joinReadyPeer(contactID: contactID)])
        #expect(transition.state.selectedPeerState.phase == .waitingForPeer)
        #expect(transition.state.selectedPeerState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerSkipsPeerReadyFlashEvenIfOutgoingRequestRelationshipHasNotClearedYet() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.outgoingRequest(requestCount: 1)),
                .baseStateUpdated(.requested),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let transition = SelectedPeerReducer.reduce(
            state: armedState,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(transition.effects == [.joinReadyPeer(contactID: contactID)])
        #expect(transition.state.selectedPeerState.phase == .waitingForPeer)
        #expect(transition.state.selectedPeerState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerAtomicSyncSkipsPeerReadyFlashWhileRequesterAutoJoinIsArmed() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.outgoingRequest(requestCount: 1)),
                .baseStateUpdated(.requested),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let transition = SelectedPeerReducer.reduce(
            state: armedState,
            event: .syncUpdated(
                SelectedPeerSyncSnapshot(
                    selection: selection,
                    relationship: .outgoingRequest(requestCount: 1),
                    baseState: .requested,
                    channel: ChannelReadinessSnapshot(
                        channelState: makeChannelState(
                            status: .waitingForPeer,
                            canTransmit: false,
                            selfJoined: false,
                            peerJoined: true,
                            peerDeviceConnected: false
                        )
                    ),
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    requesterAutoJoinOnPeerAcceptanceEnabled: true,
                    localTransmit: .idle,
                    peerSignalIsTransmitting: false,
                    systemSessionState: .none,
                    systemSessionMatchesContact: false,
                    mediaState: .idle,
                    localRelayTransportReady: true,
                    directMediaPathActive: false,
                    incomingWakeActivationState: nil,
                    localJoinFailure: nil
                )
            )
        )

        #expect(transition.effects == [.joinReadyPeer(contactID: contactID)])
        #expect(transition.state.selectedPeerState.phase == .waitingForPeer)
        #expect(transition.state.selectedPeerState.statusMessage == "Connecting...")
        #expect(!transition.state.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerKeepsConnectingAfterRequesterAutoJoinEffectDispatchUntilLocalJoinReflects() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let readyTransition = SelectedPeerReducer.reduce(
            state: SelectedPeerReducer.reduce(
                state: armedState,
                event: .relationshipUpdated(.none)
            ).state,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        #expect(readyTransition.effects == [.joinReadyPeer(contactID: contactID)])
        #expect(readyTransition.state.selectedPeerState.phase == .waitingForPeer)
        #expect(readyTransition.state.selectedPeerState.statusMessage == "Connecting...")

        let bridgedTransition = SelectedPeerReducer.reduce(
            state: readyTransition.state,
            event: .baseStateUpdated(.idle)
        )

        #expect(bridgedTransition.effects.isEmpty)
        #expect(bridgedTransition.state.selectedPeerState.phase == .waitingForPeer)
        #expect(bridgedTransition.state.selectedPeerState.statusMessage == "Connecting...")
        #expect(!bridgedTransition.state.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerKeepsConnectingWhileRequesterAutoJoinBackendConnectIsQueued() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let armedState = SelectedPeerReducer.reduce(
            state: reduceSelectedPeerState([
                .selectedContactChanged(selection),
                .relationshipUpdated(.none),
                .baseStateUpdated(.idle),
                .channelUpdated(nil),
                .localSessionUpdated(
                    isJoined: false,
                    activeChannelID: nil,
                    pendingAction: .none,
                    pendingConnectAcceptedIncomingRequest: false,
                    localJoinFailure: nil
                ),
                .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true),
                .systemSessionUpdated(.none, matchesSelectedContact: false)
            ]),
            event: .joinRequested
        ).state

        let readyTransition = SelectedPeerReducer.reduce(
            state: SelectedPeerReducer.reduce(
                state: armedState,
                event: .relationshipUpdated(.none)
            ).state,
            event: .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: true
                    )
                )
            )
        )

        let queuedBackendConnect = SelectedPeerReducer.reduce(
            state: readyTransition.state,
            event: .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .connect(.requestingBackend(contactID: contactID)),
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            )
        )

        #expect(queuedBackendConnect.effects.isEmpty)
        #expect(queuedBackendConnect.state.selectedPeerState.phase == .waitingForPeer)
        #expect(queuedBackendConnect.state.selectedPeerState.statusMessage == "Connecting...")
        #expect(!queuedBackendConnect.state.selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerReducerJoinRequestEmitsJoinReadyPeerForRecoverableChannelWithoutMembership() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: true,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        #expect(seededState.selectedPeerState.phase == .peerReady)

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .joinRequested)

        #expect(transition.effects == [.joinReadyPeer(contactID: contactID)])
    }

    @Test func selectedPeerReducerProjectsPeerReadyFromWaitingForSelfChannelWithoutMembership() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForSelf,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .unavailable
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        #expect(state.selectedPeerState.phase == .peerReady)
    }

    @Test func selectedPeerReducerDisconnectRequestEmitsDisconnectForPendingJoin() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.idle),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .connect(.joiningLocal(contactID: contactID)),
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .disconnectRequested)

        #expect(transition.effects == [.disconnect(contactID: contactID)])
    }

    @Test func selectedPeerReducerDisconnectRequestSkipsDuplicateDisconnectDuringExplicitLeave() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .leave(.explicit(contactID: contactID)),
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .disconnectRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedPeerReducerReconcileRequestEmitsRestoreEffectWhenContinuityExists() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        var seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])
        seededState.hadConnectedSessionContinuity = true

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.restoreLocalSession(contactID: contactID)])
    }

    @Test func selectedPeerReducerReconcileRequestSkipsRestoreWhenSystemSessionAlreadyMatches() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedPeerReducerReconcileRequestSkipsDuplicateTeardownDuringExplicitLeave() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.ready),
            .channelUpdated(ChannelReadinessSnapshot(channelState: makeChannelState(status: .ready, canTransmit: true))),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .leave(.explicit(contactID: contactID)),
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedPeerReducerReconcileRequestSkipsDuplicateTeardownWhileTeardownIsInFlight() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: true,
                        peerJoined: false,
                        peerDeviceConnected: false
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .leave(.reconciledTeardown(contactID: contactID)),
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: UUID()), matchesSelectedContact: true)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects.isEmpty)
    }

    @Test func selectedPeerReducerReconcileRequestTeardownsTerminalBackendAbsence() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForSelf,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .unavailable
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.teardownLocalSession(contactID: contactID)])
    }

    @Test func selectedPeerReducerReconcileRequestTeardownsTerminalBackendAbsenceWithOnlyStaleWakeToken() {
        let contactID = UUID()
        let channelUUID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Avery",
            contactIsOnline: true
        )

        let seededState = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.none),
            .baseStateUpdated(.waitingForPeer),
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: false,
                        peerDeviceConnected: false
                    ),
                    readiness: makeChannelReadiness(
                        status: .waitingForSelf,
                        peerHasActiveDevice: false,
                        remoteAudioReadiness: .unknown,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            ),
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.active(contactID: contactID, channelUUID: channelUUID), matchesSelectedContact: true)
        ])

        let transition = SelectedPeerReducer.reduce(state: seededState, event: .reconcileRequested)

        #expect(transition.effects == [.teardownLocalSession(contactID: contactID)])
    }

    @Test func peerReadyPrimaryActionAllowsConnect() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .outgoingRequest(requestCount: 1),
                phase: .peerReady,
                statusMessage: "Blake is ready to connect",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: 20
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Connect")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func idleSelectedPeerPrimaryActionUsesRequestLabel() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .none,
                phase: .idle,
                statusMessage: "Blake is online",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Request")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func localJoinFailedPrimaryActionStaysDisabled() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .none,
                phase: .localJoinFailed,
                statusMessage: "Reconnect failed. End session and retry.",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.isEnabled == false)
        #expect(action.style == .muted)
    }

    @Test func blockedRequestedPrimaryActionAllowsRequestAgainAfterCooldownExpires() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .outgoingRequest(requestCount: 1),
                phase: .blockedByOtherSession,
                statusMessage: "Another session is active",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Request Again")
        #expect(action.isEnabled)
        #expect(action.style == .muted)
    }

    @Test func requestedPrimaryActionReenablesAndRestylesAfterCooldownExpires() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .outgoingRequest(requestCount: 1),
                phase: .requested,
                statusMessage: "Requested Blake",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Request Again")
        #expect(action.isEnabled)
        #expect(action.style == .accent)
    }

    @Test func blockedRequestedPrimaryActionStaysDisabledDuringCooldown() {
        let action = ConversationStateMachine.primaryAction(
            selectedPeerState: SelectedPeerState(
                relationship: .outgoingRequest(requestCount: 1),
                phase: .blockedByOtherSession,
                statusMessage: "Another session is active",
                canTransmitNow: false
            ),
            isSelectedChannelJoined: false,
            isTransmitting: false,
            requestCooldownRemaining: 12
        )

        #expect(action.kind == .connect)
        #expect(action.label == "Request again in 12s")
        #expect(action.isEnabled == false)
        #expect(action.style == .muted)
    }

    @Test func selectedPeerReducerClearsStateOnDeselection() {
        let contactID = UUID()
        let selection = SelectedPeerSelection(
            contactID: contactID,
            contactName: "Blake",
            contactIsOnline: true
        )

        let state = reduceSelectedPeerState([
            .selectedContactChanged(selection),
            .relationshipUpdated(.incomingRequest(requestCount: 1)),
            .baseStateUpdated(.incomingRequest),
            .channelUpdated(nil),
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            ),
            .systemSessionUpdated(.none, matchesSelectedContact: false),
            .selectedContactChanged(nil)
        ])

        #expect(state.selection == nil)
        #expect(state.selectedPeerState.phase == .idle)
        #expect(state.reconciliationAction == .none)
    }

    @Test func listConversationStatePrefersIncomingRequestOverSummaryBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel",
            isOnline: true,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 3,
            isActiveConversation: false,
            badgeStatus: "ready"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .incomingRequest)
    }

    @Test func relationshipStateRepresentsSimultaneousIncomingAndOutgoingRequests() {
        let relationship = ConversationStateMachine.relationshipState(
            hasIncomingRequest: true,
            hasOutgoingRequest: true,
            requestCount: 2
        )

        #expect(relationship == .mutualRequest(requestCount: 2))
        #expect(relationship.isIncomingRequest)
        #expect(relationship.isOutgoingRequest)
        #expect(relationship.fallbackConversationState == .incomingRequest)
    }

    @Test func selectedPeerStateTreatsMutualRequestsAsAcceptableIncomingRequest() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .incomingRequest,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: false,
            activeChannelID: nil,
            systemSessionMatchesContact: false,
            systemSessionState: .none,
            pendingAction: .none,
            localJoinFailure: nil,
            channel: nil
        )

        let state = ConversationStateMachine.selectedPeerState(
            for: context,
            relationship: .mutualRequest(requestCount: 2)
        )

        #expect(state.phase == .incomingRequest)
        #expect(state.relationship == .mutualRequest(requestCount: 2))
        #expect(state.conversationState == .incomingRequest)
        #expect(state.statusMessage == "Blake wants to talk")
    }

    @Test func contactSummaryTypedProjectionExposesMutualRequestRelationshipAndBadgeState() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel",
            isOnline: true,
            hasIncomingRequest: true,
            hasOutgoingRequest: true,
            requestCount: 2,
            isActiveConversation: true,
            badgeStatus: ConversationState.ready.rawValue
        )

        #expect(summary.requestRelationship == .mutual(requestCount: 2))
        #expect(summary.badge == .ready)
        #expect(summary.badge.conversationState == .ready)
    }

    @Test func channelStateTypedProjectionExposesMembershipAndRequestRelationship() {
        let channelState = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: false,
            hasIncomingRequest: false,
            hasOutgoingRequest: true,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.waitingForPeer.rawValue,
            canTransmit: false
        )

        #expect(channelState.membership == .both(peerDeviceConnected: false))
        #expect(channelState.requestRelationship == .outgoing(requestCount: 1))
        #expect(channelState.conversationStatus == .waitingForPeer)
    }

    @Test func contactSummaryDecodesNestedRequestRelationshipProjection() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "requestRelationship": {
                "kind": "mutual",
                "requestCount": 3
              },
              "summaryStatus": {
                "kind": "incoming",
                "activeTransmitterUserId": null
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.requestRelationship == .mutual(requestCount: 3))
        #expect(summary.membership == .peerOnly(peerDeviceConnected: true))
        #expect(summary.badge == .incoming)
        #expect(summary.badgeKind == "incoming")
        #expect(summary.badge.conversationState == .incomingRequest)
    }

    @Test func userLookupDecodesPublicIdentityFields() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@legacy",
              "publicId": "maurice",
              "displayName": "Maurice",
              "profileName": "Maurice",
              "shareCode": "@maurice",
              "shareLink": "https://beepbeep.to/maurice",
              "did": "did:web:beepbeep.to:id:maurice",
              "subjectKind": "agent"
            }
            """.utf8
        )

        let user = try JSONDecoder().decode(TurboUserLookupResponse.self, from: data)

        #expect(user.handle == "@legacy")
        #expect(user.publicId == "maurice")
        #expect(user.profileName == "Maurice")
        #expect(user.shareCode == "@maurice")
        #expect(user.shareLink == "https://beepbeep.to/maurice")
        #expect(user.did == "did:web:beepbeep.to:id:maurice")
        #expect(user.subjectKind == "agent")
    }

    @Test func incomingLinkParsesCanonicalSharePage() {
        let url = URL(string: "https://beepbeep.to/maurice?utm_source=test#card")!

        #expect(TurboIncomingLink.reference(from: url) == "https://beepbeep.to/maurice")
    }

    @Test func incomingLinkParsesCustomSchemeSharePage() {
        let url = URL(string: "beepbeep://p/maurice")!

        #expect(TurboIncomingLink.reference(from: url) == "https://beepbeep.to/maurice")
    }

    @Test func incomingLinkParsesCustomSchemeDidTarget() {
        let url = URL(string: "beepbeep://id/maurice")!

        #expect(TurboIncomingLink.reference(from: url) == "did:web:beepbeep.to:id:@maurice")
    }

    @Test func incomingLinkRejectsUnrelatedURLs() {
        let url = URL(string: "https://example.com/p/maurice")!

        #expect(TurboIncomingLink.reference(from: url) == nil)
    }

    @Test func contactSummaryFallsBackToLegacyHandleForPublicIdentityFields() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "requestRelationship": {
                "kind": "none",
                "requestCount": 0
              },
              "summaryStatus": {
                "kind": "online",
                "activeTransmitterUserId": null
              },
              "membership": {
                "kind": "both",
                "peerDeviceConnected": true
              },
              "isActiveConversation": false,
              "badgeStatus": "online"
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.publicId == "@blake")
        #expect(summary.profileName == "Blake")
    }

    @Test func contactSummaryDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)
            Issue.record("Expected TurboContactSummaryResponse decode to fail without nested contract")
        } catch {
        }
    }

    @Test func contactSummaryDecodeFailsForInvalidNestedRelationshipKind() {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@blake",
              "displayName": "Blake",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "requestRelationship": {
                "kind": "sideways",
                "requestCount": 3
              },
              "summaryStatus": {
                "kind": "incoming",
                "activeTransmitterUserId": null
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "isActiveConversation": true,
              "badgeStatus": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)
            Issue.record("Expected TurboContactSummaryResponse decode to fail for invalid requestRelationship kind")
        } catch {
        }
    }

    @Test func channelStateDecodesNestedMembershipAndRequestRelationshipProjection() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "membership": {
                "kind": "both",
                "peerDeviceConnected": true
              },
              "requestRelationship": {
                "kind": "incoming",
                "requestCount": 4
              },
              "conversationStatus": {
                "kind": "self-transmitting",
                "activeTransmitterUserId": "self"
              },
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true
            }
            """.utf8
        )

        let channelState = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)

        #expect(channelState.membership == .both(peerDeviceConnected: true))
        #expect(channelState.requestRelationship == .incoming(requestCount: 4))
        #expect(channelState.statusView == .selfTransmitting(activeTransmitterUserId: "self"))
        #expect(channelState.statusKind == "self-transmitting")
        #expect(channelState.conversationStatus == .transmitting)
    }

    @Test func channelStateDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)
            Issue.record("Expected TurboChannelStateResponse decode to fail without nested contract")
        } catch {
        }
    }

    @Test func channelStateDecodeFailsForInvalidMembershipPayload() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@blake",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": false,
              "peerJoined": false,
              "peerDeviceConnected": false,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "membership": {
                "kind": "both"
              },
              "requestRelationship": {
                "kind": "incoming",
                "requestCount": 4
              },
              "conversationStatus": {
                "kind": "self-transmitting",
                "activeTransmitterUserId": "self"
              },
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)
            Issue.record("Expected TurboChannelStateResponse decode to fail for invalid membership payload")
        } catch {
        }
    }

    @Test func channelReadinessDecodesNestedReadinessProjection() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "peerUserId": "peer",
              "selfHasActiveDevice": true,
              "peerHasActiveDevice": true,
              "readiness": {
                "kind": "peer-transmitting",
                "activeTransmitterUserId": "peer"
              },
              "audioReadiness": {
                "self": { "kind": "ready" },
                "peer": { "kind": "waiting" },
                "peerTargetDeviceId": "peer-device"
              },
              "wakeReadiness": {
                "self": { "kind": "wake-capable", "targetDeviceId": "self-device" },
                "peer": { "kind": "wake-capable", "targetDeviceId": "peer-device" }
              },
              "activeTransmitterUserId": "peer",
              "activeTransmitExpiresAt": null,
              "status": "ready"
            }
            """.utf8
        )

        let readiness = try JSONDecoder().decode(TurboChannelReadinessResponse.self, from: data)

        #expect(readiness.statusView == .peerTransmitting(activeTransmitterUserId: "peer"))
        #expect(readiness.statusKind == "peer-transmitting")
        #expect(readiness.canTransmit == false)
        #expect(readiness.remoteAudioReadiness == .waiting)
        #expect(readiness.peerTargetDeviceId == "peer-device")
        #expect(readiness.remoteWakeCapability == .wakeCapable(targetDeviceId: "peer-device"))
    }

    @Test func channelReadinessDecodesInactiveReadinessProjection() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "peerUserId": "peer",
              "selfHasActiveDevice": false,
              "peerHasActiveDevice": false,
              "readiness": {
                "kind": "inactive"
              },
              "audioReadiness": {
                "self": { "kind": "unknown" },
                "peer": { "kind": "unknown" }
              },
              "wakeReadiness": {
                "self": { "kind": "unavailable" },
                "peer": { "kind": "unavailable" }
              },
              "activeTransmitExpiresAt": null,
              "status": "inactive"
            }
            """.utf8
        )

        let readiness = try JSONDecoder().decode(TurboChannelReadinessResponse.self, from: data)

        #expect(readiness.statusView == .inactive)
        #expect(readiness.statusKind == "inactive")
        #expect(readiness.canTransmit == false)
        #expect(readiness.remoteAudioReadiness == .unknown)
        #expect(readiness.remoteWakeCapability == .unavailable)
    }

    @Test func channelReadinessDecodeFailsWithoutNestedContract() {
        let data = Data(
            """
            {
              "channelId": "channel",
              "peerUserId": "peer",
              "selfHasActiveDevice": true,
              "peerHasActiveDevice": true,
              "activeTransmitterUserId": "peer",
              "activeTransmitExpiresAt": null,
              "status": "ready"
            }
            """.utf8
        )

        do {
            _ = try JSONDecoder().decode(TurboChannelReadinessResponse.self, from: data)
            Issue.record("Expected TurboChannelReadinessResponse decode to fail without readiness contract")
        } catch {
        }
    }

    @Test func contactSummaryPrefersNestedContractOverLegacyFields() throws {
        let data = Data(
            """
            {
              "userId": "peer",
              "handle": "@peer",
              "displayName": "Peer",
              "channelId": "channel",
              "isOnline": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": true,
              "requestCount": 2,
              "isActiveConversation": true,
              "badgeStatus": "requested",
              "requestRelationship": {
                "kind": "incoming",
                "requestCount": 2
              },
              "membership": {
                "kind": "peer-only",
                "peerDeviceConnected": true
              },
              "summaryStatus": {
                "kind": "requested"
              }
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(TurboContactSummaryResponse.self, from: data)

        #expect(summary.requestRelationship == .incoming(requestCount: 2))
        #expect(summary.hasIncomingRequest == true)
        #expect(summary.hasOutgoingRequest == false)
        #expect(summary.requestCount == 2)
        #expect(summary.badge == .requested)
        #expect(summary.badgeStatus == "requested")
    }

    @Test func channelStatePrefersNestedContractOverLegacyFields() throws {
        let data = Data(
            """
            {
              "channelId": "channel",
              "selfUserId": "self",
              "peerUserId": "peer",
              "peerHandle": "@peer",
              "selfOnline": true,
              "peerOnline": true,
              "selfJoined": true,
              "peerJoined": true,
              "peerDeviceConnected": true,
              "hasIncomingRequest": false,
              "hasOutgoingRequest": false,
              "requestCount": 0,
              "activeTransmitterUserId": null,
              "transmitLeaseExpiresAt": null,
              "status": "ready",
              "canTransmit": true,
              "membership": {
                "kind": "self-only"
              },
              "requestRelationship": {
                "kind": "none"
              },
              "conversationStatus": {
                "kind": "ready"
              }
            }
            """.utf8
        )

        let channelState = try JSONDecoder().decode(TurboChannelStateResponse.self, from: data)

        #expect(channelState.membership == .selfOnly)
        #expect(channelState.selfJoined == true)
        #expect(channelState.peerJoined == false)
        #expect(channelState.peerDeviceConnected == false)
        #expect(channelState.requestRelationship == .none)
        #expect(channelState.statusView == .ready)
        #expect(channelState.status == "ready")
    }

    @Test func channelSnapshotPrefersBackendReadinessProjection() {
        let channelState = makeChannelState(status: .ready, canTransmit: true)
        let readiness = makeChannelReadiness(status: .waitingForSelf)

        let snapshot = ChannelReadinessSnapshot(channelState: channelState, readiness: readiness)

        #expect(snapshot.readinessStatus == .waitingForSelf)
        #expect(snapshot.status == .waitingForPeer)
        #expect(snapshot.canTransmit == false)
    }

    @Test func listConversationStateMapsBackendReadyBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            isActiveConversation: true,
            badgeStatus: "ready"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .ready)
    }

    @Test func listConversationStateFallsBackToIdleForUnknownBadge() {
        let summary = TurboContactSummaryResponse(
            userId: "peer",
            handle: "@casey",
            displayName: "Casey",
            channelId: nil,
            isOnline: false,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            isActiveConversation: false,
            badgeStatus: "mystery"
        )

        #expect(ConversationStateMachine.listConversationState(for: summary) == .idle)
    }

    @Test func transmitReducerPressRequestEmitsBeginEffect() {
        let request = makeTransmitRequest()

        let transition = TransmitReducer.reduce(
            state: .initial,
            event: .pressRequested(request)
        )

        #expect(transition.state.phase == .requesting(contactID: request.contactID))
        #expect(transition.state.isPressingTalk)
        #expect(transition.effects == [.beginTransmit(request)])
    }

    @Test func transmitReducerSystemPressRequestEmitsBeginEffect() {
        let request = makeTransmitRequest()

        let transition = TransmitReducer.reduce(
            state: .initial,
            event: .systemPressRequested(request)
        )

        #expect(transition.state.phase == .requesting(contactID: request.contactID))
        #expect(transition.state.isPressingTalk)
        #expect(transition.effects == [.beginTransmit(request)])
    }

    @Test func transmitReducerBeginSuccessEmitsActivationWhileStillPressing() {
        let request = makeTransmitRequest()
        let requestingState = TransmitReducer.reduce(
            state: .initial,
            event: .pressRequested(request)
        ).state
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let transition = TransmitReducer.reduce(
            state: requestingState,
            event: .beginSucceeded(target, request)
        )

        #expect(transition.state.phase == .active(contactID: request.contactID))
        #expect(transition.state.activeTarget == target)
        #expect(transition.effects == [.activateTransmit(request, target)])
    }

    @Test func transmitReducerReleaseAfterGrantEmitsStopEffect() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let activeState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .beginSucceeded(target, request)
        ).state

        let transition = TransmitReducer.reduce(
            state: activeState,
            event: .releaseRequested
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects == [.stopTransmit(target)])
    }

    @Test func transmitReducerSystemEndedWhileActiveEmitsStopEffect() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let activeState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .beginSucceeded(target, request)
        ).state

        let transition = TransmitReducer.reduce(
            state: activeState,
            event: .systemEnded
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects == [.stopTransmit(target)])
    }

    @Test func transmitExecutionReducerTreatsBackgroundSystemEndAsImplicitRelease() {
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        let state = TransmitExecutionSessionState(
            latchedTarget: target,
            pressState: .pressing,
            stopIntent: .none,
            systemTransmitState: .transmitting(startedAt: Date(timeIntervalSince1970: 100))
        )

        let transition = TransmitExecutionReducer.reduce(
            state: state,
            event: .handleSystemTransmitEnded(
                applicationStateIsActive: false,
                matchingActiveTarget: target
            )
        )

        #expect(transition.state.isPressingTalk == false)
        #expect(transition.state.requiresReleaseBeforeNextPress == false)
        #expect(transition.state.activeTarget == target)
        #expect(transition.state.lastSystemTransmitBeganAt == nil)
        #expect(transition.effects == [.handledSystemTransmitEnded(.implicitRelease)])
    }

    @Test func transmitExecutionReducerTreatsForegroundSystemEndAsFreshPressBarrier() {
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        let state = TransmitExecutionSessionState(
            latchedTarget: target,
            pressState: .pressing,
            stopIntent: .none,
            systemTransmitState: .transmitting(startedAt: Date(timeIntervalSince1970: 100))
        )

        let transition = TransmitExecutionReducer.reduce(
            state: state,
            event: .handleSystemTransmitEnded(
                applicationStateIsActive: true,
                matchingActiveTarget: target
            )
        )

        #expect(transition.state.isPressingTalk == false)
        #expect(transition.state.requiresReleaseBeforeNextPress == true)
        #expect(transition.state.interruptedContactID == target.contactID)
        #expect(transition.state.activeTarget == target)
        #expect(transition.effects == [.handledSystemTransmitEnded(.requireFreshPress(contactID: target.contactID))])
    }

    @Test func transmitRuntimeAllowsSystemTransmitActivationOnlyOncePerLifecycle() {
        var runtime = TransmitRuntimeState()
        let channelUUID = UUID()

        runtime.noteSystemTransmitBegan()

        let firstActivationStart = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        let secondActivationStart = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        #expect(firstActivationStart)
        #expect(!secondActivationStart)

        runtime.noteSystemTransmitActivationCompleted(channelUUID: channelUUID)
        let activationAfterCompletion = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        #expect(!activationAfterCompletion)

        runtime.noteSystemTransmitEnded()
        runtime.noteSystemTransmitBegan()

        let activationAfterSystemEnd = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        #expect(activationAfterSystemEnd)
    }

    @Test func transmitRuntimeAllowsSystemTransmitActivationRetryAfterActivationReset() {
        var runtime = TransmitRuntimeState()
        let channelUUID = UUID()

        runtime.noteSystemTransmitBegan()

        let firstActivationStart = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        runtime.clearSystemTransmitActivation(channelUUID: channelUUID)
        let activationAfterReset = runtime.beginSystemTransmitActivationIfNeeded(channelUUID: channelUUID)
        #expect(firstActivationStart)
        #expect(activationAfterReset)
    }

    @Test func transmitReducerSystemEndedDuringStoppingDoesNotDuplicateStopEffect() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let stoppingState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(
                state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
                event: .beginSucceeded(target, request)
            ).state,
            event: .releaseRequested
        ).state

        let transition = TransmitReducer.reduce(
            state: stoppingState,
            event: .systemEnded
        )

        #expect(transition.state.phase == .stopping(contactID: request.contactID))
        #expect(transition.state.isPressingTalk == false)
        #expect(transition.effects.isEmpty)
    }

    @Test func transmitRuntimePreservesLatchedTargetWhilePressRemainsActive() {
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(target)

        runtime.syncActiveTarget(nil)

        #expect(runtime.isPressingTalk == true)
        #expect(runtime.activeTarget == target)

        runtime.markPressEnded()
        runtime.syncActiveTarget(nil)

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.activeTarget == nil)
    }

    @Test func transmitRuntimeReconcileIdleStateClearsStalePressAndTargetButKeepsStopLatch() {
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(
            TransmitTarget(
                contactID: UUID(),
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel-123"
            )
        )
        runtime.markExplicitStopRequested()

        runtime.reconcileIdleState()

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.activeTarget == nil)
        #expect(runtime.explicitStopRequested)
    }

    @Test func transmitRuntimeFreshPressClearsPreviousStopLatch() {
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.markExplicitStopRequested()
        runtime.markPressEnded()
        runtime.reconcileIdleState()

        runtime.markPressBegan()

        #expect(runtime.isPressingTalk)
        #expect(runtime.explicitStopRequested == false)
    }

    @Test func transmitRuntimePressEndKeepsLatchedTargetUntilCoordinatorClearsIt() {
        var runtime = TransmitRuntimeState()
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        runtime.markPressBegan()
        runtime.syncActiveTarget(target)

        runtime.markPressEnded()
        runtime.syncActiveTarget(target)

        #expect(runtime.activeTarget == target)
        #expect(runtime.explicitStopRequested == false)
    }

    @Test func transmitRuntimeInitialOutboundAudioSendGateSurvivesReleaseUntilFirstSend() {
        var runtime = TransmitRuntimeState()

        runtime.markPressBegan()
        runtime.markPressEnded()

        let firstTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        let secondTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()

        #expect(firstTake)
        #expect(!secondTake)
    }

    @Test func transmitRuntimeInitialOutboundAudioSendGateConsumesOncePerPress() {
        var runtime = TransmitRuntimeState()

        let initialTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        #expect(!initialTake)

        runtime.markPressBegan()

        let firstPressTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        let repeatedTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()

        #expect(firstPressTake)
        #expect(!repeatedTake)

        runtime.markPressEnded()
        let postReleaseTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        #expect(!postReleaseTake)

        runtime.reconcileIdleState()
        runtime.markPressBegan()

        let nextPressTake = runtime.takeShouldAwaitInitialOutboundAudioSendGate()
        #expect(nextPressTake)
    }

    @Test func transmitRuntimeExplicitStopDoesNotRearmPress() {
        var runtime = TransmitRuntimeState()
        runtime.markPressBegan()
        runtime.syncActiveTarget(
            TransmitTarget(
                contactID: UUID(),
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel-123"
            )
        )

        runtime.markExplicitStopRequested()
        runtime.markPressEnded()
        runtime.syncActiveTarget(runtime.activeTarget)

        #expect(runtime.explicitStopRequested)
        #expect(runtime.isPressingTalk == false)
    }

    @Test func transmitTaskRuntimeCancelBeginTaskCancelsTaskAndClearsReference() async {
        let runtime = TransmitTaskRuntimeState()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }

        runtime.replaceBeginTask(with: task, id: 1)
        runtime.cancelBeginTask(matching: 1)

        #expect(runtime.beginTask == nil)
        #expect(task.isCancelled)
        _ = await task.result
    }

    @Test func transmitTaskRuntimeCancelRenewTaskCancelsTaskAndClearsTarget() async {
        let runtime = TransmitTaskRuntimeState()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        runtime.replaceRenewalTask(with: task, id: 7, target: target)
        runtime.cancelRenewalTask(matching: 7)

        #expect(runtime.renewalTask == nil)
        #expect(runtime.renewalChannelID == nil)
        #expect(task.isCancelled)
        _ = await task.result
    }

    @Test func transmitTaskReducerResetCancelsBeginAndRenewal() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "peer-device",
            channelID: request.backendChannelID
        )
        let state = TransmitTaskSessionState(
            begin: .running(id: 1, request: request),
            renewal: .running(id: 2, target: target),
            nextWorkID: 3
        )

        let transition = TransmitTaskReducer.reduce(
            state: state,
            event: .reset
        )

        #expect(transition.state == TransmitTaskSessionState())
        #expect(
            transition.effects == [
                .cancelBegin,
                .cancelRenewal
            ]
        )
    }

    @Test func transmitTaskReducerCancelBeginOnlyCancelsBeginWork() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "peer-device",
            channelID: request.backendChannelID
        )
        let state = TransmitTaskSessionState(
            begin: .running(id: 1, request: request),
            renewal: .running(id: 2, target: target),
            nextWorkID: 3
        )

        let transition = TransmitTaskReducer.reduce(
            state: state,
            event: .cancelBegin
        )

        #expect(transition.state.begin == .idle)
        #expect(transition.state.renewal == .running(id: 2, target: target))
        #expect(transition.state.nextWorkID == 3)
        #expect(transition.effects == [.cancelBegin])
    }

    @Test func transmitTaskReducerKeepsExistingRenewalForSameTarget() {
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        let transition = TransmitTaskReducer.reduce(
            state: TransmitTaskSessionState(renewal: .running(id: 4, target: target), nextWorkID: 5),
            event: .renewalRequested(target)
        )

        #expect(transition.state.renewal == .running(id: 4, target: target))
        #expect(transition.effects.isEmpty)
    }

    @Test func transmitTaskReducerIgnoresStaleRenewalFinishAfterReplacement() {
        let contactID = UUID()
        let oldTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device-old",
            channelID: "channel-123"
        )
        let newTarget = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device-new",
            channelID: "channel-123"
        )

        let requestedTransition = TransmitTaskReducer.reduce(
            state: TransmitTaskSessionState(
                renewal: .running(id: 1, target: oldTarget),
                nextWorkID: 2
            ),
            event: .renewalRequested(newTarget)
        )

        #expect(requestedTransition.state.renewal == .running(id: 2, target: newTarget))
        #expect(
            requestedTransition.effects == [
                .cancelRenewal,
                .startRenewal(id: 2, target: newTarget)
            ]
        )

        let finishedTransition = TransmitTaskReducer.reduce(
            state: requestedTransition.state,
            event: .renewalFinished(id: 1)
        )

        #expect(finishedTransition.state.renewal == .running(id: 2, target: newTarget))
        #expect(finishedTransition.effects.isEmpty)
    }

    @MainActor
    @Test func systemTransmitClosesPrewarmedMediaSessionBeforeHandoff() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()

        #expect(viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
    }

    @MainActor
    @Test func systemTransmitDoesNotCloseMediaSessionDuringPTTAudioActivation() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()
        viewModel.isPTTAudioSessionActive = true

        #expect(!viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
    }

    @MainActor
    @Test func appleGatedSystemTransmitClosesPrewarmedAudioWhilePreservingDirectPathBeforeAppleAudioActivation() {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }

        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(viewModel.shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID))
        #expect(viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
        #expect(viewModel.shouldDeactivatePrewarmedAudioSessionBeforeSystemTransmit(for: contactID))
    }

    @MainActor
    @Test func speculativeSystemTransmitPreservesPrewarmedDirectMediaBeforeAppleAudioActivation() {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.mediaRuntime.contactID = contactID
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.session = StubRelayMediaSession()
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }

        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(viewModel.shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID))
        #expect(!viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))
    }

    @MainActor
    @Test func prewarmedDirectQuicSystemTransmitBridgeStartsCaptureAfterPTTFlagIsActive() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.isPTTAudioSessionActive = true

        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(viewModel.shouldBridgePrewarmedDirectMediaDuringSystemTransmit(for: contactID))
        #expect(!viewModel.shouldClosePrewarmedMediaBeforeSystemTransmit(for: contactID))

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            target: target,
            trigger: "test"
        )

        #expect(didStartBridge)
        #expect(mediaSession.startSendingAudioCallCount == 1)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Starting prewarmed Direct QUIC audio bridge before PTT activation"
            )
        )
    }

    @MainActor
    @Test func appleGatedForegroundPrewarmedDirectQuicSystemTransmitDefersCaptureBeforeAppleAudioActivation() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        #expect(viewModel.transmitCoordinator.state.activeTarget == nil)

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend"
        )
        let didStartDuplicateBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend-duplicate"
        )

        #expect(!didStartBridge)
        #expect(!didStartDuplicateBridge)
        #expect(mediaSession.startSendingAudioCallCount == 0)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferring warm Direct QUIC capture until Apple audio activation"
            )
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "early-audio-capture-deferred-until-system-activation"
            ) != nil
        )
    }

    @MainActor
    @Test func speculativePrewarmedDirectQuicSystemTransmitBridgeStartsCaptureBeforeBackendLease() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        #expect(viewModel.transmitCoordinator.state.activeTarget == nil)

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend"
        )
        let didStartDuplicateBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend-duplicate"
        )

        #expect(didStartBridge)
        #expect(!didStartDuplicateBridge)
        #expect(mediaSession.startSendingAudioCallCount == 1)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Starting prewarmed Direct QUIC audio bridge before PTT activation"
            )
        )
    }

    @MainActor
    @Test func speculativeWarmDirectQuicLeaseBypassProjectsTalkingBeforeAppleSystemTransmit() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend"
        )
        viewModel.recordTransmitStartupTiming(
            stage: "backend-lease-bypassed-direct-quic",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            metadata: ["targetDeviceId": "peer-device"]
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )
        viewModel.directQuicBackendLeaseBypassedContactIDs.insert(contactID)
        viewModel.transmitRuntime.syncActiveTarget(target)
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.syncTransmitState()

        #expect(didStartBridge)
        #expect(viewModel.isPTTAudioSessionActive == false)
        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "early-audio-capture-start-completed"
            ) != nil
        )
        #expect(viewModel.localTransmitProjection(for: contactID) == .transmitting)
        #expect(viewModel.selectedPeerState(for: contactID).statusMessage == "Talking to Blake")
    }

    @MainActor
    @Test func systemAudioActivationRefreshesDirectQuicCaptureAfterPreactivationBridge() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.transmitCoordinator.effectHandler = nil
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend"
        )
        viewModel.isPTTAudioSessionActive = true

        await viewModel.startPendingSystemTransmitAudioCaptureIfPossible(
            channelUUID: channelUUID,
            trigger: "audio-session-activated"
        )

        #expect(didStartBridge)
        #expect(mediaSession.audioRouteDidChangeCallCount == 0)
        #expect(mediaSession.startSendingAudioCallCount == 2)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Refreshing prewarmed audio capture after system audio activation"
            )
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "audio-capture-refreshed-after-system-activation"
            ) != nil
        )
    }

    @MainActor
    @Test func systemAudioActivationRefreshAbortPreventsCaptureStartAfterRelease() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend"
        )
        viewModel.transmitRuntime.markExplicitStopRequested()
        viewModel.transmitRuntime.markPressEnded()
        await viewModel.transmitCoordinator.handle(.releaseRequested)
        viewModel.isPTTAudioSessionActive = true

        await viewModel.startPendingSystemTransmitAudioCaptureIfPossible(
            channelUUID: channelUUID,
            trigger: "audio-session-activated"
        )

        #expect(didStartBridge)
        #expect(mediaSession.audioRouteDidChangeCallCount == 0)
        #expect(mediaSession.startSendingAudioCallCount == 1)
        #expect(mediaSession.abortSendingAudioCallCount == 0)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "audio-capture-refreshed-after-system-activation"
            ) == nil
        )
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.stale_startup_side_effect"
            }
        )
    }

    @MainActor
    @Test func systemAudioActivationRefreshAbortHandlesStartReturningAfterRelease() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend"
        )
        mediaSession.startSendingAudioDelayNanoseconds = 100_000_000
        viewModel.isPTTAudioSessionActive = true

        let refreshTask = Task { @MainActor in
            await viewModel.startPendingSystemTransmitAudioCaptureIfPossible(
                channelUUID: channelUUID,
                trigger: "audio-session-activated"
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        viewModel.transmitRuntime.markExplicitStopRequested()
        viewModel.transmitRuntime.markPressEnded()
        await viewModel.transmitCoordinator.handle(.releaseRequested)
        await refreshTask.value

        #expect(didStartBridge)
        #expect(mediaSession.audioRouteDidChangeCallCount == 0)
        #expect(mediaSession.startSendingAudioCallCount == 2)
        #expect(mediaSession.abortSendingAudioCallCount == 1)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "audio-capture-refreshed-after-system-activation"
            ) == nil
        )
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.stale_startup_side_effect"
            }
        )
    }

    @MainActor
    @Test func directQuicBridgeShowsTalkingOnlyAfterBackendLeaseBeforeAppleAudioActivation() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        let didStartBridge = await viewModel.startPrewarmedDirectSystemTransmitBridgeIfPossible(
            request: request,
            trigger: "test-pre-backend"
        )
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, source: "test")
        )
        viewModel.syncPTTState()

        #expect(didStartBridge)
        #expect(viewModel.isPTTAudioSessionActive == false)
        #expect(viewModel.localTransmitProjection(for: contactID) == .starting(.awaitingAudioSession))
        #expect(viewModel.selectedPeerState(for: contactID).statusMessage == "Waiting for microphone...")

        viewModel.recordTransmitStartupTiming(
            stage: "backend-lease-granted",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            metadata: ["targetDeviceId": "peer-device"]
        )

        #expect(viewModel.localTransmitProjection(for: contactID) == .transmitting)
        #expect(viewModel.selectedPeerState(for: contactID).statusMessage == "Talking to Blake")
    }

    @MainActor
    @Test func appleGatedWarmDirectQuicDefersCaptureUntilAppleAudioActivation() async throws {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }

        viewModel.beginTransmit()
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(pttClient.beginTransmitRequests == [channelUUID])
        #expect(viewModel.transmitCoordinator.state.activeTarget?.deviceID == "peer-device")
        #expect(viewModel.directQuicBackendLeaseBypassedContactIDs.contains(contactID))
        #expect(mediaSession.startSendingAudioCallCount == 0)
        #expect(mediaSession.closedDeactivateAudioSessionFlags == [true])
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "prewarmed-media-closed"
            ) != nil
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Bypassing backend transmit lease for warm Direct QUIC"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Closing app-managed media session before system transmit handoff"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Preserving direct QUIC media path during media close"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Backend transmit lease granted"
            )
        )

        viewModel.handleDidBeginTransmitting(channelUUID, source: "test")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(mediaSession.startSendingAudioCallCount == 0)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "early-audio-capture-deferred-until-system-activation"
            ) != nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "early-audio-capture-start-completed"
            ) == nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "transmit-start-signal-sent"
            ) == nil
        )

        viewModel.handleDidActivateAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "audio-capture-start-completed"
            ) != nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "audio-capture-refreshed-after-system-activation"
            ) == nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "transmit-start-signal-sent"
            ) == nil
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped transmit start signal for Direct QUIC lease bypass because WebSocket is not connected"
            )
        )
        #expect(viewModel.localTransmitProjection(for: contactID) == .transmitting)
    }

    @MainActor
    @Test func speculativeWarmDirectQuicRequestsAppleHandoffWithoutGatingAudioCapture() async throws {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }

        viewModel.beginTransmit()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(pttClient.beginTransmitRequests == [channelUUID])
        #expect(viewModel.directQuicBackendLeaseBypassedContactIDs.contains(contactID))
        #expect(mediaSession.startSendingAudioCallCount == 1)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "system-handoff-requested"
            ) != nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "early-audio-capture-start-completed"
            ) != nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "backend-lease-bypassed-direct-quic"
            ) != nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "system-handoff-skipped-warm-direct"
            ) == nil
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Starting foreground warm Direct QUIC audio after system handoff request"
            )
        )
        #expect(viewModel.localTransmitProjection(for: contactID) == .transmitting)
        #expect(viewModel.selectedPeerState(for: contactID).statusMessage == "Talking to Blake")
    }

    @MainActor
    @Test func appleGatedWarmDirectQuicAbortHandlesAudioStartReturningAfterRelease() async throws {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        mediaSession.startSendingAudioDelayNanoseconds = 100_000_000

        viewModel.beginTransmit()
        try await Task.sleep(nanoseconds: 150_000_000)
        viewModel.handleDidBeginTransmitting(channelUUID, source: "test")
        try await Task.sleep(nanoseconds: 20_000_000)

        viewModel.endTransmit()
        try await Task.sleep(nanoseconds: 20_000_000)
        viewModel.handleDidActivateAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(pttClient.beginTransmitRequests == [channelUUID])
        #expect(pttClient.stopTransmitRequests.contains(channelUUID))
        #expect(mediaSession.closedDeactivateAudioSessionFlags == [true])
        #expect(mediaSession.startSendingAudioCallCount == 0)
        #expect(mediaSession.abortSendingAudioCallCount == 0)
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "prewarmed-media-closed"
            ) != nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "early-audio-capture-deferred-until-system-activation"
            ) != nil
        )
        #expect(
            viewModel.transmitStartupTiming.elapsedMilliseconds(
                for: "early-audio-capture-start-completed"
            ) == nil
        )
        #expect(
            !viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.stale_startup_side_effect"
            }
        )
        #expect(viewModel.isTransmitting == false)
    }

    @MainActor
    @Test func pendingPTTHandoffReassertsPrewarmedDirectCaptureBeforeAudioActivation() async {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applicationStateOverride = .active
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.mediaRuntime.directQuicProbeController = DirectQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.startTransmitStartupTiming(for: request, source: "test")
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()

        viewModel.schedulePreActivationDirectCaptureReassertion(
            request: request,
            trigger: "test"
        )
        try? await Task.sleep(nanoseconds: 350_000_000)

        #expect(mediaSession.audioRouteDidChangeCallCount == 0)
        #expect(mediaSession.startSendingAudioCallCount >= 1)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Reasserting prewarmed Direct QUIC capture during PTT handoff"
            )
        )
        viewModel.transmitTaskRuntime.cancelCaptureReassertionTask()
    }

    @MainActor
    @Test func touchReleaseCancelsPendingSystemTransmitHandoffImmediately() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.transmitCoordinator.effectHandler = nil
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)

        viewModel.endTransmit()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.stopTransmitRequests == [channelUUID])
        #expect(viewModel.transmitRuntime.pendingSystemBeginChannelUUID == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Cancelling requested system transmit handoff"
            )
        )
    }

    @MainActor
    @Test func systemTransmitActivationContinuationCancelsAfterRelease() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.transmitCoordinator.effectHandler = nil
        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)

        #expect(
            viewModel.shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "test-before-release"
            )
        )

        viewModel.transmitRuntime.markExplicitStopRequested()
        viewModel.transmitRuntime.markPressEnded()
        await viewModel.transmitCoordinator.handle(.releaseRequested)

        #expect(
            !viewModel.shouldContinueSystemTransmitActivation(
                channelUUID: channelUUID,
                target: target,
                stage: "test-after-release"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Cancelled stale system transmit activation continuation"
            )
        )

        _ = viewModel.shouldContinueSystemTransmitActivation(
            channelUUID: channelUUID,
            target: target,
            stage: "audio-capture-start-completed"
        )
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.stale_startup_side_effect"
            }
        )
    }

    @MainActor
    @Test func systemTransmitHandoffPreservesPrewarmedAudioSession() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: false)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        viewModel.beginTransmit()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(pttClient.beginTransmitRequests == [channelUUID])
        #expect(mediaSession.closedDeactivateAudioSessionFlags == [false])
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Closing app-managed media session before system transmit handoff"
            )
        )
    }

    @Test func transmitReducerReleaseBeforeGrantCancelsPendingBeginAndIgnoresLateGrant() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let releasedState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .releaseRequested
        ).state

        #expect(releasedState.phase == .idle)
        #expect(releasedState.pendingRequest == nil)
        #expect(releasedState.isPressingTalk == false)

        let transition = TransmitReducer.reduce(
            state: releasedState,
            event: .beginSucceeded(target, request)
        )

        #expect(transition.state == releasedState)
        #expect(transition.effects.isEmpty)
    }

    @Test func transmitReducerSystemBeginFailureAbortsWithoutPeerStopSignal() {
        let request = makeTransmitRequest()
        let target = TransmitTarget(
            contactID: request.contactID,
            userID: request.remoteUserID,
            deviceID: "device-peer",
            channelID: request.backendChannelID
        )

        let activeState = TransmitReducer.reduce(
            state: TransmitReducer.reduce(state: .initial, event: .pressRequested(request)).state,
            event: .beginSucceeded(target, request)
        ).state

        let transition = TransmitReducer.reduce(
            state: activeState,
            event: .systemBeginFailed("PTChannelError(rawValue: 1)")
        )

        #expect(transition.state.phase == .idle)
        #expect(!transition.state.isPressingTalk)
        #expect(transition.state.activeTarget == nil)
        #expect(transition.effects == [.abortTransmit(target)])
    }

    @MainActor
    @Test func backendChannelRefreshPreservesRequestingTransmitLifecycle() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .requesting(contactID: contactID),
                    isPressActive: true,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @MainActor
    @Test func backendChannelRefreshDoesNotPreserveIdleTransmitLifecycle() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            !viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .idle,
                    isPressActive: false,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @MainActor
    @Test func backendSelfTransmittingProjectionDoesNotOverrideExplicitStop() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            !viewModel.shouldAcceptBackendLocalTransmitProjection(
                backendShowsLocalTransmit: true,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .stopping(contactID: contactID),
                    isPressActive: false,
                    explicitStopRequested: true,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
        #expect(
            viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.transmitting.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .stopping(contactID: contactID),
                    isPressActive: false,
                    explicitStopRequested: true,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @Test func selectedPeerStateKeepsStoppingAboveStaleBackendSelfTransmittingProjection() {
        let contactID = UUID()
        let channelState = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: "self",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.transmitting.rawValue,
            canTransmit: false
        )
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localTransmit: .stopping,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            directMediaPathActive: true,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(channelState: channelState, readiness: nil)
        )

        let selected = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selected.phase == .waitingForPeer)
        #expect(selected.detail == .waitingForPeer(reason: .localSessionTransition))
        #expect(selected.statusMessage == "Stopping...")
    }

    @MainActor
    @Test func backendChannelRefreshPreservesActiveTransmitLifecycleWhileHoldRemainsPressed() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        #expect(
            viewModel.shouldPreserveLocalTransmitState(
                selectedContactID: contactID,
                refreshedContactID: contactID,
                backendChannelStatus: ConversationState.ready.rawValue,
                transmitSnapshot: TransmitDomainSnapshot(
                    phase: .active(contactID: contactID),
                    isPressActive: true,
                    explicitStopRequested: false,
                    isSystemTransmitting: false,
                    activeTarget: nil,
                    interruptedContactID: nil,
                    requiresReleaseBeforeNextPress: false
                )
            )
        )
    }

    @MainActor
    @Test func channelRefreshFailurePreservesJoinedSelectedSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true

        #expect(viewModel.shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID))
    }

    @MainActor
    @Test func channelRefreshFailureDoesNotPreserveIdleSelectedSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID

        #expect(!viewModel.shouldPreserveLocalSessionAfterChannelRefreshFailure(contactID: contactID))
    }

    @MainActor
    @Test func liveChannelRegressionPreservesReadySessionWhileReceiving() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.remoteTransmittingContactIDs.insert(contactID)

        let existing = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: "peer",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.receiving.rawValue,
            canTransmit: false
        )
        let incoming = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.idle.rawValue,
            canTransmit: false
        )

        #expect(
            viewModel.shouldPreserveLiveChannelState(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        )
    }

    @MainActor
    @Test func idleChannelRegressionDoesNotPreserveAbsentSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        let existing = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.ready.rawValue,
            canTransmit: true
        )
        let incoming = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.idle.rawValue,
            canTransmit: false
        )

        #expect(
            !viewModel.shouldPreserveLiveChannelState(
                contactID: contactID,
                existing: existing,
                incoming: incoming
            )
        )
    }

    @MainActor
    @Test func activeSelfTransmittingRefreshPreservesExistingPeerMembership() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        let existing = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.ready.rawValue,
            canTransmit: true
        )
        let incoming = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: "self",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.transmitting.rawValue,
            canTransmit: true
        )

        let effective = viewModel.effectiveChannelStatePreservingLiveMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.membership == .both(peerDeviceConnected: true))
        #expect(effective.statusKind == ConversationState.transmitting.rawValue)
    }

    @MainActor
    @Test func authoritativeMembershipLossDoesNotPreserveLiveChannelState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true

        let existing = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.ready.rawValue,
            canTransmit: true
        )
        let incoming = TurboChannelStateResponse(
            channelId: "channel",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.idle.rawValue,
            canTransmit: false
        )

        let effective = viewModel.effectiveChannelStatePreservingLiveMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming,
            authoritativeMembershipLoss: true
        )

        #expect(effective.membership == .absent)
        #expect(effective.statusKind == ConversationState.idle.rawValue)
    }

    @MainActor
    @Test func idleMembershipLossDoesNotPreserveLiveChannelState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true

        let existing = makeChannelState(status: .ready, canTransmit: true)
        let incoming = makeChannelState(
            status: .idle,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )

        let effective = viewModel.effectiveChannelStatePreservingLiveMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.membership == .absent)
        #expect(effective.statusKind == ConversationState.idle.rawValue)
    }

    @MainActor
    @Test func signalingRecoveryPreservesReadyLiveChannelDuringTransientWaitingProjection() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendRuntime.replaceSignalingJoinRecoveryTask(with: Task {})

        let existing = makeChannelState(status: .ready, canTransmit: true)
        let incoming = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: false
        )

        let effective = viewModel.effectiveChannelStatePreservingLiveMembership(
            contactID: contactID,
            existing: existing,
            incoming: incoming
        )

        #expect(effective.statusKind == ConversationState.ready.rawValue)
        #expect(effective.membership == .both(peerDeviceConnected: true))
    }

    @MainActor
    @Test func websocketIdleWithoutTransmitDoesNotResetCallSession() {
        let viewModel = PTTViewModel()

        #expect(
            !viewModel.shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: false,
                systemIsTransmitting: false
            )
        )
    }

    @MainActor
    @Test func websocketIdleDuringTransmitDoesNotResetTransmitSession() {
        let viewModel = PTTViewModel()

        #expect(
            !viewModel.shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: true,
                systemIsTransmitting: false
            )
        )
        #expect(
            !viewModel.shouldResetTransmitSessionOnWebSocketIdle(
                hasPendingBeginOrActiveTransmit: false,
                systemIsTransmitting: true
            )
        )
    }

    @MainActor
    @Test func failedOrClosedMediaSessionIsRecreatedBeforeReuse() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldRecreateMediaSession(connectionState: .failed("send failed")))
        #expect(viewModel.shouldRecreateMediaSession(connectionState: .closed))
        #expect(!viewModel.shouldRecreateMediaSession(connectionState: .connected))
    }

    @Test func mediaRuntimeResetClearsOutgoingAudioRoute() {
        let runtime = MediaRuntimeState()
        runtime.replaceSendAudioChunk(with: { _ in })

        #expect(runtime.hasSendAudioChunk)

        runtime.reset()

        #expect(!runtime.hasSendAudioChunk)
    }

    @Test func mediaRuntimeResetCanPreserveActiveDirectQuicPath() {
        let contactID = UUID()
        let runtime = MediaRuntimeState()
        _ = runtime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-1",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        _ = runtime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        )
        runtime.updateTransportPathState(.direct)

        runtime.reset(preserveDirectQuic: true)

        #expect(runtime.transportPathState == .direct)
        #expect(runtime.directQuicUpgrade.attempt(for: contactID)?.isDirectActive == true)

        runtime.reset(preserveDirectQuic: false)

        #expect(runtime.transportPathState == .relay)
        #expect(runtime.directQuicUpgrade.attempt(for: contactID) == nil)
    }

    @MainActor
    @Test func pttStopFailureClassifierTreatsCodeFiveAsExpected() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 5)

        #expect(viewModel.isExpectedPTTStopFailure(error))
    }

    @MainActor
    @Test func pttRemoteParticipantClearClassifierTreatsCodeFiveAsExpected() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 5)

        #expect(viewModel.isExpectedPTTRemoteParticipantClearFailure(error))
    }

    @MainActor
    @Test func pttChannelUnavailableClassifierTreatsCodeOneAsRecoverable() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 1)

        #expect(viewModel.isRecoverablePTTChannelUnavailable(error))
    }

    @MainActor
    @Test func pttTransmissionInProgressClassifierTreatsCodeFourAsRecoverable() {
        let viewModel = PTTViewModel()
        let error = NSError(domain: PTChannelErrorDomain, code: 4)

        #expect(viewModel.isRecoverablePTTTransmissionInProgress(error))
    }

    @MainActor
    @Test func localTransmitClearsSystemRemoteParticipantBeforeHandoff() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()

        await viewModel.clearSystemRemoteParticipantBeforeLocalTransmit(
            contactID: contactID,
            channelUUID: channelUUID,
            reason: "test"
        )

        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.name == nil)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.channelUUID == channelUUID)
    }

    @MainActor
    @Test func joinedPTTChannelRequestsFullDuplexTransmissionMode() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]

        viewModel.handleDidJoinChannel(channelUUID, reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.transmissionModeUpdates.count == 1)
        #expect(pttClient.transmissionModeUpdates.first?.mode == .fullDuplex)
        #expect(pttClient.transmissionModeUpdates.first?.channelUUID == channelUUID)
        #expect(viewModel.diagnosticsTranscript.contains("Updated PTT transmission mode"))
    }

    @MainActor
    @Test func localTransmitClearRemoteParticipantCodeFiveIsNotAnError() async {
        let pttClient = RecordingPTTSystemClient()
        pttClient.activeRemoteParticipantError = NSError(domain: PTChannelErrorDomain, code: 5)
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()

        await viewModel.clearSystemRemoteParticipantBeforeLocalTransmit(
            contactID: contactID,
            channelUUID: channelUUID,
            reason: "test"
        )

        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped remote participant clear because no active remote participant was present"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Failed to clear active remote participant before local transmit"
            )
        )
    }

    @MainActor
    @Test func localTransmitRemoteParticipantClearCanTimeOut() async {
        let pttClient = RecordingPTTSystemClient()
        pttClient.activeRemoteParticipantDelayNanoseconds = 500_000_000
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()

        let cleared = await viewModel.clearSystemRemoteParticipantBeforeLocalTransmit(
            contactID: contactID,
            channelUUID: channelUUID,
            reason: "test",
            timeoutNanoseconds: 10_000_000
        )

        #expect(cleared == false)
        #expect(viewModel.diagnosticsTranscript.contains(
            "Timed out clearing active remote participant before local transmit"
        ))
    }

    @MainActor
    @Test func transmissionInProgressBeginFailureClearsRemoteParticipantAndRetriesOnce() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)

        viewModel.handleFailedToBeginTransmitting(
            channelUUID,
            error: NSError(domain: PTChannelErrorDomain, code: 4)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.name == nil)
        #expect(pttClient.beginTransmitRequests == [channelUUID])
        #expect(viewModel.systemTransmitBeginRecoveryAttemptsByChannelUUID[channelUUID] == 1)
    }

    @Test func selectedPeerStateUsesLocalTransmitWhileBackendRefreshLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: true,
            localPTTAudioSessionActive: true,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        #expect(selectedPeerState.phase == .transmitting)
    }

    @Test func selectedPeerStateUsesStartingTransmitUntilAudioTransportIsConnected() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: true,
            localPTTAudioSessionActive: true,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.transmitting.rawValue,
                    canTransmit: true
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: true,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .startingTransmit)
        #expect(selectedPeerState.conversationState == .transmitting)
        #expect(selectedPeerState.detail == .startingTransmit(stage: .awaitingAudioConnection(mediaState: .preparing)))
        #expect(selectedPeerState.statusMessage == "Establishing audio...")
        #expect(primaryAction.kind == .holdToTalk)
    }

    @Test func selectedPeerStateUsesRequestingTransmitStatusBeforeLeaseArrives() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .requesting(contactID: contactID),
            localSystemIsTransmitting: false,
            localPTTAudioSessionActive: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .startingTransmit)
        #expect(selectedPeerState.detail == .startingTransmit(stage: .requestingLease))
        #expect(selectedPeerState.statusMessage == "Requesting transmit...")
    }

    @Test func selectedPeerStateUsesWakeStatusWhileAwaitingSystemTransmitStart() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: false,
            localPTTAudioSessionActive: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .startingTransmit)
        #expect(selectedPeerState.detail == .startingTransmit(stage: .awaitingSystemTransmit))
        #expect(selectedPeerState.statusMessage == "Waking Blake...")
    }

    @Test func selectedPeerStateWaitsForMicrophoneAfterSystemTransmitBegins() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: true,
            localTransmitPhase: .active(contactID: contactID),
            localSystemIsTransmitting: true,
            localPTTAudioSessionActive: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(status: .transmitting, canTransmit: true),
                readiness: makeChannelReadiness(
                    status: .selfTransmitting(activeTransmitterUserId: "self"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .startingTransmit)
        #expect(selectedPeerState.detail == .startingTransmit(stage: .awaitingAudioSession))
        #expect(selectedPeerState.statusMessage == "Waiting for microphone...")
    }

    @Test func selectedPeerStateUsesWakeReadyWhilePeerDeviceIsNotConnected() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .wakeReady)
        #expect(selectedPeerState.conversationState == .ready)
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(selectedPeerState.allowsHoldToTalk)
        #expect(selectedPeerState.statusMessage == "Hold to talk to wake Blake")
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.label == "Hold To Talk")
        #expect(primaryAction.isEnabled)
    }

    @Test func selectedPeerStateTreatsActiveDirectQuicPathAsMediaReady() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .idle,
            localMediaWarmupState: .cold,
            directMediaPathActive: true,
            channel: ChannelReadinessSnapshot(
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .waiting
                )
            )
        )

        let projection = ConversationStateMachine.projection(for: context, relationship: .none)

        #expect(projection.connectedControlPlane == .ready)
        #expect(projection.selectedPeerState.phase == .ready)
        #expect(projection.selectedPeerState.statusMessage == "Connected")
        #expect(projection.selectedPeerState.canTransmitNow)
    }

    @MainActor
    @Test func conversationContextTreatsLocalPressLatchAsTransmitIntent() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true

        await viewModel.transmitCoordinator.handle(.pressRequested(request))

        let context = viewModel.conversationContext(for: viewModel.contacts[0])

        #expect(context.localIsTransmitting)
        #expect(viewModel.isTransmitting == false)
    }

    @Test func selectedPeerStatePrefersReadyOverWakeWhenRemoteAudioIsReadyButPeerConnectivityLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .ready)
        #expect(selectedPeerState.statusMessage == "Connected")
        #expect(selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerStateUsesBackendReadyWhenPeerDeviceIsConnectedButWakeMetadataLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .ready)
        #expect(selectedPeerState.statusMessage == "Connected")
        #expect(selectedPeerState.canTransmitNow)
    }

    @Test func selectedPeerStateWaitsForRemoteAudioWhenPeerConnectivityDropsDuringReadyConvergence() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Waiting for Blake's audio...")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(selectedPeerState.allowsHoldToTalk == false)
    }

    @Test func selectedPeerStateWaitsWhenBackendWaitingAndPeerDeviceIsStillConnectedDespiteWakeCapability() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Establishing connection...")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(selectedPeerState.allowsHoldToTalk == false)
    }

    @Test func selectedPeerStateWaitsWhenOnlyLocalMembershipRemainsEvenIfPeerCanStillWake() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.conversationState == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Connecting...")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(!selectedPeerState.allowsHoldToTalk)
        #expect(primaryAction.kind == .connect)
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedPeerStateDoesNotUseWakeReadyWhenOnlyLocalMembershipRemainsButPeerHasNotPublishedWakeReadiness() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Connecting...")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(!selectedPeerState.allowsHoldToTalk)
        #expect(primaryAction.kind == .connect)
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedPeerStateDoesNotUseWakeReadyWhenOnlyLocalMembershipRemainsDespitePeerWakeCapability() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .waitingForPeer,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.waitingForPeer.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Connecting...")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(!selectedPeerState.allowsHoldToTalk)
        #expect(primaryAction.kind == .connect)
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedPeerStateRequiresReleaseAfterInterruptedTransmitInsteadOfWakeReady() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            localIsStopping: false,
            localRequiresFreshPress: true,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Release and press again.")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.label == "Release To Retry")
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedPeerStatePrefersReceivingOverWakeWhenBackendShowsPeerTransmittingButPeerConnectivityLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .unknown,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .receiving)
        #expect(selectedPeerState.statusMessage == "Blake is talking")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerStateWaitsForSystemWakeActivationBeforeShowingReceiving() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            incomingWakeActivationState: .awaitingSystemActivation,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == SelectedPeerPhase.waitingForPeer)
        #expect(selectedPeerState.detail == SelectedPeerDetail.waitingForPeer(reason: .systemWakeActivation))
        #expect(selectedPeerState.statusMessage == "Waiting for system audio activation...")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerStateWaitsForSystemWakeActivationBeforeShowingReceivingFromBackendProjection() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .connected,
            localMediaWarmupState: .ready,
            incomingWakeActivationState: .awaitingSystemActivation,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.detail == .waitingForPeer(reason: .systemWakeActivation))
        #expect(selectedPeerState.statusMessage == "Waiting for system audio activation...")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerStateRequiresLocalAudioPrewarmBeforeHoldToTalkIsEnabled() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
            localMediaWarmupState: .prewarming,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.statusMessage == "Preparing audio...")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled == false)
    }

    @Test func selectedPeerStateKeepsWakeReadyWhenPeerBackgroundedLeavesLocalMediaCold() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .closed,
            localMediaWarmupState: .cold,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .wakeReady)
        #expect(selectedPeerState.statusMessage == "Hold to talk to wake Blake")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(selectedPeerState.allowsHoldToTalk)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled)
    }

    @Test func selectedPeerStateKeepsWakeReadyWhileLocalAudioPrewarmsForWakeCapablePeer() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .preparing,
            localMediaWarmupState: .prewarming,
            hadConnectedSessionContinuity: true,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        let primaryAction = ConversationStateMachine.primaryAction(
            selectedPeerState: selectedPeerState,
            isSelectedChannelJoined: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        #expect(selectedPeerState.phase == .wakeReady)
        #expect(selectedPeerState.statusMessage == "Hold to talk to wake Blake")
        #expect(selectedPeerState.canTransmitNow == false)
        #expect(selectedPeerState.allowsHoldToTalk)
        #expect(primaryAction.kind == .holdToTalk)
        #expect(primaryAction.isEnabled)
    }

    @Test func pttWakeRuntimeBuffersAudioUntilActivation() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        #expect(runtime.shouldBufferAudioChunk(for: contactID))
        runtime.bufferAudioChunk("AQI=", for: contactID)
        runtime.bufferAudioChunk("AwQ=", for: contactID)

        let buffered = runtime.takeBufferedAudioChunks(for: contactID)

        #expect(buffered == ["AQI=", "AwQ="])
        #expect(runtime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)

        runtime.markAudioSessionActivated(for: channelUUID)

        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(runtime.shouldBufferAudioChunk(for: contactID) == false)
    }

    @MainActor
    @Test func wakeReceiveTimingSummaryIncludesActivationAndPlaybackStages() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        viewModel.recordWakeReceiveTiming(
            stage: "incoming-push-result-active-participant-returned",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .pushToTalk
        )
        viewModel.recordWakeReceiveTiming(
            stage: "backend-peer-transmitting-observed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .websocket
        )
        viewModel.recordWakeReceiveTiming(
            stage: "backend-peer-transmit-prepare-observed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .websocket
        )
        viewModel.recordWakeReceiveTiming(
            stage: "backend-peer-transmit-refresh-observed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .backend
        )
        viewModel.recordWakeReceiveTiming(
            stage: "active-remote-participant-requested",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .pushToTalk
        )
        viewModel.recordWakeReceiveTiming(
            stage: "active-remote-participant-completed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            subsystem: .pushToTalk
        )
        viewModel.recordWakeReceiveTiming(
            stage: "direct-quic-audio-received",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123"
        )
        viewModel.pttWakeRuntime.bufferAudioChunk("AQI=", for: contactID)
        viewModel.recordWakeReceiveTiming(
            stage: "first-audio-buffered",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            ifAbsent: true
        )
        viewModel.pttWakeRuntime.markAudioSessionActivated(for: channelUUID)
        viewModel.recordWakeReceiveTiming(
            stage: "system-audio-activation-observed",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123"
        )
        viewModel.recordWakeReceiveTiming(
            stage: "first-playback-buffer-scheduled",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123",
            ifAbsent: true
        )
        viewModel.recordWakeReceiveTimingSummary(
            reason: "test",
            contactID: contactID,
            channelUUID: channelUUID,
            channelID: "channel-123"
        )

        let summary = viewModel.diagnostics.entries.first {
            $0.message == "Wake receive timing summary"
        }
        #expect(summary != nil)
        #expect(summary?.metadata["reason"] == "test")
        #expect(summary?.metadata["incoming-push-result-active-participant-returnedMs"] != nil)
        #expect(summary?.metadata["backend-peer-transmit-prepare-observedMs"] != nil)
        #expect(summary?.metadata["backend-peer-transmit-refresh-observedMs"] != nil)
        #expect(summary?.metadata["backend-peer-transmitting-observedMs"] != nil)
        #expect(summary?.metadata["active-remote-participant-requestedMs"] != nil)
        #expect(summary?.metadata["active-remote-participant-completedMs"] != nil)
        #expect(summary?.metadata["direct-quic-audio-receivedMs"] != nil)
        #expect(summary?.metadata["first-audio-bufferedMs"] != nil)
        #expect(summary?.metadata["system-audio-activation-observedMs"] != nil)
        #expect(summary?.metadata["first-playback-buffer-scheduledMs"] != nil)
        #expect(summary?.metadata["wakeToSystemActivationDeltaMs"] != nil)
        #expect(summary?.metadata["firstBufferedToFirstPlaybackScheduledDeltaMs"] != nil)
        #expect(summary?.metadata["activeParticipantRequestedToDidActivateMs"] != nil)
        #expect(summary?.metadata["activeParticipantCompletedToDidActivateMs"] != nil)
        #expect(summary?.metadata["firstAudioToActiveParticipantRequestedMs"] != nil)
        #expect(summary?.metadata["backendPeerPrepareToActiveParticipantRequestedMs"] != nil)
        #expect(summary?.metadata["backendPeerRefreshToActiveParticipantRequestedMs"] != nil)
        #expect(summary?.metadata["backendPeerTransmitToActiveParticipantRequestedMs"] != nil)
        #expect(summary?.metadata["incomingPushResultToDidActivateMs"] != nil)
    }

    @Test func wakeExecutionReducerBuffersAudioAndTracksActivation() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let storedState = WakeExecutionReducer.reduce(
            state: WakeExecutionSessionState(),
            event: .store(
                PendingIncomingPTTPush(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    payload: payload
                )
            ),
            maximumBufferedAudioChunks: 12
        ).state
        let bufferedState = WakeExecutionReducer.reduce(
            state: storedState,
            event: .bufferAudioChunk(contactID: contactID, payload: "AQI="),
            maximumBufferedAudioChunks: 12
        ).state
        let activatedState = WakeExecutionReducer.reduce(
            state: bufferedState,
            event: .markAudioSessionActivated(channelUUID: channelUUID),
            maximumBufferedAudioChunks: 12
        ).state

        #expect(bufferedState.bufferedAudioChunkCount(for: contactID) == 1)
        #expect(bufferedState.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(activatedState.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(activatedState.mediaSessionActivationMode(for: contactID) == .systemActivated)
    }

    @Test func wakeExecutionReducerConfirmIncomingPushDoesNotDowngradeSystemActivation() {
        let contactID = UUID()
        let channelUUID = UUID()
        let provisionalPayload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "direct-quic"
        )
        let confirmedPayload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let activatedState = WakeExecutionReducer.reduce(
            state: WakeExecutionReducer.reduce(
                state: WakeExecutionSessionState(),
                event: .store(
                    PendingIncomingPTTPush(
                        contactID: contactID,
                        channelUUID: channelUUID,
                        payload: provisionalPayload,
                        activationState: .systemActivated
                    )
                ),
                maximumBufferedAudioChunks: 12
            ).state,
            event: .confirmIncomingPush(channelUUID: channelUUID, payload: confirmedPayload),
            maximumBufferedAudioChunks: 12
        ).state

        #expect(activatedState.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(activatedState.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(activatedState.shouldBufferAudioChunk(for: contactID) == false)
        #expect(activatedState.pendingIncomingPush?.payload.senderDeviceId == "peer-device")
    }

    @Test func wakeExecutionReducerInterruptCancelsPlaybackFallbackTask() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let awaitingState = WakeExecutionReducer.reduce(
            state: WakeExecutionSessionState(),
            event: .store(
                PendingIncomingPTTPush(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    payload: payload,
                    hasConfirmedIncomingPush: true,
                    activationState: .awaitingSystemActivation
                )
            ),
            maximumBufferedAudioChunks: 12
        ).state
        let transition = WakeExecutionReducer.reduce(
            state: awaitingState,
            event: .markSystemActivationInterruptedByTransmitEnd(contactID: contactID),
            maximumBufferedAudioChunks: 12
        )

        #expect(
            transition.effects == [
                .cancelPlaybackFallbackTask(contactID: contactID)
            ]
        )
        #expect(
            transition.state.incomingWakeActivationState(for: contactID)
                == .systemActivationInterruptedByTransmitEnd
        )
        #expect(transition.state.pendingIncomingPush == nil)
    }

    @Test func wakeExecutionReducerClearAllCanPreserveSuppression() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let suppressedState = WakeExecutionReducer.reduce(
            state: WakeExecutionReducer.reduce(
                state: WakeExecutionSessionState(),
                event: .store(
                    PendingIncomingPTTPush(
                        contactID: contactID,
                        channelUUID: channelUUID,
                        payload: payload
                    )
                ),
                maximumBufferedAudioChunks: 12
            ).state,
            event: .suppressProvisionalWakeCandidate(contactID: contactID),
            maximumBufferedAudioChunks: 12
        ).state
        let transition = WakeExecutionReducer.reduce(
            state: suppressedState,
            event: .clearAll(clearSuppression: false),
            maximumBufferedAudioChunks: 12
        )

        #expect(transition.effects == [.cancelAllPlaybackFallbackTasks])
        #expect(transition.state.pendingIncomingPush == nil)
        #expect(transition.state.shouldSuppressProvisionalWakeCandidate(for: contactID))
    }

    @Test func receiveExecutionReducerSchedulesAndClearsRemoteActivity() {
        let contactID = UUID()

        var transition = ReceiveExecutionReducer.reduce(
            state: ReceiveExecutionSessionState(),
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )

        #expect(transition.state.remoteTransmittingContactIDs == [contactID])
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .drainingAudio,
                        generation: 1
                    )
                ]
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: false)
        )

        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(transition.effects == [.cancelRemoteSilenceTimeout(contactID: contactID)])
    }

    @Test func receiveExecutionReducerPreservesPlaybackDrainAfterTransmitStop() {
        let contactID = UUID()

        var transition = ReceiveExecutionReducer.reduce(
            state: ReceiveExecutionSessionState(),
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )
        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteTransmitStopped(contactID: contactID, preservePlaybackDrain: true)
        )

        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .audioChunk,
                    hasReceivedAudioChunk: true,
                    activityGeneration: 2,
                    isPeerTransmitting: false
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .drainingAudio,
                        generation: 2
                    )
                ]
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )

        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .audioChunk,
                    hasReceivedAudioChunk: true,
                    activityGeneration: 3,
                    isPeerTransmitting: false
                )
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .transmitStartSignal)
        )

        #expect(transition.state.remoteTransmittingContactIDs == [contactID])
        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .transmitStartSignal,
                    hasReceivedAudioChunk: false,
                    activityGeneration: 4,
                    isPeerTransmitting: true
                )
        )
    }

    @Test func receiveExecutionReducerUsesExtendedInitialTimeoutUntilFirstAudioChunkArrives() {
        let contactID = UUID()

        var transition = ReceiveExecutionReducer.reduce(
            state: ReceiveExecutionSessionState(),
            event: .remoteActivityDetected(contactID: contactID, source: .incomingPush)
        )

        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .incomingPush,
                    hasReceivedAudioChunk: false,
                    activityGeneration: 1
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .awaitingFirstAudioChunk,
                        generation: 1
                    )
                ]
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .transmitStartSignal)
        )

        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .transmitStartSignal,
                    hasReceivedAudioChunk: false,
                    activityGeneration: 2
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .awaitingFirstAudioChunk,
                        generation: 2
                    )
                ]
        )

        transition = ReceiveExecutionReducer.reduce(
            state: transition.state,
            event: .remoteActivityDetected(contactID: contactID, source: .audioChunk)
        )

        #expect(
            transition.state.remoteActivityByContactID[contactID]
                == RemoteReceiveActivityState(
                    lastSource: .audioChunk,
                    hasReceivedAudioChunk: true,
                    activityGeneration: 3
                )
        )
        #expect(
            transition.effects
                == [
                    .scheduleRemoteSilenceTimeout(
                        contactID: contactID,
                        phase: .drainingAudio,
                        generation: 3
                    )
                ]
        )
    }

    @Test func receiveExecutionReducerResetCancelsSilenceTimeouts() {
        let contactID = UUID()
        let state = ReceiveExecutionSessionState(
            remoteActivityByContactID: [
                contactID: RemoteReceiveActivityState(
                    lastSource: .transmitStartSignal,
                    hasReceivedAudioChunk: false,
                    activityGeneration: 1
                )
            ]
        )

        let transition = ReceiveExecutionReducer.reduce(
            state: state,
            event: .reset
        )

        #expect(transition.state.remoteTransmittingContactIDs.isEmpty)
        #expect(transition.effects == [.cancelAllRemoteSilenceTimeouts])
    }

    @MainActor
    @Test func staleRemoteAudioSilenceTimerDoesNotClearNewerAudioGeneration() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.remoteAudioSilenceTimeoutNanoseconds = 40_000_000
        viewModel.receiveExecutionCoordinator.effectHandler = { _ in }

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        let staleGeneration = viewModel.receiveExecutionCoordinator
            .state
            .remoteActivityByContactID[contactID]?
            .activityGeneration

        #expect(staleGeneration == 1)

        if let staleGeneration {
            viewModel.runReceiveExecutionEffect(
                .scheduleRemoteSilenceTimeout(
                    contactID: contactID,
                    phase: .drainingAudio,
                    generation: staleGeneration
                )
            )
        }

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        #expect(
            viewModel.receiveExecutionCoordinator
                .state
                .remoteActivityByContactID[contactID]?
                .activityGeneration == 2
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Remote audio activity timed out"
            )
        )
    }

    @Test func pttWakeRuntimeTracksIncomingPushAndFallbackStates() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )
        runtime.confirmIncomingPush(for: channelUUID, payload: payload)
        #expect(runtime.hasConfirmedIncomingPush(for: contactID))
        #expect(runtime.incomingWakeActivationState(for: contactID) == .awaitingSystemActivation)

        runtime.markFallbackDeferredUntilForeground(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivationTimedOutWaitingForForeground)
        runtime.bufferAudioChunk("AQI=", for: contactID)
        #expect(runtime.bufferedAudioChunkCount(for: contactID) == 1)

        runtime.markSystemActivationInterruptedByTransmitEnd(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd)
        #expect(runtime.pendingIncomingPush == nil)
        #expect(runtime.shouldBufferAudioChunk(for: contactID) == false)

        runtime.markAppManagedFallbackStarted(for: contactID)
        #expect(runtime.incomingWakeActivationState(for: contactID) == .appManagedFallback)
    }

    @Test func selectedPeerStateSurfacesMissingSystemWakeActivationExplicitly() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .closed,
            localMediaWarmupState: .cold,
            incomingWakeActivationState: .systemActivationTimedOutWaitingForForeground,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.detail == .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground))
        #expect(selectedPeerState.statusMessage == "Wake received, but system audio never activated. Unlock to resume audio.")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func selectedPeerStateSurfacesInterruptedSystemWakeActivationExplicitly() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Blake",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            mediaState: .closed,
            localMediaWarmupState: .cold,
            incomingWakeActivationState: .systemActivationInterruptedByTransmitEnd,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                ),
                readiness: makeChannelReadiness(
                    status: .ready,
                    remoteAudioReadiness: .ready,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)

        #expect(selectedPeerState.phase == .waitingForPeer)
        #expect(selectedPeerState.detail == .waitingForPeer(reason: .wakePlaybackDeferredUntilForeground))
        #expect(selectedPeerState.statusMessage == "Wake ended before system audio activated.")
        #expect(selectedPeerState.canTransmitNow == false)
    }

    @Test func pttWakeRuntimeTreatsConfirmedMatchingIncomingPushAsDuplicate() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel",
            activeSpeaker: "@blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )

        let runtime = PTTWakeRuntimeState()
        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload,
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        #expect(
            runtime.shouldIgnoreDuplicateIncomingPush(
                for: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )
        #expect(
            !runtime.shouldIgnoreDuplicateIncomingPush(
                for: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel",
                    activeSpeaker: "@blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device-2"
                )
            )
        )
    }

    @Test func pttWakeRuntimeCanResetPlaybackFallbackTaskWithoutClearingPendingWake() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload
            )
        )

        runtime.replacePlaybackFallbackTask(for: contactID, with: Task { })
        #expect(runtime.hasPlaybackFallbackTask(for: contactID))

        runtime.clearPlaybackFallbackTask(for: contactID)

        #expect(runtime.hasPlaybackFallbackTask(for: contactID) == false)
        #expect(runtime.hasPendingWake(for: contactID))
        #expect(runtime.pendingIncomingPush?.channelUUID == channelUUID)
    }

    @MainActor
    @Test func appActivationResumesInteractiveAudioPrewarmForAlignedSelectedSession() async {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)

        await viewModel.resumeInteractiveAudioPrewarmIfNeeded(
            reason: "test",
            applicationState: .active
        )

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @MainActor
    @Test func foregroundTalkPathPrewarmCanSkipAppManagedAudioWhenDisabled() async {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = false
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        #expect(
            !viewModel.shouldPrewarmForegroundTalkPath(
                for: contactID,
                applicationState: .active
            )
        )

        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )

        #expect(
            viewModel.shouldPrewarmForegroundTalkPath(
                for: contactID,
                applicationState: .active
            )
        )

        await viewModel.prewarmForegroundTalkPathIfNeeded(for: contactID, reason: "test")

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Prewarming interactive audio for joined session"
            )
        )
    }

    @MainActor
    @Test func foregroundTalkPathPrewarmIsNoopWhenWarmAndPublished() async {
        let viewModel = PTTViewModel()
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, localAudioReadiness: .ready)
            )
        )
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        #expect(
            viewModel.shouldPrewarmForegroundTalkPath(
                for: contactID,
                applicationState: .active
            )
        )
        #expect(!viewModel.foregroundTalkPathNeedsPrewarm(for: contactID))
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmRecoversWithoutPTTDeactivationCallback() async {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
        try? await Task.sleep(nanoseconds: 700_000_000)

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == nil)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .ready)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmWaitsWhilePTTAudioSessionIsStillActive() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = true

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)
        try? await Task.sleep(nanoseconds: 700_000_000)

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmDoesNotRecoverWithoutCallbackWhileBackgrounded() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)

        await viewModel.recoverDeferredInteractivePrewarmWithoutPTTDeactivationIfNeeded(
            for: contactID,
            applicationState: .background
        )

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
    }

    @MainActor
    @Test func deferredInteractiveAudioPrewarmDoesNotResumeOnPTTDeactivationWhileBackgrounded() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        viewModel.contacts = [contact]
        viewModel.trackContact(contactID)
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.deferInteractivePrewarmUntilPTTAudioDeactivation(for: contactID)

        await viewModel.handleDeactivatedAudioSession(
            AVAudioSession.sharedInstance(),
            applicationState: .background
        )

        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
    }

    @Test func provisionalWakeCandidateStillBuffersAudioWithoutConfirmedPush() {
        let contactID = UUID()
        let channelUUID = UUID()
        let payload = TurboPTTPushPayload(
            event: .transmitStart,
            channelId: "channel-123",
            activeSpeaker: "Blake",
            senderUserId: "peer-user",
            senderDeviceId: "peer-device"
        )
        let runtime = PTTWakeRuntimeState()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: payload,
                hasConfirmedIncomingPush: false
            )
        )

        #expect(runtime.hasPendingWake(for: contactID))
        #expect(runtime.hasConfirmedIncomingPush(for: contactID) == false)
        #expect(runtime.shouldBufferAudioChunk(for: contactID))
    }

    @MainActor
    @Test func foregroundJoinedReceivePrefersAppManagedPlaybackOverSystemActivation() {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.remoteTransmittingContactIDs.insert(contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        #expect(
            viewModel.prefersForegroundAppManagedReceivePlayback(
                for: contactID,
                applicationState: .active
            )
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .active
            ) == false
        )
        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            )
        )
        viewModel.isPTTAudioSessionActive = true
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .background
            )
        )
    }

    @MainActor
    @Test func appleGatedForegroundJoinedReceiveUsesSystemActivatedPlayback() {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.remoteTransmittingContactIDs.insert(contactID)
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.isPTTAudioSessionActive = true

        #expect(
            viewModel.prefersForegroundAppManagedReceivePlayback(
                for: contactID,
                applicationState: .active
            ) == false
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .active
            )
        )
    }

    @MainActor
    @Test func signalPathSetsSystemRemoteParticipantWheneverSystemChannelCanReceive() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        #expect(
            viewModel.shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: .active
            )
        )
        #expect(
            viewModel.shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: .background
            )
        )
        #expect(
            viewModel.shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: .inactive
            )
        )
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, source: "test")
        )
        #expect(
            viewModel.shouldSetSystemRemoteParticipantFromSignalPath(
                for: contactID,
                applicationState: .background
            ) == false
        )
    }

    @MainActor
    @Test func transmitStopSignalPathClearsSystemRemoteParticipantOutsideForeground() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        #expect(viewModel.shouldClearSystemRemoteParticipantFromSignalPath(for: contactID))
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, source: "test")
        )
        #expect(viewModel.shouldClearSystemRemoteParticipantFromSignalPath(for: contactID) == false)
    }

    @Test func interactiveMediaSessionAudioPolicyUsesPlayAndRecord() {
        let appManaged = MediaSessionAudioPolicy.configuration(
            activationMode: .appManaged,
            startupMode: .interactive
        )
        let systemActivated = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .interactive
        )

        #expect(appManaged.category == .playAndRecord)
        #expect(appManaged.mode == .default)
        #expect(appManaged.options == MediaSessionAudioPolicy.routeCapableOptions)
        #expect(appManaged.shouldActivateSession == true)

        #expect(systemActivated.category == .playAndRecord)
        #expect(systemActivated.mode == .default)
        #expect(systemActivated.options == MediaSessionAudioPolicy.routeCapableOptions)
        #expect(systemActivated.shouldActivateSession == false)
    }

    @Test func playbackOnlyMediaSessionAudioPolicyKeepsPlayAndRecordWithoutActivating() {
        let appManaged = MediaSessionAudioPolicy.configuration(
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        let systemActivated = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(appManaged.category == .playAndRecord)
        #expect(appManaged.mode == .default)
        #expect(appManaged.options == MediaSessionAudioPolicy.routeCapableOptions)
        #expect(appManaged.shouldActivateSession == false)

        #expect(systemActivated.category == .playAndRecord)
        #expect(systemActivated.mode == .default)
        #expect(systemActivated.options == MediaSessionAudioPolicy.routeCapableOptions)
        #expect(systemActivated.shouldActivateSession == false)
    }

    @Test func liveTransmitCaptureRouteRefreshRestartsRunningEngineAndTap() {
        let plan = CaptureRouteRefreshPlan.forLiveTransmitRoute(
            engineIsRunning: true,
            inputTapInstalled: true
        )

        #expect(plan.shouldStopEngine)
        #expect(plan.shouldResetEngine)
        #expect(plan.shouldRemoveInputTap)
        #expect(plan.shouldRestartEngine)
    }

    @Test func liveTransmitCaptureRouteRefreshStillReinstallsPathWhenEngineWasIdle() {
        let plan = CaptureRouteRefreshPlan.forLiveTransmitRoute(
            engineIsRunning: false,
            inputTapInstalled: false
        )

        #expect(!plan.shouldStopEngine)
        #expect(!plan.shouldResetEngine)
        #expect(!plan.shouldRemoveInputTap)
        #expect(plan.shouldRestartEngine)
    }

    @Test func transmitStartPlanSkipsRefreshWhenCapturePathIsAlreadyLive() {
        let plan = CaptureTransmitStartPlan.forCurrentCapturePath(
            isCaptureReady: true,
            engineIsRunning: true,
            inputTapInstalled: true,
            hasCaptureConverter: true
        )

        #expect(!plan.shouldRefreshRoute)
    }

    @Test func audioChunkPayloadCodecPreservesLegacySingleChunkPayload() {
        let decoded = AudioChunkPayloadCodec.decode("chunk-1")

        #expect(decoded == ["chunk-1"])
    }

    @Test func audioChunkPayloadCodecRoundTripsBatchedPayloads() {
        let encoded = AudioChunkPayloadCodec.encode(["chunk-1", "chunk-2", "chunk-3"])
        let decoded = AudioChunkPayloadCodec.decode(encoded)

        #expect(decoded == ["chunk-1", "chunk-2", "chunk-3"])
    }

    @Test func audioChunkPayloadCodecTransportDigestIsStableForSamePayload() {
        let payload = AudioChunkPayloadCodec.encode(["chunk-1", "chunk-2"])
        let samePayloadDigest = AudioChunkPayloadCodec.transportDigest(payload)
        let repeatedDigest = AudioChunkPayloadCodec.transportDigest(payload)
        let differentDigest = AudioChunkPayloadCodec.transportDigest(
            AudioChunkPayloadCodec.encode(["chunk-1", "chunk-3"])
        )

        #expect(samePayloadDigest == repeatedDigest)
        #expect(samePayloadDigest != differentDigest)
    }

    @Test func mediaRuntimeBudgetsIncomingRelayAudioDiagnostics() {
        let runtime = MediaRuntimeState()
        let contactID = UUID()

        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .suppressedNotice
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .suppressed
        )

        runtime.resetIncomingRelayAudioDiagnostics(for: contactID, detailedReportLimit: 1)

        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .detailed
        )
        #expect(
            runtime.consumeIncomingRelayAudioDiagnosticDisposition(
                for: contactID,
                detailedReportLimit: 2
            ) == .suppressedNotice
        )
    }

    @Test func playbackBufferReceivePlanStartsNodeWithoutDuplicatingCurrentBuffer() {
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: false,
                playbackIOCycleAvailable: true
            ) == .scheduleAndStartNode
        )
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: true,
                playbackIOCycleAvailable: true
            ) == .scheduleOnly
        )
        #expect(
            PCMWebSocketMediaSession.playbackBufferReceivePlan(
                isPlayerNodePlaying: false,
                playbackIOCycleAvailable: false
            ) == .deferUntilIOCycle
        )
    }

    @Test func systemActivatedPlaybackOnlyPrimesPlaybackNodeOnce() {
        #expect(
            PCMWebSocketMediaSession.shouldPrimeSystemActivatedPlaybackNode(
                activationMode: .systemActivated,
                startupMode: .playbackOnly,
                playbackAlreadyReady: false
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldPrimeSystemActivatedPlaybackNode(
                activationMode: .appManaged,
                startupMode: .playbackOnly,
                playbackAlreadyReady: false
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldPrimeSystemActivatedPlaybackNode(
                activationMode: .systemActivated,
                startupMode: .interactive,
                playbackAlreadyReady: false
            )
        )
        #expect(
            !PCMWebSocketMediaSession.shouldPrimeSystemActivatedPlaybackNode(
                activationMode: .systemActivated,
                startupMode: .playbackOnly,
                playbackAlreadyReady: true
            )
        )
    }

    @Test func pcmLevelMetricsDetectsSilentAndNonSilentInt16Buffers() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let silentBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        silentBuffer.frameLength = 4

        let silentMetrics = try #require(PCMLevelMetrics.forBuffer(silentBuffer))
        #expect(silentMetrics.sampleCount == 4)
        #expect(silentMetrics.nonZeroSampleCount == 0)
        #expect(silentMetrics.isSilent)
        #expect(silentMetrics.diagnosticMetadata["pcmSilent"] == "true")

        let signalBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        signalBuffer.frameLength = 4
        let signalData = try #require(signalBuffer.int16ChannelData?.pointee)
        signalData[0] = 0
        signalData[1] = 16_384
        signalData[2] = -16_384
        signalData[3] = 8_192

        let signalMetrics = try #require(PCMLevelMetrics.forBuffer(signalBuffer))
        #expect(signalMetrics.sampleCount == 4)
        #expect(signalMetrics.nonZeroSampleCount == 3)
        #expect(!signalMetrics.isSilent)
        #expect(signalMetrics.peak == 0.5)
        #expect(signalMetrics.diagnosticMetadata["pcmSilent"] == "false")
    }

    @Test func pcmLevelMetricsDetectsSilentAndNonSilentInt16PayloadData() throws {
        let silentData = Data(count: 4 * MemoryLayout<Int16>.size)
        let silentMetrics = try #require(PCMLevelMetrics.forInt16PCMData(silentData))
        #expect(silentMetrics.sampleCount == 4)
        #expect(silentMetrics.nonZeroSampleCount == 0)
        #expect(silentMetrics.isSilent)

        let samples: [Int16] = [0, 16_384, -16_384, 8_192]
        let signalData = samples.withUnsafeBufferPointer { buffer in
            Data(
                bytes: buffer.baseAddress!,
                count: samples.count * MemoryLayout<Int16>.size
            )
        }
        let signalMetrics = try #require(PCMLevelMetrics.forInt16PCMData(signalData))
        #expect(signalMetrics.sampleCount == 4)
        #expect(signalMetrics.nonZeroSampleCount == 3)
        #expect(!signalMetrics.isSilent)
        #expect(signalMetrics.peak == 0.5)
    }

    @Test func audioChunkSenderWaitsForShortPacketizationWindowUntilBatchIsFull() {
        #expect(
            AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 1,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 3,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            !AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 4,
                maximumPayloadsPerMessage: 4
            )
        )
        #expect(
            !AudioChunkSender.shouldWaitForMorePayloads(
                pendingPayloadCount: 0,
                maximumPayloadsPerMessage: 4
            )
        )
    }

    @Test func audioChunkSenderBatchesNearbyPayloadsIntoSingleTransportSend() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.append(payload)
            },
            reportFailure: { _ in },
            payloadBatchCollectionNanoseconds: 220_000_000
        )

        async let enqueue1: Void = sender.enqueue("chunk-1")
        async let enqueue2: Void = sender.enqueue("chunk-2")
        async let enqueue3: Void = sender.enqueue("chunk-3")
        _ = await (enqueue1, enqueue2, enqueue3)
        try? await Task.sleep(nanoseconds: 500_000_000)

        let transportPayloads = await recorder.payloads
        let deliveredPayloads = transportPayloads.flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads.count == 3)
        #expect(Set(deliveredPayloads) == Set(["chunk-1", "chunk-2", "chunk-3"]))
        #expect(transportPayloads.count < 3)
    }

    @Test func audioChunkSenderBuffersSinglePayloadForShortPacketizationWindow() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }

            func snapshot() -> [String] {
                payloads
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.append(payload)
            },
            reportFailure: { _ in },
            payloadBatchCollectionNanoseconds: 220_000_000
        )

        async let enqueue: Void = sender.enqueue("chunk-1")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let transportPayloads = await recorder.snapshot()
        #expect(transportPayloads.isEmpty)

        _ = await enqueue
        try? await Task.sleep(nanoseconds: 300_000_000)

        let flushedPayloads = await recorder.snapshot()
        #expect(flushedPayloads == ["chunk-1"])
    }

    @Test func audioChunkSenderUsesUpdatedTransportHandler() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: nil,
            reportFailure: { _ in }
        )

        await sender.updateSendChunk { payload in
            await recorder.append(payload)
        }
        await sender.enqueue("chunk-1")
        await sender.enqueue("chunk-2")
        try? await Task.sleep(nanoseconds: 500_000_000)

        let transportPayloads = await recorder.payloads
        let deliveredPayloads = transportPayloads.flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads == ["chunk-1", "chunk-2"])
    }

    @Test func audioChunkSenderReportsTransportDispatchAndDelivery() async {
        actor Recorder {
            var messages: [String] = []

            func append(_ message: String) {
                messages.append(message)
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { _ in },
            reportFailure: { _ in },
            reportEvent: { message, _ in
                await recorder.append(message)
            }
        )

        await sender.enqueue("chunk-1")
        try? await Task.sleep(nanoseconds: 800_000_000)

        let messages = await recorder.messages
        #expect(messages.contains("Dispatching outbound audio transport payload"))
        #expect(messages.contains("Delivered outbound audio transport payload"))
    }

    @Test func audioChunkSenderDropsOldestQueuedPayloadsUnderBackpressure() async {
        actor Gate {
            var isOpen = false
            var continuations: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                guard !isOpen else { return }
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                }
            }

            func open() {
                isOpen = true
                let waiting = continuations
                continuations.removeAll(keepingCapacity: false)
                for continuation in waiting {
                    continuation.resume()
                }
            }
        }

        actor Recorder {
            var payloads: [String] = []
            var events: [String] = []

            func appendPayload(_ payload: String) {
                payloads.append(payload)
            }

            func appendEvent(_ event: String) {
                events.append(event)
            }
        }

        let gate = Gate()
        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await gate.wait()
                await recorder.appendPayload(payload)
            },
            reportFailure: { _ in },
            reportEvent: { message, _ in
                await recorder.appendEvent(message)
            },
            maximumPendingPayloads: 3,
            maximumPayloadsPerMessage: 1
        )

        let firstSend = Task {
            await sender.enqueue("chunk-0")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let queuedSends = (1...6).map { index in
            Task {
                await sender.enqueue("chunk-\(index)")
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        await gate.open()
        await firstSend.value
        for queuedSend in queuedSends {
            await queuedSend.value
        }
        await sender.finishDraining(pollNanoseconds: 1_000_000)

        let deliveredPayloads = await recorder.payloads.flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads == ["chunk-0", "chunk-4", "chunk-5", "chunk-6"])
        #expect(await recorder.events.contains("Dropped stale outbound audio transport payload"))
    }

    @Test func audioChunkSenderWaitsBrieflyForLateTransportHandler() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }
        }

        actor FailureRecorder {
            var messages: [String] = []

            func append(_ message: String) {
                messages.append(message)
            }
        }

        let recorder = Recorder()
        let failures = FailureRecorder()
        let sender = AudioChunkSender(
            sendChunk: nil,
            reportFailure: { message in
                await failures.append(message)
            }
        )

        let enqueueTask = Task {
            await sender.enqueue("chunk-late")
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await sender.updateSendChunk { payload in
            await recorder.append(payload)
        }
        await enqueueTask.value

        let payloads = await recorder.payloads
        let failureMessages = await failures.messages
        #expect(payloads == ["chunk-late"])
        #expect(failureMessages.isEmpty)
    }

    @Test func audioChunkSenderFinishDrainingWaitsForQueuedPayloadsToFlush() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }

            func snapshot() -> [String] {
                payloads
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                try? await Task.sleep(nanoseconds: 120_000_000)
                await recorder.append(payload)
            },
            reportFailure: { _ in }
        )

        let enqueueTask = Task {
            await sender.enqueue("chunk-1")
            await sender.enqueue("chunk-2")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let finishTask = Task {
            await sender.finishDraining(pollNanoseconds: 5_000_000)
        }

        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(await recorder.snapshot().isEmpty)

        await finishTask.value
        await enqueueTask.value

        let deliveredPayloads = await recorder.snapshot().flatMap(AudioChunkPayloadCodec.decode)
        #expect(deliveredPayloads == ["chunk-1", "chunk-2"])
    }

    @Test func audioChunkSenderFinishDrainingFlushesPartialBatchWithoutWaitingForFullBatchWindow() async {
        actor Recorder {
            var payloads: [String] = []

            func append(_ payload: String) {
                payloads.append(payload)
            }

            func count() -> Int {
                payloads.count
            }
        }

        let recorder = Recorder()
        let sender = AudioChunkSender(
            sendChunk: { payload in
                await recorder.append(payload)
            },
            reportFailure: { _ in },
            payloadBatchCollectionNanoseconds: 1_000_000_000
        )

        let enqueueTask = Task {
            await sender.enqueue("chunk-1")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        await sender.finishDraining(pollNanoseconds: 1_000_000)
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
        await enqueueTask.value

        #expect(await recorder.count() == 1)
        #expect(elapsedNanoseconds < 500_000_000)
    }

    @Test func captureSendStateKeepsAcceptingBuffersDuringStopTailGrace() {
        let nowNanoseconds: UInt64 = 2_000_000_000
        let state = CaptureSendState.stopping(
            graceDeadlineNanoseconds: nowNanoseconds + 120_000_000
        )

        #expect(
            CaptureSendState.shouldAcceptCapturedBuffer(
                state,
                nowNanoseconds: nowNanoseconds + 40_000_000
            )
        )
        #expect(
            !CaptureSendState.shouldAcceptCapturedBuffer(
                state,
                nowNanoseconds: nowNanoseconds + 121_000_000
            )
        )
    }

    @MainActor
    @Test func incomingWebSocketAudioChunkDiagnosticsAreBudgeted() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                )
            )
        )

        for index in 0..<5 {
            viewModel.handleIncomingSignal(
                TurboSignalEnvelope(
                    type: .audioChunk,
                    channelId: "channel-123",
                    fromUserId: "peer-user",
                    fromDeviceId: "peer-device",
                    toUserId: "self-user",
                    toDeviceId: "self-device",
                    payload: AudioChunkPayloadCodec.encode([
                        Data([UInt8(index)]).base64EncodedString()
                    ])
                )
            )
        }

        let detailedEntries = viewModel.diagnostics.entries.filter {
            $0.message == "Audio chunk received"
        }
        let suppressedEntries = viewModel.diagnostics.entries.filter {
            $0.message == "Suppressing repetitive WebSocket audio chunk diagnostics"
        }

        #expect(detailedEntries.count == 3)
        #expect(suppressedEntries.count == 1)
        #expect(
            detailedEntries.allSatisfy {
                $0.metadata["transportDigest"] != nil
                    && $0.metadata["decodedChunkCount"] != nil
            }
        )
        #expect(suppressedEntries.first?.metadata["detailedReportLimit"] == "3")

        try await Task.sleep(nanoseconds: 100_000_000)
    }

    @MainActor
    @Test func incomingAudioChunkWaitsForPTTAudioActivationBeforeCreatingMediaSession() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                )
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["AQI="])
    }

    @MainActor
    @Test func transmitPrepareArmsReceiverWakeWithoutMarkingRemoteTalking() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-prepare"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.payload.event == .transmitStart)
        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.first?.channelUUID == channelUUID)
        #expect(
            viewModel.pttWakeRuntime.timing.elapsedMilliseconds(
                for: "backend-peer-transmit-prepare-observed"
            ) != nil
        )
    }

    @MainActor
    @Test func channelRefreshPeerTransmittingArmsReceiverWakeWithoutMarkingRemoteTalking() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false
        let channelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: "peer-user",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.receiving.rawValue,
            canTransmit: false
        )
        let readiness = makeChannelReadiness(
            status: .peerTransmitting(activeTransmitterUserId: "peer-user"),
            remoteAudioReadiness: .wakeCapable,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        await viewModel.prepareReceiverForBackendPeerTransmitFromChannelRefreshIfNeeded(
            contactID: contactID,
            effectiveChannelState: channelState,
            effectiveChannelReadiness: readiness
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.payload.event == .transmitStart)
        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.first?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.first?.channelUUID == channelUUID)
        #expect(
            viewModel.pttWakeRuntime.timing.elapsedMilliseconds(
                for: "backend-peer-transmit-refresh-observed"
            ) != nil
        )
    }

    @MainActor
    @Test func foregroundIncomingAudioChunkUsesAppManagedPlaybackWithoutWaitingForPTTActivation() async throws {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false
        let mediaSession = RecordingMediaSession()
        mediaSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.activationState == .appManagedFallback)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == [])
        #expect(mediaSession.receivedRemoteAudioChunks == ["AQI="])
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Using app-managed wake playback for foreground audio"
            )
        )
    }

    @MainActor
    @Test func appleGatedForegroundIncomingAudioChunkBuffersUntilPTTActivation() async throws {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false
        let mediaSession = RecordingMediaSession()
        mediaSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.activationState == .signalBuffered)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["AQI="])
        #expect(mediaSession.receivedRemoteAudioChunks.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Buffered wake audio chunk until PTT activation"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Using app-managed wake playback for foreground audio"
            ) == false
        )

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.activationState == .systemActivated)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == [])
        #expect(mediaSession.closedDeactivateAudioSessionFlags == [false])
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.receiveExecutionCoordinator.state
                .remoteActivityByContactID[contactID]?.hasReceivedAudioChunk == true
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Flushing buffered wake audio after PTT activation"
            )
        )
    }

    @MainActor
    @Test func appleGatedForegroundDirectQuicAudioUsesAppManagedPlaybackBeforePTTActivation() async throws {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.appleGated)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false
        let mediaSession = RecordingMediaSession()
        mediaSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }

        await viewModel.handleIncomingDirectQuicReceiverPrewarmRequest(
            DirectQuicReceiverPrewarmPayload(
                requestId: UUID().uuidString.lowercased(),
                channelId: "channel-123",
                fromDeviceId: "peer-device",
                reason: "transmit-system-handoff",
                directQuicAttemptId: "attempt-1"
            ),
            contactID: contactID,
            attemptID: "attempt-1"
        )
        await viewModel.handleIncomingDirectQuicAudioPayload(
            "AQI=",
            contactID: contactID,
            attemptID: "attempt-1"
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.activationState == .appManagedFallback)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == [])
        #expect(mediaSession.receivedRemoteAudioChunks == ["AQI="])
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Using app-managed wake playback for foreground audio"
            )
        )
    }

    @MainActor
    @Test func wakePlaybackFallbackKeepsBufferedAudioAvailableForLatePTTActivation() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                )
            )
        )
        viewModel.pttWakeRuntime.bufferAudioChunk("one", for: contactID)
        viewModel.pttWakeRuntime.bufferAudioChunk("two", for: contactID)

        let delayedSession = DelayedStartMediaSession(delayNanoseconds: 500_000_000)
        delayedSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: delayedSession, contactID: contactID)

        let fallbackTask = Task {
            await viewModel.runWakePlaybackFallbackIfNeeded(for: contactID)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(delayedSession.startCallCount == 1)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["one", "two"])

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == [])
        #expect(
            viewModel.receiveExecutionCoordinator.state
                .remoteActivityByContactID[contactID]?.hasReceivedAudioChunk == true
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Flushing buffered wake audio after PTT activation"
            )
        )

        delayedSession.finishStart()
        await fallbackTask.value
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped app-managed playback fallback because wake activation changed during startup"
            )
        )
    }

    @MainActor
    @Test func latePTTAudioActivationPreservesForegroundAppManagedWakePlayback() async throws {
        let previousPolicy = UserDefaults.standard.string(
            forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
        )
        TurboDirectPathDebugOverride.setTransmitStartupPolicy(.speculativeForeground)
        defer {
            if let previousPolicy {
                UserDefaults.standard.set(
                    previousPolicy,
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: TurboDirectPathDebugOverride.transmitStartupPolicyStorageKey
                )
            }
        }

        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        let mediaSession = RecordingMediaSession()
        mediaSession.delegate = viewModel
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                playbackMode: .appManagedFallback,
                activationState: .appManagedFallback
            )
        )

        await viewModel.handleActivatedAudioSession(.sharedInstance())

        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(mediaSession.audioRouteDidChangeCallCount == 1)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.activationState == .appManagedFallback)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Preserved app-managed wake playback after late PTT audio activation"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Refreshed app-managed wake playback after late PTT audio activation"
            )
        )
    }

    @MainActor
    @Test func receiveTransmitStopDefersInteractiveAudioPrewarmUntilPTTAudioDeactivation() async throws {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.remoteTransmittingContactIDs.insert(contactID)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)

        await viewModel.handleDeactivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func channelRefreshRecoversMissingTransmitStopAndDefersInteractiveAudioPrewarmUntilPTTAudioDeactivation() async throws {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.remoteTransmittingContactIDs.insert(contactID)

        let existingChannelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: "peer-user",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.receiving.rawValue,
            canTransmit: false
        )
        let readyChannelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.ready.rawValue,
            canTransmit: true
        )

        await viewModel.recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
            contactID: contactID,
            existingChannelState: existingChannelState,
            effectiveChannelState: readyChannelState
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)

        await viewModel.handleDeactivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func channelRefreshDoesNotRecoverMissingTransmitStopWhileAudioChunksAreStillDraining() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        let existingChannelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: "peer-user",
            transmitLeaseExpiresAt: nil,
            status: ConversationState.receiving.rawValue,
            canTransmit: false
        )
        let readyChannelState = TurboChannelStateResponse(
            channelId: "channel-123",
            selfUserId: "self-user",
            peerUserId: "peer-user",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.ready.rawValue,
            canTransmit: true
        )

        await viewModel.recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
            contactID: contactID,
            existingChannelState: existingChannelState,
            effectiveChannelState: readyChannelState
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Recovered missing transmit-stop from channel refresh"
            )
        )
    }

    @MainActor
    @Test func channelRefreshDoesNotRecoverMissingTransmitStopWhileWakeReceiveIsStillPending() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.isPTTAudioSessionActive = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .incomingPush)

        let connectingChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true
        )

        await viewModel.recoverRemoteTransmitStopFromChannelRefreshIfNeeded(
            contactID: contactID,
            existingChannelState: connectingChannelState,
            effectiveChannelState: connectingChannelState
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Recovered missing transmit-stop from channel refresh"
            )
        )
    }

    @MainActor
    @Test func explicitTransmitStopClearsTalkingWhileDeferringReceiveTeardownUntilRemoteAudioDrain() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.isPTTAudioSessionActive = true

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: ""
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferring receive teardown until remote audio drain after transmit stop"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after transmit stop"
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "duplicate"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after transmit stop"
            )
        )

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.mediaRuntime.pendingInteractivePrewarmAfterAudioDeactivationContactID == contactID)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after remote audio silence timeout"
            )
        )
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutDoesNotClosePlaybackWhilePeerStillTransmitting() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .receiving,
                    canTransmit: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer-user")
                )
            )
        )
        viewModel.isPTTAudioSessionActive = true

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferred remote audio silence timeout while peer transmit is authoritative"
            )
        )
        #expect(
            viewModel.diagnostics.invariantViolations.isEmpty
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after remote audio silence timeout"
            )
        )
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutDoesNotClosePlaybackWhileLocalAudioIsDraining() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(mediaSession.closedDeactivateAudioSessionFlags.isEmpty)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferred remote audio silence timeout while playback is still draining"
            )
        )

        mediaSession.hasPendingPlaybackResult = false
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(mediaSession.closedDeactivateAudioSessionFlags == [true])
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutSelfHealsStalePendingPlaybackDrain() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let mediaSession = RecordingMediaSession()
        mediaSession.hasPendingPlaybackResult = true
        viewModel.remoteAudioPendingPlaybackDrainMaxNanoseconds = 80_000_000

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 120_000_000)
        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .drainingAudio)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(mediaSession.closedDeactivateAudioSessionFlags == [true])
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "selected.receiving_stale_pending_playback_drain"
            }
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after remote audio silence timeout"
            )
        )
    }

    @MainActor
    @Test func explicitTransmitStopClearsTalkingWhileDeferringReceiveTeardownAwaitingFirstAudioChunk() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.isPTTAudioSessionActive = true

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .transmitStartSignal)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: ""
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Deferring receive teardown until remote audio drain after transmit stop"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Closed receive media session after transmit stop"
            )
        )

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID, phase: .awaitingFirstAudioChunk)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Initial remote audio chunk timed out"
            )
        )
    }

    @MainActor
    @Test func lateAudioChunkAfterTransmitStopDoesNotRearmProvisionalWakeCandidate() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd)
        #expect(viewModel.pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID))

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
    }

    @MainActor
    @Test func interruptedWakeStateClearsAfterInteractiveMediaRecovers() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivationInterruptedByTransmitEnd)

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
    }

    @MainActor
    @Test func delayedFirstAudioChunkKeepsWakeReceiveAliveUntilInitialGraceExpires() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.remoteAudioInitialChunkTimeoutNanoseconds = 300_000_000
        viewModel.remoteAudioSilenceTimeoutNanoseconds = 100_000_000
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.isPTTAudioSessionActive = true

        viewModel.markRemoteAudioActivity(for: contactID, source: .incomingPush)
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Initial remote audio chunk timed out"
            )
        )

        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))
        #expect(
            viewModel.receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.timeoutPhase
                == .drainingAudio
        )
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
    }

    @MainActor
    @Test func remoteAudioSilenceTimeoutClearsCompletedWakeState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
        #expect(!viewModel.remoteTransmittingContactIDs.contains(contactID))
    }

    @MainActor
    @Test func backgroundAudioChunkDoesNotRearmWakeAfterSystemAudioActivation() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.isPTTAudioSessionActive = true

        viewModel.handleRemoteAudioSilenceTimeout(for: contactID)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
    }

    @MainActor
    @Test func backgroundAudioChunkAfterPTTDeactivationBuffersActiveReceiveFlow() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )
        viewModel.isPTTAudioSessionActive = true
        viewModel.markRemoteAudioActivity(for: contactID, source: .audioChunk)

        await viewModel.handleDeactivatedAudioSession(
            AVAudioSession.sharedInstance(),
            applicationState: .background
        )
        viewModel.isPTTAudioSessionActive = false

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(
            viewModel.receiveExecutionCoordinator.state.remoteActivityByContactID[contactID]?.hasReceivedAudioChunk == true
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.contactID == contactID)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(viewModel.pttWakeRuntime.bufferedAudioChunkCount(for: contactID) == 1)
        #expect(pttClient.activeRemoteParticipantUpdates.last?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.last?.channelUUID == channelUUID)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Created provisional wake candidate from signal path"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Buffered wake audio chunk until PTT activation"
            )
        )
    }

    @MainActor
    @Test func lateAudioChunkAfterPTTDeactivationDoesNotRearmSuppressedWakeCandidate() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStop,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-end"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        await viewModel.handleDeactivatedAudioSession(
            AVAudioSession.sharedInstance(),
            applicationState: .background
        )

        #expect(viewModel.pttWakeRuntime.shouldSuppressProvisionalWakeCandidate(for: contactID))
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == nil)
    }

    @MainActor
    @Test func backendTransmitPrepareRearmsSuppressedBackgroundWakeAfterDirectAudioBeatsControlPlane() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.suppressProvisionalWakeCandidate(for: contactID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush == nil)
        #expect(pttClient.activeRemoteParticipantUpdates.isEmpty)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-prepare"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.contactID == contactID)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(pttClient.activeRemoteParticipantUpdates.last?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.last?.channelUUID == channelUUID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AwQ="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.bufferedAudioChunkCount(for: contactID) == 1)
    }

    @MainActor
    @Test func directQuicTransmitPrepareInForegroundArmsSystemReceiveWithoutTalkingStateBeforeAudio() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.handleIncomingDirectQuicReceiverPrewarmRequest(
            DirectQuicReceiverPrewarmPayload(
                requestId: UUID().uuidString.lowercased(),
                channelId: "channel-123",
                fromDeviceId: "peer-device",
                reason: "transmit-system-handoff",
                directQuicAttemptId: "attempt-1"
            ),
            contactID: contactID,
            attemptID: "attempt-1"
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.contactID == contactID)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(pttClient.activeRemoteParticipantUpdates.last?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.last?.channelUUID == channelUUID)
        #expect(viewModel.selectedPeerState(for: contactID).statusMessage == "Waiting for system audio activation...")
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Direct QUIC receiver transmit prepare received"
            )
        )

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
        #expect(viewModel.selectedPeerState(for: contactID).statusMessage != "Blake is talking")
    }

    @MainActor
    @Test func systemActivatedDirectQuicAudioDoesNotReassertActiveRemoteParticipantOnFirstChunk() async throws {
        let pttClient = RecordingPTTSystemClient()
        let mediaSession = RecordingMediaSession()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.mediaRuntime.attach(session: mediaSession, contactID: contactID)
        viewModel.mediaRuntime.updateConnectionState(.connected)

        await viewModel.handleIncomingDirectQuicReceiverPrewarmRequest(
            DirectQuicReceiverPrewarmPayload(
                requestId: UUID().uuidString.lowercased(),
                channelId: "channel-123",
                fromDeviceId: "peer-device",
                reason: "transmit-system-handoff",
                directQuicAttemptId: "attempt-1"
            ),
            contactID: contactID,
            attemptID: "attempt-1"
        )
        viewModel.pttWakeRuntime.markAudioSessionActivated(for: channelUUID)
        viewModel.isPTTAudioSessionActive = true
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(pttClient.activeRemoteParticipantUpdates.count == 1)
        #expect(mediaSession.receivedRemoteAudioChunks == ["AQI="])
    }

    @MainActor
    @Test func directQuicTransmitPrepareArmsBackgroundWakeBeforeAudio() async throws {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.handleIncomingDirectQuicReceiverPrewarmRequest(
            DirectQuicReceiverPrewarmPayload(
                requestId: UUID().uuidString.lowercased(),
                channelId: "channel-123",
                fromDeviceId: "peer-device",
                reason: "transmit-system-handoff",
                directQuicAttemptId: "attempt-1"
            ),
            contactID: contactID,
            attemptID: "attempt-1"
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.contactID == contactID)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .signalBuffered)
        #expect(pttClient.activeRemoteParticipantUpdates.last?.name == "Blake")
        #expect(pttClient.activeRemoteParticipantUpdates.last?.channelUUID == channelUUID)

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .audioChunk,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "AQI="
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.bufferedAudioChunkCount(for: contactID) == 1)
    }

    @MainActor
    @Test func transmitStartWithoutAudioOrStopExpiresRemoteTransmittingLatch() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.remoteAudioInitialChunkTimeoutNanoseconds = 300_000_000
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        viewModel.handleIncomingSignal(
            TurboSignalEnvelope(
                type: .transmitStart,
                channelId: "channel-123",
                fromUserId: "peer-user",
                fromDeviceId: "peer-device",
                toUserId: "self-user",
                toDeviceId: "self-device",
                payload: "ptt-begin"
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID))

        try await Task.sleep(nanoseconds: 350_000_000)

        #expect(viewModel.remoteTransmittingContactIDs.contains(contactID) == false)
    }

    @MainActor
    @Test func pttAudioActivationCreatesSystemPlaybackSessionAndFlushesBufferedWakeAudio() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        var pendingPush = PendingIncomingPTTPush(
            contactID: contactID,
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        pendingPush.bufferedAudioChunks = ["AQI=", "AwQ="]
        viewModel.pttWakeRuntime.store(pendingPush)

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .systemActivated)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
    }

    @MainActor
    @Test func incomingPTTPushResumesSuspendedWebSocketBeforeAudioActivation() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        client.suspendWebSocket()
        observedStates.removeAll()

        viewModel.handleReceivedIncomingPTTPush(
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.contains(.connecting))
    }

    @MainActor
    @Test func incomingLeaveChannelPushDoesNotResumeSuspendedWebSocketForAudioActivation() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        client.suspendWebSocket()
        observedStates.removeAll()

        viewModel.handleReceivedIncomingPTTPush(
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .leaveChannel,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.isEmpty)
    }

    @MainActor
    @Test func backgroundSyncEffectDoesNotReconnectSuspendedWebSocketWithoutLiveSession() async throws {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background

        client.suspendWebSocket()
        observedStates.removeAll()

        await viewModel.runBackendSyncEffect(.ensureWebSocketConnected)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.isEmpty)
        #expect(client.isWebSocketConnected == false)
    }

    @MainActor
    @Test func backgroundIdleUnexpectedWebSocketReconnectIsImmediatelyResuspended() async throws {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background

        client.resumeWebSocket()
        try await Task.sleep(nanoseconds: 20_000_000)

        viewModel.handleWebSocketStateChange(.connecting)
        try await Task.sleep(nanoseconds: 1_700_000_000)

        #expect(observedStates == [.connecting, .idle])
        #expect(client.isWebSocketConnected == false)
    }

    @Test func incomingPTTPushPreservesConnectedWebSocketUntilAudioActivation() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        client.setWebSocketConnectionStateForTesting(.connected)
        observedStates.removeAll()

        viewModel.handleReceivedIncomingPTTPush(
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.isEmpty)
    }

    @Test func incomingPTTPushPreservesConnectingWebSocketUntilAudioActivation() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        client.setWebSocketConnectionStateForTesting(.connecting)
        observedStates.removeAll()

        viewModel.handleReceivedIncomingPTTPush(
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.isEmpty)
    }

    @Test func systemTransmitActivationPreservesConnectedWebSocketInBackground() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        client.setWebSocketConnectionStateForTesting(.connected)
        observedStates.removeAll()

        guard let backend = viewModel.backendServices else {
            Issue.record("Missing backend services")
            return
        }

        viewModel.refreshWebSocketForSystemTransmitActivationIfNeeded(
            backend,
            contactID: contactID,
            channelID: "channel-123"
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.isEmpty)
    }

    @Test func systemTransmitActivationPreservesConnectingWebSocketInBackground() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        client.setWebSocketConnectionStateForTesting(.connecting)
        observedStates.removeAll()

        guard let backend = viewModel.backendServices else {
            Issue.record("Missing backend services")
            return
        }

        viewModel.refreshWebSocketForSystemTransmitActivationIfNeeded(
            backend,
            contactID: contactID,
            channelID: "channel-123"
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.isEmpty)
    }

    @Test func systemTransmitActivationResumesIdleWebSocketInBackgroundWithoutForcedRestart() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        client.setWebSocketConnectionStateForTesting(.idle)
        observedStates.removeAll()

        guard let backend = viewModel.backendServices else {
            Issue.record("Missing backend services")
            return
        }

        viewModel.refreshWebSocketForSystemTransmitActivationIfNeeded(
            backend,
            contactID: contactID,
            channelID: "channel-123"
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates == [.connecting])
    }

    @MainActor
    @Test func wakeReceiveActivationReconnectsStaleConnectingWebSocketInBackground() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        client.setWebSocketConnectionStateForTesting(.connecting)
        observedStates.removeAll()

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.starts(with: [.idle, .connecting]))
    }

    @MainActor
    @Test func foregroundIncomingPTTPushRewarmsReceivePathWhenWakeFlowIsIgnored() async throws {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = true
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.applicationStateOverride = .active
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)

        viewModel.handleReceivedIncomingPTTPush(
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func foregroundIncomingPTTPushReassertsBackendJoinWhenLocalSessionOutlivesBackendMembership() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-123",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .active
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true, selfJoined: false)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleReceivedIncomingPTTPush(
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID && request.intent == .joinReadyPeer
            }
        )
    }

    @MainActor
    @Test func systemOriginatedBeginTransmitReassertsBackendJoinWhenLocalSessionOutlivesBackendMembership() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-123",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttCoordinator.send(
            .didBeginTransmitting(channelUUID: channelUUID, source: "system-ui")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: true,
                    peerDeviceConnected: true
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .waitingForSelf)
            )
        )

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-123",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )

        await viewModel.transmitCoordinator.handle(.systemPressRequested(request))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID && request.intent == .joinReadyPeer
            }
        )
    }

    @MainActor
    @Test func pttAudioActivationPreservesExistingAppManagedAudioSessionWhileHandingOffToSystemPlayback() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        let existingSession = RecordingMediaSession()
        viewModel.mediaRuntime.attach(session: existingSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(existingSession.closedDeactivateAudioSessionFlags == [false])
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
    }

    @MainActor
    @Test func pttAudioActivationCreatesPlaybackBeforeDeferredBackendRefreshFails() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        var pendingPush = PendingIncomingPTTPush(
            contactID: contactID,
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        pendingPush.bufferedAudioChunks = ["AQI="]
        viewModel.pttWakeRuntime.store(pendingPush)

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.diagnosticsTranscript.contains("Deferring wake backend refresh off audio activation critical path"))
        #expect(viewModel.diagnosticsTranscript.contains("Contact sync failed"))

        let messages = viewModel.diagnostics.entries.map(\.message)
        let recreateIndex = messages.lastIndex(of: "Recreating media session after PTT audio activation")
        let deferIndex = messages.lastIndex(of: "Deferring wake backend refresh off audio activation critical path")
        let failureIndex = messages.lastIndex(of: "Contact sync failed")

        #expect(recreateIndex != nil)
        #expect(deferIndex != nil)
        #expect(failureIndex != nil)
        if let recreateIndex, let deferIndex, let failureIndex {
            #expect(recreateIndex > deferIndex)
            #expect(deferIndex > failureIndex)
        }
    }

    @MainActor
    @Test func pttAudioActivationResumesSuspendedWebSocketForBackgroundWake() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        client.suspendWebSocket()
        observedStates.removeAll()

        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        await viewModel.handleActivatedAudioSession(.sharedInstance())
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.contains(.connecting))
    }

    @Test func systemActivatedPlaybackOnlyPreservesExistingAudioSessionConfiguration() {
        let configuration = MediaSessionAudioPolicy.configuration(
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(configuration.shouldConfigureSession == false)
        #expect(configuration.shouldActivateSession == false)
        #expect(configuration.category == .playAndRecord)
    }

    @MainActor
    @Test func closeMediaSessionPreservesAudioSessionWhileWakeActivationIsPending() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        let existingSession = RecordingMediaSession()
        viewModel.mediaRuntime.attach(session: existingSession, contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .awaitingSystemActivation
            )
        )

        viewModel.closeMediaSession()

        #expect(existingSession.closedDeactivateAudioSessionFlags == [false])
        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
    }

    @Test func wakePlaybackFallbackRequiresActiveApplicationState() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .active))
        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .inactive) == false)
        #expect(viewModel.shouldUseAppManagedWakePlaybackFallback(applicationState: .background) == false)
    }

    @MainActor
    @Test func backgroundTransitionSuspendsIdleForegroundMediaSession() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState == .connected)
        #expect(
            viewModel.shouldSuspendForegroundMediaForBackgroundTransition(
                applicationState: .inactive
            )
        )

        await viewModel.suspendForegroundMediaForBackgroundTransition(
            reason: "test-background",
            applicationState: .background
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
    }

    @MainActor
    @Test func idleBackgroundTransitionRetiresDirectQuicAndPublishesNotReady() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(
                mode: "cloud",
                supportsWebSocket: true,
                supportsDirectQuicUpgrade: true
            )
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )

        _ = viewModel.directQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }
        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))

        var capturedEffects: [ControlPlaneEffect] = []
        viewModel.controlPlaneCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.reconcileIdleTransportForBackgroundTransition(
            reason: "test-background",
            applicationState: .background
        )

        #expect(!viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(
            capturedEffects.contains {
                guard case .publishReceiverAudioReadiness(let intent) = $0 else { return false }
                return intent.contactID == contactID
                    && intent.isReady == false
                    && intent.reason == "app-background-media-closed"
            }
        )
        #expect(viewModel.diagnosticsTranscript.contains("Retiring Direct QUIC media path"))
    }

    @MainActor
    @Test func backgroundNotificationRetiresDirectQuicSynchronously() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        _ = viewModel.directQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }

        let didRetire = viewModel.retireIdleDirectQuicForBackgroundTransitionImmediately(
            reason: "application-will-resign-active",
            applicationState: .inactive
        )

        #expect(didRetire)
        #expect(!viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(viewModel.mediaTransportPathState == .relay)
        #expect(viewModel.mediaRuntime.directQuicProbeController == nil)
        #expect(!viewModel.retireIdleDirectQuicForBackgroundTransitionImmediately(
            reason: "application-did-enter-background",
            applicationState: .background
        ))
    }

    @MainActor
    @Test func backgroundMediaClosedReadinessIntentForcesNotReadyWhileMediaIsConnected() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready, remoteAudioReadiness: .ready)
            )
        )
        viewModel.mediaRuntime.attach(session: RecordingMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.connectionState = .connected

        #expect(viewModel.desiredLocalReceiverAudioReadiness(for: contactID))

        let intent = viewModel.receiverAudioReadinessIntent(
            for: contactID,
            reason: "app-background-media-closed"
        )

        #expect(intent?.isReady == false)
        #expect(intent?.reason == "app-background-media-closed")
    }

    @MainActor
    @Test func backgroundTransitionPreservesDirectQuicOwnedByPendingWake() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-123",
                    activeSpeaker: "Blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: false,
                activationState: .signalBuffered
            )
        )
        _ = viewModel.directQuicProbeController()
        _ = viewModel.mediaRuntime.directQuicUpgrade.beginLocalAttempt(
            contactID: contactID,
            channelID: "channel-123",
            attemptID: "attempt-1",
            peerDeviceID: "peer-device"
        )
        if let direct = viewModel.mediaRuntime.directQuicUpgrade.markDirectPathActivated(
            for: contactID,
            attemptID: "attempt-1",
            nominatedPath: makeDirectQuicNominatedPath()
        ) {
            viewModel.applyDirectQuicUpgradeTransition(direct, for: contactID)
        }

        await viewModel.reconcileIdleTransportForBackgroundTransition(
            reason: "test-background",
            applicationState: .background
        )

        #expect(viewModel.shouldUseDirectQuicTransport(for: contactID))
        #expect(!viewModel.diagnosticsTranscript.contains("Retiring Direct QUIC media path"))
    }

    @MainActor
    @Test func backgroundJoinedSessionKeepsPTTServiceStatusReadyWhileWebSocketIsSuspended() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.applicationStateOverride = .background
        viewModel.backendRuntime.isReady = true
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        viewModel.syncPTTServiceStatus(reason: "test-background")
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(viewModel.lastReportedPTTServiceStatus == .ready)
        #expect(viewModel.lastReportedPTTServiceStatusChannelUUID == channelUUID)
    }

    @MainActor
    @Test func foregroundJoinedSessionStillReportsConnectingWhileWebSocketReconnects() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.applicationStateOverride = .active
        viewModel.backendRuntime.isReady = true
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        viewModel.syncPTTServiceStatus(reason: "test-foreground")
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(viewModel.lastReportedPTTServiceStatus == .connecting)
        #expect(viewModel.lastReportedPTTServiceStatusChannelUUID == channelUUID)
    }

    @MainActor
    @Test func backgroundTransitionDoesNotSuspendActiveTransmitSession() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.isTransmitting = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        #expect(
            viewModel.shouldSuspendForegroundMediaForBackgroundTransition(
                applicationState: .background
            ) == false
        )
    }

    @MainActor
    @Test func wakePlaybackFallbackDefersUntilApplicationBecomesActive() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]

        var pendingPush = PendingIncomingPTTPush(
            contactID: contactID,
            channelUUID: channelUUID,
            payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel-123",
                activeSpeaker: "Blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
        )
        pendingPush.bufferedAudioChunks = ["AQI=", "AwQ="]
        viewModel.pttWakeRuntime.store(pendingPush)

        await viewModel.runWakePlaybackFallbackIfNeeded(
            for: contactID,
            reason: "test-background",
            applicationState: .background
        )

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .awaitingPTTActivation)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks == ["AQI=", "AwQ="])

        await viewModel.resumeBufferedWakePlaybackIfNeeded(
            reason: "test-active",
            applicationState: .active
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.playbackMode == .appManagedFallback)
        #expect(viewModel.pttWakeRuntime.pendingIncomingPush?.bufferedAudioChunks.isEmpty == true)
        #expect(viewModel.mediaSessionContactID == contactID)
        #expect(viewModel.mediaConnectionState != .idle)
    }

    @Test func mediaRuntimeDelaysRetryAfterRecentStartFailure() {
        let contactID = UUID()
        let context = MediaSessionStartupContext(
            contactID: contactID,
            activationMode: .appManaged,
            startupMode: .playbackOnly
        )
        let runtime = MediaRuntimeState()

        runtime.markStartupInFlight(context)
        runtime.markStartupFailed(context, message: "session activation failed")

        #expect(runtime.connectionState == .failed("session activation failed"))
        #expect(runtime.shouldDelayRetry(for: context, cooldown: 0.75))
        #expect(runtime.shouldDelayRetry(for: context, now: Date().addingTimeInterval(1.0), cooldown: 0.75) == false)
    }

    @Test func selectedPeerStateUsesTransmitSignalWhileReceiverRefreshLags() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: true,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.ready.rawValue,
                    canTransmit: true
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        #expect(selectedPeerState.phase == .receiving)
    }

    @MainActor
    @Test func selectedPeerCoordinatorProjectsPeerSignalReceivingState() {
        let contactID = UUID()
        let coordinator = SelectedPeerCoordinator()

        coordinator.send(
            .selectedContactChanged(
                SelectedPeerSelection(
                    contactID: contactID,
                    contactName: "Avery",
                    contactIsOnline: true
                )
            )
        )
        coordinator.send(.relationshipUpdated(.none))
        coordinator.send(.baseStateUpdated(.ready))
        coordinator.send(
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: TurboChannelStateResponse(
                        channelId: "channel",
                        selfUserId: "self",
                        peerUserId: "peer",
                        peerHandle: "@avery",
                        selfOnline: true,
                        peerOnline: true,
                        selfJoined: true,
                        peerJoined: true,
                        peerDeviceConnected: true,
                        hasIncomingRequest: false,
                        hasOutgoingRequest: false,
                        requestCount: 0,
                        activeTransmitterUserId: nil,
                        transmitLeaseExpiresAt: nil,
                        status: ConversationState.ready.rawValue,
                        canTransmit: true
                    )
                )
            )
        )
        coordinator.send(
            .localSessionUpdated(
                isJoined: true,
                activeChannelID: contactID,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            )
        )
        coordinator.send(.localTransmitUpdated(.idle))
        coordinator.send(.peerSignalTransmittingUpdated(true))
        coordinator.send(
            .systemSessionUpdated(
                .active(contactID: contactID, channelUUID: UUID()),
                matchesSelectedContact: true
            )
        )

        #expect(coordinator.state.selectedPeerState.phase == .receiving)
    }

    @MainActor
    @Test func selectedPeerCoordinatorSendExecutesRequesterAutoJoinEffectWhenPeerBecomesReady() async {
        let contactID = UUID()
        let coordinator = SelectedPeerCoordinator()
        var observedEffects: [SelectedPeerEffect] = []
        coordinator.effectHandler = { effect in
            observedEffects.append(effect)
        }

        coordinator.send(
            .selectedContactChanged(
                SelectedPeerSelection(
                    contactID: contactID,
                    contactName: "Blake",
                    contactIsOnline: true
                )
            )
        )
        coordinator.send(.shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true))
        coordinator.send(.relationshipUpdated(.none))
        coordinator.send(.baseStateUpdated(.idle))
        coordinator.send(.channelUpdated(nil))
        coordinator.send(
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            )
        )
        coordinator.send(.systemSessionUpdated(.none, matchesSelectedContact: false))

        await coordinator.handle(.joinRequested)

        #expect(observedEffects == [.requestConnection(contactID: contactID)])
        #expect(coordinator.state.requesterAutoJoinOnPeerAcceptanceArmed)

        observedEffects.removeAll()

        coordinator.send(
            .channelUpdated(
                ChannelReadinessSnapshot(
                    channelState: makeChannelState(
                        status: .waitingForPeer,
                        canTransmit: false,
                        selfJoined: false,
                        peerJoined: true,
                        peerDeviceConnected: false
                    )
                )
            )
        )

        await Task.yield()
        await Task.yield()

        #expect(observedEffects == [.joinReadyPeer(contactID: contactID)])
        #expect(!coordinator.state.requesterAutoJoinOnPeerAcceptanceArmed)
        #expect(coordinator.state.selectedPeerState.phase == .waitingForPeer)
        #expect(coordinator.state.selectedPeerState.statusMessage == "Connecting...")
    }

    @Test func selectedPeerStateShowsReceivingFromBackendTransmitWithoutSignalOrReadyAudio() {
        let contactID = UUID()
        let context = ConversationDerivationContext(
            contactID: contactID,
            selectedContactID: contactID,
            baseState: .ready,
            contactName: "Avery",
            contactIsOnline: true,
            isJoined: true,
            localIsTransmitting: false,
            peerSignalIsTransmitting: false,
            activeChannelID: contactID,
            systemSessionMatchesContact: true,
            systemSessionState: .active(contactID: contactID, channelUUID: UUID()),
            pendingAction: .none,
            localJoinFailure: nil,
            incomingWakeActivationState: nil,
            channel: ChannelReadinessSnapshot(
                channelState: TurboChannelStateResponse(
                    channelId: "channel",
                    selfUserId: "self",
                    peerUserId: "peer",
                    peerHandle: "@avery",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: true,
                    peerJoined: true,
                    peerDeviceConnected: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: "peer",
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.receiving.rawValue,
                    canTransmit: false
                ),
                readiness: makeChannelReadiness(
                    status: .peerTransmitting(activeTransmitterUserId: "peer"),
                    remoteAudioReadiness: .waiting,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        let selectedPeerState = ConversationStateMachine.selectedPeerState(for: context, relationship: .none)
        #expect(selectedPeerState.phase == .receiving)
        #expect(selectedPeerState.detail == .receiving)
        #expect(selectedPeerState.statusMessage == "Avery is talking")
    }

    @MainActor
    @Test func activeTransmitTargetMatchesSystemChannel() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-1",
            remoteUserID: "user-blake",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))

        #expect(viewModel.activeTransmitTarget(for: channelUUID) == target)
    }

    @MainActor
    @Test func activeTransmitTargetRejectsMismatchedSystemChannel() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel-1",
            remoteUserID: "user-blake",
            channelUUID: UUID(),
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.transmitCoordinator.handle(.pressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))

        #expect(viewModel.activeTransmitTarget(for: UUID()) == nil)
    }

    @MainActor
    @Test func activeTransmitTargetFallsBackToLatchedRuntimeTargetWhilePressIsHeld() async {
        let viewModel = PTTViewModel()
        viewModel.transmitCoordinator.effectHandler = nil

        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncTransmitState()

        #expect(viewModel.transmitCoordinator.state.activeTarget == nil)
        #expect(viewModel.activeTransmitTarget(for: channelUUID) == target)
    }

    @MainActor
    @Test func transmitProjectionDerivesRequestingPhaseFromLatchedRuntimeTarget() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-blake",
            deviceID: "device-blake",
            channelID: "channel-1"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncTransmitState()

        #expect(viewModel.transmitProjection.activeTarget == target)
        #expect(viewModel.transmitDomainSnapshot.phase == .requesting(contactID: contactID))
    }

    @MainActor
    @Test func activateTransmitStartsLeaseRenewalBeforePTTActivationCompletes() async {
        let viewModel = PTTViewModel()
        let channelUUID = UUID()
        let contactID = UUID()

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "user-self",
            mode: "cloud"
        )
        await viewModel.initializeIfNeeded()
        try? viewModel.pttSystemClient.joinChannel(channelUUID: channelUUID, name: "Chat with Avery")
        try? await Task.sleep(nanoseconds: 250_000_000)

        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@avery",
            backendChannelID: "channel-1",
            remoteUserID: "user-avery",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-1"
        )

        await viewModel.runTransmitEffect(.activateTransmit(request, target))

        #expect(viewModel.transmitTaskCoordinator.state.renewal.target == target)
        #expect(viewModel.transmitTaskRuntime.renewalTask != nil)
        #expect(viewModel.transmitTaskRuntime.renewalChannelID == "channel-1")
    }

    @MainActor
    @Test func syncTransmitStateClearsStaleIdlePressLatch() async {
        let viewModel = PTTViewModel()
        viewModel.transmitRuntime.markPressBegan()

        viewModel.syncTransmitState()

        #expect(viewModel.isTransmitPressActive == false)
        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitRuntime.activeTarget == nil)
    }

    @MainActor
    @Test func explicitTransmitStopFallbackClearsStaleSystemTransmittingState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                source: "test"
            )
        )
        viewModel.syncPTTState()

        #expect(viewModel.isTransmitting)

        await viewModel.reconcileExplicitTransmitStopIfNeeded(
            target: target,
            source: "test-fallback"
        )

        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(viewModel.isTransmitting == false)
    }

    @MainActor
    @Test func explicitTransmitStopLocalCompletionClearsCoordinatorAfterRelease() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                source: "test"
            )
        )
        await viewModel.transmitCoordinator.handle(
            .beginSucceeded(
                target,
                TransmitRequestContext(
                    contactID: contactID,
                    contactHandle: "@avery",
                    backendChannelID: "channel-avery",
                    remoteUserID: "user-avery",
                    channelUUID: channelUUID,
                    usesLocalHTTPBackend: false,
                    backendSupportsWebSocket: true
                )
            )
        )
        await viewModel.transmitCoordinator.handle(.releaseRequested)
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncPTTState()
        viewModel.syncTransmitState()

        await viewModel.finalizeExplicitTransmitStopLocallyIfNeeded(
            target: target,
            source: "test-local-complete"
        )

        #expect(viewModel.transmitDomainSnapshot.hasTransmitIntent(for: contactID) == false)
        #expect(viewModel.pttCoordinator.state.isTransmitting == false)
        #expect(viewModel.isTransmitting == false)
        #expect(viewModel.transmitCoordinator.state.activeTarget == nil)
        switch viewModel.transmitCoordinator.state.phase {
        case .idle:
            break
        case .requesting, .active, .stopping:
            Issue.record("Expected transmit coordinator to return to idle after local stop completion")
        }
    }

    @MainActor
    @Test func transmitDomainSnapshotSuppressesTransmitIntentAfterExplicitStop() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.transmitRuntime.markExplicitStopRequested()
        viewModel.syncTransmitState()

        let snapshot = viewModel.transmitDomainSnapshot

        #expect(snapshot.isPressActive == false)
        #expect(snapshot.hasTransmitIntent(for: contactID) == false)
        #expect(snapshot.isStopping(for: contactID))
    }

    @MainActor
    @Test func transmitDomainSnapshotTracksInterruptedHoldUntilRelease() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let target = TransmitTarget(
            contactID: contactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.transmitRuntime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)

        let interruptedSnapshot = viewModel.transmitDomainSnapshot
        #expect(interruptedSnapshot.requiresFreshPress(for: contactID))
        #expect(interruptedSnapshot.hasTransmitIntent(for: contactID) == false)

        viewModel.transmitRuntime.noteTouchReleased()

        let releasedSnapshot = viewModel.transmitDomainSnapshot
        #expect(releasedSnapshot.requiresFreshPress(for: contactID) == false)
    }

    @Test func transmitRuntimeTracksSystemTransmitDurationAndClearsItOnEnd() {
        var runtime = TransmitRuntimeState()
        let beganAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 101.25)

        runtime.noteSystemTransmitBegan(at: beganAt)

        #expect(runtime.currentSystemTransmitDurationMilliseconds(at: endedAt) == 1250)

        runtime.noteSystemTransmitEnded()

        #expect(runtime.currentSystemTransmitDurationMilliseconds(at: endedAt) == nil)
    }

    @Test func transmitRuntimeTracksPendingSystemTransmitBeginState() {
        var runtime = TransmitRuntimeState()
        let channelUUID = UUID()

        runtime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        #expect(runtime.pendingSystemBeginChannelUUID == channelUUID)
        #expect(runtime.isSystemTransmitBeginPending(channelUUID: channelUUID))

        runtime.clearPendingSystemTransmitBegin(channelUUID: channelUUID)

        #expect(runtime.pendingSystemBeginChannelUUID == nil)
        #expect(runtime.isSystemTransmitBeginPending(channelUUID: channelUUID) == false)
    }

    @Test func transmitRuntimeHandleSystemTransmitEndedUsesReducerClassification() {
        var runtime = TransmitRuntimeState()
        let target = TransmitTarget(
            contactID: UUID(),
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-123"
        )

        runtime.markPressBegan()
        runtime.syncActiveTarget(target)
        runtime.noteSystemTransmitBeginRequested(channelUUID: UUID())
        runtime.noteSystemTransmitBegan(at: Date(timeIntervalSince1970: 100))

        let disposition = runtime.handleSystemTransmitEnded(
            applicationStateIsActive: true,
            matchingActiveTarget: target
        )

        #expect(disposition == .requireFreshPress(contactID: target.contactID))
        #expect(runtime.requiresReleaseBeforeNextPress)
        #expect(runtime.activeTarget == target)
        #expect(runtime.pendingSystemBeginChannelUUID == nil)
        #expect(runtime.currentSystemTransmitDurationMilliseconds(at: Date(timeIntervalSince1970: 101)) == nil)
    }

    @MainActor
    @Test func systemTransmitCallbacksClearPendingSystemBeginState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID

        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        viewModel.handleDidBeginTransmitting(channelUUID, source: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitRuntime.pendingSystemBeginChannelUUID == nil)

        viewModel.transmitRuntime.noteSystemTransmitBeginRequested(channelUUID: channelUUID)
        viewModel.handleFailedToBeginTransmitting(
            channelUUID,
            error: NSError(domain: PTChannelErrorDomain, code: 1)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitRuntime.pendingSystemBeginChannelUUID == nil)
    }

    @MainActor
    @Test func systemTransmitBeginWithoutLocalPressStartsSystemOriginatedTransmitRequest() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "self-user",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.handleDidBeginTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitCoordinator.state.phase == .requesting(contactID: contactID))
        #expect(viewModel.transmitCoordinator.state.isPressingTalk)
        #expect(viewModel.transmitCoordinator.state.pendingRequest?.channelUUID == channelUUID)
        #expect(viewModel.transmitRuntime.isPressingTalk)
    }

    @MainActor
    @Test func systemOriginatedBackgroundTransmitResumesSuspendedWebSocketBeforeBackendBegin() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        client.suspendWebSocket()
        observedStates.removeAll()

        viewModel.handleDidBeginTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(observedStates.contains(.connecting))
    }

    @MainActor
    @Test func systemTransmitEndClearsPendingSystemOriginatedRequestBeforeBackendGrant() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.applyAuthenticatedBackendSession(
            client: TurboBackendClient(config: makeUnreachableBackendConfig()),
            userID: "self-user",
            mode: "cloud"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]
        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        viewModel.syncPTTState()

        viewModel.handleDidBeginTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)
        viewModel.handleDidEndTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.transmitCoordinator.state.phase == .idle)
        #expect(viewModel.transmitCoordinator.state.pendingRequest == nil)
        #expect(viewModel.transmitCoordinator.state.isPressingTalk == false)
    }

    @MainActor
    @Test func backgroundSystemTransmitEndActsAsImplicitReleaseWithoutFreshPressBarrier() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@avery",
            backendChannelID: "channel-avery",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-avery"
        )

        viewModel.applicationStateOverride = .background
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                source: "system-ui"
            )
        )
        await viewModel.transmitCoordinator.handle(.systemPressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncPTTState()

        viewModel.handleDidEndTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = viewModel.transmitDomainSnapshot
        #expect(snapshot.requiresFreshPress(for: contactID) == false)
        #expect(snapshot.isPressActive == false)
        #expect(viewModel.transmitRuntime.isPressingTalk == false)
        #expect(viewModel.transmitCoordinator.state.phase == .stopping(contactID: contactID))
    }

    @MainActor
    @Test func activeSystemTransmitEndStillRequiresFreshPressBarrier() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let request = TransmitRequestContext(
            contactID: contactID,
            contactHandle: "@avery",
            backendChannelID: "channel-avery",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel-avery"
        )

        viewModel.applicationStateOverride = .active
        viewModel.transmitCoordinator.effectHandler = nil
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "peer-user"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: channelUUID,
                source: "system-ui"
            )
        )
        await viewModel.transmitCoordinator.handle(.systemPressRequested(request))
        await viewModel.transmitCoordinator.handle(.beginSucceeded(target, request))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.transmitRuntime.syncActiveTarget(target)
        viewModel.syncPTTState()

        viewModel.handleDidEndTransmitting(channelUUID, source: "system-ui")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = viewModel.transmitDomainSnapshot
        #expect(snapshot.requiresFreshPress(for: contactID))
        #expect(snapshot.isPressActive == false)
        #expect(viewModel.transmitCoordinator.state.phase == .stopping(contactID: contactID))
    }

    @MainActor
    @Test func backgroundTransitionSuspendsWebSocketImmediatelyWithoutLateSuspendAfterOfflinePresence() async {
        let viewModel = PTTViewModel()
        let probe = BackgroundTransitionProbe()

        viewModel.backgroundWebSocketSuspendHandler = {
            probe.recordSuspend()
        }
        viewModel.beginBackgroundActivity = { name, _ in
            probe.recordBackgroundTaskBegin(name)
            return UIBackgroundTaskIdentifier(rawValue: 1)
        }
        viewModel.endBackgroundActivity = { _ in
            probe.recordBackgroundTaskEnd()
        }
        viewModel.backgroundOfflinePresenceHandler = {
            probe.recordOfflineStart()
            try? await Task.sleep(nanoseconds: 50_000_000)
            probe.recordOfflineFinish()
        }

        await viewModel.handleApplicationDidEnterBackground()
        let events = probe.events
        #expect(probe.offlineStarted)
        #expect(probe.suspendCount == 1)
        #expect(probe.backgroundTaskStarted)
        #expect(probe.backgroundTaskEnded)
        #expect(events.first == "suspend")
        #expect(events.contains("background-task-begin:offline-presence"))
        #expect(events.contains("offline-start"))
        #expect(events.contains("offline-finish"))
        #expect(events.contains("background-task-end"))
        #expect(events.firstIndex(of: "background-task-begin:offline-presence")! < events.firstIndex(of: "offline-finish")!)
        #expect(events.firstIndex(of: "background-task-end")! > events.firstIndex(of: "offline-finish")!)
    }

    @MainActor
    @Test func backgroundTransitionPreservesJoinedSessionWhilePublishingBackgroundPresence() async {
        let viewModel = PTTViewModel()
        let probe = BackgroundTransitionProbe()
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Kai",
                handle: "@kai",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-kai",
                remoteUserId: "user-kai"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        viewModel.backgroundWebSocketSuspendHandler = {
            probe.recordSuspend()
        }
        viewModel.beginBackgroundActivity = { name, _ in
            probe.recordBackgroundTaskBegin(name)
            return UIBackgroundTaskIdentifier(rawValue: 1)
        }
        viewModel.endBackgroundActivity = { _ in
            probe.recordBackgroundTaskEnd()
        }
        viewModel.backgroundSessionPresenceHandler = {
            probe.recordBackgroundStart()
            try? await Task.sleep(nanoseconds: 50_000_000)
            probe.recordBackgroundFinish()
        }
        viewModel.backgroundOfflinePresenceHandler = {
            probe.recordOfflineStart()
        }

        await viewModel.handleApplicationDidEnterBackground()
        let events = probe.events
        #expect(probe.backgroundStarted)
        #expect(probe.offlineStarted == false)
        #expect(probe.suspendCount == 1)
        #expect(probe.backgroundTaskStarted)
        #expect(probe.backgroundTaskEnded)
        #expect(events.first == "suspend")
        #expect(events.contains("background-task-begin:background-presence"))
        #expect(events.contains("background-start"))
        #expect(events.contains("background-finish"))
        #expect(events.contains("background-task-end"))
        #expect(events.firstIndex(of: "background-task-begin:background-presence")! < events.firstIndex(of: "background-finish")!)
        #expect(events.firstIndex(of: "background-task-end")! > events.firstIndex(of: "background-finish")!)
    }

    @MainActor
    @Test func resetLocalDevStateClearsVisibleSessionErrorsAndTransientState() {
        let viewModel = PTTViewModel()
        let contactID = UUID()

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.remoteTransmittingContactIDs = [contactID]
        viewModel.remoteAudioSilenceTasks[contactID] = Task {}
        viewModel.statusMessage = "Join failed: stale channel"
        viewModel.diagnostics.record(.media, level: .error, message: "Old error")

        viewModel.resetLocalDevState(backendStatus: "Reconnecting as @blake...")

        #expect(viewModel.selectedContactId == nil)
        #expect(viewModel.contacts.isEmpty)
        #expect(viewModel.remoteTransmittingContactIDs.isEmpty)
        #expect(viewModel.remoteAudioSilenceTasks.isEmpty)
        #expect(viewModel.statusMessage == "Initializing...")
        #expect(viewModel.backendStatusMessage == "Reconnecting as @blake...")
        #expect(viewModel.diagnostics.latestError == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Old error") == false)
    }

    @MainActor
    @Test func resetLocalDevStateClearsSelectedPeerShortcutStateBeforeFreshSelection() async {
        let viewModel = PTTViewModel()
        let staleContactID = UUID()
        let freshContactID = UUID()

        viewModel.selectedPeerCoordinator.send(
            .selectedContactChanged(
                SelectedPeerSelection(
                    contactID: staleContactID,
                    contactName: "Blake",
                    contactIsOnline: true
                )
            )
        )
        viewModel.selectedPeerCoordinator.send(
            .shortcutPolicyUpdated(requesterAutoJoinOnPeerAcceptanceEnabled: true)
        )
        viewModel.selectedPeerCoordinator.send(.relationshipUpdated(.none))
        viewModel.selectedPeerCoordinator.send(.baseStateUpdated(.idle))
        viewModel.selectedPeerCoordinator.send(.channelUpdated(nil))
        viewModel.selectedPeerCoordinator.send(
            .localSessionUpdated(
                isJoined: false,
                activeChannelID: nil,
                pendingAction: .none,
                pendingConnectAcceptedIncomingRequest: false,
                localJoinFailure: nil
            )
        )
        viewModel.selectedPeerCoordinator.send(.systemSessionUpdated(.none, matchesSelectedContact: false))

        await viewModel.selectedPeerCoordinator.handle(.joinRequested)

        #expect(viewModel.selectedPeerCoordinator.state.requesterAutoJoinOnPeerAcceptanceArmed)

        viewModel.resetLocalDevState(backendStatus: "Reconnecting as @kai...")

        #expect(!viewModel.selectedPeerCoordinator.state.requesterAutoJoinOnPeerAcceptanceArmed)
        #expect(!viewModel.selectedPeerCoordinator.state.requesterAutoJoinOnPeerAcceptanceDispatchInFlight)
        #expect(viewModel.selectedPeerCoordinator.state.selection == nil)

        viewModel.contacts = [
            Contact(
                id: freshContactID,
                name: "Kai",
                handle: "@kai",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-kai",
                remoteUserId: "user-kai"
            )
        ]

        guard let kai = viewModel.contacts.first else {
            Issue.record("missing fresh contact after reset")
            return
        }

        viewModel.selectContact(kai)

        let selectedPeerState = viewModel.selectedPeerState(for: freshContactID)

        #expect(selectedPeerState.phase == .idle)
        #expect(selectedPeerState.statusMessage == "Kai is online")
    }

    @MainActor
    @Test func explicitTransmitStopFallbackIgnoresMismatchedChannel() async {
        let viewModel = PTTViewModel()
        let joinedContactID = UUID()
        let targetContactID = UUID()
        let joinedChannelUUID = UUID()
        let target = TransmitTarget(
            contactID: targetContactID,
            userID: "user-avery",
            deviceID: "device-avery",
            channelID: "channel-avery"
        )

        viewModel.contacts = [
            Contact(
                id: joinedContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: joinedChannelUUID,
                backendChannelId: "channel-joined",
                remoteUserId: "user-avery"
            ),
            Contact(
                id: targetContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-avery",
                remoteUserId: "user-blake"
            )
        ]

        await viewModel.pttCoordinator.handle(
            .didJoinChannel(
                channelUUID: joinedChannelUUID,
                contactID: joinedContactID,
                reason: "test"
            )
        )
        await viewModel.pttCoordinator.handle(
            .didBeginTransmitting(
                channelUUID: joinedChannelUUID,
                source: "test"
            )
        )
        viewModel.syncPTTState()

        await viewModel.reconcileExplicitTransmitStopIfNeeded(
            target: target,
            source: "test-fallback"
        )

        #expect(viewModel.pttCoordinator.state.isTransmitting)
        #expect(viewModel.isTransmitting)
    }

    @Test func pttReducerRestoredUnknownChannelIsMismatched() {
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .restoredChannel(channelUUID: channelUUID, contactID: nil)
        )

        #expect(transition.state.isJoined)
        #expect(transition.state.systemSessionState == .mismatched(channelUUID: channelUUID))
        #expect(transition.effects.isEmpty)
    }

    @Test func pttReducerJoinEmitsSyncEffect() {
        let contactID = UUID()
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "push")
        )

        #expect(transition.state.isJoined)
        #expect(transition.state.activeContactID == contactID)
        #expect(transition.state.systemSessionState == .active(contactID: contactID, channelUUID: channelUUID))
        #expect(transition.effects == [.syncJoinedChannel(contactID: contactID)])
    }

    @Test func pttReducerLeaveEmitsSyncAndAutoRejoinEffects() {
        let contactID = UUID()
        let channelUUID = UUID()
        let joinedState = PTTReducer.reduce(
            state: .initial,
            event: .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "manual")
        ).state
        let autoRejoinContactID = UUID()

        let transition = PTTReducer.reduce(
            state: joinedState,
            event: .didLeaveChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: "switch",
                autoRejoinContactID: autoRejoinContactID
            )
        )

        #expect(transition.state.isJoined == false)
        #expect(transition.state.systemSessionState == .none)
        #expect(
            transition.effects == [
                .syncLeftChannel(contactID: contactID, autoRejoinContactID: autoRejoinContactID)
            ]
        )
    }

    @Test func pttReducerSystemTransmitFailureEmitsTransmitFailureEffect() {
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: PTTSessionState(
                systemChannelUUID: channelUUID,
                activeContactID: UUID(),
                isJoined: true,
                isTransmitting: true,
                lastError: nil
            ),
            event: .failedToBeginTransmitting(channelUUID: channelUUID, message: "denied")
        )

        #expect(transition.state.isTransmitting == false)
        #expect(transition.state.lastError == "denied")
        #expect(transition.effects == [.handleSystemTransmitFailure("denied")])
    }

    @Test func pttReducerCapturesJoinFailureReasonAndContact() {
        let contactID = UUID()
        let channelUUID = UUID()

        let transition = PTTReducer.reduce(
            state: .initial,
            event: .failedToJoinChannel(
                channelUUID: channelUUID,
                contactID: contactID,
                reason: .channelLimitReached
            )
        )

        #expect(transition.state.isJoined == false)
        #expect(transition.state.lastError == "Channel limit reached")
        #expect(
            transition.state.lastJoinFailure
                == PTTJoinFailure(
                    contactID: contactID,
                    channelUUID: channelUUID,
                    reason: .channelLimitReached
                )
        )
        #expect(transition.effects == [.closeMediaSession])
    }

    @Test func backendSyncReducerPollRequestsBootstrapBeforeConnectionEstablished() {
        let contactID = UUID()

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .pollRequested(selectedContactID: contactID)
        )

        #expect(transition.effects == [.bootstrapIfNeeded])
    }

    @Test func backendSyncReducerPollRefreshesSelectedChannelAfterBootstrapEstablished() {
        let contactID = UUID()
        var state = BackendSyncSessionState()
        state.syncState.hasEstablishedConnection = true

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .pollRequested(selectedContactID: contactID)
        )

        #expect(
            transition.effects == [
                .ensureWebSocketConnected,
                .heartbeatPresence,
                .refreshContactSummaries,
                .refreshInvites,
                .refreshChannelState(contactID)
            ]
        )
    }

    @Test func backendSyncReducerReconnectRefreshesSelectedSession() {
        let contactID = UUID()

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .webSocketStateChanged(.connected, selectedContactID: contactID)
        )

        #expect(
            transition.effects == [
                .heartbeatPresence,
                .refreshContactSummaries,
                .refreshInvites,
                .refreshChannelState(contactID)
            ]
        )
    }

    @Test func backendSyncReducerIdleInvalidatesStaleRemoteReceiverReady() {
        let contactID = UUID()
        var state = BackendSyncSessionState()
        state.syncState.channelReadiness[contactID] = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
        )

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .webSocketStateChanged(.idle, selectedContactID: contactID)
        )

        #expect(
            transition.state.syncState.channelReadiness[contactID]?.remoteAudioReadiness
                == .wakeCapable
        )
        #expect(transition.effects.isEmpty)
    }

    @Test func backendSyncReducerIdleDropsStaleRemoteReceiverReadyWithoutWakeCapability() {
        let contactID = UUID()
        var state = BackendSyncSessionState()
        state.syncState.channelReadiness[contactID] = makeChannelReadiness(
            status: .ready,
            remoteAudioReadiness: .ready,
            remoteWakeCapability: .unavailable
        )

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .webSocketStateChanged(.idle, selectedContactID: contactID)
        )

        #expect(
            transition.state.syncState.channelReadiness[contactID]?.remoteAudioReadiness
                == .unknown
        )
        #expect(transition.effects.isEmpty)
    }

    @Test func controlPlaneReducerDefersReceiverAudioReadinessUntilReconnect() {
        let contactID = UUID()
        let intent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: "channel-refresh"
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(),
            event: .receiverAudioReadinessSyncRequested(
                intent,
                peerIsRoutable: true,
                webSocketConnected: false
            )
        )

        #expect(
            transition.state.receiverAudioReadinessStates[contactID]
                == .deferred(intent)
        )
        #expect(
            transition.effects == [
                .deferReceiverAudioReadinessUntilReconnect(intent)
            ]
        )
        #expect(transition.state.localReceiverAudioReadinessPublications[contactID] == nil)
    }

    @Test func controlPlaneReducerRepublishesWhenPeerBecomesRoutableAfterSuppression() {
        let contactID = UUID()
        let intent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: "channel-refresh"
        )

        let firstTransition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(),
            event: .receiverAudioReadinessSyncRequested(
                intent,
                peerIsRoutable: false,
                webSocketConnected: true
            )
        )

        #expect(
            firstTransition.state.receiverAudioReadinessStates[contactID]
                == .suppressed(intent.suppressedState)
        )
        #expect(firstTransition.effects.isEmpty)

        let secondTransition = ControlPlaneReducer.reduce(
            state: firstTransition.state,
            event: .receiverAudioReadinessSyncRequested(
                intent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(secondTransition.effects == [.publishReceiverAudioReadiness(intent)])
    }

    @Test func controlPlaneReducerReconnectPublishesDeferredReceiverReadiness() {
        let contactID = UUID()
        let intent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: false,
            reason: "app-background-media-closed"
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(
                receiverAudioReadinessStates: [contactID: .deferred(intent)]
            ),
            event: .webSocketStateChanged(.connected)
        )

        #expect(
            transition.effects == [
                .publishReceiverAudioReadiness(intent)
            ]
        )
        #expect(
            transition.state.receiverAudioReadinessStates[contactID]
                == .deferred(intent)
        )
    }

    @Test func controlPlaneReducerRepublishesReadyOnFirstChannelRefreshAfterLifecyclePublish() {
        let contactID = UUID()
        let lifecycleIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: "media-connected"
        )
        let refreshIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: "channel-refresh"
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(
                receiverAudioReadinessStates: [
                    contactID: .published(lifecycleIntent.publishedState)
                ]
            ),
            event: .receiverAudioReadinessSyncRequested(
                refreshIntent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(transition.effects == [.publishReceiverAudioReadiness(refreshIntent)])
    }

    @Test func controlPlaneReducerDoesNotRepublishRepeatedChannelRefreshReady() {
        let contactID = UUID()
        let refreshIntent = ReceiverAudioReadinessIntent(
            contactID: contactID,
            contactHandle: "@blake",
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            currentUserID: "self-user",
            deviceID: "self-device",
            isReady: true,
            reason: "channel-refresh"
        )

        let transition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(
                receiverAudioReadinessStates: [
                    contactID: .published(refreshIntent.publishedState)
                ]
            ),
            event: .receiverAudioReadinessSyncRequested(
                refreshIntent,
                peerIsRoutable: true,
                webSocketConnected: true
            )
        )

        #expect(transition.effects.isEmpty)
    }

    @Test func controlPlaneReducerRunsPostWakeRepairAtMostOncePerContact() {
        let contactID = UUID()
        let firstTransition = ControlPlaneReducer.reduce(
            state: ControlPlaneSessionState(),
            event: .postWakeRepairRequested(contactID: contactID)
        )
        let secondTransition = ControlPlaneReducer.reduce(
            state: firstTransition.state,
            event: .postWakeRepairRequested(contactID: contactID)
        )

        #expect(firstTransition.state.postWakeRepairContactIDs == [contactID])
        #expect(
            firstTransition.effects == [
                .performPostWakeRepair(contactID: contactID)
            ]
        )
        #expect(secondTransition.state.postWakeRepairContactIDs == [contactID])
        #expect(secondTransition.effects.isEmpty)
    }

    @MainActor
    @Test func applicationDidBecomeActiveRequestsBackendBootstrapBeforeConnectionEstablished() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.selectedContactId = contactID

        var capturedEffects: [BackendSyncEffect] = []
        viewModel.backendSyncCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.handleApplicationDidBecomeActive()

        #expect(capturedEffects == [.bootstrapIfNeeded])
    }

    @MainActor
    @Test func applicationDidBecomeActiveRequestsBackendPollForSelectedContactAfterBootstrapEstablished() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(.bootstrapCompleted(mode: "cloud", handle: "@self"))

        var capturedEffects: [BackendSyncEffect] = []
        viewModel.backendSyncCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.handleApplicationDidBecomeActive()

        #expect(
            capturedEffects == [
                .ensureWebSocketConnected,
                .heartbeatPresence,
                .refreshContactSummaries,
                .refreshInvites,
                .refreshChannelState(contactID)
            ]
        )
    }

    @MainActor
    @Test func applicationDidBecomeActiveCanSkipAppManagedAudioPrewarmWhenDisabled() async {
        let viewModel = PTTViewModel()
        viewModel.foregroundAppManagedInteractiveAudioPrewarmEnabled = false
        viewModel.applicationStateOverride = .active
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )

        await viewModel.handleApplicationDidBecomeActive()

        #expect(viewModel.mediaSessionContactID == nil)
        #expect(viewModel.mediaConnectionState == .idle)
        #expect(viewModel.localMediaWarmupState(for: contactID) == .cold)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Skipped app-managed interactive audio prewarm after app activation"
            )
        )
    }

    @MainActor
    @Test func transientBackendBootstrapFailureRetriesWhenForegrounded() {
        let viewModel = PTTViewModel()
        let error = URLError(.timedOut)

        #expect(
            viewModel.shouldAutoRetryBackendBootstrapFailure(
                error,
                applicationState: .active
            )
        )
    }

    @MainActor
    @Test func transientBackendBootstrapFailureDoesNotRetryInBackground() {
        let viewModel = PTTViewModel()
        let error = URLError(.timedOut)

        #expect(
            viewModel.shouldAutoRetryBackendBootstrapFailure(
                error,
                applicationState: .background
            ) == false
        )
    }

    @MainActor
    @Test func nonTransientBackendBootstrapFailureDoesNotRetry() {
        let viewModel = PTTViewModel()
        let error = TurboBackendError.invalidResponse

        #expect(
            viewModel.shouldAutoRetryBackendBootstrapFailure(
                error,
                applicationState: .active
            ) == false
        )
    }

    @MainActor
    @Test func transientForegroundSyncFailureRecoversConnectedControlPlane() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setWebSocketConnectionStateForTesting(.connected)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")

        #expect(
            viewModel.shouldRecoverBackendControlPlaneAfterSyncFailure(
                URLError(.timedOut),
                applicationState: .active
            )
        )
    }

    @MainActor
    @Test func transientSyncFailureDoesNotRecoverDisconnectedControlPlane() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setWebSocketConnectionStateForTesting(.idle)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")

        #expect(
            viewModel.shouldRecoverBackendControlPlaneAfterSyncFailure(
                URLError(.timedOut),
                applicationState: .active
            ) == false
        )
    }

    @MainActor
    @Test func applicationDidBecomeActiveClearsBadgeAndDeliveredNotifications() async {
        let viewModel = PTTViewModel()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }

        await viewModel.handleApplicationDidBecomeActive()

        #expect(badgeCounts == [0])
        #expect(clearNotificationsCallCount == 1)
    }

    @MainActor
    @Test func foregroundPresencePublishingRequiresActiveApplicationState() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .active))
        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .inactive) == false)
        #expect(viewModel.shouldPublishForegroundPresence(applicationState: .background) == false)
    }

    @MainActor
    @Test func talkRequestBadgeCountUsesUniqueIncomingContacts() {
        let viewModel = PTTViewModel()
        let firstContactID = UUID()
        let secondContactID = UUID()

        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [
                    BackendInviteUpdate(
                        contactID: firstContactID,
                        invite: makeInvite(direction: "incoming", requestCount: 3)
                    ),
                    BackendInviteUpdate(
                        contactID: secondContactID,
                        invite: makeInvite(direction: "incoming", requestCount: 1)
                    ),
                ],
                outgoing: [],
                now: .now
            )
        )

        #expect(viewModel.pendingIncomingTalkRequestBadgeCount == 2)
    }

    @MainActor
    @Test func talkRequestBadgeSyncAppliesUniqueIncomingContactCountWhileBackgrounded() {
        let viewModel = PTTViewModel()
        let firstContactID = UUID()
        let secondContactID = UUID()
        var badgeCounts: [Int] = []
        var clearNotificationsCallCount = 0
        viewModel.setApplicationBadgeCount = { badgeCounts.append($0) }
        viewModel.clearDeliveredNotifications = { clearNotificationsCallCount += 1 }

        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [
                    BackendInviteUpdate(
                        contactID: firstContactID,
                        invite: makeInvite(direction: "incoming", requestCount: 4)
                    ),
                    BackendInviteUpdate(
                        contactID: secondContactID,
                        invite: makeInvite(direction: "incoming", requestCount: 1)
                    ),
                ],
                outgoing: [],
                now: .now
            )
        )

        viewModel.syncTalkRequestNotificationBadge(applicationState: .background)

        #expect(badgeCounts == [2])
        #expect(clearNotificationsCallCount == 0)
    }

    @MainActor
    @Test func notificationOpenSelectsCachedIncomingRequestContactBeforeBackendIsReady() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let invite = makeInvite(
            direction: "incoming",
            inviteId: "invite-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: invite.channelId,
                remoteUserId: invite.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [BackendInviteUpdate(contactID: contactID, invite: invite)],
                outgoing: [],
                now: .now
            )
        )

        await viewModel.handleTalkRequestNotificationResponse(
            userInfo: ["event": "talk-request", "fromHandle": "@avery", "inviteId": "invite-1"]
        )

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.pendingTalkRequestNotificationHandle == "@avery")
    }

    @MainActor
    @Test func contactSelectionReconcilePrefersIncomingRequestOverFallbackContact() {
        let viewModel = PTTViewModel()
        let fallbackContactID = UUID()
        let requestContactID = UUID()
        viewModel.contacts = [
            Contact(
                id: fallbackContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID()
            ),
            Contact(
                id: requestContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
        ]
        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [
                    BackendInviteUpdate(
                        contactID: requestContactID,
                        invite: makeInvite(direction: "incoming", fromHandle: "@avery")
                    )
                ],
                outgoing: [],
                now: .now
            )
        )

        viewModel.reconcileContactSelectionIfNeeded(
            reason: "test",
            allowSelectingFallbackContact: true
        )

        #expect(viewModel.selectedContactId == requestContactID)
    }

    @Test func backendSyncReducerContactSummaryUpdateReplacesSnapshot() {
        let contactID = UUID()
        let summary = makeContactSummary(channelId: "channel-1")

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
    }

    @Test func backendSyncReducerContactSummaryAbsentMembershipDowngradesCachedChannelState() {
        let contactID = UUID()
        let staleChannelState = makeChannelState(status: .ready, canTransmit: true)
        let summary = makeContactSummary(
            channelId: "channel",
            isOnline: true,
            badgeStatus: "online",
            membershipKind: "absent"
        )
        var state = BackendSyncSessionState()
        state.syncState.channelStates[contactID] = staleChannelState
        state.syncState.channelReadiness[contactID] = makeChannelReadiness(status: .ready)

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
        #expect(transition.state.syncState.channelStates[contactID]?.membership == .absent)
        #expect(transition.state.syncState.channelReadiness[contactID] == nil)
    }

    @Test func backendSyncReducerContactSummaryFailurePreservesLastKnownSnapshot() {
        let contactID = UUID()
        let summary = TurboContactSummaryResponse(
            userId: "user-peer",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel-1",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: true,
            requestCount: 1,
            isActiveConversation: false,
            badgeStatus: "requested"
        )
        var state = BackendSyncSessionState()
        state.syncState.contactSummaries[contactID] = summary

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .contactSummariesFailed("Contact sync failed: internal server error")
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
        #expect(transition.state.syncState.statusMessage == "Contact sync failed: internal server error")
    }

    @Test func backendSyncReducerContactSummaryFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let summary = makeContactSummary(channelId: "channel-1")
        var state = BackendSyncSessionState()
        state.syncState.contactSummaries[contactID] = summary
        state.syncState.hasEstablishedConnection = true
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .contactSummariesFailed("Contact sync failed: internal server error")
        )

        #expect(transition.state.syncState.contactSummaries[contactID] == summary)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
    }

    @Test func backendSyncReducerSeededInviteStartsCooldown() {
        let contactID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let invite = makeInvite(direction: "outgoing")

        let transition = BackendSyncReducer.reduce(
            state: BackendSyncSessionState(),
            event: .outgoingInviteSeeded(contactID: contactID, invite: invite, now: now)
        )

        #expect(transition.state.syncState.outgoingInvites[contactID] == invite)
        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == now.addingTimeInterval(30))
        #expect(transition.state.syncState.requestCooldownSourceKeys[contactID] == "\(invite.inviteId)|\(invite.requestCount)|\(invite.updatedAt ?? invite.createdAt)")
    }

    @Test func backendSyncReducerInviteRefreshDoesNotRestartCooldownForSameOutgoingInvite() {
        let contactID = UUID()
        let invite = makeInvite(direction: "outgoing", inviteId: "invite-1")
        let originalNow = Date(timeIntervalSince1970: 1_000)
        let laterNow = originalNow.addingTimeInterval(31)
        var state = BackendSyncSessionState()
        state.syncState.outgoingInvites[contactID] = invite
        state.syncState.requestCooldownDeadlines[contactID] = originalNow.addingTimeInterval(30)
        state.syncState.requestCooldownSourceKeys[contactID] =
            "\(invite.inviteId)|\(invite.requestCount)|\(invite.updatedAt ?? invite.createdAt)"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesUpdated(
                incoming: [],
                outgoing: [BackendInviteUpdate(contactID: contactID, invite: invite)],
                now: laterNow
            )
        )

        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == nil)
        #expect(transition.state.syncState.requestCooldownSourceKeys[contactID] == "\(invite.inviteId)|\(invite.requestCount)|\(invite.updatedAt ?? invite.createdAt)")
    }

    @Test func backendSyncReducerInviteRefreshRestartsCooldownForUpdatedOutgoingInvite() {
        let contactID = UUID()
        let originalInvite = makeInvite(direction: "outgoing", inviteId: "invite-1")
        let updatedInvite = makeInvite(
            direction: "outgoing",
            inviteId: "invite-1",
            requestCount: 2,
            updatedAt: "2026-04-17T21:00:00Z"
        )
        let originalNow = Date(timeIntervalSince1970: 1_000)
        let laterNow = originalNow.addingTimeInterval(31)
        var state = BackendSyncSessionState()
        state.syncState.outgoingInvites[contactID] = originalInvite
        state.syncState.requestCooldownDeadlines[contactID] = originalNow.addingTimeInterval(30)
        state.syncState.requestCooldownSourceKeys[contactID] =
            "\(originalInvite.inviteId)|\(originalInvite.requestCount)|\(originalInvite.updatedAt ?? originalInvite.createdAt)"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesUpdated(
                incoming: [],
                outgoing: [BackendInviteUpdate(contactID: contactID, invite: updatedInvite)],
                now: laterNow
            )
        )

        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == laterNow.addingTimeInterval(30))
        #expect(transition.state.syncState.requestCooldownSourceKeys[contactID] == "\(updatedInvite.inviteId)|\(updatedInvite.requestCount)|\(updatedInvite.updatedAt ?? updatedInvite.createdAt)")
    }

    @Test func backendSyncReducerInviteFailurePreservesLastKnownRequests() {
        let contactID = UUID()
        let incomingInvite = makeInvite(direction: "incoming")
        let outgoingInvite = makeInvite(direction: "outgoing")
        let cooldownDeadline = Date(timeIntervalSince1970: 2_000)
        var state = BackendSyncSessionState()
        state.syncState.incomingInvites[contactID] = incomingInvite
        state.syncState.outgoingInvites[contactID] = outgoingInvite
        state.syncState.requestCooldownDeadlines[contactID] = cooldownDeadline

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesFailed("Invite sync failed: internal server error")
        )

        #expect(transition.state.syncState.incomingInvites[contactID] == incomingInvite)
        #expect(transition.state.syncState.outgoingInvites[contactID] == outgoingInvite)
        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == cooldownDeadline)
        #expect(transition.state.syncState.statusMessage == "Invite sync failed: internal server error")
    }

    @Test func backendSyncReducerInviteFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let incomingInvite = makeInvite(direction: "incoming")
        let outgoingInvite = makeInvite(direction: "outgoing")
        let cooldownDeadline = Date(timeIntervalSince1970: 2_000)
        var state = BackendSyncSessionState()
        state.syncState.incomingInvites[contactID] = incomingInvite
        state.syncState.outgoingInvites[contactID] = outgoingInvite
        state.syncState.requestCooldownDeadlines[contactID] = cooldownDeadline
        state.syncState.hasEstablishedConnection = true
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .invitesFailed("Invite sync failed: internal server error")
        )

        #expect(transition.state.syncState.incomingInvites[contactID] == incomingInvite)
        #expect(transition.state.syncState.outgoingInvites[contactID] == outgoingInvite)
        #expect(transition.state.syncState.requestCooldownDeadlines[contactID] == cooldownDeadline)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
    }

    @MainActor
    @Test func refreshContactSummariesFailurePreservesExistingSelectedContactState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )
        let summary = TurboContactSummaryResponse(
            userId: "user-avery",
            handle: "@avery",
            displayName: "Avery",
            channelId: "channel-1",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: true,
            requestCount: 1,
            isActiveConversation: false,
            badgeStatus: "requested"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.trackContact(contactID)
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        await viewModel.refreshContactSummaries()

        #expect(viewModel.selectedContact?.id == contactID)
        #expect(viewModel.contacts.map(\.id) == [contactID])
        #expect(viewModel.contacts.first?.isOnline == true)
        #expect(viewModel.backendSyncCoordinator.state.syncState.contactSummaries[contactID] == summary)
    }

    @MainActor
    @Test func trackedPresenceFallbackTargetsIncludeTrackedContactsWithoutSummaries() {
        let viewModel = PTTViewModel()
        let trackedContactID = UUID()
        let summarizedContactID = UUID()

        viewModel.contacts = [
            Contact(
                id: trackedContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            ),
            Contact(
                id: summarizedContactID,
                name: "Casey",
                handle: "@casey",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: "channel-casey",
                remoteUserId: "user-casey"
            )
        ]
        viewModel.trackContact(trackedContactID)
        viewModel.trackContact(summarizedContactID)

        let targets = viewModel.trackedPresenceFallbackTargets(
            excluding: [
                summarizedContactID: TurboContactSummaryResponse(
                    userId: "user-casey",
                    handle: "@casey",
                    displayName: "Casey",
                    channelId: "channel-casey",
                    isOnline: true,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    isActiveConversation: false,
                    badgeStatus: "online"
                )
            ]
        )

        #expect(targets.count == 1)
        #expect(targets.first?.contactID == trackedContactID)
        #expect(targets.first?.handle == "@blake")
    }

    @MainActor
    @Test func trackedPresenceFallbackClearsStaleChannelReferenceWhenSummaryIsMissing() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let originalChannelID = "channel-blake"
        let originalStableChannelUUID = ContactDirectory.stableChannelUUID(for: originalChannelID)

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: originalStableChannelUUID,
                backendChannelId: originalChannelID,
                remoteUserId: "user-blake"
            )
        ]
        viewModel.trackContact(contactID)
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: TurboChannelStateResponse(
                    channelId: originalChannelID,
                    selfUserId: "self-user",
                    peerUserId: "user-blake",
                    peerHandle: "@blake",
                    selfOnline: true,
                    peerOnline: true,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false,
                    hasIncomingRequest: false,
                    hasOutgoingRequest: false,
                    requestCount: 0,
                    activeTransmitterUserId: nil,
                    transmitLeaseExpiresAt: nil,
                    status: ConversationState.idle.rawValue,
                    canTransmit: false
                )
            )
        )

        viewModel.clearStaleTrackedChannelReferencesMissingFromSummaries(excluding: [:])

        #expect(viewModel.contacts.first?.backendChannelId == nil)
        #expect(viewModel.contacts.first?.channelId != originalStableChannelUUID)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID] == nil)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelReadiness[contactID] == nil)
    }

    @Test func backendClientPresenceLookupUsesCanonicalPresenceEndpoint() {
        let path = TurboBackendClient.presenceLookupPath(for: "@blake")

        #expect(path == "/v1/users/by-handle/@blake/presence")
        #expect(path.contains("/presence"))
        #expect(path.contains("/presence/") == false)
    }

    @MainActor
    @Test func contactPresencePresentationUsesSummaryOnlineBadgeForForegroundPeer() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            )
        ]
        let summary = TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: "channel-blake",
                isOnline: true,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "online",
                membershipPayload: TurboChannelMembershipPayload(
                    kind: "peer-only",
                    peerDeviceConnected: false
                )
            )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(viewModel.contactPresencePresentation(for: contactID) == .connected)
    }

    @MainActor
    @Test func contactPresencePresentationTreatsIdleDisconnectedSummaryAsReachable() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            )
        ]
        let summary = TurboContactSummaryResponse(
            userId: "user-blake",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel-blake",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            isActiveConversation: false,
            badgeStatus: "idle",
            membershipPayload: TurboChannelMembershipPayload(
                kind: "peer-only",
                peerDeviceConnected: false
            )
        )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        #expect(viewModel.contactPresencePresentation(for: contactID) == .reachable)
        #expect(viewModel.selectedConversationPresenceIsOnline(for: contactID) == false)
    }

    @MainActor
    @Test func contactPresencePresentationKeepsAbsentChannelSnapshotOnline() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            )
        ]
        let summary = TurboContactSummaryResponse(
            userId: "user-blake",
            handle: "@blake",
            displayName: "Blake",
            channelId: "channel-blake",
            isOnline: true,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            isActiveConversation: false,
            badgeStatus: "online",
            membershipPayload: TurboChannelMembershipPayload(kind: "absent", peerDeviceConnected: nil)
        )
        let channelState = TurboChannelStateResponse(
            channelId: "channel-blake",
            selfUserId: "self-user",
            peerUserId: "user-blake",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: false,
            hasOutgoingRequest: false,
            requestCount: 0,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.idle.rawValue,
            canTransmit: false
        )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(contactID: contactID, channelState: channelState)
        )

        #expect(viewModel.contactPresencePresentation(for: contactID) == .connected)
    }

    @MainActor
    @Test func contactPresencePresentationTreatsFallbackPresenceAsOnlineWithoutSummary() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: nil,
                remoteUserId: "user-blake"
            )
        ]

        #expect(viewModel.contactPresencePresentation(for: contactID) == .connected)
    }

    @MainActor
    @Test func contactListSectionsBucketContactsByDerivedGroup() {
        let viewModel = PTTViewModel()
        let incomingID = UUID()
        let readyID = UUID()
        let requestedID = UUID()
        let offlineID = UUID()
        viewModel.contacts = [
            Contact(
                id: incomingID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            ),
            Contact(
                id: readyID,
                name: "Casey",
                handle: "@casey",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-casey"),
                backendChannelId: "channel-casey",
                remoteUserId: "user-casey"
            ),
            Contact(
                id: requestedID,
                name: "Drew",
                handle: "@drew",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-drew"),
                backendChannelId: "channel-drew",
                remoteUserId: "user-drew"
            ),
            Contact(
                id: offlineID,
                name: "Erin",
                handle: "@erin",
                isOnline: false,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-erin"),
                backendChannelId: "channel-erin",
                remoteUserId: "user-erin"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: incomingID,
                    summary: makeContactSummary(
                        channelId: "channel-blake",
                        handle: "@blake",
                        displayName: "Blake",
                        isOnline: true,
                        hasIncomingRequest: true,
                        requestCount: 2,
                        badgeStatus: "incoming",
                        membershipKind: "peer-only",
                        peerDeviceConnected: true
                    )
                ),
                BackendContactSummaryUpdate(
                    contactID: readyID,
                    summary: makeContactSummary(
                        channelId: "channel-casey",
                        handle: "@casey",
                        displayName: "Casey",
                        isOnline: true,
                        badgeStatus: "ready",
                        membershipKind: "both",
                        peerDeviceConnected: true
                    )
                ),
                BackendContactSummaryUpdate(
                    contactID: requestedID,
                    summary: makeContactSummary(
                        channelId: "channel-drew",
                        handle: "@drew",
                        displayName: "Drew",
                        isOnline: true,
                        hasOutgoingRequest: true,
                        requestCount: 1,
                        badgeStatus: "requested",
                        membershipKind: "peer-only",
                        peerDeviceConnected: false
                    )
                ),
                BackendContactSummaryUpdate(
                    contactID: offlineID,
                    summary: makeContactSummary(
                        channelId: "channel-erin",
                        handle: "@erin",
                        displayName: "Erin",
                        isOnline: false,
                        badgeStatus: "offline",
                        membershipKind: "absent",
                        peerDeviceConnected: nil
                    )
                ),
            ])
        )

        let sections = viewModel.contactListSections

        #expect(sections.wantsToTalk.map { $0.contact.handle } == ["@blake"])
        #expect(sections.readyToTalk.map { $0.contact.handle } == ["@casey"])
        #expect(sections.requested.map { $0.contact.handle } == ["@drew"])
        #expect(sections.contacts.map { $0.contact.handle } == ["@erin"])
        #expect(sections.wantsToTalk.first?.presentation.availabilityPill == .online)
        #expect(sections.readyToTalk.first?.presentation.availabilityPill == .online)
        #expect(sections.requested.first?.presentation.availabilityPill == .online)
        #expect(sections.contacts.first?.presentation.availabilityPill == .offline)
    }

    @MainActor
    @Test func contactListKeepsSelectedPeerInSectionAndPinsOnlyActualActiveConversation() {
        let viewModel = PTTViewModel()
        let activeID = UUID()
        let selectedReadyID = UUID()
        viewModel.contacts = [
            Contact(
                id: activeID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-avery"),
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            ),
            Contact(
                id: selectedReadyID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
                backendChannelId: "channel-blake",
                remoteUserId: "user-blake"
            ),
        ]
        viewModel.selectedContactId = selectedReadyID
        viewModel.activeChannelId = activeID
        viewModel.isJoined = true
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: activeID,
                    summary: makeContactSummary(
                        channelId: "channel-avery",
                        handle: "@avery",
                        displayName: "Avery",
                        isOnline: true,
                        isActiveConversation: true,
                        badgeStatus: "ready",
                        membershipKind: "both",
                        peerDeviceConnected: true
                    )
                ),
                BackendContactSummaryUpdate(
                    contactID: selectedReadyID,
                    summary: makeContactSummary(
                        channelId: "channel-blake",
                        handle: "@blake",
                        displayName: "Blake",
                        isOnline: true,
                        badgeStatus: "ready",
                        membershipKind: "both",
                        peerDeviceConnected: true
                    )
                ),
            ])
        )

        let sections = viewModel.contactListSections

        #expect(viewModel.activeConversationContact?.handle == "@avery")
        #expect(sections.readyToTalk.map { $0.contact.handle } == ["@blake"])
        #expect(!sections.readyToTalk.map { $0.contact.handle }.contains("@avery"))
    }

    @MainActor
    @Test func selectedPeerIdleStatusShowsReadyToConnectWhenSummaryPresenceIsReachable() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        let summary = TurboContactSummaryResponse(
                userId: "user-blake",
                handle: "@blake",
                displayName: "Blake",
                channelId: "channel-blake",
                isOnline: true,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                isActiveConversation: false,
                badgeStatus: "idle",
                membershipPayload: TurboChannelMembershipPayload(
                    kind: "peer-only",
                    peerDeviceConnected: false
                )
            )
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(contactID: contactID, summary: summary)
            ])
        )

        let state = viewModel.selectedPeerState(for: contactID)

        #expect(state.phase == .idle)
        #expect(state.statusMessage == "Ready to connect")
    }

    @MainActor
    @Test func transportPathBadgeStateIsHiddenWithoutActivePeerSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: ContactDirectory.stableChannelUUID(for: "channel-blake"),
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID

        #expect(viewModel.mediaTransportPathState == .relay)
        #expect(viewModel.transportPathBadgeState == nil)

        viewModel.mediaRuntime.updateTransportPathState(.direct)

        #expect(viewModel.transportPathBadgeState == nil)
    }

    @MainActor
    @Test func transportPathBadgeStateSurfacesOnlyForLivePeerSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = ContactDirectory.stableChannelUUID(for: "channel-blake")
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        client.setWebSocketConnectionStateForTesting(.connected)
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-blake",
            remoteUserId: "user-blake"
        )
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .waitingForPeer,
                    canTransmit: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        #expect(viewModel.selectedPeerState(for: contactID).phase == .waitingForPeer)
        #expect(viewModel.transportPathBadgeState == nil)

        viewModel.mediaRuntime.attach(session: StubRelayMediaSession(), contactID: contactID)
        viewModel.mediaRuntime.markStartupSucceeded()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    localAudioReadiness: .ready,
                    remoteAudioReadiness: .ready
                )
            )
        )

        #expect(viewModel.selectedPeerState(for: contactID).phase == .ready)
        #expect(viewModel.transportPathBadgeState == .relay)

        viewModel.mediaRuntime.updateTransportPathState(.direct)

        #expect(viewModel.transportPathBadgeState == .direct)
    }

    @MainActor
    @Test func refreshInvitesFailurePreservesExistingSelectedContactState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )
        let incomingInvite = makeInvite(direction: "incoming")
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.trackContact(contactID)
        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [BackendInviteUpdate(contactID: contactID, invite: incomingInvite)],
                outgoing: [],
                now: .now
            )
        )

        await viewModel.refreshInvites()

        #expect(viewModel.selectedContact?.id == contactID)
        #expect(viewModel.contacts.map(\.id) == [contactID])
        #expect(viewModel.backendSyncCoordinator.state.syncState.incomingInvites[contactID] == incomingInvite)
    }

    @MainActor
    @Test func receiverAudioReadinessPublishDefersWhileWebSocketReconnects() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: "channel-refresh")

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Deferred receiver audio readiness publish until WebSocket reconnects"))
        #expect(!viewModel.diagnosticsTranscript.contains("Receiver audio readiness publish failed"))
    }

    @MainActor
    @Test func receiverAudioReadinessPublishDoesNotRequirePeerDeviceConnectedWhenPeerMembershipExists() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: "channel-refresh")

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Deferred receiver audio readiness publish until WebSocket reconnects"))
        #expect(!viewModel.diagnosticsTranscript.contains("Receiver audio readiness publish failed"))
    }

    @MainActor
    @Test func backgroundWakeReceiverAudioReadinessUsesAlignedLocalSessionWhileBackendMembershipLags() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true, selfJoined: false)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(viewModel.desiredLocalReceiverAudioReadiness(for: contactID))

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: "channel-refresh")

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == nil)
        #expect(viewModel.diagnosticsTranscript.contains("Deferred receiver audio readiness publish until WebSocket reconnects"))
        #expect(viewModel.diagnosticsTranscript.contains("state=ready"))
    }

    @MainActor
    @Test func wakeActivatedReceiverPublishesReadyFromConnectedPlaybackSessionDespiteStaleLocalTransmitState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        let staleRequest = TransmitRequestContext(
            contactID: contactID,
            contactHandle: contact.handle,
            backendChannelID: "channel",
            remoteUserID: "peer-user",
            channelUUID: channelUUID,
            usesLocalHTTPBackend: false,
            backendSupportsWebSocket: true
        )
        await viewModel.transmitCoordinator.handle(.systemPressRequested(staleRequest))
        viewModel.transmitRuntime.markPressBegan()
        viewModel.syncTransmitState()

        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel",
                    activeSpeaker: "@blake",
                    senderUserId: "peer-user",
                    senderDeviceId: "peer-device"
                ),
                hasConfirmedIncomingPush: true,
                activationState: .systemActivated
            )
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .systemActivated,
            startupMode: .playbackOnly
        )

        #expect(viewModel.mediaConnectionState == .connected)
        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(viewModel.transmitDomainSnapshot.phase == .requesting(contactID: contactID))
        #expect(viewModel.desiredLocalReceiverAudioReadiness(for: contactID))
    }

    @MainActor
    @Test func outgoingAudioSendGateWaitsForRemoteReceiverReadinessRecovery() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .waiting
                )
            )
        )

        let target = TransmitTarget(
            contactID: contactID,
            userID: "peer-user",
            deviceID: "peer-device",
            channelID: "channel"
        )
        let waitTask = Task {
            await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
                target: target,
                timeoutNanoseconds: 500_000_000,
                pollNanoseconds: 20_000_000
            )
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: true,
                    remoteAudioReadiness: .ready
                )
            )
        )

        #expect(await waitTask.value)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Remote receiver audio became ready; releasing outbound audio send gate"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateTimesOutWhenRemoteReceiverNeverRecovers() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .waiting
                )
            )
        )

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 120_000_000,
            pollNanoseconds: 20_000_000
        )

        #expect(!didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; sending anyway"
            )
        )
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "transmit.outbound_audio_without_remote_receiver_ready"
            }
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateWaitsForWakeCapableReceiverRecoveryAfterTalkRelease() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            viewModel.transmitRuntime.markPressEnded()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            viewModel.backendSyncCoordinator.send(
                .channelReadinessUpdated(
                    contactID: contactID,
                    readiness: makeChannelReadiness(
                        status: .ready,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            )
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 200_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 140_000_000
        )

        #expect(didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Waiting for wake-capable receiver recovery before sending initial outbound audio"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Continuing to hold initial outbound audio after talk release until wake-capable receiver recovery"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Remote receiver audio became ready; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; sending anyway"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateDoesNotReleaseWakeGraceWhileTalkIsStillActive() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            viewModel.backendSyncCoordinator.send(
                .channelReadinessUpdated(
                    contactID: contactID,
                    readiness: makeChannelReadiness(
                        status: .ready,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            )
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 220_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 50_000_000
        )

        #expect(didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Waiting for wake-capable receiver recovery before sending initial outbound audio"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Remote receiver audio became ready; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; sending anyway"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateUsesWakeRecoveryGraceWhenReceiverReadySignalNeverArrives() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            viewModel.transmitRuntime.markPressEnded()
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 220_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 90_000_000,
            postReleaseWakeRecoveryGraceNanoseconds: 20_000_000
        )

        #expect(didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Extending wake-capable receiver recovery hold after talk release to preserve buffered audio"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; sending anyway"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateDefaultWakeGraceDoesNotHoldShortReleaseForMultipleSeconds() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            viewModel.transmitRuntime.markPressEnded()
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 1_800_000_000,
            pollNanoseconds: 10_000_000
        )

        #expect(didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Extending wake-capable receiver recovery hold after talk release to preserve buffered audio"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; sending anyway"
            )
        )
    }

    @MainActor
    @Test func outgoingAudioSendGateAllowsShortPostReleaseWindowForWakeCapableReceiverRecovery() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.transmitRuntime.markPressBegan()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .waitingForPeer,
                    selfHasActiveDevice: true,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            viewModel.transmitRuntime.markPressEnded()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            viewModel.backendSyncCoordinator.send(
                .channelReadinessUpdated(
                    contactID: contactID,
                    readiness: makeChannelReadiness(
                        status: .ready,
                        selfHasActiveDevice: true,
                        peerHasActiveDevice: true,
                        remoteAudioReadiness: .ready,
                        remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                    )
                )
            )
        }

        let didBecomeReady = await viewModel.waitForRemoteReceiverAudioReadinessBeforeSendingIfNeeded(
            target: TransmitTarget(
                contactID: contactID,
                userID: "peer-user",
                deviceID: "peer-device",
                channelID: "channel"
            ),
            timeoutNanoseconds: 250_000_000,
            pollNanoseconds: 10_000_000,
            wakeRecoveryGraceNanoseconds: 90_000_000,
            postReleaseWakeRecoveryGraceNanoseconds: 80_000_000
        )

        #expect(didBecomeReady)
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Extending wake-capable receiver recovery hold after talk release to preserve buffered audio"
            )
        )
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Remote receiver audio became ready; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Wake-capable receiver recovery grace elapsed; releasing outbound audio send gate"
            )
        )
        #expect(
            !viewModel.diagnosticsTranscript.contains(
                "Timed out waiting for remote receiver audio readiness; sending anyway"
            )
        )
    }

    @MainActor
    @Test func wakeRecoveryTreatsPeerAsRoutableForReceiverReadinessWhileBackendPeerMembershipLags() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )

        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.pttWakeRuntime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                event: .transmitStart,
                channelId: "channel",
                activeSpeaker: "@blake",
                senderUserId: "peer-user",
                senderDeviceId: "peer-device"
            )
            )
        )
        viewModel.pttWakeRuntime.markAudioSessionActivated(for: channelUUID)

        #expect(viewModel.pttWakeRuntime.incomingWakeActivationState(for: contactID) == .systemActivated)
        #expect(viewModel.peerIsRoutableForReceiverAudioReadiness(for: contactID))
    }

    @MainActor
    @Test func localSessionAloneDoesNotMakePeerRoutableForReceiverReadiness() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .ready,
                    canTransmit: true,
                    selfJoined: true,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(
                    status: .ready,
                    peerHasActiveDevice: false,
                    remoteAudioReadiness: .wakeCapable,
                    remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
                )
            )
        )

        await viewModel.ensureMediaSession(
            for: contactID,
            activationMode: .appManaged,
            startupMode: .interactive
        )

        #expect(viewModel.desiredLocalReceiverAudioReadiness(for: contactID))
        #expect(!viewModel.peerIsRoutableForReceiverAudioReadiness(for: contactID))

        await viewModel.syncLocalReceiverAudioReadinessSignal(for: contactID, reason: "channel-refresh")

        #expect(
            viewModel.localReceiverAudioReadinessPublications[contactID]
                == ReceiverAudioReadinessPublication(
                    isReady: true,
                    peerWasRoutable: false,
                    basis: .channelRefresh
                )
        )
    }

    @MainActor
    @Test func wakeRecoveryReassertsBackendJoinWhenLocalSessionOutlivesBackendMembership() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true, selfJoined: false)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.reassertBackendJoinAfterWakeIfNeeded(for: contactID)

        #expect(
            capturedEffects == [
                .join(
                    BackendJoinRequest(
                        contactID: contactID,
                        handle: "@blake",
                        intent: .joinReadyPeer,
                        relationship: .none,
                        existingRemoteUserID: "peer-user",
                        existingBackendChannelID: "channel",
                        incomingInvite: nil,
                        outgoingInvite: nil,
                        requestCooldownRemaining: nil,
                        usesLocalHTTPBackend: false
                    )
                )
            ]
        )
    }

    @MainActor
    @Test func wakeRecoveryReassertionClearsCachedReceiverAudioReadinessPublication() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true, selfJoined: false)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )
        viewModel.localReceiverAudioReadinessPublications[contactID] = ReceiverAudioReadinessPublication(
            isReady: true,
            peerWasRoutable: true,
            basis: .lifecycle
        )

        await viewModel.reassertBackendJoinAfterWakeIfNeeded(for: contactID)

        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == nil)
    }

    @MainActor
    @Test func signalingJoinDriftNoticeReassertsBackendJoinForActiveLocalSession() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()
        viewModel.localReceiverAudioReadinessPublications[contactID] = ReceiverAudioReadinessPublication(
            isReady: true,
            peerWasRoutable: true,
            basis: .lifecycle
        )

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleBackendServerNotice("sender device is not joined to this channel")

        await Task.yield()
        await Task.yield()

        #expect(capturedEffects.contains(
            .join(
                BackendJoinRequest(
                    contactID: contactID,
                    handle: "@blake",
                    intent: .joinReadyPeer,
                    relationship: .none,
                    existingRemoteUserID: "peer-user",
                    existingBackendChannelID: "channel",
                    incomingInvite: nil,
                    outgoingInvite: nil,
                    requestCooldownRemaining: nil,
                    usesLocalHTTPBackend: false
                )
            )
        ))
        #expect(viewModel.localReceiverAudioReadinessPublications[contactID] == nil)
    }

    @MainActor
    @Test func backendJoinFailureClearsPendingConnectAndSelectedWaitingState() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.sessionCoordinator.queueConnect(contactID: contactID)
        viewModel.syncSelectedPeerSession()

        await viewModel.backendCommandCoordinator.handle(
            .joinRequested(
                BackendJoinRequest(
                    contactID: contactID,
                    handle: "@blake",
                    intent: .joinReadyPeer,
                    relationship: .none,
                    existingRemoteUserID: "peer-user",
                    existingBackendChannelID: "channel-123",
                    incomingInvite: nil,
                    outgoingInvite: nil,
                    requestCooldownRemaining: nil,
                    usesLocalHTTPBackend: false
                )
            )
        )

        #expect(viewModel.pendingJoinContactId == nil)
        #expect(viewModel.sessionCoordinator.pendingAction == .none)
        #expect(viewModel.backendCommandCoordinator.state.activeOperation == nil)
        #expect(viewModel.backendCommandCoordinator.state.lastError != nil)
        #expect(viewModel.statusMessage.contains("Join failed:"))
        #expect(viewModel.selectedPeerState(for: contactID).phase != .waitingForPeer)
    }

    @MainActor
    @Test func signalingJoinDriftNoticeIsIgnoredWithoutActiveLocalSession() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: UUID(),
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleBackendServerNotice("sender device is not joined to this channel")

        await Task.yield()

        #expect(capturedEffects.isEmpty)
    }

    @MainActor
    @Test func signalingJoinDriftSelfHealDoesNotReassertIdleBackendChannel() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(
                    status: .idle,
                    canTransmit: false,
                    selfJoined: false,
                    peerJoined: false,
                    peerDeviceConnected: false
                )
            )
        )

        #expect(!viewModel.shouldReassertBackendJoinAfterSignalingDrift(for: contactID))
    }

    @MainActor
    @Test func signalingJoinDriftStillReassertsLiveBackendChannel() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )

        #expect(viewModel.shouldReassertBackendJoinAfterSignalingDrift(for: contactID))
    }

    @MainActor
    @Test func signalingPrefixedJoinDriftNoticeReassertsBackendJoinForActiveLocalSession() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleBackendServerNotice("signaling sender device is not joined to this channel")

        await Task.yield()
        await Task.yield()

        #expect(capturedEffects.contains(
            .join(
                BackendJoinRequest(
                    contactID: contactID,
                    handle: "@blake",
                    intent: .joinReadyPeer,
                    relationship: .none,
                    existingRemoteUserID: "peer-user",
                    existingBackendChannelID: "channel",
                    incomingInvite: nil,
                    outgoingInvite: nil,
                    requestCooldownRemaining: nil,
                    usesLocalHTTPBackend: false
                )
            )
        ))
    }

    @MainActor
    @Test func websocketReconnectReassertsBackendJoinForActiveLocalSession() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let contact = Contact(
            id: contactID,
            name: "Blake",
            handle: "@blake",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel",
            remoteUserId: "peer-user"
        )
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.contacts = [contact]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleWebSocketStateChange(.connected)

        await Task.yield()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 250_000_000)

        #expect(capturedEffects.contains(
            .join(
                BackendJoinRequest(
                    contactID: contactID,
                    handle: "@blake",
                    intent: .joinReadyPeer,
                    relationship: .none,
                    existingRemoteUserID: "peer-user",
                    existingBackendChannelID: "channel",
                    incomingInvite: nil,
                    outgoingInvite: nil,
                    requestCooldownRemaining: nil,
                    usesLocalHTTPBackend: false
                )
            )
        ))
        #expect(
            viewModel.diagnosticsTranscript.contains(
                "Reasserting backend join after WebSocket reconnect"
            )
        )
    }

    @MainActor
    @Test func websocketIdleClearsCachedReceiverAudioReadinessPublications() {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )
        let contactID = UUID()
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")
        viewModel.localReceiverAudioReadinessPublications[contactID] = ReceiverAudioReadinessPublication(
            isReady: true,
            peerWasRoutable: true,
            basis: .lifecycle
        )

        viewModel.handleWebSocketStateChange(.idle)

        #expect(viewModel.localReceiverAudioReadinessPublications.isEmpty)
    }

    @MainActor
    @Test func selectedPeerStateIgnoresCachedChannelStateWithoutMatchingSummary() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-stale",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: false)
            )
        )

        let state = viewModel.selectedPeerState(for: contactID)

        #expect(state.phase == .idle)
        #expect(state.conversationState == .idle)
        #expect(state.canTransmitNow == false)
    }

    @Test func backendSyncReducerRetainsChannelStateOnRefreshFailure() {
        let contactID = UUID()
        let existingChannelState = makeChannelState(status: .ready, canTransmit: true)
        var state = BackendSyncSessionState()
        state.syncState.channelStates[contactID] = existingChannelState

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .channelStateFailed(contactID: contactID, message: "Channel sync failed: timeout")
        )

        #expect(transition.state.syncState.channelStates[contactID] == existingChannelState)
        #expect(transition.state.syncState.statusMessage == "Channel sync failed: timeout")
    }

    @Test func backendSyncReducerChannelFailureAfterBootstrapUsesRecoverableStatus() {
        let contactID = UUID()
        let existingChannelState = makeChannelState(status: .ready, canTransmit: true)
        var state = BackendSyncSessionState()
        state.syncState.channelStates[contactID] = existingChannelState
        state.syncState.hasEstablishedConnection = true
        state.syncState.statusMessage = "Backend connected (cloud) as @avery"

        let transition = BackendSyncReducer.reduce(
            state: state,
            event: .channelStateFailed(contactID: contactID, message: "Channel sync failed: timeout")
        )

        #expect(transition.state.syncState.channelStates[contactID] == existingChannelState)
        #expect(transition.state.syncState.statusMessage == "Connected (retrying sync)")
    }

    @Test func backendSyncStateAcceptsBackendConnectingRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: joinedChannelState.hasIncomingRequest,
            hasOutgoingRequest: joinedChannelState.hasOutgoingRequest,
            requestCount: joinedChannelState.requestCount,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: "connecting",
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateClearsReadinessWhenChannelMembershipBecomesAbsent() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let absentChannelState = makeChannelState(
            status: .idle,
            canTransmit: false,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelReadiness(
            makeChannelReadiness(
                status: .ready,
                remoteAudioReadiness: .wakeCapable,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "peer-device")
            ),
            for: contactID
        )
        syncState.applyChannelState(absentChannelState, for: contactID)
        syncState.applyChannelReadiness(
            makeChannelReadiness(
                status: .ready,
                remoteAudioReadiness: .wakeCapable,
                remoteWakeCapability: .wakeCapable(targetDeviceId: "stale-peer-device")
            ),
            for: contactID
        )

        #expect(syncState.channelStates[contactID] == absentChannelState)
        #expect(syncState.channelReadiness[contactID] == nil)
    }

    @Test func backendSyncStateAcceptsBackendIncomingRequestRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 1,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: ConversationState.incomingRequest.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateAcceptsBackendPeerRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let peerReadyChannelState = TurboChannelStateResponse(
            channelId: "channel-1",
            selfUserId: "self",
            peerUserId: "peer",
            peerHandle: "@blake",
            selfOnline: true,
            peerOnline: true,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.incomingRequest.rawValue,
            canTransmit: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: peerReadyChannelState.channelId,
            selfUserId: peerReadyChannelState.selfUserId,
            peerUserId: peerReadyChannelState.peerUserId,
            peerHandle: peerReadyChannelState.peerHandle,
            selfOnline: peerReadyChannelState.selfOnline,
            peerOnline: peerReadyChannelState.peerOnline,
            selfJoined: false,
            peerJoined: false,
            peerDeviceConnected: false,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 1,
            activeTransmitterUserId: nil,
            transmitLeaseExpiresAt: nil,
            status: ConversationState.incomingRequest.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(peerReadyChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateAcceptsBackendPeerJoinedConnectingRegression() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .ready,
            canTransmit: true,
            selfJoined: true,
            peerJoined: true,
            peerDeviceConnected: true
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: false,
            hasIncomingRequest: joinedChannelState.hasIncomingRequest,
            hasOutgoingRequest: joinedChannelState.hasOutgoingRequest,
            requestCount: joinedChannelState.requestCount,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: "connecting",
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendSyncStateReplacesStaleJoinedMembershipWhenBackendResetsChannel() {
        let contactID = UUID()
        var syncState = BackendSyncState()
        let joinedChannelState = makeChannelState(
            status: .waitingForPeer,
            canTransmit: false,
            selfJoined: true,
            peerJoined: false,
            peerDeviceConnected: false
        )
        let regressedChannelState = TurboChannelStateResponse(
            channelId: joinedChannelState.channelId,
            selfUserId: joinedChannelState.selfUserId,
            peerUserId: joinedChannelState.peerUserId,
            peerHandle: joinedChannelState.peerHandle,
            selfOnline: joinedChannelState.selfOnline,
            peerOnline: joinedChannelState.peerOnline,
            selfJoined: false,
            peerJoined: true,
            peerDeviceConnected: true,
            hasIncomingRequest: true,
            hasOutgoingRequest: false,
            requestCount: 1,
            activeTransmitterUserId: joinedChannelState.activeTransmitterUserId,
            transmitLeaseExpiresAt: joinedChannelState.transmitLeaseExpiresAt,
            status: ConversationState.incomingRequest.rawValue,
            canTransmit: false
        )

        syncState.applyChannelState(joinedChannelState, for: contactID)
        syncState.applyChannelState(regressedChannelState, for: contactID)

        #expect(syncState.channelStates[contactID] == regressedChannelState)
    }

    @Test func backendCommandReducerOpenPeerEmitsLookupEffect() {
        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState.initial,
            event: .openPeerRequested(handle: "@avery")
        )

        #expect(transition.state.activeOperation == .openPeer(handle: "@avery"))
        #expect(transition.effects == [.openPeer(handle: "@avery")])
    }

    @Test func backendCommandReducerDeduplicatesJoinForSameContact() {
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .none,
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(activeOperation: .join(request: request), queuedJoinRequest: nil, lastError: nil),
            event: .joinRequested(request)
        )

        #expect(transition.state.activeOperation == .join(request: request))
        #expect(transition.effects.isEmpty)
    }

    @Test func backendCommandReducerQueuesUpdatedJoinForSameContact() {
        let contactID = UUID()
        let inFlightRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let queuedRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(activeOperation: .join(request: inFlightRequest), queuedJoinRequest: nil, lastError: nil),
            event: .joinRequested(queuedRequest)
        )

        #expect(transition.state.activeOperation == .join(request: inFlightRequest))
        #expect(transition.state.queuedJoinRequest == queuedRequest)
        #expect(transition.effects.isEmpty)
    }

    @Test func backendCommandReducerRunsQueuedJoinAfterOperationFinishes() {
        let contactID = UUID()
        let inFlightRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: nil,
            existingBackendChannelID: nil,
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let queuedRequest = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let transition = BackendCommandReducer.reduce(
            state: BackendCommandState(
                activeOperation: .join(request: inFlightRequest),
                queuedJoinRequest: queuedRequest,
                lastError: nil
            ),
            event: .operationFinished
        )

        #expect(transition.state.activeOperation == .join(request: queuedRequest))
        #expect(transition.state.queuedJoinRequest == nil)
        #expect(transition.effects == [.join(queuedRequest)])
    }

    @MainActor
    @Test func backendJoinExecutionPlanTreatsOutgoingInviteAsRequestOnly() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: nil
        )

        #expect(plan == .requestOnly)
    }

    @MainActor
    @Test func requestAgainReplacesExistingOutgoingInviteAfterCooldownExpires() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        #expect(viewModel.shouldReplaceExistingOutgoingInvite(for: request))
    }

    @MainActor
    @Test func requestAgainDoesNotReplaceOutgoingInviteWhileCooldownIsActive() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: 12,
            usesLocalHTTPBackend: false
        )

        #expect(!viewModel.shouldReplaceExistingOutgoingInvite(for: request))
    }

    @MainActor
    @Test func backendJoinExecutionPlanTreatsIncomingInviteAsJoinSession() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: makeInvite(direction: "incoming"),
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: nil
        )

        #expect(plan == .joinSession)
    }

    @MainActor
    @Test func backendJoinExecutionPlanKeepsOutgoingInviteOnRequestPathEvenWhenPeerAlreadyJoined() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let currentChannel = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: true,
                hasIncomingRequest: false,
                hasOutgoingRequest: true,
                requestCount: 1,
                activeTransmitterUserId: nil,
                transmitLeaseExpiresAt: nil,
                status: ConversationState.requested.rawValue,
                canTransmit: false
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: currentChannel
        )

        #expect(plan == .requestOnly)
    }

    @MainActor
    @Test func backendJoinExecutionPlanKeepsOutgoingInviteOnRequestPathWhenPeerIsJoinedButDeviceNotConnected() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .outgoingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: makeInvite(direction: "outgoing"),
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let currentChannel = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: false,
                hasIncomingRequest: false,
                hasOutgoingRequest: true,
                requestCount: 1,
                activeTransmitterUserId: nil,
                transmitLeaseExpiresAt: nil,
                status: ConversationState.requested.rawValue,
                canTransmit: false
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: currentChannel
        )

        #expect(plan == .requestOnly)
    }

    @MainActor
    @Test func backendJoinExecutionPlanKeepsNeutralConnectOnRequestPathWhenPeerMembershipLooksReady() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .requestConnection,
            relationship: .none,
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let currentChannel = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: false,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                activeTransmitterUserId: nil,
                transmitLeaseExpiresAt: nil,
                status: ConversationState.waitingForPeer.rawValue,
                canTransmit: false
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: currentChannel
        )

        #expect(plan == .requestOnly)
    }

    @MainActor
    @Test func backendJoinExecutionPlanAllowsExplicitJoinReadyPeerIntentWhenPeerHasJoined() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let request = BackendJoinRequest(
            contactID: contactID,
            handle: "@avery",
            intent: .joinReadyPeer,
            relationship: .none,
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let currentChannel = ChannelReadinessSnapshot(
            channelState: TurboChannelStateResponse(
                channelId: "channel-avery",
                selfUserId: "self",
                peerUserId: "user-avery",
                peerHandle: "@avery",
                selfOnline: true,
                peerOnline: true,
                selfJoined: false,
                peerJoined: true,
                peerDeviceConnected: false,
                hasIncomingRequest: false,
                hasOutgoingRequest: false,
                requestCount: 0,
                activeTransmitterUserId: nil,
                transmitLeaseExpiresAt: nil,
                status: ConversationState.waitingForPeer.rawValue,
                canTransmit: false
            )
        )

        let plan = viewModel.backendJoinExecutionPlan(
            request: request,
            createdInvite: nil,
            currentChannel: currentChannel
        )

        #expect(plan == .joinSession)
    }

    @MainActor
    @Test func inviteMatcherFindsIncomingInviteByHandleWhenCachedInviteIsMissing() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let invite = TurboInviteResponse(
            inviteId: "invite-1",
            fromUserId: "user-avery",
            fromHandle: "@avery",
            toUserId: "self",
            toHandle: "@blake",
            channelId: "channel-avery",
            status: "pending",
            direction: "incoming",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:00Z",
            updatedAt: nil,
            targetAvailability: nil,
            shouldAutoJoinPeer: nil,
            accepted: nil,
            pendingJoin: nil
        )

        #expect(viewModel.inviteMatchesJoinRequest(invite, request: request, direction: "incoming"))
    }

    @MainActor
    @Test func staleIncomingInviteAcceptFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldIgnoreIncomingInviteAcceptFailure(TurboBackendError.server("invite not found")))
        #expect(viewModel.shouldIgnoreIncomingInviteAcceptFailure(TurboBackendError.server(" Invite Not Found ")) )
    }

    @MainActor
    @Test func staleSupersededOutgoingInviteCancelFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldIgnoreInviteNotFoundFailure(TurboBackendError.server("invite not found")))
        #expect(viewModel.shouldIgnoreInviteNotFoundFailure(TurboBackendError.server(" Invite Not Found ")))
    }

    @MainActor
    @Test func nonStaleIncomingInviteAcceptFailureIsNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldIgnoreIncomingInviteAcceptFailure(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldIgnoreIncomingInviteAcceptFailure(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func unrelatedInviteCancelFailuresAreNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldIgnoreInviteNotFoundFailure(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldIgnoreInviteNotFoundFailure(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func backendJoinChannelNotFoundIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server("channel not found")))
        #expect(viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server(" Channel Not Found ")))
    }

    @MainActor
    @Test func backendJoinMetadataFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server("missing otherUserId or otherHandle")))
        #expect(viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server(" Missing OtherUserId Or OtherHandle ")))
    }

    @MainActor
    @Test func backendJoinDisconnectedSessionFailureIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatBackendJoinDisconnectedSessionAsRecoverable(TurboBackendError.server("device session not connected")))
        #expect(viewModel.shouldTreatBackendJoinDisconnectedSessionAsRecoverable(TurboBackendError.server(" Device Session Not Connected ")))
    }

    @MainActor
    @Test func backendJoinPreparationWaitsForWebSocketConnectionButDoesNotBlockJoinIfItNeverConnects() async {
        let viewModel = PTTViewModel()
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        client.setRuntimeConfigForTesting(
            TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: true)
        )

        var observedStates: [TurboBackendClient.WebSocketConnectionState] = []
        client.onWebSocketStateChange = { state in
            observedStates.append(state)
        }

        viewModel.applyAuthenticatedBackendSession(client: client, userID: "self-user", mode: "cloud")
        guard let backend = viewModel.backendServices else {
            Issue.record("Missing backend services")
            return
        }

        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .joinReadyPeer,
            relationship: .none,
            existingRemoteUserID: "peer-user",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )

        do {
            try await viewModel.prepareBackendJoinControlPlaneIfNeeded(backend, request: request)
        } catch {
            Issue.record("Expected websocket-backed join preparation to proceed after reconnect attempt, got \(error)")
        }

        #expect(observedStates.contains(.connecting))
        #expect(viewModel.diagnosticsTranscript.contains("Waiting for backend WebSocket before join"))
        #expect(viewModel.diagnosticsTranscript.contains("Proceeding with backend join while WebSocket remains unavailable"))
    }

    @MainActor
    @Test func unrelatedBackendJoinFailuresAreNotRecoverable() {
        let viewModel = PTTViewModel()

        #expect(!viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldTreatBackendJoinChannelNotFoundAsRecoverable(TurboBackendError.invalidResponse))
        #expect(!viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldTreatBackendJoinMetadataFailureAsRecoverable(TurboBackendError.invalidResponse))
        #expect(!viewModel.shouldTreatBackendJoinDisconnectedSessionAsRecoverable(TurboBackendError.server("internal server error")))
        #expect(!viewModel.shouldTreatBackendJoinDisconnectedSessionAsRecoverable(TurboBackendError.invalidResponse))
    }

    @MainActor
    @Test func transmitLeaseLossIsTreatedAsCleanStop() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatTransmitLeaseLossAsStop(TurboBackendError.server("no active transmit state for sender")))
        #expect(!viewModel.shouldTreatTransmitLeaseLossAsStop(TurboBackendError.server("channel already transmitting")))
    }

    @MainActor
    @Test func transmitBeginMembershipLossIsRecoverable() {
        let viewModel = PTTViewModel()

        #expect(viewModel.shouldTreatTransmitBeginMembershipLossAsRecoverable(TurboBackendError.server("not a channel member")))
        #expect(!viewModel.shouldTreatTransmitBeginMembershipLossAsRecoverable(TurboBackendError.server("channel already transmitting")))
    }

    @MainActor
    @Test func inviteMatcherRejectsWrongDirection() {
        let viewModel = PTTViewModel()
        let request = BackendJoinRequest(
            contactID: UUID(),
            handle: "@avery",
            intent: .requestConnection,
            relationship: .incomingRequest(requestCount: 1),
            existingRemoteUserID: "user-avery",
            existingBackendChannelID: "channel-avery",
            incomingInvite: nil,
            outgoingInvite: nil,
            requestCooldownRemaining: nil,
            usesLocalHTTPBackend: false
        )
        let invite = TurboInviteResponse(
            inviteId: "invite-1",
            fromUserId: "self",
            fromHandle: "@blake",
            toUserId: "user-avery",
            toHandle: "@avery",
            channelId: "channel-avery",
            status: "pending",
            direction: "outgoing",
            requestCount: 1,
            createdAt: "2026-04-08T00:00:00Z",
            updatedAt: nil,
            targetAvailability: nil,
            shouldAutoJoinPeer: nil,
            accepted: nil,
            pendingJoin: nil
        )

        #expect(viewModel.inviteMatchesJoinRequest(invite, request: request, direction: "incoming") == false)
    }

    @MainActor
    @Test func backendSyncCancellationClassifierAcceptsTaskCancellation() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(CancellationError()))
    }

    @MainActor
    @Test func backendSyncCancellationClassifierAcceptsURLSessionCancellation() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(URLError(.cancelled)))
    }

    @MainActor
    @Test func backendSyncCancellationClassifierRejectsRealBackendFailures() {
        let viewModel = PTTViewModel()

        #expect(viewModel.isExpectedBackendSyncCancellation(TurboBackendError.server("boom")) == false)
    }

    @MainActor
    @Test func backendChannelReadinessMembershipLossIsAuthoritative() {
        let viewModel = PTTViewModel()

        #expect(
            viewModel.shouldTreatChannelReadinessMembershipLossAsAuthoritative(
                TurboBackendError.server("not a channel member")
            )
        )
        #expect(
            !viewModel.shouldTreatChannelReadinessMembershipLossAsAuthoritative(
                TurboBackendError.server("internal server error")
            )
        )
    }

    @Test func talkRequestSurfaceShowsNewestUnsurfacedInviteWhenAppIsActive() {
        let older = IncomingTalkRequestCandidate(
            contact: Contact(
                id: UUID(),
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            invite: makeInvite(
                direction: "incoming",
                inviteId: "invite-older",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )
        let newer = IncomingTalkRequestCandidate(
            contact: Contact(
                id: UUID(),
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID()
            ),
            invite: makeInvite(
                direction: "incoming",
                inviteId: "invite-newer",
                fromHandle: "@blake",
                createdAt: "2026-04-17T19:02:00Z",
                updatedAt: "2026-04-17T19:02:00Z"
            )
        )

        let nextState = TalkRequestSurfaceReducer.reduce(
            state: TalkRequestSurfaceState(),
            event: .invitesUpdated(
                candidates: [older, newer],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(nextState.activeIncomingRequest?.inviteID == "invite-newer")
        #expect(nextState.surfacedInviteIDs == Set(["invite-newer"]))
    }

    @Test func talkRequestSurfaceDefersUntilAppBecomesActive() {
        let candidate = IncomingTalkRequestCandidate(
            contact: Contact(
                id: UUID(),
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID()
            ),
            invite: makeInvite(
                direction: "incoming",
                inviteId: "invite-1",
                fromHandle: "@avery",
                createdAt: "2026-04-17T19:00:00Z",
                updatedAt: "2026-04-17T19:00:00Z"
            )
        )

        let backgroundState = TalkRequestSurfaceReducer.reduce(
            state: TalkRequestSurfaceState(),
            event: .invitesUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: false
            )
        )
        let activeState = TalkRequestSurfaceReducer.reduce(
            state: backgroundState,
            event: .invitesUpdated(
                candidates: [candidate],
                selectedContactID: nil,
                applicationIsActive: true
            )
        )

        #expect(backgroundState.activeIncomingRequest == nil)
        #expect(backgroundState.surfacedInviteIDs.isEmpty)
        #expect(activeState.activeIncomingRequest?.inviteID == "invite-1")
    }

    @Test func openingRequestContactClearsBannerAndMarksInviteSurfaced() {
        let contactID = UUID()
        let inviteID = "invite-1"
        let initialState = TalkRequestSurfaceState(
            activeIncomingRequest: IncomingTalkRequestSurface(
                contactID: contactID,
                inviteID: inviteID,
                contactName: "Avery",
                contactHandle: "@avery",
                requestCount: 1,
                recencyKey: "2026-04-17T19:00:00Z"
            ),
            surfacedInviteIDs: []
        )

        let nextState = TalkRequestSurfaceReducer.reduce(
            state: initialState,
            event: .contactOpened(contactID: contactID, inviteID: inviteID)
        )

        #expect(nextState.activeIncomingRequest == nil)
        #expect(nextState.surfacedInviteIDs == Set([inviteID]))
    }

    @MainActor
    @Test func acceptingActiveIncomingTalkRequestSelectsContactAndRequestsJoin() async throws {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        let invite = makeInvite(
            direction: "incoming",
            inviteId: "invite-1",
            fromHandle: "@avery",
            toHandle: "@self"
        )
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: invite.channelId,
                remoteUserId: invite.fromUserId
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .invitesUpdated(
                incoming: [BackendInviteUpdate(contactID: contactID, invite: invite)],
                outgoing: [],
                now: .now
            )
        )
        viewModel.reconcileTalkRequestSurface(applicationState: .active)
        let client = TurboBackendClient(config: makeUnreachableBackendConfig())
        viewModel.applyAuthenticatedBackendSession(client: client, userID: "user-self", mode: "cloud")

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.acceptActiveIncomingTalkRequest()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.selectedContactId == contactID)
        #expect(viewModel.activeIncomingTalkRequest == nil)
        #expect(
            capturedEffects.contains {
                guard case let .join(request) = $0 else { return false }
                return request.contactID == contactID
                    && request.relationship == .incomingRequest(requestCount: 1)
                    && request.incomingInvite?.inviteId == "invite-1"
            }
        )
    }

    @Test func backendCommandReducerLeaveFailureClearsOperationAndStoresError() {
        let contactID = UUID()
        let leaveRequest = BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
        let joinedTransition = BackendCommandReducer.reduce(
            state: BackendCommandState.initial,
            event: .leaveRequested(leaveRequest)
        )
        let failedTransition = BackendCommandReducer.reduce(
            state: joinedTransition.state,
            event: .operationFailed("leave failed")
        )

        #expect(joinedTransition.effects == [.leave(leaveRequest)])
        #expect(failedTransition.state.activeOperation == nil)
        #expect(failedTransition.state.lastError == "leave failed")
    }

    @MainActor
    @Test func unexpectedSystemLeaveDoesNotRequestBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runPTTEffect(.syncLeftChannel(contactID: contactID, autoRejoinContactID: nil))

        #expect(capturedEffects.isEmpty)
    }

    @MainActor
    @Test func explicitSystemLeaveStillRequestsBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.sessionCoordinator.markExplicitLeave(contactID: contactID)

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runPTTEffect(.syncLeftChannel(contactID: contactID, autoRejoinContactID: nil))

        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
                )
            ]
        )
    }

    @MainActor
    @Test func activeSystemLeaveCallbackArmsExplicitLeaveAndRequestsBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleDidLeaveChannel(channelUUID, reason: "PTChannelLeaveReason(rawValue: 1)")

        await Task.yield()
        await Task.yield()

        #expect(viewModel.sessionCoordinator.pendingAction == .leave(.explicit(contactID: contactID)))
        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
                )
            ]
        )
    }

    @MainActor
    @Test func backgroundUserInitiatedSystemLeaveCallbackRequestsBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleDidLeaveChannel(channelUUID, reason: "PTChannelLeaveReason(rawValue: 1)")

        await Task.yield()
        await Task.yield()

        #expect(viewModel.sessionCoordinator.pendingAction == .leave(.explicit(contactID: contactID)))
        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: contactID, backendChannelID: "channel-1")
                )
            ]
        )
    }

    @MainActor
    @Test func backgroundSystemEvictionLeaveCallbackDoesNotRequestBackendLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.applicationStateOverride = .background
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.syncPTTState()

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleDidLeaveChannel(channelUUID, reason: "PTChannelLeaveReason(rawValue: 2)")

        await Task.yield()
        await Task.yield()

        #expect(viewModel.sessionCoordinator.pendingAction == .none)
        #expect(capturedEffects.isEmpty)
    }

    @MainActor
    @Test func systemLeaveForChannelSwitchRequestsBackendLeave() async {
        let viewModel = PTTViewModel()
        let currentContactID = UUID()
        let nextContactID = UUID()
        viewModel.contacts = [
            Contact(
                id: currentContactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            ),
            Contact(
                id: nextContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-2",
                remoteUserId: "user-avery"
            )
        ]

        var capturedEffects: [BackendCommandEffect] = []
        viewModel.backendCommandCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        await viewModel.runPTTEffect(
            .syncLeftChannel(contactID: currentContactID, autoRejoinContactID: nextContactID)
        )

        #expect(
            capturedEffects == [
                .leave(
                    BackendLeaveRequest(contactID: currentContactID, backendChannelID: "channel-1")
                )
            ]
        )
    }

    @MainActor
    @Test func reconciledTeardownWithoutSystemSessionClearsPendingLeave() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.selectedContactId = contactID

        await viewModel.runSelectedPeerEffect(.teardownLocalSession(contactID: contactID))

        #expect(viewModel.sessionCoordinator.pendingAction == .none)
        #expect(viewModel.isJoined == false)
        #expect(viewModel.systemSessionState == .none)
    }

    @Test func devSelfCheckReducerTracksRunningAndLatestReport() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: true,
            isBackendClientReady: true,
            microphonePermission: .granted,
            selectedTarget: nil
        )
        let report = DevSelfCheckReport(
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(1),
            targetHandle: nil,
            steps: [DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok")]
        )

        let started = DevSelfCheckReducer.reduce(
            state: .initial,
            event: .runRequested(request)
        )
        let completed = DevSelfCheckReducer.reduce(
            state: started.state,
            event: .runCompleted(report)
        )

        #expect(started.state.isRunning)
        #expect(started.effects == [.run(request)])
        #expect(completed.state.isRunning == false)
        #expect(completed.state.latestReport == report)
    }

    @Test func devSelfCheckRunnerSkipsPeerStepsWithoutSelection() async {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let request = DevSelfCheckRequest(
            startedAt: startedAt,
            hasBackendConfig: true,
            isBackendClientReady: true,
            microphonePermission: .granted,
            selectedTarget: nil
        )
        let services = DevSelfCheckServices(
            fetchRuntimeConfig: { TurboBackendRuntimeConfig(mode: "cloud", supportsWebSocket: false) },
            authenticate: { TurboAuthSessionResponse(userId: "user-self", handle: "@self", displayName: "Self") },
            heartbeatPresence: { TurboPresenceHeartbeatResponse(deviceId: "device", userId: "user-self", status: "ok") },
            ensureWebSocketConnected: {},
            waitForWebSocketConnection: {},
            lookupUser: { _ in Issue.record("lookupUser should not run without a selected target"); return TurboUserLookupResponse(userId: "", handle: "", displayName: "") },
            directChannel: { _ in Issue.record("directChannel should not run without a selected target"); return TurboDirectChannelResponse(channelId: "", lowUserId: "", highUserId: "", createdAt: "") },
            channelState: { _ in Issue.record("channelState should not run without a selected target"); return makeChannelState(status: .idle, canTransmit: false) },
            alignmentAction: { _ in .none }
        )

        let outcome = await DevSelfCheckRunner.run(
            request: request,
            services: services
        )

        #expect(outcome.authenticatedUserID == "user-self")
        #expect(outcome.contactUpdate == nil)
        #expect(outcome.channelStateUpdate == nil)
        #expect(outcome.report.isPassing)
        #expect(
            outcome.report.steps.map(\.id)
                == [
                    .backendConfig,
                    .microphonePermission,
                    .runtimeConfig,
                    .authSession,
                    .deviceHeartbeat,
                    .websocket,
                    .peerLookup,
                    .directChannel,
                    .channelState,
                    .sessionAlignment
                ]
        )
        #expect(outcome.report.steps.first(where: { $0.id == .microphonePermission })?.status == .passed)
        #expect(outcome.report.steps.first(where: { $0.id == .websocket })?.status == .skipped)
        #expect(outcome.report.steps.suffix(4).allSatisfy { $0.status == .skipped })
    }

    @Test func pttSystemPolicyReducerEmitsUploadEffectWhenChannelIsKnown() {
        let transition = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: "channel-1")
        )

        #expect(transition.state.latestTokenHex == "deadbeef")
        #expect(
            transition.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @Test func pttSystemPolicyReducerRecordsUploadFailure() {
        let transition = PTTSystemPolicyReducer.reduce(
            state: PTTSystemPolicyState(latestTokenHex: "deadbeef", lastTokenUploadError: nil),
            event: .tokenUploadFailed("network down")
        )

        #expect(transition.state.latestTokenHex == "deadbeef")
        #expect(transition.state.lastTokenUploadError == "network down")
        #expect(transition.effects.isEmpty)
    }

    @Test func pttSystemPolicyReducerRetriesUploadWhenChannelBecomesKnownLater() {
        let received = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: nil)
        )

        #expect(received.state.latestTokenHex == "deadbeef")
        #expect(received.effects.isEmpty)

        let ready = PTTSystemPolicyReducer.reduce(
            state: received.state,
            event: .backendChannelReady("channel-1")
        )

        #expect(
            ready.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @Test func pttSystemPolicyReducerKeepsFailedUploadContextForRetry() {
        let received = PTTSystemPolicyReducer.reduce(
            state: .initial,
            event: .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: "channel-1")
        )
        let failed = PTTSystemPolicyReducer.reduce(
            state: received.state,
            event: .tokenUploadFailed("network down")
        )

        #expect(failed.state.latestTokenHex == "deadbeef")
        #expect(failed.state.lastTokenUploadError == "network down")
        #expect(
            failed.state.tokenRegistration
                == .uploadFailed(
                    latestTokenHex: "deadbeef",
                    backendChannelID: "channel-1",
                    attemptedRequest: PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    ),
                    message: "network down"
                )
        )

        let retried = PTTSystemPolicyReducer.reduce(
            state: failed.state,
            event: .backendChannelReady("channel-1")
        )

        #expect(
            retried.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
        #expect(
            retried.state.tokenRegistration
                == .uploadPending(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
        )
    }

    @Test func pttSystemPolicyReducerDoesNotReuploadSameTokenAndChannel() {
        let state = PTTSystemPolicyState(
            latestTokenHex: "deadbeef",
            lastTokenUploadError: nil,
            uploadedTokenHex: "deadbeef",
            uploadedBackendChannelID: "channel-1"
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .backendChannelReady("channel-1")
        )

        #expect(transition.effects.isEmpty)
    }

    @Test func pttSystemPolicyReducerDoesNotReuploadWhileSameTokenAndChannelUploadIsPending() {
        let state = PTTSystemPolicyState(
            tokenRegistration: .uploadPending(
                PTTTokenUploadRequest(
                    backendChannelID: "channel-1",
                    tokenHex: "deadbeef"
                )
            )
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .backendChannelReady("channel-1")
        )

        #expect(transition.effects.isEmpty)
        #expect(
            transition.state.tokenRegistration
                == .tokenKnown(tokenHex: "deadbeef", backendChannelID: "channel-1")
        )
    }

    @Test func pttSystemPolicyReducerReuploadsPersistedTokenForNewBackendChannel() {
        let state = PTTSystemPolicyState(
            latestTokenHex: "deadbeef",
            uploadedTokenHex: "deadbeef",
            uploadedBackendChannelID: "old-channel"
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .backendChannelReady("channel-1")
        )

        #expect(
            transition.effects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
        #expect(
            transition.state.tokenRegistration
                == .uploadPending(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
        )
    }

    @Test func pttSystemPolicyReducerResetPreservesLatestTokenButClearsUploadedChannelBinding() {
        let state = PTTSystemPolicyState(
            latestTokenHex: "deadbeef",
            uploadedTokenHex: "deadbeef",
            uploadedBackendChannelID: "old-channel"
        )

        let transition = PTTSystemPolicyReducer.reduce(
            state: state,
            event: .reset
        )

        #expect(
            transition.state.tokenRegistration
                == .tokenKnown(tokenHex: "deadbeef", backendChannelID: nil)
        )
        #expect(transition.effects.isEmpty)
    }

    @MainActor
    @Test func persistedPTTSystemPolicyStateRestoresAcrossViewModelInit() async {
        let suiteName = "TurboTests.ptt-system-policy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PTTSystemPolicyPersistence.store(
            PTTSystemPolicyState(
                latestTokenHex: "deadbeef",
                uploadedTokenHex: "deadbeef",
                uploadedBackendChannelID: "old-channel"
            ),
            to: defaults
        )

        let viewModel = PTTViewModel(pttSystemPolicyDefaults: defaults)
        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        #expect(viewModel.pushTokenHex == "deadbeef")
        #expect(viewModel.pttSystemPolicyCoordinator.state.uploadedBackendChannelID == "old-channel")

        await viewModel.pttSystemPolicyCoordinator.handle(.backendChannelReady("channel-1"))

        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )

        let restoredState = PTTSystemPolicyPersistence.load(from: defaults)
        #expect(restoredState.latestTokenHex == "deadbeef")
        #expect(restoredState.tokenRegistrationKind == "token-known")
        #expect(restoredState.uploadedBackendChannelID == nil)
    }

    @MainActor
    @Test func resetLocalDevStatePreservesPTTTokenAcrossRejoinAndTriggersFreshUpload() async {
        let suiteName = "TurboTests.ptt-system-policy-reset.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("failed to create isolated user defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PTTSystemPolicyPersistence.store(
            PTTSystemPolicyState(
                latestTokenHex: "deadbeef",
                uploadedTokenHex: "deadbeef",
                uploadedBackendChannelID: "old-channel"
            ),
            to: defaults
        )

        let viewModel = PTTViewModel(pttSystemPolicyDefaults: defaults)
        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.resetLocalDevState(backendStatus: "Reconnecting...")

        #expect(viewModel.pushTokenHex == "deadbeef")
        #expect(
            viewModel.pttSystemPolicyCoordinator.state.tokenRegistration
                == .tokenKnown(tokenHex: "deadbeef", backendChannelID: nil)
        )

        let resetPersistedState = PTTSystemPolicyPersistence.load(from: defaults)
        #expect(resetPersistedState.latestTokenHex == "deadbeef")
        #expect(resetPersistedState.tokenRegistrationKind == "token-known")
        #expect(resetPersistedState.uploadedBackendChannelID == nil)

        await viewModel.pttSystemPolicyCoordinator.handle(.backendChannelReady("channel-1"))

        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @MainActor
    @Test func restoredChannelFlushesDeferredPTTTokenUploadOnceBackendChannelIsKnown() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.pttSystemPolicyCoordinator.send(
            .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: nil)
        )

        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleRestoredChannel(channelUUID)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
        #expect(viewModel.pushTokenHex == "deadbeef")
        #expect(viewModel.pttSystemPolicyCoordinator.state.uploadedBackendChannelID == nil)
    }

    @MainActor
    @Test func resolvingRestoredSystemSessionBindsContactAndFlushesDeferredTokenUpload() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: nil))
        viewModel.syncPTTState()
        viewModel.pttSystemPolicyCoordinator.send(
            .ephemeralTokenReceived(tokenHex: "deadbeef", backendChannelID: nil)
        )

        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        let resolvedContactID = await viewModel.resolveRestoredSystemSessionIfPossible(trigger: "test")

        #expect(resolvedContactID == contactID)
        #expect(viewModel.isJoined)
        #expect(viewModel.activeChannelId == contactID)
        #expect(
            viewModel.pttCoordinator.state.systemSessionState
                == .active(contactID: contactID, channelUUID: channelUUID)
        )
        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "deadbeef"
                    )
                )
            ]
        )
    }

    @MainActor
    @Test func unresolvedRestoredSystemSessionIsClearedAfterAuthoritativeRefresh() {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let restoredChannelUUID = UUID()
        let unrelatedContactID = UUID()
        viewModel.contacts = [
            Contact(
                id: unrelatedContactID,
                name: "Avery",
                handle: "@avery",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: nil,
                remoteUserId: "user-avery"
            )
        ]
        viewModel.pttCoordinator.send(.restoredChannel(channelUUID: restoredChannelUUID, contactID: nil))
        viewModel.syncPTTState()

        viewModel.clearUnresolvedRestoredSystemSessionIfNeeded(trigger: "test")

        #expect(pttClient.leaveRequests == [restoredChannelUUID])
        #expect(viewModel.isJoined == false)
        #expect(viewModel.activeChannelId == nil)
        #expect(viewModel.pttCoordinator.state.systemSessionState == .none)
        #expect(
            viewModel.diagnostics.invariantViolations.contains {
                $0.invariantID == "ptt.restored_channel_without_backend_contact"
            }
        )
    }

    @MainActor
    @Test func resolvedRestoredSystemSessionIsNotClearedAfterAuthoritativeRefresh() {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let restoredChannelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: false,
                channelId: restoredChannelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.pttCoordinator.send(.restoredChannel(channelUUID: restoredChannelUUID, contactID: nil))
        viewModel.syncPTTState()

        viewModel.clearUnresolvedRestoredSystemSessionIfNeeded(trigger: "test")

        #expect(pttClient.leaveRequests.isEmpty)
        #expect(viewModel.isJoined)
        #expect(
            viewModel.pttCoordinator.state.systemSessionState
                == .mismatched(channelUUID: restoredChannelUUID)
        )
    }

    @MainActor
    @Test func absentSummaryMembershipTearsDownStaleJoinedSystemSession() async {
        let pttClient = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: pttClient)
        let contactID = UUID()
        let channelUUID = ContactDirectory.stableChannelUUID(for: "channel")
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.selectedContactId = contactID
        viewModel.activeChannelId = contactID
        viewModel.isJoined = true
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test")
        )
        viewModel.backendSyncCoordinator.send(
            .channelStateUpdated(
                contactID: contactID,
                channelState: makeChannelState(status: .ready, canTransmit: true)
            )
        )
        viewModel.backendSyncCoordinator.send(
            .channelReadinessUpdated(
                contactID: contactID,
                readiness: makeChannelReadiness(status: .ready)
            )
        )

        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: makeContactSummary(
                        channelId: "channel",
                        isOnline: true,
                        badgeStatus: "online",
                        membershipKind: "absent"
                    )
                )
            ])
        )
        await viewModel.reconcileSelectedSessionIfNeeded()

        #expect(pttClient.leaveRequests == [channelUUID])
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelStates[contactID]?.membership == .absent)
        #expect(viewModel.backendSyncCoordinator.state.syncState.channelReadiness[contactID] == nil)
    }

    @MainActor
    @Test func receivedEphemeralTokenUsesResolvedSystemChannelBackendWhenActiveChannelIsUnset() async {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-1",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.pttCoordinator.send(.restoredChannel(channelUUID: channelUUID, contactID: nil))
        viewModel.syncPTTState()

        var capturedEffects: [PTTSystemPolicyEffect] = []
        viewModel.pttSystemPolicyCoordinator.effectHandler = { effect in
            capturedEffects.append(effect)
        }

        viewModel.handleReceivedEphemeralPushToken(Data("token".utf8))
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.activeChannelId == nil)
        #expect(
            capturedEffects == [
                .uploadEphemeralToken(
                    PTTTokenUploadRequest(
                        backendChannelID: "channel-1",
                        tokenHex: "746f6b656e"
                    )
                )
            ]
        )
    }

    @Test func pttWakeRuntimeUsesSystemActivatedModeAfterAudioSessionActivation() {
        let runtime = PTTWakeRuntimeState()
        let contactID = UUID()
        let otherContactID = UUID()
        let channelUUID = UUID()

        runtime.store(
            PendingIncomingPTTPush(
                contactID: contactID,
                channelUUID: channelUUID,
                payload: TurboPTTPushPayload(
                    event: .transmitStart,
                    channelId: "channel-1",
                    activeSpeaker: "@blake",
                    senderUserId: "sender",
                    senderDeviceId: "device"
                )
            )
        )

        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)
        runtime.markAudioSessionActivated(for: channelUUID)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .systemActivated)
        #expect(runtime.mediaSessionActivationMode(for: otherContactID) == .appManaged)
        runtime.clear(for: contactID)
        #expect(runtime.mediaSessionActivationMode(for: contactID) == .appManaged)
    }

    @Test func pttSystemDisplayPolicyUsesContactNameForRestoredDescriptor() {
        let channelUUID = UUID()
        let contact = Contact(
            id: UUID(),
            name: "Avery",
            handle: "@avery",
            isOnline: true,
            channelId: channelUUID,
            backendChannelId: "channel-1",
            remoteUserId: "user-avery"
        )

        let knownName = PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: channelUUID,
            contacts: [contact],
            fallbackName: "Fallback"
        )
        let fallbackName = PTTSystemDisplayPolicy.restoredDescriptorName(
            channelUUID: UUID(),
            contacts: [contact],
            fallbackName: "Fallback"
        )

        #expect(knownName == "Chat with Avery")
        #expect(fallbackName == "Fallback")
    }

    @Test func pttPushPayloadParsesTransmitStart() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "event": "transmit-start",
                "channelId": "channel-1",
                "activeSpeaker": "@blake",
                "senderUserId": "user-blake",
                "senderDeviceId": "device-blake",
            ]
        )

        #expect(payload?.event == .transmitStart)
        #expect(payload?.channelId == "channel-1")
        #expect(payload?.participantName == "@blake")
    }

    @Test func pttPushPayloadParsesLeaveChannel() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "type": "leave-channel",
                "channelId": "channel-1",
            ]
        )

        #expect(payload?.event == .leaveChannel)
        #expect(payload?.channelId == "channel-1")
    }

    @Test func pttPushPayloadRejectsUnknownEvent() {
        let payload = TurboPTTPushPayload(
            pushPayload: [
                "event": "unknown-event",
                "channelId": "channel-1",
            ]
        )

        #expect(payload == nil)
    }

    @Test func transmittablePrimaryActionUsesHoldToTalk() {
        let action = ConversationStateMachine.primaryAction(
            conversationState: .ready,
            isSelectedChannelJoined: true,
            canTransmitNow: true,
            isTransmitting: false,
            requestCooldownRemaining: nil
        )

        switch action.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected hold-to-talk primary action when transmission is available")
        }
        #expect(action.label == "Hold To Talk")
        #expect(action.isEnabled)
        switch action.style {
        case .accent:
            break
        case .muted, .active:
            Issue.record("Expected accent styling for hold-to-talk readiness")
        }
    }

    @Test func holdToTalkButtonPolicyKeepsActivePresentationWhileGestureIsHeld() {
        let action = ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        )

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: true)

        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected hold-to-talk presentation to remain a hold action")
        }
        #expect(displayAction.label == "Release To Stop")
        #expect(displayAction.isEnabled)
        switch displayAction.style {
        case .active:
            break
        case .accent, .muted:
            Issue.record("Expected active styling while hold gesture remains pressed")
        }
    }

    @Test func holdToTalkButtonPolicyLeavesIdleHoldPresentationUnchanged() {
        let action = ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        )

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: false)

        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected idle hold-to-talk presentation to remain a hold action")
        }
        #expect(displayAction.label == "Hold To Talk")
        #expect(displayAction.isEnabled)
        switch displayAction.style {
        case .accent:
            break
        case .active, .muted:
            Issue.record("Expected accent styling while idle and ready to talk")
        }
    }

    @Test func holdToTalkButtonPolicyKeepsHoldControlMountedWhileGestureIsHeld() {
        let action = ConversationPrimaryAction(
            kind: .connect,
            label: "Connect",
            isEnabled: true,
            style: .accent
        )

        #expect(HoldToTalkButtonPolicy.shouldRenderHoldToTalkControl(action, gestureIsActive: true))
        #expect(!HoldToTalkButtonPolicy.shouldRenderHoldToTalkControl(action, gestureIsActive: false))

        let displayAction = HoldToTalkButtonPolicy.displayAction(action, gestureIsActive: true)
        switch displayAction.kind {
        case .holdToTalk:
            break
        case .connect:
            Issue.record("Expected latched hold control to stay mounted while gesture remains pressed")
        }
        #expect(displayAction.label == "Release To Stop")
    }

    @Test func holdToTalkGestureStateRequiresReleaseAfterMachineEndsHeldPress() {
        var state = HoldToTalkGestureState()

        let didBegin = state.beginIfAllowed(isEnabled: true)
        #expect(didBegin)

        state.handleMachinePressChanged(isActive: false)

        #expect(state.isTrackingTouch == false)
        #expect(state.requiresReleaseBeforeNextPress)
        let blockedBegin = state.beginIfAllowed(isEnabled: true)
        #expect(blockedBegin == false)
    }

    @Test func holdToTalkGestureStateRearmsOnlyAfterTouchEnds() {
        var state = HoldToTalkGestureState()

        let firstBegin = state.beginIfAllowed(isEnabled: true)
        #expect(firstBegin)
        state.handleMachinePressChanged(isActive: false)

        #expect(state.endTouch() == false)
        #expect(state.requiresReleaseBeforeNextPress == false)
        let secondBegin = state.beginIfAllowed(isEnabled: true)
        #expect(secondBegin)
    }

    @Test func transmitRuntimeRequiresFreshPressAfterUnexpectedSystemEndUntilTouchRelease() {
        var runtime = TransmitRuntimeState()
        let contactID = UUID()

        runtime.markPressBegan()
        runtime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)

        #expect(runtime.isPressingTalk == false)
        #expect(runtime.requiresReleaseBeforeNextPress == true)
        #expect(runtime.interruptedContactID == contactID)

        runtime.markPressBegan()
        #expect(runtime.isPressingTalk == false)

        runtime.noteTouchReleased()
        runtime.markPressBegan()
        #expect(runtime.isPressingTalk == true)
        #expect(runtime.requiresReleaseBeforeNextPress == false)
        #expect(runtime.interruptedContactID == nil)
    }

    @Test func transmitRuntimeIdleReconcilePreservesFreshPressBarrierUntilTouchRelease() {
        var runtime = TransmitRuntimeState()
        let contactID = UUID()

        runtime.markPressBegan()
        runtime.markUnexpectedSystemEndRequiresRelease(contactID: contactID)
        runtime.reconcileIdleState()

        #expect(runtime.requiresReleaseBeforeNextPress == true)
        #expect(runtime.interruptedContactID == contactID)

        runtime.noteTouchReleased()

        #expect(runtime.requiresReleaseBeforeNextPress == false)
        #expect(runtime.interruptedContactID == nil)
    }

    @MainActor
    @Test func systemActivatedReceivePlaybackDefersUntilPTTAudioSessionIsActive() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-avery",
                remoteUserId: "user-avery"
            )
        ]
        viewModel.remoteTransmittingContactIDs = [contactID]
        viewModel.pttCoordinator.send(.didJoinChannel(channelUUID: channelUUID, contactID: contactID, reason: "test"))
        viewModel.syncPTTState()
        viewModel.isPTTAudioSessionActive = false

        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            )
        )
        #expect(
            viewModel.shouldUseSystemActivatedReceivePlayback(
                for: contactID,
                applicationState: .background
            ) == false
        )

        viewModel.isPTTAudioSessionActive = true
        #expect(
            viewModel.shouldDeferBackgroundPlaybackUntilPTTAudioActivation(
                for: contactID,
                applicationState: .background
            ) == false
        )
    }

    @Test func selfCheckSummaryPrefersFailingStep() {
        let report = DevSelfCheckReport(
            startedAt: .now,
            completedAt: .now,
            targetHandle: "@blake",
            steps: [
                DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok"),
                DevSelfCheckStep(.channelState, status: .failed, detail: "state failed")
            ]
        )

        #expect(report.isPassing == false)
        #expect(report.summary == "Self-check failed at channel state")
    }

    @Test func selfCheckSummaryUsesTargetOnSuccess() {
        let report = DevSelfCheckReport(
            startedAt: .now,
            completedAt: .now,
            targetHandle: "@avery",
            steps: [
                DevSelfCheckStep(.backendConfig, status: .passed, detail: "ok"),
                DevSelfCheckStep(.sessionAlignment, status: .passed, detail: "aligned")
            ]
        )

        #expect(report.isPassing)
        #expect(report.summary == "Self-check passed for @avery")
    }

    @MainActor
    @Test func diagnosticsExportIncludesStateTimeline() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "idle",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedPeerStatus": "Blake is online"
            ]
        )

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "peerReady",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "connecting",
                "backendSelfJoined": "false",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedPeerStatus": "Blake is ready to connect"
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=peerReady")

        #expect(exported.contains("STATE SNAPSHOT"))
        #expect(exported.contains("STATE TIMELINE"))
        #expect(exported.contains("[selected-peer-sync]"))
        #expect(exported.contains("phase=peerReady"))
        #expect(exported.contains("status=Blake is ready to connect"))
    }

    @MainActor
    @Test func diagnosticsLatestErrorClearsWhenBoundedBufferDropsOldError() {
        let store = DiagnosticsStore()
        store.clear()

        store.record(.pushToTalk, level: .error, message: "PTT init failed")
        #expect(store.latestError?.message == "PTT init failed")

        for index in 0..<200 {
            store.record(.app, level: .info, message: "info-\(index)")
        }

        #expect(store.entries.count == 200)
        #expect(store.latestError == nil)
    }

    @MainActor
    @Test func recoveredPTTInitFailureDoesNotSurfaceInTopChrome() {
        let client = RecordingPTTSystemClient()
        client.isReady = false

        let viewModel = PTTViewModel(pttSystemClient: client)
        viewModel.diagnostics.clear()
        viewModel.diagnostics.record(.pushToTalk, level: .error, message: "PTT init failed")

        #expect(viewModel.diagnostics.latestError?.message == "PTT init failed")
        #expect(viewModel.topChromeDiagnosticsErrorText == "ptt: PTT init failed")

        client.isReady = true

        #expect(viewModel.diagnostics.latestError?.message == "PTT init failed")
        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func directQuicPathLostDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.diagnostics.clear()
        viewModel.diagnostics.record(
            .media,
            level: .error,
            message: "Direct QUIC media path lost",
            metadata: ["reason": "consent-timeout"]
        )

        #expect(viewModel.diagnostics.latestError?.message == "Direct QUIC media path lost")
        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func diagnosticsExportIncludesInvariantViolations() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "ready",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "backendCanTransmit": "false",
                "selectedPeerStatus": "Connected"
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=ready")

        #expect(exported.contains("INVARIANT VIOLATIONS"))
        #expect(exported.contains("[selected.ready_without_join]"))
        #expect(exported.contains("[selected.ready_while_backend_cannot_transmit]"))
        #expect(store.invariantViolations.contains { $0.invariantID == "selected.ready_without_join" })
        #expect(store.latestError?.message == "selectedPeerPhase=ready while backendCanTransmit=false")
    }

    @MainActor
    @Test func diagnosticsExportIncludesStaleMembershipPeerReadyInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "peerReady",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "inactive",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "false",
                "selectedPeerStatus": "Blake is ready to connect"
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=peerReady")

        #expect(exported.contains("[selected.stale_membership_peer_ready_without_session]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.stale_membership_peer_ready_without_session"
            }
        )
        #expect(
            store.latestError?.message
                == "backend retained durable channel membership while selectedPeerPhase is peerReady without a local session"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesWaitingForSelfNotConnectableInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "idle",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-self",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedPeerStatus": "Blake is online"
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=idle")

        #expect(exported.contains("[selected.waiting_for_self_ui_not_connectable]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.waiting_for_self_ui_not_connectable"
            }
        )
        #expect(
            store.latestError?.message
                == "backend says the peer is waiting for self, but selectedPeerPhase is still not connectable"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesWakeCapablePeerNotConnectableInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "idle",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-self",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedPeerStatus": "Blake is online"
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=idle")

        #expect(exported.contains("[selected.peer_wake_capable_ui_not_connectable]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.peer_wake_capable_ui_not_connectable"
            }
        )
        #expect(
            store.latestError?.message
                == "backend channel is connectable and peer wake is available, but selectedPeerPhase is still not connectable"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesJoinedSessionLostWakeCapabilityInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "hadConnectedSessionContinuity": "true",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: test, channelUUID: test)",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "remoteWakeCapabilityKind": "unavailable",
                "selectedPeerStatus": "Establishing connection..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(exported.contains("[selected.joined_session_lost_wake_capability]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.joined_session_lost_wake_capability"
            }
        )
        #expect(
            store.latestError?.message
                == "joined live session regressed to waiting-for-peer without wake capability"
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendInactiveStillJoinedInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.localSessionTransition)",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "hadConnectedSessionContinuity": "true",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: test, channelUUID: test)",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "selectedPeerStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_inactive_ui_still_joined]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_inactive_ui_still_joined"
            }
        )
        #expect(
            store.invariantViolations.contains {
                $0.message
                    == "backend says the session is inactive, but selectedPeerPhase is still waitingForPeer on a joined local session"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendMembershipAbsentStillJoinedInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.backendSessionTransition)",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedSessionContinuity": "true",
                "selectedPeerStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_membership_absent_ui_still_joined]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_membership_absent_ui_still_joined"
            }
        )
        #expect(
            store.latestError?.message
                == "backend says channel membership is absent, but selectedPeerPhase is still waitingForPeer on a joined local session"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendMembershipAbsentInvariantDuringScheduledTeardown() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.localSessionTransition)",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "selectedPeerReconciliationAction": "teardownSelectedSession(contactID: 123)",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "none",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedSessionContinuity": "true",
                "selectedPeerStatus": "Connecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_membership_absent_ui_still_joined]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_membership_absent_ui_still_joined"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendMembershipAbsentInvariantDuringDisconnectingTeardown() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-effect:teardown-local",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.disconnecting)",
                "selectedPeerRelationship": "none",
                "pendingAction": "leave(BeepBeep.PendingLeaveAction.reconciledTeardown(contactID: 123))",
                "isJoined": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "idle",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedSessionContinuity": "true",
                "selectedPeerStatus": "Disconnecting..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_membership_absent_ui_still_joined]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_membership_absent_ui_still_joined"
            }
        )
    }

    @MainActor
    @Test func diagnosticsFlagsReconciledTeardownWithoutLocalSession() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-status-refresh",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.disconnecting)",
                "selectedPeerRelationship": "incomingRequest(requestCount: 1)",
                "pendingAction": "leave(BeepBeep.PendingLeaveAction.reconciledTeardown(contactID: 123))",
                "isJoined": "false",
                "isTransmitting": "false",
                "systemSession": "none",
                "backendChannelStatus": "incoming-request",
                "backendReadiness": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "hadConnectedSessionContinuity": "true",
                "selectedPeerStatus": "Disconnecting..."
            ]
        )

        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.reconciled_teardown_without_local_session"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesBackendReadyMissingRemoteAudioSignalInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.remoteAudioPrewarm)",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "mediaState": "connected",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedPeerStatus": "Waiting for Blake's audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(exported.contains("[selected.backend_ready_missing_remote_audio_signal]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.backend_ready_missing_remote_audio_signal"
            }
        )
        #expect(
            store.latestError?.message
                == "backend says the peer is ready and connected, but selectedPeerPhase is still waitingForPeer on remote audio prewarm"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesBackendReadyMissingRemoteAudioSignalInvariantDuringSignalingRecovery() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "backend-signaling:recovery-scheduled",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.remoteAudioPrewarm)",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "backendSignalingJoinRecoveryActive": "true",
                "isJoined": "true",
                "mediaState": "connected",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "backendPeerDeviceConnected": "true",
                "selectedPeerStatus": "Waiting for Blake's audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(!exported.contains("[selected.backend_ready_missing_remote_audio_signal]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.backend_ready_missing_remote_audio_signal"
            }
        )
    }

    @MainActor
    @Test func diagnosticsExportIncludesWakeCapablePeerBlockedOnLocalAudioPrewarmInvariant() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-peer-sync",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.localAudioPrewarm)",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "hadConnectedSessionContinuity": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "remoteAudioReadiness": "wakeCapable",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedPeerStatus": "Preparing audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(exported.contains("[selected.wake_capable_peer_blocked_on_local_audio_prewarm]"))
        #expect(
            store.invariantViolations.contains {
                $0.invariantID == "selected.wake_capable_peer_blocked_on_local_audio_prewarm"
            }
        )
        #expect(
            store.latestError?.message
                == "peer is wake-capable, but selectedPeerPhase is still waitingForPeer on local audio prewarm"
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesWakeCapableLocalAudioPrewarmInvariantWhenPeerAudioIsReady() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-status-refresh",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.localAudioPrewarm)",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "hadConnectedSessionContinuity": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "remoteAudioReadiness": "ready",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedPeerStatus": "Preparing audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(!exported.contains("[selected.wake_capable_peer_blocked_on_local_audio_prewarm]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.wake_capable_peer_blocked_on_local_audio_prewarm"
            }
        )
    }

    @MainActor
    @Test func diagnosticsSuppressesWakeCapableLocalAudioPrewarmInvariantWhenPeerAudioIsWaiting() {
        let store = DiagnosticsStore()
        store.clear()

        store.captureState(
            reason: "selected-status-refresh",
            fields: [
                "selectedContact": "@blake",
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerPhaseDetail": "waitingForPeer(reason: BeepBeep.SelectedPeerWaitingReason.localAudioPrewarm)",
                "selectedPeerRelationship": "none",
                "pendingAction": "none",
                "isJoined": "true",
                "hadConnectedSessionContinuity": "true",
                "isTransmitting": "false",
                "systemSession": "active(contactID: 123, channelUUID: 456)",
                "backendChannelStatus": "ready",
                "backendReadiness": "ready",
                "backendSelfJoined": "true",
                "backendPeerJoined": "true",
                "remoteAudioReadiness": "waiting",
                "remoteWakeCapabilityKind": "wake-capable",
                "selectedPeerStatus": "Preparing audio..."
            ]
        )

        let exported = store.exportText(snapshot: "selectedPeerPhase=waitingForPeer")

        #expect(!exported.contains("[selected.wake_capable_peer_blocked_on_local_audio_prewarm]"))
        #expect(
            !store.invariantViolations.contains {
                $0.invariantID == "selected.wake_capable_peer_blocked_on_local_audio_prewarm"
            }
        )
    }

    @MainActor
    @Test func recoveredBackendReadyMissingRemoteAudioSignalDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.diagnostics.clear()

        viewModel.diagnostics.record(
            .invariant,
            level: .error,
            message: "backend says the peer is ready and connected, but selectedPeerPhase is still waitingForPeer on remote audio prewarm"
        )

        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func recoveredWakeCapableLocalAudioPrewarmInvariantDoesNotSurfaceInTopChrome() {
        let viewModel = PTTViewModel()
        viewModel.diagnostics.clear()

        viewModel.diagnostics.record(
            .invariant,
            level: .error,
            message: "peer is wake-capable, but selectedPeerPhase is still waitingForPeer on local audio prewarm",
            metadata: [
                "invariantID": "selected.wake_capable_peer_blocked_on_local_audio_prewarm",
                "remoteAudioReadiness": "wakeCapable",
                "remoteWakeCapabilityKind": "wake-capable",
            ]
        )

        #expect(viewModel.topChromeDiagnosticsErrorText == nil)
    }

    @MainActor
    @Test func diagnosticsStoreAcceptsBackgroundRecordCalls() async {
        let store = DiagnosticsStore()
        store.clear()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    store.record(.app, message: "background-\(index)")
                }
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(store.entries.count == 8)
        #expect(store.entries.allSatisfy { $0.message.hasPrefix("background-") })
    }

    @MainActor
    @Test func diagnosticsSnapshotIncludesMachineReadableContactProjection() {
        let viewModel = PTTViewModel()
        let contactID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Blake",
                handle: "@blake",
                isOnline: false,
                channelId: UUID(),
                backendChannelId: "channel-1",
                remoteUserId: "user-blake"
            )
        ]
        viewModel.backendSyncCoordinator.send(
            .contactSummariesUpdated([
                BackendContactSummaryUpdate(
                    contactID: contactID,
                    summary: TurboContactSummaryResponse(
                        userId: "user-blake",
                        handle: "@blake",
                        displayName: "Blake",
                        channelId: "channel-1",
                        isOnline: true,
                        hasIncomingRequest: false,
                        hasOutgoingRequest: false,
                        requestCount: 0,
                        isActiveConversation: false,
                        badgeStatus: "online"
                    )
                )
            ])
        )

        let snapshot = viewModel.diagnosticsSnapshot

        #expect(snapshot.contains("contact[@blake].isOnline=true"))
        #expect(snapshot.contains("contact[@blake].listState=idle"))
        #expect(snapshot.contains("contact[@blake].badgeStatus=online"))
    }

    @MainActor
    @Test func simulatorPTTClientJoinsAndTransmits() async throws {
        let recorder = TestPTTCallbackRecorder()
        let client = SimulatorPTTSystemClient()
        let channelID = UUID()

        try await client.configure(callbacks: recorder.callbacks)
        try client.joinChannel(channelUUID: channelID, name: "Avery")
        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(recorder.joinedChannelIDs == [channelID])
        #expect(recorder.joinFailures.isEmpty)
        #expect(recorder.ephemeralPushTokens.count == 1)
        #expect(recorder.ephemeralPushTokens.first?.isEmpty == false)

        try client.beginTransmitting(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.didBeginTransmittingChannelIDs == [channelID])
        #expect(recorder.activatedAudioSessionCategories == [.playAndRecord])

        try client.stopTransmitting(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.didEndTransmittingChannelIDs == [channelID])
        #expect(recorder.deactivatedAudioSessionCategories == [.playAndRecord])

        try client.leaveChannel(channelUUID: channelID)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.leftChannelIDs == [channelID])
    }

    @MainActor
    @Test func joinPTTChannelRetriesStalePendingJoinWithoutLocalSessionEvidence() {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()
        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.sessionCoordinator.queueJoin(contactID: contactID)

        viewModel.joinPTTChannel(for: viewModel.contacts[0])

        #expect(client.joinRequests == [channelUUID])
        #expect(viewModel.pendingJoinContactId == contactID)
    }

    @MainActor
    @Test func pttAccessoryButtonEventsAreEnabledForJoinedSystemChannel() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let channelUUID = UUID()
        viewModel.pttCoordinator.send(
            .didJoinChannel(channelUUID: channelUUID, contactID: nil, reason: "test")
        )

        viewModel.syncPTTAccessoryButtonEvents(reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(client.accessoryButtonEventUpdates.count == 1)
        #expect(client.accessoryButtonEventUpdates.first?.enabled == true)
        #expect(client.accessoryButtonEventUpdates.first?.channelUUID == channelUUID)
    }

    @MainActor
    @Test func failedJoinChannelLimitRecoversStaleSystemChannelAndRetriesJoin() async {
        let client = RecordingPTTSystemClient()
        let viewModel = PTTViewModel(pttSystemClient: client)
        let contactID = UUID()
        let channelUUID = UUID()

        viewModel.contacts = [
            Contact(
                id: contactID,
                name: "Avery",
                handle: "@avery",
                isOnline: true,
                channelId: channelUUID,
                backendChannelId: "channel-123",
                remoteUserId: "peer-user"
            )
        ]
        viewModel.selectedContactId = contactID

        let error = NSError(domain: PTChannelErrorDomain, code: 2)
        viewModel.handleFailedToJoinChannel(channelUUID, error: error)
        try? await Task.sleep(nanoseconds: 400_000_000)

        #expect(client.leaveRequests == [channelUUID])
        #expect(client.joinRequests == [channelUUID])
        #expect(viewModel.pttCoordinator.state.lastJoinFailure == nil)
        #expect(viewModel.pendingJoinContactId == contactID)
    }

    @MainActor
    @Test func simulatorPTTClientRejectsSecondConcurrentChannel() async throws {
        let recorder = TestPTTCallbackRecorder()
        let client = SimulatorPTTSystemClient()
        let firstChannelID = UUID()
        let secondChannelID = UUID()

        try await client.configure(callbacks: recorder.callbacks)
        try client.joinChannel(channelUUID: firstChannelID, name: "Avery")
        try await Task.sleep(nanoseconds: 250_000_000)

        try client.joinChannel(channelUUID: secondChannelID, name: "Blake")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(recorder.joinedChannelIDs == [firstChannelID])
        #expect(recorder.ephemeralPushTokens.count == 1)
        #expect(recorder.joinFailures.count == 1)
        #expect(recorder.joinFailures.first?.channelID == secondChannelID)
        #expect((recorder.joinFailures.first?.error as NSError?)?.code == 2)
    }

    @MainActor
    @Test func simulatorBuildUsesStubMediaSessionEvenWhenWebSocketIsAvailable() {
        let session = makeDefaultMediaSession(supportsWebSocket: true) { _ in }

        #if targetEnvironment(simulator)
        #expect(session is StubRelayMediaSession)
        #else
        #expect(session is PCMWebSocketMediaSession)
        #endif
    }

}

@MainActor
struct SimulatorScenarioTests {
    @Test func simulatorDistributedJoinScenario() async throws {
        guard let runtimeConfig = loadSimulatorScenarioRuntimeConfig() else {
            return
        }
        let specs = try loadSimulatorScenarioSpecs(runtimeConfig: runtimeConfig)
        for spec in specs {
            try await executeSimulatorScenario(spec)
        }
    }
}

struct SimulatorScenarioPlannerTests {
    @Test func scenarioPlannerSupportsDelayDropAndDuplicateDelivery() throws {
        let scheduled = try scheduledScenarioActions(
            for: [
                SimulatorScenarioAction(
                    actor: "a",
                    type: "connect",
                    peer: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: 400,
                    repeatCount: nil,
                    repeatIntervalMilliseconds: nil,
                    reorderIndex: nil,
                    drop: nil
                ),
                SimulatorScenarioAction(
                    actor: "b",
                    type: "refreshContactSummaries",
                    peer: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: nil,
                    repeatCount: 2,
                    repeatIntervalMilliseconds: 150,
                    reorderIndex: nil,
                    drop: nil
                ),
                SimulatorScenarioAction(
                    actor: "a",
                    type: "refreshInvites",
                    peer: nil,
                    route: nil,
                    signalKind: nil,
                    milliseconds: nil,
                    count: nil,
                    delayMilliseconds: 50,
                    repeatCount: nil,
                    repeatIntervalMilliseconds: nil,
                    reorderIndex: nil,
                    drop: true
                ),
            ]
        )

        #expect(scheduled.count == 3)
        #expect(scheduled.map { $0.actor } == ["b", "b", "a"])
        #expect(scheduled.map { $0.scheduledDelayMilliseconds } == [0, 150, 400])
        #expect(scheduled.map { $0.deliveryIndex } == [0, 1, 0])
        #expect(scheduled.map { $0.action.type } == ["refreshContactSummaries", "refreshContactSummaries", "connect"])
    }

    @Test func scenarioPlannerRejectsNegativeDelay() throws {
        #expect(throws: ScenarioFailure.self) {
            _ = try scheduledScenarioActions(
                for: [
                    SimulatorScenarioAction(
                        actor: "a",
                        type: "connect",
                        peer: nil,
                        route: nil,
                        signalKind: nil,
                        milliseconds: nil,
                        count: nil,
                        delayMilliseconds: -1,
                        repeatCount: nil,
                        repeatIntervalMilliseconds: nil,
                        reorderIndex: nil,
                        drop: nil
                    )
                ]
            )
        }
    }

    @Test func transportFaultRuntimeConsumesHTTPAndSignalRulesDeterministically() {
        let faults = TransportFaultRuntimeState()

        faults.setHTTPDelay(route: .contactSummaries, milliseconds: 250, count: 2)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 250)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 250)
        #expect(faults.consumeHTTPDelay(for: .contactSummaries) == 0)

        faults.setWebSocketSignalDelay(kind: .transmitStart, milliseconds: 400, count: 1)
        faults.duplicateNextWebSocketSignals(kind: .transmitStart, count: 1)
        faults.dropNextWebSocketSignals(kind: .transmitStop, count: 1)
        faults.reorderNextWebSocketSignals(kind: nil, count: 2)

        let startEnvelope = TurboSignalEnvelope(
            type: .transmitStart,
            channelId: "channel",
            fromUserId: "a",
            fromDeviceId: "device-a",
            toUserId: "b",
            toDeviceId: "device-b",
            payload: "{}"
        )
        let stopEnvelope = TurboSignalEnvelope(
            type: .transmitStop,
            channelId: "channel",
            fromUserId: "a",
            fromDeviceId: "device-a",
            toUserId: "b",
            toDeviceId: "device-b",
            payload: "{}"
        )

        switch faults.consumeWebSocketReorderResult(for: startEnvelope) {
        case .buffered:
            break
        case .deliver:
            Issue.record("Expected first reordered websocket signal to be buffered")
        }

        switch faults.consumeWebSocketReorderResult(for: stopEnvelope) {
        case .buffered:
            Issue.record("Expected reordered websocket fault to flush on the second signal")
        case .deliver(let envelopes):
            #expect(envelopes.map(\.type.rawValue) == ["transmit-stop", "transmit-start"])
        }

        let firstTransmitStartPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStart)
        #expect(firstTransmitStartPlan.delayMilliseconds == 400)
        #expect(firstTransmitStartPlan.duplicateDeliveries == 1)
        #expect(firstTransmitStartPlan.shouldDrop == false)

        let secondTransmitStartPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStart)
        #expect(secondTransmitStartPlan.delayMilliseconds == 0)
        #expect(secondTransmitStartPlan.duplicateDeliveries == 0)
        #expect(secondTransmitStartPlan.shouldDrop == false)

        let transmitStopPlan = faults.consumeWebSocketSignalDeliveryPlan(for: .transmitStop)
        #expect(transmitStopPlan.delayMilliseconds == 0)
        #expect(transmitStopPlan.duplicateDeliveries == 0)
        #expect(transmitStopPlan.shouldDrop == true)
    }
}

@MainActor
private final class TestPTTCallbackRecorder {
    struct JoinFailure {
        let channelID: UUID
        let error: Error
    }

    var joinedChannelIDs: [UUID] = []
    var leftChannelIDs: [UUID] = []
    var didBeginTransmittingChannelIDs: [UUID] = []
    var didEndTransmittingChannelIDs: [UUID] = []
    var activatedAudioSessionCategories: [AVAudioSession.Category] = []
    var deactivatedAudioSessionCategories: [AVAudioSession.Category] = []
    var joinFailures: [JoinFailure] = []
    var incomingPushes: [(UUID, TurboPTTPushPayload)] = []
    var ephemeralPushTokens: [Data] = []

    var callbacks: PTTSystemClientCallbacks {
        PTTSystemClientCallbacks(
            receivedEphemeralPushToken: { [weak self] token in
                self?.ephemeralPushTokens.append(token)
            },
            receivedIncomingPush: { [weak self] channelID, payload in
                self?.incomingPushes.append((channelID, payload))
            },
            willReturnIncomingPushResult: { _, _, _ in },
            didJoinChannel: { [weak self] channelID, _ in
                self?.joinedChannelIDs.append(channelID)
            },
            didLeaveChannel: { [weak self] channelID, _ in
                self?.leftChannelIDs.append(channelID)
            },
            failedToJoinChannel: { [weak self] channelID, error in
                self?.joinFailures.append(JoinFailure(channelID: channelID, error: error))
            },
            failedToLeaveChannel: { _, _ in },
            didBeginTransmitting: { [weak self] channelID, _ in
                self?.didBeginTransmittingChannelIDs.append(channelID)
            },
            didEndTransmitting: { [weak self] channelID, _ in
                self?.didEndTransmittingChannelIDs.append(channelID)
            },
            failedToBeginTransmitting: { _, _ in },
            failedToStopTransmitting: { _, _ in },
            didActivateAudioSession: { [weak self] session in
                self?.activatedAudioSessionCategories.append(session.category)
            },
            didDeactivateAudioSession: { [weak self] session in
                self?.deactivatedAudioSessionCategories.append(session.category)
            },
            willRequestRestoredChannelDescriptor: { _ in },
            descriptorForRestoredChannel: { _ in
                PTChannelDescriptor(name: "Restored", image: nil)
            },
            restoredChannel: { _ in }
        )
    }
}

@MainActor
private final class RecordingPTTSystemClient: PTTSystemClientProtocol {
    var isReady: Bool = true
    var modeDescription: String { "test" }
    var activeRemoteParticipantError: Error?
    var activeRemoteParticipantDelayNanoseconds: UInt64?
    private(set) var joinRequests: [UUID] = []
    private(set) var leaveRequests: [UUID] = []
    private(set) var beginTransmitRequests: [UUID] = []
    private(set) var stopTransmitRequests: [UUID] = []
    private(set) var transmissionModeUpdates: [(mode: PTTransmissionMode, channelUUID: UUID)] = []
    private(set) var activeRemoteParticipantUpdates: [(name: String?, channelUUID: UUID)] = []
    private(set) var accessoryButtonEventUpdates: [(enabled: Bool, channelUUID: UUID)] = []

    func configure(callbacks _: PTTSystemClientCallbacks) async throws {}

    func joinChannel(channelUUID: UUID, name _: String) throws {
        joinRequests.append(channelUUID)
    }

    func leaveChannel(channelUUID: UUID) throws {
        leaveRequests.append(channelUUID)
    }
    func beginTransmitting(channelUUID: UUID) throws {
        beginTransmitRequests.append(channelUUID)
    }
    func stopTransmitting(channelUUID: UUID) throws {
        stopTransmitRequests.append(channelUUID)
    }
    func setTransmissionMode(_ mode: PTTransmissionMode, channelUUID: UUID) async throws {
        transmissionModeUpdates.append((mode: mode, channelUUID: channelUUID))
    }
    func setActiveRemoteParticipant(name: String?, channelUUID: UUID) async throws {
        if let activeRemoteParticipantDelayNanoseconds {
            try? await Task.sleep(nanoseconds: activeRemoteParticipantDelayNanoseconds)
        }
        activeRemoteParticipantUpdates.append((name: name, channelUUID: channelUUID))
        if let activeRemoteParticipantError {
            throw activeRemoteParticipantError
        }
    }
    func setAccessoryButtonEventsEnabled(_ enabled: Bool, channelUUID: UUID) async throws {
        accessoryButtonEventUpdates.append((enabled: enabled, channelUUID: channelUUID))
    }
    func setServiceStatus(_: PTServiceStatus, channelUUID _: UUID) async throws {}
    func updateChannelDescriptor(name _: String, channelUUID _: UUID) async throws {}
}

private final class RecordingMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?
    private(set) var state: MediaConnectionState = .idle
    private(set) var closedDeactivateAudioSessionFlags: [Bool] = []
    private(set) var startSendingAudioCallCount = 0
    private(set) var stopSendingAudioCallCount = 0
    private(set) var abortSendingAudioCallCount = 0
    private(set) var audioRouteDidChangeCallCount = 0
    private(set) var receivedRemoteAudioChunks: [String] = []
    var startSendingAudioDelayNanoseconds: UInt64?
    var audioRouteDidChangeDelayNanoseconds: UInt64?
    var hasPendingPlaybackResult = false

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {}

    func start(
        activationMode _: MediaSessionActivationMode,
        startupMode _: MediaSessionStartupMode
    ) async throws {
        state = .connected
        delegate?.mediaSession(self, didChange: .connected)
    }

    func startSendingAudio() async throws {
        startSendingAudioCallCount += 1
        if let startSendingAudioDelayNanoseconds {
            try? await Task.sleep(nanoseconds: startSendingAudioDelayNanoseconds)
        }
    }

    func stopSendingAudio() async throws {
        stopSendingAudioCallCount += 1
    }

    func abortSendingAudio() async {
        abortSendingAudioCallCount += 1
    }

    func receiveRemoteAudioChunk(_ payload: String) async {
        receivedRemoteAudioChunks.append(payload)
    }

    func audioRouteDidChange() async {
        audioRouteDidChangeCallCount += 1
        if let audioRouteDidChangeDelayNanoseconds {
            try? await Task.sleep(nanoseconds: audioRouteDidChangeDelayNanoseconds)
        }
    }

    func hasPendingPlayback() -> Bool { hasPendingPlaybackResult }

    func close(deactivateAudioSession: Bool) {
        closedDeactivateAudioSessionFlags.append(deactivateAudioSession)
        state = .closed
        delegate?.mediaSession(self, didChange: .closed)
    }
}

private final class DelayedStartMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?
    private(set) var state: MediaConnectionState = .idle
    private(set) var startCallCount = 0

    private let delayNanoseconds: UInt64
    private var shouldFinishStart = false
    private var isClosed = false

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {}

    func start(
        activationMode _: MediaSessionActivationMode,
        startupMode _: MediaSessionStartupMode
    ) async throws {
        startCallCount += 1
        state = .preparing
        delegate?.mediaSession(self, didChange: .preparing)
        while !shouldFinishStart && !isClosed {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !isClosed else { return }
        state = .connected
        delegate?.mediaSession(self, didChange: .connected)
    }

    func finishStart() {
        shouldFinishStart = true
    }

    func startSendingAudio() async throws {}

    func stopSendingAudio() async throws {}

    func receiveRemoteAudioChunk(_ payload: String) async {}

    func audioRouteDidChange() async {}

    func hasPendingPlayback() -> Bool { false }

    func close(deactivateAudioSession _: Bool) {
        isClosed = true
        state = .closed
        delegate?.mediaSession(self, didChange: .closed)
    }
}

private struct ScenarioFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private struct SimulatorScenarioConfig: Decodable {
    let name: String
    let baseURL: URL
    let requiresLocalBackend: Bool?
    let participants: [String: SimulatorScenarioParticipant]
    let steps: [SimulatorScenarioStep]
}

private struct SimulatorScenarioParticipant: Decodable {
    let handle: String
    let deviceId: String
}

private struct SimulatorScenarioStep: Decodable {
    let description: String
    let actions: [SimulatorScenarioAction]
    let expectEventually: [String: SimulatorScenarioExpectation]?
}

private struct SimulatorScenarioAction: Decodable {
    let actor: String
    let type: String
    let peer: String?
    let route: String?
    let signalKind: String?
    let milliseconds: Int?
    let count: Int?
    let delayMilliseconds: Int?
    let repeatCount: Int?
    let repeatIntervalMilliseconds: Int?
    let reorderIndex: Int?
    let drop: Bool?
}

private struct SimulatorScenarioExpectation: Decodable {
    let selectedHandle: String?
    let phase: String?
    let selectedStatus: String?
    let isJoined: Bool?
    let isTransmitting: Bool?
    let canTransmitNow: Bool?
    let pttTokenRegistrationKind: String?
    let selected: SimulatorScenarioSelectedExpectation?
    let contacts: [SimulatorScenarioContactExpectation]?
    let backend: SimulatorScenarioBackendExpectation?

    var selectedExpectation: SimulatorScenarioSelectedExpectation? {
        if let selected {
            return selected
        }

        if selectedHandle != nil
            || phase != nil
            || selectedStatus != nil
            || isJoined != nil
            || isTransmitting != nil
            || canTransmitNow != nil
            || pttTokenRegistrationKind != nil
        {
            return SimulatorScenarioSelectedExpectation(
                handle: selectedHandle,
                phase: phase,
                status: selectedStatus,
                isJoined: isJoined,
                isTransmitting: isTransmitting,
                canTransmitNow: canTransmitNow,
                pttTokenRegistrationKind: pttTokenRegistrationKind
            )
        }

        return nil
    }
}

private struct SimulatorScenarioSelectedExpectation: Decodable {
    let handle: String?
    let phase: String?
    let status: String?
    let isJoined: Bool?
    let isTransmitting: Bool?
    let canTransmitNow: Bool?
    let pttTokenRegistrationKind: String?
}

private struct SimulatorScenarioContactExpectation: Decodable {
    let handle: String
    let isOnline: Bool?
    let listState: String?
    let badgeStatus: String?
    let requestRelationship: String?
    let hasIncomingRequest: Bool?
    let hasOutgoingRequest: Bool?
    let requestCount: Int?
}

private struct SimulatorScenarioBackendExpectation: Decodable {
    let channelStatus: String?
    let readiness: String?
    let remoteAudioReadiness: String?
    let remoteWakeCapabilityKind: String?
    let membership: String?
    let requestRelationship: String?
    let selfJoined: Bool?
    let peerJoined: Bool?
    let peerDeviceConnected: Bool?
    let canTransmit: Bool?
    let webSocketConnected: Bool?
}

private enum SimulatorScenarioPhaseMatch {
    case exact
    case progressed
}

private struct SimulatorScenarioDiagnosticsArtifact: Codable {
    let scenarioName: String
    let handle: String
    let deviceId: String
    let baseURL: String
    let selectedHandle: String?
    let appVersion: String
    let snapshot: String
    let transcript: String
}

private struct ScheduledSimulatorScenarioAction {
    let actor: String
    let action: SimulatorScenarioAction
    let scheduledDelayMilliseconds: Int
    let declarationIndex: Int
    let deliveryIndex: Int
}

private struct SimulatorScenarioRuntimeConfig: Decodable {
    let enabledUntilEpochSeconds: TimeInterval
    let filter: String?
    let baseURL: URL?
    let handleA: String?
    let handleB: String?
    let deviceIDA: String?
    let deviceIDB: String?
}

private let simulatorScenarioRuntimeConfigURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".scenario-runtime-config.json", isDirectory: false)

@MainActor
private func makeSimulatorScenarioViewModel(baseURL: URL, handle: String, deviceID: String) -> PTTViewModel {
    let viewModel = PTTViewModel()
    viewModel.automaticDiagnosticsPublishEnabled = false
    viewModel.replaceBackendConfig(
        with: TurboBackendConfig(
            baseURL: baseURL,
            devUserHandle: handle,
            deviceID: deviceID
        )
    )
    return viewModel
}

private func loadSimulatorScenarioRuntimeConfig() -> SimulatorScenarioRuntimeConfig? {
    guard
        let data = try? Data(contentsOf: simulatorScenarioRuntimeConfigURL),
        let config = try? JSONDecoder().decode(SimulatorScenarioRuntimeConfig.self, from: data)
    else {
        return nil
    }

    guard Date().timeIntervalSince1970 <= config.enabledUntilEpochSeconds else {
        return nil
    }

    return config
}

private func loadSimulatorScenarioSpecs(runtimeConfig: SimulatorScenarioRuntimeConfig) throws -> [SimulatorScenarioConfig] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scenariosDirectory = root.appendingPathComponent("scenarios", isDirectory: true)
    let scenarioFiles =
        try FileManager.default.contentsOfDirectory(at: scenariosDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let decoder = JSONDecoder()
    let allSpecs = try scenarioFiles.map { fileURL in
        let data = try Data(contentsOf: fileURL)
        let spec = try decoder.decode(SimulatorScenarioConfig.self, from: data)
        return applyScenarioRuntimeConfig(runtimeConfig, to: spec)
    }
    guard !allSpecs.isEmpty else {
        throw ScenarioFailure(message: "No simulator scenario specs were found in \(scenariosDirectory.path)")
    }

    let filter = runtimeConfig.filter?
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard let filter, !filter.isEmpty else {
        return try runnableScenarioSpecs(
            allSpecs,
            filter: nil,
            baseURLOverride: runtimeConfig.baseURL
        )
    }

    let filtered = try runnableScenarioSpecs(
        allSpecs,
        filter: filter,
        baseURLOverride: runtimeConfig.baseURL
    )
    guard !filtered.isEmpty else {
        throw ScenarioFailure(
            message: "No runnable simulator scenarios matched filter \(filter.joined(separator: ",")) in \(scenariosDirectory.path)"
        )
    }
    return filtered
}

private func applyScenarioRuntimeConfig(
    _ runtimeConfig: SimulatorScenarioRuntimeConfig,
    to spec: SimulatorScenarioConfig
) -> SimulatorScenarioConfig {
    let overriddenBaseURL = runtimeConfig.baseURL ?? spec.baseURL

    let participantOverrides: [String: (handle: String?, deviceId: String?)] = [
        "a": (
            runtimeConfig.handleA,
            runtimeConfig.deviceIDA
        ),
        "b": (
            runtimeConfig.handleB,
            runtimeConfig.deviceIDB
        ),
    ]

    let overriddenParticipants = Dictionary(uniqueKeysWithValues: spec.participants.map { actor, participant in
        let overrides = participantOverrides[actor] ?? (nil, nil)
        return (
            actor,
            SimulatorScenarioParticipant(
                handle: overrides.handle ?? participant.handle,
                deviceId: overrides.deviceId ?? participant.deviceId
            )
        )
    })

    return SimulatorScenarioConfig(
        name: spec.name,
        baseURL: overriddenBaseURL,
        requiresLocalBackend: spec.requiresLocalBackend,
        participants: overriddenParticipants,
        steps: spec.steps
    )
}

private func runnableScenarioSpecs(
    _ specs: [SimulatorScenarioConfig],
    filter: [String]?,
    baseURLOverride: URL?
) throws -> [SimulatorScenarioConfig] {
    let requestedSpecs: [SimulatorScenarioConfig]
    if let filter, !filter.isEmpty {
        requestedSpecs = specs.filter { filter.contains($0.name) }
        guard !requestedSpecs.isEmpty else {
            throw ScenarioFailure(message: "No simulator scenarios matched filter \(filter.joined(separator: ","))")
        }
    } else {
        requestedSpecs = specs
    }

    var runnable: [SimulatorScenarioConfig] = []
    var localOnlyMismatches: [String] = []

    for spec in requestedSpecs {
        let effectiveBaseURL = baseURLOverride ?? spec.baseURL
        if spec.requiresLocalBackend == true && !scenarioBaseURLIsLocal(effectiveBaseURL) {
            localOnlyMismatches.append(spec.name)
            continue
        }
        runnable.append(spec)
    }

    if let filter, !filter.isEmpty, !localOnlyMismatches.isEmpty {
        throw ScenarioFailure(
            message: "Scenario(s) require a local backend: \(localOnlyMismatches.joined(separator: ", "))"
        )
    }

    return runnable
}

private func scenarioBaseURLIsLocal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

@MainActor
private func executeSimulatorScenario(_ spec: SimulatorScenarioConfig) async throws {
    for participant in spec.participants.values {
        try await resetAllDevelopmentState(baseURL: spec.baseURL, handle: participant.handle)
    }

    var viewModels = Dictionary(uniqueKeysWithValues: spec.participants.map { actor, participant in
        (
            actor,
            makeSimulatorScenarioViewModel(
                baseURL: spec.baseURL,
                handle: participant.handle,
                deviceID: participant.deviceId
            )
        )
    })

    func currentParticipants() -> [PTTViewModel] {
        Array(viewModels.values)
    }

    do {
        for participant in currentParticipants() {
            await participant.initializeIfNeeded()
        }
        try await stabilizeScenario(currentParticipants())
        try await waitForScenario(
            "participants become mutually discoverable",
            participants: currentParticipants(),
            timeoutNanoseconds: 60_000_000_000
        ) {
            await scenarioParticipantsAreDiscoverable(spec: spec, viewModels: viewModels)
        }

        for step in spec.steps {
            let scheduledActions = try scheduledScenarioActions(for: step.actions)
            var elapsedMilliseconds = 0

            for scheduledAction in scheduledActions {
                let delayBeforeDelivery = scheduledAction.scheduledDelayMilliseconds - elapsedMilliseconds
                if delayBeforeDelivery > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delayBeforeDelivery) * 1_000_000)
                    elapsedMilliseconds = scheduledAction.scheduledDelayMilliseconds
                }

                let action = scheduledAction.action
                guard let participant = viewModels[action.actor] else {
                    throw ScenarioFailure(message: "Scenario references unknown actor \(action.actor)")
                }

                switch action.type {
                case "openPeer":
                    guard let peerActor = action.peer,
                          let peer = spec.participants[peerActor] else {
                        throw ScenarioFailure(message: "openPeer requires a known peer actor")
                    }
                    await participant.openContact(reference: peer.handle)
                case "connect":
                    participant.joinChannel()
                case "disconnect":
                    participant.disconnect()
                case "declineRequest":
                    await participant.declineIncomingRequestForSelectedContact()
                case "cancelRequest":
                    await participant.cancelOutgoingRequestForSelectedContact()
                case "beginTransmit":
                    participant.beginTransmit()
                case "endTransmit":
                    participant.endTransmit()
                case "ensureDirectChannel":
                    guard let peerActor = action.peer,
                          let peer = spec.participants[peerActor],
                          let backend = participant.backendServices else {
                        throw ScenarioFailure(message: "ensureDirectChannel requires a known peer actor and backend")
                    }
                    let remoteUser = try await backend.resolveIdentity(reference: peer.handle)
                    _ = try await backend.directChannel(otherUserId: remoteUser.userId)
                    await participant.refreshContactSummaries()
                    if let selectedContactID = participant.selectedContact?.id {
                        await participant.refreshChannelState(for: selectedContactID)
                    }
                case "heartbeatPresence":
                    guard let backend = participant.backendServices else {
                        throw ScenarioFailure(message: "heartbeatPresence requires an initialized backend")
                    }
                    _ = try await backend.heartbeatPresence()
                case "refreshContactSummaries":
                    await participant.refreshContactSummaries()
                case "refreshInvites":
                    await participant.refreshInvites()
                case "refreshChannelState":
                    guard let selectedContactID = participant.selectedContact?.id else {
                        throw ScenarioFailure(message: "refreshChannelState requires a selected contact")
                    }
                    await participant.refreshChannelState(for: selectedContactID)
                case "resetTransportFaults":
                    participant.resetTransportFaults()
                case "setHTTPDelay":
                    guard let routeText = action.route,
                          let route = TransportFaultHTTPRoute(rawValue: routeText) else {
                        throw ScenarioFailure(message: "setHTTPDelay requires a known route")
                    }
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(message: "setHTTPDelay requires a non-negative milliseconds value")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "setHTTPDelay requires count >= 1")
                    }
                    participant.setHTTPTransportDelay(route: route, milliseconds: milliseconds, count: count)
                case "setWebSocketSignalDelay":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "setWebSocketSignalDelay requires a known signalKind")
                    }
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(
                            message: "setWebSocketSignalDelay requires a non-negative milliseconds value"
                        )
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "setWebSocketSignalDelay requires count >= 1")
                    }
                    participant.setIncomingWebSocketSignalDelay(
                        kind: signalKind,
                        milliseconds: milliseconds,
                        count: count
                    )
                case "dropNextWebSocketSignals":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "dropNextWebSocketSignals requires a known signalKind")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "dropNextWebSocketSignals requires count >= 1")
                    }
                    participant.dropNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "duplicateNextWebSocketSignals":
                    guard let signalKindText = action.signalKind,
                          let signalKind = TurboSignalKind(rawValue: signalKindText) else {
                        throw ScenarioFailure(message: "duplicateNextWebSocketSignals requires a known signalKind")
                    }
                    let count = action.count ?? 1
                    guard count >= 1 else {
                        throw ScenarioFailure(message: "duplicateNextWebSocketSignals requires count >= 1")
                    }
                    participant.duplicateNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "reorderNextWebSocketSignals":
                    let signalKind: TurboSignalKind?
                    if let signalKindText = action.signalKind {
                        guard let parsedKind = TurboSignalKind(rawValue: signalKindText) else {
                            throw ScenarioFailure(message: "reorderNextWebSocketSignals requires a known signalKind")
                        }
                        signalKind = parsedKind
                    } else {
                        signalKind = nil
                    }
                    let count = action.count ?? 2
                    guard count >= 2 else {
                        throw ScenarioFailure(message: "reorderNextWebSocketSignals requires count >= 2")
                    }
                    participant.reorderNextIncomingWebSocketSignals(kind: signalKind, count: count)
                case "disconnectWebSocket":
                    participant.disconnectBackendWebSocket()
                case "reconnectWebSocket":
                    guard let backend = participant.backendServices, backend.supportsWebSocket else {
                        throw ScenarioFailure(message: "reconnectWebSocket requires an initialized websocket backend")
                    }
                    backend.resumeWebSocket()
                    try await backend.waitForWebSocketConnection()
                case "backgroundApp":
                    participant.applicationStateOverride = .background
                    await participant.suspendForegroundMediaForBackgroundTransition(
                        reason: "scenario-background",
                        applicationState: .background
                    )
                    await participant.handleApplicationDidEnterBackground()
                case "foregroundApp":
                    participant.applicationStateOverride = .active
                    await participant.handleApplicationDidBecomeActive()
                case "reconnectBackend":
                    await participant.reconnectBackendControlPlane()
                case "reconcileSelectedSession":
                    await participant.reconcileSelectedSessionIfNeeded()
                case "restartApp":
                    guard let scenarioParticipant = spec.participants[action.actor] else {
                        throw ScenarioFailure(message: "restartApp requires a known participant")
                    }
                    participant.resetLocalDevState(backendStatus: "Scenario restart")
                    let replacement = makeSimulatorScenarioViewModel(
                        baseURL: spec.baseURL,
                        handle: scenarioParticipant.handle,
                        deviceID: scenarioParticipant.deviceId
                    )
                    viewModels[action.actor] = replacement
                    await replacement.initializeIfNeeded()
                    try await stabilizeScenario(currentParticipants())
                    try await waitForScenario(
                        "\(action.actor) restarts and becomes discoverable",
                        participants: currentParticipants(),
                        timeoutNanoseconds: 60_000_000_000
                    ) {
                        await scenarioParticipantsAreDiscoverable(spec: spec, viewModels: viewModels)
                    }
                case "wait":
                    let milliseconds = action.milliseconds ?? 0
                    guard milliseconds >= 0 else {
                        throw ScenarioFailure(message: "wait requires a non-negative milliseconds value")
                    }
                    try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                default:
                    throw ScenarioFailure(message: "Unknown scenario action type \(action.type)")
                }
            }

            if scenarioStepRequiresImmediateStabilization(step) {
                try await stabilizeScenario(currentParticipants())
            }

            if let expectations = step.expectEventually {
                try await waitForScenario(step.description, participants: currentParticipants()) {
                    scenarioExpectationsMatch(expectations, viewModels: viewModels)
                }
            }
        }

        try await publishScenarioDiagnosticsArtifacts(spec: spec, viewModels: viewModels)
        await tearDownSimulatorScenarioParticipants(currentParticipants())
    } catch {
        try? await publishScenarioDiagnosticsArtifacts(spec: spec, viewModels: viewModels)
        await tearDownSimulatorScenarioParticipants(currentParticipants())
        throw error
    }
}

private func scheduledScenarioActions(
    for actions: [SimulatorScenarioAction]
) throws -> [ScheduledSimulatorScenarioAction] {
    var scheduled: [ScheduledSimulatorScenarioAction] = []

    for (declarationIndex, action) in actions.enumerated() {
        let isDropped = action.drop ?? false
        if isDropped {
            continue
        }

        let initialDelayMilliseconds = action.delayMilliseconds ?? 0
        guard initialDelayMilliseconds >= 0 else {
            throw ScenarioFailure(message: "Scenario action \(action.type) requires a non-negative delayMilliseconds value")
        }

        let repeatCount = action.repeatCount ?? 1
        guard repeatCount >= 1 else {
            throw ScenarioFailure(message: "Scenario action \(action.type) requires repeatCount >= 1")
        }

        let repeatIntervalMilliseconds = action.repeatIntervalMilliseconds ?? 0
        guard repeatIntervalMilliseconds >= 0 else {
            throw ScenarioFailure(
                message: "Scenario action \(action.type) requires a non-negative repeatIntervalMilliseconds value"
            )
        }

        for deliveryIndex in 0..<repeatCount {
            scheduled.append(
                ScheduledSimulatorScenarioAction(
                    actor: action.actor,
                    action: action,
                    scheduledDelayMilliseconds: initialDelayMilliseconds + (deliveryIndex * repeatIntervalMilliseconds),
                    declarationIndex: declarationIndex,
                    deliveryIndex: deliveryIndex
                )
            )
        }
    }

    return scheduled.sorted { lhs, rhs in
        if lhs.scheduledDelayMilliseconds != rhs.scheduledDelayMilliseconds {
            return lhs.scheduledDelayMilliseconds < rhs.scheduledDelayMilliseconds
        }
        if lhs.declarationIndex != rhs.declarationIndex {
            let lhsOrder = lhs.action.reorderIndex ?? lhs.declarationIndex
            let rhsOrder = rhs.action.reorderIndex ?? rhs.declarationIndex
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.declarationIndex < rhs.declarationIndex
        }
        return lhs.deliveryIndex < rhs.deliveryIndex
    }
}

private func scenarioStepRequiresImmediateStabilization(_ step: SimulatorScenarioStep) -> Bool {
    !step.actions.contains { action in
        action.type == "beginTransmit" || action.type == "endTransmit"
    }
}

@MainActor
private func publishScenarioDiagnosticsArtifacts(
    spec: SimulatorScenarioConfig,
    viewModels: [String: PTTViewModel]
) async throws {
    let scenarioRunID = UUID().uuidString.lowercased()
    for (actor, participant) in viewModels {
        let expectedDeviceID = spec.participants[actor]?.deviceId ?? "<missing>"
        let expectedHandle = spec.participants[actor]?.handle ?? participant.currentDevUserHandle
        let artifact = SimulatorScenarioDiagnosticsArtifact(
            scenarioName: spec.name,
            handle: expectedHandle,
            deviceId: expectedDeviceID,
            baseURL: spec.baseURL.absoluteString,
            selectedHandle: participant.selectedContact?.handle,
            appVersion: "scenario:\(spec.name):\(scenarioRunID):\(expectedDeviceID)",
            snapshot: participant.diagnosticsSnapshot,
            transcript: participant.diagnosticsTranscript
        )
        try await publishScenarioDiagnosticsArtifact(artifact)
        try await verifyScenarioDiagnosticsArtifactPublished(
            baseURL: spec.baseURL,
            handle: artifact.handle,
            deviceID: artifact.deviceId,
            expectedAppVersion: artifact.appVersion
        )
    }
}

@MainActor
private func scenarioParticipantsAreDiscoverable(
    spec: SimulatorScenarioConfig,
    viewModels: [String: PTTViewModel]
) async -> Bool {
    for (actor, participant) in viewModels {
        guard let backend = participant.backendServices else { return false }
        for (peerActor, peer) in spec.participants where peerActor != actor {
            do {
                _ = try await backend.resolveIdentity(reference: peer.handle)
            } catch {
                return false
            }
        }
    }
    return true
}

@MainActor
private func tearDownSimulatorScenarioParticipants(_ participants: [PTTViewModel]) async {
    for participant in participants {
        participant.resetLocalDevState(backendStatus: "Scenario teardown")
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
}

@MainActor
private func scenarioExpectationsMatch(
    _ expectations: [String: SimulatorScenarioExpectation],
    viewModels: [String: PTTViewModel]
) -> Bool {
    for (actor, expected) in expectations {
        guard let participant = viewModels[actor] else { return false }
        let projection = participant.stateMachineProjection

        if let selected = expected.selectedExpectation,
           !scenarioSelectedExpectationMatches(selected, projection: projection)
        {
            return false
        }

        if let contacts = expected.contacts,
           !scenarioContactExpectationsMatch(contacts, projection: projection)
        {
            return false
        }

        if let backend = expected.backend,
           !scenarioBackendExpectationMatches(backend, projection: projection)
        {
            return false
        }
    }

    return true
}

private func scenarioSelectedExpectationMatches(
    _ expected: SimulatorScenarioSelectedExpectation,
    projection: StateMachineProjection
) -> Bool {
    let selected = projection.selectedSession

    if let handle = expected.handle,
       selected.selectedHandle != handle {
        return false
    }

    var phaseMatch: SimulatorScenarioPhaseMatch = .exact
    if let phase = expected.phase {
        guard let matched = simulatorScenarioPhaseMatch(expected: phase, actual: selected.selectedPhase) else {
            return false
        }
        phaseMatch = matched
    }

    if let status = expected.status,
       selected.statusMessage != status {
        return false
    }

    if let isJoined = expected.isJoined,
       !(phaseMatch == .progressed && isJoined == false) && selected.isJoined != isJoined {
        return false
    }

    if let isTransmitting = expected.isTransmitting,
       !(phaseMatch == .progressed && isTransmitting == false) && selected.isTransmitting != isTransmitting {
        return false
    }

    if let canTransmitNow = expected.canTransmitNow,
       !(phaseMatch == .progressed && canTransmitNow == false) && selected.canTransmitNow != canTransmitNow {
        return false
    }
    if let pttTokenRegistrationKind = expected.pttTokenRegistrationKind,
       selected.pttTokenRegistrationKind != pttTokenRegistrationKind {
        return false
    }

    return true
}

private func scenarioContactExpectationsMatch(
    _ expectedContacts: [SimulatorScenarioContactExpectation],
    projection: StateMachineProjection
) -> Bool {
    for expected in expectedContacts {
        guard let contact = projection.contact(handle: expected.handle) else {
            return false
        }

        if let isOnline = expected.isOnline,
           contact.isOnline != isOnline {
            return false
        }
        if let listState = expected.listState,
           contact.listState != listState {
            return false
        }
        if let badgeStatus = expected.badgeStatus,
           contact.badgeStatus != badgeStatus {
            return false
        }
        if let requestRelationship = expected.requestRelationship,
           contact.requestRelationship != requestRelationship {
            return false
        }
        if let hasIncomingRequest = expected.hasIncomingRequest,
           contact.hasIncomingRequest != hasIncomingRequest {
            return false
        }
        if let hasOutgoingRequest = expected.hasOutgoingRequest,
           contact.hasOutgoingRequest != hasOutgoingRequest {
            return false
        }
        if let requestCount = expected.requestCount,
           contact.requestCount != requestCount {
            return false
        }
    }

    return true
}

private func scenarioBackendExpectationMatches(
    _ expected: SimulatorScenarioBackendExpectation,
    projection: StateMachineProjection
) -> Bool {
    let selected = projection.selectedSession

    if let channelStatus = expected.channelStatus,
       selected.backendChannelStatus != channelStatus {
        return false
    }
    if let readiness = expected.readiness,
       selected.backendReadiness != readiness {
        return false
    }
    if let remoteAudioReadiness = expected.remoteAudioReadiness,
       selected.remoteAudioReadiness != remoteAudioReadiness {
        return false
    }
    if let remoteWakeCapabilityKind = expected.remoteWakeCapabilityKind,
       selected.remoteWakeCapabilityKind != remoteWakeCapabilityKind {
        return false
    }
    if let membership = expected.membership,
       selected.backendMembership != membership {
        return false
    }
    if let requestRelationship = expected.requestRelationship,
       selected.backendRequestRelationship != requestRelationship {
        return false
    }
    if let selfJoined = expected.selfJoined,
       selected.backendSelfJoined != selfJoined {
        return false
    }
    if let peerJoined = expected.peerJoined,
       selected.backendPeerJoined != peerJoined {
        return false
    }
    if let peerDeviceConnected = expected.peerDeviceConnected,
       selected.backendPeerDeviceConnected != peerDeviceConnected {
        return false
    }
    if let canTransmit = expected.canTransmit,
       selected.backendCanTransmit != canTransmit {
        return false
    }
    if let webSocketConnected = expected.webSocketConnected,
       projection.isWebSocketConnected != webSocketConnected {
        return false
    }

    return true
}

private func simulatorScenarioPhaseMatch<Phase: CustomStringConvertible>(
    expected expectedPhase: String,
    actual actualPhase: Phase
) -> SimulatorScenarioPhaseMatch? {
    let actual = String(describing: actualPhase)
    if actual == expectedPhase {
        return .exact
    }

    guard
        let expectedRank = simulatorScenarioTransientPhaseRank(expectedPhase),
        let actualRank = simulatorScenarioTransientPhaseRank(actual)
    else {
        return nil
    }

    return actualRank >= expectedRank ? .progressed : nil
}

private func simulatorScenarioTransientPhaseRank(_ phase: String) -> Int? {
    switch phase {
    case "requested", "incomingRequest":
        return 0
    case "peerReady", "waitingForPeer":
        return 1
    case "ready":
        return 2
    default:
        return nil
    }
}

private enum DevelopmentResetEndpoint {
    case resetAll
    case resetState

    var path: String {
        switch self {
        case .resetAll:
            return "/v1/dev/reset-all"
        case .resetState:
            return "/v1/dev/reset-state"
        }
    }

    var label: String {
        switch self {
        case .resetAll:
            return "reset-all"
        case .resetState:
            return "reset-state"
        }
    }
}

private func resetAllDevelopmentState(baseURL: URL, handle: String) async throws {
    if shouldUseResetStateOnly(baseURL: baseURL) {
        try await performDevelopmentReset(
            endpoint: .resetState,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 3
        )
        return
    }

    do {
        try await performDevelopmentReset(
            endpoint: .resetAll,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 2
        )
    } catch let error as ScenarioFailure {
        let message = error.message.lowercased()
        let shouldFallbackToResetState =
            message.contains("reset-all")
            && (message.contains("failed") || message.contains("timed out"))
        guard shouldFallbackToResetState else { throw error }

        try await performDevelopmentReset(
            endpoint: .resetState,
            baseURL: baseURL,
            handle: handle,
            maxAttempts: 5
        )
    }
}

private func shouldUseResetStateOnly(baseURL: URL) -> Bool {
    guard let host = baseURL.host?.lowercased() else { return false }
    return host != "localhost" && host != "127.0.0.1"
}

private func performDevelopmentReset(
    endpoint: DevelopmentResetEndpoint,
    baseURL: URL,
    handle: String,
    maxAttempts: Int
) async throws {
    let timeoutInterval: TimeInterval = switch endpoint {
    case .resetAll:
        8
    case .resetState:
        12
    }
    for attempt in 1...maxAttempts {
        let url = baseURL.appending(path: endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue(handle, forHTTPHeaderField: "x-turbo-user-handle")
        request.setValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ScenarioFailure(message: "\(endpoint.label) for \(handle) returned a non-HTTP response")
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return
            }

            let payload = String(data: data, encoding: .utf8) ?? "<empty>"
            let isRetriable = httpResponse.statusCode >= 500 && attempt < maxAttempts
            if isRetriable {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                continue
            }

            throw ScenarioFailure(message: "\(endpoint.label) for \(handle) failed: \(httpResponse.statusCode) \(payload)")
        } catch let scenarioFailure as ScenarioFailure {
            throw scenarioFailure
        } catch {
            let isFinalAttempt = attempt == maxAttempts
            if isFinalAttempt {
                throw ScenarioFailure(
                    message: "\(endpoint.label) for \(handle) failed after \(maxAttempts) attempts: \(error.localizedDescription)"
                )
            }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
        }
    }

    throw ScenarioFailure(message: "\(endpoint.label) for \(handle) failed after \(maxAttempts) attempts")
}

@MainActor
private func stabilizeScenario(_ participants: [PTTViewModel]) async throws {
    for participant in participants {
        await participant.refreshContactSummaries()
        await participant.refreshInvites()
        if let selectedContactID = participant.selectedContactId {
            await participant.refreshChannelState(for: selectedContactID)
        }
        participant.updateStatusForSelectedContact()
    }
    try await Task.sleep(nanoseconds: 300_000_000)
}

@MainActor
private func requireSelectedContactID(in viewModel: PTTViewModel, expectedHandle: String) throws -> UUID {
    guard let selectedContact = viewModel.selectedContact else {
        throw ScenarioFailure(message: "Expected selected contact \(expectedHandle), but selection was empty")
    }
    guard selectedContact.handle == expectedHandle else {
        throw ScenarioFailure(
            message: "Expected selected contact \(expectedHandle), got \(selectedContact.handle)"
        )
    }
    return selectedContact.id
}

@MainActor
private func waitForScenario(
    _ description: String,
    participants: [PTTViewModel],
    timeoutNanoseconds: UInt64 = 30_000_000_000,
    pollNanoseconds: UInt64 = 500_000_000,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    let snapshotSummary = scenarioSnapshotSummary(participants)
    throw ScenarioFailure(
        message: "Timed out waiting for scenario step: \(description)\n\(snapshotSummary)"
    )
}

@MainActor
private func scenarioSnapshotSummary(_ participants: [PTTViewModel]) -> String {
    participants.map { participant in
        let projection = participant.stateMachineProjection
        let fields = [
            "devUserHandle=\(participant.currentDevUserHandle)",
            "selectedContact=\(projection.selectedSession.selectedHandle ?? "none")",
            "selectedPeerPhase=\(projection.selectedSession.selectedPhase)",
            "selectedPeerStatus=\(projection.selectedSession.statusMessage)",
            "pendingAction=\(String(describing: participant.sessionCoordinator.pendingAction))",
            "isJoined=\(projection.selectedSession.isJoined)",
            "isTransmitting=\(projection.selectedSession.isTransmitting)",
            "backendChannelStatus=\(projection.selectedSession.backendChannelStatus ?? "none")",
            "backendReadiness=\(projection.selectedSession.backendReadiness ?? "none")",
            "backendSelfJoined=\(projection.selectedSession.backendSelfJoined.map(String.init(describing:)) ?? "none")",
            "backendPeerJoined=\(projection.selectedSession.backendPeerJoined.map(String.init(describing:)) ?? "none")",
            "backendPeerDeviceConnected=\(projection.selectedSession.backendPeerDeviceConnected.map(String.init(describing:)) ?? "none")",
            "backendCanTransmit=\(projection.selectedSession.backendCanTransmit.map(String.init(describing:)) ?? "none")",
            "remoteAudioReadiness=\(projection.selectedSession.remoteAudioReadiness ?? "unknown")",
            "remoteWakeCapability=\(projection.selectedSession.remoteWakeCapability ?? "unavailable")",
            "systemSession=\(String(describing: participant.systemSessionState))",
            "localJoinFailure=\(participant.pttCoordinator.state.lastJoinFailure.map { String(describing: $0) } ?? "none")",
        ]
        let contactDetails = projection.contacts.map { contact in
            "contact[\(contact.handle)]={online:\(contact.isOnline),list:\(contact.listState),section:\(contact.listSection),presence:\(contact.presencePill),badge:\(contact.badgeStatus ?? "none")}"
        }
        return (fields + contactDetails).joined(separator: " ")
    }
    .joined(separator: "\n")
}

private func publishScenarioDiagnosticsArtifact(_ artifact: SimulatorScenarioDiagnosticsArtifact) async throws {
    guard let baseURL = URL(string: artifact.baseURL) else {
        throw ScenarioFailure(message: "Invalid base URL for scenario diagnostics upload: \(artifact.baseURL)")
    }
    let endpointURL = baseURL.appending(path: "/v1/dev/diagnostics")
    let requestPayload: [String: Any?] = [
        "deviceId": artifact.deviceId,
        "appVersion": artifact.appVersion,
        "backendBaseURL": artifact.baseURL,
        "selectedHandle": artifact.selectedHandle,
        "snapshot": artifact.snapshot,
        "transcript": artifact.transcript,
    ]
    let body = try JSONSerialization.data(withJSONObject: requestPayload.compactMapValues { $0 })
    var request = URLRequest(url: endpointURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(artifact.handle, forHTTPHeaderField: "x-turbo-user-handle")
    request.setValue("Bearer \(artifact.handle)", forHTTPHeaderField: "Authorization")
    request.httpBody = body

    let (data, _) = try await performScenarioDiagnosticsRequest(
        request,
        label: "upload",
        handle: artifact.handle,
        deviceID: artifact.deviceId
    )
    let responsePayload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let report = responsePayload?["report"] as? [String: Any]
    let reportedDeviceID = report?["deviceId"] as? String
    let reportedAppVersion = report?["appVersion"] as? String
    guard reportedDeviceID == artifact.deviceId,
          reportedAppVersion == artifact.appVersion else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw ScenarioFailure(
            message: "Scenario diagnostics upload returned unexpected report for \(artifact.handle) expected device \(artifact.deviceId) appVersion \(artifact.appVersion) got device \(reportedDeviceID ?? "none") appVersion \(reportedAppVersion ?? "none"): \(body)"
        )
    }
}

private func verifyScenarioDiagnosticsArtifactPublished(
    baseURL: URL,
    handle: String,
    deviceID: String,
    expectedAppVersion: String,
    maxAttempts: Int = 10
) async throws {
    let endpointURL = baseURL.appending(path: "/v1/dev/diagnostics/latest/\(deviceID)/")
    for attempt in 1...maxAttempts {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue(handle, forHTTPHeaderField: "x-turbo-user-handle")
        request.setValue("Bearer \(handle)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await performScenarioDiagnosticsRequest(
            request,
            label: "verification",
            handle: handle,
            deviceID: deviceID
        )
        let responsePayload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let report = responsePayload?["report"] as? [String: Any]
        let reportedDeviceID = report?["deviceId"] as? String
        let reportedAppVersion = report?["appVersion"] as? String
        if reportedDeviceID == deviceID,
           reportedAppVersion == expectedAppVersion {
            return
        }
        if attempt < maxAttempts {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            continue
        }

        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw ScenarioFailure(
            message: "Scenario diagnostics verification returned unexpected report for \(handle) expected device \(deviceID) appVersion \(expectedAppVersion) got device \(reportedDeviceID ?? "none") appVersion \(reportedAppVersion ?? "none"): \(body)"
        )
    }

    throw ScenarioFailure(
        message: "Scenario diagnostics verification failed for \(handle) \(deviceID) after \(maxAttempts) attempts"
    )
}

private func performScenarioDiagnosticsRequest(
    _ request: URLRequest,
    label: String,
    handle: String,
    deviceID: String,
    maxAttempts: Int = 3
) async throws -> (Data, HTTPURLResponse) {
    for attempt in 1...maxAttempts {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ScenarioFailure(
                    message: "Scenario diagnostics \(label) returned a non-HTTP response for \(handle) \(deviceID)"
                )
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return (data, httpResponse)
            }

            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            let isRetriable = httpResponse.statusCode >= 500 && attempt < maxAttempts
            if isRetriable {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
                continue
            }
            throw ScenarioFailure(
                message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID): \(httpResponse.statusCode) \(body)"
            )
        } catch let scenarioFailure as ScenarioFailure {
            throw scenarioFailure
        } catch {
            if attempt == maxAttempts {
                throw ScenarioFailure(
                    message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID) after \(maxAttempts) attempts: \(error.localizedDescription)"
                )
            }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
        }
    }

    throw ScenarioFailure(
        message: "Scenario diagnostics \(label) failed for \(handle) \(deviceID) after \(maxAttempts) attempts"
    )
}

private func makeChannelState(
    status: ConversationState,
    canTransmit: Bool,
    selfJoined: Bool = true,
    peerJoined: Bool = true,
    peerDeviceConnected: Bool = true,
    hasIncomingRequest: Bool = false,
    hasOutgoingRequest: Bool = false
) -> TurboChannelStateResponse {
    TurboChannelStateResponse(
        channelId: "channel",
        selfUserId: "self",
        peerUserId: "peer",
        peerHandle: "@peer",
        selfOnline: true,
        peerOnline: true,
        selfJoined: selfJoined,
        peerJoined: peerJoined,
        peerDeviceConnected: peerDeviceConnected,
        hasIncomingRequest: hasIncomingRequest,
        hasOutgoingRequest: hasOutgoingRequest,
        requestCount: 0,
        activeTransmitterUserId: nil,
        transmitLeaseExpiresAt: nil,
        status: status.rawValue,
        canTransmit: canTransmit
    )
}

private func makeChannelReadiness(
    status: TurboChannelReadinessStatus,
    selfHasActiveDevice: Bool = true,
    peerHasActiveDevice: Bool = true,
    localAudioReadiness: RemoteAudioReadinessState? = nil,
    remoteAudioReadiness: RemoteAudioReadinessState? = nil,
    localWakeCapability: RemoteWakeCapabilityState = .unavailable,
    remoteWakeCapability: RemoteWakeCapabilityState = .unavailable,
    peerDirectQuicIdentity: TurboDirectQuicPeerIdentityPayload? = nil
) -> TurboChannelReadinessResponse {
    let resolvedLocalAudioReadiness = localAudioReadiness ?? (selfHasActiveDevice ? .ready : .unknown)
    let resolvedRemoteAudioReadiness = remoteAudioReadiness ?? (peerHasActiveDevice ? .ready : .unknown)
    return TurboChannelReadinessResponse(
        channelId: "channel",
        peerUserId: "peer",
        selfHasActiveDevice: selfHasActiveDevice,
        peerHasActiveDevice: peerHasActiveDevice,
        activeTransmitterUserId: status.activeTransmitterUserId,
        activeTransmitExpiresAt: nil,
        status: status.kind,
        audioReadinessPayload: TurboChannelAudioReadinessPayload(
            selfReadiness: TurboAudioReadinessStatusPayload(kind: {
                switch resolvedLocalAudioReadiness {
                case .unknown:
                    return "unknown"
                case .waiting:
                    return "waiting"
                case .wakeCapable:
                    return "wake-capable"
                case .ready:
                    return "ready"
                }
            }()),
            peerReadiness: TurboAudioReadinessStatusPayload(kind: {
                switch resolvedRemoteAudioReadiness {
                case .unknown:
                    return "unknown"
                case .waiting:
                    return "waiting"
                case .wakeCapable:
                    return "wake-capable"
                case .ready:
                    return "ready"
                }
            }()),
            peerTargetDeviceId: peerHasActiveDevice ? "peer-device" : nil
        ),
        wakeReadinessPayload: TurboChannelWakeReadinessPayload(
            selfWakeCapability: TurboWakeCapabilityStatusPayload(
                kind: {
                    switch localWakeCapability {
                    case .unavailable:
                        return "unavailable"
                    case .wakeCapable:
                        return "wake-capable"
                    }
                }(),
                targetDeviceId: {
                    switch localWakeCapability {
                    case .unavailable:
                        return nil
                    case .wakeCapable(let targetDeviceId):
                        return targetDeviceId
                    }
                }()
            ),
            peerWakeCapability: TurboWakeCapabilityStatusPayload(
                kind: {
                    switch remoteWakeCapability {
                    case .unavailable:
                        return "unavailable"
                    case .wakeCapable:
                        return "wake-capable"
                    }
                }(),
                targetDeviceId: {
                    switch remoteWakeCapability {
                    case .unavailable:
                        return nil
                    case .wakeCapable(let targetDeviceId):
                        return targetDeviceId
                    }
                }()
            )
        ),
        peerDirectQuicIdentity: peerDirectQuicIdentity
    )
}

private func reduceSelectedPeerState(_ events: [SelectedPeerEvent]) -> SelectedPeerSessionState {
    events.reduce(.initial) { state, event in
        SelectedPeerReducer.reduce(state: state, event: event).state
    }
}

@MainActor
private final class BackgroundTransitionProbe {
    private(set) var events: [String] = []
    private(set) var backgroundStarted = false
    private(set) var backgroundTaskStarted = false
    private(set) var backgroundTaskEnded = false
    private(set) var offlineStarted = false
    private(set) var suspendCount = 0

    func recordSuspend() {
        suspendCount += 1
        events.append("suspend")
    }

    func recordBackgroundTaskBegin(_ name: String) {
        backgroundTaskStarted = true
        events.append("background-task-begin:\(name)")
    }

    func recordBackgroundTaskEnd() {
        backgroundTaskEnded = true
        events.append("background-task-end")
    }

    func recordBackgroundStart() {
        backgroundStarted = true
        events.append("background-start")
    }

    func recordBackgroundFinish() {
        events.append("background-finish")
    }

    func recordOfflineStart() {
        offlineStarted = true
        events.append("offline-start")
    }

    func recordOfflineFinish() {
        events.append("offline-finish")
    }
}

private func makeTransmitRequest() -> TransmitRequestContext {
    TransmitRequestContext(
        contactID: UUID(),
        contactHandle: "@avery",
        backendChannelID: "channel-1",
        remoteUserID: "user-peer",
        channelUUID: UUID(),
        usesLocalHTTPBackend: false,
        backendSupportsWebSocket: true
    )
}

private func makeContactSummary(
    channelId: String?,
    handle: String = "@avery",
    displayName: String = "Avery",
    isOnline: Bool = true,
    hasIncomingRequest: Bool = false,
    hasOutgoingRequest: Bool = false,
    requestCount: Int = 0,
    isActiveConversation: Bool = false,
    badgeStatus: String = "online",
    membershipKind: String? = nil,
    peerDeviceConnected: Bool? = nil
) -> TurboContactSummaryResponse {
    TurboContactSummaryResponse(
        userId: "user-peer",
        handle: handle,
        displayName: displayName,
        channelId: channelId,
        isOnline: isOnline,
        hasIncomingRequest: hasIncomingRequest,
        hasOutgoingRequest: hasOutgoingRequest,
        requestCount: requestCount,
        isActiveConversation: isActiveConversation,
        badgeStatus: badgeStatus,
        membershipPayload: membershipKind.map {
            TurboChannelMembershipPayload(kind: $0, peerDeviceConnected: peerDeviceConnected)
        }
    )
}

private func makeInvite(
    direction: String,
    inviteId: String = UUID().uuidString,
    fromHandle: String = "@self",
    toHandle: String = "@avery",
    requestCount: Int = 1,
    createdAt: String = "2026-04-08T00:00:00Z",
    updatedAt: String? = nil
) -> TurboInviteResponse {
    TurboInviteResponse(
        inviteId: inviteId,
        fromUserId: "user-self",
        fromHandle: fromHandle,
        toUserId: "user-peer",
        toHandle: toHandle,
        channelId: "channel-1",
        status: "pending",
        direction: direction,
        requestCount: requestCount,
        createdAt: createdAt,
        updatedAt: updatedAt,
        targetAvailability: nil,
        shouldAutoJoinPeer: nil,
        accepted: nil,
        pendingJoin: nil
    )
}

private func makeUnreachableBackendConfig() -> TurboBackendConfig {
    TurboBackendConfig(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        devUserHandle: "@self",
        deviceID: "test-device"
    )
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian, Array.init)
    }
}
