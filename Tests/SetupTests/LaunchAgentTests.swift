import Foundation
import Testing

@testable import Setup

@Suite("LaunchAgent plist generation (PRD v2 §7.4)")
struct LaunchAgentPlistTests {
    @Test("Plist embeds the binary path, --watch, and a generic label")
    func plistContents() {
        let xml = LaunchAgent.plist(
            binaryPath: "/opt/homebrew/bin/unbreak",
            standardOutPath: "/Users/x/Library/Logs/unbreak.watch.log"
        )
        #expect(xml.contains("<string>io.unbreak.watch</string>"))
        #expect(xml.contains("<string>/opt/homebrew/bin/unbreak</string>"))
        #expect(xml.contains("<string>--watch</string>"))
        #expect(xml.contains("<key>RunAtLoad</key>"))
        #expect(xml.contains("<key>KeepAlive</key>"))
        #expect(xml.contains("<string>/Users/x/Library/Logs/unbreak.watch.log</string>"))
    }

    @Test("Label carries no personal identifier (fixes the original plist)")
    func genericLabel() {
        #expect(LaunchAgent.label == "io.unbreak.watch")
        #expect(!LaunchAgent.label.contains("/Users/"))
        let xml = LaunchAgent.plist(binaryPath: "/usr/local/bin/unbreak", standardOutPath: "/tmp/o")
        #expect(!xml.lowercased().contains("bartturczynski"))
    }

    @Test("XML special characters in paths are escaped")
    func escaping() {
        let xml = LaunchAgent.plist(
            binaryPath: "/Apps/A & B/unbreak",
            standardOutPath: "/logs/<weird>.log"
        )
        #expect(xml.contains("/Apps/A &amp; B/unbreak"))
        #expect(xml.contains("/logs/&lt;weird&gt;.log"))
        #expect(!xml.contains("A & B"))
    }
}

/// Records every side effect a `LaunchAgentManager` performs so install/uninstall
/// can be asserted without touching launchd or the filesystem.
final class FakeAgentBackend {
    var launchctlCalls: [[String]] = []
    var written: [(String, URL)] = []
    var removed: [URL] = []
    var present: Set<String> = []
    var bootstrapStatus: Int32 = 0
    var binary: String? = "/opt/homebrew/bin/unbreak"
    var writeError: Error?
    /// Whether `launchctl list homebrew.mxcl.unbreak` should report a loaded
    /// brew-services watcher (exit 0). Off by default to match a plain install.
    var brewServiceLoaded = false

    func manager() -> LaunchAgentManager {
        LaunchAgentManager(
            launchAgentsDirectory: URL(fileURLWithPath: "/Users/x/Library/LaunchAgents"),
            standardOutPath: "/Users/x/Library/Logs/unbreak.watch.log",
            binaryPath: { self.binary },
            writeFile: { contents, url in
                if let writeError = self.writeError { throw writeError }
                self.written.append((contents, url))
                self.present.insert(url.path)
            },
            removeFile: { url in
                self.removed.append(url)
                self.present.remove(url.path)
            },
            fileExists: { self.present.contains($0.path) },
            runLaunchctl: { args in
                self.launchctlCalls.append(args)
                if args.first == "bootstrap" { return self.bootstrapStatus }
                // `launchctl list <label>` exits 0 only when the label is loaded.
                if args.first == "list" { return self.brewServiceLoaded ? 0 : 1 }
                return 0  // bootout and friends
            }
        )
    }
}

@Suite("LaunchAgentManager install/uninstall (PRD v2 §8.2)")
struct LaunchAgentManagerTests {
    @Test("Install writes the plist then bootstraps after a defensive bootout")
    func installHappyPath() {
        let backend = FakeAgentBackend()
        let outcome = backend.manager().install()

        #expect(outcome.exitCode == 0)
        #expect(backend.written.count == 1)
        #expect(backend.written[0].1.lastPathComponent == "io.unbreak.watch.plist")
        #expect(backend.written[0].0.contains("/opt/homebrew/bin/unbreak"))
        // bootout (idempotent re-install) precedes bootstrap.
        #expect(backend.launchctlCalls[0][0] == "bootout")
        #expect(backend.launchctlCalls[1][0] == "bootstrap")
    }

    @Test("Install refuses when the binary path cannot be resolved")
    func installNoBinary() {
        let backend = FakeAgentBackend()
        backend.binary = nil
        let outcome = backend.manager().install()
        #expect(outcome.exitCode == 1)
        #expect(backend.written.isEmpty)
        #expect(backend.launchctlCalls.isEmpty)
    }

    @Test("A failed bootstrap surfaces a non-zero outcome but keeps the plist")
    func installBootstrapFails() {
        let backend = FakeAgentBackend()
        backend.bootstrapStatus = 5
        let outcome = backend.manager().install()
        #expect(outcome.exitCode == 1)
        #expect(backend.written.count == 1)
        #expect(outcome.message.contains("bootstrap"))
    }

    @Test("Uninstall of an installed agent boots it out and removes the plist")
    func uninstallExisting() {
        let backend = FakeAgentBackend()
        _ = backend.manager().install()
        let outcome = backend.manager().uninstall()
        #expect(outcome.exitCode == 0)
        #expect(backend.removed.count == 1)
        #expect(outcome.message.contains("removed"))
        #expect(backend.launchctlCalls.last?[0] == "bootout")
    }

    @Test("Uninstall with nothing installed is a clean no-op")
    func uninstallMissing() {
        let backend = FakeAgentBackend()
        let outcome = backend.manager().uninstall()
        #expect(outcome.exitCode == 0)
        #expect(outcome.message.contains("nothing to do"))
    }

    @Test("brewServiceLoaded reflects `launchctl list` for the brew label")
    func brewServiceDetection() {
        let backend = FakeAgentBackend()
        #expect(backend.manager().brewServiceLoaded() == false)
        backend.brewServiceLoaded = true
        #expect(backend.manager().brewServiceLoaded() == true)
        #expect(backend.launchctlCalls.last == ["list", "homebrew.mxcl.unbreak"])
    }

    @Test("Install surfaces an error when writing the plist fails")
    func installWriteFailure() {
        struct WriteError: Error {}
        let backend = FakeAgentBackend()
        backend.writeError = WriteError()
        let outcome = backend.manager().install()
        #expect(outcome.exitCode == 1)
        #expect(outcome.message.contains("failed to write"))
        #expect(backend.launchctlCalls.isEmpty)
    }

    @Test("Uninstall surfaces an error when removing the plist fails")
    func uninstallRemoveFailure() {
        struct RemoveError: Error, LocalizedError {
            var errorDescription: String? { "disk full" }
        }

        var manager = FakeAgentBackend().manager()
        // Pre-seed the plist as present so fileExists returns true.
        manager.fileExists = { _ in true }
        manager.removeFile = { _ in throw RemoveError() }

        let outcome = manager.uninstall()
        #expect(outcome.exitCode == 1)
        #expect(outcome.message.contains("failed to remove"))
    }
}

@Suite("LaunchAgentManager.system production wiring (PRD v2 §8.2)")
struct LaunchAgentSystemTests {
    @Test("system(home:) builds a manager with correct URL layout")
    func systemURLLayout() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unbreak-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let manager = LaunchAgentManager.system(home: tmpHome)
        #expect(manager.launchAgentsDirectory.path.hasSuffix("Library/LaunchAgents"))
        #expect(manager.standardOutPath.hasSuffix("unbreak.watch.log"))
        #expect(manager.plistURL.lastPathComponent == "io.unbreak.watch.plist")
    }

    @Test("resolveBinaryPath returns a non-empty absolute path in the test context")
    func resolveBinaryPath() {
        let path = LaunchAgentManager.resolveBinaryPath()
        #expect(path != nil)
        #expect(path?.isEmpty == false)
    }
}
