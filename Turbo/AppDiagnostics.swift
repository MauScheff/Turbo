import Foundation
import Observation
import OSLog

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

@MainActor
@Observable
final class DiagnosticsStore {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Turbo", category: "diagnostics")
    private let entryLimit = 200
    private let logFileURL: URL?

    private(set) var entries: [DiagnosticsEntry] = []

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
        guard let logFileURL else { return }
        try? Data().write(to: logFileURL, options: .atomic)
    }

    func exportText(snapshot: String? = nil) -> String {
        var sections: [String] = []
        if let snapshot, !snapshot.isEmpty {
            sections.append("STATE SNAPSHOT\n\(snapshot)")
        }

        if entries.isEmpty {
            sections.append("DIAGNOSTICS\n<empty>")
        } else {
            let lines = entries.map { entry in
                let timestamp = entry.timestamp.formatted(date: .omitted, time: .standard)
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
        let timestamp = entry.timestamp.formatted(date: .omitted, time: .standard)
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
