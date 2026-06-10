import Testing

@testable import UnbreakCore

@Suite("Repair pipeline (PRD v2 §6)")
struct RepairTests {
    // MARK: §6.1 Normalize

    @Test("CRLF and CR collapse to LF")
    func normalizesNewlines() {
        #expect(Repair.normalize("a\r\nb\rc") == "a\nb\nc")
    }

    @Test("Strips ANSI SGR color sequences (§6.1)")
    func stripsSGR() {
        // Red "git status" reset — the escapes must not survive or count as width.
        #expect(Repair.normalize("\u{1B}[31mgit status\u{1B}[0m") == "git status")
    }

    @Test("Strips a multi-parameter CSI sequence (§6.1)")
    func stripsCSI() {
        #expect(Repair.normalize("a\u{1B}[1;32;40mb") == "ab")
    }

    @Test("Strips an OSC52 clipboard sequence terminated by BEL (§6.1, §13)")
    func stripsOSC52BEL() {
        #expect(Repair.normalize("\u{1B}]52;c;Zm9v\u{07}echo hi") == "echo hi")
    }

    @Test("Strips an OSC sequence terminated by ST (ESC backslash) (§6.1)")
    func stripsOSCWithST() {
        #expect(Repair.normalize("\u{1B}]0;title\u{1B}\\ls") == "ls")
    }

    @Test("Escape bytes do not count as display columns after normalize (§6.1)")
    func escapesDoNotCountAsWidth() {
        let colored = "\u{1B}[32m" + String(repeating: "x", count: 42) + "\u{1B}[0m"
        #expect(DisplayWidth.width(of: Repair.normalize(colored)) == 42)
    }

    // MARK: §6.2 De-gutter

    @Test("Removes the common gutter, preserving relative indent among lines 2..n (§5 cases 2/6)")
    func dedentRemovesGutterKeepsRelativeIndent() {
        // Gutter = minimum indent of the continuation lines (4). Stripping it
        // keeps the 4-space nesting difference between the two of them.
        let input = "git clone foo\n    && cd foo\n        && nested"
        let (out, changed) = Repair.degutter(input, tabWidth: 8)
        #expect(changed)
        #expect(out == "git clone foo\n&& cd foo\n    && nested")
    }

    @Test("Excludes a partially selected first line from gutter detection (§5 case 3)")
    func dedentExcludesPartialFirstLine() {
        // Line 1 has only 1 leading space (partial selection); the gutter (4) is
        // computed from lines 2..n, and line 1 loses only min(1, 4) = 1 space.
        let input = " git push\n    --force\n    origin"
        let (out, _) = Repair.degutter(input, tabWidth: 8)
        #expect(out == "git push\n--force\norigin")
    }

    // MARK: §6.2 Quote-bar gutter (Claude Code queued-prompt box)

    @Test("Strips the `  ▎ ` quote-bar gutter from every line")
    func stripsQuoteBarGutter() {
        let input = "  ▎ first line\n  ▎ second line\n  ▎ third line"
        let (out, changed) = Repair.stripGutterBars(input, profile: .claudeCode)
        #expect(changed)
        #expect(out == "first line\nsecond line\nthird line")
    }

    @Test("A bare `  ▎` separator line collapses to empty, preserving the paragraph break")
    func stripsQuoteBarSeparatorLine() {
        let input = "  ▎ one\n  ▎\n  ▎ two"
        let (out, _) = Repair.stripGutterBars(input, profile: .claudeCode)
        #expect(out == "one\n\ntwo")
    }

    @Test("Content past the single padding space keeps its own indentation")
    func stripsQuoteBarKeepsContentIndent() {
        // Only the margin + bar + one padding space is the gutter; further spaces
        // are the content's own indentation and survive.
        let input = "  ▎ def f():\n  ▎     return 1"
        let (out, _) = Repair.stripGutterBars(input, profile: .claudeCode)
        #expect(out == "def f():\n    return 1")
    }

    @Test("A stray bar glyph in ordinary content does not trigger stripping")
    func leavesStrayBarUntouched() {
        // Only one of three non-blank lines opens with a bar — below the two-thirds
        // majority, so nothing is stripped ("when in doubt, don't act").
        let input = "draw a ▎ here\nplain line two\nplain line three"
        let (out, changed) = Repair.stripGutterBars(input, profile: .claudeCode)
        #expect(!changed)
        #expect(out == input)
    }

    @Test("A profile with no gutter bars never strips")
    func noBarsConfiguredIsNoOp() {
        let plain = WrapProfile(name: "plain", continuationTokens: [])
        let input = "  ▎ one\n  ▎ two"
        let (out, changed) = Repair.stripGutterBars(input, profile: plain)
        #expect(!changed)
        #expect(out == input)
    }

    @Test("Stripping the quote-bar gutter is idempotent through the full pipeline")
    func quoteBarRepairIdempotent() {
        let input = "  ▎ alpha bravo charlie\n  ▎ delta echo foxtrot"
        let once = Repair.repair(input).text
        let twice = Repair.repair(once).text
        #expect(once == twice)
        #expect(!once.contains("\u{258E}"))
    }

    // MARK: §6.2 Quote-bar reflow

    @Test("A soft-wrapped paragraph in a bar block reflows to one line")
    func reflowsWrappedParagraph() {
        // Each next line's first word would not have fit above, so all are soft wraps.
        let input =
            "  ▎ the quick brown fox jumped over the\n"
            + "  ▎ lazy dog while the whole sleepy town\n"
            + "  ▎ kept dreaming."
        let out = Repair.repair(input).text
        #expect(
            out == "the quick brown fox jumped over the lazy dog "
                + "while the whole sleepy town kept dreaming."
        )
    }

    @Test("Blank bar lines stay as paragraph breaks; each paragraph reflows on its own")
    func reflowKeepsParagraphBreaks() {
        let input =
            "  ▎ alpha beta gamma delta epsilon zeta\n"
            + "  ▎ eta theta.\n"
            + "  ▎\n"
            + "  ▎ iota kappa lambda mu nu xi omicron\n"
            + "  ▎ pi rho."
        let out = Repair.repair(input).text
        #expect(
            out == "alpha beta gamma delta epsilon zeta eta theta.\n\n"
                + "iota kappa lambda mu nu xi omicron pi rho."
        )
    }

    @Test("List items in a bar block survive, even when as wide as a wrapped line")
    func reflowPreservesListItems() {
        // No blank lines and each item is near the wrap width, so only the list
        // marker distinguishes these intentional breaks from soft wraps.
        let input =
            "  ▎ Tasks to work through in priority order today:\n"
            + "  ▎ - audit the tokenizer for the off-by-one slip\n"
            + "  ▎ - add a regression test pinning the fixed output\n"
            + "  ▎ - open the PR and link the tracking issue"
        let out = Repair.repair(input).text
        #expect(
            out == "Tasks to work through in priority order today:\n"
                + "- audit the tokenizer for the off-by-one slip\n"
                + "- add a regression test pinning the fixed output\n"
                + "- open the PR and link the tracking issue"
        )
    }

    @Test("List-marker detection: bullets and ordered markers vs flags")
    func listMarkerDetection() {
        #expect(Repair.startsWithListMarker("- item"))
        #expect(Repair.startsWithListMarker("  * item"))
        #expect(Repair.startsWithListMarker("+ item"))
        #expect(Repair.startsWithListMarker("1. item"))
        #expect(Repair.startsWithListMarker("12) item"))
        // A flag/option is NOT a bullet — no space after the dash run.
        #expect(!Repair.startsWithListMarker("--workdir /work"))
        #expect(!Repair.startsWithListMarker("-x"))
        #expect(!Repair.startsWithListMarker("1.5 release"))
        #expect(!Repair.startsWithListMarker("plain text"))
    }

    @Test("Reflow leaves a wrapped command's flags joinable (no false bullet)")
    func reflowJoinsCommandFlags() {
        // `--workdir` must not be read as a list marker, so the flag rejoins.
        let input = "  ▎ docker run --rm --volume \"$PWD\":/work\n  ▎ --workdir /work img"
        let out = Repair.repair(input).text
        #expect(out == "docker run --rm --volume \"$PWD\":/work --workdir /work img")
    }

    // MARK: §6.3 Rejoin

    @Test("Rejoins a word-boundary wrap with a single space (§5 case 1)")
    func rejoinSingleSpace() {
        // First line is full (width 42 == W) and ends in a normal character, not
        // a continuation token, so the next line is rejoined with one space.
        let head = String(repeating: "x", count: 42)
        let result = Repair.rejoin(
            head + "\n/tmp/out.json",
            profile: .claudeCode,
            options: .init(forcedWidth: 42)
        )
        #expect(result.text == head + " /tmp/out.json")
    }

    @Test("Leaves explicit `\\` continuations as separate lines (§5 case 6)")
    func preservesBackslashContinuation() {
        let input = String(repeating: "y", count: 42) + " \\\nnext line"
        let result = Repair.rejoin(
            input,
            profile: .claudeCode,
            options: .init(forcedWidth: 44)
        )
        #expect(result.text == input)
    }

    // MARK: §6.8 Structure preservation (§5 Cases 3/4/6 round-trips)

    @Test("Case 3: a partially selected first line dedents to the continuation gutter")
    func case3PartialFirstLineRoundTrip() {
        // Line 1 has 1 leading space; the gutter (4) comes from lines 2..n.
        let input = " git push\n    --force\n    origin"
        #expect(Repair.repair(input).text == "git push\n--force\norigin")
    }

    @Test("Case 4: an unbreakable long token (URL) is left intact")
    func case4UnbreakableToken() {
        // No interior space to wrap at → nothing to rejoin or split.
        let url = "https://example.com/" + String(repeating: "a", count: 120)
        #expect(Repair.repair(url).text == url)
    }

    @Test("Case 6: a `\\` continuation layout is never rejoined into one line")
    func case6BackslashLayoutRoundTrip() {
        // De-gutter may strip a uniform leading indent (indistinguishable from the
        // render gutter), but the `\`-terminated newlines must survive — the lines
        // are never merged.
        let input = "docker run --rm \\\n  -v $PWD:/app \\\n  image:latest"
        let out = Repair.repair(input).text
        #expect(out.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
        #expect(out.contains("--rm \\"))
        #expect(out.contains("image:latest"))
    }

    @Test("Case 6: a heredoc body keeps its intentional internal spacing")
    func case6HeredocInternalSpacing() {
        let input = "cat <<EOF\n  col1    col2\n  data    here\nEOF"
        let result = Repair.repair(input)
        #expect(result.text == input)
        #expect(result.report.heredocDetected)
    }

    @Test("Case 6: internal multiple spaces outside a wrap seam are preserved")
    func case6InternalSpaces() {
        let input = "echo a    b    c"
        #expect(Repair.repair(input).text == input)
    }

    // MARK: §6.8 Guarantees

    @Test("Clean single-line input is returned unchanged")
    func cleanSingleLineUnchanged() {
        let input = "git status"
        #expect(Repair.repair(input).text == input)
    }

    @Test("Clean short multi-line input is returned unchanged")
    func cleanMultiLineUnchanged() {
        let input = "line one\nline two\nline three"
        #expect(Repair.repair(input).text == input)
    }

    @Test("Idempotent: repairing twice equals repairing once")
    func idempotent() {
        let wrapped = [
            String(repeating: "a", count: 42),
            String(repeating: "b", count: 42),
            "tail",
        ].joined(separator: "\n")
        let once = Repair.repair(wrapped, options: .init(forcedWidth: 42)).text
        let twice = Repair.repair(once, options: .init(forcedWidth: 42)).text
        #expect(once == twice)
    }

    @Test("Wrap-width detection breaks count ties deterministically (largest width)")
    func detectWidthTieBreak() {
        // Two widths share the top count (2 each). The detected column must be a
        // pure function of the input, not of per-process Dictionary order — pick
        // the larger width. (Regression: this tie made repair flakily non-idempotent
        // across process launches, §6.8.)
        #expect(Repair.detectWidth([100, 100, 45, 45, 17]) == 100)
        #expect(Repair.detectWidth([45, 45, 100, 100, 17]) == 100)
        // Same multiset, different order → same answer.
        #expect(Repair.detectWidth([30, 70, 70, 30]) == 70)
    }

    @Test("A count tie does not make repair flaky across runs (§6.8)")
    func tiedWidthsAreIdempotent() {
        // Mirrors the seed-436 fuzz case: two long unbreakable URL-like lines tie
        // with two shorter full lines. Whatever column is chosen, it must be chosen
        // the same way every time, so a second pass is a no-op.
        let input = [
            "https://example.com/" + String(repeating: "a", count: 80),
            "https://example.com/" + String(repeating: "a", count: 80),
            String(repeating: "y", count: 40) + " tail",
            String(repeating: "y", count: 40) + " tail",
            "heredoc body line",
        ].joined(separator: "\n")
        let once = Repair.repair(input).text
        let twice = Repair.repair(once).text
        #expect(once == twice)
    }
}
