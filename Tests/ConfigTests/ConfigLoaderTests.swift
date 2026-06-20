import Foundation
import Testing
import UnbreakCore

@testable import Config

@Suite("Config loading: defaults, file, env precedence (PRD v2 §8.3)")
struct ConfigLoaderTests {
    @Test("No file and no env yields the built-in defaults")
    func defaults() {
        let loaded = ConfigLoader.resolve(tomlText: nil, environment: [:])
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.config == UnbreakConfig())
        #expect(loaded.config.terminalAllowlist == WatchGate.Config.defaultTerminalAllowlist)
        #expect(loaded.config.pollIntervalMilliseconds == 500)
        #expect(loaded.config.maxClipboardBytes == 16 * 1024)
        #expect(loaded.config.wrapProfile == .claudeCode)
        #expect(loaded.config.shellSignalScoreThreshold == nil)
    }

    @Test("File values override the defaults")
    func fileOverrides() {
        let toml = """
            terminals = ["com.apple.Terminal"]
            poll_interval_ms = 250
            wrap_profile = "claude-code"
            max_clipboard_bytes = 8192

            [thresholds]
            shell_signal_score = 0.4
            structure_risk = 0.8
            """
        let loaded = ConfigLoader.resolve(tomlText: toml, environment: [:])
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.config.terminalAllowlist == ["com.apple.Terminal"])
        #expect(loaded.config.pollIntervalMilliseconds == 250)
        #expect(loaded.config.maxClipboardBytes == 8192)
        #expect(loaded.config.shellSignalScoreThreshold == 0.4)
        #expect(loaded.config.structureRiskThreshold == 0.8)
    }

    @Test("Env overrides take precedence over the file")
    func envBeatsFile() {
        let toml = """
            terminals = ["com.apple.Terminal"]
            poll_interval_ms = 250
            max_clipboard_bytes = 8192
            """
        let env = [
            ConfigLoader.EnvKey.terminals: "com.mitchellh.ghostty, com.googlecode.iterm2",
            ConfigLoader.EnvKey.pollIntervalMs: "100",
            ConfigLoader.EnvKey.maxClipboardBytes: "4096",
            ConfigLoader.EnvKey.structureRisk: "0.6",
        ]
        let loaded = ConfigLoader.resolve(tomlText: toml, environment: env)
        #expect(loaded.warnings.isEmpty)
        #expect(
            loaded.config.terminalAllowlist == ["com.mitchellh.ghostty", "com.googlecode.iterm2"]
        )
        #expect(loaded.config.pollIntervalMilliseconds == 100)
        #expect(loaded.config.maxClipboardBytes == 4096)
        #expect(loaded.config.structureRiskThreshold == 0.6)
    }

    @Test("A malformed file is ignored with a warning; env still applies")
    func malformedFileFallsBack() {
        let loaded = ConfigLoader.resolve(
            tomlText: "this is not valid toml",
            environment: [ConfigLoader.EnvKey.pollIntervalMs: "300"]
        )
        #expect(loaded.warnings.contains { $0.contains("config.toml") })
        // Defaults stand for the file, env override still lands.
        #expect(loaded.config.terminalAllowlist == WatchGate.Config.defaultTerminalAllowlist)
        #expect(loaded.config.pollIntervalMilliseconds == 300)
    }

    @Test("An unknown key warns but does not abort the load")
    func unknownKeyWarns() {
        let loaded = ConfigLoader.resolve(
            tomlText: "poll_interval_ms = 400\nmystery = 1",
            environment: [:]
        )
        #expect(loaded.config.pollIntervalMilliseconds == 400)
        #expect(loaded.warnings.contains { $0.contains("unknown key 'mystery'") })
    }

    @Test("A bad-typed / out-of-range value warns and keeps the default")
    func badValueWarns() {
        let loaded = ConfigLoader.resolve(
            tomlText: "poll_interval_ms = -5\nmax_clipboard_bytes = \"big\"",
            environment: [:]
        )
        #expect(loaded.config.pollIntervalMilliseconds == 500)  // default kept
        #expect(loaded.config.maxClipboardBytes == 16 * 1024)  // default kept
        #expect(loaded.warnings.count == 2)
    }

    @Test("An unknown wrap profile warns and keeps the default")
    func unknownProfileWarns() {
        let loaded = ConfigLoader.resolve(tomlText: #"wrap_profile = "gemini""#, environment: [:])
        #expect(loaded.config.wrapProfile == .claudeCode)
        #expect(loaded.warnings.contains { $0.contains("unknown wrap profile 'gemini'") })
    }

    @Test("A bad env value warns and keeps the default")
    func badEnvWarns() {
        let loaded = ConfigLoader.resolve(
            tomlText: nil,
            environment: [ConfigLoader.EnvKey.pollIntervalMs: "soon"]
        )
        #expect(loaded.config.pollIntervalMilliseconds == 500)
        #expect(loaded.warnings.contains { $0.contains(ConfigLoader.EnvKey.pollIntervalMs) })
    }

    @Test("An empty UNBREAK_TERMINALS is ignored with a warning")
    func emptyTerminalsEnv() {
        let loaded = ConfigLoader.resolve(
            tomlText: nil,
            environment: [ConfigLoader.EnvKey.terminals: "  ,  "]
        )
        #expect(loaded.config.terminalAllowlist == WatchGate.Config.defaultTerminalAllowlist)
        #expect(loaded.warnings.contains { $0.contains(ConfigLoader.EnvKey.terminals) })
    }

    @Test("The config projects onto WatchGate.Config and the poll TimeInterval")
    func projections() {
        let config = UnbreakConfig(
            terminalAllowlist: ["com.apple.Terminal"],
            pollIntervalMilliseconds: 250,
            maxClipboardBytes: 8192,
            shellSignalScoreThreshold: 0.4
        )
        #expect(config.gateConfig.terminalAllowlist == ["com.apple.Terminal"])
        #expect(config.gateConfig.maxClipboardBytes == 8192)
        #expect(config.gateConfig.shellSignalScoreThreshold == 0.4)
        #expect(config.pollInterval == 0.25)
    }

    @Test("An empty or non-string-array 'terminals' warns and keeps the default")
    func badTerminalsFile() {
        let emptyArray = ConfigLoader.resolve(tomlText: "terminals = []", environment: [:])
        #expect(emptyArray.config.terminalAllowlist == WatchGate.Config.defaultTerminalAllowlist)
        #expect(emptyArray.warnings.contains { $0.contains("'terminals' must be a non-empty") })

        let notStrings = ConfigLoader.resolve(tomlText: "terminals = [1, 2]", environment: [:])
        #expect(notStrings.config.terminalAllowlist == WatchGate.Config.defaultTerminalAllowlist)
        #expect(notStrings.warnings.contains { $0.contains("'terminals' must be a non-empty") })
    }

    @Test("A non-string wrap_profile in the file warns and keeps the default")
    func nonStringProfileFile() {
        let loaded = ConfigLoader.resolve(tomlText: "wrap_profile = 123", environment: [:])
        #expect(loaded.config.wrapProfile == .claudeCode)
        #expect(loaded.warnings.contains { $0.contains("wrap profile must be a string") })
    }

    @Test("UNBREAK_WRAP_PROFILE selects a shipped profile")
    func wrapProfileEnv() {
        let loaded = ConfigLoader.resolve(
            tomlText: nil,
            environment: [ConfigLoader.EnvKey.wrapProfile: "claude-code"]
        )
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.config.wrapProfile == .claudeCode)
    }

    @Test("A bad-typed / negative threshold in the file warns and keeps the default")
    func badThresholdFile() {
        let loaded = ConfigLoader.resolve(
            tomlText: """
                [thresholds]
                shell_signal_score = -0.5
                structure_risk = "high"
                """,
            environment: [:]
        )
        #expect(loaded.config.shellSignalScoreThreshold == nil)
        #expect(loaded.config.structureRiskThreshold == nil)
        #expect(loaded.warnings.count == 2)
        #expect(loaded.warnings.allSatisfy { $0.contains("non-negative number") })
    }

    @Test("A bad env threshold warns and keeps the default")
    func badThresholdEnv() {
        let loaded = ConfigLoader.resolve(
            tomlText: nil,
            environment: [ConfigLoader.EnvKey.structureRisk: "high"]
        )
        #expect(loaded.config.structureRiskThreshold == nil)
        #expect(loaded.warnings.contains { $0.contains(ConfigLoader.EnvKey.structureRisk) })
    }

    @Test("XDG_CONFIG_HOME redirects the config path")
    func xdgPath() {
        let url = ConfigLoader.defaultConfigURL(environment: ["XDG_CONFIG_HOME": "/tmp/cfg"])
        #expect(url.path == "/tmp/cfg/unbreak/config.toml")
    }

    @Test("Without XDG_CONFIG_HOME the path falls back to ~/.config")
    func defaultPathFallsBackToDotConfig() {
        // An absent var and an empty one both take the home fallback.
        for env in [[:], ["XDG_CONFIG_HOME": ""]] as [[String: String]] {
            let url = ConfigLoader.defaultConfigURL(environment: env)
            #expect(url.path.hasSuffix("/.config/unbreak/config.toml"))
        }
    }

    @Test("load() reads a real file under XDG_CONFIG_HOME; a missing file yields defaults")
    func loadFromDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unbreak-cfg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["XDG_CONFIG_HOME": root.path]

        // No file on disk yet → defaults, no warnings.
        let missing = ConfigLoader.load(environment: env)
        #expect(missing.warnings.isEmpty)
        #expect(missing.config == UnbreakConfig())

        // Write a config and confirm load() picks it up.
        let configURL = ConfigLoader.defaultConfigURL(environment: env)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "poll_interval_ms = 321".write(to: configURL, atomically: true, encoding: .utf8)

        let loaded = ConfigLoader.load(environment: env)
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.config.pollIntervalMilliseconds == 321)
    }

    @Test("The bundled sample is valid TOML and resolves cleanly")
    func sampleIsValid() {
        let loaded = ConfigLoader.resolve(tomlText: UnbreakConfig.sampleTOML, environment: [:])
        // Every line in the sample is commented, so it must resolve to the
        // defaults with no warnings.
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.config == UnbreakConfig())
    }
}
