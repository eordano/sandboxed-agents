# Sandboxed OpenCode

- `apiBaseUrlEnvVars` covers both `ANTHROPIC_BASE_URL` and
  `OPENAI_BASE_URL` so the `internetAccess=false` pre-flight accepts
  either provider's override (whichever the user is wiring their proxy at).
- `sandboxHomeDest = ".config/opencode"` -- the sandbox's XDG config
  dir is the agent's home, not a dotfile. OpenCode was born
  XDG-native; there's no `~/.opencode` legacy path to remap.
- `configDir = ./config` ships default config with the package; it's
  staged into the sandbox at launch (see `configDeployLines` in
  `lib/shell-blocks.nix`).
- `extraHomeAllow` exposes `.opencode`, `.config/opencode`, and
  `.local/share/opencode` from the host even when XDG remap is off.
- `cccp ? null`: when the overlay passes a `cccp` package, the launcher
  copies `${cccp}/share/cccp/plugin/opencode/cccp.js` into the config
  root's `plugin/` at init (bwrap: the host's `$XDG_CONFIG_HOME/opencode`,
  which is what gets bound at `~/.config/opencode`; microvm: the guest
  `$HOME/.config/opencode`) and puts `cccp` on the sandbox PATH. OpenCode
  auto-discovers `plugin/*.js` under its global config dir -- but only
  real files, a symlinked plugin is skipped by its glob. A file of that
  name that lacks the `// @cccp-plugin opencode` marker is the user's
  and is left alone with a warning. The plugin writes
  `$XDG_DATA_HOME/opencode/transcripts/<session>.jsonl` and the daemon
  state under `$XDG_DATA_HOME/opencode/cccp/`, both inside the already
  home-allowed `.local/share/opencode`.
