#!/usr/bin/env bash
set -euo pipefail

if [ -n "${REPO_ROOT:-}" ]; then
  SCRIPT_DIR="$REPO_ROOT/codex"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
PREBUILT_NIX="$SCRIPT_DIR/codex-binary-prebuilt.nix"

REPO="openai/codex"
TAG_PFX="rust-v"

LATEST_TAG=$(curl -sf ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
  "https://api.github.com/repos/$REPO/releases" |
  jq -r "[.[] | select(.prerelease == false) | select(.tag_name | startswith(\"$TAG_PFX\"))][0].tag_name")
if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
  echo "ERROR: no $TAG_PFX* release found." >&2
  exit 1
fi
LATEST_VERSION="${LATEST_TAG#${TAG_PFX}}"
if ! [[ "$LATEST_VERSION" =~ ^[0-9A-Za-z._+-]+$ ]]; then
  echo "ERROR: suspicious upstream version '$LATEST_VERSION'." >&2
  exit 1
fi
CURRENT_VERSION=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' "$PREBUILT_NIX" | head -1)

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
  echo "Already at latest version $LATEST_VERSION."
  exit 0
fi

declare -A ASSETS=(
  ["x86_64-linux"]="codex-x86_64-unknown-linux-musl"
  ["aarch64-linux"]="codex-aarch64-unknown-linux-musl"
  ["x86_64-darwin"]="codex-x86_64-apple-darwin"
  ["aarch64-darwin"]="codex-aarch64-apple-darwin"
)

# Prefetch every platform before touching the file, so a missing asset
# can't leave a half-updated version/hash mix behind.
declare -A HASHES=()
for nix_system in "${!ASSETS[@]}"; do
  asset="${ASSETS[$nix_system]}"
  url="https://github.com/$REPO/releases/download/$LATEST_TAG/$asset.tar.gz"
  if ! raw_hash=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null); then
    echo "ERROR: $asset.tar.gz not available for $LATEST_TAG; aborting without changes." >&2
    exit 1
  fi
  HASHES[$nix_system]=$(nix-hash --to-sri --type sha256 "$raw_hash")
done

for nix_system in "${!HASHES[@]}"; do
  sed -i "/\"$nix_system\"/,/};/ s|sha256 = \"[^\"]*\"|sha256 = \"${HASHES[$nix_system]}\"|" "$PREBUILT_NIX"
done
sed -i "s/version = \"[^\"]*\";/version = \"$LATEST_VERSION\";/" "$PREBUILT_NIX"
echo "Updated codex $CURRENT_VERSION -> $LATEST_VERSION"
