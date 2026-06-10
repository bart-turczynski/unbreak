import Foundation
import UnbreakCore

/// Loads `CCFixConfig` from the config file and `UNBREAK_*` environment overrides
/// (PRD v2 §8.3).
///
/// Loading is **forgiving by design**: a malformed file, an unknown key, or an
/// out-of-range value never aborts the load — the offending value is dropped (the
/// built-in default stands) and a human-readable warning is collected. This keeps
/// the login daemon (§8.2) running on a typo'd config instead of silently failing
/// to start; the caller logs the warnings.
public enum ConfigLoader {
    /// A resolved config plus any non-fatal warnings gathered while resolving it.
    public struct Loaded: Equatable, Sendable {
        public var config: CCFixConfig
        public var warnings: [String]

        public init(config: CCFixConfig, warnings: [String] = []) {
            self.config = config
            self.warnings = warnings
        }
    }

    /// Recognized `UNBREAK_*` environment override names.
    public enum EnvKey {
        public static let terminals = "UNBREAK_TERMINALS"
        public static let pollIntervalMs = "UNBREAK_POLL_INTERVAL_MS"
        public static let wrapProfile = "UNBREAK_WRAP_PROFILE"
        public static let maxClipboardBytes = "UNBREAK_MAX_CLIPBOARD_BYTES"
        public static let shellSignalScore = "UNBREAK_SHELL_SIGNAL_SCORE"
        public static let structureRisk = "UNBREAK_STRUCTURE_RISK"
    }

    // Recognized TOML keys (flattened — see `TOML.parse`).
    private enum Key {
        static let terminals = "terminals"
        static let pollIntervalMs = "poll_interval_ms"
        static let wrapProfile = "wrap_profile"
        static let maxClipboardBytes = "max_clipboard_bytes"
        static let shellSignalScore = "thresholds.shell_signal_score"
        static let structureRisk = "thresholds.structure_risk"
        static let all: Set<String> = [
            terminals, pollIntervalMs, wrapProfile, maxClipboardBytes,
            shellSignalScore, structureRisk,
        ]
    }

    // MARK: - Pure resolution (testable without touching the filesystem)

    /// Resolve a config from optional file contents and an environment map.
    /// Pure — no I/O — so the full precedence/validation matrix is unit-testable.
    public static func resolve(
        tomlText: String?,
        environment: [String: String]
    ) -> Loaded {
        var config = CCFixConfig()
        var warnings: [String] = []

        if let tomlText {
            applyFile(tomlText, to: &config, warnings: &warnings)
        }
        applyEnvironment(environment, to: &config, warnings: &warnings)

        return Loaded(config: config, warnings: warnings)
    }

    // MARK: - File layer

    private static func applyFile(
        _ text: String,
        to config: inout CCFixConfig,
        warnings: inout [String]
    ) {
        let table: [String: TOMLValue]
        do {
            table = try TOML.parse(text)
        } catch let TOML.ParseError.syntax(line, message) {
            warnings.append("config.toml line \(line): \(message); ignoring the file")
            return
        } catch {
            warnings.append("config.toml: \(error); ignoring the file")
            return
        }

        for key in table.keys where !Key.all.contains(key) {
            warnings.append("config.toml: unknown key '\(key)'; ignored")
        }

        if let value = table[Key.terminals] {
            if let list = stringArray(value), !list.isEmpty {
                config.terminalAllowlist = Set(list)
            } else {
                warnings.append("config.toml: 'terminals' must be a non-empty array of strings")
            }
        }
        applyInt(table[Key.pollIntervalMs], label: "poll_interval_ms", warnings: &warnings) {
            config.pollIntervalMilliseconds = $0
        }
        if let value = table[Key.wrapProfile] {
            applyProfile(
                stringValue(value),
                source: "config.toml",
                to: &config,
                warnings: &warnings
            )
        }
        applyInt(table[Key.maxClipboardBytes], label: "max_clipboard_bytes", warnings: &warnings) {
            config.maxClipboardBytes = $0
        }
        applyThreshold(
            table[Key.shellSignalScore],
            label: "thresholds.shell_signal_score",
            warnings: &warnings
        ) { config.shellSignalScoreThreshold = $0 }
        applyThreshold(
            table[Key.structureRisk],
            label: "thresholds.structure_risk",
            warnings: &warnings
        ) { config.structureRiskThreshold = $0 }
    }

    // MARK: - Environment layer (highest precedence)

    private static func applyEnvironment(
        _ env: [String: String],
        to config: inout CCFixConfig,
        warnings: inout [String]
    ) {
        if let raw = env[EnvKey.terminals] {
            let list = raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            if list.isEmpty {
                warnings.append("\(EnvKey.terminals) is empty; ignored")
            } else {
                config.terminalAllowlist = Set(list)
            }
        }
        applyEnvInt(env[EnvKey.pollIntervalMs], label: EnvKey.pollIntervalMs, warnings: &warnings) {
            config.pollIntervalMilliseconds = $0
        }
        if let raw = env[EnvKey.wrapProfile] {
            applyProfile(raw, source: EnvKey.wrapProfile, to: &config, warnings: &warnings)
        }
        applyEnvInt(
            env[EnvKey.maxClipboardBytes],
            label: EnvKey.maxClipboardBytes,
            warnings: &warnings
        ) { config.maxClipboardBytes = $0 }
        applyEnvThreshold(
            env[EnvKey.shellSignalScore],
            label: EnvKey.shellSignalScore,
            warnings: &warnings
        ) { config.shellSignalScoreThreshold = $0 }
        applyEnvThreshold(
            env[EnvKey.structureRisk],
            label: EnvKey.structureRisk,
            warnings: &warnings
        ) { config.structureRiskThreshold = $0 }
    }

    // MARK: - Shared validation helpers

    private static func applyProfile(
        _ name: String?,
        source: String,
        to config: inout CCFixConfig,
        warnings: inout [String]
    ) {
        guard let name else {
            warnings.append("\(source): wrap profile must be a string")
            return
        }
        guard let profile = WrapProfile.named(name) else {
            let known = WrapProfile.all.map(\.name).joined(separator: ", ")
            warnings.append("\(source): unknown wrap profile '\(name)' (known: \(known))")
            return
        }
        config.wrapProfile = profile
    }

    /// A positive integer from a TOML value; warns otherwise.
    private static func applyInt(
        _ value: TOMLValue?,
        label: String,
        warnings: inout [String],
        set: (Int) -> Void
    ) {
        guard let value else { return }
        guard case .integer(let n) = value, n > 0 else {
            warnings.append("config.toml: '\(label)' must be a positive integer")
            return
        }
        set(n)
    }

    /// A non-negative threshold (int or float) from a TOML value; warns otherwise.
    private static func applyThreshold(
        _ value: TOMLValue?,
        label: String,
        warnings: inout [String],
        set: (Double) -> Void
    ) {
        guard let value else { return }
        guard let d = doubleValue(value), d >= 0 else {
            warnings.append("config.toml: '\(label)' must be a non-negative number")
            return
        }
        set(d)
    }

    private static func applyEnvInt(
        _ raw: String?,
        label: String,
        warnings: inout [String],
        set: (Int) -> Void
    ) {
        guard let raw else { return }
        guard let n = Int(raw.trimmingCharacters(in: .whitespaces)), n > 0 else {
            warnings.append("\(label) must be a positive integer, got '\(raw)'")
            return
        }
        set(n)
    }

    private static func applyEnvThreshold(
        _ raw: String?,
        label: String,
        warnings: inout [String],
        set: (Double) -> Void
    ) {
        guard let raw else { return }
        guard let d = Double(raw.trimmingCharacters(in: .whitespaces)), d >= 0 else {
            warnings.append("\(label) must be a non-negative number, got '\(raw)'")
            return
        }
        set(d)
    }

    // MARK: - TOMLValue extraction

    private static func stringValue(_ value: TOMLValue) -> String? {
        if case .string(let s) = value { return s }
        return nil
    }

    private static func stringArray(_ value: TOMLValue) -> [String]? {
        guard case .array(let elements) = value else { return nil }
        var result: [String] = []
        for element in elements {
            guard case .string(let s) = element else { return nil }
            result.append(s)
        }
        return result
    }

    private static func doubleValue(_ value: TOMLValue) -> Double? {
        switch value {
        case .double(let d): return d
        case .integer(let n): return Double(n)
        default: return nil
        }
    }

    // MARK: - Filesystem entry point

    /// The config file path: `$XDG_CONFIG_HOME/unbreak/config.toml` when that env
    /// var is set and non-empty, else `~/.config/unbreak/config.toml` (§8.3).
    public static func defaultConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: String
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = xdg
        } else {
            base = NSHomeDirectory() + "/.config"
        }
        return URL(fileURLWithPath: base).appendingPathComponent("unbreak/config.toml")
    }

    /// Load the config from disk + environment. A missing file is normal and
    /// yields the defaults (plus env overrides); only a present-but-broken file
    /// produces warnings.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Loaded {
        let url = defaultConfigURL(environment: environment)
        let text = try? String(contentsOf: url, encoding: .utf8)
        return resolve(tomlText: text, environment: environment)
    }
}
