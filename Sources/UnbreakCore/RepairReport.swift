/// Confidence signals returned alongside a repair (PRD v2 §6.7).
///
/// The one-shot CLI acts whenever `changed` is true (permissive — the user
/// asked). Watch mode is stricter: it gates on `structuralChange` (§7 gate 4) so a
/// copy that merely *contained* escapes or CRLFs — stripped by §6.1 normalize but
/// carrying no wrap to rejoin and no gutter to remove — is left untouched. Watch
/// mode also applies the discrete shell-signal tiers and the structure-risk veto
/// (§7 gates 5/6); these float fields exist for logging and optional power-user
/// overrides.
public struct RepairReport: Sendable, Equatable {
    public var changed: Bool
    public var dedentChanged: Bool
    public var wrapColumnConfidence: Double
    public var shellSignalScore: Double
    public var structureRisk: Double
    public var heredocDetected: Bool
    public var detectedWidth: Int?

    /// True when the repair's *only* structural change was a whitespace de-gutter —
    /// no wrap rejoin, no quote-bar reflow, no merge-split. Watch mode's safe-dedent
    /// fast path (§7.4) acts on such a repair even when the shell-signal (§7.5) and
    /// structure-risk (§7.6) gates would veto: stripping a uniform render gutter
    /// never merges lines or alters relative indentation, so on an allowlisted
    /// terminal it is the universally-wanted fix (a guttered table/markdown/prose
    /// loses its `  ` margin) and never the dangerous line-merging op the gates
    /// guard against. `false` for hand-built reports, so they keep the strict path.
    public var dedentOnly: Bool

    /// Set by `Repair.repair` to whether the output differs from the *normalized*
    /// input — i.e. the repair did real structural work (a wrap rejoin or a dedent)
    /// rather than just stripping control sequences. `nil` when a report is built by
    /// hand (tests/CLI), in which case `structuralChange` falls back to `changed`.
    private let explicitStructuralChange: Bool?

    /// The watch-mode gate-4 subject (§7.4): true when the repair changed content
    /// *beyond* §6.1 normalization. Falls back to `changed` for hand-built reports.
    public var structuralChange: Bool { explicitStructuralChange ?? changed }

    public init(
        changed: Bool = false,
        dedentChanged: Bool = false,
        wrapColumnConfidence: Double = 0,
        shellSignalScore: Double = 0,
        structureRisk: Double = 0,
        heredocDetected: Bool = false,
        detectedWidth: Int? = nil,
        dedentOnly: Bool = false,
        structuralChange: Bool? = nil
    ) {
        self.changed = changed
        self.dedentChanged = dedentChanged
        self.wrapColumnConfidence = wrapColumnConfidence
        self.shellSignalScore = shellSignalScore
        self.structureRisk = structureRisk
        self.heredocDetected = heredocDetected
        self.detectedWidth = detectedWidth
        self.dedentOnly = dedentOnly
        self.explicitStructuralChange = structuralChange
    }
}

/// Output of the pure repair pipeline (PRD v2 §6).
public struct RepairResult: Sendable, Equatable {
    public let text: String
    public let report: RepairReport

    public init(text: String, report: RepairReport) {
        self.text = text
        self.report = report
    }
}
