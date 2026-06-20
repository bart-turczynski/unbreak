import Foundation

/// The pure, deterministic repair pipeline (PRD v2 §6):
///
///   normalize → (de-gutter → rejoin)* → optional merge-split → (String, RepairReport)
///
/// No I/O, no globals, no clipboard access. The CLI and the watcher both call
/// `repair(_:profile:options:)` and decide what to do from the returned report.
///
/// Implemented: §6.1 normalize (ANSI/OSC stripping + CRLF/CR), §6.2 de-gutter,
/// §6.3 rejoin, §6.4 heredoc protection, §6.5 merge-split (opt-in), §6.7
/// confidence signals. The de-gutter/rejoin core is iterated to a fixed point so
/// the whole function is idempotent (§6.8).
/// TODO: §6.6 non-Claude profiles.
public enum Repair {
    public static func repair(
        _ input: String,
        profile: WrapProfile = .claudeCode,
        options: RepairOptions = .init()
    ) -> RepairResult {
        let normalized = normalize(input)

        // §6.2 (quote-bar variant): strip a leading "quote bar" gutter (e.g. Claude
        // Code's `  ▎ ` queued-prompt box) once, before the loop. The whitespace
        // de-gutter below only removes spaces/tabs, so without this the bar survives
        // on every line — and a residual `▎ ` prefix also throws off wrap detection,
        // leaving the paste both ugly and unjoined. Stripping is idempotent (no line
        // opens with the bar afterwards), so running it once outside the loop is
        // sufficient and keeps `repair` a fixed point.
        let (barStripped, barChanged) = stripGutterBars(normalized, profile: profile)

        // §6.2 (reflow): once a bar gutter is confirmed we know the block is a
        // display box the CLI soft-wrapped to a fixed column, so reflow each
        // paragraph back to one line. The explicit one-shot CLI (Option A) opts a
        // *whitespace*-guttered prose/markdown block in too via `reflowParagraphs` —
        // the TUI hard-wrap case, where there is no `▎` bar but the block is just as
        // clearly a wrapped display box. Both are gated: ordinary captures (and the
        // watcher, whose default leaves the flag off) keep the conservative §6.3 wrap
        // detection; only a confirmed quoted block or an opted-in prose box reflows.
        let wantsProseReflow =
            options.reflowParagraphs && isReflowableProse(barStripped, profile: profile)
        // De-gutter *before* reflow on the whitespace-guttered prose path (the bar
        // path was already de-guttered by stripGutterBars). Reflow can collapse a
        // block to a single line, after which the in-loop de-gutter — which needs ≥2
        // lines — would never fire and the render gutter would survive on the lone
        // reflowed line.
        var reflowInput = barStripped
        var preDegutterChanged = false
        if wantsProseReflow && !barChanged {
            let protectedLines = Heredoc.detect(splitLines(barStripped)).protectedLines
            let (deg, dc) = degutter(
                barStripped,
                tabWidth: profile.tabWidth,
                protected: protectedLines
            )
            reflowInput = deg
            preDegutterChanged = dc
        }
        let reflowed =
            (barChanged || wantsProseReflow)
            ? reflowQuoted(reflowInput, profile: profile) : reflowInput

        // §6 (cmux capture): un-shatter a renderer-merged box-drawing table. cmux
        // copies a Claude TUI message by flattening the grid — several `│…│` rows
        // arrive concatenated on one line behind ~100-space padding runs, with prose
        // right-shifted by a leading-padding run. This splits the merged rows back
        // apart and pulls the spurious leading padding to the block's modal indent,
        // leaving a uniform margin the §6.2 de-gutter below then strips cleanly. It
        // is self-gating (a no-op unless a real row seam exists), so a cleanly copied
        // table or any non-table copy flows through untouched. Runs unconditionally
        // (no opt-in flag) so the watcher fixes it hands-free via the §7.4 fast path.
        let (preprocessed, unshatterChanged) = Unshatter.unshatter(reflowed, profile: profile)

        // §6.4 + §6.8: iterate de-gutter → rejoin to a fixed point. One pass is not
        // idempotent — rejoin merges full lines, and on a fresh pass those merged
        // lines can form a *new* dominant width that `detectWidth` would merge
        // again, cascading. The pair is monotone (line count and leading whitespace
        // only ever decrease), so it converges; the converged text is a true fixed
        // point, which is what makes `repair` idempotent. Heredocs are re-detected
        // each round because a merge upstream shifts body line indices.
        var working = preprocessed
        var dedentChanged = barChanged || preDegutterChanged
        // Track which kinds of structural change fired, to set `dedentOnly` for the
        // watch-mode safe-dedent fast path (§7.4). A quote-bar strip/reflow is a
        // non-dedent change, so it disqualifies the fast path from the start.
        var sawDegutter = preDegutterChanged
        // A bar strip, a reflow that merged lines, or a box-table un-shatter is a
        // non-dedent structural change — it disqualifies the §7.4 dedent-only fast
        // path (the un-shatter instead claims its own `tableUnshattered` fast path).
        var sawRejoinOrReflow = barChanged || unshatterChanged || preprocessed != reflowInput
        var firstConfidence = 0.0
        var firstWidth: Int?
        var heredocDetected = false
        let maxIterations = splitLines(normalized).count + 2
        for iteration in 0..<maxIterations {
            let heredoc = Heredoc.detect(splitLines(working))
            let (dedented, dc) = degutter(
                working,
                tabWidth: profile.tabWidth,
                protected: heredoc.protectedLines
            )
            let rejoined = rejoin(
                dedented,
                profile: profile,
                options: options,
                protected: heredoc.protectedLines
            )
            dedentChanged = dedentChanged || dc
            if dc { sawDegutter = true }
            // A rejoin merged ≥1 seam this pass: the change is no longer dedent-only.
            if rejoined.text != dedented { sawRejoinOrReflow = true }
            if iteration == 0 {
                firstConfidence = rejoined.confidence
                firstWidth = rejoined.detectedWidth
                heredocDetected = heredoc.detected
            }
            if rejoined.text == working { break }
            working = rejoined.text
        }

        // §6.5: optional, lossy merge-artifact split — off unless the caller opts
        // in. Runs once after the fixed point (it works on the over-long lines that
        // remain) and skips heredoc bodies; it is intentionally not part of the
        // idempotence guarantee.
        var finalText = working
        if options.splitPaddingArtifacts {
            // A forced width applies even when rejoin saw a single line (and so
            // reported no detected column).
            let splitWidth = options.forcedWidth ?? firstWidth
            let split = MergeSplit.split(finalText, profile: profile, width: splitWidth).text
            if split != finalText { sawRejoinOrReflow = true }
            finalText = split
        }

        // §6.7: classify the normalized content for the watch-mode gates. Signals
        // describe what the user copied (the gate-5/6 subject), so they read the
        // normalized input rather than the rewritten output.
        let shell = Signals.shell(normalized)
        let structure = Signals.structure(normalized)

        let report = RepairReport(
            changed: finalText != input,
            dedentChanged: dedentChanged,
            wrapColumnConfidence: firstConfidence,
            shellSignalScore: shell.score,
            structureRisk: structure.risk,
            heredocDetected: heredocDetected,
            detectedWidth: firstWidth,
            // The only structural change was a whitespace de-gutter (§7.4 fast path):
            // a dedent fired, nothing merged/reflowed/split, and the output really
            // differs from the normalized input.
            dedentOnly: sawDegutter && !sawRejoinOrReflow && finalText != normalized,
            // A confirmed `▎` quote-bar gutter was stripped (§6.2). The watch-mode
            // fast path (§7.4) waives gates 5/6 for this the same way it does for a
            // pure dedent — the bar is unambiguous render chrome, so the strip +
            // bounded reflow is the universally-wanted fix, not a risky prose merge.
            barStripped: barChanged,
            // A renderer-merged box-drawing table was un-shattered (cmux capture).
            // Like a bar strip, this is unambiguous render corruption — the watch
            // fast path (§7.4) waives gates 5/6 for it, since the structure-risk gate
            // would otherwise veto every table copy and leave the bork on the
            // clipboard. Splitting only fires on real `│…│` row seams, so it can
            // never mistake authored content for a shattered table.
            tableUnshattered: unshatterChanged,
            // Beyond normalization? If the output equals the normalized input, the
            // only change was §6.1 stripping (escapes/CRLF) — no wrap rejoined, no
            // gutter removed. Watch mode (§7.4) must not fire on that.
            structuralChange: finalText != normalized
        )
        return RepairResult(text: finalText, report: report)
    }

    // MARK: - §6.1 Normalize

    /// Strip terminal escape sequences, then collapse CRLF/CR to LF. Escapes are
    /// removed *first* so their bytes never count as display columns (§6.1) or
    /// survive into the repaired output — this is what locks down the Codex
    /// `#8306` corruption fixtures (§13).
    static func normalize(_ input: String) -> String {
        var s = stripControlSequences(input)
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        s = trimBlankEdges(s)
        return s
    }

    /// Drop leading and trailing blank lines (§6.1). A drag-selection routinely
    /// grabs a stray blank line above or below the real content; left in place it
    /// not only survives into the paste but skews §6.2 de-gutter — a leading blank
    /// pushes the real first content line into the "lines 2..n" set, changing the
    /// gutter `G` so the result depends on selection slop. Trimming the edges first
    /// makes `G` a function of the real content alone.
    ///
    /// Internal blank lines (paragraph breaks in a bar block, §6.2) are preserved —
    /// only the leading and trailing runs are removed. A single trailing newline is
    /// re-added when the input had one, honoring §6.1's output-parity rule. An input
    /// that is entirely blank is returned unchanged: there is no content to anchor a
    /// trim, and emptying a deliberately-whitespace clipboard would be a surprise.
    static func trimBlankEdges(_ text: String) -> String {
        let endsWithNewline = text.hasSuffix("\n")
        var lines = splitLines(text)
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        guard !lines.isEmpty else { return text }
        let joined = lines.joined(separator: "\n")
        return endsWithNewline ? joined + "\n" : joined
    }

    /// Remove ANSI CSI sequences (SGR colors, cursor moves), OSC payloads
    /// (window titles, OSC52 clipboard writes — terminated by BEL or ST), and
    /// other lone `ESC x` escapes. Tabs and newlines are preserved; everything
    /// else passes through untouched.
    static func stripControlSequences(_ input: String) -> String {
        guard input.unicodeScalars.contains(where: { $0.value == 0x1B }) else {
            return input  // fast path: no ESC, nothing to strip
        }
        let esc: UInt32 = 0x1B
        let bel: UInt32 = 0x07
        let scalars = Array(input.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c.value == esc, i + 1 < scalars.count else {
                out.append(c)
                i += 1
                continue
            }
            let next = scalars[i + 1].value
            if next == 0x5B {  // '[' — CSI: params/intermediates then a final byte 0x40–0x7E
                i += 2
                while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                if i < scalars.count { i += 1 }  // consume the final byte
            } else if next == 0x5D {  // ']' — OSC: until BEL or ST (ESC '\')
                i += 2
                while i < scalars.count {
                    if scalars[i].value == bel { i += 1; break }
                    let isST =
                        scalars[i].value == esc && i + 1 < scalars.count
                        && scalars[i + 1].value == 0x5C
                    if isST { i += 2; break }
                    i += 1
                }
            } else {  // any other two-byte ESC sequence
                i += 2
            }
        }
        return String(out)
    }

    // MARK: - §6.2 De-gutter (dedent, robust to a partially selected line 1)

    static func degutter(
        _ text: String,
        tabWidth: Int,
        protected: Set<Int> = []
    ) -> (String, Bool) {
        let lines = splitLines(text)
        guard lines.count >= 2 else { return (text, false) }

        // Body indents = leading widths of non-blank lines 2..n, excluding heredoc
        // bodies (§6.4) — their intentional indentation must not skew the gutter.
        let bodyIndents =
            lines.enumerated()
            .dropFirst()
            .filter { !protected.contains($0.offset) && !isBlank($0.element) }
            .map { DisplayWidth.leadingWidth(of: $0.element, tabWidth: tabWidth) }
        guard let gBody = bodyIndents.min() else { return (text, false) }

        // When line 1 sits *below* the body's minimum indent the gutter is ambiguous:
        // either line 1 was partially selected and clipped below a real render gutter
        // (§5 Case 3 — strip the body minimum), or line 1 is the outermost scope of
        // indented source and the body indent is genuine structure (strip nothing
        // beyond line 1's own indent). Excluding line 1 unconditionally (the old
        // behavior) always assumed the former and so flattened code like `def f():`
        // over its body, violating §6.8 lossless-on-clean.
        //
        // Disambiguate by nesting depth: a clipped command or its continuations sit at
        // one or two indent levels, whereas source code with ≥3 distinct body indents
        // is unmistakably structural — keep it. (A real gutter that *does* prefix
        // line 1 lands in the `indent1 >= gBody` path below and still strips cleanly.)
        let line1Active = !protected.contains(0) && !isBlank(lines[0])
        let indent1 =
            line1Active ? DisplayWidth.leadingWidth(of: lines[0], tabWidth: tabWidth) : gBody
        let distinctBodyLevels = Set(bodyIndents).count
        let structuralCode = line1Active && indent1 < gBody && distinctBodyLevels >= 3
        // Structural code: the gutter is only line 1's own indent (often 0), so its
        // nesting survives. Otherwise the body minimum is the render gutter.
        let g = structuralCode ? indent1 : gBody
        guard g > 0 else { return (text, false) }

        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (idx, line) in lines.enumerated() {
            if protected.contains(idx) {
                out.append(line)  // §6.4: heredoc body left untouched
            } else if idx == 0 {
                let firstIndent = DisplayWidth.leadingWidth(of: line, tabWidth: tabWidth)
                out.append(
                    removeLeadingColumns(line, upTo: min(firstIndent, g), tabWidth: tabWidth)
                )
            } else {
                out.append(removeLeadingColumns(line, upTo: g, tabWidth: tabWidth))
            }
        }
        return (out.joined(separator: "\n"), true)
    }

    // MARK: - §6.3 Rejoin wrapped lines

    /// Result of the rejoin pass: the rewritten text plus the wrap-column signals
    /// that flow into the `RepairReport` (§6.7).
    struct RejoinResult {
        let text: String
        let confidence: Double
        let detectedWidth: Int?
    }

    static func rejoin(
        _ text: String,
        profile: WrapProfile,
        options: RepairOptions,
        protected: Set<Int> = []
    ) -> RejoinResult {
        let lines = splitLines(text)
        guard lines.count >= 2 else {
            return RejoinResult(text: text, confidence: 0, detectedWidth: nil)
        }

        let widths = lines.map { DisplayWidth.width(of: $0, tabWidth: profile.tabWidth) }
        let detected = options.forcedWidth ?? detectWidth(widths)
        // With no detectable wrap column we only act under `--join-all`; otherwise
        // the text is returned untouched. `--join-all` then collapses through the
        // same loop below (with an unbounded width so every seam qualifies), so it
        // still honors the heredoc protections in §6.4.
        if detected == nil, !options.joinAll {
            return RejoinResult(text: text, confidence: 0, detectedWidth: nil)
        }
        let w = detected ?? Int.max

        // §5 Case 4: a terminal only breaks *inside* a token when that token is
        // longer than the wrap column — there is no space to break at, so the
        // fragments must rejoin with **no** space (the old tool's injected-space bug
        // corrupted URLs/hashes/base64). A "solid" line is one that is full *and* a
        // single space-free token, i.e. a fragment of such a wrap.
        //
        // A lone solid line followed by a short line is genuinely ambiguous — it is
        // indistinguishable from a long word that fit exactly and then an ordinary
        // word wrap (the §5 case 1 test locks that as a single-space join). So a
        // fragment is only confirmed by a *neighbour*: a run of ≥2 consecutive solid
        // lines is unmistakably one token char-wrapped across lines. A line is a
        // `fragment` when it is solid and has a solid neighbour; every seam whose left
        // line is a fragment (including the seam onto a short final remainder) joins
        // without a space. `joinAll` (sentinel `w == .max`) can't know the column, so
        // it always falls back to the safe word join.
        let solid = lines.indices.map { idx in
            w != .max && widths[idx] >= w - 2 && widths[idx] <= w
                && !lines[idx].contains(where: { $0 == " " || $0 == "\t" })
        }
        func isFragment(_ idx: Int) -> Bool {
            guard solid[idx] else { return false }
            return (idx > 0 && solid[idx - 1]) || (idx + 1 < solid.count && solid[idx + 1])
        }

        // The `solid` test above only spots a mid-token wrap when the *whole* line is
        // one space-free token — it misses a long unbreakable token at the tail of an
        // otherwise spaced line (`gcloud … --scopes=openid,https://www.g` wrapping into
        // `oogleapis.com/auth/cse`), where injecting a word-join space splits the URL
        // into an invalid `https://www.g` scope. Decide tight-vs-space at the *seam*
        // instead: a terminal/TUI only hard-breaks *inside* a token when that token is
        // too long for one line, so the seam fell mid-token exactly when (a) no
        // whitespace sits on either side of it and (b) the token straddling it —
        // `lines[idx]`'s trailing run plus `lines[idx+1]`'s leading run — is wider than
        // the wrap column `w`, i.e. it could never have fit on one line. A short
        // boundary token (`--workdir` + `/work`) is an ordinary word wrap. joinAll
        // (sentinel `w == .max`) can't know the column, so it keeps the safe word join.
        func seamIsMidToken(_ idx: Int) -> Bool {
            guard w != .max, idx + 1 < lines.count else { return false }
            let left = lines[idx], right = lines[idx + 1]
            // Only a line with *interior* whitespace gets the seam test: there the
            // trailing run is genuinely a tail token (`… --scopes=…g`), so a boundary
            // wider than `w` is firm evidence of a char-break. A lone full token line
            // that fills the column on its own (no interior space) is the ambiguous §5
            // case-1 shape — a word that fit exactly is indistinguishable from a
            // char-break — and stays a single-space join unless a *solid run* (≥2 such
            // lines, `isFragment`) confirms the wrap. Without this guard the case-1
            // lock (`xx…(42 cols)` + `/tmp/out.json`) would flip to a tight join.
            guard left.contains(" ") || left.contains("\t") else { return false }
            guard let l = left.last, l != " ", l != "\t" else { return false }
            guard let r = right.first, r != " ", r != "\t" else { return false }
            let leftRun = String(left.reversed().prefix { $0 != " " && $0 != "\t" }.reversed())
            let rightRun = String(right.prefix { $0 != " " && $0 != "\t" })
            let boundaryWidth =
                DisplayWidth.width(of: leftRun, tabWidth: profile.tabWidth)
                + DisplayWidth.width(of: rightRun, tabWidth: profile.tabWidth)
            return boundaryWidth > w
        }

        // A seam joins tight when either signal fires: a confirmed solid-run fragment,
        // or a boundary token too wide to have fit on one line.
        func midTokenSeam(_ idx: Int) -> Bool { isFragment(idx) || seamIsMidToken(idx) }

        var out: [String] = []
        var joins = 0
        var i = 0
        while i < lines.count {
            var current = lines[i]
            // A newline after line `i` is a wrap when line `i` is "full" and does
            // not end in an explicit continuation token. Decisions key off the
            // *original* line `i`, so a run of full lines collapses correctly and
            // the operation stays idempotent.
            while i < lines.count - 1 {
                // §6.4: never merge into or across a heredoc body — the opener
                // line must not absorb the first body line, and body newlines are
                // intentional. joinAll cannot override this.
                if protected.contains(i) || protected.contains(i + 1) { break }
                let lineWidth = widths[i]
                let isFull = lineWidth >= w - 2 && lineWidth <= w
                let endsContinuation = profile.continuationTokens.contains {
                    lines[i].hasSuffix($0)
                }
                let nextNonBlank = !isBlank(lines[i + 1])
                // A line opening with a list marker (`- `, `* `, `1. `) is an
                // intentional break — a markdown/prose list, never a wrap. Two list
                // items can share a display width and otherwise read as "full", so
                // without this they would wrongly collapse into one line. This binds
                // even under joinAll: merging bullets is never what was meant.
                let nextIsListItem = startsWithListMarker(lines[i + 1])
                // A soft-wrap continuation returns to the block's left margin (column
                // 0 once de-gutter has run), so a next line that is itself *indented*
                // is intentional structure — nested code, not a wrap. Without this,
                // consecutive code lines that happen to share a near-`w` width (e.g. a
                // `for:`/`if:`/body run) get spuriously merged, mangling clean source
                // (§6.8). The de-gutter pass has already removed any real gutter, so
                // surviving indentation is always meaningful here.
                let nextIndented =
                    DisplayWidth.leadingWidth(of: lines[i + 1], tabWidth: profile.tabWidth) > 0
                // Box-drawing rows (tables, trees) line up at a uniform width and so
                // read as "full", but their newlines are structural, never wraps —
                // merging them smushes the whole table onto one line. Guard either
                // side of the seam, and bind even under joinAll (like list markers).
                let touchesBoxDrawing =
                    containsBoxDrawing(lines[i]) || containsBoxDrawing(lines[i + 1])
                // A line ending in a shell comment is a complete logical line, never
                // the source of a soft wrap — merging the next line up into it would
                // comment that line out. Bind this even under joinAll (like list
                // markers / box-drawing): swallowing a command into a comment is never
                // what the user meant.
                let leftEndsWithComment = endsWithComment(lines[i])
                // A soft-wrap continuation resumes the previous statement mid-stream
                // (arguments, paths, words), so it never *begins a fresh command*. When
                // the next line opens with a known tool or a `VAR=value` assignment it is
                // a separate statement, not a wrap remainder — two independent commands
                // that happen to share a near-`w` display width (`cd ~/p` / `python3 -m
                // venv .venv`, both 30 cols) read as "full" and would otherwise smush
                // into one unrunnable line. Bind even under joinAll, like the list /
                // box-drawing / comment guards: gluing two commands together is never
                // what the user meant. Skip the guard on a confirmed mid-token char-wrap
                // (`isFragment`): there the next line is the tail of one unbreakable
                // token, not a statement, and a solid-run fragment like `n=eyJ…` (the
                // back half of `…?token=…`) only *looks* like a `VAR=value` start (F4).
                // This keys off `isFragment` (the whole-line solid-run test), not the
                // broader seam test: a wide boundary token alone (e.g. a long path next
                // to a fresh command, `~/p` + `python3`) is not evidence of a wrap.
                let nextStartsCommand = !isFragment(i) && startsFreshCommand(lines[i + 1])
                let isWrap = isFull && !endsContinuation && nextNonBlank && !nextIndented
                if !nextIsListItem && !touchesBoxDrawing && !leftEndsWithComment
                    && !nextStartsCommand
                    && (options.joinAll || isWrap)
                {
                    // Mid-token char-wrap (§5 Case 4): when the seam fell inside one
                    // unbreakable token, rejoin with no space. Otherwise it is a word
                    // boundary and rejoins with a single space.
                    current =
                        midTokenSeam(i)
                        ? joinSeamTight(current, lines[i + 1])
                        : joinSeam(current, lines[i + 1])
                    joins += 1
                    i += 1
                } else {
                    break
                }
            }
            out.append(current)
            i += 1
        }

        let confidence = joins > 0 ? min(1.0, 0.5 + 0.1 * Double(joins)) : 0
        return RejoinResult(
            text: out.joined(separator: "\n"),
            confidence: confidence,
            detectedWidth: detected  // nil under the --join-all fallback (sentinel w)
        )
    }

    /// Plausible-wrap-point floor: a line narrower than this is never treated as a
    /// wrap column. Keeps short clean lines (`one\ntwo\nthree`) from ever joining.
    static let minWrapColumn = 20
    /// A *single* full line is weak evidence of a wrap, so a lone candidate only
    /// establishes a column on a clean two-line paste and only when it is at least
    /// this wide — comfortably below a narrow split-pane width, well above any line a
    /// user would deliberately type and break by hand.
    static let minTwoLineWrapColumn = 40

    /// Wrap column = the dominant display width among the **full, non-final** lines,
    /// matched with the same ±2 tolerance `rejoin` uses for "full". Returns nil when
    /// no column dominates, which keeps clean input unchanged (§6.8).
    ///
    /// Real word-wraps vary by a few columns (the last word that fit rarely lands on
    /// the exact same cell), so an *exactly* repeated width is too strict — it misses
    /// uneven multi-line wraps (F3) and two-line wraps that have only one non-final
    /// line (F2). We instead cluster candidates into a [w-2, w] band (mirroring
    /// `isFull`) and take the band with the most members; a lone candidate is
    /// accepted only for a clean two-line paste that is suitably wide.
    ///
    /// The tie-break is deterministic and **must stay that way**: a bare `max(by:)`
    /// over a `Dictionary` would pick a different width across runs whenever two
    /// share the top count (Swift randomizes hash-seed iteration order), making
    /// `repair` non-idempotent at random (§6.8). We iterate sorted widths and break
    /// count ties toward the **larger** column: it admits fewer lines as "full", so
    /// fewer speculative rejoins fire ("when in doubt, don't act", §7).
    static func detectWidth(_ widths: [Int]) -> Int? {
        // Drop the trailing blank line a final newline leaves behind, so the real
        // remainder line — not the empty string — is the one excluded as non-final.
        var content = widths
        while let last = content.last, last == 0 { content.removeLast() }
        guard content.count >= 2 else { return nil }

        // Exclude the final content line: it is the wrap remainder, narrower than the
        // column, so counting it would only dilute the band.
        let candidates = content.dropLast().filter { $0 >= minWrapColumn }
        guard !candidates.isEmpty else { return nil }

        // For each distinct candidate width `w`, count how many candidates fall in its
        // [w-2, w] band; pick the widest `w` with the largest band.
        var bestWidth = 0
        var bestCount = 0
        for w in Set(candidates).sorted() {
            let count = candidates.filter { $0 >= w - 2 && $0 <= w }.count
            if count > bestCount || (count == bestCount && w > bestWidth) {
                bestCount = count
                bestWidth = w
            }
        }

        if bestCount >= 2 { return bestWidth }
        // A single full line is only trusted as a wrap column on a two-line paste:
        // one full line wide enough to be a column, plus a strictly shorter
        // remainder. The remainder check matters — a confirmed quote-bar reflow
        // (§6.2) can leave two lines where the *second* is the longer one (an
        // intentional break it preserved); that is not a wrap and must not rejoin.
        // More lines without a repeated width are too ambiguous to act on.
        if content.count == 2, bestWidth >= minTwoLineWrapColumn,
            let remainder = content.last, remainder < bestWidth
        {
            return bestWidth
        }
        return nil
    }

    // MARK: - Helpers

    static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// True if the line carries a Unicode Box Drawing glyph (U+2500–U+257F) — the
    /// `─│┌┬┐├┼┤└┴┘` family used by table and tree output. Such lines are structural
    /// and must never be rejoined (§6.3 guard, F5).
    static func containsBoxDrawing(_ line: String) -> Bool {
        line.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
    }

    /// Join a word-boundary wrap with exactly one space, collapsing the accidental
    /// double space at the seam (the old tool's `>  /tmp` bug — §5 note).
    static func joinSeam(_ left: String, _ right: String) -> String {
        var l = Substring(left)
        while l.hasSuffix(" ") { l = l.dropLast() }
        var r = Substring(right)
        while r.hasPrefix(" ") { r = r.dropFirst() }
        return String(l) + " " + String(r)
    }

    /// Join a mid-token wrap with **no** space — the terminal split a single
    /// unbreakable token (URL/hash/base64) across the column, so the two halves
    /// belong directly adjacent. Trailing/leading spaces at the seam are still
    /// trimmed for safety, though a true mid-token break never has any.
    static func joinSeamTight(_ left: String, _ right: String) -> String {
        var l = Substring(left)
        while l.hasSuffix(" ") { l = l.dropLast() }
        var r = Substring(right)
        while r.hasPrefix(" ") { r = r.dropFirst() }
        return String(l) + String(r)
    }

    /// True when `line` carries a shell line-comment — an unquoted `#` at a word
    /// boundary (line start, or right after whitespace) outside single/double
    /// quotes. In shell such a `#` opens a comment that runs to end-of-line, so the
    /// line is a *complete* logical line and can never be the source side of a soft
    /// wrap: a real wrap would have continued the comment text, not started a fresh
    /// command back at the left margin. §6.3 rejoin uses this to refuse merging the
    /// next line up into the comment — which would silently comment a command out
    /// (data loss: the `brew update … # …\nbrew services restart …` paste collapsed
    /// `brew services restart` into the first line's comment). Conservative by
    /// design — a false positive only forgoes a rejoin (a wrapped long comment stays
    /// two lines), never corrupts; a `#` inside quotes, after `$`, or mid-token
    /// (`url#frag`) is correctly *not* a comment.
    static func endsWithComment(_ line: String) -> Bool {
        var inSingle = false
        var inDouble = false
        var atWordBoundary = true  // line start is a word boundary
        for ch in line {
            if inSingle {
                if ch == "'" { inSingle = false }
                atWordBoundary = false
                continue
            }
            if inDouble {
                if ch == "\"" { inDouble = false }
                atWordBoundary = false
                continue
            }
            switch ch {
            case "#" where atWordBoundary:
                return true
            case "'":
                inSingle = true
                atWordBoundary = false
            case "\"":
                inDouble = true
                atWordBoundary = false
            case " ", "\t":
                atWordBoundary = true
            default:
                atWordBoundary = false
            }
        }
        return false
    }

    /// True when `line` begins a *fresh* shell statement — its first bare token is a
    /// known command/tool (`Signals.knownTools`) or it opens with a `VAR=value`
    /// assignment. A soft-wrap continuation never starts this way: the wrap broke
    /// mid-statement, so the remainder resumes with arguments/words, not a new command
    /// invocation. §6.3 rejoin refuses to treat a seam *onto* such a line as a wrap, so
    /// two independent commands that coincidentally share a near-`w` display width
    /// (`cd ~/p` / `python3 -m venv .venv`) stay on separate lines instead of smushing
    /// into one unrunnable line. Conservative by construction — the known-tool and
    /// assignment shapes are unambiguous statement starts, never wrap remainders (a
    /// real wrap continues with the argument *to* the trailing flag, e.g. `--workdir`
    /// then `/work …`, which is not a known tool), so the guard only ever *forgoes* a
    /// rejoin (leaves two lines); it can never corrupt.
    static func startsFreshCommand(_ line: String) -> Bool {
        Signals.startsWithKnownTool(line) || Signals.hasEnvAssignmentPrefix(line)
    }

    /// Remove up to `columns` of leading whitespace (display-width aware).
    static func removeLeadingColumns(_ line: String, upTo columns: Int, tabWidth: Int) -> String {
        guard columns > 0 else { return line }
        var removed = 0
        var idx = line.startIndex
        while idx < line.endIndex, removed < columns {
            let ch = line[idx]
            if ch == " " {
                removed += 1
            } else if ch == "\t" {
                removed += tabWidth - (removed % tabWidth)
            } else {
                break
            }
            idx = line.index(after: idx)
        }
        return String(line[idx...])
    }
}
