#!/usr/bin/env bash
set -euo pipefail

for cmd in nix git jq; do
  command -v "$cmd" &>/dev/null || {
    echo "Error: '$cmd' required but not found." >&2
    exit 1
  }
done

cd "${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

locked_rev() {
  nix flake metadata --json 2>/dev/null |
    jq -r '.locks.nodes["hermes-agent"].locked.rev'
}

OLD_REV=$(locked_rev)
nix flake update hermes-agent
NEW_REV=$(locked_rev)

if [ "$NEW_REV" = "$OLD_REV" ]; then
  echo "No changes -- hermes-agent already up to date."
  exit 0
fi

echo "Updated hermes-agent to rev ${NEW_REV:0:8}"
