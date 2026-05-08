import CryptoKit
import Darwin
import Foundation
import Network
import Security

nonisolated enum DirectQuicAttemptRole: String, Equatable {
    case listenerOfferer
    case dialerAnswerer

    static func resolve(localDeviceID: String, peerDeviceID: String) -> DirectQuicAttemptRole {
        localDeviceID.localizedStandardCompare(peerDeviceID) == .orderedAscending
            ? .listenerOfferer
            : .dialerAnswerer
    }
}

nonisolated enum DirectQuicIdentityConfiguration {
    static let storageKey = "TurboDirectQuicIdentityLabel"
    static let launchArgument = "-TurboDirectQuicIdentityLabel"
    static let environmentKey = "TURBO_DIRECT_QUIC_IDENTITY_LABEL"
    static let infoPlistKey = "TurboDirectQuicIdentityLabel"
    static let selectedFingerprintStorageKey = "TurboDirectQuicInstalledIdentityFingerprint"

    static func preferredLabel(
        deviceID: String?,
        fallbackHandle: String
    ) -> String {
        let rawSuffix = deviceID ?? fallbackHandle
        let sanitizedSuffix = rawSuffix
            .lowercased()
            .map { character -> Character in
                switch character {
                case "a"..."z", "0"..."9", "-", "_":
                    return character
                default:
                    return "-"
                }
            }
        let collapsedSuffix = String(sanitizedSuffix)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let suffix = collapsedSuffix.isEmpty ? "default" : collapsedSuffix
        return "turbo.direct-quic.identity.\(suffix)"
    }

    static func resolvedLabel(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> String? {
        resolvedLabel(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            defaults: defaults,
            bundleInfo: bundle.infoDictionary
        )
    }

    static func resolvedLabel(
        arguments: [String],
        environment: [String: String],
        defaults: UserDefaults = .standard,
        bundleInfo: [String: Any]?
    ) -> String? {
        if let launchValue = launchArgumentValue(arguments), !launchValue.isEmpty {
            return launchValue
        }
        if let environmentValue = environment[environmentKey], !environmentValue.isEmpty {
            return environmentValue
        }
        if let storedValue = defaults.string(forKey: storageKey), !storedValue.isEmpty {
            return storedValue
        }
        if let infoValue = bundleInfo?[infoPlistKey] as? String, !infoValue.isEmpty {
            return infoValue
        }
        return nil
    }

    static func setResolvedLabel(_ label: String?, defaults: UserDefaults = .standard) {
        defaults.set(label, forKey: storageKey)
    }

    static func setSelectedInstalledIdentityFingerprint(
        _ fingerprint: String?,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(fingerprint, forKey: selectedFingerprintStorageKey)
    }

    static func selectedInstalledIdentityFingerprint(
        defaults: UserDefaults = .standard
    ) -> String? {
        defaults.string(forKey: selectedFingerprintStorageKey)
    }

    static func status(
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> DirectQuicIdentityStatus {
        guard let label = resolvedLabel(
            processInfo: processInfo,
            defaults: defaults,
            bundle: bundle
        ), !label.isEmpty else {
            return .missingLabel
        }
        if let productionIdentity = DirectQuicProductionIdentityManager.existingIdentity(label: label) {
            return .readyProduction(label, productionIdentity.certificateFingerprint)
        }
        if let debugIdentity = loadIdentityIfPresent(label: label),
           let fingerprint = try? Self.fingerprint(for: debugIdentity) {
            return .readyDebug(label, fingerprint)
        }
        if let fingerprint = selectedInstalledIdentityFingerprint(defaults: defaults),
           loadInstalledIdentityMatchingFingerprint(fingerprint) != nil {
            return .readyInstalled(label, fingerprint)
        }
        return .missingIdentity(label)
    }

    static func provisionProductionIdentity(
        label: String,
        deviceID: String,
        defaults: UserDefaults = .standard
    ) throws -> DirectQuicResolvedIdentity {
        let identity = try DirectQuicProductionIdentityManager.provisionIdentity(
            label: label,
            deviceID: deviceID
        )
        setResolvedLabel(label, defaults: defaults)
        setSelectedInstalledIdentityFingerprint(nil, defaults: defaults)
        return identity
    }

    static func productionIdentityRegistrationMetadata(label: String) -> DirectQuicIdentityRegistrationMetadata? {
        guard let identity = DirectQuicProductionIdentityManager.existingIdentity(label: label) else {
            return nil
        }
        return DirectQuicIdentityRegistrationMetadata(
            fingerprint: identity.certificateFingerprint
        )
    }

    static func importPKCS12Identity(
        data: Data,
        password: String,
        label: String
    ) throws {
        let options = [kSecImportExportPassphrase as String: password] as NSDictionary
        var rawItems: CFArray?
        let importStatus = SecPKCS12Import(data as CFData, options, &rawItems)
        guard importStatus == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let importedValue = items.first?[kSecImportItemIdentity as String] else {
            throw DirectQuicIdentityImportError.pkcs12ImportFailed(importStatus)
        }
        let identity = importedValue as! SecIdentity

        let deleteQuery = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
        ] as CFDictionary
        let deleteStatus = SecItemDelete(deleteQuery)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw DirectQuicIdentityImportError.keychainDeleteFailed(deleteStatus)
        }

        let addQuery = [
            kSecValueRef: identity,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as NSDictionary
        let addStatus = SecItemAdd(addQuery, nil)
        guard addStatus == errSecSuccess
                || (addStatus == errSecDuplicateItem && loadIdentityIfPresent(label: label) != nil) else {
            throw DirectQuicIdentityImportError.keychainSaveFailed(addStatus)
        }
        setSelectedInstalledIdentityFingerprint(nil)
    }

    static func installedIdentityCount() -> Int {
        (try? installedIdentities().count) ?? 0
    }

    static func adoptInstalledIdentity(
        label: String,
        defaults: UserDefaults = .standard
    ) throws -> String {
        let identities = try installedIdentities()
        guard !identities.isEmpty else {
            throw DirectQuicInstalledIdentityAdoptionError.noInstalledIdentities
        }
        guard identities.count == 1 else {
            throw DirectQuicInstalledIdentityAdoptionError.multipleInstalledIdentities(identities.count)
        }
        let fingerprint = try Self.fingerprint(for: identities[0])
        setResolvedLabel(label, defaults: defaults)
        setSelectedInstalledIdentityFingerprint(fingerprint, defaults: defaults)
        return fingerprint
    }

    private static func launchArgumentValue(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static func loadIdentityIfPresent(label: String) -> SecIdentity? {
        var item: CFTypeRef?
        let identityQuery: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        let identity = item as! SecIdentity
        return identity
    }

    static func loadIdentity(label: String) throws -> SecIdentity {
        var item: CFTypeRef?
        let identityQuery: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &item)
        guard status == errSecSuccess, let item else {
            if status == errSecItemNotFound {
                throw DirectQuicProbeError.identityNotFound(label)
            }
            throw DirectQuicProbeError.identityLookupFailed(label, status)
        }
        return item as! SecIdentity
    }

    private static func installedIdentities() throws -> [SecIdentity] {
        var item: CFTypeRef?
        let identityQuery: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let item else {
            throw DirectQuicInstalledIdentityAdoptionError.keychainQueryFailed(status)
        }
        let array = item as! [Any]
        return array.map { $0 as! SecIdentity }
    }

    static func loadInstalledIdentityMatchingFingerprint(_ fingerprint: String) -> SecIdentity? {
        guard let identities = try? installedIdentities() else { return nil }
        return identities.first { identity in
            (try? Self.fingerprint(for: identity)) == fingerprint
        }
    }

    private static func fingerprint(for identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw DirectQuicProbeError.certificateMissing
        }
        return try fingerprint(for: certificate)
    }

    private static func fingerprint(for certificate: SecCertificate) throws -> String {
        let certificateData = SecCertificateCopyData(certificate) as Data
        guard !certificateData.isEmpty else {
            throw DirectQuicProbeError.fingerprintEncodingFailed
        }
        let digest = SHA256.hash(data: certificateData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}

nonisolated enum DirectQuicIdentityStatus: Equatable {
    case missingLabel
    case missingIdentity(String)
    case readyProduction(String, String)
    case readyDebug(String, String)
    case readyInstalled(String, String)

    var resolvedLabel: String? {
        switch self {
        case .missingLabel:
            return nil
        case .missingIdentity(let label),
             .readyProduction(let label, _),
             .readyDebug(let label, _),
             .readyInstalled(let label, _):
            return label
        }
    }

    var fingerprint: String? {
        switch self {
        case .missingLabel, .missingIdentity:
            return nil
        case .readyProduction(_, let fingerprint),
             .readyDebug(_, let fingerprint),
             .readyInstalled(_, let fingerprint):
            return fingerprint
        }
    }

    var source: DirectQuicIdentitySource {
        switch self {
        case .readyProduction:
            return .production
        case .readyDebug, .readyInstalled:
            return .debugP12
        case .missingLabel, .missingIdentity:
            return .missing
        }
    }

    var diagnosticsText: String {
        switch self {
        case .missingLabel:
            return "missing-label"
        case .missingIdentity(let label):
            return "missing-identity (\(label))"
        case .readyProduction(let label, _):
            return "ready-production (\(label))"
        case .readyDebug(let label, _):
            return "ready-debug-p12 (\(label))"
        case .readyInstalled(let label, _):
            return "ready-installed-debug-p12 (\(label))"
        }
    }
}

nonisolated enum DirectQuicIdentityImportError: Error, LocalizedError, Equatable {
    case pkcs12ImportFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case keychainSaveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .pkcs12ImportFailed(let status):
            return "Direct QUIC identity import failed: \(Self.describe(status))"
        case .keychainDeleteFailed(let status):
            return "Direct QUIC identity replacement failed: \(Self.describe(status))"
        case .keychainSaveFailed(let status):
            return "Direct QUIC identity save failed: \(Self.describe(status))"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "OSStatus \(status)"
    }
}

nonisolated enum DirectQuicInstalledIdentityAdoptionError: Error, LocalizedError, Equatable {
    case noInstalledIdentities
    case multipleInstalledIdentities(Int)
    case keychainQueryFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInstalledIdentities:
            return "No installed identities were found on this device"
        case .multipleInstalledIdentities(let count):
            return "Found \(count) installed identities; can’t auto-select one"
        case .keychainQueryFailed(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Installed identity lookup failed: \(message) (\(status))"
            }
            return "Installed identity lookup failed: OSStatus \(status)"
        }
    }
}

nonisolated enum DirectQuicProbeError: Error, LocalizedError, Equatable {
    case identityLabelMissing
    case identityNotFound(String)
    case identityLookupFailed(String, OSStatus)
    case certificateMissing
    case fingerprintEncodingFailed
    case listenerFailed(String)
    case listenerCancelled
    case noViableCandidate
    case localPortAllocationFailed(String)
    case connectionFailed(String)
    case proofFailed(String)

    var errorDescription: String? {
        switch self {
        case .identityLabelMissing:
            return "Direct QUIC identity label is not configured"
        case .identityNotFound(let label):
            return "Direct QUIC identity '\(label)' was not found in the Keychain"
        case .identityLookupFailed(let label, let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Direct QUIC identity '\(label)' lookup failed: \(message) (\(status))"
            }
            return "Direct QUIC identity '\(label)' lookup failed: OSStatus \(status)"
        case .certificateMissing:
            return "Direct QUIC identity is missing its certificate"
        case .fingerprintEncodingFailed:
            return "Direct QUIC certificate fingerprint could not be encoded"
        case .listenerFailed(let message):
            return "Direct QUIC listener failed: \(message)"
        case .listenerCancelled:
            return "Direct QUIC listener was cancelled"
        case .noViableCandidate:
            return "Direct QUIC offer contained no viable direct candidate"
        case .localPortAllocationFailed(let message):
            return "Direct QUIC local port allocation failed: \(message)"
        case .connectionFailed(let message):
            return "Direct QUIC connection failed: \(message)"
        case .proofFailed(let message):
            return "Direct QUIC proof failed: \(message)"
        }
    }
}

nonisolated struct DirectQuicPreparedLocalOffer: Equatable {
    let attemptId: String
    let quicAlpn: String
    let localPort: UInt16
    let certificateFingerprint: String
    let candidates: [TurboDirectQuicCandidate]
}

nonisolated struct DirectQuicPreparedDialerConnection: Equatable {
    let attemptId: String
    let certificateFingerprint: String
    let candidates: [TurboDirectQuicCandidate]
    let didEstablishPath: Bool
    let lastFailureReason: String?
}

nonisolated struct DirectQuicPreparedDialerAnswer: Equatable {
    let attemptId: String
    let certificateFingerprint: String
    let candidates: [TurboDirectQuicCandidate]
}

nonisolated private struct DirectQuicIdentityMaterial {
    let label: String
    let identity: SecIdentity
    let certificateFingerprint: String
    let source: DirectQuicIdentitySource
}

nonisolated private struct DirectQuicPreparedDialerAttempt: Equatable {
    let attemptId: String
    let quicAlpn: String
    let localPort: UInt16
    let candidates: [TurboDirectQuicCandidate]
}

nonisolated enum DirectQuicCandidateProbeDisposition: String, Equatable {
    case alreadyConnected
    case pathEstablished
    case noViableCandidates
    case noNewCandidates
    case probeAlreadyInFlight
    case batchExhausted
}

nonisolated struct DirectQuicCandidateProbeOutcome: Equatable {
    let disposition: DirectQuicCandidateProbeDisposition
    let inputCandidateCount: Int
    let viableCandidateCount: Int
    let newlyAttemptedCandidateCount: Int
    let lastErrorDescription: String?

    var didEstablishPath: Bool {
        switch disposition {
        case .alreadyConnected, .pathEstablished:
            return true
        case .noViableCandidates, .noNewCandidates, .probeAlreadyInFlight, .batchExhausted:
            return false
        }
    }
}

nonisolated enum DirectQuicCandidateProbeSelection: Equatable {
    case immediate(DirectQuicCandidateProbeOutcome)
    case ready([TurboDirectQuicCandidate], viableCandidateCount: Int)
}

nonisolated enum DirectQuicWireMessageKind: String, Codable, Equatable {
    case probeHello = "probe-hello"
    case probeAck = "probe-ack"
    case consentPing = "consent-ping"
    case consentAck = "consent-ack"
    case receiverPrewarmRequest = "receiver-prewarm-request"
    case receiverPrewarmAck = "receiver-prewarm-ack"
    case pathClosing = "path-closing"
    case warmPing = "warm-ping"
    case warmPong = "warm-pong"
    case audioChunk = "audio-chunk"
}

nonisolated struct DirectQuicReceiverPrewarmPayload: Codable, Equatable, Sendable {
    let requestId: String
    let channelId: String
    let fromDeviceId: String
    let reason: String
    let directQuicAttemptId: String?
}

nonisolated enum DirectQuicReceiverPrewarmPayloadCodec {
    static func encode(_ payload: DirectQuicReceiverPrewarmPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DirectQuicProbeError.proofFailed("receiver prewarm payload encoding failed")
        }
        return encoded
    }

    static func decode(_ payload: String?) throws -> DirectQuicReceiverPrewarmPayload {
        guard let payload, let data = payload.data(using: .utf8) else {
            throw DirectQuicProbeError.proofFailed("receiver prewarm payload missing")
        }
        return try JSONDecoder().decode(DirectQuicReceiverPrewarmPayload.self, from: data)
    }
}

nonisolated struct DirectQuicPathClosingPayload: Codable, Equatable, Sendable {
    let attemptId: String
    let reason: String
}

nonisolated enum DirectQuicPathClosingPayloadCodec {
    static func encode(_ payload: DirectQuicPathClosingPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DirectQuicProbeError.proofFailed("path closing payload encoding failed")
        }
        return encoded
    }

    static func decode(_ payload: String?) throws -> DirectQuicPathClosingPayload {
        guard let payload, let data = payload.data(using: .utf8) else {
            throw DirectQuicProbeError.proofFailed("path closing payload missing")
        }
        return try JSONDecoder().decode(DirectQuicPathClosingPayload.self, from: data)
    }
}

nonisolated struct DirectQuicWireMessage: Codable, Equatable {
    let kind: DirectQuicWireMessageKind
    let payload: String?

    static let probeHello = DirectQuicWireMessage(kind: .probeHello, payload: nil)
    static let probeAck = DirectQuicWireMessage(kind: .probeAck, payload: nil)
    static func consentPing(_ id: String) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .consentPing, payload: id)
    }

    static func consentAck(_ id: String?) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .consentAck, payload: id)
    }

    static func receiverPrewarmRequest(_ payload: DirectQuicReceiverPrewarmPayload) throws -> DirectQuicWireMessage {
        DirectQuicWireMessage(
            kind: .receiverPrewarmRequest,
            payload: try DirectQuicReceiverPrewarmPayloadCodec.encode(payload)
        )
    }

    static func receiverPrewarmAck(_ payload: DirectQuicReceiverPrewarmPayload) throws -> DirectQuicWireMessage {
        DirectQuicWireMessage(
            kind: .receiverPrewarmAck,
            payload: try DirectQuicReceiverPrewarmPayloadCodec.encode(payload)
        )
    }

    static func pathClosing(_ payload: DirectQuicPathClosingPayload) throws -> DirectQuicWireMessage {
        DirectQuicWireMessage(
            kind: .pathClosing,
            payload: try DirectQuicPathClosingPayloadCodec.encode(payload)
        )
    }

    static func warmPing(_ id: String) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .warmPing, payload: id)
    }

    static func warmPong(_ id: String?) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .warmPong, payload: id)
    }

    static func audioChunk(_ payload: String) -> DirectQuicWireMessage {
        DirectQuicWireMessage(kind: .audioChunk, payload: payload)
    }
}

nonisolated enum DirectQuicWireCodec {
    private static let newline = Data([0x0A])

    static func encode(_ message: DirectQuicWireMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(newline)
        return data
    }

    static func decodeAvailable(from buffer: inout Data) throws -> [DirectQuicWireMessage] {
        var decoded: [DirectQuicWireMessage] = []

        while let delimiterRange = buffer.firstRange(of: newline) {
            let frame = buffer.subdata(in: 0 ..< delimiterRange.lowerBound)
            buffer.removeSubrange(0 ..< delimiterRange.upperBound)
            guard !frame.isEmpty else { continue }
            decoded.append(try JSONDecoder().decode(DirectQuicWireMessage.self, from: frame))
        }

        return decoded
    }
}

nonisolated enum DirectQuicHostCandidateGatherer {
    static func gatherCandidates(
        port: UInt16,
        includeLoopbackFallback: Bool = true
    ) -> [TurboDirectQuicCandidate] {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            guard let address = interface.pointee.ifa_addr else { continue }

            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let host = String(cString: hostBuffer)
            guard !host.isEmpty else { continue }
            guard !host.hasPrefix("fe80:") else { continue }
            guard host != "::1" else { continue }
            if host == "127.0.0.1" && !includeLoopbackFallback {
                continue
            }
            addresses.append(host)
        }

        let nonLoopback = addresses.filter { $0 != "127.0.0.1" }
        let selectedAddresses = nonLoopback.isEmpty && includeLoopbackFallback ? addresses : nonLoopback

        return selectedAddresses.enumerated().map { index, host in
            let foundation = "host-\(index)"
            return TurboDirectQuicCandidate(
                foundation: foundation,
                component: "media",
                transport: "udp",
                priority: max(1_000_000 - index, 1),
                kind: .host,
                address: host,
                port: Int(port),
                relatedAddress: nil,
                relatedPort: nil
            )
        }
    }
}

nonisolated private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resume(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        operation()
    }
}

nonisolated final class DirectQuicSerialAsyncQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var tailTask: Task<Void, Never>?

    func reset() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            generation += 1
            let task = tailTask
            tailTask = nil
            return task
        }
        task?.cancel()
    }

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let task = lock.withLock { () -> Task<Void, Never> in
            let generation = self.generation
            let previousTask = tailTask
            let task = Task {
                await previousTask?.value
                guard !Task.isCancelled, self.isCurrentGeneration(generation) else { return }
                await operation()
            }
            tailTask = task
            return task
        }
        _ = task
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        lock.withLock { self.generation == generation }
    }
}

nonisolated final class DirectQuicProbeController: @unchecked Sendable {
    private static let consentIntervalNanoseconds: UInt64 = 1_000_000_000
    // Apple PTT activation can hold the first transmit/receive path for several
    // seconds. Keep the app-level consent watchdog longer than that activation
    // window so a warm Direct QUIC path is not torn down just before audio starts.
    private static let consentTimeoutSeconds: TimeInterval = 10

    private let queue = DispatchQueue(label: "Turbo.DirectQuicProbe")
    private let stateLock = NSLock()
    private let incomingAudioPayloadQueue = DirectQuicSerialAsyncQueue()
    private let reportEvent: (@Sendable (String, [String: String]) async -> Void)?

    private var listener: NWListener?
    private var inboundConnection: NWConnection?
    private var outboundConnection: NWConnection?
    private var activeMediaConnection: NWConnection?
    private var preparedOffer: DirectQuicPreparedLocalOffer?
    private var preparedDialerAttempt: DirectQuicPreparedDialerAttempt?
    private var activeReceiveBuffer = Data()
    private var verifiedPeerCertificateFingerprint: String?
    private var nominatedPath: DirectQuicNominatedPath?
    private var onIncomingAudioPayload: (@Sendable (String) async -> Void)?
    private var onReceiverPrewarmRequest: (@Sendable (DirectQuicReceiverPrewarmPayload) async -> Void)?
    private var onReceiverPrewarmAck: (@Sendable (DirectQuicReceiverPrewarmPayload) async -> Void)?
    private var onPathClosing: (@Sendable (DirectQuicPathClosingPayload) async -> Void)?
    private var onWarmPong: (@Sendable (String?) async -> Void)?
    private var onPathLost: (@Sendable (String) async -> Void)?
    private var suppressPathLostCallback = false
    private var remoteCandidateKeysAttempted: Set<String> = []
    private var remoteCandidateProbeInFlight = false
    private var consentTask: Task<Void, Never>?
    private var outstandingConsentID: String?
    private var outstandingConsentSentAt: Date?

    init(
        reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil
    ) {
        self.reportEvent = reportEvent
    }

    func prepareListenerOffer(
        attemptId: String,
        alpn: String = "turbo-ptt",
        stunServers: [TurboDirectQuicStunServer] = []
    ) async throws -> DirectQuicPreparedLocalOffer {
        let existingPreparedOffer: DirectQuicPreparedLocalOffer? = withLockedState { self.preparedOffer }
        if let existingPreparedOffer = existingPreparedOffer,
           existingPreparedOffer.attemptId == attemptId {
            return existingPreparedOffer
        }

        cancel(reason: "replacing-listener")

        let identityMaterial = try resolvedIdentityMaterial()
        let quicOptions = NWProtocolQUIC.Options(alpn: [alpn])
        sec_protocol_options_set_min_tls_protocol_version(
            quicOptions.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_peer_authentication_required(
            quicOptions.securityProtocolOptions,
            true
        )
        installPeerVerification(
            on: quicOptions.securityProtocolOptions,
            expectedPeerCertificateFingerprint: nil,
            role: "listener"
        )
        if let localIdentity = sec_identity_create(identityMaterial.identity) {
            sec_protocol_options_set_local_identity(
                quicOptions.securityProtocolOptions,
                localIdentity
            )
        }

        let parameters = NWParameters(quic: quicOptions)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: 0)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleInboundConnection(connection)
        }

        let port = try await startListener(listener)
        let candidates = await localCandidates(
            localPort: port,
            stunServers: stunServers
        )
        let preparedOffer = DirectQuicPreparedLocalOffer(
            attemptId: attemptId,
            quicAlpn: alpn,
            localPort: port,
            certificateFingerprint: identityMaterial.certificateFingerprint,
            candidates: candidates
        )

        withLockedState {
            self.listener = listener
            self.preparedOffer = preparedOffer
            self.verifiedPeerCertificateFingerprint = nil
            self.nominatedPath = nil
        }
        await report(
            "Prepared direct QUIC listener offer",
            metadata: [
                "attemptId": attemptId,
                "candidateCount": String(candidates.count),
                "port": String(port),
                "identityLabel": identityMaterial.label,
            ]
        )
        return preparedOffer
    }

    func connect(
        using offer: TurboDirectQuicOfferPayload,
        stunServers: [TurboDirectQuicStunServer] = []
    ) async throws -> DirectQuicPreparedDialerConnection {
        let viableCandidates = viableCandidates(from: offer.candidates)
        let identityMaterial = try resolvedIdentityMaterial()
        let localPort = try allocateLocalUDPPort()
        let localCandidates = await localCandidates(
            localPort: localPort,
            stunServers: stunServers
        )

        let previousOutboundConnection = withLockedState { () -> NWConnection? in
            let existing = outboundConnection
            outboundConnection = nil
            return existing
        }
        previousOutboundConnection?.cancel()
        withLockedState {
            preparedDialerAttempt = DirectQuicPreparedDialerAttempt(
                attemptId: offer.attemptId,
                quicAlpn: offer.quicAlpn,
                localPort: localPort,
                candidates: localCandidates
            )
            nominatedPath = nil
        }

        guard !viableCandidates.isEmpty else {
            await report(
                "Direct QUIC offer contained no viable initial candidate",
                metadata: [
                    "attemptId": offer.attemptId,
                    "localPort": String(localPort),
                    "localCandidateCount": String(localCandidates.count),
                ]
            )
            return DirectQuicPreparedDialerConnection(
                attemptId: offer.attemptId,
                certificateFingerprint: identityMaterial.certificateFingerprint,
                candidates: localCandidates,
                didEstablishPath: false,
                lastFailureReason: DirectQuicProbeError.noViableCandidate.localizedDescription
            )
        }

        var lastError: Error?
        for candidate in viableCandidates {
            let parameters = makeOutboundParameters(
                quicAlpn: offer.quicAlpn,
                expectedPeerCertificateFingerprint: offer.certificateFingerprint,
                identityMaterial: identityMaterial,
                localPort: localPort,
                remoteAddress: candidate.address
            )
            do {
                try await attemptOutboundProof(
                    to: candidate,
                    using: parameters,
                    attemptId: offer.attemptId,
                    role: "dialer",
                    localPort: localPort
                )
                await report(
                    "Direct QUIC probe connection established",
                    metadata: [
                        "attemptId": offer.attemptId,
                        "address": candidate.address,
                        "port": String(candidate.port),
                        "peerCertificateFingerprint": offer.certificateFingerprint,
                        "localPort": String(localPort),
                        "localCandidateCount": String(localCandidates.count),
                    ]
                )
                return DirectQuicPreparedDialerConnection(
                    attemptId: offer.attemptId,
                    certificateFingerprint: identityMaterial.certificateFingerprint,
                    candidates: localCandidates,
                    didEstablishPath: true,
                    lastFailureReason: nil
                )
            } catch {
                lastError = error
                await report(
                    "Direct QUIC probe candidate failed",
                    metadata: [
                        "attemptId": offer.attemptId,
                        "address": candidate.address,
                        "port": String(candidate.port),
                        "kind": candidate.kind.rawValue,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        return DirectQuicPreparedDialerConnection(
            attemptId: offer.attemptId,
            certificateFingerprint: identityMaterial.certificateFingerprint,
            candidates: localCandidates,
            didEstablishPath: false,
            lastFailureReason: lastError?.localizedDescription
                ?? DirectQuicProbeError.noViableCandidate.localizedDescription
        )
    }

    func prepareDialerAnswer(
        using offer: TurboDirectQuicOfferPayload,
        stunServers: [TurboDirectQuicStunServer] = []
    ) async throws -> DirectQuicPreparedDialerAnswer {
        let identityMaterial = try resolvedIdentityMaterial()
        let localPort = try allocateLocalUDPPort()
        let localCandidates = await localCandidates(
            localPort: localPort,
            stunServers: stunServers
        )

        let previousOutboundConnection = withLockedState { () -> NWConnection? in
            let existing = outboundConnection
            outboundConnection = nil
            return existing
        }
        previousOutboundConnection?.cancel()
        withLockedState {
            preparedDialerAttempt = DirectQuicPreparedDialerAttempt(
                attemptId: offer.attemptId,
                quicAlpn: offer.quicAlpn,
                localPort: localPort,
                candidates: localCandidates
            )
            nominatedPath = nil
        }

        await report(
            "Prepared direct QUIC dialer answer",
            metadata: [
                "attemptId": offer.attemptId,
                "candidateCount": String(localCandidates.count),
                "localPort": String(localPort),
                "identityLabel": identityMaterial.label,
            ]
        )

        return DirectQuicPreparedDialerAnswer(
            attemptId: offer.attemptId,
            certificateFingerprint: identityMaterial.certificateFingerprint,
            candidates: localCandidates
        )
    }

    func activateMediaTransport(
        onIncomingAudioPayload: @escaping @Sendable (String) async -> Void,
        onReceiverPrewarmRequest: (@Sendable (DirectQuicReceiverPrewarmPayload) async -> Void)? = nil,
        onReceiverPrewarmAck: (@Sendable (DirectQuicReceiverPrewarmPayload) async -> Void)? = nil,
        onPathClosing: (@Sendable (DirectQuicPathClosingPayload) async -> Void)? = nil,
        onWarmPong: (@Sendable (String?) async -> Void)? = nil,
        onPathLost: @escaping @Sendable (String) async -> Void
    ) async throws {
        let connection = withLockedState { outboundConnection ?? inboundConnection }
        guard let connection else {
            throw DirectQuicProbeError.connectionFailed("no verified direct QUIC connection")
        }

        withLockedState {
            suppressPathLostCallback = false
            self.onIncomingAudioPayload = onIncomingAudioPayload
            self.onReceiverPrewarmRequest = onReceiverPrewarmRequest
            self.onReceiverPrewarmAck = onReceiverPrewarmAck
            self.onPathClosing = onPathClosing
            self.onWarmPong = onWarmPong
            self.onPathLost = onPathLost
            activeMediaConnection = connection
            activeReceiveBuffer.removeAll(keepingCapacity: false)
            outstandingConsentID = nil
            outstandingConsentSentAt = nil
        }
        incomingAudioPayloadQueue.reset()
        receiveMediaMessages(on: connection)
        startConsentLoop(on: connection)

        await report(
            "Activated direct QUIC media transport",
            metadata: [:]
        )
    }

    func sendAudioPayload(_ payload: String) async throws {
        let connection = withLockedState {
            activeMediaConnection ?? outboundConnection ?? inboundConnection
        }
        guard let connection else {
            throw DirectQuicProbeError.connectionFailed("direct QUIC media path is unavailable")
        }
        try sendLiveAudio(message: .audioChunk(payload), on: connection)
    }

    func sendReceiverPrewarmRequest(_ payload: DirectQuicReceiverPrewarmPayload) async throws {
        let connection = try activeControlConnection()
        try await send(message: .receiverPrewarmRequest(payload), on: connection)
    }

    func sendReceiverPrewarmAck(_ payload: DirectQuicReceiverPrewarmPayload) async throws {
        let connection = try activeControlConnection()
        try await send(message: .receiverPrewarmAck(payload), on: connection)
    }

    func sendPathClosing(_ payload: DirectQuicPathClosingPayload) async throws {
        let connection = try activeControlConnection()
        try await send(message: .pathClosing(payload), on: connection)
    }

    func beginIntentionalPathClose(
        _ payload: DirectQuicPathClosingPayload,
        metadata: [String: String],
        cancelReason: String
    ) {
        suppressPathLostForIntentionalClose()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendPathClosing(payload)
                await self.report(
                    "Direct QUIC path closing sent",
                    metadata: metadata
                )
            } catch {
                var failureMetadata = metadata
                failureMetadata["error"] = error.localizedDescription
                await self.report(
                    "Direct QUIC path closing send failed",
                    metadata: failureMetadata
                )
            }
            self.cancel(reason: cancelReason)
        }
    }

    func sendWarmPing(id: String) async throws {
        let connection = try activeControlConnection()
        try await send(message: .warmPing(id), on: connection)
    }

    func preparedLocalCandidates(matching attemptId: String) -> [TurboDirectQuicCandidate] {
        withLockedState {
            if let preparedOffer, preparedOffer.attemptId == attemptId {
                return preparedOffer.candidates
            }
            if let preparedDialerAttempt, preparedDialerAttempt.attemptId == attemptId {
                return preparedDialerAttempt.candidates
            }
            return []
        }
    }

    func nominatedPath(matching attemptId: String) -> DirectQuicNominatedPath? {
        withLockedState {
            guard let nominatedPath, nominatedPath.attemptId == attemptId else {
                return nil
            }
            return nominatedPath
        }
    }

    func cancel(reason: String) {
        let resources = withLockedState { () -> (NWListener?, NWConnection?, NWConnection?, Task<Void, Never>?) in
            suppressPathLostCallback = true
            onIncomingAudioPayload = nil
            onReceiverPrewarmRequest = nil
            onReceiverPrewarmAck = nil
            onPathClosing = nil
            onWarmPong = nil
            onPathLost = nil
            activeMediaConnection = nil
            activeReceiveBuffer.removeAll(keepingCapacity: false)
            verifiedPeerCertificateFingerprint = nil
            nominatedPath = nil
            remoteCandidateKeysAttempted = []
            remoteCandidateProbeInFlight = false
            outstandingConsentID = nil
            outstandingConsentSentAt = nil
            let resources = (listener, inboundConnection, outboundConnection, consentTask)
            listener = nil
            inboundConnection = nil
            outboundConnection = nil
            preparedOffer = nil
            preparedDialerAttempt = nil
            consentTask = nil
            return resources
        }
        resources.0?.cancel()
        resources.1?.cancel()
        resources.2?.cancel()
        resources.3?.cancel()
        incomingAudioPayloadQueue.reset()
        Task {
            await report("Cancelled direct QUIC probe resources", metadata: ["reason": reason])
        }
    }

    private func suppressPathLostForIntentionalClose() {
        let consentTask = withLockedState { () -> Task<Void, Never>? in
            suppressPathLostCallback = true
            outstandingConsentID = nil
            outstandingConsentSentAt = nil
            let task = self.consentTask
            self.consentTask = nil
            return task
        }
        consentTask?.cancel()
    }

    func verifyConnectedPeerCertificateFingerprint(
        _ expectedPeerCertificateFingerprint: String
    ) throws {
        let normalizedExpectedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(expectedPeerCertificateFingerprint)
        let verifiedPeerCertificateFingerprint = withLockedState {
            self.verifiedPeerCertificateFingerprint
        }
        guard let verifiedPeerCertificateFingerprint else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC peer certificate fingerprint was unavailable"
            )
        }
        let normalizedVerifiedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(verifiedPeerCertificateFingerprint)
        guard normalizedVerifiedPeerCertificateFingerprint == normalizedExpectedPeerCertificateFingerprint else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC peer certificate fingerprint mismatch"
            )
        }
    }

    func verifyConnectedPeerCertificateFingerprintIfAvailable(
        _ expectedPeerCertificateFingerprint: String
    ) throws -> Bool {
        let normalizedExpectedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(expectedPeerCertificateFingerprint)
        let verifiedPeerCertificateFingerprint = withLockedState {
            self.verifiedPeerCertificateFingerprint
        }
        guard let verifiedPeerCertificateFingerprint else {
            return false
        }
        let normalizedVerifiedPeerCertificateFingerprint =
            Self.normalizedCertificateFingerprint(verifiedPeerCertificateFingerprint)
        guard normalizedVerifiedPeerCertificateFingerprint == normalizedExpectedPeerCertificateFingerprint else {
            throw DirectQuicProbeError.proofFailed(
                "direct QUIC peer certificate fingerprint mismatch"
            )
        }
        return true
    }

    func probeRemoteCandidatesIfNeeded(
        attemptId: String,
        expectedPeerCertificateFingerprint: String,
        candidates: [TurboDirectQuicCandidate]
    ) async throws -> DirectQuicCandidateProbeOutcome {
        let viableCandidates = viableCandidates(from: candidates)
        if try verifyConnectedPeerCertificateFingerprintIfAvailable(
            expectedPeerCertificateFingerprint
        ) {
            return DirectQuicCandidateProbeOutcome(
                disposition: .alreadyConnected,
                inputCandidateCount: candidates.count,
                viableCandidateCount: viableCandidates.count,
                newlyAttemptedCandidateCount: 0,
                lastErrorDescription: nil
            )
        }

        enum LocalProbeContext {
            case listener(DirectQuicPreparedLocalOffer)
            case dialer(DirectQuicPreparedDialerAttempt)

            var quicAlpn: String {
                switch self {
                case .listener(let offer):
                    return offer.quicAlpn
                case .dialer(let attempt):
                    return attempt.quicAlpn
                }
            }

            var localPort: UInt16 {
                switch self {
                case .listener(let offer):
                    return offer.localPort
                case .dialer(let attempt):
                    return attempt.localPort
                }
            }
        }

        let localProbeContext = withLockedState { () -> LocalProbeContext? in
            if let preparedOffer, preparedOffer.attemptId == attemptId {
                return .listener(preparedOffer)
            }
            if let preparedDialerAttempt, preparedDialerAttempt.attemptId == attemptId {
                return .dialer(preparedDialerAttempt)
            }
            return nil
        }
        guard let localProbeContext else {
            throw DirectQuicProbeError.connectionFailed(
                "direct QUIC local probe context is unavailable for candidate probing"
            )
        }

        let selection = withLockedState { () -> DirectQuicCandidateProbeSelection in
            let attemptedCandidateKeys = remoteCandidateKeysAttempted
            let selection = Self.selectCandidatesForProbeBatch(
                inputCandidates: candidates,
                attemptedCandidateKeys: attemptedCandidateKeys,
                probeInFlight: remoteCandidateProbeInFlight
            )
            if case .ready(let filteredCandidates, _) = selection {
                remoteCandidateProbeInFlight = true
                for candidate in filteredCandidates {
                    remoteCandidateKeysAttempted.insert(Self.candidateKey(candidate))
                }
            }
            return selection
        }
        let candidatesToProbe: [TurboDirectQuicCandidate]
        let viableCandidateCount: Int
        switch selection {
        case .immediate(let outcome):
            return outcome
        case .ready(let filteredCandidates, let selectionViableCandidateCount):
            candidatesToProbe = filteredCandidates
            viableCandidateCount = selectionViableCandidateCount
        }

        defer {
            withLockedState {
                remoteCandidateProbeInFlight = false
            }
        }

        let identityMaterial = try resolvedIdentityMaterial()
        var lastError: Error?
        for candidate in candidatesToProbe {
            if try verifyConnectedPeerCertificateFingerprintIfAvailable(
                expectedPeerCertificateFingerprint
            ) {
                return DirectQuicCandidateProbeOutcome(
                    disposition: .alreadyConnected,
                    inputCandidateCount: candidates.count,
                    viableCandidateCount: viableCandidateCount,
                    newlyAttemptedCandidateCount: candidatesToProbe.count,
                    lastErrorDescription: nil
                )
            }

            let parameters = makeOutboundParameters(
                quicAlpn: localProbeContext.quicAlpn,
                expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
                identityMaterial: identityMaterial,
                localPort: localProbeContext.localPort,
                remoteAddress: candidate.address
            )
            do {
                try await attemptOutboundProof(
                    to: candidate,
                    using: parameters,
                    attemptId: attemptId,
                    role: "listener-probe",
                    localPort: localProbeContext.localPort
                )
                await report(
                    "Direct QUIC candidate probe connection established",
                    metadata: [
                        "attemptId": attemptId,
                        "address": candidate.address,
                        "port": String(candidate.port),
                        "kind": candidate.kind.rawValue,
                        "peerCertificateFingerprint": expectedPeerCertificateFingerprint,
                        "localPort": String(localProbeContext.localPort),
                    ]
                )
                return DirectQuicCandidateProbeOutcome(
                    disposition: .pathEstablished,
                    inputCandidateCount: candidates.count,
                    viableCandidateCount: viableCandidateCount,
                    newlyAttemptedCandidateCount: candidatesToProbe.count,
                    lastErrorDescription: nil
                )
            } catch {
                lastError = error
                await report(
                    "Direct QUIC candidate probe failed",
                    metadata: [
                        "attemptId": attemptId,
                        "address": candidate.address,
                        "port": String(candidate.port),
                        "kind": candidate.kind.rawValue,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        if let lastError {
            await report(
                "Direct QUIC candidate probe batch exhausted",
                metadata: [
                    "attemptId": attemptId,
                    "candidateCount": String(candidatesToProbe.count),
                    "error": lastError.localizedDescription,
                ]
            )
        }
        return DirectQuicCandidateProbeOutcome(
            disposition: .batchExhausted,
            inputCandidateCount: candidates.count,
            viableCandidateCount: viableCandidateCount,
            newlyAttemptedCandidateCount: candidatesToProbe.count,
            lastErrorDescription: lastError?.localizedDescription
        )
    }

    private func viableCandidates(
        from candidates: [TurboDirectQuicCandidate]
    ) -> [TurboDirectQuicCandidate] {
        Self.viableProbeCandidates(from: candidates)
    }

    private func localCandidates(
        localPort: UInt16,
        stunServers: [TurboDirectQuicStunServer]
    ) async -> [TurboDirectQuicCandidate] {
        let hostCandidates = DirectQuicHostCandidateGatherer.gatherCandidates(port: localPort)
        let stunCandidates = await DirectQuicStunClient().gatherServerReflexiveCandidates(
            localPort: localPort,
            servers: stunServers
        )
        return hostCandidates + stunCandidates
    }

    private func allocateLocalUDPPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw DirectQuicProbeError.localPortAllocationFailed("socket() returned \(errno)")
        }
        defer { close(descriptor) }

        var value: Int32 = 1
        if setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        ) != 0 {
            throw DirectQuicProbeError.localPortAllocationFailed("setsockopt() returned \(errno)")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("0.0.0.0"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(
                    descriptor,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.stride)
                )
            }
        }
        guard bindResult == 0 else {
            throw DirectQuicProbeError.localPortAllocationFailed("bind() returned \(errno)")
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &addressLength)
            }
        }
        guard nameResult == 0 else {
            throw DirectQuicProbeError.localPortAllocationFailed("getsockname() returned \(errno)")
        }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func attemptOutboundProof(
        to candidate: TurboDirectQuicCandidate,
        using parameters: NWParameters,
        attemptId: String,
        role: String,
        localPort: UInt16
    ) async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(candidate.port)) else {
            throw DirectQuicProbeError.noViableCandidate
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(candidate.address),
            port: port,
            using: parameters
        )
        withLockedState {
            outboundConnection = connection
            verifiedPeerCertificateFingerprint = nil
        }

        do {
            try await startConnection(
                connection,
                metadata: [
                    "attemptId": attemptId,
                    "address": candidate.address,
                    "port": String(candidate.port),
                    "kind": candidate.kind.rawValue,
                    "role": role,
                ]
            )
            try await send(message: .probeHello, on: connection)
            let acknowledgement = try await receiveNextMessage(
                on: connection,
                errorPrefix: "expected direct QUIC probe acknowledgement"
            )
            guard acknowledgement.kind == .probeAck else {
                throw DirectQuicProbeError.proofFailed(
                    "expected direct QUIC probe acknowledgement: received \(acknowledgement.kind.rawValue)"
                )
            }
            withLockedState {
                nominatedPath = DirectQuicNominatedPath(
                    attemptId: attemptId,
                    source: .outboundProbe,
                    localPort: localPort,
                    remoteAddress: candidate.address,
                    remotePort: candidate.port,
                    remoteCandidateKind: candidate.kind
                )
            }
        } catch {
            withLockedState {
                if outboundConnection === connection {
                    outboundConnection = nil
                }
            }
            connection.cancel()
            throw error
        }
    }

    private func handleInboundConnection(_ connection: NWConnection) {
        let previousConnection = withLockedState { () -> NWConnection? in
            let previousConnection = inboundConnection
            inboundConnection = connection
            return previousConnection
        }
        previousConnection?.cancel()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task {
                    await self.report("Accepted direct QUIC inbound connection", metadata: [:])
                }
                self.receiveInboundProbe(on: connection)
            case .failed(let error):
                self.reportConnectionFailure(
                    connection: connection,
                    role: "inbound",
                    message: error.localizedDescription
                )
            case .cancelled:
                self.reportConnectionFailure(
                    connection: connection,
                    role: "inbound",
                    message: "cancelled"
                )
            case .waiting, .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveInboundProbe(on connection: NWConnection) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await self.receiveNextMessage(
                    on: connection,
                    errorPrefix: "expected direct QUIC probe hello"
                )
                guard message.kind == .probeHello else {
                    await self.report(
                        "Ignored unexpected direct QUIC inbound proof payload",
                        metadata: ["kind": message.kind.rawValue]
                    )
                    return
                }

                try await self.send(message: .probeAck, on: connection)
                self.recordInboundNominationIfPossible(on: connection)
                await self.report(
                    "Direct QUIC inbound proof acknowledged",
                    metadata: [:]
                )
            } catch {
                await self.report(
                    "Direct QUIC inbound proof receive failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func startListener(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let gate = ContinuationGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        gate.resume {
                            continuation.resume(
                                throwing: DirectQuicProbeError.listenerFailed("listener started without a port")
                            )
                        }
                        return
                    }
                    gate.resume {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicProbeError.listenerFailed(error.localizedDescription)
                        )
                    }
                case .cancelled:
                    gate.resume {
                        continuation.resume(throwing: DirectQuicProbeError.listenerCancelled)
                    }
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func startConnection(
        _ connection: NWConnection,
        metadata: [String: String]
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    gate.resume {
                        continuation.resume()
                    }
                case .failed(let error):
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicProbeError.connectionFailed(error.localizedDescription)
                        )
                    }
                    self?.reportConnectionFailure(
                        connection: connection,
                        role: metadata["role"] ?? "outbound",
                        message: error.localizedDescription
                    )
                case .cancelled:
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicProbeError.connectionFailed("cancelled")
                        )
                    }
                    self?.reportConnectionFailure(
                        connection: connection,
                        role: metadata["role"] ?? "outbound",
                        message: "cancelled"
                    )
                case .waiting(let error):
                    Task {
                        await self?.report(
                            "Direct QUIC outbound connection waiting",
                            metadata: metadata.merging(
                                ["error": error.localizedDescription],
                                uniquingKeysWith: { _, new in new }
                            )
                        )
                    }
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(
        message: DirectQuicWireMessage,
        on connection: NWConnection
    ) async throws {
        let content = try DirectQuicWireCodec.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: content, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(
                        throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func sendLiveAudio(
        message: DirectQuicWireMessage,
        on connection: NWConnection
    ) throws {
        let content = try DirectQuicWireCodec.encode(message)
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task {
                await self?.report(
                    "Direct QUIC live audio send completion failed",
                    metadata: [
                        "error": error.localizedDescription,
                        "payloadLength": String(content.count),
                    ]
                )
            }
        })
    }

    private func activeControlConnection() throws -> NWConnection {
        let connection = withLockedState {
            activeMediaConnection ?? outboundConnection ?? inboundConnection
        }
        guard let connection else {
            throw DirectQuicProbeError.connectionFailed("direct QUIC control path is unavailable")
        }
        return connection
    }

    private func receiveNextMessage(
        on connection: NWConnection,
        errorPrefix: String
    ) async throws -> DirectQuicWireMessage {
        var buffer = Data()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DirectQuicWireMessage, Error>) in
            func receiveNextChunk() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed(error.localizedDescription)
                        )
                        return
                    }
                    if let data, !data.isEmpty {
                        buffer.append(data)
                        do {
                            let decoded = try DirectQuicWireCodec.decodeAvailable(from: &buffer)
                            if let decoded = decoded.first {
                                continuation.resume(returning: decoded)
                                return
                            }
                        } catch {
                            continuation.resume(
                                throwing: DirectQuicProbeError.proofFailed("\(errorPrefix): \(error.localizedDescription)")
                            )
                            return
                        }
                    }
                    if isComplete {
                        continuation.resume(
                            throwing: DirectQuicProbeError.proofFailed("\(errorPrefix): empty response")
                        )
                        return
                    }
                    receiveNextChunk()
                }
            }
            receiveNextChunk()
        }
    }

    private func receiveMediaMessages(on connection: NWConnection) {
        guard withLockedState({ activeMediaConnection === connection }) else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                Task {
                    await self.report(
                        "Direct QUIC media receive failed",
                        metadata: ["error": error.localizedDescription]
                    )
                }
                self.notifyPathLostIfNeeded(
                    for: connection,
                    reason: error.localizedDescription
                )
                return
            }

            if let data, !data.isEmpty {
                let decodeResult = withLockedState { () -> Result<[DirectQuicWireMessage], Error> in
                    self.activeReceiveBuffer.append(data)
                    do {
                        return .success(
                            try DirectQuicWireCodec.decodeAvailable(from: &self.activeReceiveBuffer)
                        )
                    } catch {
                        return .failure(error)
                    }
                }
                switch decodeResult {
                case .success(let decodedMessages):
                    for decodedMessage in decodedMessages {
                        switch decodedMessage.kind {
                        case .audioChunk:
                            guard let payload = decodedMessage.payload else { continue }
                            let onIncomingAudioPayload = self.withLockedState { self.onIncomingAudioPayload }
                            self.incomingAudioPayloadQueue.enqueue {
                                await onIncomingAudioPayload?(payload)
                            }
                        case .probeHello:
                            Task {
                                do {
                                    try await self.send(message: .probeAck, on: connection)
                                } catch {
                                    await self.report(
                                        "Direct QUIC media probe acknowledgement failed",
                                        metadata: ["error": error.localizedDescription]
                                    )
                                }
                            }
                        case .probeAck:
                            Task {
                                await self.report(
                                    "Ignored unexpected direct QUIC media control payload",
                                    metadata: ["kind": decodedMessage.kind.rawValue]
                                )
                            }
                        case .consentPing:
                            let consentID = decodedMessage.payload
                            Task {
                                do {
                                    try await self.send(message: .consentAck(consentID), on: connection)
                                } catch {
                                    await self.report(
                                        "Direct QUIC consent acknowledgement failed",
                                        metadata: ["error": error.localizedDescription]
                                    )
                                }
                            }
                        case .consentAck:
                            self.withLockedState {
                                guard self.outstandingConsentID == decodedMessage.payload else { return }
                                self.outstandingConsentID = nil
                                self.outstandingConsentSentAt = nil
                            }
                        case .receiverPrewarmRequest:
                            do {
                                let payload = try DirectQuicReceiverPrewarmPayloadCodec.decode(decodedMessage.payload)
                                let onReceiverPrewarmRequest = self.withLockedState { self.onReceiverPrewarmRequest }
                                Task {
                                    await onReceiverPrewarmRequest?(payload)
                                }
                            } catch {
                                Task {
                                    await self.report(
                                        "Direct QUIC receiver prewarm request decode failed",
                                        metadata: ["error": error.localizedDescription]
                                    )
                                }
                            }
                        case .receiverPrewarmAck:
                            do {
                                let payload = try DirectQuicReceiverPrewarmPayloadCodec.decode(decodedMessage.payload)
                                let onReceiverPrewarmAck = self.withLockedState { self.onReceiverPrewarmAck }
                                Task {
                                    await onReceiverPrewarmAck?(payload)
                                }
                            } catch {
                                Task {
                                    await self.report(
                                        "Direct QUIC receiver prewarm ack decode failed",
                                        metadata: ["error": error.localizedDescription]
                                    )
                                }
                            }
                        case .pathClosing:
                            do {
                                let payload = try DirectQuicPathClosingPayloadCodec.decode(decodedMessage.payload)
                                let onPathClosing = self.withLockedState {
                                    self.suppressPathLostCallback = true
                                    self.outstandingConsentID = nil
                                    self.outstandingConsentSentAt = nil
                                    let task = self.consentTask
                                    self.consentTask = nil
                                    task?.cancel()
                                    return self.onPathClosing
                                }
                                Task {
                                    await onPathClosing?(payload)
                                }
                            } catch {
                                Task {
                                    await self.report(
                                        "Direct QUIC path closing decode failed",
                                        metadata: ["error": error.localizedDescription]
                                    )
                                }
                            }
                        case .warmPing:
                            let pingID = decodedMessage.payload
                            Task {
                                do {
                                    try await self.send(message: .warmPong(pingID), on: connection)
                                } catch {
                                    await self.report(
                                        "Direct QUIC warm pong failed",
                                        metadata: ["error": error.localizedDescription]
                                    )
                                }
                            }
                        case .warmPong:
                            let onWarmPong = self.withLockedState { self.onWarmPong }
                            Task {
                                await onWarmPong?(decodedMessage.payload)
                            }
                        }
                    }
                case .failure(let error):
                    Task {
                        await self.report(
                            "Direct QUIC media framing decode failed",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                    self.notifyPathLostIfNeeded(
                        for: connection,
                        reason: "invalid-media-frame"
                    )
                    return
                }
            }

            if isComplete {
                self.notifyPathLostIfNeeded(
                    for: connection,
                    reason: "connection-complete"
                )
                return
            }

            self.receiveMediaMessages(on: connection)
        }
    }

    private func notifyPathLostIfNeeded(
        for connection: NWConnection,
        reason: String
    ) {
        let pathLostHandler = withLockedState { () -> (((@Sendable (String) async -> Void)?, Task<Void, Never>?)?) in
            guard !suppressPathLostCallback else { return nil }
            guard activeMediaConnection === connection else { return nil }
            suppressPathLostCallback = true
            outstandingConsentID = nil
            outstandingConsentSentAt = nil
            let task = consentTask
            consentTask = nil
            return (onPathLost, task)
        }
        guard let (handler, task) = pathLostHandler else { return }
        task?.cancel()
        guard let handler else { return }
        Task {
            await handler(reason)
        }
    }

    private func reportConnectionFailure(
        connection: NWConnection,
        role: String,
        message: String
    ) {
        Task {
            await report(
                "Direct QUIC \(role) connection failed",
                metadata: ["error": message]
            )
        }
        notifyPathLostIfNeeded(for: connection, reason: message)
    }

    private func resolvedIdentityLabel() throws -> String {
        guard let label = DirectQuicIdentityConfiguration.resolvedLabel(), !label.isEmpty else {
            throw DirectQuicProbeError.identityLabelMissing
        }
        return label
    }

    private func resolvedIdentityMaterial() throws -> DirectQuicIdentityMaterial {
        let label = try resolvedIdentityLabel()
        if let productionIdentity = DirectQuicProductionIdentityManager.existingIdentity(label: label) {
            return DirectQuicIdentityMaterial(
                label: label,
                identity: productionIdentity.identity,
                certificateFingerprint: productionIdentity.certificateFingerprint,
                source: .production
            )
        }
        let identity = try Self.loadDebugIdentity(label: label)
        let certificateFingerprint = try Self.fingerprint(for: identity)
        return DirectQuicIdentityMaterial(
            label: label,
            identity: identity,
            certificateFingerprint: certificateFingerprint,
            source: .debugP12
        )
    }

    private static func loadDebugIdentity(label: String) throws -> SecIdentity {
        do {
            return try DirectQuicIdentityConfiguration.loadIdentity(label: label)
        } catch DirectQuicProbeError.identityNotFound {
            if let fingerprint = DirectQuicIdentityConfiguration.selectedInstalledIdentityFingerprint(),
               let installedIdentity = DirectQuicIdentityConfiguration.loadInstalledIdentityMatchingFingerprint(
                    fingerprint
               ) {
                return installedIdentity
            }
            throw DirectQuicProbeError.identityNotFound(label)
        } catch {
            throw error
        }
    }

    private static func fingerprint(for identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw DirectQuicProbeError.certificateMissing
        }
        return try fingerprint(for: certificate)
    }

    private static func fingerprint(for certificate: SecCertificate) throws -> String {
        let certificateData = SecCertificateCopyData(certificate) as Data
        guard !certificateData.isEmpty else {
            throw DirectQuicProbeError.fingerprintEncodingFailed
        }
        let digest = SHA256.hash(data: certificateData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    private static func normalizedCertificateFingerprint(_ fingerprint: String) -> String {
        fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func peerCertificateFingerprint(
        metadata: sec_protocol_metadata_t
    ) -> String? {
        var leafCertificate: SecCertificate?
        let didAccessCertificates = sec_protocol_metadata_access_peer_certificate_chain(metadata) {
            certificate in
            guard leafCertificate == nil else { return }
            leafCertificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
        }
        guard didAccessCertificates, let leafCertificate else { return nil }
        return try? fingerprint(for: leafCertificate)
    }

    private func installPeerVerification(
        on options: sec_protocol_options_t,
        expectedPeerCertificateFingerprint: String?,
        role: String
    ) {
        sec_protocol_options_set_verify_block(
            options,
            { [weak self] metadata, _, complete in
                guard let self else {
                    complete(false)
                    return
                }
                guard let peerCertificateFingerprint = Self.peerCertificateFingerprint(metadata: metadata) else {
                    Task {
                        await self.report(
                            "Direct QUIC peer certificate fingerprint unavailable",
                            metadata: ["role": role]
                        )
                    }
                    complete(false)
                    return
                }
                let normalizedPeerCertificateFingerprint =
                    Self.normalizedCertificateFingerprint(peerCertificateFingerprint)
                self.withLockedState {
                    self.verifiedPeerCertificateFingerprint = normalizedPeerCertificateFingerprint
                }

                if let expectedPeerCertificateFingerprint {
                    let normalizedExpectedPeerCertificateFingerprint =
                        Self.normalizedCertificateFingerprint(expectedPeerCertificateFingerprint)
                    guard normalizedPeerCertificateFingerprint == normalizedExpectedPeerCertificateFingerprint else {
                        Task {
                            await self.report(
                                "Direct QUIC peer certificate fingerprint mismatch",
                                metadata: [
                                    "role": role,
                                    "expectedPeerCertificateFingerprint": normalizedExpectedPeerCertificateFingerprint,
                                    "actualPeerCertificateFingerprint": normalizedPeerCertificateFingerprint,
                                ]
                            )
                        }
                        complete(false)
                        return
                    }
                }

                Task {
                    await self.report(
                        "Direct QUIC peer certificate verified",
                        metadata: [
                            "role": role,
                            "peerCertificateFingerprint": normalizedPeerCertificateFingerprint,
                        ]
                    )
                }
                complete(true)
            },
            queue
        )
    }

    private func report(
        _ message: String,
        metadata: [String: String]
    ) async {
        await reportEvent?(message, metadata)
    }

    private func makeOutboundParameters(
        quicAlpn: String,
        expectedPeerCertificateFingerprint: String,
        identityMaterial: DirectQuicIdentityMaterial,
        localPort: UInt16,
        remoteAddress: String? = nil
    ) -> NWParameters {
        let quicOptions = NWProtocolQUIC.Options(alpn: [quicAlpn])
        sec_protocol_options_set_min_tls_protocol_version(
            quicOptions.securityProtocolOptions,
            .TLSv13
        )
        installPeerVerification(
            on: quicOptions.securityProtocolOptions,
            expectedPeerCertificateFingerprint: expectedPeerCertificateFingerprint,
            role: "dialer"
        )
        if let localIdentity = sec_identity_create(identityMaterial.identity) {
            sec_protocol_options_set_local_identity(
                quicOptions.securityProtocolOptions,
                localIdentity
            )
        }

        let parameters = NWParameters(quic: quicOptions)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        let localHost = remoteAddress.map(Self.isIPv6Address) == true ? "::" : "0.0.0.0"
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(localHost),
            port: NWEndpoint.Port(rawValue: localPort) ?? .any
        )
        return parameters
    }

    static func candidateKey(_ candidate: TurboDirectQuicCandidate) -> String {
        [
            candidate.kind.rawValue,
            candidate.transport.lowercased(),
            candidate.address.lowercased(),
            String(candidate.port),
            candidate.relatedAddress?.lowercased() ?? "",
            candidate.relatedPort.map(String.init) ?? "",
            candidate.foundation,
        ].joined(separator: "|")
    }

    static func selectCandidatesForProbeBatch(
        inputCandidates: [TurboDirectQuicCandidate],
        attemptedCandidateKeys: Set<String>,
        probeInFlight: Bool
    ) -> DirectQuicCandidateProbeSelection {
        let viableCandidates = viableProbeCandidates(from: inputCandidates)

        if probeInFlight {
            return .immediate(
                DirectQuicCandidateProbeOutcome(
                    disposition: .probeAlreadyInFlight,
                    inputCandidateCount: inputCandidates.count,
                    viableCandidateCount: viableCandidates.count,
                    newlyAttemptedCandidateCount: 0,
                    lastErrorDescription: nil
                )
            )
        }

        let filteredCandidates = viableCandidates.filter {
            !attemptedCandidateKeys.contains(candidateKey($0))
        }
        if filteredCandidates.isEmpty {
            return .immediate(
                DirectQuicCandidateProbeOutcome(
                    disposition: viableCandidates.isEmpty ? .noViableCandidates : .noNewCandidates,
                    inputCandidateCount: inputCandidates.count,
                    viableCandidateCount: viableCandidates.count,
                    newlyAttemptedCandidateCount: 0,
                    lastErrorDescription: nil
                )
            )
        }

        return .ready(filteredCandidates, viableCandidateCount: viableCandidates.count)
    }

    private static func viableProbeCandidates(
        from candidates: [TurboDirectQuicCandidate]
    ) -> [TurboDirectQuicCandidate] {
        candidates
            .filter {
                ($0.kind == .host || $0.kind == .serverReflexive)
                    && $0.transport.caseInsensitiveCompare("udp") == .orderedSame
                    && $0.port > 0
                    && $0.port <= Int(UInt16.max)
                    && !isIPv6LoopbackOrLinkLocal($0.address)
            }
            .sorted { lhs, rhs in
                let lhsRank = candidateSortRank(lhs)
                let rhsRank = candidateSortRank(rhs)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.priority > rhs.priority
            }
    }

    private static func candidateSortRank(_ candidate: TurboDirectQuicCandidate) -> Int {
        switch candidate.kind {
        case .serverReflexive where isIPv6Address(candidate.address):
            return 0
        case .serverReflexive:
            return 1
        case .host where isGlobalIPv6Address(candidate.address):
            return 2
        case .host where isPrivateOrLoopbackIPv4Address(candidate.address):
            return 4
        case .host:
            return 3
        case .relay:
            return 5
        }
    }

    private static func isIPv6Address(_ address: String) -> Bool {
        address.contains(":")
    }

    private static func isGlobalIPv6Address(_ address: String) -> Bool {
        isIPv6Address(address) && !isIPv6LoopbackOrLinkLocal(address)
    }

    private static func isIPv6LoopbackOrLinkLocal(_ address: String) -> Bool {
        let normalized = address.lowercased()
        return normalized == "::1"
            || normalized.hasPrefix("fe80:")
            || normalized.hasPrefix("fe80::")
    }

    private static func isPrivateOrLoopbackIPv4Address(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let first = parts[0]
        let second = parts[1]
        return first == 10
            || first == 127
            || (first == 172 && (16 ... 31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }

    private func startConsentLoop(on connection: NWConnection) {
        let task = Task { [weak self] in
            guard let self else { return }

            enum ConsentAction {
                case send(String)
                case wait
                case fail(String)
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.consentIntervalNanoseconds)
                guard !Task.isCancelled else { return }

                let action = self.withLockedState { () -> ConsentAction in
                    guard !self.suppressPathLostCallback, self.activeMediaConnection === connection else {
                        return .wait
                    }
                    if self.outstandingConsentID != nil,
                       let outstandingConsentSentAt = self.outstandingConsentSentAt,
                       Date().timeIntervalSince(outstandingConsentSentAt) > Self.consentTimeoutSeconds {
                        self.outstandingConsentID = nil
                        self.outstandingConsentSentAt = nil
                        return .fail("consent-timeout")
                    }
                    guard self.outstandingConsentID == nil else {
                        return .wait
                    }
                    let consentID = UUID().uuidString.lowercased()
                    self.outstandingConsentID = consentID
                    self.outstandingConsentSentAt = Date()
                    return .send(consentID)
                }

                switch action {
                case .wait:
                    continue
                case .send(let consentID):
                    do {
                        try await self.send(message: .consentPing(consentID), on: connection)
                    } catch {
                        await self.report(
                            "Direct QUIC consent ping failed",
                            metadata: ["error": error.localizedDescription]
                        )
                        self.notifyPathLostIfNeeded(
                            for: connection,
                            reason: "consent-send-failed"
                        )
                        return
                    }
                case .fail(let reason):
                    await self.report(
                        "Direct QUIC consent timed out",
                        metadata: ["reason": reason]
                    )
                    self.notifyPathLostIfNeeded(for: connection, reason: reason)
                    return
                }
            }
        }

        let previousTask = withLockedState { () -> Task<Void, Never>? in
            let previousTask = consentTask
            consentTask = task
            return previousTask
        }
        previousTask?.cancel()
    }

    private func recordInboundNominationIfPossible(on connection: NWConnection) {
        guard let endpoint = Self.endpointAddressAndPort(for: connection.endpoint) else {
            return
        }
        withLockedState {
            guard let preparedOffer else { return }
            nominatedPath = DirectQuicNominatedPath(
                attemptId: preparedOffer.attemptId,
                source: .inboundConnection,
                localPort: preparedOffer.localPort,
                remoteAddress: endpoint.address,
                remotePort: endpoint.port,
                remoteCandidateKind: nil
            )
        }
    }

    private static func endpointAddressAndPort(
        for endpoint: NWEndpoint
    ) -> (address: String, port: Int)? {
        guard case .hostPort(let host, let port) = endpoint else {
            return nil
        }
        return (String(describing: host), Int(port.rawValue))
    }

    private func withLockedState<T>(
        _ operation: () -> T
    ) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}
