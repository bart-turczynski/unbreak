import Foundation
import Testing

@testable import UnbreakCore

/// PRD v2 §13 validation suite.
///
/// Two halves of the same guarantee:
///  - **Zero watch-mode mutations** on a corpus of normal copies (the §2 goal,
///    operationalized): for every safe fixture, in every allowlisted terminal,
///    the six-gate pipeline (§7) must decide *skip*. The fixtures are column-0
///    (no uniform render gutter), so the §7.4 safe-dedent fast path is a no-op on
///    them — the refined contract ("zero *rejoin/split* mutations; a uniform
///    render-gutter strip is allowed") still yields zero mutations here. A
///    guttered-table case that *does* fast-path-mutate lives in `WatchGateTests`.
///  - **Golden repair captures** per §5 case type: raw mangled fragments repair to
///    a known-good form, idempotently, and the watcher acts only on the ones it
///    should.
///
/// The fixtures live on disk under `Fixtures/` so real captures keep their exact
/// bytes (ANSI/OSC/tabs/CJK), which a Swift string literal would not preserve.

@Suite("Zero watch-mode mutations on the safe corpus (PRD v2 §2/§13)")
struct ZeroMutationCorpusTests {
    /// Every allowlisted terminal — the gate-1 worst case. If a fixture is going to
    /// wrongly mutate, it does so precisely when the frontmost app is a terminal we
    /// watch, so we prove the *content* gates (4/5/6) hold for each of them.
    static let terminals = Array(WatchGate.Config.defaultTerminalAllowlist).sorted()

    @Test("The safe corpus is present and non-trivial")
    func corpusLoaded() {
        let safe = FixtureLoader.load("safe")
        // A wrong resource path would silently load nothing and make every
        // per-fixture test vacuously pass — guard against that.
        #expect(safe.count >= 12, "expected the full §13 safe corpus, got \(safe.count)")
    }

    @Test(
        "Each safe fixture yields decision=skip in every allowlisted terminal",
        arguments: FixtureLoader.load("safe")
    )
    func safeFixtureNeverMutates(_ fixture: FixtureLoader.Fixture) {
        let report = Repair.repair(fixture.text).report
        for terminal in Self.terminals {
            let decision = WatchGate.decide(
                clipboard: fixture.text,
                isPlainText: true,
                frontmostBundleID: terminal,
                report: report
            )
            #expect(
                !decision.shouldMutate,
                "fixture '\(fixture.name)' would mutate in \(terminal): \(decision.logSummary)"
            )
        }
    }
}

@Suite("Golden repair captures per §5 case type (PRD v2 §13)")
struct GoldenRepairTests {
    static let pairs = FixtureLoader.goldenPairs(tool: "claude-code")

    @Test("All six §5 case-type captures are present")
    func allCaseTypesPresent() {
        let names = Set(Self.pairs.map(\.caseName))
        #expect(
            names.isSuperset(of: [
                "long-wrap", "inline", "multiline-backslash", "heredoc", "long-token",
                "nested-merge",
            ])
        )
    }

    @Test("Each capture repairs to its golden form", arguments: GoldenRepairTests.pairs)
    func repairsToGolden(_ pair: FixtureLoader.GoldenPair) {
        #expect(
            Repair.repair(pair.input).text == pair.expected,
            "repair drift on '\(pair.caseName)'"
        )
    }

    @Test("Repairing a capture is idempotent", arguments: GoldenRepairTests.pairs)
    func idempotent(_ pair: FixtureLoader.GoldenPair) {
        let once = Repair.repair(pair.input).text
        let twice = Repair.repair(once).text
        #expect(once == twice, "second pass changed '\(pair.caseName)'")
    }
}

@Suite("§13 assert-specifics over the golden captures")
struct RepairSpecificsTests {
    private func golden(_ name: String) -> String {
        FixtureLoader.goldenPairs(tool: "claude-code").first { $0.caseName == name }!.expected
    }

    @Test("Single-space rejoin: a wrapped command collapses to one line, no double spaces")
    func singleSpaceRejoin() {
        for name in ["long-wrap", "inline"] {
            let out = golden(name)
            #expect(!out.dropLast().contains("\n"), "'\(name)' should be a single line")
            #expect(!out.contains("  "), "'\(name)' has a double space at a seam")
        }
    }

    @Test("Gutter removal preserves relative indent")
    func gutterRemovalKeepsRelativeIndent() {
        // The +gutter is stripped (the loop header sits at column 0) but the body's
        // 4-space nesting relative to it survives; `done` returns to column 0.
        let lines = golden("nested-merge").split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "for f in *.swift; do")
        #expect(lines.contains("    swift-format --in-place \"$f\""))
        #expect(lines.contains("    git add \"$f\""))
        #expect(lines.contains("done"))
    }

    @Test("Heredoc bodies are left untouched")
    func heredocUntouched() {
        let pair = FixtureLoader.goldenPairs(tool: "claude-code").first {
            $0.caseName == "heredoc"
        }!
        // The whole capture round-trips unchanged, and the body keeps its indent.
        #expect(pair.expected == pair.input)
        #expect(Repair.repair(pair.input).report.heredocDetected)
        #expect(pair.expected.contains("\n  remember to bump"))
    }

    @Test("Merge-split stays off unless explicitly opted in (§5 case 5 / §6.5)")
    func mergeSplitOptIn() {
        // A line that ran past the wrap column W and absorbed a fresh statement
        // behind a padding run — the lossy §5-case-5 artifact.
        let left = String(repeating: "x", count: 44)
        let merged = left + "   make test && make lint"

        // Off by default: the merged line is left exactly as-is.
        let byDefault = Repair.repair(merged, options: .init(forcedWidth: 42))
        #expect(byDefault.text == merged, "default repair must not split padding artifacts")

        // Opt-in: the hidden statement boundary is restored.
        let opted = Repair.repair(
            merged,
            options: .init(forcedWidth: 42, splitPaddingArtifacts: true)
        )
        #expect(opted.text == left + "\nmake test && make lint")
    }
}

@Suite("Watch mode acts only on the captures it should (PRD v2 §7/§13)")
struct WatchTruePositiveTests {
    let terminal = "com.apple.Terminal"

    private func decision(for input: String) -> WatchGate.Decision {
        WatchGate.decide(
            clipboard: input,
            isPlainText: true,
            frontmostBundleID: terminal,
            report: Repair.repair(input).report
        )
    }

    private func capture(_ name: String) -> String {
        FixtureLoader.goldenPairs(tool: "claude-code").first { $0.caseName == name }!.input
    }

    @Test(
        "Mangled command captures pass all six gates in an allowlisted terminal",
        arguments: ["long-wrap", "inline", "nested-merge"]
    )
    func repairableCapturesMutate(_ name: String) {
        let d = decision(for: capture(name))
        #expect(d.shouldMutate, "'\(name)' should mutate: \(d.logSummary)")
    }

    @Test(
        "Captures the repair leaves unchanged are never mutated",
        arguments: ["heredoc", "long-token"]
    )
    func unchangedCapturesSkip(_ name: String) {
        let d = decision(for: capture(name))
        #expect(!d.shouldMutate)
        #expect(d.blockingGate == .repairChangedContent)
    }
}
