import Foundation
import UnbreakCore

/// Content-safe observability for watch mode (PRD v2 §7.3).
///
/// Every gate decision is logged — what the watcher saw and what it did — but
/// **never the clipboard contents**. The log line carries the frontmost bundle
/// id, the per-decision summary (`decision`/`blocked`/`bytes`/`lines`), and the
/// `RepairReport` signal floats, all of which are derived metadata, not payload.
public protocol WatchLog: AnyObject {
    func record(_ line: String)
}

extension WatchLog {
    /// Compose and record a single content-safe decision line (§7.3).
    ///
    /// - Parameters:
    ///   - timestamp: ISO-8601 instant for the line (injected so callers control
    ///     the clock — keeps this testable).
    ///   - frontmostBundleID: the gate-1 app context, or `nil` if unknown.
    ///   - decision: the §7 gate decision (its `logSummary` is already content-safe).
    ///   - report: the §6 repair report — only its signal floats are logged.
    public func recordDecision(
        timestamp: String,
        frontmostBundleID: String?,
        decision: WatchGate.Decision,
        report: RepairReport
    ) {
        let frontmost = frontmostBundleID ?? "unknown"
        let signals =
            "wrapConf="
            + String(format: "%.2f", report.wrapColumnConfidence)
            + " shell=" + String(format: "%.2f", report.shellSignalScore)
            + " struct=" + String(format: "%.2f", report.structureRisk)
        record("\(timestamp) frontmost=\(frontmost) \(decision.logSummary) \(signals)")
    }
}

/// Appends lines to `~/Library/Logs/unbreak.log` (PRD v2 §7.3, §8.3 — a real log
/// file, not world-writable `/tmp`). Each `record` opens, appends, and closes so
/// the file can be rotated or tailed without holding a handle open for the life
/// of the daemon.
public final class FileLog: WatchLog {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The default location: `~/Library/Logs/unbreak.log`.
    public static func defaultLog() -> FileLog {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return FileLog(url: logs.appendingPathComponent("unbreak.log"))
    }

    public func record(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // File does not exist yet — create it with this first line.
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Collects lines in memory. For tests and `--dry-run-watch` piping.
public final class CollectingLog: WatchLog {
    public private(set) var lines: [String] = []
    public init() {}
    public func record(_ line: String) { lines.append(line) }
}
