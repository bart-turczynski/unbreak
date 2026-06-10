import Foundation
import Watch

/// The `unbreak undo` subcommand (PRD v2 §7.1).
///
/// Sits *in front of* the one-shot `CLI` grammar — like the setup-family verbs in
/// `SetupCommand` — so `unbreak undo` is never read as "repair the literal text
/// `undo`". `parse` returns `nil` for anything that is not `undo`, letting the
/// executable fall through to `CLI.parse`.
///
/// The command is a thin client: it asks the running daemon (over the undo socket)
/// to restore the pre-fix clipboard and reports the daemon's answer. The restore
/// itself happens daemon-side (see `RollbackService`), so this process never
/// touches the clipboard — which is why the work is injected as a `requestUndo`
/// closure and the whole run driver is unit-testable without a socket.
public enum UndoCommand {
    /// A recognized `undo` invocation, or a usage error for one.
    public enum Parsed: Equatable {
        /// `unbreak undo`.
        case undo
        /// A usage error; printed to stderr, exit code 2.
        case error(String)
    }

    /// Parse `argv` (already stripped of the executable path). Returns `nil` when
    /// the first token is not `undo`, so the caller falls through to the one-shot CLI.
    public static func parse(_ argv: [String]) -> Parsed? {
        guard let verb = argv.first, verb == "undo" else { return nil }
        let rest = Array(argv.dropFirst())
        return rest.isEmpty
            ? .undo
            : .error("undo takes no arguments (got '\(rest[0])')")
    }
}

extension UndoCommand {
    /// The injectable surface the run driver writes through: the undo round-trip
    /// and the output streams.
    public struct Environment {
        /// Performs the undo round-trip and returns the daemon's outcome. In
        /// production this is a real `UndoClient` request; tests stub it.
        public var requestUndo: () -> UndoOutcome
        public var writeStdout: (String) -> Void
        public var writeStderr: (String) -> Void

        public init(
            requestUndo: @escaping () -> UndoOutcome,
            writeStdout: @escaping (String) -> Void,
            writeStderr: @escaping (String) -> Void
        ) {
            self.requestUndo = requestUndo
            self.writeStdout = writeStdout
            self.writeStderr = writeStderr
        }
    }

    /// Run a parsed undo command and return the process exit code.
    public static func run(_ command: Parsed, environment: Environment) -> Int32 {
        switch command {
        case .undo:
            return runUndo(environment: environment)
        case .error(let message):
            environment.writeStderr("unbreak: \(message)\n")
            return 2
        }
    }

    private static func runUndo(environment: Environment) -> Int32 {
        switch environment.requestUndo() {
        case .restored:
            environment.writeStdout(
                "unbreak: clipboard restored to the text before the last auto-fix.\n"
            )
            return 0
        case .empty:
            environment.writeStdout(
                "unbreak: nothing to undo (no recent auto-fix, or it was cleared "
                    + "by a newer copy).\n"
            )
            return 0
        case .noDaemon:
            environment.writeStderr(
                """
                unbreak: no running watcher to undo through.
                Start it with `unbreak --watch`, or enable it at login with `unbreak install-agent`.

                """
            )
            return 1
        case .error(let detail):
            environment.writeStderr("unbreak: undo failed: \(detail)\n")
            return 1
        }
    }

    /// The production environment: a real `UndoClient` against the default socket
    /// and the process's standard streams.
    public static func systemEnvironment() -> Environment {
        Environment(
            requestUndo: { UndoClient().requestUndo() },
            writeStdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
            writeStderr: { FileHandle.standardError.write(Data($0.utf8)) }
        )
    }
}
