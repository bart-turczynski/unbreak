import Foundation
import Testing

@testable import Watch

/// Single-instance lock for the active watch daemon (PRD v2 §7.4). The lock keeps a
/// second watcher from double-processing — and thereby corrupting — every copy.
@Suite("WatchLock single-instance guard (PRD v2 §7.4)")
struct WatchLockTests {
    /// A unique lock path under the temp dir, cleaned up after the test.
    private func tempLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("unbreak-test-\(UUID().uuidString)")
            .appendingPathComponent("watch.lock")
    }

    @Test("First acquirer gets the lock")
    func firstAcquires() {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = WatchLock(url: url)
        #expect(lock.acquire() == .acquired)
    }

    @Test("A second lock on the same path is held by another")
    func secondIsBlocked() {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = WatchLock(url: url)
        #expect(first.acquire() == .acquired)

        let second = WatchLock(url: url)
        #expect(second.acquire() == .heldByAnother)

        // The holder still owns it on re-check (idempotent for the same instance).
        #expect(first.acquire() == .acquired)
    }

    @Test("Releasing the first lets the second acquire")
    func releaseHandsOff() {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = WatchLock(url: url)
        #expect(first.acquire() == .acquired)

        let second = WatchLock(url: url)
        #expect(second.acquire() == .heldByAnother)

        first.release()
        #expect(second.acquire() == .acquired)
    }

    @Test("An unopenable lock path reports unavailable, not acquired")
    func unavailableWhenPathUnopenable() throws {
        // Put a regular file where the lock's parent directory would need to be, so
        // createDirectory and open both fail and the lock cannot be taken.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("unbreak-test-\(UUID().uuidString)")
        try Data().write(to: base)  // `base` is now a file, not a directory
        defer { try? FileManager.default.removeItem(at: base) }

        let url = base.appendingPathComponent("nested").appendingPathComponent("watch.lock")
        let lock = WatchLock(url: url)
        guard case .unavailable = lock.acquire() else {
            Issue.record("expected .unavailable for an unopenable lock path")
            return
        }
    }

    @Test("waitUntilAcquired blocks until the holder releases, then takes over")
    func waitUntilAcquiredHandsOff() async {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let holder = WatchLock(url: url)
        #expect(holder.acquire() == .acquired)

        let spare = WatchLock(url: url)
        #expect(spare.acquire() == .heldByAnother)

        // Block a background thread on the handoff; it must not return while the
        // holder still owns the lock.
        let tookOver = Box(false)
        let thread = Thread {
            spare.waitUntilAcquired()
            tookOver.value = true
        }
        thread.start()

        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
        #expect(tookOver.value == false)  // still blocked — holder is alive

        holder.release()  // hand off
        // Spin briefly for the background thread to wake and record the takeover.
        for _ in 0..<50 where !tookOver.value {
            try? await Task.sleep(nanoseconds: 20_000_000)  // 0.02s
        }
        #expect(tookOver.value == true)
    }

    // MARK: - acquireActiveWatchLock orchestration

    @Test("Dry-run never contends for the lock")
    func orchestrationDryRunSkipsLock() {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let warnings = Box<[String]>([])
        let outcome = acquireActiveWatchLock(
            WatchLock(url: url),
            dryRun: true,
            warn: { warnings.value.append($0) },
            waitForHandoff: { _ in Issue.record("dry-run must not wait") }
        )
        #expect(outcome == .dryRun)
        #expect(warnings.value.isEmpty)
    }

    @Test("A free lock makes us the active watcher")
    func orchestrationActive() {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let warnings = Box<[String]>([])
        let outcome = acquireActiveWatchLock(
            WatchLock(url: url),
            dryRun: false,
            warn: { warnings.value.append($0) },
            waitForHandoff: { _ in Issue.record("must not wait when the lock is free") }
        )
        #expect(outcome == .active)
        #expect(warnings.value.isEmpty)
    }

    @Test("A held lock makes us stand by, then take over after the handoff")
    func orchestrationStandbyThenTakeover() {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let holder = WatchLock(url: url)
        #expect(holder.acquire() == .acquired)

        let warnings = Box<[String]>([])
        let waited = Box(false)
        let outcome = acquireActiveWatchLock(
            WatchLock(url: url),
            dryRun: false,
            warn: { warnings.value.append($0) },
            waitForHandoff: { _ in waited.value = true }  // fake the blocking wait
        )
        #expect(outcome == .tookOverAfterWait)
        #expect(waited.value == true)
        #expect(warnings.value.count == 2)  // standby + took-over
        #expect(warnings.value.first?.contains("standing by") == true)
        #expect(warnings.value.last?.contains("now active") == true)
    }

    @Test("An unopenable lock degrades to running unguarded")
    func orchestrationUnguarded() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("unbreak-test-\(UUID().uuidString)")
        try Data().write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("nested").appendingPathComponent("watch.lock")

        let warnings = Box<[String]>([])
        let outcome = acquireActiveWatchLock(
            WatchLock(url: url),
            dryRun: false,
            warn: { warnings.value.append($0) },
            waitForHandoff: { _ in Issue.record("must not wait when the lock is unavailable") }
        )
        guard case .unguarded = outcome else {
            Issue.record("expected .unguarded for an unopenable lock path")
            return
        }
        #expect(warnings.value.count == 1)
        #expect(warnings.value.first?.contains("without the single-instance guard") == true)
    }
}
