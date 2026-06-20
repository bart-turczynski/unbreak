# unbreak

[![codecov](https://codecov.io/gh/bart-turczynski/unbreak/branch/main/graph/badge.svg)](https://app.codecov.io/gh/bart-turczynski/unbreak)

> Repairs terminal-wrapped clipboard commands from grid-renderer
> agent CLIs (Claude Code, Gemini CLI, Codex CLI) so they paste as clean,
> runnable shell commands. macOS only.

See [`docs/PRDv2.md`](docs/PRDv2.md) for the full product spec.

## Why

TUI agents render through a fixed character grid and insert **real newlines** plus
a left-margin gutter into long lines. Copying a wrapped shell command carries hard
breaks and leading spaces, so pasting garbles or prematurely runs it. This tool
repairs exactly the copied fragment. (Background: PRD v2 §1.)

## Quick start (teams)

Have the **Xcode Command Line Tools** installed first (`xcode-select --install`) —
the formula builds from source, so without them the install fails. Then:

```sh
brew install bart-turczynski/tap/unbreak   # puts the CLI on PATH
unbreak setup                              # detect your terminals, write config, enable the watcher
```

`brew install` alone does **not** start the always-on behavior — it only installs
the CLI. `unbreak setup` is the step that detects which terminals you use, writes
the allowlist config, and offers to turn on the login watcher. If Homebrew warns
about an untrusted tap, run `brew tap bart-turczynski/tap` first.

Just want a one-shot repair without any background watcher? That works straight
after `brew install`, no setup needed:

```sh
pbpaste | unbreak -                        # repair clipboard text, print to stdout
```

## Install

Primary path is a Homebrew tap (builds from source — needs the Xcode Command Line
Tools). The tap lives at `bart-turczynski/homebrew-tap` (§9).

```sh
brew install bart-turczynski/tap/unbreak
```

`brew install` only puts the `unbreak` CLI on your `PATH`. The clipboard watcher is
**off until you opt in** — enable it at login with `brew services start unbreak`, or
run the guided `unbreak setup`.

No Homebrew? Use the fallback installer (builds from source the same way):

```sh
curl -fsSL https://raw.githubusercontent.com/bart-turczynski/unbreak/main/install.sh | bash
```

See [`docs/RELEASING.md`](docs/RELEASING.md) for the tap setup and release flow.

## Uninstall

`unbreak uninstall` tears down everything unbreak writes to your machine — the login
watcher, logs, the undo socket, and the config file (pass `--keep-config` to keep
the latter). It then prints how to remove the binary itself:

```sh
unbreak uninstall                 # remove all unbreak state
unbreak uninstall --keep-config   # …but leave the config in place
```

To also remove the binary, follow the printed instruction for your install
method — `brew uninstall unbreak` for the Homebrew tap, or for the curl install:

```sh
curl -fsSL https://raw.githubusercontent.com/bart-turczynski/unbreak/main/uninstall.sh | bash
```

(The curl uninstaller runs `unbreak uninstall` for you and then deletes the binary.)

## Layout

```
Sources/UnbreakCore   pure, deterministic repair pipeline (PRD v2 §6)
Sources/unbreak       thin CLI shell (PRD v2 §8.1)
Sources/Watch       opt-in fix-on-copy daemon + gates (PRD v2 §7)
Sources/Setup       setup wizard + per-user LaunchAgent (PRD v2 §8.2)
Tests/              swift-testing unit + property + corpus tests (§6.8, §13)
Formula/unbreak.rb    Homebrew formula (PRD v2 §9)
install.sh          curl|bash fallback installer (PRD v2 §9)
uninstall.sh        curl|bash uninstaller — state teardown + binary (PRD v2 §9)
docs/               product spec + release flow
```

## Develop

Requires the Swift toolchain (Xcode Command Line Tools).

```sh
make build      # swift build
make test       # swift test (+ swift-testing framework paths)
make fmt        # format in place (needs swift-format)
make lint       # static analysis (needs swiftlint)
```

> Use `make test`, not bare `swift test`: on the standalone Command Line Tools
> (no full Xcode) the swift-testing framework needs its search/runtime paths
> passed explicitly, which the Makefile derives from `xcode-select -p`.

Optional tools:

```sh
brew install swift-format swiftlint
```

## Try it

```sh
pbpaste | swift run unbreak -      # repair clipboard text, print to stdout
swift run unbreak --help
```

## Status

Feature-complete for v1. The repair pipeline (normalize, de-gutter, wrap-rejoin,
heredoc protection, opt-in merge-split — §6.1–6.5, §6.8), the six-gate watch-mode
daemon with in-memory undo (§7), the CLI (§8.1), config + env overrides (§8.3), the
setup wizard / LaunchAgent (§8.2), and distribution (§9) are all in place. The §13
fixture corpus enforces zero watch-mode mutations on normal copies.

Deferred to v2 (§12): Gemini CLI / Codex CLI wrap profiles (§6.6), bottles, and a
homebrew-core submission.
