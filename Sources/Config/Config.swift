import Foundation
import UnbreakCore

/// User configuration for `unbreak` (PRD v2 §8.3).
///
/// Resolved from three layers, lowest precedence first:
///   1. built-in defaults (this struct's `init` defaults),
///   2. `~/.config/unbreak/config.toml` (or `$XDG_CONFIG_HOME/unbreak/config.toml`),
///   3. `UNBREAK_*` environment variables.
///
/// The fields are already typed and validated; projections (`gateConfig`,
/// `pollInterval`) hand them to the watch daemon (§7). The discrete gate rules
/// ship as the default — the float thresholds are optional power-user overrides
/// that stay `nil` unless the user sets them.
public struct UnbreakConfig: Equatable, Sendable {
    public var terminalAllowlist: Set<String>
    public var pollIntervalMilliseconds: Int
    public var wrapProfile: WrapProfile
    public var maxClipboardBytes: Int
    public var shellSignalScoreThreshold: Double?
    public var structureRiskThreshold: Double?

    public init(
        terminalAllowlist: Set<String> = WatchGate.Config.defaultTerminalAllowlist,
        pollIntervalMilliseconds: Int = 500,
        wrapProfile: WrapProfile = .claudeCode,
        maxClipboardBytes: Int = 16 * 1024,
        shellSignalScoreThreshold: Double? = nil,
        structureRiskThreshold: Double? = nil
    ) {
        self.terminalAllowlist = terminalAllowlist
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.wrapProfile = wrapProfile
        self.maxClipboardBytes = maxClipboardBytes
        self.shellSignalScoreThreshold = shellSignalScoreThreshold
        self.structureRiskThreshold = structureRiskThreshold
    }

    /// The watch-mode gate configuration this config projects to (§7 / §8.3).
    public var gateConfig: WatchGate.Config {
        WatchGate.Config(
            terminalAllowlist: terminalAllowlist,
            maxClipboardBytes: maxClipboardBytes,
            shellSignalScoreThreshold: shellSignalScoreThreshold,
            structureRiskThreshold: structureRiskThreshold
        )
    }

    /// Poll interval as the `TimeInterval` (seconds) `Watcher.start` expects.
    public var pollInterval: TimeInterval {
        Double(pollIntervalMilliseconds) / 1000
    }

    /// A fully-commented sample for `unbreak --init`/the setup wizard and the docs.
    /// Every key shown is the built-in default, so copying it changes nothing.
    public static let sampleTOML = """
        # ~/.config/unbreak/config.toml — unbreak configuration (PRD v2 §8.3)
        # Every value below is the built-in default; uncomment to override.
        # Env vars (UNBREAK_TERMINALS, UNBREAK_POLL_INTERVAL_MS, UNBREAK_WRAP_PROFILE,
        # UNBREAK_MAX_CLIPBOARD_BYTES, UNBREAK_SHELL_SIGNAL_SCORE, UNBREAK_STRUCTURE_RISK)
        # take precedence over this file.

        # Frontmost-app bundle ids watch mode will act in (gate 1, §7.1). Defaults to
        # the popular macOS terminals (Apple Terminal, iTerm2, Ghostty, Kitty, Warp,
        # Alacritty, WezTerm, Hyper, Tabby, cmux); set this to narrow or extend it.
        # terminals = ["com.apple.Terminal", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable"]

        # How often watch mode polls the clipboard, in milliseconds.
        # poll_interval_ms = 500

        # Wrap profile used by the repair pipeline (§6.6). v1 ships "claude-code".
        # wrap_profile = "claude-code"

        # Largest clipboard payload watch mode will touch, in bytes (gate 3, §7.3).
        # max_clipboard_bytes = 16384

        # Optional power-user overrides. Leave unset to keep the shipped discrete
        # rules (gates 5 and 6). When set, the float score/risk is compared instead.
        # [thresholds]
        # shell_signal_score = 0.5   # gate 5 passes when the 0..1 score >= this
        # structure_risk = 0.5       # gate 6 vetoes when the 0..1 risk >= this
        """
}
