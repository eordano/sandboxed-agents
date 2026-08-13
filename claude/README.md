# Sandboxed Claude Code

- `--yolo` / `"yolo": true` passes `--dangerously-skip-permissions`
- The sandbox init rewrites the agent's `.config.json` with
  `installMethod = "native"` and `autoUpdates = false`. The former
  suppresses `claude doctor` warnings; the latter stops the agent
  from trying to replace a Nix-store binary on disk.
- `~/.local/bin/claude` inside the sandbox is symlinked to the resolved
  agent binary so `claude`-invoking-`claude` subcommands (MCP, hooks)
  find themselves on `$PATH` instead of the unsandboxed host binary.
- Telemetry and upgrade paths are disabled via env: `DISABLE_TELEMETRY`,
  `DISABLE_AUTOUPDATER`, `DISABLE_ERROR_REPORTING`, `DISABLE_UPGRADE_COMMAND`,
  `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY`,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
  `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL`. These aren't user-configurable;
  if one breaks a workflow, flip it in `claude/default.nix`.
