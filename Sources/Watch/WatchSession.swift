import Foundation
import UnbreakCore

/// The opt-in fix-on-copy daemon's decision-and-act loop (PRD v2 §7).
///
/// `WatchSession` is the integration that the plumbing (`Watcher`), the gate
/// pipeline (`WatchGate`), the repair (`Repair`), the log (`WatchLog`), and the
/// dry-run switch all hang off. For every external copy the `Watcher` surfaces,
/// it runs the read-only §7 evaluation, logs the (content-safe) decision, and —
/// only when **all** gates pass and we are not in dry-run — performs the in-place
/// clipboard mutation that is the entire point of watch mode (§7).
///
/// `handle(_:)` is pure orchestration over injected dependencies (no run loop, no
/// real clock), so the full gated pipeline is unit-testable end to end.
public final class WatchSession {
    /// Tuning for a session.
    public struct Options: Sendable {
        /// Log what *would* happen, never touch the clipboard (`--dry-run-watch`,
        /// §7.2). The primary QA tool for threshold tuning.
        public var dryRun: Bool
        /// Wrap profile forwarded to `Repair.repair` (§6.6 / §8.3).
        public var profile: WrapProfile
        /// Repair knobs forwarded to `Repair.repair` (§6).
        public var repair: RepairOptions
        /// Gate configuration: terminal allowlist + size bound + optional float
        /// thresholds (§8.3).
        public var gate: WatchGate.Config

        public init(
            dryRun: Bool = false,
            profile: WrapProfile = .claudeCode,
            repair: RepairOptions = .init(),
            gate: WatchGate.Config = .init()
        ) {
            self.dryRun = dryRun
            self.profile = profile
            self.repair = repair
            self.gate = gate
        }
    }

    /// What the session did with a single copy — returned for testing and useful
    /// as a structured record for the log.
    public enum Action: Equatable, Sendable {
        /// Non-plain-text (rich/file/image) item — nothing to repair, left untouched.
        case skippedNonPlainText
        /// A gate blocked the mutation; carries the first failing gate.
        case skipped(WatchGate.Gate?)
        /// All gates passed but `dryRun` is on — logged, not applied.
        case wouldMutate
        /// All gates passed and the clipboard was rewritten in place.
        case mutated
    }

    private let watcher: Watcher
    private let log: WatchLog
    private let options: Options
    /// Injected clock, so the log timestamp is deterministic in tests.
    private let now: () -> String
    /// The single-slot rollback buffer (§7.1). Recorded into before a mutation,
    /// cleared when a non-mutated copy goes by. Exposed so the daemon can wire the
    /// same instance into the undo socket server.
    public let rollback: RollbackStore

    public init(
        watcher: Watcher,
        log: WatchLog,
        options: Options = .init(),
        rollback: RollbackStore = RollbackStore(),
        now: @escaping () -> String = WatchSession.iso8601Now
    ) {
        self.watcher = watcher
        self.log = log
        self.options = options
        self.rollback = rollback
        self.now = now
        watcher.onExternalCopy = { [weak self] copy in
            self?.handle(copy)
        }
    }

    /// Run the full gated pipeline for one external copy (§7). Evaluates, logs the
    /// content-safe decision, and mutates the clipboard in place iff every gate
    /// passed and we are not in dry-run.
    @discardableResult
    public func handle(_ copy: Watcher.ExternalCopy) -> Action {
        guard
            let evaluation = watcher.evaluate(
                copy,
                profile: options.profile,
                options: options.repair,
                config: options.gate
            )
        else {
            // Non-plain-text item: §7.2 leaves it untouched. Logged for visibility.
            // A copy we did not mutate is now the clipboard's truth, so any older
            // undoable original is stale — drop it (§7.1).
            rollback.clear()
            let frontmost = copy.frontmostBundleID ?? "unknown"
            log.record("\(now()) frontmost=\(frontmost) decision=skip blocked=plain-text")
            return .skippedNonPlainText
        }

        log.recordDecision(
            timestamp: now(),
            frontmostBundleID: copy.frontmostBundleID,
            decision: evaluation.decision,
            report: evaluation.report
        )

        guard evaluation.decision.shouldMutate else {
            // A gate blocked the rewrite: the copy stands as-is, so clear any stale
            // undoable original (§7.1, "cleared on next user copy").
            rollback.clear()
            return .skipped(evaluation.decision.blockingGate)
        }

        if options.dryRun {
            return .wouldMutate
        }

        // Stash the original before overwriting it, so `unbreak undo` can restore it.
        rollback.record(evaluation.original)
        watcher.applyMutation(evaluation.repaired)
        return .mutated
    }

    /// ISO-8601 timestamp for "now" (the production clock).
    public static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
