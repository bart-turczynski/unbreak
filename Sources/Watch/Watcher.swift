import Clipboard
import Foundation
import UnbreakCore

#if canImport(AppKit)
import AppKit
#endif

/// The watch-mode event loop and app-context detection (PRD v2 §7.4).
///
/// Responsibilities, all kept here so the rest of watch mode stays pure:
///  - **Detect external copies** by polling `NSPasteboard.changeCount` (a single
///    integer read until it advances — cheap enough to run continuously at login).
///  - **Track the frontmost app** (its bundle id) so gate 1 (§7.1) can run; the
///    real source is `NSWorkspace` activation notifications (event-driven).
///  - **Ignore our own writes** so a mutation never re-triggers the loop (§7.4).
///
/// The actual gate decision lives in `WatchGate` (pure, §7) and the repair in
/// `Repair` (pure, §6). This type is the only place `NSPasteboard` / `NSWorkspace`
/// I/O happens, and even that is injected so `poll()`/`evaluate(_:)` are
/// unit-testable against an in-memory `Clipboard`.
///
/// Mutation, dry-run/log-only (§7.2, CLAU-cgikkvfd), observability logging
/// (§7.3, CLAU-ydlgtmhk), and the rollback buffer (§7.1, CLAU-mdafgnyd) build on
/// the `externalCopy` seam below; they are deliberately *not* implemented here.
///
/// `@unchecked Sendable`: a watcher is confined to a single execution context —
/// the main run loop when run as the login daemon (`start()`), or the calling
/// thread in tests (`poll()`/`evaluate(_:)` called directly). Its mutable state
/// is never touched from two threads at once.
public final class Watcher: @unchecked Sendable {
    /// A clipboard change that came from outside the tool (a genuine user copy).
    public struct ExternalCopy: Equatable, Sendable {
        /// The plain-text payload, or `nil` for a non-plain-text (rich/file/image)
        /// item that we read but must leave untouched (§7.2).
        public let content: String?
        /// Whether the item is plain text we may rewrite (gate 2).
        public let isPlainText: Bool
        /// Frontmost app bundle id at the moment of the copy, or `nil` if unknown
        /// (gate 1).
        public let frontmostBundleID: String?

        public init(content: String?, isPlainText: Bool, frontmostBundleID: String?) {
            self.content = content
            self.isPlainText = isPlainText
            self.frontmostBundleID = frontmostBundleID
        }
    }

    /// What a single `poll()` observed.
    public enum Event: Equatable, Sendable {
        /// `changeCount` did not advance — nothing to do (the steady state).
        case idle
        /// The change was our own write; ignored to break the feedback loop (§7.4).
        case selfWrite
        /// A genuine external copy to (possibly) act on.
        case externalCopy(ExternalCopy)
    }

    /// The result of running the read-only §7 pipeline over an external copy.
    public struct Evaluation: Equatable, Sendable {
        /// The full gate decision (which gates passed, byte/line counts, log line).
        public let decision: WatchGate.Decision
        /// The §6 repair report — its signal floats feed the content-safe log (§7.3).
        public let report: RepairReport
        /// The original copied text, kept so a rollback buffer can restore it (§7.1).
        public let original: String
        /// The repaired text the mutation step would write if `decision.shouldMutate`.
        public let repaired: String

        public init(
            decision: WatchGate.Decision,
            report: RepairReport,
            original: String,
            repaired: String
        ) {
            self.decision = decision
            self.report = report
            self.original = original
            self.repaired = repaired
        }
    }

    private let clipboard: Clipboard
    private let frontmostBundleID: () -> String?

    /// The last `changeCount` we have accounted for. Seeded from the current
    /// clipboard so the watcher never fires on whatever happened to be copied
    /// before it started.
    public private(set) var lastChangeCount: Int

    /// Invoked for every external copy, before `poll()` returns. The default watch
    /// loop sets this to the gate/mutate handler; tests use it to observe events.
    public var onExternalCopy: ((ExternalCopy) -> Void)?

    public init(clipboard: Clipboard, frontmostBundleID: @escaping () -> String?) {
        self.clipboard = clipboard
        self.frontmostBundleID = frontmostBundleID
        self.lastChangeCount = clipboard.changeCount
    }

    /// One poll step: classify the clipboard's current state relative to the last
    /// one we saw. Pure orchestration over the injected `Clipboard` and frontmost
    /// provider — no timers, no run loop — so the loop's logic is testable.
    @discardableResult
    public func poll() -> Event {
        let current = clipboard.changeCount
        guard current != lastChangeCount else { return .idle }
        lastChangeCount = current

        // Our own mutation bumped the count — swallow it (§7.4).
        if clipboard.isSelfWrite(current) { return .selfWrite }

        let isPlainText = clipboard.hasPlainText()
        let copy = ExternalCopy(
            content: isPlainText ? clipboard.plainText() : nil,
            isPlainText: isPlainText,
            frontmostBundleID: frontmostBundleID()
        )
        onExternalCopy?(copy)
        return .externalCopy(copy)
    }

    /// Run the read-only §7 pipeline for an external copy: repair (§6), derive the
    /// signals (§6.7), and compute the gate `Decision` (§7). Performs **no**
    /// clipboard mutation — that, dry-run, logging, and rollback are layered on by
    /// their own tasks. Returns `nil` for a non-plain-text item (nothing to repair).
    public func evaluate(
        _ copy: ExternalCopy,
        profile: WrapProfile = .claudeCode,
        options: RepairOptions = .init(),
        config: WatchGate.Config = .init()
    ) -> Evaluation? {
        guard let content = copy.content else { return nil }
        let result = Repair.repair(content, profile: profile, options: options)
        let decision = WatchGate.decide(
            clipboard: content,
            isPlainText: copy.isPlainText,
            frontmostBundleID: copy.frontmostBundleID,
            report: result.report,
            config: config
        )
        return Evaluation(
            decision: decision,
            report: result.report,
            original: content,
            repaired: result.text
        )
    }

    /// Write a repaired payload to the clipboard, recording it as a self-write so
    /// the next `poll()` swallows it instead of re-triggering the loop (§7.4). The
    /// gated-pipeline daemon (`WatchSession`) calls this only after a
    /// `Decision.shouldMutate`. Mutation routes through the watcher because it owns
    /// the `Clipboard` and thus the self-write bookkeeping.
    public func applyMutation(_ text: String) {
        clipboard.write(text)
    }

    // MARK: - Run loop (AppKit)

    #if canImport(AppKit)
    private var pollTimer: Timer?
    private var frontmostTracker: FrontmostAppTracker?

    /// Wire a watcher onto the system: `NSPasteboard.general` plus event-driven
    /// frontmost-app tracking. Call `start(pollInterval:)` to begin polling.
    public static func system() -> Watcher {
        let tracker = FrontmostAppTracker()
        let watcher = Watcher(
            clipboard: Clipboard(),
            frontmostBundleID: { tracker.bundleID }
        )
        watcher.frontmostTracker = tracker
        return watcher
    }

    /// Begin polling on the current run loop and start frontmost-app tracking.
    /// The poll is `changeCount`-gated, so a short interval is still cheap.
    public func start(pollInterval: TimeInterval = 0.5) {
        frontmostTracker?.start()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Stop polling and frontmost-app tracking.
    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        frontmostTracker?.stop()
    }
    #endif
}

#if canImport(AppKit)
/// Event-driven frontmost-app tracker (§7.4). Caches the frontmost bundle id and
/// updates it from `NSWorkspace` activation notifications, so reading it during a
/// poll is just a property access — no synchronous `NSWorkspace` query per tick.
///
/// `@unchecked Sendable`: all access is confined to the main thread — the
/// activation notification is delivered on the `.main` queue and `bundleID` is
/// read from the watcher's main-run-loop poll. There is no cross-thread access.
public final class FrontmostAppTracker: @unchecked Sendable {
    public private(set) var bundleID: String?
    private var observer: NSObjectProtocol?

    public init() {
        bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        observer = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.bundleID =
                app?.bundleIdentifier
                ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    deinit { stop() }
}
#endif
