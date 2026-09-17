# gVisor / runsc backend (Linux)

The default Linux backend wraps the agent in a [gVisor](https://gvisor.dev)
OCI container via `runsc`. gVisor's user-space Sentry kernel intercepts
syscalls and re-issues a small audited subset to the host kernel, narrowing
the attack surface vs. a raw user-namespace sandbox.

Picked as the unsuffixed `<agent>` package because isolation is meaningfully
stronger than bubblewrap at similar startup cost (no VM boot). bubblewrap
remains as `<agent>-bwrap` when Sentry's reduced syscall surface is the
problem; `<agent>-microvm` layers a KVM guest on top -- see
[microvm.md](microvm.md) for the in-guest `--runsc` flag.

The runsc and bwrap backends share `lib/sandbox-linux.nix` and therefore the
same flag surface; this doc covers what's specific to runsc. For precedence,
config shape, and the per-flag matrix, see [flags.md](flags.md).

Wired up in `lib/sandbox-linux.nix` (the `isRunsc` branch builds the OCI
invocation), `lib/runsc-bundle.nix` (Nix-built rootfs + `config.json`
template), and `overlays/default.nix` (selects `runsc` as `defaultBackend`
on Linux, exposes `<agent>` and `<agent>-runsc`).

## OCI bundle

A fresh bundle is materialized per invocation under
`${TMPDIR:-/tmp}/<agent>-runsc-bundle-$$`:

- **`rootfs/`** -- copied from the Nix-built bundle, made writable. Skeleton
  dirs (`/proc`, `/dev`, `/sys`, `/tmp`, `/etc`, `/home`, `/root`, `/var`,
  `/run`, `/nix`, `/usr/{bin,lib}`); symlinks `/bin`, `/sbin`, `/lib` ->
  `/run/current-system/sw/{bin,sbin,lib}`, `/usr/bin/{sh,env}` -> bash /
  coreutils, `/lib64/ld-linux-*` for x86_64 and aarch64.
- **`config.json`** -- built per-invocation by splicing runtime mounts /
  env / args / uid-gid / cwd / platform into
  `${bundle}/config-template.json`.
- **`state/`** -- `runsc --root` directory. The whole bundle is deleted
  on exit by the `_cleanup` trap (`runsc ... delete -force` then `rm -rf`);
  a bundle whose wrapper died by SIGKILL is removed by the next launch's
  `_sweep_stale` (see [Process lifetime](#process-lifetime-and-cleanup)).

### Process / security

The template (`lib/runsc-bundle.nix`) sets:

- `process.user.uid/gid = 0` (rootless -- host uid/gid mapped to 0 via
  `linux.uidMappings`/`gidMappings` written at runtime).
- `process.capabilities` -- all four sets (`bounding`, `effective`,
  `permitted`, `ambient`) **empty**.
- `process.noNewPrivileges = true`.
- `process.rlimits = [{ RLIMIT_NOFILE: 65536/65536 }]`.
- `root.readonly = true` paired with `runsc --overlay2=root:memory` --
  writes go to an in-memory overlay discarded at exit.
- `linux.namespaces` = `pid`, `ipc`, `uts`, `mount`. **No** `network`
  entry -- `--network=host` makes Sentry inherit the wrapper's netns
  (see [Network](#network)).

### Mount layout

The template seeds `/proc`, `/dev` (tmpfs 64M), `/sys` (tmpfs ro), `/etc`
(tmpfs); the wrapper appends per-launch:

- `ALLOWLIST` entries -- `/nix`, `/run/current-system/sw` (ro), `$PWD`,
  `$SANDBOX_HOME -> $HOME`, `$SANDBOX_TMP -> /tmp` (or real `/tmp` with
  `--mount-tmp`), plus `--mount` / `paths` / `homePatterns` / mount-groups
  / `--allow-X` additions. `ro:` and `dev:` prefixes map to
  `["rbind","ro","rprivate"]` and `["rbind","rprivate"]`; `host:guest`
  remaps preserved.
- Staged `/etc` files: `resolv.conf`, `hosts`, `passwd`, `group`,
  `ssh_config` (sanitized -- `Include /nix/store/...` lines stripped, same
  as bwrap) written into `$BUNDLE_DIR/etc-stage/` and bind-mounted ro.
  `passwd`/`group` carry only `root` and the invoking user so name
  lookups resolve.
- NSS / TLS support: `/etc/nsswitch.conf`, `/etc/services`,
  `/etc/protocols`, `/etc/ssl/certs` (or the Nix `cacert` certs dir).

`_dedup_allowlist` runs before bundle assembly and drops entries covered by
a strict ancestor with the same access mode -- overlapping binds
(`$PWD` plus a wider config path) otherwise become two distinct gofer
mounts and trip tools like `git` walking upward to find `.git`.

## Network

`runsc --network=host` makes Sentry inherit whatever netns the wrapper put
us in. Same machinery as bwrap:

- Default -- host network.
- `--socks-proxy` -- wrapper enters `unshare --user --map-root-user --net`,
  brings up `slirp4netns` + `tun2socks`, runs `runsc` inside. See
  [tun2socks.md](tun2socks.md).
- `--no-internet-access` -- same netns, `iptables OUTPUT DROP` with ACCEPT
  for RFC1918 / loopback / link-local / CGNAT.
- `--disable-networking` -- same netns, ACCEPT only for `lo` and resolved
  `--allow-host` IPs.

`--allow-host`, `--socks-proxy`, etc. work transparently because the rules
are already in the netns Sentry inherits.

## runsc invocation

```
runsc --root=$BUNDLE/state --platform=$PLATFORM --network=host \
      --rootless --ignore-cgroups --overlay2=root:memory \
      [--nvproxy] [extraRunscArgs...] \
      run --bundle $BUNDLE $CONTAINER_ID
```

`--rootless` because the wrapper runs as the invoking user, not root.
`--ignore-cgroups` skips the cgroup setup runsc would otherwise require
root for. `--overlay2=root:memory` makes the read-only rootfs writable via
an ephemeral overlay.

## Platform

`SANDBOX_RUNSC_PLATFORM={systrap,ptrace,kvm}` (or `"runscPlatform"` in
config) selects gVisor's syscall-interception platform. Default `systrap`
(uses `SECCOMP_FILTER_RET_TRAP`, fastest in most environments). `ptrace` is
the conservative fallback. `kvm` needs `/dev/kvm` exposed to the user and
has the lowest syscall overhead -- opt-in only.

No CLI flag; set in config or env.

## Environment propagation

Whitelist matches bwrap: `PATH`, `HOME`, `USER`, `LOGNAME`, `MAIL`, `TERM`,
`SHELL`, `LANG`, `TZ`. `SSL_CERT_FILE` / `NIX_SSL_CERT_FILE` /
`CURL_CA_BUNDLE` default to the bundled `cacert`. Per-`--allow-X` forwards
its own extras (`SSH_AUTH_SOCK`, `GPG_AGENT_INFO`/`GPG_TTY`, `DISPLAY`,
`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, `DOCKER_HOST`,
`CUDA_VISIBLE_DEVICES`). `--env KEY=VALUE` and config `extraEnvs` append;
the final map is written verbatim into `process.env`.

## Process lifetime and cleanup

The wrapper does **not** `exec` runsc. It starts
`env --default-signal setpriv --pdeathsig=SIGKILL -- runsc ... run` as a
child, forwards `INT`/`TERM`/`HUP` to it, waits, and exits with the child's
status. Until 2026-09-06 the script ended in `exec runsc`, which replaced
bash and with it the `trap _cleanup EXIT`: the cleanup code was dead on the
default path, and every launch (clean exit or killed) left
`/tmp/<agent>-runsc-bundle-$$` behind (114 on one desktop, on a ZFS root,
not tmpfs). The `-home-$$`/`-tmp-$$` dirs are unrelated: they are kept
unless `cleanTmp` is set, before and after this change. Process orphans
were never the problem: `runsc run` is attached mode, so gVisor sets
`PDEATHSIG=SIGKILL` on the sandbox and the `--rootless` re-exec child, and
killing the `runsc run` pid with TERM or KILL tears down gofer and sandbox
within seconds.

Why the three pieces:

- `setpriv --pdeathsig=SIGKILL` keeps that guarantee now that bash is the
  pid a harness sees: SIGKILL to the wrapper kills runsc, whose own
  pdeathsig kills the sandbox. Nothing polls.
- `env --default-signal` undoes bash's rule that an asynchronous child of a
  non-interactive shell ignores `INT` and `QUIT` (`SIG_IGN` survives
  `exec`), so a terminal `^C` still reaches runsc directly.
- The trap forwards signals that were sent to the wrapper alone
  (`kill <pid>`, a harness stopping one agent). Signals that hit the whole
  process group (terminal, `timeout`, systemd) reach runsc twice, once
  directly and once forwarded; the agents in use treat a repeated
  TERM/INT as idempotent.

`_sweep_stale` runs at every launch after the config is parsed: for each
`${TMPDIR:-/tmp}/<agent>-<backend>-*-<pid>` whose pid no longer exists it
removes the bundle and the coordination files, and the `-home-`/`-tmp-`
dirs only when `cleanTmp` is set (without it those are kept on purpose,
exactly as after a normal exit). This is the only path that covers a
SIGKILLed wrapper, and it needs no timer or tmpfiles rule. Liveness is
`[ -d /proc/<pid> ]`, not `kill -0`, so another user's live pid on a shared
`/tmp` is not classed dead.

What the change buys is bundle cleanup: immediate after a normal exit or a
caught signal, one launch late after SIGKILL (nothing can run a trap then).
Sandbox teardown on SIGKILL was already immediate through gVisor's own
pdeathsig, so it is not orphan prevention. The exit status a caller sees is
unchanged: runsc's own, e.g. 255 after a TERM, measured identical on the
`exec` wrapper and this one.

A leaked `config.json` is the forensic record of a launch: `process.args`,
`process.env`, `process.cwd` and the mount table are exactly what the
harness asked for. That is how the 2026-09-06 Buzz incident was diagnosed
(bundles from the failure window had `process.args` without `acp`).
Bundles that `_sweep_stale` would remove can be preserved by copying them
before the next launch of the same agent.

## Compatibility limits

These come from gVisor's syscall coverage, not this wrapper:

- **`io_uring` is unimplemented** -- Sentry returns `ENOSYS`. Node / Python
  / Go / Rust work; tools that hard-require `io_uring` (some recent FUSE
  filesystems, a few async runtimes) don't.
- **`perf_event_open` is partial** -- most BPF profilers fail; `strace`
  works.
- **File locks are per sandbox** -- `fcntl`/`flock` locks are served from a
  table inside the sentry, never from the host (`Range lock using gofer
  file handled internally` in the debug log). Two sandboxes sharing a file
  lock nothing against each other. SQLite in WAL mode on a shared `$HOME`
  file is the concrete casualty: each new connection truncates the `-shm`
  index as if it were alone, which `SIGBUS`es other sandboxes that have it
  `MAP_SHARED` (opencode's `opencode-stable.db-shm`, 3-5 of 30 concurrent
  `opencode acp` starts on one host), and two writers can both hold the WRITER
  lock. `--file-access-mounts` does not help (caching mode only) and there
  is no per-mount option; use `<agent>-bwrap` or separate data dirs for
  instances that share a lock-protected file.
- **FUSE is partial** -- read-heavy FUSE works; exotic write paths hit
  unimplemented ops.
- **`--allow-nvidia` via `--nvproxy`** (auto-added) -- CUDA on supported
  drivers only; no GL/Vulkan.
- **`--allow-kvm` forwarded** (`/dev/kvm` bind-mounted) but Sentry has no
  nested-virt acceleration -- VM launches inside runsc are slow.

For workloads that hit these limits: `<agent>-bwrap` skips Sentry
entirely (full host syscalls, weaker isolation) and `<agent>-microvm`
gives a real Linux kernel inside QEMU.

## Escape hatch

`--extra-runsc-args ARG` (repeatable) and config `extraRunscArgs` pass
arguments verbatim before the `run` subcommand. For debugging (`--debug`,
`--strace`, `--debug-log=...`) or features the wrapper doesn't surface.
"I know what I'm doing" mode -- flags here can break the sandbox model.
