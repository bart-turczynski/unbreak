import Clipboard
import Foundation
import UnbreakCore

/// The one-shot command-line surface (PRD v2 §8.1).
///
/// This module is deliberately split from the executable so the argument
/// grammar (`parse`) and the I/O driver (`runOneShot`) are unit-testable without
/// touching a real terminal or `NSPasteboard`. The `unbreak` executable is a thin
/// shim that wires `parse` to stdout/stderr/clipboard and dispatches the watch
/// daemon (§7), which owns its own run loop and lives outside this surface.
public enum CLI {
    /// Where the text to repair comes from.
    public enum Source: Equatable {
        /// `unbreak` — read the clipboard and rewrite it in place (the default).
        case clipboard
        /// `unbreak "text"` — repair the argument; the result goes to the clipboard.
        case literal(String)
        /// `unbreak -` — stdin → stdout; never touches the clipboard.
        case stdin
    }

    /// A fully parsed one-shot invocation.
    public struct Arguments: Equatable {
        public var source: Source
        public var options: RepairOptions
        /// `--no-copy`: print the result + a confidence summary, write nothing.
        public var noCopy: Bool
        /// `--watch` / `--dry-run-watch`: hand off to the daemon (§7). The
        /// executable inspects these; `runOneShot` never sees a watch invocation.
        public var watch: Bool
        public var dryRunWatch: Bool

        public init(
            source: Source = .clipboard,
            options: RepairOptions = .init(),
            noCopy: Bool = false,
            watch: Bool = false,
            dryRunWatch: Bool = false
        ) {
            self.source = source
            self.options = options
            self.noCopy = noCopy
            self.watch = watch
            self.dryRunWatch = dryRunWatch
        }
    }

    /// The outcome of parsing `argv`.
    public enum Parsed: Equatable {
        case run(Arguments)
        case help
        /// A usage error; the message is printed to stderr and exit code 2 used.
        case error(String)
    }

    public static let helpText = """
        unbreak — repair terminal-wrapped clipboard commands (PRD v2 §8.1)

        USAGE:
          unbreak                       fix clipboard in place (default)
          unbreak "text"                fix an argument, write result to clipboard
          unbreak -                     stdin -> stdout (never touches clipboard)
          unbreak --no-copy             print result + confidence, do not write (preview)
          unbreak --join-all            aggressive full-collapse fallback
          unbreak --width N             force the wrap column
          unbreak --no-reflow           keep wrapped prose/markdown line-broken
                                      (skip the §6.2 paragraph reflow, on by default)
          unbreak --split-padding-artifacts
                                      enable the lossy merge-artifact split (§6.5)

        WATCH MODE (opt-in, §7) — fixes the clipboard hands-free on copy, but ONLY
        when every gate passes (allowlisted terminal frontmost, plain text, small,
        repaired, strong shell signal, no structure-risk veto):
          unbreak --watch               run the fix-on-copy daemon (mutates clipboard)
          unbreak --dry-run-watch       run the daemon log-only — never mutates (§7.2)
          unbreak undo                  restore the clipboard to before the last auto-fix
                                      (asks the running watcher; single-slot, §7.1)

        SETUP & LOGIN WATCHER (§8.2) — the watcher is OFF until you opt in here:
          unbreak setup                 interactive: detect terminals, write config,
                                      prompt to enable the watcher at login
          unbreak setup --enable-agent  non-interactive setup that forces the watcher on
          unbreak install-agent         install + start the per-user login LaunchAgent
          unbreak uninstall-agent       stop + remove the login LaunchAgent
          unbreak uninstall             remove all unbreak state (agent, logs, socket,
                                      config); pass --keep-config to spare the config.
                                      Reports how to remove the binary itself.
        """

    /// Parse `argv` (already stripped of the executable path) into a `Parsed`.
    ///
    /// Flags are permissive about order but strict about correctness: an unknown
    /// flag, a `--width` without a positive integer, or a second positional are
    /// usage errors rather than silently ignored.
    public static func parse(_ argv: [String]) -> Parsed {
        var builder = Builder()
        var index = 0
        while index < argv.count {
            let arg = argv[index]
            if arg == "-h" || arg == "--help" {
                return .help
            }
            if let toggle = toggles[arg] {
                toggle(&builder)
            } else if arg == "--width" {
                index += 1
                guard index < argv.count else {
                    return .error("--width requires a positive integer")
                }
                guard let n = Int(argv[index]), n > 0 else {
                    return .error("--width expects a positive integer, got '\(argv[index])'")
                }
                builder.options.forcedWidth = n
            } else if let failure = builder.addPositional(arg) {
                return .error(failure)
            }
            index += 1
        }
        return .run(builder.finish())
    }

    /// Mutable accumulator threaded through `parse`. Resolving the source is
    /// deferred to `finish()` because `-` (stdin) must win over a positional
    /// regardless of the order they appear.
    private struct Builder {
        // The explicit one-shot CLI reflows soft-wrapped prose/markdown by default
        // (Option A): the user asked, so a wrapped paragraph rejoins to one line.
        // `--no-reflow` opts back out. The watcher never goes through here, so its
        // default-options path keeps the conservative §6.3 behavior.
        var options = RepairOptions(reflowParagraphs: true)
        var isStdin = false
        var literal: String?
        var noCopy = false
        var watch = false
        var dryRunWatch = false

        /// Record a positional token. Returns a usage-error message if it is an
        /// unknown flag or a second positional, else `nil`.
        mutating func addPositional(_ arg: String) -> String? {
            if arg.hasPrefix("-") {
                return "unknown flag '\(arg)' (see --help)"
            }
            guard literal == nil else {
                return "unexpected extra argument '\(arg)' (one fragment at a time)"
            }
            literal = arg
            return nil
        }

        func finish() -> Arguments {
            let source: Source = isStdin ? .stdin : literal.map(Source.literal) ?? .clipboard
            return Arguments(
                source: source,
                options: options,
                noCopy: noCopy,
                watch: watch,
                dryRunWatch: dryRunWatch
            )
        }
    }

    /// Value-less flags mapped to the mutation each applies. Kept as a table
    /// (rather than `switch` cases) so `parse` stays within the complexity budget.
    private static let toggles: [String: @Sendable (inout Builder) -> Void] = [
        "-": { $0.isStdin = true },
        "--no-copy": { $0.noCopy = true },
        "--watch": { $0.watch = true },
        "--dry-run-watch": { $0.dryRunWatch = true },
        "--join-all": { $0.options.joinAll = true },
        "--split-padding-artifacts": { $0.options.splitPaddingArtifacts = true },
        "--no-reflow": { $0.options.reflowParagraphs = false },
    ]

    /// The injectable I/O surface `runOneShot` writes through, so the driver can
    /// be exercised with an in-memory clipboard and string buffers in tests.
    public struct Environment {
        /// The clipboard backend, or `nil` when no pasteboard is available
        /// (non-AppKit platforms) — in which case clipboard operations error out.
        public var clipboard: Clipboard?
        public var readStdin: () -> String
        public var writeStdout: (String) -> Void
        public var writeStderr: (String) -> Void

        public init(
            clipboard: Clipboard?,
            readStdin: @escaping () -> String,
            writeStdout: @escaping (String) -> Void,
            writeStderr: @escaping (String) -> Void
        ) {
            self.clipboard = clipboard
            self.readStdin = readStdin
            self.writeStdout = writeStdout
            self.writeStderr = writeStderr
        }
    }

    /// Run a parsed one-shot invocation and return the process exit code.
    ///
    /// Routing (PRD v2 §8.1):
    ///   - `-`        : repair stdin → stdout verbatim; the clipboard is untouched.
    ///   - `--no-copy`: print the repaired text to stdout and a confidence summary
    ///                  to stderr; nothing is written anywhere.
    ///   - `"text"`   : repair the argument and place the result on the clipboard.
    ///   - default    : repair the clipboard and rewrite it *only when the output
    ///                  differs* (permissive — the user asked, but a no-op write
    ///                  would needlessly bump the system change count, §7.4).
    @discardableResult
    public static func runOneShot(
        _ arguments: Arguments,
        profile: WrapProfile = .claudeCode,
        environment: Environment
    ) -> Int32 {
        let input: String
        switch arguments.source {
        case .stdin:
            input = environment.readStdin()
        case .literal(let text):
            input = text
        case .clipboard:
            guard let clipboard = environment.clipboard else {
                environment.writeStderr(noClipboardMessage)
                return 1
            }
            input = clipboard.plainText() ?? ""
        }

        let result = Repair.repair(input, profile: profile, options: arguments.options)
        return deliver(
            result,
            source: arguments.source,
            noCopy: arguments.noCopy,
            environment: environment
        )
    }

    /// Route a completed repair to its destination per the source/`--no-copy`
    /// rules. Split out of `runOneShot` to keep each within the complexity budget.
    private static func deliver(
        _ result: RepairResult,
        source: Source,
        noCopy: Bool,
        environment: Environment
    ) -> Int32 {
        // stdin → stdout passthrough: emit the repaired text verbatim (no added
        // newline), never the clipboard. This is the pipe-friendly surface.
        if case .stdin = source {
            environment.writeStdout(result.text)
            return 0
        }

        if noCopy {
            environment.writeStdout(result.text + "\n")
            environment.writeStderr(confidenceSummary(result.report))
            return 0
        }

        // Both the literal and clipboard sources write to the clipboard; bail
        // clearly if there isn't one.
        guard let clipboard = environment.clipboard else {
            environment.writeStderr(noClipboardMessage)
            return 1
        }

        // In-place clipboard repair acts only when the text changed (a no-op write
        // would needlessly bump the system change count, §7.4). A literal fragment
        // was handed to us explicitly, so it is always deposited.
        if case .clipboard = source, !result.report.changed {
            environment.writeStderr("unbreak: clipboard already clean, nothing to do\n")
        } else {
            clipboard.write(result.text)
        }
        return 0
    }

    private static let noClipboardMessage = "unbreak: no clipboard available on this platform\n"

    /// A one-line, content-free confidence summary for `--no-copy` previews. It
    /// reports the repair signals (§6.7) but never the payload itself.
    static func confidenceSummary(_ report: RepairReport) -> String {
        let width = report.detectedWidth.map(String.init) ?? "?"
        return """
            unbreak: changed=\(report.changed ? "yes" : "no") \
            wrap-confidence=\(format(report.wrapColumnConfidence)) \
            shell-signal=\(format(report.shellSignalScore)) \
            structure-risk=\(format(report.structureRisk)) \
            width=\(width) \
            heredoc=\(report.heredocDetected ? "yes" : "no")

            """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

extension CLI.Environment {
    /// The production environment: a real `NSPasteboard`-backed clipboard (when
    /// available) and the process's standard streams.
    public static func system() -> CLI.Environment {
        #if canImport(AppKit)
        let clipboard: Clipboard? = Clipboard()
        #else
        let clipboard: Clipboard? = nil
        #endif
        return CLI.Environment(
            clipboard: clipboard,
            readStdin: {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                return String(bytes: data, encoding: .utf8) ?? ""
            },
            writeStdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
            writeStderr: { FileHandle.standardError.write(Data($0.utf8)) }
        )
    }
}
