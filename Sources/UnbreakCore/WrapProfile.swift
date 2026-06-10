/// Per-tool wrap behavior as data, not a framework (PRD v2 §6.6).
///
/// Adding Gemini/Codex support should be a new value here plus fixtures, not new
/// code paths. v1 ships `claudeCode` only.
public struct WrapProfile: Sendable, Equatable {
    public var name: String
    /// Tokens that, when a line ends with one, mark an *intentional* line break
    /// (heredoc/`\` layout/one-operator-per-line) that must be preserved (§6.3).
    public var continuationTokens: [String]
    public var tabWidth: Int
    /// Minimum wrap-column confidence before rejoin is attempted (§6.3).
    public var minWrapConfidence: Double
    /// Minimum run of spaces that can mark a merge artifact's hidden newline (§6.5).
    public var minPaddingRun: Int
    /// Leading "quote bar" glyphs a CLI renders as a left margin around a quoted or
    /// previewed block. Claude Code's queued-prompt box prefixes every line with
    /// `  ▎ ` (U+258E). When a dominant run of lines opens with
    /// `<whitespace>* <bar> <space>?`, that prefix is a rendering gutter, not
    /// content, and is stripped in §6.2 — exactly like the whitespace gutter.
    public var gutterBars: [Character]

    public init(
        name: String,
        continuationTokens: [String],
        tabWidth: Int = DisplayWidth.defaultTabWidth,
        minWrapConfidence: Double = 0.5,
        minPaddingRun: Int = 3,
        gutterBars: [Character] = []
    ) {
        self.name = name
        self.continuationTokens = continuationTokens
        self.tabWidth = tabWidth
        self.minWrapConfidence = minWrapConfidence
        self.minPaddingRun = minPaddingRun
        self.gutterBars = gutterBars
    }

    public static let claudeCode = WrapProfile(
        name: "claude-code",
        continuationTokens: ["\\", "&&", "||", "|", "(", ","],
        gutterBars: ["\u{258E}"]  // ▎ — the queued-prompt preview box bar
    )

    /// Every profile that ships, keyed by its `name` — the lookup the config's
    /// `wrap_profile` key resolves against (§8.3). v1 ships `claude-code` only;
    /// adding Gemini/Codex (§6.6) means adding a value here.
    public static let all: [WrapProfile] = [.claudeCode]

    /// Resolve a profile by `name`, or `nil` if no shipped profile matches. The
    /// config loader turns a `nil` into a warning and falls back to the default.
    public static func named(_ name: String) -> WrapProfile? {
        all.first { $0.name == name }
    }
}

/// One-shot CLI options (PRD v2 §8.1).
public struct RepairOptions: Sendable, Equatable {
    public var forcedWidth: Int?
    public var joinAll: Bool
    /// Lossy merge-artifact split — off by default (§6.5).
    public var splitPaddingArtifacts: Bool

    public init(
        forcedWidth: Int? = nil,
        joinAll: Bool = false,
        splitPaddingArtifacts: Bool = false
    ) {
        self.forcedWidth = forcedWidth
        self.joinAll = joinAll
        self.splitPaddingArtifacts = splitPaddingArtifacts
    }
}
