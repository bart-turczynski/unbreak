import Clipboard
import Testing
import UnbreakCore

@testable import Watch

@Suite("Watch daemon gated pipeline (PRD v2 §7)")
struct WatchSessionTests {
    /// The wired-up pieces a test needs to drive and observe a session.
    private struct Fixture {
        let session: WatchSession
        let watcher: Watcher
        let log: CollectingLog
        let clip: Clipboard
    }

    /// Build a session whose watcher reads from `fake`, wired to a collecting log
    /// and a fixed clock.
    private func makeSession(
        _ fake: FakePasteboard,
        frontmost: String? = "com.apple.Terminal",
        dryRun: Bool = false
    ) -> Fixture {
        let clip = Clipboard(backend: fake)
        let watcher = Watcher(clipboard: clip, frontmostBundleID: { frontmost })
        let log = CollectingLog()
        let session = WatchSession(
            watcher: watcher,
            log: log,
            options: .init(dryRun: dryRun),
            now: { "2026-06-06T00:00:00Z" }
        )
        return Fixture(session: session, watcher: watcher, log: log, clip: clip)
    }

    /// A terminal-wrapped command the repair changes and that clears all gates.
    private let wrapped = "git clone foo\n    && cd foo\n        && nested"

    @Test("All gates pass in a terminal → clipboard is mutated in place")
    func mutates() {
        let fake = FakePasteboard()
        let f = makeSession(fake)

        let action = f.session.handle(
            .init(content: wrapped, isPlainText: true, frontmostBundleID: "com.apple.Terminal")
        )

        #expect(action == .mutated)
        // The clipboard now holds the repaired (rejoined) text, and the write was
        // recorded as a self-write so the next poll won't re-trigger.
        #expect(f.clip.plainText() != wrapped)
        #expect(f.clip.lastSelfWriteChangeCount == f.clip.changeCount)
        #expect(f.log.lines.count == 1)
        #expect(f.log.lines[0].contains("decision=mutate"))
        #expect(f.log.lines[0].contains("frontmost=com.apple.Terminal"))
    }

    @Test("Dry-run logs the would-mutate decision but never touches the clipboard")
    func dryRun() {
        let fake = FakePasteboard()
        let f = makeSession(fake, dryRun: true)

        let action = f.session.handle(
            .init(content: wrapped, isPlainText: true, frontmostBundleID: "com.apple.Terminal")
        )

        #expect(action == .wouldMutate)
        #expect(f.clip.lastSelfWriteChangeCount == nil)  // no write happened
        #expect(f.log.lines[0].contains("decision=mutate"))
    }

    @Test("A blocked gate skips the mutation and is named in the action + log")
    func blocked() {
        let fake = FakePasteboard()
        let f = makeSession(fake, frontmost: "com.apple.Safari")

        let action = f.session.handle(
            .init(content: wrapped, isPlainText: true, frontmostBundleID: "com.apple.Safari")
        )

        #expect(action == .skipped(.terminalAllowlisted))
        #expect(f.clip.lastSelfWriteChangeCount == nil)
        #expect(f.log.lines[0].contains("decision=skip"))
        #expect(f.log.lines[0].contains("blocked=terminal-allowlisted"))
    }

    @Test("A non-plain-text item is left untouched and logged as such")
    func nonPlainText() {
        let fake = FakePasteboard()
        let f = makeSession(fake)

        let action = f.session.handle(
            .init(content: nil, isPlainText: false, frontmostBundleID: "com.apple.Terminal")
        )

        #expect(action == .skippedNonPlainText)
        #expect(f.clip.lastSelfWriteChangeCount == nil)
        #expect(f.log.lines[0].contains("blocked=plain-text"))
    }

    @Test("Wiring through poll(): a user copy in a terminal drives a mutation")
    func endToEndPoll() {
        let fake = FakePasteboard()
        let f = makeSession(fake)
        _ = f.session  // installs the onExternalCopy handler on the watcher

        fake.userCopy(wrapped)
        let event = f.watcher.poll()  // surfaces the copy → session.handle → mutate

        guard case .externalCopy = event else {
            Issue.record("expected the user copy to surface as an external copy")
            return
        }
        // The handler ran and rewrote the clipboard to the repaired text.
        #expect(f.clip.plainText() != wrapped)
        #expect(f.clip.lastSelfWriteChangeCount == f.clip.changeCount)
    }

    @Test("A mutation records the original into the rollback buffer (§7.1)")
    func mutationRecordsRollback() {
        let fake = FakePasteboard()
        let f = makeSession(fake)

        f.session.handle(
            .init(content: wrapped, isPlainText: true, frontmostBundleID: "com.apple.Terminal")
        )

        // The pre-mutation original is buffered, and taking it returns exactly it.
        #expect(f.session.rollback.hasValue)
        #expect(f.session.rollback.take() == wrapped)
    }

    @Test("A blocked gate clears any stale rollback original (§7.1)")
    func blockedClearsRollback() {
        let fake = FakePasteboard()
        let f = makeSession(fake, frontmost: "com.apple.Safari")
        f.session.rollback.record("stale original")

        f.session.handle(
            .init(content: wrapped, isPlainText: true, frontmostBundleID: "com.apple.Safari")
        )

        #expect(f.session.rollback.hasValue == false)
    }

    @Test("A non-plain-text copy clears any stale rollback original (§7.1)")
    func nonPlainTextClearsRollback() {
        let fake = FakePasteboard()
        let f = makeSession(fake)
        f.session.rollback.record("stale original")

        f.session.handle(
            .init(content: nil, isPlainText: false, frontmostBundleID: "com.apple.Terminal")
        )

        #expect(f.session.rollback.hasValue == false)
    }

    @Test("Dry-run never records a rollback original (nothing was mutated, §7.1)")
    func dryRunNoRollback() {
        let fake = FakePasteboard()
        let f = makeSession(fake, dryRun: true)

        f.session.handle(
            .init(content: wrapped, isPlainText: true, frontmostBundleID: "com.apple.Terminal")
        )

        #expect(f.session.rollback.hasValue == false)
    }

    @Test("Log line never contains the clipboard payload (content-safe, §7.3)")
    func contentSafe() {
        let fake = FakePasteboard()
        let f = makeSession(fake)
        let secret = "git push --force # SUPER_SECRET_TOKEN=abc123"

        f.session.handle(
            .init(content: secret, isPlainText: true, frontmostBundleID: "com.apple.Terminal")
        )

        for line in f.log.lines {
            #expect(!line.contains("SUPER_SECRET_TOKEN"))
            #expect(!line.contains("abc123"))
        }
    }
}
