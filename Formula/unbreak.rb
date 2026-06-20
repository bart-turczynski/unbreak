# Homebrew formula for unbreak (PRD v2 §9).
#
# Lives in the tap repo `bart-turczynski/homebrew-tap` as `Formula/unbreak.rb`, so
# users install with:
#
#   brew install bart-turczynski/tap/unbreak
#
# Installs come from a prebuilt **bottle** (see the `bottle do` block) so users
# need no Swift toolchain. The `install` recipe below still builds from source —
# it is both how the release workflow *produces* the bottle and the automatic
# fallback for any platform without a matching bottle (then the Xcode Command
# Line Tools are required). On each tagged release, bump `version`, `url`, and
# `sha256` (source tarball) together, then paste the workflow-generated bottle
# block — see docs/RELEASING.md.
class Unbreak < Formula
  desc "Repair terminal-wrapped clipboard commands from TUI coding agents"
  homepage "https://github.com/bart-turczynski/unbreak"
  # Source tarball for the tagged release. `version` is explicit so users update
  # only on a bump, not on every tap refresh.
  url "https://github.com/bart-turczynski/unbreak/archive/refs/tags/v0.5.3.tar.gz"
  version "0.5.3"
  # Digest of the v0.2.0 source tarball (see docs/RELEASING.md):
  #   curl -fsSL .../v0.2.0.tar.gz | shasum -a 256
  # NOTE: in *this* repo the formula ships inside the tarball it points at, so a
  # self-consistent source sha is impossible — the tap repo's copy carries the
  # real digest, and release.yml injects it for the bottle build. This value is a
  # placeholder until mirrored to the tap.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  # Prebuilt binary, hosted as a GitHub release asset (see .github/workflows/
  # release.yml). The job builds on the macos-26 runner but relabels the bottle to
  # the OLDEST supported macOS (arm64_ventura = Package.swift .macOS(.v13)) so
  # newer systems reuse it — one file serves macOS 13+ on Apple Silicon. Paste the
  # job-generated block here and in the tap. `:any_skip_relocation` is correct:
  # the binary hardcodes no Cellar path (links only system libs + the OS Swift
  # runtime).
  bottle do
    root_url "https://github.com/bart-turczynski/unbreak/releases/download/v0.5.3"
    # Real v0.5.3 bottle digest, produced by release.yml. On the NEXT bump keep a
    # valid 64-hex value here even before rebuilding: the workflow's `brew install
    # --build-bottle` parses this block (the v0.3.0 lesson — a bad placeholder
    # failed the first tagged build).
    sha256 cellar: :any_skip_relocation, arm64_ventura: "243119bd5bf0529727c8a743076847b3f1e61e3f54dcc517aaac1fd9779975b0"
  end

  depends_on :macos

  def install
    # Self-contained SwiftPM package (no external deps): a release build with the
    # sandbox disabled so SwiftPM can write its build products.
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/unbreak"
  end

  # `brew services start unbreak` generates the per-user launchd plist — no
  # hardcoded path or username (§9). The watcher only mutates the clipboard when
  # every §7 gate passes.
  service do
    run [opt_bin/"unbreak", "--watch"]
    run_type :immediate
    keep_alive true
    log_path var/"log/unbreak.watch.log"
    error_log_path var/"log/unbreak.watch.log"
  end

  def caveats
    <<~EOS
      The clipboard watcher is OFF until you opt in — `brew install` only puts the
      CLI on your PATH. Turn it on with either:

        brew services start unbreak     # run the watcher at login (launchd)

      or the guided setup, which detects your terminals and writes a config first:

        unbreak setup

      One-shot use never needs the watcher:

        pbpaste | unbreak -             # repair clipboard text, print to stdout

      To remove everything unbreak wrote (login watcher, logs, undo socket, config)
      before `brew uninstall unbreak`, run:

        unbreak uninstall               # `brew uninstall` alone leaves this state behind
    EOS
  end

  test do
    # Exercise the core repair path over stdin: §6.1 normalize must strip ANSI
    # escapes (the stdin->stdout surface never touches the real clipboard).
    assert_equal "git status",
      pipe_output("#{bin}/unbreak -", "\e[31mgit status\e[0m\n").strip
  end
end
