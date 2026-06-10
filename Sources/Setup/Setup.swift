import Config
import Foundation
import UnbreakCore

/// The setup-family subcommands (PRD v2 §8.2): the install wizard and the
/// LaunchAgent lifecycle commands.
///
/// These sit *in front of* the one-shot `CLI` grammar: `unbreak setup` must not be
/// read as "repair the literal text `setup`". `parse` therefore returns `nil` for
/// anything that is not a setup-family command, letting the executable fall
/// through to `CLI.parse`. The run driver's I/O is injected via `Environment` so
/// the whole flow — prompts, config write, agent install — is unit-testable.
public enum SetupCommand {
    /// A recognized setup-family invocation, or a usage error for one.
    public enum Parsed: Equatable {
        /// `unbreak setup [--enable-agent]`. `enableAgent` forces the watcher on
        /// without prompting (for scripted installs).
        case setup(enableAgent: Bool)
        /// `unbreak install-agent`.
        case installAgent
        /// `unbreak uninstall-agent`.
        case uninstallAgent
        /// `unbreak uninstall [--keep-config]`. Tear down every trace of unbreak
        /// *state* — the login LaunchAgent, logs, and the undo socket, plus the
        /// config file unless `keepConfig`. The binary is reported, not deleted
        /// (a running, possibly Homebrew-managed binary can't safely remove
        /// itself — §9).
        case uninstall(keepConfig: Bool)
        /// A usage error; printed to stderr, exit code 2.
        case error(String)
    }

    /// Parse `argv` (already stripped of the executable path). Returns `nil` when
    /// the first token is not a setup-family verb, so the caller can fall through
    /// to the one-shot CLI.
    public static func parse(_ argv: [String]) -> Parsed? {
        guard let verb = argv.first else { return nil }
        let rest = Array(argv.dropFirst())
        switch verb {
        case "setup":
            return parseSetup(rest)
        case "install-agent":
            return rest.isEmpty
                ? .installAgent
                : .error("install-agent takes no arguments (got '\(rest[0])')")
        case "uninstall-agent":
            return rest.isEmpty
                ? .uninstallAgent
                : .error("uninstall-agent takes no arguments (got '\(rest[0])')")
        case "uninstall":
            return parseUninstall(rest)
        default:
            return nil
        }
    }

    private static func parseUninstall(_ rest: [String]) -> Parsed {
        var keepConfig = false
        for arg in rest {
            switch arg {
            case "--keep-config":
                keepConfig = true
            default:
                return .error("unknown uninstall option '\(arg)' (see --help)")
            }
        }
        return .uninstall(keepConfig: keepConfig)
    }

    private static func parseSetup(_ rest: [String]) -> Parsed {
        var enableAgent = false
        for arg in rest {
            switch arg {
            case "--enable-agent":
                enableAgent = true
            default:
                return .error("unknown setup option '\(arg)' (see --help)")
            }
        }
        return .setup(enableAgent: enableAgent)
    }
}

extension SetupCommand {
    /// The injectable surface the run driver writes through: prompts, config-file
    /// I/O, terminal detection, and the LaunchAgent manager.
    public struct Environment {
        public var writeStdout: (String) -> Void
        public var writeStderr: (String) -> Void
        /// Reads one line of user input (without the trailing newline), or `nil`
        /// at EOF / when no terminal is attached — treated as "no".
        public var readLine: () -> String?
        /// The terminals to seed the allowlist with (already detected).
        public var detectTerminals: () -> [TerminalDetector.Terminal]
        public var configURL: URL
        /// Reports whether a file exists at `url` (config presence and, during
        /// uninstall, each state file).
        public var fileExists: (URL) -> Bool
        public var writeConfig: (_ contents: String, _ url: URL) throws -> Void
        /// Removes the file at `url` (used by uninstall); a missing file is fine.
        public var removeFile: (_ url: URL) throws -> Void
        /// The unbreak-created state files uninstall should clean up beyond the
        /// config and LaunchAgent: the watch logs and the undo socket (§7.1, §7.3).
        public var stateFiles: [URL]
        public var agentManager: LaunchAgentManager
        /// Resolves symlinks in a filesystem path. Uninstall uses it to classify the
        /// install method: a Homebrew binary reaches us as the PATH symlink
        /// (`<prefix>/bin/unbreak`), which only reveals its `…/Cellar/…` keg once
        /// dereferenced. Injectable so the classification is testable without a real
        /// symlink on disk.
        public var resolveSymlinks: (String) -> String

        public init(
            writeStdout: @escaping (String) -> Void,
            writeStderr: @escaping (String) -> Void,
            readLine: @escaping () -> String?,
            detectTerminals: @escaping () -> [TerminalDetector.Terminal],
            configURL: URL,
            fileExists: @escaping (URL) -> Bool,
            writeConfig: @escaping (_ contents: String, _ url: URL) throws -> Void,
            removeFile: @escaping (_ url: URL) throws -> Void,
            stateFiles: [URL],
            agentManager: LaunchAgentManager,
            resolveSymlinks: @escaping (String) -> String = {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            }
        ) {
            self.writeStdout = writeStdout
            self.writeStderr = writeStderr
            self.readLine = readLine
            self.detectTerminals = detectTerminals
            self.configURL = configURL
            self.fileExists = fileExists
            self.writeConfig = writeConfig
            self.removeFile = removeFile
            self.stateFiles = stateFiles
            self.agentManager = agentManager
            self.resolveSymlinks = resolveSymlinks
        }
    }

    /// Run a parsed setup-family command and return the process exit code.
    public static func run(_ command: Parsed, environment: Environment) -> Int32 {
        switch command {
        case .setup(let enableAgent):
            return runSetup(enableAgent: enableAgent, environment: environment)
        case .installAgent:
            return finish(environment.agentManager.install(), environment: environment)
        case .uninstallAgent:
            return finish(environment.agentManager.uninstall(), environment: environment)
        case .uninstall(let keepConfig):
            return runUninstall(keepConfig: keepConfig, environment: environment)
        case .error(let message):
            environment.writeStderr("unbreak: \(message)\n")
            return 2
        }
    }

    /// The interactive wizard: detect terminals → write the config scaffold →
    /// decide on the login watcher (forced by `--enable-agent`, else prompted).
    private static func runSetup(enableAgent: Bool, environment: Environment) -> Int32 {
        let terminals = environment.detectTerminals()
        reportDetected(terminals, environment: environment)
        writeConfigScaffold(terminals, environment: environment)

        let enable = enableAgent || promptEnableAgent(environment: environment)
        guard enable else {
            environment.writeStdout(
                """
                Watcher left off. Enable it any time with `unbreak install-agent`
                (or re-run `unbreak setup`). One-shot `unbreak` still works regardless.

                """
            )
            return 0
        }
        return finish(environment.agentManager.install(), environment: environment)
    }

    private static func reportDetected(
        _ terminals: [TerminalDetector.Terminal],
        environment: Environment
    ) {
        guard !terminals.isEmpty else {
            environment.writeStdout(
                """
                No known terminals detected. Seeding the allowlist with the shipped
                defaults (Apple Terminal, iTerm2, Ghostty, Kitty, Warp, Warp Preview,
                Alacritty, WezTerm, Hyper, Tabby, cmux). Edit
                \(environment.configURL.path) to adjust.

                """
            )
            return
        }
        let lines =
            terminals
            .map { "  • \($0.displayName)  (\($0.bundleID))" }
            .joined(separator: "\n")
        environment.writeStdout(
            """
            Detected terminals — watch mode will act only when one of these is frontmost:
            \(lines)

            """
        )
    }

    /// Write the config scaffold with the detected allowlist active. An existing
    /// config is never clobbered — the wizard reports it and moves on.
    private static func writeConfigScaffold(
        _ terminals: [TerminalDetector.Terminal],
        environment: Environment
    ) {
        if environment.fileExists(environment.configURL) {
            environment.writeStdout(
                "Config already exists at \(environment.configURL.path); leaving it untouched.\n\n"
            )
            return
        }
        let bundleIDs =
            terminals.isEmpty
            ? WatchGate.Config.defaultTerminalAllowlist
            : Set(terminals.map(\.bundleID))
        do {
            try environment.writeConfig(configContents(terminals: bundleIDs), environment.configURL)
            environment.writeStdout("Wrote \(environment.configURL.path).\n\n")
        } catch {
            environment.writeStderr(
                "unbreak: could not write \(environment.configURL.path): \(error)\n"
            )
        }
    }

    /// Prompt "enable the auto-fix watcher at login? [y/N]". Defaults to **no**:
    /// the watcher stays off unless the user explicitly opts in (§8.2). EOF / no
    /// terminal also reads as no.
    private static func promptEnableAgent(environment: Environment) -> Bool {
        environment.writeStdout("Enable the auto-fix watcher at login? [y/N] ")
        guard let answer = environment.readLine() else { return false }
        let normalized = answer.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "y" || normalized == "yes"
    }

    private static func finish(
        _ outcome: LaunchAgentManager.Outcome,
        environment: Environment
    ) -> Int32 {
        if outcome.exitCode == 0 {
            environment.writeStdout(outcome.message + "\n")
        } else {
            environment.writeStderr(outcome.message + "\n")
        }
        return outcome.exitCode
    }

    /// The production environment: real stdin/stdout/stderr, the default config
    /// path, on-disk config write, `NSWorkspace` terminal detection, and the
    /// system LaunchAgent manager.
    public static func systemEnvironment() -> Environment {
        Environment(
            writeStdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
            writeStderr: { FileHandle.standardError.write(Data($0.utf8)) },
            readLine: { Swift.readLine(strippingNewline: true) },
            detectTerminals: {
                #if canImport(AppKit)
                return TerminalDetector.systemDetected()
                #else
                return []
                #endif
            },
            configURL: ConfigLoader.defaultConfigURL(),
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            writeConfig: { contents, url in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: url, atomically: true, encoding: .utf8)
            },
            removeFile: { url in
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            },
            stateFiles: StatePaths.all(),
            agentManager: .system()
        )
    }

    /// Build a `config.toml` with the chosen allowlist active, followed by the
    /// fully-commented `CCFixConfig.sampleTOML` defaults so every other knob is
    /// documented in place.
    public static func configContents(terminals: Set<String>) -> String {
        let array = terminals.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        return """
            # unbreak configuration — written by `unbreak setup`.
            # The active line below was filled in from detected terminals; the
            # commented defaults that follow document every other available option.
            terminals = [\(array)]

            \(CCFixConfig.sampleTOML)
            """
    }
}
