#!/usr/bin/env bash
set -euo pipefail

command -v gh >/dev/null 2>&1 || {
  echo "error: gh CLI required (https://cli.github.com)" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "error: jq required" >&2
  exit 1
}

resolve_sha() {
  local action="$1" ref="$2" response type sha
  response=$(gh api "repos/${action}/git/ref/tags/${ref}" 2>/dev/null) ||
    response=$(gh api "repos/${action}/git/ref/heads/${ref}" 2>/dev/null) ||
    {
      echo "warning: cannot resolve ${action}@${ref}" >&2
      return 1
    }

  type=$(jq -r '.object.type' <<<"$response")
  sha=$(jq -r '.object.sha' <<<"$response")

  if [ "$type" = "tag" ]; then
    sha=$(gh api "repos/${action}/git/tags/${sha}" --jq '.object.sha') ||
      {
        echo "warning: cannot dereference tag object for ${action}@${ref}" >&2
        return 1
      }
  fi

  echo "$sha"
}

WORKFLOWS=(.github/workflows/*.yml .forgejo/workflows/*.yml)

for workflow in "${WORKFLOWS[@]}"; do
  echo "Processing $workflow ..."
  changed=0

  while IFS= read -r line; do
    if [[ "$line" =~ ^([[:space:]]*(-[[:space:]]*)?)uses:[[:space:]]*(([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+))@([A-Za-z0-9_./-]+) ]]; then
      indent="${BASH_REMATCH[1]}"
      action="${BASH_REMATCH[3]}"
      ref="${BASH_REMATCH[6]}"
      [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && continue
      sha=$(resolve_sha "$action" "$ref") || continue
      echo "  ${action}@${ref} -> ${sha}"
      sed -i \
        "s|${indent}uses: ${action}@${ref}.*|${indent}uses: ${action}@${sha}  # ${ref}|" \
        "$workflow"
      changed=1
    fi
  done <"$workflow"

  [ "$changed" -eq 1 ] && echo "  -> updated" || echo "  -> no unpinned actions found"
done
