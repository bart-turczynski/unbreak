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
        // paragraph back to one line. This is gated behind `barChanged` on purpose —
        // ordinary captures keep the conservative §6.3 wrap detection; only a
        // confirmed quoted block opts into prose reflow.
        let preprocessed = barChanged ? reflowQuoted(barStripped, profile: profile) : barStripped

        // §6.4 + §6.8: iterate de-gutter → rejoin to a fixed point. One pass is not
        // idempotent — rejoin merges full lines, and on a fresh pass those merged
        // lines can form a *new* dominant width that `detectWidth` would merge
        // again, cascading. The pair is monotone (line count and leading whitespace
        // only ever decrease), so it converges; the converged text is a true fixed
        // point, which is what makes `repair` idempotent. Heredocs are re-detected
        // each round because a merge upstream shifts body line indices.
        var working = preprocessed
        var dedentChanged = barChanged
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
            finalText = MergeSplit.split(finalText, profile: profile, width: splitWidth).text
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
        return s
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

        // Gutter `G` = minimum leading width over non-blank lines 2..n, excluding
        // heredoc bodies (§6.4) — their intentional indentation must not skew `G`.
        let indents =
            lines.enumerated()
            .dropFirst()
            .filter { !protected.contains($0.offset) && !isBlank($0.element) }
            .map { DisplayWidth.leadingWidth(of: $0.element, tabWidth: tabWidth) }
        guard let g = indents.min(), g > 0 else { return (text, false) }

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
                let isWrap = isFull && !endsContinuation && nextNonBlank
                if !nextIsListItem && (options.joinAll || isWrap) {
                    current = joinSeam(current, lines[i + 1])
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

    /// Wrap column = the most common repeated display width among non-final lines
    /// wide enough to plausibly be a wrap point. Returns nil when no such column
    /// dominates, which keeps clean input unchanged (§6.8).
    ///
    /// The tie-break is deterministic and **must stay that way**: `Dictionary`
    /// iteration order is randomized per process by Swift's hash seed, so a bare
    /// `max(by: value)` would pick a different width across runs whenever two widths
    /// share the top count — making `repair` non-idempotent at random (§6.8). On a
    /// count tie we pick the **larger** width: it admits fewer lines as "full", so
    /// fewer speculative rejoins fire ("when in doubt, don't act", §7).
    static func detectWidth(_ widths: [Int]) -> Int? {
        let candidates = widths.dropLast().filter { $0 >= 20 }
        guard candidates.count >= 2 else { return nil }
        var counts: [Int: Int] = [:]
        for value in candidates { counts[value, default: 0] += 1 }
        // Order by count, then by width as a stable tie-break (largest wins).
        let best = counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
        }
        guard let best, best.value >= 2 else { return nil }
        return best.key
    }

    // MARK: - Helpers

    static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
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
