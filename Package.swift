// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "unbreak",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "unbreak", targets: ["unbreak"]),
        .library(name: "UnbreakCore", targets: ["UnbreakCore"]),
    ],
    targets: [
        // Pure, deterministic repair pipeline (PRD v2 §6). No I/O, no globals.
        .target(name: "UnbreakCore"),
        // NSPasteboard-backed clipboard, behind a testable protocol (PRD v2 §7.2).
        .target(name: "Clipboard"),
        // Watch-mode event loop + app-context detection (PRD v2 §7.4).
        .target(
            name: "Watch",
            dependencies: ["UnbreakCore", "Clipboard"]
        ),
        // One-shot CLI surface: arg grammar + I/O driver, testable in isolation
        // from a real terminal/NSPasteboard (PRD v2 §8.1).
        .target(
            name: "CLI",
            dependencies: ["UnbreakCore", "Clipboard", "Watch"]
        ),
        // User config: config.toml reader + UNBREAK_* env overrides (PRD v2 §8.3).
        .target(
            name: "Config",
            dependencies: ["UnbreakCore"]
        ),
        // Setup wizard + per-user LaunchAgent lifecycle (PRD v2 §8.2, §7.4).
        .target(
            name: "Setup",
            dependencies: ["UnbreakCore", "Config"]
        ),
        // Thin executable shim around CLI (§8.1) + the watch daemon (§7).
        .executableTarget(
            name: "unbreak",
            dependencies: ["UnbreakCore", "Clipboard", "Watch", "CLI", "Config", "Setup"]
        ),
        .testTarget(
            name: "UnbreakCoreTests",
            dependencies: ["UnbreakCore"]
        ),
        // §13 validation: a file-based fixture corpus proving zero watch-mode
        // mutations on normal copies, plus golden repair captures per §5 case type.
        .testTarget(
            name: "CorpusTests",
            dependencies: ["UnbreakCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ClipboardTests",
            dependencies: ["Clipboard"]
        ),
        .testTarget(
            name: "WatchTests",
            dependencies: ["Watch", "Clipboard", "UnbreakCore"]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["CLI", "UnbreakCore", "Clipboard", "Watch"]
        ),
        .testTarget(
            name: "ConfigTests",
            dependencies: ["Config", "UnbreakCore"]
        ),
        .testTarget(
            name: "SetupTests",
            dependencies: ["Setup", "UnbreakCore", "Config"]
        ),
    ]
)
