# Sandboxed Agents

Nix flake that wraps AI coding agents in gVisor (Linux, default), bubblewrap (Linux), microVM (Linux/aarch64-darwin), or seatbelt (macOS) sandboxes. The agent runs with filesystem isolation, optional network isolation via SOCKS proxy, and no access to your API keys.

## Agents

| Agent | Source |
|---|---|
| [Claude Code](./claude/) | Fetched binary from Anthropic GCS |
| [Hermes](./hermes/) | Flake input (`hermes-agent`) |
| [OpenCode](./opencode/) | Built from GitHub (`anomalyco/opencode`) |
| [Codex](./codex/) | Prebuilt binary from `openai/codex` releases |
| [Gemini CLI](./gemini/) | Built from GitHub (`google-gemini/gemini-cli`) |
| [Aider](./aider/) | Built from GitHub (`Aider-AI/aider`) |

All agents run under gVisor by default on Linux and seatbelt on macOS.

## Quick Start

```bash
nix run github:eordano/sandboxed-agents                   # Claude Code (gVisor on Linux, seatbelt on macOS)
nix run github:eordano/sandboxed-agents#hermes            # or any agent from the table
nix run github:eordano/sandboxed-agents#claude-runsc      # gVisor backend (Linux; alias of the default)
nix run github:eordano/sandboxed-agents#claude-bwrap      # bubblewrap backend (Linux)
nix run github:eordano/sandboxed-agents#claude-microvm    # microVM backend (Linux + aarch64-darwin for claude)
```

The wrapper binary is named after the agent (`claude`, `hermes`, etc.). The unsandboxed binary is `<agent>-achtung-achtung`. Each agent is exposed in four package names on Linux: `<agent>` (gVisor -- the default), `<agent>-runsc` (explicit alias of the default), `<agent>-bwrap` (bubblewrap), and `<agent>-microvm` (microVM). On macOS the unsuffixed `<agent>` is the seatbelt build, and `<agent>-microvm` is offered only for claude on aarch64-darwin.

All variants of an agent install the same `bin/<agent>` (and `bin/<agent>-achtung-achtung`), so only one variant per agent can live in a profile at a time. Use `nix run .#<agent>-bwrap` / `.#<agent>-microvm` to invoke a non-default backend ad-hoc, or pick the variant you want with `home.packages = [ pkgs.sandboxedAgents.<agent>-bwrap ]` etc.

Bash, zsh, and fish completions are installed alongside each wrapper and cover all sandbox flags (with `--no-...` and value completion). They are picked up automatically when the package is on `XDG_DATA_DIRS` (e.g. via home-manager or `nix profile install`).

### Home-Manager

Use your sandboxed binary with their options by setting e.g.:

```nix
programs.claude-code = {
  enable = true;
  package = sandboxed-agents.packages.${system}.claude;
  settings = { ... };
  mcpServers = { ... };
};
```

## What the Sandbox Does

### Filesystem

Fresh `$HOME` with only these paths mounted by default: current directory (rw), `/nix` (immutable), `/etc` (ro), and agent-specific config dirs/state. Shared developer caches and toolchain homes are explicit mount flags: `--mount-home-cache` and `--mount-common-home-folders` (or config `"mountHomeCache": true`, `"mountCommonHomeFolders": true`).

### Credential Isolation

API keys are never passed in. Environment whitelist: `PATH`, `HOME`, `USER`, `LOGNAME`, `MAIL`, `TERM`, `SHELL`, `LANG`, `TZ`, plus SSL cert paths pointing to the Nix `cacert` store path. Provide credentials via a SOCKS proxy (e.g. mitmproxy) that injects API headers at the proxy layer.

The two platforms reach the same "no credentials leak" outcome via different mechanisms:

- **Linux (bwrap/runsc/microvm)** -- the sandbox gets a fresh ephemeral `$HOME`, so paths like `~/.aws`, `~/.ssh`, `~/.gnupg`, `~/.kube`, browser keyrings, etc. do not exist inside it. No explicit deny-list is needed.
- **macOS (seatbelt)** -- seatbelt has no filesystem namespace; the sandbox shares the real `$HOME`. An explicit deny-list blocks reads of `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`, `~/.config/gcloud`, `~/.docker`, `~/.gitconfig`, `~/.git-credentials`, `~/.netrc`, `~/.kube`, `~/.terraform.d`, `~/.config/gh`, `~/.local/share/keyrings`, `~/.gnome-keyring`, `~/.password-store`, `~/.1password`, `~/.bitwarden`. `--allow-ssh`/`--allow-gpg`/`--allow-git`/`--allow-docker` remove the corresponding entry when those specific credentials are intentionally granted.

### Network

Default: shared host network unless a `socksProxy` is configured. With `--socks-proxy` or config `"socksProxy"`, Linux enters an isolated network namespace (`unshare --user --net` + `slirp4netns` + `tun2socks`): non-private traffic goes through the proxy, while local/private network ranges stay reachable directly. `--no-internet-access` (or `"internetAccess": false`) drops non-private egress at iptables. `--disable-networking` blocks all non-localhost traffic. `--allow-host HOST` punches through for specific hosts.

### XDG Base Directory Remapping

On Linux, the sandbox can bind-mount `$XDG_CONFIG_HOME/<agent>/` to `~/.<agent>/` inside the sandbox. Off by default; enable with `"xdgRemap": true` in config or `SANDBOX_XDG_REMAP=1`. Respects `$XDG_CONFIG_HOME`, falls back to dotfile paths. No effect on macOS.

| Agent | Legacy path | XDG path (host) |
|---|---|---|
| Claude Code | `~/.claude/`, `~/.claude.json` | `~/.config/claude/` |
| Hermes | `~/.hermes/` | `~/.config/hermes/` |
| OpenCode | -- | `~/.config/opencode/` |
| Codex | `~/.codex/` | `~/.config/codex/` |
| Gemini CLI | `~/.gemini/` | `~/.config/gemini/` |
| Aider | `~/.aider/`, `~/.aider.conf.yml`, `~/.aider.model.metadata.json` | `~/.config/aider/` |

## Configuration

Each agent looks for its config at, in order: `--sandbox-config FILE`, `$SANDBOX_CONFIG_FILE`, the nearest `<agent>-sandbox.json` found walking up from the current directory to `/`, then `${XDG_CONFIG_HOME:-~/.config}/<agent>-sandbox.json` (e.g. `claude-sandbox.json`). `$XDG_CONFIG_HOME` is respected; it defaults to `~/.config` if unset. The per-directory file lets a project pin its own sandbox profile without committing global config.

All agents accept the same CLI flags. Every boolean toggle has a `--no-X` counterpart (e.g. `--no-allow-ssh`, alias `--no-ssh`) and a matching `SANDBOX_X` env var (e.g. `SANDBOX_ALLOW_SSH={0,1,true,false,yes,no,on,off}`). Precedence: CLI > env > config > default. See [docs/flags.md](./docs/flags.md) for the full rules. Unsupported flags on macOS/microvm print a warning. Unrecognized flags are forwarded to the agent.

| Flag | Config key | Type | Description |
|---|---|---|---|
| `--allow-ssh` | `ssh` | bool | Mount `~/.ssh` (read-only) + `SSH_AUTH_SOCK` |
| `--allow-ssh-write` | `sshWrite` | bool | Upgrade `~/.ssh` mount to read-write |
| `--allow-gpg` | `gpg` | bool | Mount `~/.gnupg` + bridge gpg-agent socket |
| `--allow-git` | `git` | bool | Mount `~/.gitconfig`, `~/.git-credentials` |
| `--allow-docker` | `docker` | bool | Mount Docker socket |
| `--allow-fuse` | `fuse` | bool | Mount `/dev/fuse` and user runtime dir |
| `--allow-gui` | `gui` | bool | Mount X11/Wayland, DRI, fonts, themes, audio |
| `--allow-nvidia` | `nvidia` | bool | Mount NVIDIA devices and OpenGL driver |
| `--allow-kvm` | `kvm` | bool | Mount `/dev/kvm` and `/dev/vfio` |
| `--allow-audio` | `audio` | bool | Mount PulseAudio/PipeWire and `/dev/snd` |
| `--allow-libvirt` | `libvirt` | bool | Mount libvirt sockets |
| `--allow-home-access` | `allowHome` | bool | Allow running from `$HOME` (weakens isolation) |
| `--allow-internet-access` | `internetAccess` | bool | Allow internet access (default true; env `SANDBOX_INTERNET_ACCESS`) |
| `--no-internet-access` | `internetAccess: false` | bool | Block non-private egress (RFC1918 / loopback / link-local stay reachable) |
| `--allow-host HOST` | | string | Allow traffic to a specific host (with `--disable-networking`) |
| `--disable-networking` | `disableNetworking` | bool | Block all non-localhost connections |
| `--socks-proxy HOST:PORT` | `socksProxy` | string | SOCKS5 proxy (Linux only) |
| `--backend BACKEND` | `backend` | string | Re-exec under `bwrap`\|`runsc`\|`microvm`. CLI > `SANDBOX_BACKEND` env > config > wrapper's own backend. Targets the `<agent>-{sandbox,runsc,microvm}` symlink on PATH; errors if not installed. |
| `--sandbox-config FILENAME` | | string | Use a specific config file |
| `--mount-home-cache` | `mountHomeCache` | bool | Mount `~/.cache/*` dirs for common dev tools |
| `--mount-common-home-folders` | `mountCommonHomeFolders` | bool | Mount common toolchain homes (`~/.cargo`, `~/.npm`, etc.) |
| `--mount-tmp` | `mountTmp` | bool | Mount the real `/tmp` instead of ephemeral sandbox tmp (Linux only; no-op on macOS where `/tmp` is always writable) |
| `--mount PATH` | `paths` | string[] | Transparent bind-mount (supports `ro:/path`, `/host:/guest`) |
| `--env KEY=VALUE` | `extraEnvs` | string[] | Extra env vars (repeatable) |
| `--extra-bubblewrap-args ARG` | `extraBubblewrapArgs` | string[] | Pass ARG verbatim to `bwrap` (Linux/bwrap only) |
| `--extra-runsc-args ARG` | `extraRunscArgs` | string[] | Pass ARG verbatim to `runsc` (Linux/runsc only) |
| `--extra-qemu-args ARG` | `extraQemuArgs` | string[] | Pass ARG verbatim to QEMU (microvm only) |
| `--extra-sandbox-exec-args ARG` | `extraSandboxExecArgs` | string[] | Pass ARG verbatim to `sandbox-exec` (macOS only) |
| `--sandbox-help` | | | Print wrapper path and packaged README path |
| `--sandbox-show-config` | | | Print sandbox command without executing |
| `--sandbox-open-shell` | | | Drop into a shell inside the sandbox |
| `--yolo` | `yolo` | bool | Claude only: `--dangerously-skip-permissions` |
| | `paths` | string[] | Extra rw directories |
| | `homePatterns` | string[] | Relative `$HOME` paths to mount |
| | `xdgRemap` / `noXdgRemap` | bool | Toggle XDG remapping (Linux/microvm only; default off). Also `SANDBOX_XDG_REMAP` env. |
| | `cleanTmp` | bool | Remove sandbox temp dirs on exit |

### Example config (flat)

```json
{
  "paths": ["~/projects/mylib", "/data/datasets"],
  "homePatterns": [".rustup", ".poetry"],
  "mountHomeCache": true,
  "mountCommonHomeFolders": true,
  "gui": false,
  "docker": true,
  "audio": false,
  "nvidia": false,
  "kvm": false,
  "socksProxy": "127.0.0.1:1080",
  "extraEnvs": ["RUST_LOG=debug"],
  "yolo": false
}
```

### Multiple profiles

Config files are flat -- keep one file per profile and pick one with
`--sandbox-config path/to/config.json`. See
[docs/flags.md](./docs/flags.md#config-file-shape) for details.

### Mount groups (config)

The config `"mounts"` key still supports named mount groups for backward compatibility:

- `common-tools`: common local toolchain homes such as `~/.cargo`, `~/.npm`, `~/.yarn`, `~/.go`, `~/.java`, and Nix user profile metadata.
- `caches`: `~/.cache/*` directories for common developer tools such as `pip`, `pnpm`, `npm`, `uv`, `deno`, `bun`, `gradle`, `go`, `gopls`, `huggingface`, `prisma`, and related language/tool caches.

Prefer the CLI flags `--mount-home-cache` and `--mount-common-home-folders` or the config booleans `mountHomeCache` and `mountCommonHomeFolders`.

## Helper Scripts

Each agent installs `<agent>-allow-dir` (allow cwd) and `<agent>-forget-dir` (remove cwd).

## Debugging

```bash
claude --sandbox-show-config    # print bwrap command / seatbelt profile
claude --sandbox-open-shell     # drop into a shell inside the sandbox
claude --sandbox-help           # print wrapper path and packaged README path
```

## Updating Agents

```bash
nix run .#update-all      # all agents
nix run .#update-claude   # single agent
```

`main` takes version bumps through reviewed PRs. The `auto-update` branch is
rebuilt every 12 hours as `main` plus the newest upstream pins, pushed only if
all six agents still build:

```bash
nix run github:eordano/sandboxed-agents/auto-update
```

## Running Tests

NixOS VM tests with a 4-node topology (machine, server, blocked, another):

```bash
nix flake check                                          # all tests
nix build .#checks.x86_64-linux.claude-sandbox-test      # single agent
```

## Recordings

The `Recordings` workflow (manual dispatch) records each agent x backend combination with asciinema and publishes the player site to GitHub Pages. It needs the `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, and `GEMINI_API_KEY` repository secrets; `OPENAI_API_KEY` is optional (codex is skipped without it). The same run works locally: `scripts/record-agents.sh <backend> [outdir]` (needs `asciinema` and `tmux`), then `scripts/build-recordings-site.sh` renders the static site.

## Architecture

Each agent directory: `default.nix` (calls `lib/mk-sandbox.nix`) and `tests/sandbox.nix`, plus where applicable a `*-binary.nix` (version-pinned source), a `config/` dir, and an agent-specific `update.sh` (agents without one are updated by the generic `lib/update.sh`).

Shared library (`lib/`): `mk-sandbox.nix` (builder), `sandbox-{linux,darwin}.nix` (platform wrappers), `shell-blocks.nix` (config parsing, home allow, XDG remap), `data.nix` (constants), `update-lib.sh` (shared update functions), `tests/` (parameterized VM test + mock API server).

`mk-sandbox.nix` generates the wrapper shell script with an `@agent_binary@` placeholder, then `substituteInPlace` rewrites it to the resolved `${agentBinaryDrv}/${agentBinaryRelPath}` at install time. This keeps the wrapper source identical across agents and lets Nix fail the build if the agent derivation path doesn't match.

The unsandboxed binary is available as `<agent>-achtung-achtung` for emergencies. It's a symlink to the underlying agent derivation, installed when the builder is called with `enableEscapeHatch = true` (the default). Agents that shouldn't offer an unsandboxed entry point can set it to `false`.

## macOS (Darwin) Support

All six agents opt in with `supportsDarwin = true` and build under seatbelt. Only `aarch64-darwin` is supported (nixpkgs unstable dropped `x86_64-darwin` in 26.11). On macOS the `<agent>-bwrap` package name is an alias of the seatbelt build, kept so profiles and scripts stay portable across platforms. On `aarch64-darwin`, claude additionally has a microvm variant (no other agent does -- see [docs/microvm.md](./docs/microvm.md#macos-aarch64-darwin-support)). Seatbelt profile: deny-default, allows exec in `/nix`/`/usr/bin`/`/bin`, outbound network, read of system libs/`/etc`/`/dev`, rw to project dir/agent config/caches and an ephemeral per-invocation `TMPDIR` under `/var/folders`. `/tmp` and `/private/tmp` are always writable (required for agent tool calls); `--mount-tmp` and config `mountTmp` are no-ops on macOS and warn. Linux-only flags (e.g. `--allow-gui`, `--allow-kvm`, `--socks-proxy`, `--disable-networking`) print a warning and are ignored.

## Backend Notes

Four backends implementing the same flag surface:

- **gVisor / runsc (Linux)** -- **Default on Linux.** Agent runs as an OCI bundle under [gVisor](https://gvisor.dev), whose user-space Sentry kernel intercepts syscalls and re-issues a small audited subset to the host kernel. Selected as the unsuffixed `<agent>` package. See [docs/runsc.md](./docs/runsc.md).
- **bubblewrap (Linux)** -- direct bind mounts. Selected as `<agent>-bwrap`. See [docs/bubblewrap.md](./docs/bubblewrap.md).
- **microVM (Linux)** -- NixOS guest via [microvm.nix](https://github.com/astro/microvm.nix); host resources shared via virtiofs or socat bridges. Selected as `<agent>-microvm`. See [docs/microvm.md](./docs/microvm.md).
- **microVM (aarch64-darwin, claude only)** -- same NixOS guest built as aarch64-linux via a nix-darwin `linux-builder`, booted under QEMU+HVF. Shares use 9p instead of virtiofs (virtiofsd has no darwin build). See [docs/microvm.md#macos-aarch64-darwin-support](./docs/microvm.md#macos-aarch64-darwin-support).
- **seatbelt (macOS)** -- **Default on macOS** (the only Darwin backend besides claude-only microvm). Allow/deny-listed paths, no filesystem namespace. See [docs/sandbox-exec.md](./docs/sandbox-exec.md).

Per-flag behavior differences across backends are documented in the [flag reference](./docs/flags.md#flag-reference).

## License

MIT
