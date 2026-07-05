import Foundation

// MARK: - §6.3 Rejoin: multi-line quoted-string (inline-script) protection

extension Repair {
    /// For each line, whether a shell quote is still **open** at its end — i.e. the
    /// following newline falls *inside* a single- or double-quoted string, so it is
    /// literal content (an inline `python -c "…"` / `bash -c '…'` script) rather than
    /// a soft wrap. Quote state carries across lines with shell rules: single quotes
    /// are literal (only `'` closes, no escapes), double quotes honor a `\`-escape (so
    /// `\"` does not close them), a backslash outside quotes escapes the next
    /// character, and an unquoted `#` at a word boundary opens a comment that runs to
    /// end-of-line (a `"`/`'` inside it never opens a string).
    ///
    /// §6.3 rejoin consults this to refuse merging across such a newline: without it
    /// the short lines of a quoted inline script cluster into a spurious narrow "wrap
    /// column" and collapse onto one line, breaking the script (the screaming-frog
    /// borked-copy defect). Conservative like the other rejoin guards — it can only
    /// ever *forgo* a merge, never corrupt — and the caller's width floor exempts a
    /// genuinely wrapped long quoted argument (F3), so only literal short script lines
    /// are protected.
    static func quoteOpenAtLineEnd(_ lines: [String]) -> [Bool] {
        var result = [Bool](repeating: false, count: lines.count)
        // The open quote character (`'` or `"`), or nil when outside any quote.
        var quote: Character?
        for (idx, line) in lines.enumerated() {
            var atWordBoundary = true  // line start is a word boundary
            var escaped = false
            charLoop: for ch in line {
                if escaped {
                    escaped = false
                } else if let open = quote {
                    // Inside a quote: a double quote honors `\`-escapes; either kind
                    // closes on its matching character.
                    if open == "\"" && ch == "\\" {
                        escaped = true
                    } else if ch == open {
                        quote = nil
                    }
                } else {
                    switch ch {
                    case "\\": escaped = true
                    case "'", "\"": quote = ch
                    // An unquoted comment ignores the rest of the line; a `#` never
                    // opens a string and we are outside quotes, so state is unchanged.
                    case "#" where atWordBoundary: break charLoop
                    default: break
                    }
                }
                atWordBoundary = ch == " " || ch == "\t"
            }
            // A trailing backslash outside quotes is a line-continuation, not a quote
            // opener, so `escaped` needs no carry-over: only real quote state matters.
            result[idx] = quote != nil
        }
        return result
    }
}
