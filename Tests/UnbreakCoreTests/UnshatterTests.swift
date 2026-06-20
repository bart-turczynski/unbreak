import Testing

@testable import UnbreakCore

@Suite("Box-table un-shatter (PRD v2 §6 — cmux capture)")
struct UnshatterTests {
    private let profile = WrapProfile.claudeCode

    // A minimal three-row table whose rows the renderer merged onto one physical
    // line behind padding runs (a top border, a data row, a bottom border).
    private let mergedTable =
        "┌────┬────┐          │ a  │ b  │          └────┴────┘"
    private let cleanTable = """
        ┌────┬────┐
        │ a  │ b  │
        └────┴────┘
        """

    @Test("A merged-row seam (box↔box padding) splits back into rows")
    func splitsMergedRows() {
        let (out, changed) = Unshatter.unshatter(mergedTable, profile: profile)
        #expect(changed)
        #expect(out == cleanTable)
    }

    @Test("A cleanly copied table is left untouched (no seam to act on)")
    func cleanTableUntouched() {
        let (out, changed) = Unshatter.unshatter(cleanTable, profile: profile)
        #expect(!changed)
        #expect(out == cleanTable)
    }

    @Test("An empty cell (│…│) is never mistaken for a row seam")
    func emptyCellNotSplit() {
        // Both flanks of the wide run are `│`, so it is an empty cell, not a seam.
        let emptyCell = "│        │                      │"
        #expect(Unshatter.seams(in: emptyCell).isEmpty)
        let (out, changed) = Unshatter.unshatter(emptyCell, profile: profile)
        #expect(!changed)
        #expect(out == emptyCell)
    }

    @Test("Plain prose with no box drawing is never touched")
    func proseUntouched() {
        let prose = "the quick brown fox\njumped over the lazy dog"
        let (out, changed) = Unshatter.unshatter(prose, profile: profile)
        #expect(!changed)
        #expect(out == prose)
    }

    @Test("Split pieces inherit the first piece's leading indent")
    func piecesInheritIndent() {
        // The merged line is indented two columns; every recovered row keeps it.
        let merged = "  ┌──┐          │ x│          └──┘"
        let (out, _) = Unshatter.unshatter(merged, profile: profile)
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(line.hasPrefix("  "), "row lost its margin: \(line)")
        }
    }

    @Test("Deep leading padding is pulled to the modal indent — only given a seam")
    func depadsOutliersWhenShattered() {
        // A right-shifted prose line (100-space lead) sharing a copy with a shattered
        // table is pulled back to the block's modal indent (2). The table seam is
        // what licenses the de-pad.
        let pad = String(repeating: " ", count: 100)
        let block = "  context line\n\(pad)shifted line\n  ┌──┐\(pad)└──┘"
        let (out, changed) = Unshatter.unshatter(block, profile: profile)
        #expect(changed)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains("  shifted line"))
        #expect(!out.contains(pad), "a render-padding run survived de-pad")
    }

    @Test("Deep indentation is preserved when there is no shattered table")
    func noDepadWithoutSeam() {
        // The same deep indent with no box seam anywhere is authored structure and
        // must survive verbatim (self-gating).
        let pad = String(repeating: " ", count: 100)
        let block = "  context line\n\(pad)deeply nested line"
        let (out, changed) = Unshatter.unshatter(block, profile: profile)
        #expect(!changed)
        #expect(out == block)
    }

    @Test("Un-shatter is idempotent")
    func idempotent() {
        let (once, _) = Unshatter.unshatter(mergedTable, profile: profile)
        let (twice, changedAgain) = Unshatter.unshatter(once, profile: profile)
        #expect(!changedAgain)
        #expect(once == twice)
    }
}

@Suite("Watch mode fixes a cmux-shattered table via the §7.4 fast path")
struct UnshatterWatchTests {
    // The real capture: a Claude message whose table cmux flattened onto merged
    // lines, copied from an allowlisted terminal.
    private let capture =
        "┌────┬────┐          │ a  │ b  │          ├────┼────┤          │ c  │ d  │          └────┴────┘"

    @Test("The shattered-table repair sets report.tableUnshattered")
    func reportFlagSet() {
        let report = Repair.repair(capture).report
        #expect(report.tableUnshattered)
        #expect(report.structuralChange)
        #expect(!report.dedentOnly, "an un-shatter is more than a pure dedent")
    }

    @Test("The watcher mutates a shattered table that the structure gate would veto")
    func watcherMutatesViaFastPath() {
        let report = Repair.repair(capture).report
        let decision = WatchGate.decide(
            clipboard: capture,
            isPlainText: true,
            frontmostBundleID: "com.cmuxterm.app",
            report: report
        )
        #expect(decision.shouldMutate)
        #expect(decision.viaGutterFastPath)
        #expect(decision.fastPathReason == "table-unshatter")
        // A waivable content gate (shell-signal §7.5 or structure-risk §7.6) really
        // did fail — the fast path is what let the mutation through anyway.
        let waivedAFailure = decision.outcomes.contains {
            ($0.gate == .shellSignal || $0.gate == .structureRiskClear) && !$0.passed
        }
        #expect(waivedAFailure)
    }
}
