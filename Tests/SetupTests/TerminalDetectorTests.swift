import Testing
import UnbreakCore

@testable import Setup

@Suite("Terminal detection for the allowlist step (PRD v2 §8.2)")
struct TerminalDetectorTests {
    @Test("Only installed candidates are recommended, with display names")
    func filtersInstalled() {
        let installed: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
        let result = TerminalDetector.detect(
            isInstalled: { installed.contains($0) },
            frontmostBundleID: nil
        )
        let ids = Set(result.map(\.bundleID))
        #expect(ids == installed)
        #expect(result.contains { $0.displayName == "iTerm2" })
        #expect(result.contains { $0.displayName == "Apple Terminal" })
    }

    @Test("Frontmost app is included even if not in the candidate set")
    func includesFrontmost() {
        let result = TerminalDetector.detect(
            candidates: [],
            isInstalled: { _ in false },
            frontmostBundleID: "com.example.newterm"
        )
        #expect(result.map(\.bundleID) == ["com.example.newterm"])
        // Unknown bundle id falls back to itself as the display name.
        #expect(result.first?.displayName == "com.example.newterm")
    }

    @Test("Frontmost terminal already in the set is not duplicated")
    func dedupesFrontmost() {
        let result = TerminalDetector.detect(
            candidates: ["com.apple.Terminal"],
            isInstalled: { _ in true },
            frontmostBundleID: "com.apple.Terminal"
        )
        #expect(result.count == 1)
    }

    @Test("Nothing installed and no frontmost yields an empty recommendation")
    func empty() {
        let result = TerminalDetector.detect(
            isInstalled: { _ in false },
            frontmostBundleID: nil
        )
        #expect(result.isEmpty)
    }

    @Test("Output is sorted by display name for stable prompts")
    func sorted() {
        let result = TerminalDetector.detect(
            candidates: ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2"],
            isInstalled: { _ in true },
            frontmostBundleID: nil
        )
        #expect(result.map(\.displayName) == ["Apple Terminal", "Ghostty", "iTerm2"])
    }
}
