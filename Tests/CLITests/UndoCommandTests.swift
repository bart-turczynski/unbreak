import Testing
import Watch

@testable import CLI

@Suite("`unbreak undo` subcommand (PRD v2 §7.1)")
struct UndoCommandTests {
    /// Captures what the run driver wrote, with a stubbed undo outcome.
    private final class Capture {
        var out = ""
        var err = ""
    }

    private func run(_ command: UndoCommand.Parsed, outcome: UndoOutcome) -> (Int32, Capture) {
        let capture = Capture()
        let environment = UndoCommand.Environment(
            requestUndo: { outcome },
            writeStdout: { capture.out += $0 },
            writeStderr: { capture.err += $0 }
        )
        return (UndoCommand.run(command, environment: environment), capture)
    }

    @Test("parse recognizes the undo verb and rejects trailing arguments")
    func parsing() {
        #expect(UndoCommand.parse(["undo"]) == .undo)
        #expect(
            UndoCommand.parse(["undo", "extra"]) == .error("undo takes no arguments (got 'extra')")
        )
        // Not an undo invocation → nil so the executable falls through to CLI.parse.
        #expect(UndoCommand.parse([]) == nil)
        #expect(UndoCommand.parse(["--watch"]) == nil)
        #expect(UndoCommand.parse(["some text"]) == nil)
    }

    @Test("restored → exit 0 with a confirmation on stdout")
    func restored() {
        let (code, capture) = run(.undo, outcome: .restored)
        #expect(code == 0)
        #expect(capture.out.contains("restored"))
        #expect(capture.err.isEmpty)
    }

    @Test("empty → exit 0 with a nothing-to-undo note")
    func empty() {
        let (code, capture) = run(.undo, outcome: .empty)
        #expect(code == 0)
        #expect(capture.out.contains("nothing to undo"))
    }

    @Test("noDaemon → exit 1 with guidance on starting the watcher")
    func noDaemon() {
        let (code, capture) = run(.undo, outcome: .noDaemon)
        #expect(code == 1)
        #expect(capture.err.contains("no running watcher"))
        #expect(capture.err.contains("--watch"))
    }

    @Test("error → exit 1 with the diagnostic on stderr")
    func error() {
        let (code, capture) = run(.undo, outcome: .error("malformed response from daemon"))
        #expect(code == 1)
        #expect(capture.err.contains("malformed response from daemon"))
    }

    @Test("a usage error exits 2")
    func usageError() {
        let (code, capture) = run(.error("undo takes no arguments (got 'x')"), outcome: .empty)
        #expect(code == 2)
        #expect(capture.err.contains("undo takes no arguments"))
    }

    @Test("systemEnvironment constructs the production environment without crashing")
    func systemEnvironment() {
        // Exercises the closure-building code path; closures are stored, not called.
        _ = UndoCommand.systemEnvironment()
    }
}
