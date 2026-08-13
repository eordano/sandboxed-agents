#!/usr/bin/env bash
set -euo pipefail

FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

update_init() {
  AGENT_NAME="$1"
  if [ -n "${REPO_ROOT:-}" ]; then
    BINARY_NIX="$REPO_ROOT/$AGENT_NAME/$(basename "$2")"
  else
    BINARY_NIX="$2"
    REPO_ROOT="$(cd "$(dirname "$BINARY_NIX")/.." && pwd)"
  fi

  for cmd in nix git curl jq; do
    command -v "$cmd" &>/dev/null || {
      echo "Error: '$cmd' required." >&2
      exit 1
    }
  done

  # Snapshot the files the update mutates, so a failed run can restore them
  # without discarding unrelated uncommitted changes (as git checkout would).
  _SNAP_DIR=$(mktemp -d)
  cp "$BINARY_NIX" "$_SNAP_DIR/binary.nix"
  cp "$REPO_ROOT/flake.nix" "$REPO_ROOT/flake.lock" "$_SNAP_DIR/"

  # A Ctrl-C during the (long) hash-probing build would otherwise leave the
  # fake hash and a bumped version/lock in the tree, which does not just fail
  # the next build -- it is a committable state.
  trap _update_restore EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  CURRENT=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' "$BINARY_NIX" | head -1)
  CURRENT_SYSTEM="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
}

_update_restore() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "${_SNAP_DIR:-}" ]; then
    cp "$_SNAP_DIR/binary.nix" "$BINARY_NIX" || true
    cp "$_SNAP_DIR/flake.nix" "$REPO_ROOT/flake.nix" || true
    cp "$_SNAP_DIR/flake.lock" "$REPO_ROOT/flake.lock" || true
  fi
  return "$rc"
}

version_lte() {
  printf '%s\n%s\n' "$1" "$2" | sort -V | head -1 | grep -qFx "$1"
}

check_version() {
  LATEST="$1"
  # The version is spliced into sed scripts and flake refs -- reject anything
  # that isn't a plain version string before it can corrupt them.
  if ! [[ "$LATEST" =~ ^[0-9A-Za-z._+-]+$ ]]; then
    echo "ERROR: suspicious upstream version '$LATEST'." >&2
    exit 1
  fi
  if [ "$CURRENT" = "$LATEST" ]; then
    echo "Already at latest version $LATEST."
    exit 0
  fi
  if version_lte "$LATEST" "$CURRENT"; then
    echo "Latest release $LATEST is not newer than current $CURRENT, skipping."
    exit 0
  fi
}

bump_version() {
  sed -i "s/version = \"[^\"]*\";/version = \"$LATEST\";/" "$BINARY_NIX"
}

compute_hash() {
  local field="$1" label="$2"

  sed -i "s/${field} = \"sha256-[^\"]*\";/${field} = \"${FAKE_HASH}\";/" "$BINARY_NIX"
  if ! grep -qF "${field} = \"${FAKE_HASH}\";" "$BINARY_NIX"; then
    echo "ERROR: no ${field} field found in $BINARY_NIX." >&2
    exit 1
  fi

  local log hash
  log=$(mktemp)

  nix build --no-link "$REPO_ROOT#packages.${CURRENT_SYSTEM}.$AGENT_NAME" >"$log" 2>&1 || true
  hash=$(sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+=).*/\1/p' "$log" | tail -1)

  if [ -z "$hash" ]; then
    echo "ERROR: Could not extract ${label} hash. Last 20 lines of build log:" >&2
    tail -20 "$log" >&2
    rm -f "$log"
    # Don't leave the fake hash (and a half-bumped version/lock) behind.
    cp "$_SNAP_DIR/binary.nix" "$BINARY_NIX"
    cp "$_SNAP_DIR/flake.nix" "$REPO_ROOT/flake.nix"
    cp "$_SNAP_DIR/flake.lock" "$REPO_ROOT/flake.lock"
    exit 1
  fi

  rm -f "$log"
  sed -i "s|${field} = \"${FAKE_HASH}\";|${field} = \"${hash}\";|" "$BINARY_NIX"
}
