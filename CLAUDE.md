# CLAUDE.md

Guidance for Claude Code sessions working on this repo. The [README](./README.md) covers what the project does and how users run it; this file covers how to change it.

## Layout

- `lib/sandbox-linux.nix`, `lib/sandbox-darwin.nix`, `lib/microvm-launcher.nix` -- three backends, same CLI surface. Each emits a bash wrapper from a Nix string.
- `lib/shell-blocks.nix` -- shared bash helpers (`_cfg_tristate`, `_resolve_bool`, config parsing).
- `lib/mk-sandbox.nix` -- builder called by each agent's `default.nix`.
- `lib/data.nix` -- canonical lists (cache dirs, common-tools dirs, env whitelist).
- `lib/tests/sandbox.nix` -- parameterized 4-node NixOS VM test; agents pass config in.
- `overlays/default.nix` -- backend x agent variant matrix.
- `docs/` -- one file per backend (`bubblewrap.md`, `microvm.md`, `sandbox-exec.md`, `runsc.md`), plus `flags.md` (the flag-surface spec) and `tun2socks.md`.

## Adding a flag or config key

Three backends must stay in parity. For a boolean toggle `--allow-X`:

1. **Help text** -- extend the heredoc in each of the three backend files.
2. **Init vars** -- `ENABLE_X=0`, `CLI_ENABLE_X=""` before the argv parser.
3. **Argv parser** -- handle `--allow-X` / `--no-allow-X` (alias `--no-x`). Always support both `--flag value` and `--flag=value`.
4. **Resolver** -- after the config is read, one `_resolve_bool ENABLE_X CLI_ENABLE_X SANDBOX_ALLOW_X x <default>` call. Precedence CLI > env > config > default is non-negotiable; don't read config keys directly.
5. **Usage logic** -- gate on `ENABLE_X`. If a backend can't support the flag, *warn and ignore* rather than silently dropping: `echo "Warning: --allow-X is not supported on [backend]; [suggestion]." >&2`. Point users at the native escape hatch when one exists (e.g. microvm suggests `--extra-qemu-args`).
6. **Docs** -- add a row to the `README.md` flag table and a row + bullet to `docs/flags.md` under the right section. Use the `y`/`n`/`p`/`x` support matrix convention.
7. **Test** -- add an assertion to `lib/tests/sandbox.nix` covering both enabled and disabled states.

Repeatable value-flags (`--mount`, `--env`, `--allow-host`, `--extra-*-args`) have **no** `SANDBOX_*` env var -- don't invent one. They have a config-array equivalent (`paths`, `extraEnvs`, `extraBubblewrapArgs`, etc.) and CLI args append to the config values.

## Nix / bash in Nix strings

- `''${VAR}` for bash variables inside `''...''` Nix strings (double-`$` prevents Nix interpolation). Forgetting this is the #1 source of bugs -- if a bash var "disappears," check the escape.
- Interpolate Nix package paths with `${pkg}/bin/foo`. Config reads use `${jq}/bin/jq -r '...' "$CONFIG_FILE"`.
- Prefer `inherit` over re-binding in `let` blocks.
- Conditionals for backend variants (`if isRunsc then ... else ...`) over duplicated files.

## Tests

```bash
nix flake check                                             # everything
nix build .#checks.x86_64-linux.claude-sandbox-test         # bwrap backend (one agent)
nix build .#checks.x86_64-linux.claude-sandbox-runsc-test   # gVisor backend (default for `nix run`)
```

Test attribute names are stable (referenced by `.github/workflows/ci.yml`) and stay keyed by explicit backend, even though gVisor is the user-facing default for `nix run` / unsuffixed packages.

The VM topology is `machine` (runner), `server` (accessible: microsocks:1080, http:8080, mock-api:8090), `blocked` (isolated VLAN), `another` (second accessible host). The mock API in `lib/tests/mock-api-server.py` returns a sentinel `SANDBOX_MOCK_RESPONSE_OK` -- assertions grep for that. Tests assert both filesystem isolation and network boundaries; a new network/credential flag needs both sides exercised.

## Commits & docs

- Single-line commit subjects: `feat:`, `fix:`, `test:`, `docs:`, `chore:`. Parenthetical scopes are comma-separated (`feat: agent recording scripts (bwrap, microvm, runsc)`). No bodies unless something genuinely non-obvious needs saying.
- Bundle related changes into one commit -- feature + tests + docs together, not split per file. Docs land in their own commit when a whole feature set is done.
- Docs are terse and table-heavy. Explain *why* a design is the way it is (e.g. why config is flat, why `--socks-proxy` needs a net namespace) -- not what the code does. Label backend divergence inline, not in a separate section.

## Don'ts

- Don't add a feature flag without wiring all three backends (even if just to warn).
- Don't read config keys outside the `_resolve_bool` / `_cfg_tristate` / `_cfg_bool` helpers.
- Don't introduce profile-selection *inside* a config file -- multi-profile = multiple files, picked with `--sandbox-config`.
- Don't add env vars for repeatable flags.
- Don't skip the warn-and-ignore path for unsupported-on-this-backend flags; silent drops break cross-platform scripts.
