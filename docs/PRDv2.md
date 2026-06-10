# PRD v2 — Terminal copy-fix utility (working name: `ccfix`)

> Status: **Draft for build (revised)**. Supersedes `PRD.md`. This revision folds
> in the design review: it tightens the watcher safety contract, makes
> display-column width first-class, disables lossy repairs by default, adds an
> in-memory rollback, and corrects the upstream-issue and Homebrew facts. The
> guiding constraint is unchanged — **resilient but small**: every addition below
> is scoped to a few well-defined signals, an in-memory buffer, or a data table,
> not a framework.
> Name is a placeholder (see §11). Facts dated against sources are marked
> "as of 2026-06-05".

## 1. Problem

TUI coding agents that render output through a fixed-size character grid insert
**real newline characters** (and a left-margin gutter) into their output instead
of letting the terminal soft-wrap. When a user selects and copies a long line
(typically a shell command the agent told them to run), the copied text carries:

- hard line breaks at the wrap column, and
- the rendering gutter (leading spaces) on every line.

Pasting that into a shell runs the command prematurely or garbles it.

This is **renderer-side**, not terminal-side: because the newlines are literal,
a soft-wrap-aware terminal cannot rejoin them. Confirmed affected (same
mechanism, all grid-renderer TUIs), issue status verified as of 2026-06-05:

- **Claude Code** (Ink/React) — primary target.
- **Gemini CLI** (Ink) — same family;
  [google-gemini/gemini-cli#13688](https://github.com/google-gemini/gemini-cli/issues/13688)
  is **closed** but documents the related symptoms: copy mode requires `Ctrl+S`,
  copied text broken by screen width, extra characters, and leading spaces.
- **Codex CLI** (Ratatui) —
  [openai/codex#12200](https://github.com/openai/codex/issues/12200) is **open**
  and directly matches this PRD: wrapped lines copy with a 2-space indent and long
  commands split by TUI wordwrap. [#8306](https://github.com/openai/codex/issues/8306)
  is **closed** and Windows/WSL-specific, but still corroborates the general
  wrapped-copy problem and additionally reports **Unicode copy corruption** (see
  §6.1, §13).

Not affected (sidestep via OSC52 logical-copy or stream-to-scrollback): opencode,
Textual-based tools, Aider (prose). So the tool's reach is "grid-renderer agent
CLIs," not "all CLIs."

There is **no built-in fix** (verified against the Claude Code settings docs as of
2026-06-05; re-verify periodically, as upstream CLI behavior changes quickly):
`/copy` copies the whole answer *as rendered* (gutter + wraps included); the
requested `outputWrapping: "soft"` setting does **not** exist in the published
settings docs; no hook can modify the clipboard. Until upstream ships a fix, a
clipboard post-processor is the only option. See §10 for obsolescence risk.

### Distinct value vs `/copy`
`/copy` grabs the entire response. This tool repairs **exactly the fragment the
user selected** (e.g. one bang command), which is the common real-world need.

## 2. Goals

- Repair a copied fragment so it pastes as a clean, runnable command.
- A hands-free **watch mode**: fix the clipboard automatically on copy, scoped so
  it acts on agent-CLI command text and **avoids normal copies with conservative
  gating** (§7). The target is operational, not absolute: **zero mutations across
  a fixture corpus** of prose, logs, markdown, stack traces, code snippets, and
  pager output (§13). False positives remain possible (§10); the design minimizes
  them and makes them recoverable (§7 rollback).
- Be installable by anyone (no hardcoded usernames/paths), with a first-class
  install experience.
- Be stable and efficient enough to run continuously at login.

## 3. Non-goals (v1)

- **Cross-platform.** macOS only. The clipboard backend (`NSPasteboard`) and the
  frontmost-app gate (`NSWorkspace`) have no clean portable equivalent, and the
  whole premise is a mac terminal workflow.
- **Auto-paste.** Deferred to v2 (§9) — it needs Accessibility permission, a
  heavier ask than the watcher requires.
- **Parsing the agent's answer structure.** The tool only ever sees the
  clipboard; "copy a specific element" = the user's manual text selection.
- **Pinpointing the agent process** (vs the terminal). Not reliably possible; the
  clipboard isn't source-tagged and active-pane process sniffing is fragile and
  per-terminal. The gate is terminal-app + content heuristic (§7).
- **A general profile/plugin framework.** Profiles are a small data table (§6.6),
  not an extension system.

## 4. Platform & language decision

- **macOS only.**
- **Swift native binary.** Chosen over keeping the Python script because:
  - Polls `NSPasteboard.changeCount` (a cheap integer) instead of shelling out to
    `pbpaste` every tick; truly event-driven frontmost-app via `NSWorkspace`
    activation notifications.
  - Self-contained binary → trivial Homebrew formula, no Python-env pitfalls
    (the original depended on a fragile `/usr/bin/python3`).
- The existing Python `ccfix.py` serves as the reference implementation for the
  repair heuristic and as a source of test fixtures.
- **Swift string-width caveat (first-class):** `String.count`, UTF-16 count, and
  byte count all differ from terminal display width. Wrap detection and gutter
  removal MUST use **terminal display-cell width**, not any of the above. See §6.1.

## 5. Empirical artifacts (ground truth)

Captured from a live Claude Code session with the watcher **disabled** (raw
clipboard). The repair algorithm (§6) is designed against these, not assumptions.

| # | Artifact | Example | Repair confidence |
|---|----------|---------|-------------------|
| 1 | Hard wrap at a **word boundary**; break replaces a space | `…\| .name' >` ⏎ `  /tmp/out.json` | High — rejoin with a single space |
| 2 | **+2 left gutter** on every line (relative indent preserved) | sent `  &&`, got `    &&` | High — dedent |
| 3 | **Partial first line** (selection starts inside/after gutter) | line 1 has 0–1 spaces, rest have 2+ | High — compute gutter from lines 2..n |
| 4 | **Unbreakable tokens not wrapped** (no space to break at) | 100-char URL stayed on one line | N/A — nothing to do |
| 5 | **Long-line-then-short-line merge** behind a padding run | `…dedent"   [pad]   fi` then ⏎ `  fi` | **Low — partly lossy (§6.5)** |
| 6 | **Intentional structure survives** | `\` continuations, heredoc body, internal `multiple    spaces` | Must be preserved untouched |
| 7 | **Quote-bar gutter** on a queued-prompt / preview box | every line prefixed `  ▎ ` (U+258E) | High — strip the bar gutter + reflow paragraphs (§6.2) |

Note the old tool's double-space bug (`>  /tmp`): word-boundary wraps must rejoin
with exactly one space and collapse the duplicate.

## 6. Repair algorithm

The repair is a **pure, deterministic function** of the input string:

```
normalize → profile-detect → dedent → classify-newlines → rejoin
          → optional artifact-split → render → (string, RepairReport)
```

No I/O, no globals, no clipboard access inside it. The CLI and the watcher both
call this one function and compare input to output; the watcher additionally
consults the returned `RepairReport` confidence (§6.7). Per-tool "wrap profiles"
are a pluggable data table (§6.6); **v1 ships the Claude Code profile**, with
Gemini/Codex as fast-follows.

### 6.1 Normalize (Unicode- and width-aware)
- CRLF/CR → LF. Preserve a single trailing newline decision for output parity.
- **Strip ANSI SGR / control sequences and OSC payloads** before width math, so
  escape bytes never count as columns or survive into the output.
- All subsequent "length"/"column"/"width" comparisons use **terminal
  display-cell width**, computed with a wcwidth-style function that handles: tabs
  (expanded to the next tab stop), zero-width combining marks, wide CJK (2 cells),
  emoji and emoji-ZWJ sequences, and variation selectors. This is the single
  source of truth for §6.2 gutter math and §6.3 wrap detection.
- Codex `#8306` reports Unicode copy corruption; §13 carries explicit CJK/emoji/
  tab/ANSI fixtures to lock this down.

### 6.2 De-gutter (dedent, robust to partial line 1)
- `G` = minimum leading-whitespace **display width** over **non-blank lines 2..n**
  (line 1 is excluded because it is frequently partially selected).
- Remove `G` columns from lines 2..n; remove `min(indent₁, G)` from line 1.
- This strips the rendering gutter while **preserving relative indentation**
  (verified against Case 6 nesting).
- **Quote-bar gutter (Case 7):** some surfaces draw a left margin *glyph* rather
  than plain spaces — Claude Code's queued-prompt/preview box prefixes every line
  with `  ▎ ` (U+258E). Before the whitespace dedent, strip a leading
  `<whitespace>* <bar> <space>?` prefix (the bar is profile data, `gutterBars`).
  Fire only when ≥2 non-blank lines carry the bar and they are a two-thirds
  majority, so a stray `▎` in content never trips it; a bare `  ▎` separator line
  collapses to empty, preserving the paragraph break. Left behind, the bar both
  litters the paste and defeats §6.3 wrap detection.
- **Reflow (quote-bar only):** a confirmed bar block is a display box the CLI
  soft-wrapped to a fixed column, so — unlike the conservative §6.3 path — its
  paragraphs are reflowed back to one line each. A newline between two non-blank
  lines is a soft wrap (rejoin with a single space) exactly when the first word of
  the next line would not have fit on the current line at the block width `W` (the
  widest line) — keying off the *original* line width, as §6.3 does. Blank lines
  (paragraph breaks), continuation tokens, heredoc bodies, and lines opening with a
  **list marker** (`- `/`* `/`1. `, the trailing space distinguishing a bullet from
  a `--flag`) are intentional breaks and survive. The list-marker rule is also
  taught to §6.3 `rejoin`, so two equal-width bullets never collapse into one line.

### 6.3 Rejoin wrapped lines
- A newline is a **wrap** (rejoin) when the preceding line is "full" — its display
  width is at/near the detected wrap column `W` — and it does **not** end in an
  explicit continuation token (`\`, `&&`, `||`, `|`, trailing `(`/`,` etc.).
- Rejoin word-boundary wraps with a **single space**; collapse an accidental
  double space at the seam.
- `W` detection: most-common display width among full, non-final lines (per the
  original heuristic), or `--width N` override. Record `wrapColumnConfidence` in
  the `RepairReport`.
- Lines ending in explicit continuations and short lines are left as separate
  lines → heredocs, `\` layouts, and one-operator-per-line survive (Case 6 items
  3/4 in §5).

### 6.4 Heredoc detection
- Track `<<EOF` / `<<-EOF` / `<<'EOF'` openers and their terminators; mark the body
  as a protected region. Dedent and rejoin treat protected regions as untouchable,
  and §6.5 never fires inside them. Surfaced as `heredocDetected` in the report.

### 6.5 Merge-artifact split (lossy — **off by default**)
- Detect a line whose display width exceeds `W` and contains a run of `≥k` spaces
  followed by more shell-like tokens → likely a lost newline hidden by padding.
- Split at the run. **Known limitation:** indistinguishable in general from
  intentional alignment (e.g. heredoc internal spacing), and the original line's
  indent is unrecoverable.
- Therefore this step is **disabled by default** in both one-shot and watch repair.
  It runs only when the user explicitly opts in:
  - `--split-padding-artifacts` — enable the split in one-shot mode; or
  - `--no-copy` / preview, where the proposed split is shown with a
    confidence explanation rather than written to the clipboard.
- Guards when enabled: only trigger when the run pushes past `W` **and** the tail
  looks like separate statements; **never** apply inside a detected heredoc body
  (§6.4).
- `--join-all` is the opposite escape hatch (aggressive full-collapse), **not** a
  reversibility mechanism. Reversibility comes from §7's rollback buffer.
- This is the one artifact we **do not promise** to fix cleanly; documented as such.

### 6.6 Wrap profiles (data, not framework)
- A `WrapProfile` is a small record: gutter behavior, continuation tokens,
  hidden/control-char handling, minimum wrap confidence, and known-renderer
  quirks. Adding Gemini/Codex is a new data row plus fixtures, not new code paths.
- v1 ships **Claude Code** only. Codex (+2 continuation indent that breaks
  heredocs) and Gemini (leading spaces + hidden chars) are fast-follow rows.

### 6.7 Confidence model (small, not a boolean)
The function returns a `RepairReport` with a handful of named signals rather than
a single `changed` flag:

- `dedentChanged: Bool`
- `wrapColumnConfidence: 0…1`
- `shellSignalScore: 0…1` (see §7 for the signal set)
- `structureRisk: 0…1` (heredoc/alignment/prose risk)
- `heredocDetected: Bool`

One-shot CLI acts whenever output differs from input (permissive — the user asked).
Watch mode applies the discrete shell-signal tiers and structure-risk veto (§7
gates 5/6) before mutating; `shellSignalScore`/`structureRisk` remain in the
report for logging and for power-user float overrides (§8.3).

### 6.8 Guarantees / tests
- **Idempotent**: running twice == running once (property test).
- **Lossless on already-clean input**: a fragment with no artifacts is returned
  unchanged (property test).
- **Structure-preserving**: §5 Cases 3/4/6 round-trip to their intended form.

## 7. Watch mode

Hands-free fix on copy. **Opt-in** (see §8). The watcher only ever calls the pure
repair function (§6) and decides based on its `RepairReport`. **All** of the
following gates must pass before any mutation:

1. **Frontmost app is an allowlisted terminal** (via `NSWorkspace`). Default
   allowlist: cmux, Ghostty, iTerm2, Apple Terminal — user-extensible (§8.3).
2. **Clipboard item is plain text.** Only the `public.utf8-plain-text` (string)
   pasteboard representation is read and, if mutated, rewritten. **Non-string and
   rich clipboard items are left completely untouched** — we never destroy
   images, files, or rich content.
3. **Size bound.** Clipboard payload ≤ a configurable `maxClipboardBytes`
   (**default 16 KB**). Real copied commands are well under 1 KB (even a sprawling
   `docker run` line); a few KB covers a heredoc block. Anything bigger is almost
   certainly a log dump, file, or prose paste — skipped. The bound is cheap
   defense-in-depth (`changeCount` already gates polling), so it errs small.
4. **Repair changed the content** — output differs from input.
5. **High-confidence shell signal — discrete tiers.** Two signal tiers; the gate
   passes iff **≥1 strong signal, OR ≥2 weak signals**. A single weak signal never
   fires alone (that is the prose trap).
   - **Strong** (any one passes): top-level unquoted operator (`|`, `&&`, `||`,
     `;`, `>`, `>>`), command substitution (`$(…)` / backticks), env-assignment
     prefix (`VAR=… cmd`), or a leading known tool name (`git`, `brew`, `npm`,
     `docker`, `curl`, `kubectl`, …).
   - **Weak** (need ≥2): command shape at line start (`word [subword] …`), a flag
     cluster (`-x` / `--long`), or a quoted path.
6. **Structure-risk veto.** Do **not** mutate — even when 5 passes — if any of
   these fire: markdown markers dominate (`- ` / `* ` / `# ` / `1. ` at multiple
   line starts), stack-trace patterns (`at …(file:line)`, `File "…", line N`), a
   prose ratio (most lines end in `.`/`!`/`?` with high alpha-to-symbol ratio and
   no operators), or a box-drawing table/panel (≥2 lines carrying U+2500–U+259F
   glyphs — its uniform-width rows otherwise read as wrapped command lines to §6.3
   and smush). "When in doubt, don't act" → the §2 zero-mutation target.

If all gates pass: **in-place clipboard mutation** is the intended behavior (the
whole point) — the wrapped string representation is replaced. Documented
prominently.

### 7.1 Rollback (mitigates "the original is gone")
- The watcher keeps the **last original clipboard string in memory** before it
  mutates. `ccfix undo` restores the most recent watcher mutation. This is a
  short-lived, single-slot, in-memory buffer (cleared on the next user copy or on
  daemon restart) — deliberately not persistent, to stay small and avoid stale
  state.

### 7.2 Dry-run / log-only mode
- `--dry-run-watch` runs the full watcher pipeline and **logs what it *would* do**
  (profile, confidence signals, changed/not-changed) **without mutating the
  clipboard**. Primary QA tool for tuning thresholds against real usage.

### 7.3 Observability (quiet, content-safe)
- Log to `~/Library/Logs/ccfix.log`: timestamp, frontmost bundle id, profile,
  the `RepairReport` signals, byte/line counts, and a `changed`/`not-changed`
  decision. **Full clipboard contents are never logged by default.**
- `--debug-log-content` opt-in logs raw before/after content for fixture capture.

### 7.4 Plumbing
- Detection of clipboard change via `NSPasteboard.changeCount` (cheap, fast poll
  or notification-driven); our own writes are recorded to avoid a feedback loop.
- Runs at login via a launchd LaunchAgent that the installer generates per-user
  (no hardcoded path/username/label — fixes the original personalized plist).
- Bundle id / label: generic reverse-DNS (final value pending name, §11), **not**
  a personal identifier.

## 8. Installation & CLI surface

### 8.1 CLI (one-shot)
- `ccfix`                      — fix clipboard in place (default)
- `ccfix "text"`              — fix an argument
- `ccfix -`                   — stdin → stdout (never touches clipboard)
- `ccfix --no-copy`           — print result + confidence, don't write clipboard (preview)
- `ccfix --join-all`          — aggressive full-collapse fallback
- `ccfix --width N`           — force the wrap column
- `ccfix --split-padding-artifacts` — enable the lossy merge-artifact split (§6.5)
- `ccfix undo`                — restore the most recent watcher mutation (§7.1)
- `ccfix --dry-run-watch`     — run the watcher log-only (no mutation) (§7.2)
- `ccfix --debug-log-content` — log raw before/after content (fixture capture)

### 8.2 Setup wizard (the "first-class install experience")
- `ccfix setup` — interactive wizard: detect terminals, pick the allowlist, and
  prompt "enable the auto-fix watcher at login? [y/N]".
- `ccfix setup --enable-agent` — non-interactive/forced for scripted installs.
- `ccfix install-agent` / `ccfix uninstall-agent` — manage the LaunchAgent
  through the tool (no hand-copying plists).
- Watcher is **off until the user opts in** — `brew install` alone only puts the
  CLI on PATH and prints a caveat.

### 8.3 Config
- `~/.config/ccfix/config.toml`: terminal allowlist, poll interval, default wrap
  profile, `maxClipboardBytes` (default 16 KB). The §7 gates ship as the discrete
  tier/veto rule; `shellSignalScore` / `structureRisk` float thresholds are
  optional **power-user overrides** of that default, not the primary knob. Env
  overrides (e.g. `CCFIX_TERMINALS`).
- Logs: `~/Library/Logs/ccfix.log` (not world-writable `/tmp`).

## 9. Distribution

- **Primary: Homebrew tap.** Public repo `<handle>/homebrew-tap` with
  `Formula/ccfix.rb`. No account/approval beyond a GitHub account.
  - `brew install <handle>/tap/ccfix`
  - `brew services start ccfix` (or the wizard) — Homebrew generates the per-user
    launchd plist, eliminating hardcoded path/username.
  - Formula builds from source (needs Xcode Command Line Tools); pre-built
    **bottles** are a later optimization.
- **Fallback: `curl … | bash` installer** hosted on GitHub for users without
  Homebrew; templates the LaunchAgent at install time.
- **Not pursuing**: pip/pipx (Python-env pain, and we're going native), and
  Claude Code plugin (plugins can't run a persistent OS clipboard watcher — a
  hook only rewrites the on-screen render, never the clipboard).
- **Release flow**: tagged GitHub release → tarball + SHA-256 → bump
  `version` + `sha256` in the formula. Explicit `version` so users only update on
  a bump.
- **homebrew-core** (`brew install ccfix`, no tap) is a *later* goal. Per the
  Homebrew Acceptable Formulae docs (as of 2026-06-05), the general notability
  thresholds are ~75 stars / 30 forks-or-watchers, but **self-submitted software
  faces 3× thresholds: ≥90 forks, ≥90 watchers, or ≥225 stars**, plus a stable
  release and an OSS license, and a PR. Start with the tap.

## 10. Risks

- **Upstream obsolescence**: if Anthropic ships `outputWrapping: "soft"`, the tool
  loses its reason to exist. Mitigation: keep it small and low-maintenance; the
  multi-tool reach (Gemini/Codex) hedges single-vendor risk.
- **Merge-artifact (§6.5)** is partly lossy and heuristic — **off by default**,
  documented limitation, with `--split-padding-artifacts` opt-in and `--no-copy`
  preview.
- **Watch-mode false positives**: copying a wrapped command from a pager in an
  allowlisted terminal could fire. The layered content gates (§7) make this
  uncommon and the fixture-corpus target (§13) measures it; the in-memory
  rollback (`ccfix undo`, §7.1) makes a misfire recoverable rather than
  destructive.

## 11. Open items

- **Name** (deliberately deferred): leaning toward a terminal/multi-tool-oriented
  name now that scope spans Claude Code + Gemini CLI + Codex CLI, rather than a
  Claude-specific one. `ccfix` is a placeholder throughout this PRD; final name
  fixes the binary, tap repo, bundle id, and config dir.
- **Terminal confirmation**: capture was on (presumed) cmux; artifacts are
  renderer-side so this shouldn't change the design, but worth confirming and
  cross-testing iTerm2 / Terminal.app / Ghostty during QA.
- **Threshold tuning**: defaults are now set — `maxClipboardBytes` = 16 KB, the
  discrete shell-signal tiers (≥1 strong / ≥2 weak), and the structure-risk veto
  (§7 gates 3/5/6). Remaining work is validation, not selection: confirm zero
  mutations against the §13 corpus via `--dry-run-watch` and adjust the
  signal/veto pattern lists if a fixture slips through.

## 12. v2 / future

- **Auto-paste** the fixed command (synthesize ⌘V) — requires Accessibility
  permission; separate opt-in.
- **Gemini CLI & Codex CLI wrap profiles** (Codex adds +2 continuation indent that
  breaks heredocs; Gemini adds leading spaces + hidden chars — both new rows in
  the §6.6 profile table plus fixtures).
- **Bottles** for tap installs; eventual **homebrew-core** submission (§9 thresholds).

## 13. Testing strategy

- **Fixture corpus (must yield zero watch-mode mutations):** clean prose, markdown
  lists, shell heredocs, JSON, YAML, Makefiles, Python indentation, stack traces,
  box-drawing tables/panels, URLs, CJK text, emoji, tabs, ANSI escapes, OSC52
  sequences, pager output, plus
  raw mangled captures (watcher off) per tool × the §5 case types (long wrap,
  inline, multi-line `\`, heredoc, long token, nested+merge).
- **Property tests:** idempotence (§6.8), lossless-on-clean-input, and structure
  preservation; plus random fuzz cases.
- **Unicode/width tests:** CJK, emoji-ZWJ, combining marks, tabs, and ANSI/OSC
  stripping all produce correct display-width-based wrap detection and gutter
  removal (locks down Codex `#8306` corruption).
- **Assert specifics:** correct single-space rejoin, gutter removal with
  relative-indent preservation, heredoc bodies untouched, merge-split off unless
  opted in.
- **Cross-terminal QA matrix:** cmux, Ghostty, iTerm2, Apple Terminal — run the
  watcher in `--dry-run-watch` against real copies to calibrate thresholds.
