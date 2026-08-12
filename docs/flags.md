# Flags, config keys, env vars

Every sandbox backend exposes the same surface: a set of `--allow-X` /
`--mount-X` / `--disable-X` boolean toggles, a few value-bearing flags
(`--mount PATH`, `--env KEY=VAL`, `--socks-proxy HOST:PORT`,
`--sandbox-config FILE`), plus the
`--sandbox-show-config` / `--sandbox-open-shell` / `--sandbox-help`
introspection flags.

This doc explains the rules that tie CLI flags, environment variables, and
config files together, then lists every flag with its per-backend effect.
For the deeper implementation of each backend, see [runsc.md](runsc.md),
[bubblewrap.md](bubblewrap.md), [sandbox-exec.md](sandbox-exec.md), and
[microvm.md](microvm.md).

## Precedence

For **every** boolean toggle, the effective value is resolved in this order,
highest priority first:

```
  CLI flag   ->   env var   ->   config key   ->   build-time default
```

`--allow-ssh` on the command line always wins over `SANDBOX_ALLOW_SSH=0` in
the environment, which always wins over `"ssh": true` in the config file.
If none of them say anything, the default kicks in.

Every positive flag has a matching negative. `--allow-ssh` turns the toggle
on; `--no-allow-ssh` (and its shorter alias `--no-ssh`) turns it off. The
negative form exists specifically so that a user can override a config or
env that enabled the feature.

### How it's implemented

Two helpers in `lib/shell-blocks.nix` do the work:

- **`_cfg_tristate KEY`** -- reads the config file once and prints `"1"`,
  `"0"`, or `""` (empty if the key is absent). Unlike the older
  `_cfg_bool`, it distinguishes "unset" from "false", which is what
  precedence needs.

- **`_resolve_bool OUT_VAR CLI_VAR ENV_VAR CFG_KEY [DEFAULT]`** -- walks
  the four sources in reverse order (default -> config -> env -> CLI), each
  step overwriting the previous only if it has an opinion.

Each backend's CLI parser stashes `--allow-X` into a tristate `CLI_ENABLE_X`
variable (`""` / `"0"` / `"1"`) instead of mutating `ENABLE_X` directly.
After the config file is read, one `_resolve_bool` call per toggle
collapses the three levels into the final `ENABLE_X`.

## Config file shape

Config files are **flat JSON**. The `lib/shell-blocks.nix` parser reads
one file at a time -- there's no in-file profile selection. For multiple
profiles, write multiple files and pick one with `--sandbox-config FILE`.

`cleanTmp` is read with `_cfg_bool` and has no CLI counterpart -- either
set in config or not. `internetAccess` is a tri-state bool resolved via
`_resolve_bool` (default `true` = allow): CLI `--allow-internet-access`
(-> true) and `--no-internet-access` (-> false), env
`SANDBOX_INTERNET_ACCESS`, config key `internetAccess`.

## Repeatable flags have no env var override

`--allow-host`, `--mount`, `--env`, and the backend escape-hatch flags
(`--extra-bubblewrap-args`, `--extra-runsc-args`, `--extra-qemu-args`,
`--extra-sandbox-exec-args`) take values and can be passed multiple
times. They intentionally have **no** `SANDBOX_*` environment variable,
because there's no clean way to pass a list through a single env var
(`:` and newline separators are both ugly in practice and we didn't
want users writing scripts that parse them).

Use the config file instead: `paths`, `homePatterns`, `extraEnvs`,
`mounts`, `extraBubblewrapArgs`, `extraRunscArgs`, `extraQemuArgs`, and
`extraSandboxExecArgs` are the persistent equivalents. CLI args are
appended to whatever the config set.

## The yolo exception

`--yolo` (currently only claude) appends
`--allow-dangerously-skip-permissions --dangerously-skip-permissions` to
the agent's own argv. It follows the same precedence as every other
toggle: `SANDBOX_YOLO={0,1,true,false,yes,no,on,off}` env > config
`"yolo": true` > default `false`. `--yolo` / `--no-yolo` on the CLI wins
over both.

One extra twist: yolo is suppressed for known agent subcommands
(`doctor`, `auth`, `install`, `mcp`, `agents`) because those paths don't
benefit from permission-skip and some reject the flag outright.

## xdgRemap (opt-in)

The XDG remap is off by default. When enabled, each agent's `xdgRemaps`
list (e.g. `.claude -> $XDG_CONFIG_HOME/claude`) gets applied on launch:
agent state lives under `$XDG_CONFIG_HOME` on the host while the agent
itself continues to use its native `~/.claude` path inside the sandbox.

Turn it on for a profile with a config file that sets
`"xdgRemap": true` and pass that file via `--sandbox-config FILE`, or
flip the env var for a single invocation. Spin up multiple config
files to keep parallel, isolated state locations.

Resolution follows the usual precedence. Both keys are supported on
equal footing so a user can bake a default into one file and flip it
from another layer:

- Config: `"xdgRemap": true | false` or `"noXdgRemap": true | false`
  (inverted). Both keys are first-class -- implemented as two
  `_cfg_tristate` lookups in `lib/sandbox-linux.nix` and
  `lib/microvm-launcher.nix` -- so whichever appears later in the
  precedence chain wins. A shared config can set one direction; a
  second `--sandbox-config FILE` (or the env var) can flip it without
  editing the original.
- Env: `SANDBOX_XDG_REMAP={0,1,true,false,yes,no,on,off}` wins over
  both config keys.
- Default: off.

There is no CLI flag; per-invocation overrides happen via
`--sandbox-config FILE` or the env var. macOS sets `XDG_PATH_FIX=0`
unconditionally -- seatbelt has no bind-mount equivalent, so the
keys are accepted but ignored.

## Config file lookup

The wrapper resolves the config path in this order, first hit wins:

1. `--sandbox-config FILE` (CLI)
2. `$SANDBOX_CONFIG_FILE` (env)
3. the nearest `<agent>-sandbox.json` walking up from the current working directory to `/`
4. `${XDG_CONFIG_HOME:-$HOME/.config}/<agent>-sandbox.json`

The CLI flag and env var write to the same variable, so the CLI takes
effect because it's assigned after the env is inherited. The cwd
fallback only fires when neither is set, so a per-project sandbox
profile (committed alongside the repo) is overridable without editing
or moving the file. Useful when wrapping the wrapper -- a parent
script can export `SANDBOX_CONFIG_FILE` and not have to thread an
argv.

## Mount groups

Two named groups can appear in config `mounts` or be toggled via the
matching `--mount-*` flag. Entries expand against `$HOME` (or
`$HOME/.cache` for `caches`) and silently skip paths that don't
exist.

- **`caches`** (`--mount-home-cache`) -- `~/.cache/` subdirs for
  common dev tools: `black`, `bun`, `cached-nix-shell`, `deno`,
  `fish`, `fontconfig`, `go`, `gopls`, `gradle`, `huggingface`,
  `jedi`, `lua-language-server`, `nix`, `nix-hug`, `npm`, `opencode`,
  `pip`, `pnpm`, `prisma`, `prisma-nodejs`, `puppeteer`, `pylint`,
  `staticcheck`, `tokenizer`, `typescript`, `uv`, `whisper`, `yarn`,
  `zig`.
- **`common-tools`** (`--mount-common-home-folders`) -- `~/.cargo`,
  `~/.config/nix`, `~/.go`, `~/.java`, `~/.nix-channels`,
  `~/.nix-defexpr`, `~/.nix-profile`, `~/.npm`, `~/.yarn`.

The canonical lists live in `lib/data.nix`; edit there to change what
either group pulls in.

## Known limits

- **No env var for `--socks-proxy` value on macOS/microvm** -- those
  backends don't support SOCKS routing, so `SANDBOX_SOCKS_PROXY` is a
  Linux-only passthrough.
- **`SANDBOX_ALLOW_HOST` doesn't exist** -- `--allow-host` is repeatable.
  If we ever add a comma-separated variant, it would live alongside.
- **Env-var parser is permissive** -- `1|true|yes|on` and
  `0|false|no|off` are accepted for all toggles; anything else is a
  silent no-op (falls through to config). We may want to warn on
  unknown values in a future pass.

## Flag reference

Every single-value boolean toggle below follows the precedence described
above (CLI > env > config > default) and has a matching `--no-...`
counterpart. Repeatable flags (`--allow-host`, `--mount`, `--env`, and
the backend escape-hatch flags `--extra-bubblewrap-args`,
`--extra-runsc-args`, `--extra-qemu-args`,
`--extra-sandbox-exec-args`) have no env-var override -- use the config
keys instead.

Support column: **y** = wired, **n** = warn and ignore, **p** = partial,
**x** = no-op (accepted for parity, does nothing).

Columns: **R** = standalone runsc (gVisor) backend on Linux --
`<agent>` / `<agent>-runsc` packages. **L** = bubblewrap backend on
Linux -- `<agent>-bwrap` package. **M** = seatbelt backend on macOS.
**V** = microvm backend (Linux host plus aarch64-darwin claude-only
variant). The runsc and bwrap backends share a wrapper
(`lib/sandbox-linux.nix`) so the per-flag effect is usually identical;
the matrix calls out the few cases where it isn't. Darwin microvm
diverges in two places: `--runsc` (the in-guest gVisor flag) is **n**
(no nested KVM under HVF) and `--allow-nvidia` is **n** (no vfio-pci
on darwin). See [microvm.md](microvm.md#macos-aarch64-darwin-support).

### Credentials & agent forwarding

| Flag | Config | Env | R | L | M | V |
|---|---|---|:-:|:-:|:-:|:-:|
| `--allow-ssh` | `ssh` | `SANDBOX_ALLOW_SSH` | y | y | y | y |
| `--allow-ssh-write` | `sshWrite` | `SANDBOX_ALLOW_SSH_WRITE` | y | y | y | y |
| `--allow-gpg` | `gpg` | `SANDBOX_ALLOW_GPG` | y | y | y | y |
| `--allow-git` | `git` | `SANDBOX_ALLOW_GIT` | y | y | y | y |

- **`--allow-ssh`** -- read-only by default. Linux binds `~/.ssh`
  (ro/rw) plus `SSH_AUTH_SOCK` and forwards the env. macOS adds
  `~/.ssh` to RO/RW paths and drops the deny entry. microvm
  virtiofs-shares `~/.ssh` ro and socat-bridges `SSH_AUTH_SOCK` to
  `/run/ssh-auth.sock`.
- **`--allow-ssh-write`** -- upgrades `--allow-ssh` to rw (Linux drops
  `ro:`, macOS moves RO->RW, microvm drops virtiofsd `--readonly`).
- **`--allow-gpg`** -- Linux binds `~/.gnupg` rw + gpg-agent socket
  (probes `gpgconf --list-dirs`, `$XDG_RUNTIME_DIR/gnupg/S.gpg-agent`,
  `$HOME/.gnupg/S.gpg-agent`), forwards `GPG_AGENT_INFO`/`GPG_TTY`.
  macOS adds `~/.gnupg` to RW. microvm virtiofs-shares `~/.gnupg` rw
  + socat-bridges to `/run/gpg-agent.sock`.
- **`--allow-git`** -- Linux binds `~/.gitconfig` and
  `~/.git-credentials` rw. macOS: `~/.gitconfig` ro,
  `~/.git-credentials` rw. microvm stages the files through
  `/run/env/staged` (virtiofs can't share single files).

### Host resources

| Flag | Config | Env | R | L | M | V |
|---|---|---|:-:|:-:|:-:|:-:|
| `--allow-docker` | `docker` | `SANDBOX_ALLOW_DOCKER` | y | y | y | y |
| `--allow-fuse` | `fuse` | `SANDBOX_ALLOW_FUSE` | p | y | p | x |
| `--allow-gui` | `gui` | `SANDBOX_ALLOW_GUI` | y | y | n | n |
| `--allow-nvidia` | `nvidia` | `SANDBOX_ALLOW_NVIDIA` | p | y | n | y |
| `--allow-kvm` | `kvm` | `SANDBOX_ALLOW_KVM` | p | y | n | n |
| `--allow-audio` | `audio` | `SANDBOX_ALLOW_AUDIO` | y | y | n | n |
| `--allow-libvirt` | `libvirt` | `SANDBOX_ALLOW_LIBVIRT` | y | y | y | y |

The runsc column reads slightly different from bwrap because Sentry
intercepts syscalls: `--allow-fuse` is partial (read-heavy FUSE
works, write paths through exotic daemons hit unimplemented ops);
`--allow-nvidia` adds `--nvproxy` to the runsc invocation, which
covers CUDA on supported drivers but not GL/Vulkan; `--allow-kvm`
binds `/dev/kvm` but Sentry has no nested-virt acceleration so VM
launches inside runsc will be slow. See
[runsc.md](runsc.md#compatibility-limits).

- **`--allow-docker`** -- auto-detects the socket: `DOCKER_HOST` if
  `unix://...` -> `/var/run` -> `/run` -> `$XDG_RUNTIME_DIR` ->
  `~/.docker/run`; warns if none. Linux binds it and forwards
  `DOCKER_HOST`; macOS adds to RW; microvm runs a socat TCP bridge,
  guest sees `DOCKER_HOST=tcp://$GUEST_HOST_IP:$PORT`.
- **`--allow-fuse`** -- Linux mounts `/dev/fuse` and `/run/user/$UID`.
  macOS checks for macFUSE/Fuse-T and prints a hint if missing.
  microvm accepts for compat (FUSE is always available in the VM).
- **`--allow-gui`** -- Linux binds X11/Wayland sockets,
  `$XDG_RUNTIME_DIR/bus`, `/dev/dri`, fonts, icons, GTK/Qt config,
  pulse/pipewire; forwards `DISPLAY`, `WAYLAND_DISPLAY`,
  `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_SESSION_TYPE`,
  `QT_QPA_PLATFORM`. macOS/microvm warn (microvm: ssh in for X
  forwarding).
- **`--allow-nvidia`** -- Linux mounts `/dev/nvidia*` +
  `/run/opengl-driver` ro, sets `LD_LIBRARY_PATH`, forwards
  `CUDA_VISIBLE_DEVICES`. microvm finds the GPU by PCI vendor
  `0x10de`, requires `vfio-pci`, passes through with
  `-device vfio-pci,host=$BDF`. macOS warns.
- **`--allow-kvm`** -- Linux binds `/dev/kvm` and `/dev/vfio`. macOS
  and microvm warn (nested KVM unsupported).
- **`--allow-audio`** -- Linux mounts pulse/pipewire sockets,
  `/dev/snd`, `$XDG_RUNTIME_DIR/bus`. macOS/microvm warn.
- **`--allow-libvirt`** -- Linux binds the unix socket from
  `/var/run/libvirt`, `/run/libvirt`, or `$XDG_RUNTIME_DIR/libvirt`.
  macOS adds Homebrew dirs (`/opt/homebrew`, `/usr/local`,
  `$(brew --prefix)`) plus `~/.libvirt` rw / `~/.config/libvirt` ro;
  forwards `LIBVIRT_DEFAULT_URI`. microvm: socat TCP bridge, guest
  re-bridges to `/run/libvirt-sock`,
  `LIBVIRT_DEFAULT_URI=qemu+unix:///system?socket=/run/libvirt-sock`.

### Sandbox perimeter

| Flag | Config | Env | R | L | M | V |
|---|---|---|:-:|:-:|:-:|:-:|
| `--allow-home-access` | `allowHome` | `SANDBOX_ALLOW_HOME` | y | y | n | n |
| `--allow-internet-access` / `--no-internet-access` | `internetAccess` | `SANDBOX_INTERNET_ACCESS` | y | y | n | y |
| `--allow-host HOST` | -- | -- | y | y | n | y |
| `--disable-networking` | `disableNetworking` | `SANDBOX_DISABLE_NETWORKING` | y | y | n | y |
| `--socks-proxy HOST:PORT` | `socksProxy` | `SANDBOX_SOCKS_PROXY` | y | y | n | n |
| `--runsc` | `runsc` | `SANDBOX_RUNSC` | n | n | n | y |

- **`--allow-home-access`** -- Linux disables the "PWD shadows HOME"
  abort. macOS/microvm warn.
- **`--allow-internet-access` / `--no-internet-access`** -- tri-state
  (default allow). `--no-internet-access` blocks non-private egress
  while leaving RFC1918 / loopback / link-local reachable. Linux
  enters a net namespace and applies iptables; microvm writes
  `/run/env/.no-internet-access` for the guest to apply identical
  rules. macOS warns.
- **`--allow-host HOST`** -- repeatable, no env. Linux resolves the
  host, builds a custom `/etc/hosts`, adds IPs as iptables ACCEPT.
  microvm writes `/run/env/.allowed-hosts`; guest mirrors the rules.
  macOS warns.
- **`--disable-networking`** -- forces `INTERNET_ACCESS=0` and drops
  non-localhost egress (ACCEPT lo + `--allow-host` IPs). microvm
  writes `/run/env/.disable-networking` for the guest. macOS warns.
- **`--socks-proxy`** -- Linux only: user+net namespace with
  slirp4netns + tun2socks (see [tun2socks.md](tun2socks.md));
  accepts `HOST:PORT`, `:PORT`, `socks5://HOST:PORT`, IPv6 literals
  (`[::1]:9050`).
- **`--runsc`** -- **microvm only.** Swaps `agent-run.service` for
  `agent-run-runsc.service`, which wraps the agent in a gVisor
  container *inside* the guest. See
  [microvm.md](microvm.md#optional-runsc-gvisor-inside-the-guest).
  Standalone runsc already runs gVisor on the host, so the flag is
  redundant there -- bwrap/runsc/macOS warn-and-ignore.

### Mounts, env, and config

| Flag | Config | Env | R | L | M | V |
|---|---|---|:-:|:-:|:-:|:-:|
| `--backend BACKEND` | `backend` | `SANDBOX_BACKEND` | y | y | y | y |
| `--sandbox-config FILE` | -- | `SANDBOX_CONFIG_FILE` | y | y | y | y |
| `--mount PATH` | `paths` / `homePatterns` | -- | y | y | y | p |
| `--mount-home-cache` | `mountHomeCache` | `SANDBOX_MOUNT_HOME_CACHE` | y | y | y | y |
| `--mount-common-home-folders` | `mountCommonHomeFolders` | `SANDBOX_MOUNT_COMMON_HOME` | y | y | y | y |
| `--mount-tmp` | `mountTmp` | `SANDBOX_MOUNT_TMP` | y | y | x | y |
| `--env KEY=VAL` | `extraEnvs` (array) | -- | y | y | y | y |
| `--extra-bubblewrap-args` | `extraBubblewrapArgs` | -- | n | y | n | n |
| `--extra-runsc-args` | `extraRunscArgs` | -- | y | n | n | n |
| `--extra-qemu-args` | `extraQemuArgs` | -- | n | n | n | y |
| `--extra-sandbox-exec-args` | `extraSandboxExecArgs` | -- | n | n | y | n |

- **`--backend BACKEND`** -- accepted by all four wrappers. Resolved
  before any other parsing: CLI > `SANDBOX_BACKEND` env > `.backend`
  in the resolved config file > the wrapper's own backend. If the
  target differs, `exec`s `<agent>-{sandbox,runsc,microvm}` (where
  `bwrap` maps to the `-sandbox` symlink) from PATH; errors with exit
  2 if that variant isn't installed. The flag is consumed by the
  dispatcher and never reaches the agent. `--` stops dispatch parsing,
  so `agent -- --backend foo` passes `--backend foo` to the agent.
- **`--sandbox-config FILE`** -- overrides the default lookup
  (CLI > `SANDBOX_CONFIG_FILE` env > nearest `<agent>-sandbox.json`
  up from the cwd > `$XDG_CONFIG_HOME/<agent>-sandbox.json`). Multi-profile =
  multiple files picked via this flag.
- **`--mount PATH`** -- repeatable. Linux uses bwrap bind syntax
  (`PATH`, `ro:PATH`, `HOST:GUEST`). macOS: `PATH` -> RW_PATHS,
  `ro:PATH` -> RO_PATHS, no remap. microvm: directories are virtiofs
  shares (`ro:` supported); single files are staged -- copied into the
  guest at boot, writes don't propagate back. No `HOST:GUEST`.
- **`--mount-home-cache`** / **`--mount-common-home-folders`** -- bind
  the `~/.cache/*` and toolchain-home lists from `lib/data.nix`.
  Linux bind-mounts; macOS adds to RW; microvm shares each as a
  virtiofs mount.
- **`--mount-tmp`** -- Linux mounts real `/tmp` instead of the
  per-invocation tmpfs. microvm shares `/tmp` via virtiofs. macOS
  no-op: `/tmp` and `/private/tmp` are always writable, so the flag,
  env var, and config key are accepted for parity but emit a warning
  if explicitly set.
- **`--env KEY=VAL`** -- repeatable. Linux: `bwrap --setenv`. macOS:
  prepended to `env(1)`. microvm: appended to `/run/env/.env` which
  the guest sources. Config `extraEnvs` is an array of `"KEY=VAL"`.
- **`--extra-bubblewrap-args` / `--extra-runsc-args` /
  `--extra-qemu-args` / `--extra-sandbox-exec-args`** -- passed
  verbatim to the named backend's binary; config-array equivalents
  apply first, then CLI args. Each is honored by exactly one backend
  (bwrap / runsc / microvm-qemu / macOS-seatbelt); the others warn
  and ignore.

### Introspection

| Flag | Env | R | L | M | V |
|---|---|:-:|:-:|:-:|:-:|
| `--sandbox-show-config` | `DRY_RUN` | y | y | y | y |
| `--sandbox-open-shell` | `START_SHELL` | y | y | y | y |
| `--sandbox-help` | -- | y | y | y | y |

- **`--sandbox-show-config`** -- dry-run. bwrap echoes the `bwrap`
  invocation; runsc echoes the `runsc` command plus a pretty-printed
  `config.json`; macOS prints the seatbelt profile + `env` command;
  microvm prints the mount plan, staged files, and env file. `DRY_RUN`
  presets it on Linux/macOS.
- **`--sandbox-open-shell`** -- drops into `$SHELL` instead of the
  agent. `START_SHELL` presets on Linux/macOS; microvm writes `shell`
  to `/run/env/.mode`.
- **`--sandbox-help`** -- per-backend help text.

### Agent-level

| Flag | Config | Env | R | L | M | V |
|---|---|---|:-:|:-:|:-:|:-:|
| `--yolo` | `yolo` | `SANDBOX_YOLO` | y | y | y | y |

See [The yolo exception](#the-yolo-exception) above. Opt-in per agent at
build time via `enableYolo` (currently claude only). Identical logic
across all three backends.

### Config-only keys

| Key | R | L | M | V |
|---|:-:|:-:|:-:|:-:|
| `paths` | y | y | y | y |
| `homePatterns` | y | y | y | y |
| `mounts` | y | y | y | y |
| `cleanTmp` | y | y | x | x |
| `xdgRemap` / `noXdgRemap` | y | y | x | y |
| `runscPlatform` | y | n | n | y |

- **`paths`** -- absolute paths to bind/allow. Linux/macOS go through
  the shared `configParseBlock`; microvm directories become virtiofs
  mounts and files are auto-staged via `/run/env/staged`.
- **`homePatterns`** -- `$HOME`-relative; same handling as `paths`.
  Linux entries starting with `.config/` resolve against
  `$XDG_CONFIG_HOME` (fallback `$HOME/.config`).
- **`mounts`** -- `["caches"]` / `["common-tools"]` mount-group
  selector -- equivalent to the `--mount-*` flags.
- **`cleanTmp`** -- Linux removes `SANDBOX_HOME` / `SANDBOX_TMP` on
  exit. macOS no-op; microvm always cleans up VM tmp.
- **`xdgRemap`** / **`noXdgRemap`** -- see
  [xdgRemap](#xdgremap-opt-in).
- **`runscPlatform`** -- `systrap` (default) | `ptrace` | `kvm`.
  Honored by the standalone runsc backend and microvm `--runsc`;
  ignored elsewhere. Env: `SANDBOX_RUNSC_PLATFORM`.
