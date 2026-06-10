import Clipboard
import Testing
import UnbreakCore

@testable import Watch

/// In-memory pasteboard reused for the watcher's plumbing tests.
final class FakePasteboard: PasteboardBackend {
    var changeCount = 0
    var string: String?
    var plainTextAvailable = true

    func plainText() -> String? { plainTextAvailable ? string : nil }
    func hasPlainText() -> Bool { plainTextAvailable }

    @discardableResult
    func writePlainText(_ string: String) -> Int {
        self.string = string
        plainTextAvailable = true
        changeCount += 1
        return changeCount
    }

    /// Simulate a genuine user copy of plain text.
    func userCopy(_ text: String) {
        string = text
        plainTextAvailable = true
        changeCount += 1
    }
}

@Suite("Watcher plumbing (PRD v2 §7.4)")
struct WatcherTests {
    private func makeWatcher(
        _ fake: FakePasteboard,
        frontmost: String? = "com.apple.Terminal"
    ) -> (Watcher, Clipboard) {
        let clip = Clipboard(backend: fake)
        let watcher = Watcher(clipboard: clip, frontmostBundleID: { frontmost })
        return (watcher, clip)
    }

    @Test("No clipboard change → idle")
    func idle() {
        let fake = FakePasteboard()
        let (watcher, _) = makeWatcher(fake)
        #expect(watcher.poll() == .idle)
        #expect(watcher.poll() == .idle)
    }

    @Test("Watcher seeds from current changeCount and does not fire on pre-existing content")
    func seedsBaseline() {
        let fake = FakePasteboard()
        fake.userCopy("already here")  // copied before the watcher starts
        let (watcher, _) = makeWatcher(fake)
        #expect(watcher.lastChangeCount == fake.changeCount)
        #expect(watcher.poll() == .idle)
    }

    @Test("An external copy is detected with content and frontmost bundle id")
    func detectsExternalCopy() {
        let fake = FakePasteboard()
        let (watcher, _) = makeWatcher(fake, frontmost: "com.googlecode.iterm2")

        var observed: Watcher.ExternalCopy?
        watcher.onExternalCopy = { observed = $0 }

        fake.userCopy("git status")
        let event = watcher.poll()

        let expected = Watcher.ExternalCopy(
            content: "git status",
            isPlainText: true,
            frontmostBundleID: "com.googlecode.iterm2"
        )
        #expect(event == .externalCopy(expected))
        #expect(observed == expected)
    }

    @Test("Our own write is ignored — no feedback loop")
    func ignoresSelfWrite() {
        let fake = FakePasteboard()
        let (watcher, clip) = makeWatcher(fake)

        var fired = false
        watcher.onExternalCopy = { _ in fired = true }

        clip.write("repaired text")  // the mutation we caused
        #expect(watcher.poll() == .selfWrite)
        #expect(!fired)
    }

    @Test("A user copy after our self-write IS detected")
    func detectsCopyAfterSelfWrite() {
        let fake = FakePasteboard()
        let (watcher, clip) = makeWatcher(fake)

        clip.write("ours")
        #expect(watcher.poll() == .selfWrite)

        fake.userCopy("git pull")
        guard case .externalCopy(let copy) = watcher.poll() else {
            Issue.record("expected an external copy")
            return
        }
        #expect(copy.content == "git pull")
    }

    @Test("Non-plain-text item is surfaced with nil content and isPlainText=false")
    func nonPlainText() {
        let fake = FakePasteboard()
        let (watcher, _) = makeWatcher(fake)

        fake.string = "rich"
        fake.plainTextAvailable = false
        fake.changeCount += 1  // a rich/file/image copy

        guard case .externalCopy(let copy) = watcher.poll() else {
            Issue.record("expected an external copy event")
            return
        }
        #expect(copy.content == nil)
        #expect(!copy.isPlainText)
    }

    // MARK: - evaluate(): read-only §7 pipeline

    @Test("evaluate runs repair + gates; a wrapped command in a terminal mutates")
    func evaluateMutates() {
        let fake = FakePasteboard()
        let (watcher, _) = makeWatcher(fake, frontmost: "com.apple.Terminal")

        // A terminal-wrapped command that the repair changes (rejoins) and that
        // carries a strong shell signal (leading `git`, `&&` operators).
        let copy = Watcher.ExternalCopy(
            content: "git clone foo\n    && cd foo\n        && nested",
            isPlainText: true,
            frontmostBundleID: "com.apple.Terminal"
        )
        let evaluation = watcher.evaluate(copy)
        #expect(evaluation != nil)
        #expect(evaluation?.decision.shouldMutate == true)
        #expect(evaluation?.original == copy.content)
        #expect(evaluation?.repaired != copy.content)  // the repair changed it
    }

    @Test("evaluate blocks when the frontmost app is not an allowlisted terminal")
    func evaluateBlocksNonTerminal() {
        let fake = FakePasteboard()
        let (watcher, _) = makeWatcher(fake)

        let copy = Watcher.ExternalCopy(
            content: "git clone foo\n    && cd foo\n        && nested",
            isPlainText: true,
            frontmostBundleID: "com.apple.Safari"
        )
        let evaluation = watcher.evaluate(copy)
        #expect(evaluation?.decision.shouldMutate == false)
        #expect(evaluation?.decision.blockingGate == .terminalAllowlisted)
    }

    @Test("evaluate returns nil for a non-plain-text copy (nothing to repair)")
    func evaluateNilForNonPlainText() {
        let fake = FakePasteboard()
        let (watcher, _) = makeWatcher(fake)
        let copy = Watcher.ExternalCopy(
            content: nil,
            isPlainText: false,
            frontmostBundleID: "com.apple.Terminal"
        )
        #expect(watcher.evaluate(copy) == nil)
    }
}
