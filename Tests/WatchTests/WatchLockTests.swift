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
}
