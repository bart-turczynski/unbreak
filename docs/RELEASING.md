# Releasing unbreak (PRD v2 §9)

Distribution is a **Homebrew tap** (primary) with a `curl … | bash` **fallback**
([`install.sh`](../install.sh)). Tap installs use a prebuilt **bottle** so users
need no Swift toolchain; the `curl` fallback still builds from source.

The GitHub handle is `bart-turczynski`. It appears in
[`Formula/unbreak.rb`](../Formula/unbreak.rb) (`homepage`, `url`) and in
`install.sh` (`UNBREAK_REPO` default). The tap lives in a **separate** repo,
`bart-turczynski/homebrew-tap`, with the formula at `Formula/unbreak.rb`.

## One-time tap setup

1. Create a public repo `bart-turczynski/homebrew-tap`.
2. Copy `Formula/unbreak.rb` into it at `Formula/unbreak.rb`.
3. Users then install with:

   ```sh
   brew install bart-turczynski/tap/unbreak
   ```

   `brew install` only puts the CLI on `PATH`; the watcher is off until the user
   opts in via `unbreak setup` (the single canonical enablement path — the formula
   ships no `service` block, so there is no `brew services` watcher to conflict
   with). The formula's `caveats` says so.

4. **Grant the release workflow push access to the tap.** `release.yml` mirrors
   the formula into the tap on every final tag, which is a *cross-repo* push — the
   default `GITHUB_TOKEN` can't reach another repo. Create a **fine-grained PAT**
   scoped to `bart-turczynski/homebrew-tap` with **Contents: read and write**, then
   add it to the `unbreak` repo as the **`TAP_PUSH_TOKEN`** Actions secret
   (`gh secret set TAP_PUSH_TOKEN --repo bart-turczynski/unbreak`). Without it the
   mirror step fails loudly with instructions.

## Cutting a release

The source-tarball `sha256` must match the tag *before* the bottle is built, so
the formula bump comes first, then the tag, then the workflow fills in the bottle.

1. **Bump the source fields** in [`Formula/unbreak.rb`](../Formula/unbreak.rb).
   First compute the digest of the tag's source tarball (GitHub generates one per
   tag — push the tag, or compute against the commit you're about to tag):

   ```sh
   curl -fsSL https://github.com/bart-turczynski/unbreak/archive/refs/tags/v0.1.2.tar.gz \
     | shasum -a 256
   ```

   Change `version`, `url`, and `sha256` together. The explicit `version` means
   users only update on a bump, not on every `brew update`. Commit.

2. **Tag and push:**

   ```sh
   git tag v0.1.2
   git push origin v0.1.2
   ```

3. **The release workflow** ([`.github/workflows/release.yml`](../.github/workflows/release.yml))
   fires on the tag. It builds the bottle on the `macos-26` runner, uploads the
   `*.bottle.tar.gz` as a release asset, prints the `bottle do` block to the **job
   summary**, and — for a final (non-prerelease) tag — **auto-mirrors the finished
   formula into the tap** (`bart-turczynski/homebrew-tap`), injecting the real
   source sha + bottle digest. This is the copy users install from; the manual
   paste-and-push that used to live here is gone (it kept getting skipped — the tap
   silently drifted to v0.5.2).

4. **Wire the bottle into the in-repo formula (housekeeping).** The tap is already
   updated by step 3. For the in-repo `Formula/unbreak.rb`, paste the job-summary
   `bottle do` block over the old one so the committed copy stays current — the
   next release's `brew install --build-bottle` only needs *valid* 64-hex there, so
   this is no longer release-blocking, just tidy.

5. **Verify** a clean bottle install from the tap:

   ```sh
   brew uninstall unbreak 2>/dev/null || true
   brew install bart-turczynski/tap/unbreak   # should download the bottle, not compile
   brew test unbreak                          # runs the stdin-repair test block
   brew style ./Formula/unbreak.rb
   ```

   To force-check the source path still works (the bottle's build recipe + the
   no-bottle fallback): `brew install --build-from-source ./Formula/unbreak.rb`.

> **Architectures & OS coverage.** The bottle is built on the Apple-Silicon
> `macos-26` runner, but the formula's `install` recipe compiles a **universal
> (arm64 + x86_64) binary** in one pass — `swift build -c release --arch arm64
> --arch x86_64`, which SwiftPM `lipo`s itself (no Intel runner needed; the SDK
> on the arm64 runner carries x86_64 support). Homebrew only reuses a bottle on a
> macOS release **at or newer than** the bottle's tag, and never across archs, so
> the workflow relabels the tahoe-built bottle to the *oldest* supported tag —
> `ventura` (matching `Package.swift` `.macOS(.v13)`) — and publishes the one
> universal tarball under **both** arch tags: `arm64_ventura` (Apple Silicon 13+)
> and `ventura` (Intel 13+). The two release assets are byte-identical copies
> (`:any_skip_relocation` bakes in no arch/path), so they share a single `sha256`
> — the generated `bottle do` block repeats it on both lines. Intel and Apple
> Silicon users both pour a bottle; neither needs the Swift toolchain.

## Fallback installer

For users without Homebrew, `install.sh` fetches the tagged tarball, builds
`-c release`, and installs the binary. It keeps the watcher off unless
`--enable-watch` is passed:

```sh
curl -fsSL https://raw.githubusercontent.com/bart-turczynski/unbreak/main/install.sh | bash
```

The LaunchAgent is never templated with a hardcoded path: when enabled, the
binary's own `unbreak install-agent` resolves its absolute path and writes the
per-user plist (§7.4, §8.2).

## Later (§12)

- ~~**Intel / universal bottle** so `x86_64` Macs skip the source build too.~~
  Done — the formula builds a universal binary and the release ships it under
  both `arm64_ventura` and `ventura` tags (see "Architectures & OS coverage").
- **homebrew-core** submission once notability clears the self-submission bar
  (≥90 forks / ≥90 watchers / ≥225 stars, a stable release, and an OSS license).
