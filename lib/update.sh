#!/usr/bin/env bash
set -euo pipefail

AGENT="${1:?Usage: $0 <agent>}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${REPO_ROOT:-}" ]; then
  REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
fi
export REPO_ROOT

case "$AGENT" in
  claude | hermes | codex)
    exec bash "$REPO_ROOT/$AGENT/update.sh"
    ;;
esac

source "$LIB_DIR/update-lib.sh"

case "$AGENT" in
  aider)
    REPO=Aider-AI/aider
    INPUT=aider-src
    HASH_FIELD=""
    ;;
  gemini)
    REPO=google-gemini/gemini-cli
    INPUT=gemini-src
    HASH_FIELD=npmDepsHash
    ;;
  opencode)
    REPO=anomalyco/opencode
    INPUT=opencode-src
    HASH_FIELD=outputHash
    ;;
  *)
    echo "Unknown agent: $AGENT" >&2
    exit 1
    ;;
esac

update_init "$AGENT" "$REPO_ROOT/$AGENT/$AGENT-binary.nix"

LATEST=$(curl -sf ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
  "https://api.github.com/repos/$REPO/releases/latest" |
  jq -r .tag_name | sed 's/^v//')
check_version "$LATEST"

nix flake lock --override-input "$INPUT" "github:$REPO/v$LATEST"
# Keep the declared input ref in sync with the lock, or the next
# `nix flake update` silently reverts the source to the old tag.
sed -i "s|github:$REPO/v[^\"]*|github:$REPO/v$LATEST|" "$REPO_ROOT/flake.nix"

bump_version

if [ -n "$HASH_FIELD" ]; then
  compute_hash "$HASH_FIELD" "$AGENT"
fi
