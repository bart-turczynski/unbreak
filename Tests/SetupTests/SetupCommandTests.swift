import Config
import Foundation
import Testing
import UnbreakCore

@testable import Setup

@Suite("Setup-family argument parsing (PRD v2 §8.2)")
struct SetupCommandParseTests {
    @Test("`setup` parses, with and without --enable-agent")
    func parseSetup() {
        #expect(SetupCommand.parse(["setup"]) == .setup(enableAgent: false))
        #expect(SetupCommand.parse(["setup", "--enable-agent"]) == .setup(enableAgent: true))
    }

    @Test("install-agent / uninstall-agent parse with no arguments")
    func parseAgentVerbs() {
        #expect(SetupCommand.parse(["install-agent"]) == .installAgent)
        #expect(SetupCommand.parse(["uninstall-agent"]) == .uninstallAgent)
    }

    @Test("`uninstall` parses, with and without --keep-config")
    func parseUninstall() {
        #expect(SetupCommand.parse(["uninstall"]) == .uninstall(keepConfig: false))
        #expect(SetupCommand.parse(["uninstall", "--keep-config"]) == .uninstall(keepConfig: true))
    }

    @Test("Unknown uninstall option is a usage error")
    func uninstallBadOption() {
        guard case .error = SetupCommand.parse(["uninstall", "--nope"]) else {
            Issue.record("expected error for unknown uninstall option")
            return
        }
    }

    @Test("Non-setup argv falls through (nil) to the one-shot CLI")
    func fallThrough() {
        #expect(SetupCommand.parse([]) == nil)
        #expect(SetupCommand.parse(["some text"]) == nil)
        #expect(SetupCommand.parse(["--watch"]) == nil)
        #expect(SetupCommand.parse(["-"]) == nil)
    }

    @Test("Unknown setup options and stray agent args are usage errors")
    func errors() {
        guard case .error = SetupCommand.parse(["setup", "--nope"]) else {
            Issue.record("expected error for unknown setup option")
            return
        }
        guard case .error = SetupCommand.parse(["install-agent", "extra"]) else {
            Issue.record("expected error for stray install-agent argument")
            return
        }
    }
}

/// A fully in-memory `SetupCommand.Environment` plus its recording backend.
private final class Harness {
    var stdout = ""
    var stderr = ""
    var answers: [String] = []
    var detected: [TerminalDetector.Terminal] = []
    var configContents: String?
    var configPresent = false
    let backend = FakeAgentBackend()
    let configURL = URL(fileURLWithPath: "/Users/x/.config/unbreak/config.toml")
    /// State files (logs, socket) that uninstall should clean up, and the set
    /// currently "present" on the fake filesystem.
    var stateFiles: [URL] = []
    var present: Set<String> = []
    var removed: [URL] = []
    /// Symlink → target overrides for the injected resolver; paths absent from the
    /// map resolve to themselves (matching the real no-op for non-symlinks).
    var symlinks: [String: String] = [:]

    func environment() -> SetupCommand.Environment {
        SetupCommand.Environment(
            writeStdout: { self.stdout += $0 },
            writeStderr: { self.stderr += $0 },
            readLine: { self.answers.isEmpty ? nil : self.answers.removeFirst() },
            detectTerminals: { self.detected },
            configURL: configURL,
            fileExists: { url in
                if url == self.configURL { return self.configPresent }
                return self.present.contains(url.path)
            },
            writeConfig: { contents, _ in
                self.configContents = contents
                self.configPresent = true
            },
            removeFile: { url in
                self.removed.append(url)
                self.present.remove(url.path)
                if url == self.configURL { self.configPresent = false }
            },
            stateFiles: stateFiles,
            agentManager: backend.manager(),
            resolveSymlinks: { self.symlinks[$0] ?? $0 }
        )
    }
}

@Suite("Setup wizard run flow (PRD v2 §8.2)")
struct SetupRunTests {
    @Test("`setup` answered No writes config but does not install the agent")
    func setupDeclined() {
        let harness = Harness()
        harness.detected = [.init(bundleID: "com.apple.Terminal", displayName: "Apple Terminal")]
        harness.answers = ["n"]

        let code = SetupCommand.run(.setup(enableAgent: false), environment: harness.environment())

        #expect(code == 0)
        #expect(harness.configContents?.contains("terminals = [\"com.apple.Terminal\"]") == true)
        #expect(harness.backend.launchctlCalls.isEmpty)
        #expect(harness.stdout.contains("Watcher left off"))
    }

    @Test("`setup` answered Yes installs the agent")
    func setupAccepted() {
        let harness = Harness()
        harness.detected = [.init(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty")]
        harness.answers = ["y"]

        let code = SetupCommand.run(.setup(enableAgent: false), environment: harness.environment())

        #expect(code == 0)
        #expect(harness.backend.written.count == 1)
        #expect(harness.backend.launchctlCalls.contains { $0.first == "bootstrap" })
    }

    @Test("--enable-agent installs without prompting")
    func enableAgentForced() {
        let harness = Harness()
        harness.detected = [.init(bundleID: "com.apple.Terminal", displayName: "Apple Terminal")]
        // No answers queued: a prompt would read nil → No. Forced flag must win.

        let code = SetupCommand.run(.setup(enableAgent: true), environment: harness.environment())

        #expect(code == 0)
        #expect(harness.backend.launchctlCalls.contains { $0.first == "bootstrap" })
        #expect(!harness.stdout.contains("[y/N]"))
    }

    @Test("No detected terminals falls back to the shipped allowlist in config")
    func noTerminalsFallsBack() {
        let harness = Harness()
        harness.answers = ["n"]

        _ = SetupCommand.run(.setup(enableAgent: false), environment: harness.environment())

        let contents = harness.configContents ?? ""
        for bundleID in WatchGate.Config.defaultTerminalAllowlist {
            #expect(contents.contains(bundleID))
        }
    }

    @Test("An existing config is never overwritten")
    func existingConfigUntouched() {
        let harness = Harness()
        harness.configPresent = true
        harness.answers = ["n"]

        _ = SetupCommand.run(.setup(enableAgent: false), environment: harness.environment())

        #expect(harness.configContents == nil)
        #expect(harness.stdout.contains("already exists"))
    }

    @Test("install-agent / uninstall-agent dispatch to the manager")
    func agentVerbsDispatch() {
        let harness = Harness()
        #expect(SetupCommand.run(.installAgent, environment: harness.environment()) == 0)
        #expect(harness.backend.written.count == 1)
        #expect(SetupCommand.run(.uninstallAgent, environment: harness.environment()) == 0)
        #expect(harness.backend.removed.count == 1)
    }

    @Test("`uninstall` removes the agent, state files, and config")
    func uninstallRemovesEverything() {
        let harness = Harness()
        // A tap install reaches us as the PATH symlink, not the keg path — the
        // resolver must dereference it to see `/Cellar/` and pick the brew hint.
        harness.backend.binary = "/opt/homebrew/bin/unbreak"
        harness.symlinks = [
            "/opt/homebrew/bin/unbreak": "/opt/homebrew/Cellar/unbreak/0.1.1/bin/unbreak"
        ]
        _ = backendInstall(harness)  // an agent is present to remove
        harness.configPresent = true
        let log = URL(fileURLWithPath: "/Users/x/Library/Logs/unbreak.log")
        let sock = URL(fileURLWithPath: "/Users/x/Library/Application Support/unbreak/undo.sock")
        harness.stateFiles = [log, sock]
        harness.present = [log.path, sock.path]

        let code = SetupCommand.run(
            .uninstall(keepConfig: false),
            environment: harness.environment()
        )

        #expect(code == 0)
        #expect(harness.backend.removed.count == 1)  // the plist
        #expect(harness.removed.contains(log))
        #expect(harness.removed.contains(sock))
        #expect(harness.removed.contains(harness.configURL))
        #expect(harness.stdout.contains("unbreak.log"))
        // Tap install (PATH symlink → keg) → brew uninstall hint, never a bare `rm`
        // of the symlink (which would leave brew's keg + receipt behind).
        #expect(harness.stdout.contains("brew uninstall unbreak"))
        #expect(!harness.stdout.contains("rm /opt/homebrew/bin/unbreak"))
    }

    @Test("`uninstall` surfaces the brew-services watcher it can't itself stop")
    func uninstallReportsBrewWatcher() {
        let harness = Harness()
        // No per-user agent installed, but a brew-services watcher is running — the
        // exact state of a user who opted in via `brew services start unbreak`.
        harness.backend.brewServiceLoaded = true

        let code = SetupCommand.run(
            .uninstall(keepConfig: false),
            environment: harness.environment()
        )

        #expect(code == 0)
        #expect(harness.stdout.contains("Homebrew-managed watcher is still running"))
        #expect(harness.stdout.contains("brew services stop unbreak"))
    }

    @Test("`uninstall` stays quiet about brew when no brew watcher is loaded")
    func uninstallNoBrewWatcherIsQuiet() {
        let harness = Harness()  // brewServiceLoaded defaults to false
        _ = SetupCommand.run(.uninstall(keepConfig: false), environment: harness.environment())
        #expect(!harness.stdout.contains("brew services stop"))
    }

    @Test("`uninstall --keep-config` spares the config file")
    func uninstallKeepsConfig() {
        let harness = Harness()
        harness.configPresent = true

        let code = SetupCommand.run(
            .uninstall(keepConfig: true),
            environment: harness.environment()
        )

        #expect(code == 0)
        #expect(!harness.removed.contains(harness.configURL))
        #expect(harness.stdout.contains("Keeping config"))
    }

    @Test("`uninstall` with no state present is a clean no-op")
    func uninstallNothingPresent() {
        let harness = Harness()
        let code = SetupCommand.run(
            .uninstall(keepConfig: false),
            environment: harness.environment()
        )
        #expect(code == 0)
        #expect(harness.removed.isEmpty)
        #expect(harness.stdout.contains("No unbreak state files were present"))
    }

    @Test("`uninstall` steers a non-Homebrew binary to a plain rm")
    func uninstallNonBrewBinary() {
        let harness = Harness()
        harness.backend.binary = "/usr/local/bin/unbreak"
        _ = SetupCommand.run(.uninstall(keepConfig: false), environment: harness.environment())
        #expect(harness.stdout.contains("rm /usr/local/bin/unbreak"))
        #expect(!harness.stdout.contains("brew uninstall"))
    }

    @Test("`uninstall` reports a non-zero exit when the agent removal fails")
    func uninstallAgentFailureIsSurfaced() {
        struct RemoveError: Error, LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let harness = Harness()
        var env = harness.environment()
        // A plist is present but its removal throws — uninstall() returns non-zero.
        env.agentManager.fileExists = { _ in true }
        env.agentManager.removeFile = { _ in throw RemoveError() }

        let code = SetupCommand.run(.uninstall(keepConfig: false), environment: env)

        #expect(code == 1)
        #expect(harness.stderr.contains("failed to remove"))
    }

    @Test("`uninstall` reports a state-file removal that fails")
    func uninstallStateFileFailureIsSurfaced() {
        struct RemoveError: Error, LocalizedError {
            var errorDescription: String? { "permission denied" }
        }
        let harness = Harness()
        let log = URL(fileURLWithPath: "/Users/x/Library/Logs/unbreak.log")
        harness.stateFiles = [log]
        harness.present = [log.path]
        var env = harness.environment()
        env.removeFile = { _ in throw RemoveError() }

        let code = SetupCommand.run(.uninstall(keepConfig: false), environment: env)

        #expect(code == 1)
        #expect(harness.stderr.contains("could not remove \(log.path)"))
    }

    @Test("`uninstall` leaves the binary in place when its path can't be resolved")
    func uninstallUnresolvedBinary() {
        let harness = Harness()
        harness.backend.binary = nil

        let code = SetupCommand.run(
            .uninstall(keepConfig: false),
            environment: harness.environment()
        )

        #expect(code == 0)
        #expect(harness.stdout.contains("The binary itself was left in place"))
    }

    @Test("StatePaths.all enumerates the logs and undo socket under a home")
    func statePathsLayout() {
        let home = URL(fileURLWithPath: "/Users/x")
        let paths = StatePaths.all(home: home).map(\.path)
        #expect(paths.contains("/Users/x/Library/Logs/unbreak.log"))
        #expect(paths.contains("/Users/x/Library/Logs/unbreak.watch.log"))
        #expect(paths.contains("/Users/x/Library/Application Support/unbreak/undo.sock"))
    }

    /// Install an agent through the harness's backend so a later uninstall has a
    /// plist to bootout + remove.
    private func backendInstall(_ harness: Harness) -> Int32 {
        SetupCommand.run(.installAgent, environment: harness.environment())
    }

    @Test("A parse error routes to stderr with exit code 2")
    func errorOutput() {
        let harness = Harness()
        let code = SetupCommand.run(.error("bad option"), environment: harness.environment())
        #expect(code == 2)
        #expect(harness.stderr.contains("bad option"))
    }

    @Test("Generated config reuses the documented sample defaults")
    func configReusesSample() {
        let contents = SetupCommand.configContents(terminals: ["com.apple.Terminal"])
        #expect(contents.contains("terminals = [\"com.apple.Terminal\"]"))
        // The fully-commented sample is appended so every other knob is documented.
        #expect(contents.contains("poll_interval_ms"))
        #expect(contents.contains("max_clipboard_bytes"))
    }

    @Test("install-agent failure writes to stderr and returns non-zero")
    func installAgentFailure() {
        let harness = Harness()
        harness.backend.bootstrapStatus = 5

        let code = SetupCommand.run(.installAgent, environment: harness.environment())

        #expect(code == 1)
        #expect(harness.stderr.contains("bootstrap"))
        #expect(harness.stdout.isEmpty)
    }

    @Test("writeConfigScaffold reports to stderr when writing the config throws")
    func configWriteFailure() {
        struct WriteError: Error {}
        let harness = Harness()
        harness.detected = [.init(bundleID: "com.apple.Terminal", displayName: "Apple Terminal")]
        harness.answers = ["n"]

        // Override the environment so writeConfig always throws.
        var env = harness.environment()
        env.writeConfig = { _, _ in throw WriteError() }

        _ = SetupCommand.run(.setup(enableAgent: false), environment: env)

        #expect(harness.stderr.contains("could not write"))
    }
}
