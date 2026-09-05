# unbreak

[![codecov](https://codecov.io/gh/bart-turczynski/unbreak/branch/main/graph/badge.svg)](https://app.codecov.io/gh/bart-turczynski/unbreak)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fbart-turczynski%2Funbreak%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/bart-turczynski/unbreak)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fbart-turczynski%2Funbreak%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/bart-turczynski/unbreak)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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

> **The Homebrew tap is temporarily unavailable** while it is rebuilt on GitLab.
> Use the installer below in the meantime; this section is updated when the tap
> is back.

Once restored, the tap is the primary path (pours a prebuilt bottle, no Swift
toolchain needed):

```sh
brew install unbreak      # after tapping — see the tap's own instructions
```

`brew install` only puts the `unbreak` CLI on your `PATH`. The clipboard watcher is
**off until you opt in** — enable it at login with the guided `unbreak setup` (the
single canonical way to turn the watcher on; it also writes the terminal allowlist
the watcher needs).

The fallback installer builds from source (needs the Xcode Command Line Tools)
and is the working install path right now:

```sh
curl -fsSL https://gitlab.com/bart-turczynski/unbreak/-/raw/main/install.sh | bash
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
curl -fsSL https://gitlab.com/bart-turczynski/unbreak/-/raw/main/uninstall.sh | bash
```

(The curl uninstaller runs `unbreak uninstall` for you and then deletes the binary.)

## Troubleshooting

Watch mode logs every gate decision — never the clipboard contents (§7.3) — to
`~/Library/Logs/unbreak.log`, one line per copy:

```
2026-06-20T22:20:20Z frontmost=com.apple.Terminal decision=mutate bytes=1483 lines=28 wrapConf=0.92 shell=0.00 struct=0.10
```

**Copies come back mangled, and every event is logged twice.** Two watcher
daemons are running, and each one repairs the other's output — the second pass
re-merges lines the first already joined. `unbreak setup` installs the
`io.unbreak.watch` LaunchAgent; a stray `brew services start unbreak` installs a
*second* daemon under `homebrew.mxcl.unbreak`. The formula ships no `service do`
block for exactly this reason (§9), and the §7.4 `flock` single-instance lock
(`Sources/Watch/WatchLock.swift`) keeps at most one daemon mutating — but a
binary older than **v0.7.0** predates that lock. Retire the redundant watcher and
make sure you are on a build that carries the lock:

```sh
brew services stop unbreak     # keep only the `unbreak setup` watcher
brew upgrade unbreak           # v0.7.0+ carries the §7.4 lock
```

**The CLI repairs a copy that the watcher leaves alone.** They do not run the
same configuration, so a clean `pbpaste | unbreak -` proves nothing about watch
mode: the CLI turns paragraph reflow *on* (`RepairOptions(reflowParagraphs:
true)`, §6.2) while the watcher takes the default — off — and puts every copy
through the §7 gates first. Reproduce against the **installed** binary, then read
that copy's log line: a `decision=skip blocked=…` names the gate that vetoed it.
Use `unbreak --dry-run-watch` to run the daemon log-only and watch decisions
land without touching the clipboard (§7.2).

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
