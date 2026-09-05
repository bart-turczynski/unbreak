#!/usr/bin/env bash
#
# unbreak uninstaller (PRD v2 §9) — the counterpart to install.sh, for users who
# installed via the curl one-liner rather than Homebrew.
#
#   curl -fsSL https://gitlab.com/bart-turczynski/unbreak/-/raw/main/uninstall.sh | bash
#
# It runs `unbreak uninstall` to tear down the login watcher, logs, undo socket,
# and config, then removes the `unbreak` binary itself. Homebrew users should run
# `brew uninstall unbreak` instead — this script declines to delete a brew-managed
# binary, since that would desync Homebrew's bookkeeping.
#
# Flags:
#   --keep-config    leave the config file in place (forwarded to `unbreak uninstall`)
#
# Overridable via env:
#   UNBREAK_PREFIX     install prefix to look under; binary -> $PREFIX/bin/unbreak
set -euo pipefail

KEEP_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --keep-config) KEEP_CONFIG=1 ;;
    -h | --help)
      cat <<'USAGE'
unbreak uninstaller (for users who installed without Homebrew).

  curl -fsSL https://gitlab.com/bart-turczynski/unbreak/-/raw/main/uninstall.sh | bash

Tears down unbreak state (login watcher, logs, undo socket, config) and removes the
`unbreak` binary. Homebrew users: run `brew uninstall unbreak` instead.

Options:
  --keep-config    leave the config file in place
  -h, --help       show this help

Env overrides:
  UNBREAK_PREFIX     install prefix to look under (default: search the usual paths)
USAGE
      exit 0
      ;;
    *)
      echo "unbreak uninstall: unknown argument '$arg'" >&2
      exit 2
      ;;
  esac
done

# --- Locate the binary -----------------------------------------------------
# Prefer an explicit prefix, then PATH, then the prefixes install.sh might have
# used. `command -v` resolves symlinks-on-PATH for us.
BIN=""
if [ -n "${UNBREAK_PREFIX:-}" ] && [ -x "$UNBREAK_PREFIX/bin/unbreak" ]; then
  BIN="$UNBREAK_PREFIX/bin/unbreak"
elif command -v unbreak >/dev/null 2>&1; then
  BIN="$(command -v unbreak)"
else
  for candidate in /usr/local/bin/unbreak "$HOME/.local/bin/unbreak"; do
    if [ -x "$candidate" ]; then
      BIN="$candidate"
      break
    fi
  done
fi

if [ -z "$BIN" ]; then
  echo "unbreak uninstall: no unbreak binary found on PATH or in the usual prefixes."
  echo "unbreak uninstall: if you installed via Homebrew, run: brew uninstall unbreak"
  exit 0
fi

# A Homebrew-managed binary must go through brew, not rm — bail with guidance.
RESOLVED="$BIN"
if command -v readlink >/dev/null 2>&1; then
  RESOLVED="$(readlink -f "$BIN" 2>/dev/null || echo "$BIN")"
fi
case "$RESOLVED" in
  */Cellar/* | */Homebrew/*)
    echo "unbreak uninstall: $BIN is Homebrew-managed. Remove it with:"
    echo "    brew uninstall unbreak"
    exit 0
    ;;
esac

# --- Tear down state, then the binary --------------------------------------
echo "unbreak uninstall: removing unbreak state via $BIN"
if [ "$KEEP_CONFIG" -eq 1 ]; then
  "$BIN" uninstall --keep-config || echo "unbreak uninstall: state cleanup reported an issue; continuing."
else
  "$BIN" uninstall || echo "unbreak uninstall: state cleanup reported an issue; continuing."
fi

# Remove the binary. Fall back to sudo only if the location isn't user-writable.
if rm -f "$BIN" 2>/dev/null; then
  echo "unbreak uninstall: removed $BIN"
elif command -v sudo >/dev/null 2>&1; then
  echo "unbreak uninstall: $BIN is not user-writable; removing with sudo"
  sudo rm -f "$BIN" && echo "unbreak uninstall: removed $BIN"
else
  echo "unbreak uninstall: could not remove $BIN (permission denied); delete it manually." >&2
  exit 1
fi

echo "unbreak uninstall: done."
