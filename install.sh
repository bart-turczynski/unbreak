#!/usr/bin/env bash
#
# unbreak fallback installer (PRD v2 §9) — for users without Homebrew.
#
#   curl -fsSL https://gitlab.com/bart-turczynski/unbreak/-/raw/main/install.sh | bash
#
# Builds the `unbreak` binary from a tagged source release and installs it. It does
# NOT enable the clipboard watcher: per §8.2 the watcher is opt-in. Pass
# `--enable-watch` to also install the per-user login LaunchAgent (templated by
# `unbreak install-agent`, so there is no hardcoded path or username).
#
# Overridable via env:
#   UNBREAK_REPO     owner/repo to fetch from        (default: bart-turczynski/unbreak)
#   UNBREAK_VERSION  git tag to install              (default: v0.7.2)
#   UNBREAK_PREFIX   install prefix; binary -> $PREFIX/bin/unbreak
#                  (default: /usr/local if writable, else ~/.local)
set -euo pipefail

REPO="${UNBREAK_REPO:-bart-turczynski/unbreak}"
VERSION="${UNBREAK_VERSION:-v0.7.2}"
ENABLE_WATCH=0
for arg in "$@"; do
  case "$arg" in
    --enable-watch) ENABLE_WATCH=1 ;;
    -h | --help)
      cat <<'USAGE'
unbreak fallback installer (for users without Homebrew).

  curl -fsSL https://gitlab.com/bart-turczynski/unbreak/-/raw/main/install.sh | bash

Builds and installs the `unbreak` CLI from a tagged source release. The clipboard
watcher stays OFF unless you pass --enable-watch (or run `unbreak setup` later).

Options:
  --enable-watch   also install the per-user login LaunchAgent (unbreak install-agent)
  -h, --help       show this help

Env overrides:
  UNBREAK_REPO       owner/repo to fetch from   (default: bart-turczynski/unbreak)
  UNBREAK_VERSION    git tag to install         (default: v0.7.2)
  UNBREAK_PREFIX     install prefix             (default: /usr/local or ~/.local)
USAGE
      exit 0
      ;;
    *)
      echo "unbreak install: unknown argument '$arg'" >&2
      exit 2
      ;;
  esac
done

err() {
  echo "unbreak install: $*" >&2
  exit 1
}

# --- Preflight -------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || err "macOS only (this is a native macOS utility)."
need_swift() {
  err "Swift 6.4 or newer is required${1:+ (found Swift $1)}. Install Xcode 27, or the
    Command Line Tools 27 (Swift 6.4): xcode-select --install"
}
command -v swift >/dev/null 2>&1 || need_swift
# `swift --version` prints e.g. "Apple Swift version 6.4 (swiftlang-…)"; keep major.minor.
SWIFT_VERSION="$(swift --version 2>/dev/null |
  sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1.\2/p' | head -n 1)" || true
SWIFT_MAJOR="${SWIFT_VERSION%%.*}"
SWIFT_MINOR="${SWIFT_VERSION#*.}"
if [ -z "$SWIFT_VERSION" ] || [ "$SWIFT_MAJOR" -lt 6 ] ||
  { [ "$SWIFT_MAJOR" -eq 6 ] && [ "$SWIFT_MINOR" -lt 4 ]; }; then
  need_swift "$SWIFT_VERSION"
fi
command -v curl >/dev/null 2>&1 || err "curl is required."

# Choose an install prefix we can actually write to.
if [ -n "${UNBREAK_PREFIX:-}" ]; then
  PREFIX="$UNBREAK_PREFIX"
elif [ -w /usr/local/bin ] || { [ -d /usr/local ] && [ -w /usr/local ]; }; then
  PREFIX="/usr/local"
else
  PREFIX="$HOME/.local"
fi
BINDIR="$PREFIX/bin"

# --- Fetch + build ---------------------------------------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TARBALL="https://gitlab.com/$REPO/-/archive/$VERSION/unbreak-$VERSION.tar.gz"

echo "unbreak install: downloading $REPO@$VERSION"
curl -fsSL "$TARBALL" -o "$WORKDIR/src.tar.gz" ||
  err "failed to download $TARBALL"
tar -xzf "$WORKDIR/src.tar.gz" -C "$WORKDIR"
SRCDIR="$(find "$WORKDIR" -maxdepth 1 -type d -name 'unbreak-*' | head -n1)"
[ -n "$SRCDIR" ] || err "unexpected archive layout."

echo "unbreak install: building (release)"
(cd "$SRCDIR" && swift build -c release) || err "build failed."
# The products directory differs between toolchains; ask SwiftPM, same flags.
BINPATH="$(cd "$SRCDIR" && swift build -c release --show-bin-path)" ||
  err "could not locate the build output."
BUILT="$BINPATH/unbreak"
[ -x "$BUILT" ] || err "build did not produce a unbreak binary."

# --- Install ---------------------------------------------------------------
mkdir -p "$BINDIR"
install -m 0755 "$BUILT" "$BINDIR/unbreak"
echo "unbreak install: installed $BINDIR/unbreak"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "unbreak install: note — $BINDIR is not on your PATH; add it to your shell profile." ;;
esac

# --- Watcher (opt-in) ------------------------------------------------------
if [ "$ENABLE_WATCH" -eq 1 ]; then
  echo "unbreak install: enabling the login watcher"
  "$BINDIR/unbreak" install-agent
else
  cat <<EOF

The clipboard watcher is OFF until you opt in. Enable it with the guided setup:
    unbreak setup
or directly install the login LaunchAgent:
    unbreak install-agent

One-shot use never needs the watcher:
    pbpaste | unbreak -
EOF
fi
