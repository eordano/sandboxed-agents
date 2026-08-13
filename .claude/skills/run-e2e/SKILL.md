---
name: run-e2e
description: Run the asciinema e2e recordings for all Linux sandbox backends (bwrap, runsc, microvm, microvm-runsc) and publish the resulting site to builds.example.com. Use when asked to "run e2e", "record agents", "do the recordings", or publish/refresh the recordings dashboard.
disable-model-invocation: true
---

# run-e2e

End-to-end flow: record each agent x backend combination, build the static site, publish it.

Scripts already wired: `scripts/record-agents.sh <backend> [outdir]` records one backend and then calls `scripts/build-recordings-site.sh` on the parent dir. Output defaults to `/tmp/recordings/casts/` on Linux, so running all four backends sequentially builds up a single `/tmp/recordings/` site.

## Prerequisites

1. **`.env` with API keys** at repo root. Must be gitignored -- add `.env` to `.gitignore` if missing. Keys required:
   - `OPENROUTER_API_KEY` (hermes, aider, opencode)
   - `ANTHROPIC_API_KEY` (claude)
   - `GEMINI_API_KEY` (gemini)
   - `OPENAI_API_KEY` (codex; skipped if unset)

2. **Clean host config.** `record-agents.sh` already sets its own `HOME`/`XDG_CONFIG_HOME` into a mktemp dir, so the host's `~/.config` is not touched. Don't override.

3. **Linux only.** All four backends run on Linux; macOS only supports `bwrap`.

## Workflow

```bash
set -a; . .env; set +a                     # load keys into env
rm -rf /tmp/recordings                     # start clean so stale casts don't ship

for backend in bwrap runsc microvm microvm-runsc; do
  scripts/record-agents.sh "$backend" /tmp/recordings/casts
done

# build-recordings-site.sh runs inside record-agents.sh; /tmp/recordings/ is a
# self-contained static site (entry: index.html) ready to publish with any
# static-site host or artifact store.
```

The publish URL is printed on the last line of `publish-build` stdout.

## Notes

- **Partial runs are OK.** `build-recordings-site.sh` renders placeholders for missing `<agent>-<backend>.cast`, so a single failing backend still produces a shippable site -- use `--status partial` if publishing anyway.
- **Cast naming.** `record-agents.sh` sets `CAST_SUFFIX="-${BACKEND}"` for every backend, so casts are always `<agent>-<backend>.cast` -- exactly what the site loader expects. No renaming needed.
- **Timeouts.** `BOOT_TIMEOUT=240` covers microvm guest boot; `TIMEOUT=90` per agent. Override via env if runs are slow.
- **BANANA check.** Each recording is only considered passing when `BANANA` appears in the decoded cast. Failed agents are printed at the end and `record-agents.sh` exits non-zero -- check before publishing with `--status passed`.
- **`publish-build` details.** Reads `git rev-parse --short HEAD` for the commit, so run from inside the repo. Uses `builds@builds.example.com` by default and rrsyncs the folder; the `.done` sentinel is pushed last so the receiver's promote step only fires on a complete upload.

## If something fails

- `asciinema` or `tmux` missing -> `nix shell nixpkgs#asciinema nixpkgs#tmux` before running.
- Agent-specific preroll/setup regressions usually show up as "preroll failed" with the last pane dumped. The patterns live in `scripts/record-lib.sh` (`preroll_*` and `setup_*`). Tweak the regex, don't bump timeouts blindly.
- `publish-build` failing with `not inside a git working tree` -> run from the repo root, not `/tmp`.
