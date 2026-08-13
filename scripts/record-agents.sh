#!/usr/bin/env bash

set -euo pipefail

IS_DARWIN=0
[ "$(uname -s)" = "Darwin" ] && IS_DARWIN=1

BACKEND="${BACKEND:-bwrap}"
if [ $# -gt 0 ] && [[ "$1" =~ ^(bwrap|microvm|runsc|microvm-runsc)$ ]]; then
  BACKEND="$1"
  shift
fi
case "$BACKEND" in
  bwrap) ;;
  microvm | runsc | microvm-runsc)
    if [ "$IS_DARWIN" = 1 ]; then
      echo "Error: backend '$BACKEND' is Linux-only. macOS only supports 'bwrap' (seatbelt)." >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [bwrap|microvm|runsc|microvm-runsc] [outdir]" >&2
    exit 2
    ;;
esac

DEFAULT_OUTDIR="/tmp/recordings/casts"
[ "$IS_DARWIN" = 1 ] && DEFAULT_OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/recordings/casts"
OUTDIR="${1:-$DEFAULT_OUTDIR}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUTDIR"

: "${OPENROUTER_API_KEY:?Set OPENROUTER_API_KEY}"
: "${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY}"
: "${GEMINI_API_KEY:?Set GEMINI_API_KEY}"

tmp_suffix=""
[ "$BACKEND" != "bwrap" ] && tmp_suffix="-${BACKEND}"
case "$BACKEND" in
  microvm-runsc) MKTMP_BASE="${TMPDIR:-/var/tmp}" ;;
  *) MKTMP_BASE="${TMPDIR:-/tmp}" ;;
esac
MKTMP_BASE="${MKTMP_BASE%/}"
mkdir -p "$MKTMP_BASE"
WORKDIR="$(mktemp -d "${MKTMP_BASE}/agent-rec${tmp_suffix}-XXXXXX")"
FAKE_HOME="$(mktemp -d "${MKTMP_BASE}/agent-home${tmp_suffix}-XXXXXX")"
TMUX_SOCK="agentrec-$$"

REAL_HOME="${HOME:-/home/$USER}"
export HOME="$FAKE_HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
for p in .cache/nix .nix-profile .nix-defexpr; do
  [ -e "$REAL_HOME/$p" ] && ln -sf "$REAL_HOME/$p" "$HOME/$p" 2>/dev/null || true
done

EMPTY_CFG="$WORKDIR/.sandbox-empty.json"
echo '{}' >"$EMPTY_CFG"

export CAST_SUFFIX="-${BACKEND}"

cleanup() {
  tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
  chmod -R u+w "$WORKDIR" "$FAKE_HOME" 2>/dev/null || true
  rm -rf "$WORKDIR" "$FAKE_HOME" 2>/dev/null || true
}
trap cleanup EXIT

export BACKEND SRC WORKDIR OUTDIR EMPTY_CFG TMUX_SOCK

. "$(dirname "$0")/record-lib.sh"

rc=0
record_main || rc=$?

"$(dirname "$0")/build-recordings-site.sh" "$(dirname "$OUTDIR")" || true

exit "$rc"
