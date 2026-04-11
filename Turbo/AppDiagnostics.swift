import Foundation
import Observation
import OSLog

struct SelectedSessionDiagnosticsSummary: Equatable {
    let selectedHandle: String?
    let selectedPhase: String
    let relationship: String
    let statusMessage: String
    let canTransmitNow: Bool
    let isJoined: Bool
    let isTransmitting: Bool
    let activeChannelID: String?
    let pendingAction: String
    let systemSession: String
    let mediaState: String
    let backendChannelStatus: String?
    let backendSelfJoined: Bool?
    let backendPeerJoined: Bool?
    let backendPeerDeviceConnected: Bool?
    let backendCanTransmit: Bool?
}

struct ContactDiagnosticsSummary: Equatable, Identifiable {
    let handle: String
    let listState: String
    let badgeStatus: String?
    let hasIncomingRequest: Bool
    let hasOutgoingRequest: Bool
    let requestCount: Int
    let incomingInviteCount: Int?
    let outgoingInviteCount: Int?

    var id: String { handle }
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
            "joined=\(fields["isJoined"] ?? "false")",
            "transmitting=\(fields["isTransmitting"] ?? "false")",
            "system=\(fields["systemSession"] ?? "none")",
            "backendChannel=\(fields["backendChannelStatus"] ?? "none")",
            "backendSelfJoined=\(fields["backendSelfJoined"] ?? "none")",
            "backendPeerJoined=\(fields["backendPeerJoined"] ?? "none")",
            "peerDevice=\(fields["backendPeerDeviceConnected"] ?? "none")",
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
    private let logFileURL: URL?
    private static let iso8601TimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private(set) var entries: [DiagnosticsEntry] = []
    private(set) var stateCaptures: [DiagnosticsStateCapture] = []

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
        entries.first(where: { $0.level == .error })
    }

    var logFilePath: String? {
        logFileURL?.path
    }

    func record(
        _ subsystem: DiagnosticsSubsystem,
        level: DiagnosticsLevel = .info,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let entry = DiagnosticsEntry(subsystem: subsystem, level: level, message: message, metadata: metadata)
        entries.insert(entry, at: 0)
        if entries.count > entryLimit {
            entries.removeLast(entries.count - entryLimit)
        }
        logger.log(level: level.osLogType, "\(subsystem.rawValue, privacy: .public): \(message, privacy: .public) \(metadata.formattedForLog, privacy: .public)")
        appendToDisk(entry)
    }

    func clear() {
        entries.removeAll()
        stateCaptures.removeAll()
        guard let logFileURL else { return }
        try? Data().write(to: logFileURL, options: .atomic)
    }

    func captureState(reason: String, fields: [String: String]) {
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
