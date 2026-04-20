import Foundation
import Observation
import OSLog

struct SelectedSessionDiagnosticsSummary: Equatable {
    let selectedHandle: String?
    let selectedPhase: String
    let selectedPhaseDetail: String
    let relationship: String
    let statusMessage: String
    let canTransmitNow: Bool
    let isJoined: Bool
    let isTransmitting: Bool
    let activeChannelID: String?
    let pendingAction: String
    let hadConnectedSessionContinuity: Bool
    let systemSession: String
    let mediaState: String
    let backendChannelStatus: String?
    let backendReadiness: String?
    let backendMembership: String?
    let backendRequestRelationship: String?
    let backendSelfJoined: Bool?
    let backendPeerJoined: Bool?
    let backendPeerDeviceConnected: Bool?
    let remoteAudioReadiness: String?
    let remoteWakeCapability: String?
    let remoteWakeCapabilityKind: String?
    let backendCanTransmit: Bool?
    let pttTokenRegistrationKind: String
    let incomingWakeActivationState: String?
    let incomingWakeBufferedChunkCount: Int?
}

struct ContactDiagnosticsSummary: Equatable, Identifiable {
    let handle: String
    let isOnline: Bool
    let listState: String
    let badgeStatus: String?
    let requestRelationship: String
    let hasIncomingRequest: Bool
    let hasOutgoingRequest: Bool
    let requestCount: Int
    let incomingInviteCount: Int?
    let outgoingInviteCount: Int?

    var id: String { handle }
}

struct StateMachineProjection: Equatable {
    let selectedSession: SelectedSessionDiagnosticsSummary
    let contacts: [ContactDiagnosticsSummary]
    let isWebSocketConnected: Bool
    let statusMessage: String
    let backendStatusMessage: String

    func contact(handle: String) -> ContactDiagnosticsSummary? {
        contacts.first { $0.handle == handle }
    }
}

enum DiagnosticsInvariantScope: String, Codable, CaseIterable {
    case local
    case backend
    case pair
    case convergence
}

struct DiagnosticsInvariantViolation: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let invariantID: String
    let scope: DiagnosticsInvariantScope
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        invariantID: String,
        scope: DiagnosticsInvariantScope,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.invariantID = invariantID
        self.scope = scope
        self.message = message
        self.metadata = metadata
    }
}

enum DiagnosticsLevel: String, Codable, CaseIterable {
    case debug
    case info
    case notice
    case error
}

enum DiagnosticsSubsystem: String, Codable, CaseIterable {
    case app
    case auth
    case backend
    case websocket
    case channel
    case media
    case pushToTalk = "ptt"
    case state
    case invariant
    case selfCheck = "self-check"
}

struct DiagnosticsEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let subsystem: DiagnosticsSubsystem
    let level: DiagnosticsLevel
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        subsystem: DiagnosticsSubsystem,
        level: DiagnosticsLevel,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

struct DiagnosticsStateCapture: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let reason: String
    let changedKeys: [String]
    let fields: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        reason: String,
        changedKeys: [String],
        fields: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.reason = reason
        self.changedKeys = changedKeys
        self.fields = fields
    }

    var summaryLine: String {
        let parts = [
            "selected=\(fields["selectedContact"] ?? "none")",
            "phase=\(fields["selectedPeerPhase"] ?? "unknown")",
            "relationship=\(fields["selectedPeerRelationship"] ?? "unknown")",
            "pending=\(fields["pendingAction"] ?? "none")",
            "continuity=\(fields["hadConnectedSessionContinuity"] ?? "false")",
            "joined=\(fields["isJoined"] ?? "false")",
            "transmitting=\(fields["isTransmitting"] ?? "false")",
            "system=\(fields["systemSession"] ?? "none")",
            "backendChannel=\(fields["backendChannelStatus"] ?? "none")",
            "backendReadiness=\(fields["backendReadiness"] ?? "none")",
            "backendSelfJoined=\(fields["backendSelfJoined"] ?? "none")",
            "backendPeerJoined=\(fields["backendPeerJoined"] ?? "none")",
            "peerDevice=\(fields["backendPeerDeviceConnected"] ?? "none")",
            "peerAudio=\(fields["remoteAudioReadiness"] ?? "unknown")",
            "peerWake=\(fields["remoteWakeCapability"] ?? "unavailable")",
            "wakeActivation=\(fields["incomingWakeActivationState"] ?? "none")",
            "status=\(fields["selectedPeerStatus"] ?? fields["status"] ?? "none")"
        ]
        return parts.joined(separator: " ")
    }
}

@MainActor
@Observable
final class DiagnosticsStore {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Turbo", category: "diagnostics")
    private let entryLimit = 200
    private let stateCaptureLimit = 80
    private let invariantViolationLimit = 80
    private let logFileURL: URL?
    private static let iso8601TimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private(set) var entries: [DiagnosticsEntry] = []
    private(set) var stateCaptures: [DiagnosticsStateCapture] = []
    private(set) var invariantViolations: [DiagnosticsInvariantViolation] = []
    private(set) var latestErrorEntry: DiagnosticsEntry?

    init() {
        let baseDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let baseDirectory {
            let directory = baseDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("beepbeep-diagnostics.log")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            logFileURL = fileURL
        } else {
            logFileURL = nil
        }
    }

    var latestError: DiagnosticsEntry? {
        latestErrorEntry
    }

    var logFilePath: String? {
        logFileURL?.path
    }

    nonisolated func record(
        _ subsystem: DiagnosticsSubsystem,
        level: DiagnosticsLevel = .info,
        message: String,
        metadata: [String: String] = [:]
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.recordOnMain(
                    subsystem: subsystem,
                    level: level,
                    message: message,
                    metadata: metadata
                )
            }
        } else {
            Task { @MainActor [weak self] in
                self?.recordOnMain(
                    subsystem: subsystem,
                    level: level,
                    message: message,
                    metadata: metadata
                )
            }
        }
    }

    nonisolated func clear() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.clearOnMain()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.clearOnMain()
            }
        }
    }

    nonisolated func captureState(reason: String, fields: [String: String]) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.captureStateOnMain(reason: reason, fields: fields)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.captureStateOnMain(reason: reason, fields: fields)
            }
        }
    }

    nonisolated func recordInvariantViolation(
        invariantID: String,
        scope: DiagnosticsInvariantScope,
        message: String,
        metadata: [String: String] = [:]
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.recordInvariantViolationOnMain(
                    invariantID: invariantID,
                    scope: scope,
                    message: message,
                    metadata: metadata
                )
            }
        } else {
            Task { @MainActor [weak self] in
                self?.recordInvariantViolationOnMain(
                    invariantID: invariantID,
                    scope: scope,
                    message: message,
                    metadata: metadata
                )
            }
        }
    }

    private func recordOnMain(
        subsystem: DiagnosticsSubsystem,
        level: DiagnosticsLevel,
        message: String,
        metadata: [String: String]
    ) {
        let entry = DiagnosticsEntry(
            subsystem: subsystem,
            level: level,
            message: message,
            metadata: metadata
        )
        entries.insert(entry, at: 0)
        if entries.count > entryLimit {
            entries.removeLast(entries.count - entryLimit)
        }
        refreshLatestErrorEntry(afterRecording: entry)
        logger.log(level: entry.level.osLogType, "\(entry.subsystem.rawValue, privacy: .public): \(entry.message, privacy: .public) \(entry.metadata.formattedForLog, privacy: .public)")
        appendToDisk(entry)
    }

    private func clearOnMain() {
        entries.removeAll()
        stateCaptures.removeAll()
        invariantViolations.removeAll()
        latestErrorEntry = nil
        guard let logFileURL else { return }
        try? Data().write(to: logFileURL, options: .atomic)
    }

    private func captureStateOnMain(reason: String, fields: [String: String]) {
        if stateCaptures.first?.fields == fields {
            return
        }

        let changedKeys = DiagnosticsStore.changedKeys(
            from: stateCaptures.first?.fields ?? [:],
            to: fields
        )

        let capture = DiagnosticsStateCapture(
            reason: reason,
            changedKeys: changedKeys,
            fields: fields
        )
        stateCaptures.insert(capture, at: 0)
        if stateCaptures.count > stateCaptureLimit {
            stateCaptures.removeLast(stateCaptures.count - stateCaptureLimit)
        }
        logger.debug(
            "state: \(reason, privacy: .public) changed=\(changedKeys.joined(separator: ","), privacy: .public) \(capture.summaryLine, privacy: .public)"
        )
        appendStateCaptureToDisk(capture)

        for violation in DiagnosticsStore.evaluateSnapshotInvariantViolations(fields: fields) {
            recordInvariantViolationOnMain(
                invariantID: violation.invariantID,
                scope: violation.scope,
                message: violation.message,
                metadata: violation.metadata.merging(
                    [
                        "reason": reason,
                    ],
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }
    }

    private func recordInvariantViolationOnMain(
        invariantID: String,
        scope: DiagnosticsInvariantScope,
        message: String,
        metadata: [String: String]
    ) {
        let violation = DiagnosticsInvariantViolation(
            invariantID: invariantID,
            scope: scope,
            message: message,
            metadata: metadata
        )

        if invariantViolations.first.map({
            $0.invariantID == violation.invariantID &&
                $0.scope == violation.scope &&
                $0.message == violation.message &&
                $0.metadata == violation.metadata
        }) == true {
            return
        }

        invariantViolations.insert(violation, at: 0)
        if invariantViolations.count > invariantViolationLimit {
            invariantViolations.removeLast(invariantViolations.count - invariantViolationLimit)
        }

        var diagnosticMetadata = metadata
        diagnosticMetadata["invariantID"] = invariantID
        diagnosticMetadata["scope"] = scope.rawValue
        recordOnMain(
            subsystem: .invariant,
            level: .error,
            message: message,
            metadata: diagnosticMetadata
        )
    }

    func exportText(snapshot: String? = nil) -> String {
        var sections: [String] = []
        if let snapshot, !snapshot.isEmpty {
            sections.append("STATE SNAPSHOT\n\(snapshot)")
        }

        if stateCaptures.isEmpty {
            sections.append("STATE TIMELINE\n<empty>")
        } else {
            let lines = stateCaptures.map { capture in
                let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: capture.timestamp)
                let changed =
                    capture.changedKeys.isEmpty
                    ? "none"
                    : capture.changedKeys.joined(separator: ",")
                return "[\(timestamp)] [\(capture.reason)] changed=\(changed) \(capture.summaryLine)"
            }
            sections.append("STATE TIMELINE\n" + lines.joined(separator: "\n"))
        }

        if invariantViolations.isEmpty {
            sections.append("INVARIANT VIOLATIONS\n<empty>")
        } else {
            let lines = invariantViolations.map { violation in
                let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: violation.timestamp)
                let metadata =
                    violation.metadata.isEmpty
                    ? ""
                    : " " + violation.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                return "[\(timestamp)] [\(violation.invariantID)] [\(violation.scope.rawValue)] \(violation.message)\(metadata)"
            }
            sections.append("INVARIANT VIOLATIONS\n" + lines.joined(separator: "\n"))
        }

        if entries.isEmpty {
            sections.append("DIAGNOSTICS\n<empty>")
        } else {
            let lines = entries.map { entry in
                let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: entry.timestamp)
                let metadata =
                    entry.metadata.isEmpty
                    ? ""
                    : " " + entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                return "[\(timestamp)] [\(entry.level.rawValue)] [\(entry.subsystem.rawValue)] \(entry.message)\(metadata)"
            }
            sections.append("DIAGNOSTICS\n" + lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    private func appendToDisk(_ entry: DiagnosticsEntry) {
        guard let logFileURL else { return }
        let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: entry.timestamp)
        let metadata =
            entry.metadata.isEmpty
            ? ""
            : " " + entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let line = "[\(timestamp)] [\(entry.level.rawValue)] [\(entry.subsystem.rawValue)] \(entry.message)\(metadata)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }
        defer {
            try? handle.close()
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func appendStateCaptureToDisk(_ capture: DiagnosticsStateCapture) {
        guard let logFileURL else { return }
        let timestamp = DiagnosticsStore.iso8601TimestampFormatter.string(from: capture.timestamp)
        let changed =
            capture.changedKeys.isEmpty
            ? "none"
            : capture.changedKeys.joined(separator: ",")
        let line = "[\(timestamp)] [state] [\(capture.reason)] changed=\(changed) \(capture.summaryLine)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }
        defer {
            try? handle.close()
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func changedKeys(from oldFields: [String: String], to newFields: [String: String]) -> [String] {
        Array(Set(oldFields.keys).union(newFields.keys))
            .filter { oldFields[$0] != newFields[$0] }
            .sorted()
    }

    private static func evaluateSnapshotInvariantViolations(
        fields: [String: String]
    ) -> [DiagnosticsInvariantViolationCandidate] {
        let phase = fields["selectedPeerPhase"] ?? "none"
        let backendSelfJoined = snapshotBool(fields, key: "backendSelfJoined")
        let backendPeerJoined = snapshotBool(fields, key: "backendPeerJoined")
        let backendPeerDeviceConnected = snapshotBool(fields, key: "backendPeerDeviceConnected")
        let backendCanTransmit = snapshotBool(fields, key: "backendCanTransmit")
        let isJoined = snapshotBool(fields, key: "isJoined")
        let hadConnectedSessionContinuity = snapshotBool(fields, key: "hadConnectedSessionContinuity")
        let backendChannelStatus = fields["backendChannelStatus"] ?? "none"
        let backendReadiness = fields["backendReadiness"] ?? "none"
        let remoteWakeCapabilityKind = fields["remoteWakeCapabilityKind"] ?? "unavailable"
        let systemSession = fields["systemSession"] ?? "none"

        var violations: [DiagnosticsInvariantViolationCandidate] = []

        if phase == "ready", isJoined == false {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.ready_without_join",
                    scope: .local,
                    message: "selectedPeerPhase=ready while isJoined=false",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "isJoined": fields["isJoined"] ?? "none",
                    ]
                )
            )
        }

        if phase == "ready", backendCanTransmit == false {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.ready_while_backend_cannot_transmit",
                    scope: .backend,
                    message: "selectedPeerPhase=ready while backendCanTransmit=false",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "backendCanTransmit": fields["backendCanTransmit"] ?? "none",
                    ]
                )
            )
        }

        if backendSelfJoined == true, backendPeerJoined == true, backendPeerDeviceConnected == true {
            let notLivePhases = Set(["idle", "requested", "incomingRequest"])
            if notLivePhases.contains(phase) {
                violations.append(
                    DiagnosticsInvariantViolationCandidate(
                        invariantID: "selected.backend_ready_ui_not_live",
                        scope: .backend,
                        message: "backend says both sides are ready, but selectedPeerPhase is still not live",
                        metadata: [
                            "selectedPeerPhase": phase,
                            "backendSelfJoined": fields["backendSelfJoined"] ?? "none",
                            "backendPeerJoined": fields["backendPeerJoined"] ?? "none",
                            "backendPeerDeviceConnected": fields["backendPeerDeviceConnected"] ?? "none",
                        ]
                    )
                )
            }
        }

        if backendPeerJoined == true, backendSelfJoined == false {
            let disconnectedPhases = Set(["idle", "requested"])
            if disconnectedPhases.contains(phase) {
                violations.append(
                    DiagnosticsInvariantViolationCandidate(
                        invariantID: "selected.peer_joined_ui_not_connectable",
                        scope: .backend,
                        message: "backend says the peer already joined, but selectedPeerPhase is still not connectable",
                        metadata: [
                            "selectedPeerPhase": phase,
                            "backendSelfJoined": fields["backendSelfJoined"] ?? "none",
                            "backendPeerJoined": fields["backendPeerJoined"] ?? "none",
                        ]
                    )
                )
            }
        }

        if backendReadiness == "waiting-for-self" {
            let disconnectedPhases = Set(["idle", "requested", "incomingRequest"])
            if disconnectedPhases.contains(phase) {
                violations.append(
                    DiagnosticsInvariantViolationCandidate(
                        invariantID: "selected.waiting_for_self_ui_not_connectable",
                        scope: .backend,
                        message: "backend says the peer is waiting for self, but selectedPeerPhase is still not connectable",
                        metadata: [
                            "selectedPeerPhase": phase,
                            "backendChannelStatus": backendChannelStatus,
                            "backendReadiness": backendReadiness,
                            "backendSelfJoined": fields["backendSelfJoined"] ?? "none",
                            "backendPeerJoined": fields["backendPeerJoined"] ?? "none",
                        ]
                    )
                )
            }
        }

        let connectableWakeStatuses = Set(["waiting-for-peer", "ready", "transmitting", "receiving"])
        if remoteWakeCapabilityKind == "wake-capable",
           connectableWakeStatuses.contains(backendChannelStatus) {
            let disconnectedPhases = Set(["idle", "requested"])
            if disconnectedPhases.contains(phase) {
                violations.append(
                    DiagnosticsInvariantViolationCandidate(
                        invariantID: "selected.peer_wake_capable_ui_not_connectable",
                        scope: .backend,
                        message: "backend channel is connectable and peer wake is available, but selectedPeerPhase is still not connectable",
                        metadata: [
                            "selectedPeerPhase": phase,
                            "backendChannelStatus": backendChannelStatus,
                            "backendReadiness": backendReadiness,
                            "remoteWakeCapabilityKind": remoteWakeCapabilityKind,
                        ]
                    )
                )
            }
        }

        if phase == "waitingForPeer",
           isJoined == true,
           hadConnectedSessionContinuity == true,
           systemSession.hasPrefix("active("),
           backendSelfJoined == true,
           backendPeerJoined == true,
           backendPeerDeviceConnected == true,
           backendChannelStatus == "waiting-for-peer",
           remoteWakeCapabilityKind == "unavailable" {
            violations.append(
                DiagnosticsInvariantViolationCandidate(
                    invariantID: "selected.joined_session_lost_wake_capability",
                    scope: .backend,
                    message: "joined live session regressed to waiting-for-peer without wake capability",
                    metadata: [
                        "selectedPeerPhase": phase,
                        "systemSession": systemSession,
                        "backendChannelStatus": backendChannelStatus,
                        "backendReadiness": backendReadiness,
                        "remoteWakeCapabilityKind": remoteWakeCapabilityKind,
                    ]
                )
            )
        }

        return violations
    }

    private static func snapshotBool(_ fields: [String: String], key: String) -> Bool? {
        switch fields[key] {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private func refreshLatestErrorEntry(afterRecording entry: DiagnosticsEntry) {
        if entry.level == .error {
            latestErrorEntry = entry
            return
        }

        guard let latestErrorEntry else { return }
        if entries.contains(where: { $0.id == latestErrorEntry.id }) {
            return
        }

        self.latestErrorEntry = entries.first(where: { $0.level == .error })
    }
}

private struct DiagnosticsInvariantViolationCandidate {
    let invariantID: String
    let scope: DiagnosticsInvariantScope
    let message: String
    let metadata: [String: String]
}

private extension DiagnosticsLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .notice:
            return .default
        case .error:
            return .error
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    var formattedForLog: String {
        guard !isEmpty else { return "" }
        return map { "\($0)=\($1)" }.sorted().joined(separator: " ")
    }
}
