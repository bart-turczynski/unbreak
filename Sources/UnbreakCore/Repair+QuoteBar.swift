import Foundation

// MARK: - §6.2 De-gutter: quote-bar prefix

extension Repair {
    /// Strip a leading "quote bar" gutter — the left margin some CLIs draw around a
    /// quoted/previewed block (Claude Code's queued-prompt box renders `  ▎ ` on
    /// every line). The prefix is `<whitespace>* <bar> <space>?`: the leading
    /// whitespace is the box margin and the single space after the bar is its
    /// padding; anything past that is content, so its own indentation survives.
    ///
    /// Fires only when at least two non-blank lines carry the bar AND they are a
    /// two-thirds majority of the non-blank lines — a stray `▎` inside ordinary
    /// content never trips it ("when in doubt, don't act", §7). Blank lines are
    /// preserved; a separator line that is just `  ▎` collapses to empty. Idempotent:
    /// after a pass no line opens with the bar.
    static func stripGutterBars(_ text: String, profile: WrapProfile) -> (String, Bool) {
        guard !profile.gutterBars.isEmpty else { return (text, false) }
        let bars = Set(profile.gutterBars)
        let lines = splitLines(text)
        guard lines.count >= 2 else { return (text, false) }

        // Count of leading characters forming `<whitespace>* <bar> <space>?`, or nil
        // when the line does not open with a bar gutter.
        func barPrefixLength(_ line: String) -> Int? {
            var idx = line.startIndex
            while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
                idx = line.index(after: idx)
            }
            guard idx < line.endIndex, bars.contains(line[idx]) else { return nil }
            idx = line.index(after: idx)  // consume the bar
            if idx < line.endIndex, line[idx] == " " {
                idx = line.index(after: idx)  // consume one padding space
            }
            return line.distance(from: line.startIndex, to: idx)
        }

        let nonBlank = lines.filter { !isBlank($0) }
        let matching = nonBlank.filter { barPrefixLength($0) != nil }
        guard matching.count >= 2, matching.count * 3 >= nonBlank.count * 2 else {
            return (text, false)
        }

        var out: [String] = []
        out.reserveCapacity(lines.count)
        var changed = false
        for line in lines {
            if let n = barPrefixLength(line) {
                out.append(String(line.dropFirst(n)))
                changed = true
            } else {
                out.append(line)
            }
        }
        return (out.joined(separator: "\n"), changed)
    }

    /// Reflow a bar-quoted block (after its gutter is stripped) back to one line per
    /// paragraph. Inside the block the CLI soft-wrapped long lines at a fixed
    /// column, while blank lines are paragraph breaks the user intended.
    ///
    /// A newline between two non-blank lines is a **soft wrap** — rejoined with a
    /// single space — exactly when the first word of the next line would not have
    /// fit on the current line at the block's content width `W`: that word was
    /// bumped down only because it overflowed. An **intentional** short break (a
    /// list item, a deliberately split line) leaves room for the next word, so the
    /// fit test says "keep the break". The decision keys off the *original* line `i`
    /// width (`widths[i]`), like §6.3, so a paragraph collapses correctly without a
    /// growing running line forcing every later break to merge. `W` is the widest
    /// line — the closest probe of the fixed wrap column. Continuation tokens (§6.3)
    /// and heredoc bodies (§6.4) are preserved.
    static func reflowQuoted(_ text: String, profile: WrapProfile) -> String {
        let lines = splitLines(text)
        guard lines.count >= 2 else { return text }
        let heredoc = Heredoc.detect(lines)
        let widths = lines.map { DisplayWidth.width(of: $0, tabWidth: profile.tabWidth) }
        guard let w = widths.max(), w > 0 else { return text }

        func firstWordWidth(_ line: String) -> Int {
            let body = line.drop { $0 == " " || $0 == "\t" }
            let word = body.prefix { $0 != " " && $0 != "\t" }
            return DisplayWidth.width(of: String(word), tabWidth: profile.tabWidth)
        }

        var out: [String] = []
        var i = 0
        while i < lines.count {
            var current = lines[i]
            while i < lines.count - 1 {
                // §6.4 + paragraph breaks: never merge into/across a heredoc body or
                // a blank line.
                if heredoc.protectedLines.contains(i) || heredoc.protectedLines.contains(i + 1) {
                    break
                }
                if isBlank(lines[i]) || isBlank(lines[i + 1]) { break }
                // §6.3: an explicit continuation marks an intentional break.
                if profile.continuationTokens.contains(where: { lines[i].hasSuffix($0) }) { break }
                // A line opening with a list marker is an intentional break, even
                // when it is wide enough to read as a soft-wrapped continuation —
                // the word-fit test alone cannot tell a long list item apart from a
                // wrap. The marker requires a trailing space, so a `--flag` or `-x`
                // continuation is *not* mistaken for a bullet.
                if startsWithListMarker(lines[i + 1]) { break }
                // The renderer wrapped here iff the next word overflowed line `i`.
                let wouldOverflow = widths[i] + 1 + firstWordWidth(lines[i + 1]) > w
                if wouldOverflow {
                    current = joinSeam(current, lines[i + 1])
                    i += 1
                } else {
                    break
                }
            }
            out.append(current)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    /// Does `line` open with a list-item marker — a bullet (`-`, `*`, `+`, `•`) or
    /// an ordered marker (`1.` / `1)`) — followed by a space? The trailing space is
    /// load-bearing: it tells a bullet `- foo` apart from a flag `--flag` / `-x`, so
    /// reflow keeps a bullet break but still rejoins a wrapped command's flags.
    static func startsWithListMarker(_ line: String) -> Bool {
        var body = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return false }
        if "-*+•".contains(first) {
            let after = body.dropFirst()
            return after.first == " "
        }
        if first.isNumber {
            let digits = body.prefix { $0.isNumber }
            body = body.dropFirst(digits.count)
            guard let delim = body.first, delim == "." || delim == ")" else { return false }
            return body.dropFirst().first == " "
        }
        return false
    }
}
