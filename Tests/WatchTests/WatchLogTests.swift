import Testing
import UnbreakCore

@testable import Watch

@Suite("WatchLog content-safe formatting (PRD v2 §7.3)")
struct WatchLogTests {
    @Test("recordDecision emits timestamp, frontmost, summary, and signal floats")
    func formatsDecision() {
        let log = CollectingLog()
        let decision = WatchGate.decide(
            clipboard: "git pull && make",
            isPlainText: true,
            frontmostBundleID: "com.apple.Terminal",
            report: RepairReport(changed: true)
        )
        log.recordDecision(
            timestamp: "2026-06-06T12:00:00Z",
            frontmostBundleID: "com.apple.Terminal",
            decision: decision,
            report: RepairReport(changed: true, shellSignalScore: 0.9, structureRisk: 0.1)
        )
        let line = log.lines[0]
        #expect(line.hasPrefix("2026-06-06T12:00:00Z"))
        #expect(line.contains("frontmost=com.apple.Terminal"))
        #expect(line.contains("decision=mutate"))
        #expect(line.contains("shell=0.90"))
        #expect(line.contains("struct=0.10"))
    }

    @Test("Unknown frontmost is rendered as 'unknown', not nil")
    func unknownFrontmost() {
        let log = CollectingLog()
        let decision = WatchGate.decide(
            clipboard: "x",
            isPlainText: true,
            frontmostBundleID: nil,
            report: RepairReport(changed: false)
        )
        log.recordDecision(
            timestamp: "t",
            frontmostBundleID: nil,
            decision: decision,
            report: RepairReport(changed: false)
        )
        #expect(log.lines[0].contains("frontmost=unknown"))
    }
}
