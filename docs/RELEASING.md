# Releasing unbreak (PRD v2 §9)

Distribution is a **Homebrew tap** (primary) with a `curl … | bash` **fallback**
([`install.sh`](../install.sh)). Tap installs use a prebuilt **bottle** so users
need no Swift toolchain; the `curl` fallback still builds from source.

The project lives at **GitLab**: `gitlab.com/bart-turczynski/unbreak` (project id
`85027527`), public. The `bart-turczynski` handle appears in
[`Formula/unbreak.rb`](../Formula/unbreak.rb) (`homepage`, `url`) and in
`install.sh` (`UNBREAK_REPO` default). The tap lives in a **separate** repo,
`bart-turczynski/homebrew-tap`, with the formula at `Formula/unbreak.rb`.

## One-time tap setup

1. Create a public repo `bart-turczynski/homebrew-tap` on GitLab. (As of this
   writing that repo does not exist yet — its creation is a human-approved step;
   the release pipeline below never creates it itself, and its tap-mirror job
   fails loudly and non-blockingly until it exists.)
2. Copy `Formula/unbreak.rb` into it at `Formula/unbreak.rb`.
3. Users then install with the **two-argument `brew tap` form**. Homebrew's tap
   shorthand (`brew tap user/repo`) defaults to assuming the tap is hosted on
   GitHub; since this tap lives on GitLab, the actual git URL must be given
   explicitly as the second argument:

   ```sh
   brew tap bart-turczynski/tap https://gitlab.com/bart-turczynski/homebrew-tap.git
   brew install bart-turczynski/tap/unbreak
   ```

   `brew install` only puts the CLI on `PATH`; the watcher is off until the user
   opts in via `unbreak setup` (the single canonical enablement path — the formula
   ships no `service` block, so there is no `brew services` watcher to conflict
   with). The formula's `caveats` says so.

4. **Grant the release pipeline push access to the tap.** The `release:mirror-tap`
   job in [`.gitlab-ci.yml`](../.gitlab-ci.yml) mirrors the formula into the tap on
   every final (non-prerelease) tag, which is a *cross-repo* push — the pipeline's
   own scoped `CI_JOB_TOKEN` can't reach another project. Create a GitLab
   **personal or project access token** scoped to `bart-turczynski/homebrew-tap`
   with the **`write_repository`** scope, then add it to the `unbreak` project as a
   **masked, protected** CI/CD variable named **`HOMEBREW_TAP_TOKEN`**
   (Settings > CI/CD > Variables). This replaces the old GitHub Actions
   `TAP_PUSH_TOKEN` repo secret — same role, different forge. Without it the
   mirror job fails loudly with instructions (but does not block the release: it
   runs `allow_failure: true` and only after the bottle is already uploaded and
   the GitLab Release already created). Access tokens on GitLab can also expire —
   if a later release's mirror job fails on an auth error, the token has most
   likely lapsed; regenerate it and update the `HOMEBREW_TAP_TOKEN` variable.

## Self-hosted runner prerequisite

The release job (like `build`/`test`/`format-check`) only runs on a **self-hosted
macOS runner** tagged `macos` — GitLab's hosted `saas-macos-*` images are
Premium/Ultimate only, and this project is on the `free` tier (see the header
comment in [`.gitlab-ci.yml`](../.gitlab-ci.yml)). Registering that runner
(`gitlab-runner register --tag-list macos ...`) and keeping its Swift toolchain
at 6.3+ (Xcode 26.x, matching `Package.swift`'s `swift-tools-version`) is a
**human, out-of-band step** — no file in this repo registers a runner, installs a
launchd service, or otherwise provisions one.

## Cutting a release

The source-tarball `sha256` must match the tag *before* the bottle is built, so
the formula bump comes first, then the tag, then the pipeline fills in the bottle.

1. **Bump the source fields** in [`Formula/unbreak.rb`](../Formula/unbreak.rb).
   First compute the digest of the tag's source tarball (GitLab generates one per
   tag — push the tag, or compute against the commit you're about to tag). Note
   GitLab's archive root directory is `unbreak-<tag>/` (e.g. `unbreak-v0.7.2/`),
   not GitHub's bare `unbreak-<version>/`:

   ```sh
   curl -fsSL https://gitlab.com/bart-turczynski/unbreak/-/archive/v0.7.2/unbreak-v0.7.2.tar.gz \
     | shasum -a 256
   ```

   Change `version`, `url`, and `sha256` together. The explicit `version` means
   users only update on a bump, not on every `brew update`.

2. **Bump `install.sh`'s `UNBREAK_VERSION` default in the SAME commit.** Find the
   line (anchor on the string, not a line number):

   ```sh
   VERSION="${UNBREAK_VERSION:-v0.7.2}"
   ```

   and its matching `--help` text. This is what the documented `curl | bash`
   one-liner installs, since it fetches `install.sh` from `main`, not from the
   tag — nothing else pins it to a release. It has silently drifted stale before
   (once seven releases behind, shipping `v0.1.0` to every fallback-installer
   user) because bumping it depended on a human remembering to. **The release
   pipeline now enforces this**: the `release` job in `.gitlab-ci.yml` fails the
   release outright if this default disagrees with the tag being released. This
   is a deliberately simple check, not automatic derivation — the pipeline could
   in principle rewrite `install.sh` and push that back to `main` on every tag,
   but that needs push access to a protected branch from CI and invites races
   with whatever else lands on `main`; failing loudly when a human forgot the
   bump is the smaller, safer mechanism for the same guarantee. Commit both
   bumps together.

3. **Tag and push:**

   ```sh
   git tag v0.1.2
   git push origin v0.1.2
   ```

4. **The release pipeline** ([`.gitlab-ci.yml`](../.gitlab-ci.yml), `release`
   stage) fires on the tag pipeline. It:
   - Verifies `install.sh`'s `UNBREAK_VERSION` default matches the tag (failing
     the release immediately if step 2 was skipped).
   - Builds the bottle on the runner, tagged `arm64_ventura` + `ventura` (see
     "Architectures & OS coverage" below).
   - Uploads the bottle tarball under **both** filenames to this project's
     **generic package registry** (GitLab has no direct release-asset upload
     like GitHub — Releases hold *links*, not bytes), authenticated with the
     job's own `JOB-TOKEN` (an interactive OAuth token needs `Authorization:
     Bearer` instead; `PRIVATE-TOKEN` returns 401 — don't copy the interactive
     auth path into CI).
   - Creates a **GitLab Release** for the tag via the plain Releases API (curl +
     `JOB-TOKEN`, reusing the same auth as the package upload — see the comment
     in `.gitlab-ci.yml` for why this was chosen over the `release:` CI/CD
     keyword or `glab release create`), with asset links pointing at the two
     package URLs.
   - Prints the `bottle do` block to the job log and as a `bottle-block.txt` job
     artifact (paste into `Formula/unbreak.rb` for step 5 below).
   - For a final (non-prerelease) tag, in a **separate, non-blocking**
     (`allow_failure: true`) job, **auto-mirrors the finished formula into the
     tap** (`bart-turczynski/homebrew-tap`), injecting the real source sha +
     bottle digest. A hyphenated tag (e.g. `v0.1.2-rc1`) is a prerelease and
     skips this job — stable users must never pour an `-rc` bottle.

5. **Wire the bottle into the in-repo formula (housekeeping).** The tap is already
   updated by step 4. For the in-repo `Formula/unbreak.rb`, paste the
   `bottle-block.txt` artifact (or job-log block) over the old `bottle do` block
   so the committed copy stays current — the next release's
   `brew install --build-bottle` only needs *valid* 64-hex there, so this is no
   longer release-blocking, just tidy.

6. **Verify** a clean bottle install from the tap:

   ```sh
   brew uninstall unbreak 2>/dev/null || true
   brew untap bart-turczynski/tap 2>/dev/null || true
   brew tap bart-turczynski/tap https://gitlab.com/bart-turczynski/homebrew-tap.git
   brew install bart-turczynski/tap/unbreak   # should download the bottle, not compile
   brew test unbreak                          # runs the stdin-repair test block
   brew style ./Formula/unbreak.rb
   ```

   To force-check the source path still works (the bottle's build recipe + the
   no-bottle fallback): `brew install --build-from-source ./Formula/unbreak.rb`.

> **Architectures & OS coverage.** The bottle is built on the self-hosted
> `macos` runner, but the formula's `install` recipe compiles a **universal
> (arm64 + x86_64) binary** in one pass — `swift build -c release --arch arm64
> --arch x86_64`, which SwiftPM `lipo`s itself (no Intel runner needed if the
> build runner's SDK carries x86_64 support). Homebrew only reuses a bottle on a
> macOS release **at or newer than** the bottle's tag, and never across archs, so
> the pipeline relabels the built bottle to the *oldest* supported tag —
> `ventura` (matching `Package.swift` `.macOS(.v13)`) — and publishes the one
> universal tarball under **both** arch tags: `arm64_ventura` (Apple Silicon 13+)
> and `ventura` (Intel 13+). The two package-registry assets are byte-identical
> copies (`:any_skip_relocation` bakes in no arch/path), so they share a single
> `sha256` — the generated `bottle do` block repeats it on both lines. Intel and
> Apple Silicon users both pour a bottle; neither needs the Swift toolchain.

## Fallback installer

For users without Homebrew, `install.sh` fetches the tagged tarball, builds
`-c release`, and installs the binary. It keeps the watcher off unless
`--enable-watch` is passed:

```sh
curl -fsSL https://gitlab.com/bart-turczynski/unbreak/-/raw/main/install.sh | bash
```

Because this always fetches `install.sh` from `main` (never from a tag), its
`UNBREAK_VERSION` default is the only thing that pins which release the
one-liner installs — see step 2 above for how the release pipeline now keeps
that honest.

The LaunchAgent is never templated with a hardcoded path: when enabled, the
binary's own `unbreak install-agent` resolves its absolute path and writes the
per-user plist (§7.4, §8.2).

## Later (§12)

- ~~**Intel / universal bottle** so `x86_64` Macs skip the source build too.~~
  Done — the formula builds a universal binary and the release ships it under
  both `arm64_ventura` and `ventura` tags (see "Architectures & OS coverage").
- **homebrew-core** submission once notability clears the self-submission bar
  (≥90 forks / ≥90 watchers / ≥225 stars, a stable release, and an OSS license).
