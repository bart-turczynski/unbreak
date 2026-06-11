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

    @Test("Preserves structural code indentation when line 1 is the outermost scope (§6.8)")
    func dedentPreservesStructuralCode() {
        // Line 1 (`def`) is the real left edge at column 0; the body's ≥3 distinct
        // indent levels (4, 8, 12) are genuine nesting, not a render gutter. De-gutter
        // must not mistake the 4-space body indent for a gutter and flatten structure.
        let input = "def f():\n    for x in y:\n        if x:\n            go(x)\n    return"
        let (out, changed) = Repair.degutter(input, tabWidth: 8)
        #expect(!changed)
        #expect(out == input)
    }

    @Test("A real gutter on every line (incl. line 1) over nested code still strips")
    func dedentStripsGutterOverNestedCode() {
        // A +2 render gutter prefixes line 1 too, so the indent common to all lines is
        // 2; stripping it removes the gutter while keeping the body's nesting intact.
        let input = "  def f():\n  a = 1\n      deep = 2"
        let (out, changed) = Repair.degutter(input, tabWidth: 8)
        #expect(changed)
        #expect(out == "def f():\na = 1\n    deep = 2")
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

    // MARK: §6.2 Prose reflow opt-in (whitespace-guttered, no bar — Option A)

    @Test("Off by default: a whitespace-guttered markdown block keeps the wrap break")
    func proseReflowOffByDefault() {
        // No `▎` bar, just a 2-space render gutter — the TUI hard-wrap case. With
        // default options (the watcher's path) the wrapped item stays broken.
        let input =
            "  - first item that the renderer wrapped onto a second visual row,\n"
            + "  continuing here\n"
            + "  - second item"
        let out = Repair.repair(input).text  // default: reflowParagraphs == false
        #expect(
            out == "- first item that the renderer wrapped onto a second visual row,\n"
                + "continuing here\n"
                + "- second item"
        )
    }

    @Test("Opted in: the wrapped markdown item reflows; sibling bullets stay separate")
    func proseReflowOptIn() {
        let input =
            "  - first item that the renderer wrapped onto a second visual row,\n"
            + "  continuing here\n"
            + "  - second item"
        let out = Repair.repair(input, options: .init(reflowParagraphs: true)).text
        #expect(
            out == "- first item that the renderer wrapped onto a second visual row, "
                + "continuing here\n"
                + "- second item"
        )
    }

    @Test("Opted in: a box-drawing table is never reflowed (subsumes the gate-6 guard)")
    func proseReflowSkipsTable() {
        // Uniform-width rows read as "full" to the word-fit test, but the seam guard
        // keeps every row on its own line even with the opt-in active.
        let input =
            "┌──────────┬───────┐\n"
            + "│ name     │ count │\n"
            + "│ alpha    │ 12    │\n"
            + "└──────────┴───────┘"
        let out = Repair.repair(input, options: .init(reflowParagraphs: true)).text
        #expect(out == input)
    }

    @Test("Opted in: a single wrapped bullet reflows (one marker is enough — CLAU-osmqojeq)")
    func proseReflowSingleWrappedBullet() {
        // The lone-bullet gap: §6.3 rejoin can't establish a column from one full
        // line, and the strict veto's ≥2-marker rule never fired. The permissive
        // trigger opts it in; the word-fit test merges the soft wrap.
        let input =
            "  - a single wrapped bullet item long enough to clear the forty-column reflow floor here\n"
            + "  and then some more"
        let out = Repair.repair(input, options: .init(reflowParagraphs: true)).text
        #expect(
            out == "- a single wrapped bullet item long enough to clear the "
                + "forty-column reflow floor here and then some more"
        )
    }

    @Test("Opted in: a short markered block stays put (width floor — no spurious merge)")
    func proseReflowWidthFloor() {
        // Max line width is below the wrap-column floor, so there is no evidence of
        // real wrapping — the block's longest line must not be treated as "full".
        let input = "- short one\nand two"
        let out = Repair.repair(input, options: .init(reflowParagraphs: true)).text
        #expect(out == input)
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

    @Test("Reflow keeps separate shell-chain commands on their own lines (F1)")
    func reflowKeepsShellCommandsApart() {
        // Two near-equal-width `&&` chains are distinct commands, not one wrapped
        // paragraph: the widest-line word-fit test would always merge them, so the
        // shell-chain guard keeps the intentional break (only the bar is stripped).
        let input =
            "  ▎ git tag v9 && git push origin v9 && gh release new\n"
            + "  ▎ make sign && make notarize && make upload && upload"
        let out = Repair.repair(input).text
        #expect(
            out == "git tag v9 && git push origin v9 && gh release new\n"
                + "make sign && make notarize && make upload && upload"
        )
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

    @Test("A line ending in a shell comment is never a wrap source (CLAU comment-merge)")
    func doesNotMergeIntoTrailingComment() {
        // Two distinct commands, each with an aligned trailing `# …` comment. They
        // read as same-width "full" lines, so without the comment guard rejoin
        // merged them — swallowing `brew services restart` into the first line's
        // comment (data loss). The break is intentional; both options must keep it.
        let input =
            "brew update && brew upgrade unbreak     # should download the bottle, not compile\n"
            + "brew services restart unbreak           # swap the resident watcher to v0.5.0"
        #expect(Repair.repair(input).text == input)
        #expect(Repair.repair(input, options: .init(reflowParagraphs: true)).text == input)
        // Even the aggressive full-collapse fallback must not comment a command out.
        #expect(Repair.repair(input, options: .init(joinAll: true)).text == input)
        // And the watcher (default options) must not mutate it at all.
        #expect(!Repair.repair(input).report.changed)
    }

    @Test("endsWithComment: unquoted word-boundary # only")
    func endsWithCommentDetector() {
        #expect(Repair.endsWithComment("brew install foo     # a comment"))
        #expect(Repair.endsWithComment("# whole-line comment"))
        #expect(Repair.endsWithComment("make test #c"))
        // Not comments: inside quotes, mid-token, or after a non-space char.
        #expect(!Repair.endsWithComment("echo 'not # a comment'"))
        #expect(!Repair.endsWithComment("echo \"still # fine\""))
        #expect(!Repair.endsWithComment("open https://example.com/page#section"))
        #expect(!Repair.endsWithComment("echo ${#array[@]}"))
        #expect(!Repair.endsWithComment("plain command with no hash"))
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

    @Test("Case 4: a token char-wrapped across full lines rejoins with no space")
    func case4MidTokenRejoin() {
        // Three space-free fragments at the wrap column: a run of ≥2 full solid
        // lines marks them as one token, so the seams (including onto the short
        // final remainder) join with no space — never injecting a corrupting space.
        let head = String(repeating: "a", count: 42)
        let mid = String(repeating: "b", count: 42)
        let result = Repair.rejoin(
            "\(head)\n\(mid)\nccc",
            profile: .claudeCode,
            options: .init(forcedWidth: 42)
        )
        #expect(result.text == head + mid + "ccc")
    }

    @Test("Case 4: a lone full token line + short line stays a single-space word join")
    func case4TwoLineAmbiguityKeepsSpace() {
        // One full solid line then a short line is indistinguishable from a long word
        // that fit exactly, then an ordinary word wrap — so the conservative join
        // (a single space, §5 case 1) wins rather than risk gluing two words.
        let head = String(repeating: "a", count: 42)
        let result = Repair.rejoin(
            head + "\nshort",
            profile: .claudeCode,
            options: .init(forcedWidth: 42)
        )
        #expect(result.text == head + " short")
    }

    @Test("Box-drawing table rows are never rejoined into one line (F5)")
    func boxDrawingTableNotSmushed() {
        // Uniform-width rows read as "full", but box-drawing newlines are structural.
        let table =
            "┌──────────┬──────────┐\n"
            + "│ alpha    │ bravo    │\n"
            + "│ charlie  │ delta    │\n"
            + "└──────────┴──────────┘"
        #expect(Repair.repair(table).text == table)
    }
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

    @Test("Wrap-width detection clusters near-equal widths within ±2 (F3)")
    func detectWidthTolerance() {
        // Uneven word-wraps rarely land on the exact same cell, so widths within the
        // same ±2 band as `isFull` form one cluster; W is the top of the band.
        #expect(Repair.detectWidth([94, 95, 35]) == 95)
        #expect(Repair.detectWidth([95, 94, 93, 40]) == 95)
        // A trailing blank line (from a final newline) is ignored, not counted as the
        // remainder.
        #expect(Repair.detectWidth([94, 95, 35, 0]) == 95)
    }

    @Test("Wrap-width detection accepts a single full line only on a 2-line wrap (F2)")
    func detectWidthTwoLine() {
        // One full line wide enough to be a column + a strictly shorter remainder.
        #expect(Repair.detectWidth([139, 52]) == 139)
        #expect(Repair.detectWidth([139, 52, 0]) == 139)
        // Too narrow to trust a lone candidate, or the "remainder" is not shorter →
        // not a wrap (the latter guards a quote-bar reflow's intentional break).
        #expect(Repair.detectWidth([30, 12]) == nil)
        #expect(Repair.detectWidth([118, 140]) == nil)
        // Three lines with no repeated/clustered width stay ambiguous → nil.
        #expect(Repair.detectWidth([139, 60, 52]) == nil)
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
