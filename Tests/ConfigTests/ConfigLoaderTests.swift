import Testing
import UnbreakCore

@testable import Config

@Suite("Config loading: defaults, file, env precedence (PRD v2 §8.3)")
struct ConfigLoaderTests {
    @Test("No file and no env yields the built-in defaults")
    func defaults() {
        let loaded = ConfigLoader.resolve(tomlText: nil, environment: [:])
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.config == CCFixConfig())
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
        let config = CCFixConfig(
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

    @Test("XDG_CONFIG_HOME redirects the config path")
    func xdgPath() {
        let url = ConfigLoader.defaultConfigURL(environment: ["XDG_CONFIG_HOME": "/tmp/cfg"])
        #expect(url.path == "/tmp/cfg/unbreak/config.toml")
    }

    @Test("The bundled sample is valid TOML and resolves cleanly")
    func sampleIsValid() {
        let loaded = ConfigLoader.resolve(tomlText: CCFixConfig.sampleTOML, environment: [:])
        // Every line in the sample is commented, so it must resolve to the
        // defaults with no warnings.
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.config == CCFixConfig())
    }
}
