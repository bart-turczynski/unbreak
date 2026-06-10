import Clipboard
import Testing
import UnbreakCore

@testable import CLI

// A wrapped fragment the repair pipeline collapses (changed=true), and its
// expected repair. Mirrors RepairTests "Case 3".
private let wrapped = " git push\n    --force\n    origin"
private let repaired = "git push\n--force\norigin"
// A clean single line the pipeline returns untouched (changed=false).
private let clean = "git status"

/// In-memory `PasteboardBackend` so the driver runs without a real NSPasteboard.
private final class FakePasteboard: PasteboardBackend {
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
}

/// Capturing environment: an in-memory clipboard plus string buffers for the
/// three streams.
private final class Capture {
    let fake = FakePasteboard()
    var stdinText = ""
    var stdout = ""
    var stderr = ""

    func environment(withClipboard: Bool = true) -> CLI.Environment {
        CLI.Environment(
            clipboard: withClipboard ? Clipboard(backend: fake) : nil,
            readStdin: { self.stdinText },
            writeStdout: { self.stdout += $0 },
            writeStderr: { self.stderr += $0 }
        )
    }
}

@Suite("CLI argument parsing (PRD v2 §8.1)")
struct CLIParseTests {
    private func run(_ argv: [String]) -> CLI.Arguments? {
        if case .run(let args) = CLI.parse(argv) { return args }
        return nil
    }

    @Test("No arguments defaults to in-place clipboard repair (with prose reflow on)")
    func defaults() {
        // The one-shot CLI opts into paragraph reflow by default (Option A); the
        // struct's own default leaves it off, so spell the expectation out.
        #expect(
            run([])
                == CLI.Arguments(
                    source: .clipboard,
                    options: RepairOptions(reflowParagraphs: true)
                )
        )
    }

    @Test("--no-reflow turns the default paragraph reflow back off")
    func noReflow() {
        #expect(run([])?.options.reflowParagraphs == true)
        #expect(run(["--no-reflow"])?.options.reflowParagraphs == false)
    }

    @Test("A bare positional becomes the literal source")
    func literal() {
        #expect(run(["echo hi"])?.source == .literal("echo hi"))
    }

    @Test("`-` selects the stdin source")
    func stdin() {
        #expect(run(["-"])?.source == .stdin)
    }

    @Test("`-` wins even when a positional is also present")
    func stdinBeatsLiteral() {
        #expect(run(["-", "ignored"])?.source == .stdin)
    }

    @Test("Repair flags map onto RepairOptions")
    func repairFlags() {
        let args = run(["--join-all", "--split-padding-artifacts", "--width", "80"])
        #expect(args?.options.joinAll == true)
        #expect(args?.options.splitPaddingArtifacts == true)
        #expect(args?.options.forcedWidth == 80)
    }

    @Test("--no-copy and the watch flags are recorded")
    func behaviourFlags() {
        #expect(run(["--no-copy"])?.noCopy == true)
        #expect(run(["--watch"])?.watch == true)
        #expect(run(["--dry-run-watch"])?.dryRunWatch == true)
    }

    @Test("--help short-circuits to the help case")
    func help() {
        #expect(CLI.parse(["--help"]) == .help)
        #expect(CLI.parse(["-h"]) == .help)
    }

    @Test("An unknown flag is a usage error")
    func unknownFlag() {
        guard case .error = CLI.parse(["--nope"]) else {
            Issue.record("expected an error for an unknown flag")
            return
        }
    }

    @Test("--width without a value is an error")
    func widthMissingValue() {
        guard case .error = CLI.parse(["--width"]) else {
            Issue.record("expected an error for a missing --width value")
            return
        }
    }

    @Test("--width with a non-positive / non-integer value is an error")
    func widthBadValue() {
        guard case .error = CLI.parse(["--width", "wide"]) else {
            Issue.record("expected an error for a non-integer width")
            return
        }
        guard case .error = CLI.parse(["--width", "0"]) else {
            Issue.record("expected an error for a non-positive width")
            return
        }
    }

    @Test("A second positional is an error")
    func extraPositional() {
        guard case .error = CLI.parse(["one", "two"]) else {
            Issue.record("expected an error for a second positional")
            return
        }
    }
}

@Suite("CLI one-shot driver (PRD v2 §8.1)")
struct CLIRunTests {
    @Test("Default clipboard path rewrites in place when the repair changes the text")
    func clipboardRewritesWhenChanged() {
        let cap = Capture()
        cap.fake.string = wrapped
        let code = CLI.runOneShot(CLI.Arguments(source: .clipboard), environment: cap.environment())
        #expect(code == 0)
        #expect(cap.fake.string == repaired)
    }

    @Test("Default clipboard path leaves a clean clipboard untouched")
    func clipboardNoOpWhenClean() {
        let cap = Capture()
        cap.fake.string = clean
        let before = cap.fake.changeCount
        let code = CLI.runOneShot(CLI.Arguments(source: .clipboard), environment: cap.environment())
        #expect(code == 0)
        #expect(cap.fake.changeCount == before)  // no write
        #expect(cap.stderr.contains("already clean"))
    }

    @Test("A literal fragment is always deposited on the clipboard")
    func literalWrites() {
        let cap = Capture()
        let code = CLI.runOneShot(
            CLI.Arguments(source: .literal(wrapped)),
            environment: cap.environment()
        )
        #expect(code == 0)
        #expect(cap.fake.string == repaired)
    }

    @Test("stdin source writes to stdout verbatim and never touches the clipboard")
    func stdinToStdout() {
        let cap = Capture()
        cap.stdinText = wrapped
        let code = CLI.runOneShot(CLI.Arguments(source: .stdin), environment: cap.environment())
        #expect(code == 0)
        #expect(cap.stdout == repaired)  // no trailing newline added
        #expect(cap.fake.string == nil)  // clipboard untouched
        #expect(cap.fake.changeCount == 0)
    }

    @Test("--no-copy prints the result and a confidence summary, writing nothing")
    func noCopyPreview() {
        let cap = Capture()
        cap.fake.string = wrapped
        let args = CLI.Arguments(source: .clipboard, noCopy: true)
        let code = CLI.runOneShot(args, environment: cap.environment())
        #expect(code == 0)
        #expect(cap.stdout.contains(repaired))
        #expect(cap.stderr.contains("changed=yes"))
        #expect(cap.stderr.contains("width="))
        #expect(cap.fake.string == wrapped)  // clipboard left as-is
        #expect(cap.fake.changeCount == 0)
    }

    @Test("--width is threaded into the repair options")
    func widthIsApplied() {
        let cap = Capture()
        cap.stdinText = wrapped
        var args = CLI.Arguments(source: .stdin)
        args.options.forcedWidth = 80
        // Just assert it runs cleanly with the option set; repair semantics are
        // covered exhaustively in UnbreakCoreTests.
        #expect(CLI.runOneShot(args, environment: cap.environment()) == 0)
    }

    @Test("A clipboard operation with no pasteboard available errors out")
    func noClipboardErrors() {
        let cap = Capture()
        let code = CLI.runOneShot(
            CLI.Arguments(source: .clipboard),
            environment: cap.environment(withClipboard: false)
        )
        #expect(code == 1)
        #expect(cap.stderr.contains("no clipboard"))
    }

    @Test("The confidence summary never leaks the payload")
    func confidenceIsContentFree() {
        let report = RepairReport(changed: true, wrapColumnConfidence: 0.9, detectedWidth: 80)
        let summary = CLI.confidenceSummary(report)
        #expect(summary.contains("changed=yes"))
        #expect(summary.contains("width=80"))
        #expect(!summary.contains("git"))
    }
}
