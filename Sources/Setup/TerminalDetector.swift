import Foundation
import UnbreakCore

#if canImport(AppKit)
import AppKit
#endif

/// Detects which allowlisted terminals are installed, for the setup wizard's
/// allowlist step (PRD v2 §8.2).
///
/// The detection logic is pure: it takes the candidate bundle ids, a probe that
/// answers "is this app installed?", and the current frontmost bundle id, and
/// returns the terminals to seed the allowlist with. The real probe
/// (`NSWorkspace`) and frontmost query live in `system()` so the policy is
/// testable without AppKit.
public enum TerminalDetector {
    /// A terminal the wizard can recommend, with a human-readable name for the
    /// prompt. `bundleID` is what actually lands in the allowlist.
    public struct Terminal: Equatable {
        public var bundleID: String
        public var displayName: String
        public init(bundleID: String, displayName: String) {
            self.bundleID = bundleID
            self.displayName = displayName
        }
    }

    /// Display names for the bundle ids we ship in the default allowlist. A
    /// bundle id without an entry falls back to itself as its label.
    public static let knownNames: [String: String] = [
        "com.cmuxterm.app": "cmux",
        "com.mitchellh.ghostty": "Ghostty",
        "com.googlecode.iterm2": "iTerm2",
        "com.apple.Terminal": "Apple Terminal",
        "net.kovidgoyal.kitty": "Kitty",
        "dev.warp.Warp-Stable": "Warp",
        "dev.warp.Warp-Preview": "Warp Preview",
        "org.alacritty": "Alacritty",
        "com.github.wez.wezterm": "WezTerm",
        "co.zeit.hyper": "Hyper",
        "org.tabby": "Tabby",
    ]

    /// Decide which terminals to recommend for the allowlist.
    ///
    /// - Parameters:
    ///   - candidates: bundle ids to consider (defaults to the shipped allowlist).
    ///   - isInstalled: probe answering whether a bundle id is installed.
    ///   - frontmostBundleID: the currently-frontmost app, if known. When it is a
    ///     terminal we don't otherwise recognize, it is included too — the user is
    ///     plausibly running the wizard from the terminal they want covered.
    /// - Returns: the recommended terminals, de-duplicated and sorted by display
    ///   name for stable prompt output.
    public static func detect(
        candidates: Set<String> = WatchGate.Config.defaultTerminalAllowlist,
        isInstalled: (String) -> Bool,
        frontmostBundleID: String?
    ) -> [Terminal] {
        var bundleIDs = candidates.filter(isInstalled)
        if let frontmost = frontmostBundleID, !frontmost.isEmpty {
            bundleIDs.insert(frontmost)
        }
        return
            bundleIDs
            .map { Terminal(bundleID: $0, displayName: knownNames[$0] ?? $0) }
            .sorted {
                ($0.displayName, $0.bundleID) < ($1.displayName, $1.bundleID)
            }
    }

    #if canImport(AppKit)
    /// The production detector: probe via `NSWorkspace` app-URL lookup and read
    /// the frontmost app's bundle id.
    public static func systemDetected() -> [Terminal] {
        detect(
            isInstalled: { bundleID in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            },
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }
    #endif
}
