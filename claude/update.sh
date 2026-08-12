#!/usr/bin/env bash
set -euo pipefail

if [ -n "${REPO_ROOT:-}" ]; then
  SCRIPT_DIR="$REPO_ROOT/claude"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
DEFAULT_NIX="$SCRIPT_DIR/claude-binary.nix"

GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

declare -A PLATFORMS=(
  ["x86_64-linux"]="linux-x64"
  ["aarch64-linux"]="linux-arm64"
  ["aarch64-darwin"]="darwin-arm64"
  ["x86_64-darwin"]="darwin-x64"
)

LATEST_VERSION=$(curl -sf "$GCS_BASE/latest")
if ! [[ "$LATEST_VERSION" =~ ^[0-9A-Za-z._+-]+$ ]]; then
  echo "ERROR: suspicious upstream version '$LATEST_VERSION'." >&2
  exit 1
fi
CURRENT_VERSION=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' "$DEFAULT_NIX" | head -1)

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
  echo "Already at latest version $LATEST_VERSION."
  exit 0
fi

MANIFEST=$(curl -sf "$GCS_BASE/$LATEST_VERSION/manifest.json")

# Prefetch and verify every platform before touching the file, so a bad
# platform can't leave a half-updated version/hash mix behind.
declare -A HASHES=()
for nix_system in "${!PLATFORMS[@]}"; do
  gcs_platform="${PLATFORMS[$nix_system]}"
  EXPECTED_SHA256=$(echo "$MANIFEST" | jq -r ".platforms[\"$gcs_platform\"].checksum")
  if [ -z "$EXPECTED_SHA256" ] || [ "$EXPECTED_SHA256" = "null" ]; then
    echo "ERROR: no checksum for $gcs_platform in manifest" >&2
    exit 1
  fi

  BINARY_URL="$GCS_BASE/$LATEST_VERSION/$gcs_platform/claude"
  PREFETCH_OUTPUT=$(nix-prefetch-url --type sha256 --print-path "$BINARY_URL")
  NEW_HASH=$(echo "$PREFETCH_OUTPUT" | head -1)
  NIX_STORE_PATH=$(echo "$PREFETCH_OUTPUT" | tail -1)

  ACTUAL_SHA256=$(sha256sum "$NIX_STORE_PATH" | cut -d' ' -f1)
  if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "ERROR: checksum mismatch for $gcs_platform: got $ACTUAL_SHA256, expected $EXPECTED_SHA256" >&2
    exit 1
  fi

  if ! grep -aqF "$LATEST_VERSION" "$NIX_STORE_PATH"; then
    echo "ERROR: binary for $gcs_platform does not contain version string '$LATEST_VERSION' -- CDN may be serving a stale artifact" >&2
    exit 1
  fi

  HASHES[$nix_system]="$NEW_HASH"
done

for nix_system in "${!HASHES[@]}"; do
  sed -i "/\"$nix_system\"/,/};/ s/sha256 = \"[^\"]*\"/sha256 = \"${HASHES[$nix_system]}\"/" "$DEFAULT_NIX"
done
sed -i "s/version = \"[^\"]*\";/version = \"$LATEST_VERSION\";/" "$DEFAULT_NIX"
echo "Updated claude $CURRENT_VERSION -> $LATEST_VERSION"
