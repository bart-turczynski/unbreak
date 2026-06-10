import Foundation

/// The pure watch-mode gate decision (PRD v2 §7).
///
/// Watch mode mutates the clipboard only when **all six** gates pass:
///
///  1. frontmost app is an allowlisted terminal,
///  2. the clipboard item is plain text,
///  3. the payload is within the size bound (`maxClipboardBytes`, default 16 KB),
///  4. the repair made a *structural* change — a wrap rejoin or a dedent, not just
///     §6.1 normalization (so a copy that merely contained escapes/CRLFs, with no
///     wrap to fix, is left untouched — `RepairReport.structuralChange`),
///  5. the shell-signal tier passes (≥1 strong OR ≥2 weak — §6.7 / `Signals.Shell.passesGate`),
///  6. no structure-risk veto fires (markdown/stack-trace/prose/table —
///     `Signals.Structure.vetoes`).
///
/// This function is **pure**: no `NSPasteboard`/`NSWorkspace` access lives here.
/// The watcher plumbing (CLAU-bgouhgol) reads the frontmost bundle id and the
/// plain-text representation, runs the pure repair (§6) and `Signals` (§6.7), then
/// hands those values in. Keeping the decision pure makes the whole gate ladder
/// unit-testable and lets dry-run / log-only mode (§7.2, §7.3) reuse the exact
/// same logic without touching the clipboard.
///
/// All six gates are always evaluated (no short-circuit) so the returned
/// `Decision` carries a full, content-safe per-gate breakdown for the log line.
public enum WatchGate {
    /// User-tunable gate configuration (PRD v2 §8.3). The terminal allowlist holds
    /// bundle identifiers (e.g. `com.apple.Terminal`); `maxClipboardBytes` bounds
    /// the UTF-8 payload size.
    public struct Config: Sendable, Equatable {
        public var terminalAllowlist: Set<String>
        public var maxClipboardBytes: Int
        /// Optional power-user override for gate 5 (§7.5): when set, the shell gate
        /// passes iff `Signals.Shell.score ≥ this`, replacing the discrete tier
        /// rule. `nil` (the default) keeps the shipped discrete rule (§8.3).
        public var shellSignalScoreThreshold: Double?
        /// Optional power-user override for gate 6 (§7.6): when set, the structure
        /// gate vetoes iff `Signals.Structure.risk ≥ this`, replacing the discrete
        /// veto rule. `nil` (the default) keeps the shipped discrete rule (§8.3).
        public var structureRiskThreshold: Double?

        /// Default bundle ids for the §7 allowlist: the popular macOS terminal
        /// emulators, so the common case works without any config. Every entry is a
        /// terminal where pasting a shell command is the expected action, so seeding
        /// them does not widen the safety boundary (gate 1 still keeps watch mode out
        /// of browsers, editors, chat apps). User-extensible via config/env (§8.3).
        public static let defaultTerminalAllowlist: Set<String> = [
            "com.cmuxterm.app",  // cmux (confirmed bundle id via QA, §11)
            "com.mitchellh.ghostty",  // Ghostty
            "com.googlecode.iterm2",  // iTerm2
            "com.apple.Terminal",  // Apple Terminal
            "net.kovidgoyal.kitty",  // Kitty
            "dev.warp.Warp-Stable",  // Warp (stable channel)
            "dev.warp.Warp-Preview",  // Warp (preview channel)
            "org.alacritty",  // Alacritty
            "com.github.wez.wezterm",  // WezTerm
            "co.zeit.hyper",  // Hyper
            "org.tabby",  // Tabby
        ]

        public init(
            terminalAllowlist: Set<String> = Config.defaultTerminalAllowlist,
            maxClipboardBytes: Int = 16 * 1024,
            shellSignalScoreThreshold: Double? = nil,
            structureRiskThreshold: Double? = nil
        ) {
            self.terminalAllowlist = terminalAllowlist
            self.maxClipboardBytes = maxClipboardBytes
            self.shellSignalScoreThreshold = shellSignalScoreThreshold
            self.structureRiskThreshold = structureRiskThreshold
        }
    }

    /// The six gates of §7, in evaluation order. `rawValue` doubles as a stable,
    /// content-safe log key.
    public enum Gate: String, Sendable, CaseIterable {
        case terminalAllowlisted = "terminal-allowlisted"  // §7.1
        case plainText = "plain-text"  // §7.2
        case sizeWithinBound = "size-within-bound"  // §7.3
        case repairChangedContent = "repair-changed"  // §7.4
        case shellSignal = "shell-signal"  // §7.5
        case structureRiskClear = "structure-risk-clear"  // §7.6
    }

    /// A single gate's result with a short, content-safe explanation suitable for
    /// `~/Library/Logs/unbreak.log` (§7.3 — full clipboard contents are never logged).
    public struct GateOutcome: Sendable, Equatable {
        public let gate: Gate
        public let passed: Bool
        public let detail: String

        public init(gate: Gate, passed: Bool, detail: String) {
            self.gate = gate
            self.passed = passed
            self.detail = detail
        }
    }

    /// The full decision. `shouldMutate` is true iff every gate passed. The
    /// `outcomes`, `byteCount`, and `lineCount` exist so dry-run / log-only mode
    /// (§7.2) and the observability log (§7.3) can report what *would* happen and
    /// why, without re-deriving anything.
    public struct Decision: Sendable, Equatable {
        public let shouldMutate: Bool
        /// True when the mutation was permitted by the §7.4 safe-dedent fast path —
        /// i.e. it mutated despite a shell-signal (§7.5) or structure-risk (§7.6)
        /// gate failing, because the repair was a pure de-gutter. Surfaced for the
        /// log so a "mutate" on a table/prose copy is explainable.
        public let viaDedentFastPath: Bool
        public let outcomes: [GateOutcome]
        public let byteCount: Int
        public let lineCount: Int

        public init(
            shouldMutate: Bool,
            viaDedentFastPath: Bool = false,
            outcomes: [GateOutcome],
            byteCount: Int,
            lineCount: Int
        ) {
            self.shouldMutate = shouldMutate
            self.viaDedentFastPath = viaDedentFastPath
            self.outcomes = outcomes
            self.byteCount = byteCount
            self.lineCount = lineCount
        }

        /// The first gate that blocked the mutation, or `nil` when we mutate (no gate
        /// blocked — including a fast-path mutation that waived gates 5/6). Handy for a
        /// one-word log reason ("blocked: structure-risk-clear").
        public var blockingGate: Gate? {
            shouldMutate ? nil : outcomes.first { !$0.passed }?.gate
        }

        /// A compact, content-safe summary line for the log / dry-run output, e.g.
        /// `decision=skip blocked=structure-risk-clear bytes=412 lines=6`, or
        /// `decision=mutate via=dedent-only bytes=412 lines=6` for the fast path.
        public var logSummary: String {
            let verdict = shouldMutate ? "mutate" : "skip"
            let via = viaDedentFastPath ? " via=dedent-only" : ""
            let blocked = blockingGate.map { " blocked=\($0.rawValue)" } ?? ""
            return "decision=\(verdict)\(via)\(blocked) bytes=\(byteCount) lines=\(lineCount)"
        }
    }

    /// Decide whether watch mode should mutate the clipboard (§7).
    ///
    /// - Parameters:
    ///   - clipboard: the already-read plain-text clipboard content (the original,
    ///     pre-repair string the user copied). Used for the size bound (gate 3) and
    ///     line count.
    ///   - isPlainText: whether the pasteboard item is a plain-text (`public.utf8-plain-text`)
    ///     representation. Non-string / rich items are left untouched (gate 2, §7.2);
    ///     the plumbing determines this from the pasteboard types.
    ///   - frontmostBundleID: bundle id of the frontmost app, or `nil` if unknown
    ///     (gate 1, §7.1).
    ///   - report: the `RepairReport` from the pure repair — `changed` drives gate 4.
    ///   - analysis: `Signals.analyze(...)` for the content — `shell.passesGate`
    ///     drives gate 5, `structure.vetoes` drives gate 6.
    ///   - config: the allowlist and size bound (§8.3).
    public static func decide(
        clipboard: String,
        isPlainText: Bool,
        frontmostBundleID: String?,
        report: RepairReport,
        analysis: Signals.Analysis,
        config: Config = .init()
    ) -> Decision {
        let byteCount = clipboard.utf8.count
        // Line count is informational (for the log); a trailing newline does not add
        // a phantom line.
        let lineCount =
            clipboard.isEmpty
            ? 0 : clipboard.split(separator: "\n", omittingEmptySubsequences: false).count

        let outcomes: [GateOutcome] = [
            terminalGate(frontmostBundleID, config: config),  // §7.1
            plainTextGate(isPlainText),  // §7.2
            sizeGate(byteCount: byteCount, config: config),  // §7.3
            changedGate(report),  // §7.4
            shellGate(analysis.shell, config: config),  // §7.5
            structureGate(analysis.structure, config: config),  // §7.6
        ]

        // §7.4 safe-dedent fast path: when the repair's only change is a whitespace
        // de-gutter (`report.dedentOnly`), the shell-signal (§7.5) and structure-risk
        // (§7.6) gates are waived — stripping a uniform render gutter never merges
        // lines or alters relative indent, so it is safe even on a table/markdown/
        // prose copy the content gates would otherwise veto. The terminal, plain-text,
        // size, and changed gates (1–4) still bind. A power-user float override on
        // gate 5 or 6 opts back into the strict ladder for that gate.
        let waivable: Set<Gate> = [.shellSignal, .structureRiskClear]
        let fastPathEligible =
            report.dedentOnly
            && config.shellSignalScoreThreshold == nil
            && config.structureRiskThreshold == nil
        let shouldMutate = outcomes.allSatisfy { outcome in
            outcome.passed || (fastPathEligible && waivable.contains(outcome.gate))
        }
        // Mark the fast path only when it actually mattered: we mutated *and* a
        // waivable gate was failing (so this was not an ordinary all-pass mutation).
        let waivedAFailure = outcomes.contains { waivable.contains($0.gate) && !$0.passed }
        let viaDedentFastPath = shouldMutate && fastPathEligible && waivedAFailure

        return Decision(
            shouldMutate: shouldMutate,
            viaDedentFastPath: viaDedentFastPath,
            outcomes: outcomes,
            byteCount: byteCount,
            lineCount: lineCount
        )
    }

    /// Convenience overload that derives the §6.7 signals from the clipboard content
    /// itself — the common watcher path, where signals are judged on the copied
    /// (original) string. Tests and power users that pre-compute signals on a
    /// different string can call the primary overload with their own `Analysis`.
    public static func decide(
        clipboard: String,
        isPlainText: Bool,
        frontmostBundleID: String?,
        report: RepairReport,
        config: Config = .init()
    ) -> Decision {
        decide(
            clipboard: clipboard,
            isPlainText: isPlainText,
            frontmostBundleID: frontmostBundleID,
            report: report,
            // Judge gate 5/6 on the *normalized* text — the same subject the repair
            // classifies (§6.7) — so escape-sequence punctuation (the `;` in a
            // `[1;34m` SGR or an OSC `]52;c;…`) can never masquerade as a shell
            // operator and trip a false-positive signal (§13 ANSI/OSC fixtures).
            analysis: Signals.analyze(Repair.normalize(clipboard)),
            config: config
        )
    }

    // MARK: - Per-gate evaluation

    /// Gate 1 — frontmost app is an allowlisted terminal (§7.1).
    private static func terminalGate(_ bundleID: String?, config: Config) -> GateOutcome {
        guard let bundleID else {
            return GateOutcome(
                gate: .terminalAllowlisted,
                passed: false,
                detail: "no frontmost app"
            )
        }
        let allowed = config.terminalAllowlist.contains(bundleID)
        return GateOutcome(
            gate: .terminalAllowlisted,
            passed: allowed,
            detail: allowed
                ? "frontmost \(bundleID) is allowlisted"
                : "frontmost \(bundleID) not in allowlist"
        )
    }

    /// Gate 2 — clipboard item is plain text (§7.2).
    private static func plainTextGate(_ isPlainText: Bool) -> GateOutcome {
        GateOutcome(
            gate: .plainText,
            passed: isPlainText,
            detail: isPlainText ? "plain text" : "non-string / rich item — untouched"
        )
    }

    /// Gate 3 — size bound (§7.3).
    private static func sizeGate(byteCount: Int, config: Config) -> GateOutcome {
        let withinBound = byteCount <= config.maxClipboardBytes
        return GateOutcome(
            gate: .sizeWithinBound,
            passed: withinBound,
            detail: "\(byteCount) B " + (withinBound ? "≤ " : "> ")
                + "\(config.maxClipboardBytes) B bound"
        )
    }

    /// Gate 4 — the repair made a *structural* change (§7.4): a wrap rejoin or a
    /// dedent, not merely §6.1 normalization. A copy that only carried escape/CRLF
    /// noise (stripped by normalize) has nothing to fix and must not be rewritten.
    private static func changedGate(_ report: RepairReport) -> GateOutcome {
        GateOutcome(
            gate: .repairChangedContent,
            passed: report.structuralChange,
            detail: report.structuralChange
                ? "structural repair (rejoin/dedent)"
                : (report.changed ? "normalization only — no structural change" : "no change")
        )
    }

    /// Gate 5 — high-confidence shell signal (§7.5 / §6.7). Discrete tiers by
    /// default; a configured `shellSignalScoreThreshold` switches to the float
    /// score (§8.3 power-user override).
    private static func shellGate(_ shell: Signals.Shell, config: Config) -> GateOutcome {
        if let threshold = config.shellSignalScoreThreshold {
            let passed = shell.score >= threshold
            return GateOutcome(
                gate: .shellSignal,
                passed: passed,
                detail: "shell score \(scoreString(shell.score)) "
                    + (passed ? "≥ " : "< ") + "\(scoreString(threshold)) threshold"
            )
        }
        return GateOutcome(
            gate: .shellSignal,
            passed: shell.passesGate,
            detail: "shell signals: \(shell.strongCount) strong / \(shell.weakCount) weak"
                + (shell.passesGate ? " → pass" : " → fail (need ≥1 strong or ≥2 weak)")
        )
    }

    /// Gate 6 — structure-risk veto (§7.6). Passes when nothing vetoes; a
    /// configured `structureRiskThreshold` switches to the float risk estimate
    /// (§8.3 power-user override).
    private static func structureGate(
        _ structure: Signals.Structure,
        config: Config
    ) -> GateOutcome {
        if let threshold = config.structureRiskThreshold {
            let clear = structure.risk < threshold
            return GateOutcome(
                gate: .structureRiskClear,
                passed: clear,
                detail: "structure risk \(scoreString(structure.risk)) "
                    + (clear ? "< " : "≥ ") + "\(scoreString(threshold)) threshold"
            )
        }
        let clear = !structure.vetoes
        return GateOutcome(
            gate: .structureRiskClear,
            passed: clear,
            detail: clear ? "no structure-risk veto" : "veto: \(structureVetoReason(structure))"
        )
    }

    private static func scoreString(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Which structure pattern(s) fired the veto, for the log detail (§7.6).
    private static func structureVetoReason(_ structure: Signals.Structure) -> String {
        var reasons: [String] = []
        if structure.markdownDominant { reasons.append("markdown") }
        if structure.stackTrace { reasons.append("stack-trace") }
        if structure.prose { reasons.append("prose") }
        if structure.tabular { reasons.append("table") }
        return reasons.isEmpty ? "unknown" : reasons.joined(separator: "+")
    }
}
