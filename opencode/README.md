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
