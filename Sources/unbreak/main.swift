import CLI
import Clipboard
import Config
import Foundation
import Setup
import UnbreakCore
import Watch

#if canImport(AppKit)
import AppKit
#endif

// Thin shim over the `CLI` surface (PRD v2 §8.1): load user config (§8.3), parse
// argv, then either run a setup-family subcommand (§8.2), hand off to the watch
// daemon (§7) — which owns the run loop — or run a one-shot repair through the
// shared `Clipboard` backend.

let loaded = ConfigLoader.load()
for warning in loaded.warnings {
    FileHandle.standardError.write(Data("unbreak: \(warning)\n".utf8))
}
let config = loaded.config

let argv = Array(CommandLine.arguments.dropFirst())

// Setup-family verbs (`setup`, `install-agent`, `uninstall-agent`) are handled
// ahead of the one-shot grammar, which would otherwise read `setup` as literal
// text to repair. `parse` returns nil for everything else, so we fall through.
if let command = SetupCommand.parse(argv) {
    exit(SetupCommand.run(command, environment: SetupCommand.systemEnvironment()))
}

// `unbreak undo` is likewise a verb, not literal text to repair: it asks the running
// daemon to restore the pre-fix clipboard over the undo socket (§7.1).
if let command = UndoCommand.parse(argv) {
    exit(UndoCommand.run(command, environment: UndoCommand.systemEnvironment()))
}

switch CLI.parse(argv) {
case .help:
    print(CLI.helpText)
    exit(0)

case .error(let message):
    FileHandle.standardError.write(Data("unbreak: \(message)\n".utf8))
    exit(2)

case .run(let arguments):
    if arguments.watch || arguments.dryRunWatch {
        runWatchDaemon(dryRun: arguments.dryRunWatch, options: arguments.options, config: config)
    }
    exit(CLI.runOneShot(arguments, profile: config.wrapProfile, environment: .system()))
}

/// Start the opt-in fix-on-copy daemon (§7) and block on the run loop until the
/// process is terminated. Never returns. The `config` (§8.3) supplies the gate
/// allowlist/size bound/thresholds, the wrap profile, and the poll interval.
func runWatchDaemon(dryRun: Bool, options: RepairOptions, config: UnbreakConfig) -> Never {
    #if canImport(AppKit)
    // Single-instance guard (§7.4): only one *mutating* watcher may run, or two
    // daemons double-process every copy and corrupt it. Held for the process
    // lifetime; dry-run never mutates so it does not contend for the lock.
    let lock = WatchLock()
    _ = acquireActiveWatchLock(lock, dryRun: dryRun) { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    _ = lock  // retained so the lock stays taken for the lifetime of the process

    let watcher = Watcher.system()
    let session = WatchSession(
        watcher: watcher,
        log: FileLog.defaultLog(),
        options: .init(
            dryRun: dryRun,
            profile: config.wrapProfile,
            repair: options,
            gate: config.gateConfig
        )
    )
    _ = session  // retained for the lifetime of the process

    // Expose the undo channel only in active mode: there is nothing to undo in
    // dry-run (it never mutates), and the restore must route through this daemon's
    // own clipboard so its self-write suppression doesn't re-repair the undo (§7.1).
    var undoServer: UndoSocketServer?
    if !dryRun {
        let service = RollbackService(
            store: session.rollback,
            restore: { watcher.applyMutation($0) }
        )
        let server = UndoSocketServer(
            socketURL: UndoSocketPath.defaultURL(),
            server: UndoServer(service: service)
        )
        do {
            try server.start()
            undoServer = server
        } catch {
            FileHandle.standardError.write(
                Data("unbreak: `unbreak undo` unavailable — \(error)\n".utf8)
            )
        }
    }
    _ = undoServer  // retained for the lifetime of the process

    watcher.start(pollInterval: config.pollInterval)
    let mode = dryRun ? "dry-run (log-only)" : "active (mutating)"
    FileHandle.standardError.write(
        Data("unbreak: watch mode \(mode); logging to ~/Library/Logs/unbreak.log\n".utf8)
    )
    RunLoop.main.run()
    exit(0)
    #else
    FileHandle.standardError.write(Data("unbreak: watch mode requires macOS\n".utf8))
    exit(1)
    #endif
}
