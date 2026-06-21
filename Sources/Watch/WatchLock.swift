import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A single-instance advisory lock for the active (mutating) watch daemon
/// (PRD v2 §7.4).
///
/// Without it, two watchers can run at once — e.g. a `brew services` agent
/// (`homebrew.mxcl.unbreak`) *and* an `unbreak setup` LaunchAgent
/// (`io.unbreak.watch`) — and **both** repair the same copy. The second watcher
/// sees the first's rewrite land on the clipboard and runs the repair pipeline
/// over it a second time; that double-process re-merges already-correct lines and
/// corrupts the paste. The lock guarantees at most one watcher ever mutates.
///
/// Backed by `flock(2)` on a lock file under Application Support. The lock lives on
/// the open file descriptor and is released by the kernel when the process exits —
/// including a crash or `SIGKILL` — so there is no stale lock file to reap (the
/// failure mode a pidfile has). Advisory `flock` is mutually exclusive across
/// distinct open file descriptions, so a second watcher *process* is blocked even
/// though both run the same binary.
///
/// `@unchecked Sendable`: a lock instance is owned by one execution context — the
/// daemon's main thread in production, or a single test thread during a handoff
/// (the spare blocks in `waitUntilAcquired()` on its own thread and is not touched
/// concurrently). The `flock` itself is enforced by the kernel across descriptors.
public final class WatchLock: @unchecked Sendable {
    /// The outcome of a non-blocking `acquire()`.
    public enum Acquisition: Equatable, Sendable {
        /// We hold the lock; this process is the sole watcher and may mutate.
        case acquired
        /// Another live watcher already holds it; this process must stand down.
        case heldByAnother
        /// The lock file could not be opened (e.g. permissions); carries `errno`.
        /// The caller may choose to run unguarded rather than disable the feature.
        case unavailable(Int32)
    }

    private let url: URL
    private var fd: Int32 = -1

    public init(url: URL = WatchLock.defaultURL()) {
        self.url = url
    }

    /// `~/Library/Application Support/unbreak/watch.lock` — the same private
    /// directory the undo socket uses (§7.1), created `0700`.
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/unbreak/watch.lock")
    }

    /// Try to take the lock without blocking. `acquired` means this is the only
    /// watcher; `heldByAnother` means a second watcher is already live and this one
    /// should stand down (see `waitUntilAcquired()` for the hot-spare path).
    /// The descriptor is kept open on success so the lock is held for the process
    /// lifetime.
    public func acquire() -> Acquisition {
        #if canImport(Darwin)
        if fd < 0 {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir.path
            )
            let opened = open(url.path, O_RDWR | O_CREAT, 0o600)
            guard opened >= 0 else { return .unavailable(errno) }
            fd = opened
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return .acquired
        }
        let code = errno
        return (code == EWOULDBLOCK) ? .heldByAnother : .unavailable(code)
        #else
        return .unavailable(0)
        #endif
    }

    /// Block until the lock can be taken — i.e. until the watcher currently holding
    /// it exits — then hold it. A second watcher uses this to wait as a hot spare
    /// rather than exit into a launchd `KeepAlive` restart loop: when the active
    /// watcher dies, the spare inherits the lock and takes over. Must be called only
    /// after `acquire()` returned `.heldByAnother` (so the descriptor is open).
    public func waitUntilAcquired() {
        #if canImport(Darwin)
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_EX)
        #endif
    }

    /// Release the lock and close the descriptor. The kernel releases it on exit
    /// regardless; this exists for clean shutdown and tests.
    public func release() {
        #if canImport(Darwin)
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
        #endif
    }

    deinit { release() }
}

/// How the active (mutating) watch daemon ended up with respect to the
/// single-instance lock — the outcome of `acquireActiveWatchLock`.
public enum WatchLockOutcome: Equatable, Sendable {
    /// We took the lock immediately; this is the sole watcher and may mutate.
    case active
    /// Another watcher held it; we stood by and took over once it exited.
    case tookOverAfterWait
    /// Dry-run mode never mutates, so it does not contend for the lock.
    case dryRun
    /// The lock file could not be opened (carries `errno`); running unguarded.
    case unguarded(Int32)
}

/// Bring the active watch daemon up against the single-instance lock (PRD v2 §7.4),
/// reporting human-readable progress through `warn` and standing by for a handoff
/// through `waitForHandoff` (injected so the blocking wait can be faked in tests).
///
/// Dry-run skips the lock entirely (it never mutates). If another active watcher
/// already holds the lock, we stand by as a hot spare and take over only when it
/// exits — avoiding a launchd `KeepAlive` restart loop when both a brew-services
/// agent and an `unbreak setup` LaunchAgent are installed. A lock the OS refuses to
/// open degrades to running unguarded rather than disabling the feature.
public func acquireActiveWatchLock(
    _ lock: WatchLock,
    dryRun: Bool,
    warn: (String) -> Void,
    waitForHandoff: (WatchLock) -> Void = { $0.waitUntilAcquired() }
) -> WatchLockOutcome {
    guard !dryRun else { return .dryRun }

    switch lock.acquire() {
    case .acquired:
        return .active
    case .heldByAnother:
        warn(
            "unbreak: another watcher is already active; standing by until it exits "
                + "(only one watcher may mutate the clipboard — you likely have both "
                + "`brew services` and `unbreak setup` agents installed)"
        )
        waitForHandoff(lock)
        warn("unbreak: previous watcher exited; this watcher is now active")
        return .tookOverAfterWait
    case .unavailable(let code):
        warn(
            "unbreak: could not acquire the watch lock (errno \(code)); "
                + "continuing without the single-instance guard"
        )
        return .unguarded(code)
    }
}
