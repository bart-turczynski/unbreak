import Foundation

/// Un-shatter a renderer-merged box-drawing table (PRD v2 §6 — cmux capture).
///
/// Some terminals (notably cmux) copy a Claude TUI message by flattening the grid:
/// the newline *between* two table rows becomes a long run of padding spaces, so
/// several `│…│` rows land concatenated on one physical line, and short prose
/// lines arrive right-shifted by a huge leading-padding run. The §6.3 rejoin
/// deliberately never *merges* box-drawing rows; this pass is its dual — it splits
/// rows the renderer already merged, then normalizes the spurious leading padding
/// so the existing §6.2 de-gutter can strip the block's margin uniformly.
///
/// It is **high-precision and self-gating**: a row seam is only cut where a run of
/// spaces sits directly between two box-drawing glyphs *and at least one side is a
/// corner/junction glyph* (`┐│`, `│├`, `┤│`, …) — never `│…│`, which is an empty
/// cell, not a seam. If no such seam exists the whole pass is a no-op, so a cleanly
/// copied table (or any non-table copy) is left untouched. The leading-padding
/// normalization only runs *after* a seam has confirmed the block is a mangled
/// display box, which confines its aggression to exactly that case.
enum Unshatter {
    /// Unicode Box Drawing block (U+2500–U+257F): `─│┌┬┐├┼┤└┴┘` and kin.
    static func isBoxGlyph(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let s = ch.unicodeScalars.first else { return false }
        return (0x2500...0x257F).contains(s.value)
    }

    /// `│` (U+2502) — the plain vertical. A run flanked by `│` on *both* sides is an
    /// empty table cell, not a row seam, so it must never be cut.
    static let vertical: Character = "\u{2502}"

    /// Minimum spaces between two box glyphs to read as a merged-row seam. A real
    /// seam is the row's trailing pad to the grid width plus the next row's left
    /// margin — always wide — but two is a safe floor given the both-box +
    /// not-both-`│` guard already rules out cell padding and empty cells.
    static let minSeamRun = 2

    /// A leading indent this far *above* the block's modal indent is render padding,
    /// not authored nesting, so it is pulled back to the modal indent. Generous so
    /// ordinary nested structure (a level or two deeper than its siblings) is never
    /// touched — the real artifact shifts lines by ~100 columns.
    static let minPadGap = 8

    /// Split renderer-merged box rows and pull spurious leading padding back to the
    /// block's modal indent. Returns the rewritten text and whether anything changed.
    /// A no-op (returns the input unchanged) unless at least one row seam is found.
    static func unshatter(_ text: String, profile: WrapProfile) -> (text: String, changed: Bool) {
        let lines = Repair.splitLines(text)
        guard lines.count >= 1 else { return (text, false) }

        // Self-gate: only act when at least one line actually carries a merged-row
        // seam. Without this the leading-padding normalization could fire on prose
        // that merely happens to be deeply indented.
        let shattered = lines.contains { !seams(in: $0).isEmpty }
        guard shattered else { return (text, false) }

        let modal = modalIndent(lines, tabWidth: profile.tabWidth)

        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            // De-pad first so the seam-split pieces inherit the corrected margin.
            let depadded = depad(line, toIndent: modal, tabWidth: profile.tabWidth)
            out.append(contentsOf: splitRow(depadded))
        }
        let joined = out.joined(separator: "\n")
        return (joined, joined != text)
    }

    /// The byte offsets (into `Array(line)`) at which a row-seam space run starts.
    /// A seam is a run of ≥`minSeamRun` spaces flanked by box glyphs on both sides
    /// where the pair is not `│`/`│` (an empty cell). Returned in order.
    static func seams(in line: String) -> [Range<Int>] {
        let chars = Array(line)
        var ranges: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == " " else {
                i += 1
                continue
            }
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            if j - i >= minSeamRun, i > 0, j < chars.count {
                let before = chars[i - 1]
                let after = chars[j]
                if isBoxGlyph(before), isBoxGlyph(after),
                    !(before == vertical && after == vertical)
                {
                    ranges.append(i..<j)
                }
            }
            i = j
        }
        return ranges
    }

    /// Cut `line` at each seam (dropping the seam spaces). Pieces after the first
    /// inherit the leading-whitespace prefix of the first piece, so every row of a
    /// shattered table lines up at the same margin the renderer gave the block.
    static func splitRow(_ line: String) -> [String] {
        let cuts = seams(in: line)
        guard !cuts.isEmpty else { return [line] }
        let chars = Array(line)
        var pieces: [String] = []
        var start = 0
        for cut in cuts {
            pieces.append(String(chars[start..<cut.lowerBound]))
            start = cut.upperBound
        }
        pieces.append(String(chars[start...]))

        let indent = String(pieces[0].prefix { $0 == " " || $0 == "\t" })
        return pieces.enumerated().map { idx, piece in
            idx == 0 ? piece : indent + piece
        }
    }

    /// The most common leading width among non-blank lines (the block's margin),
    /// breaking ties toward the *smaller* indent so we never over-strip.
    static func modalIndent(_ lines: [String], tabWidth: Int) -> Int {
        var counts: [Int: Int] = [:]
        for line in lines where !Repair.isBlank(line) {
            counts[DisplayWidth.leadingWidth(of: line, tabWidth: tabWidth), default: 0] += 1
        }
        var best = 0
        var bestCount = -1
        for (indent, count) in counts.sorted(by: { $0.key < $1.key })
        where count > bestCount {
            best = indent
            bestCount = count
        }
        return best
    }

    /// Pull a line whose leading indent is a render-padding outlier (more than
    /// `minPadGap` columns past the block's modal indent) back to that modal indent.
    /// Lines at or below the modal indent — including a less-indented bullet/header
    /// line — are returned untouched.
    static func depad(_ line: String, toIndent target: Int, tabWidth: Int) -> String {
        let indent = DisplayWidth.leadingWidth(of: line, tabWidth: tabWidth)
        guard indent > target + minPadGap else { return line }
        return Repair.removeLeadingColumns(line, upTo: indent - target, tabWidth: tabWidth)
    }
}
