# MicroVM backend

The microvm backend runs the agent inside a qemu KVM guest built from a
NixOS module. Process isolation, filesystem isolation, and (optionally)
network isolation are kernel-level rather than namespace-level. Used
when you want "nothing the agent does can affect the host" and you
don't mind a 5-10s boot and ~2 GB of RAM per instance.

Bubblewrap's user namespaces are good enough for 95% of cases; microvm
exists for the other 5% where an unfortunate kernel bug or a determined
local-root escape would still leave a bubblewrap agent able to touch
the host.

For the flag matrix and precedence rules, see [flags.md](flags.md).

## Components

- **`lib/mk-microvm-sandbox.nix`** -- derivation that builds the NixOS
  guest (via `lib.nixosSystem` + [microvm.nix](https://github.com/astro/microvm.nix))
  and wraps it in a launcher script.
- **`lib/microvm-guest.nix`** -- NixOS module defining the guest system:
  packages, systemd services, users, firewall rules.
- **`lib/microvm-launcher.nix`** -- the host-side script that boots the
  VM, sets up virtiofs shares, opens socat bridges, and waits for the
  agent to exit.

## Filesystem: virtiofs + file staging

The guest shares three categories of host data:

1. **The Nix store** (`/nix/store`, read-only). Mandatory -- the guest's
   own binary closure is served from the host store.
2. **An env share** (`/run/env`, read-only). Manifest files that tell
   the guest what to mount, which services to start, the user's UID,
   the workdir, the agent's argv, etc. See [The /run/env share](#the-runenv-share)
   below.
3. **User content**: current directory (`$PWD`), config `paths`,
   `homePatterns`, `--mount` entries, per-`--allow-X` dirs
   (`~/.ssh`, `~/.gnupg`, `~/.cache/*`, `~/.cargo`, ...), and xdgRemap
   source paths.

All three use **virtiofs** (vhost-user-fs-pci), spawned via
`virtiofsd`. virtiofs supports passthrough of POSIX modes, symlinks,
and ACLs; it's the same mechanism Kata Containers use. Passed as
**read-only** (via `--readonly` on the virtiofsd side) when the host
side passes `"ro:$path"` (e.g. `--allow-ssh` without `-write`).

### Why not 9p?

9p is available in qemu and works without a separate daemon, but it
mishandles symlinks and hard-links and caches stat results aggressively.
Agents writing Git objects trip the link counter discrepancy, which
shows up as silent data corruption. virtiofs doesn't have this class of
bug and the daemon overhead is acceptable.

### File staging (because virtiofs can't share files)

virtiofs can only share **directories**. `--allow-git` needs to expose
`~/.gitconfig` and `~/.git-credentials`, which are files. Config
`paths` entries might also be files.

The launcher handles this with a staging directory at
`$MOUNT_BASE/env/staged/`. For each file to share, it copies the file to
a unique ID (`f0`, `f1`, ...), records a manifest line:

```
<id>\t<guest-dest>\t<octal-mode>
```

...and the guest's `sandbox-setup.service` reads the manifest and copies
each file into place at boot, preserving mode. Special case: dest
`HOMEREL:<rel>` is rewritten to `$REAL_HOME/<rel>` so xdgRemap file
remaps land in the right place.

This is a one-way copy at boot. Writes inside the guest do not flow
back to the host file. This is intentional -- most of the files staged
are credentials, and we don't want the agent rewriting them.

## The `/run/env` share

The launcher writes a handful of small files under `$MOUNT_BASE/env`
(virtiofs-mounted at `/run/env` in the guest, read-only). Every file is
optional unless noted; the guest's `sandbox-setup.service` and the bridge
services use `ConditionPathExists` to skip work when a file is absent.

**Identity & invocation**

| File | Format | Purpose |
|---|---|---|
| `.user` | one line | Real username on the host (used for `useradd` mapping). |
| `.home` | one line | Real `$HOME` path; the guest creates `agent`'s home at the same path so embedded paths in configs stay valid. |
| `.workdir` | one line | Host `$PWD`; the guest `cd`s here before exec. |
| `.mode` | `agent` or `shell` | Selects `agent-run.service` vs an interactive shell on `ttyS0`. |
| `.args` | NUL-separated | Agent argv (preserves spaces and shell metacharacters). |
| `.env` | `KEY=VALUE` lines, mode 600 | Sourced with `set -a; . /run/env/.env; set +a`. Values are `printf '%q'`-quoted so spaces, quotes, etc. round-trip. |

**Mounts & staging**

| File | Format | Purpose |
|---|---|---|
| `.mounts` | `<tag>:[ro:]<host_path>` per line | virtiofs share manifest. `ro:` prefix -> read-only mount. |
| `.staged-manifest` | `<id>\t<dest>\t<octal-mode>` per line | One row per staged file. `staged/<id>` holds the copy; the guest copies it to `<dest>` at boot, preserving mode. `<dest>` may be `HOMEREL:<rel>`, which the guest rewrites to `$REAL_HOME/<rel>` (used by xdgRemap file remaps). |
| `.xdg-home-mounts` | `<tag>\|<from>\|<host_path>` per line | xdgRemap directory entries; the guest bind-mounts the matching virtiofs share onto `$REAL_HOME/<from>`. |
| `.nix-profile-target` | one line, `/nix/store/HASH-user-environment` | The launcher resolves `~/.nix-profile` (or `/etc/profiles/per-user/$USER`) to its store path; the guest creates a matching symlink at `$HOME/.nix-profile` so `~/.nix-profile/bin` resolves through the read-only `/nix/store` share. |

**Network policy**

| File | Presence triggers |
|---|---|
| `.no-internet-access` | iptables drops everything except RFC1918 / loopback / link-local + `--allow-host` IPs. |
| `.disable-networking` | iptables drops everything non-loopback (overrides `.no-internet-access`). |
| `.allowed-hosts` | one hostname per line; resolved at boot, IPs added to the iptables ACCEPT list. |

**Bridge ports** (one per enabled flag, free TCP ports on `127.0.0.1`)

| File | Service that consumes it |
|---|---|
| `.ssh-auth-port` | `ssh-auth-bridge.service` -> `socat UNIX-LISTEN:/run/ssh-auth.sock TCP:10.0.2.2:$PORT` |
| `.gpg-agent-port` | `gpg-agent-bridge.service` -> `socat UNIX-LISTEN:/run/gpg-agent.sock TCP:10.0.2.2:$PORT` |
| `.libvirt-port` | `libvirt-bridge.service` -> `socat UNIX-LISTEN:/run/libvirt-sock TCP:10.0.2.2:$PORT` |
| `.nvidia` | Marker (`1`); `agent-run` adds NVIDIA env to PATH/LD_LIBRARY_PATH when present. |

The guest never writes back to `/run/env` -- the share is mounted
read-only on purpose, so nothing the agent does inside the VM can
mutate the launcher's view of what was set up.

## Network: qemu slirp + socat bridges

The guest gets a single `user`-type interface. qemu's slirp sets up a
virtual `10.0.2.0/24` subnet where the host appears at `10.0.2.2`.
This address is **inside the guest's view only**; it doesn't exist on
the host's network and can't collide with real networks there.

slirp handles outbound NAT transparently. For host-side services the
agent needs to reach (ssh-agent, gpg-agent, docker, libvirt), the
launcher opens a socat TCP bridge:

```
Host:  socat TCP-LISTEN:PORT,bind=127.0.0.1 UNIX-CONNECT:$HOST_SOCK
Guest: socat UNIX-LISTEN:/run/X.sock TCP:10.0.2.2:PORT
```

Bridge ports are picked at launch time as `(RANDOM % 10000) + 40000`
(i.e. `40000`-`49999`) per bridge. No registered port collides with
this range and `reuseaddr,fork` lets the listener tolerate a transient
conflict if two launches race; we have not needed retry-on-bind in
practice.

**Multi-user caveat:** the host-side listeners are plain,
unauthenticated TCP sockets on `127.0.0.1` -- any local user or process
on the host can connect to them for as long as the VM runs. On a
multi-user host, `--allow-ssh`, `--allow-gpg`, `--allow-docker`, or
`--allow-libvirt` exposes the corresponding agent/daemon to every
local account, not just to the guest.

The guest-side socat is driven by a systemd service
(`ssh-auth-bridge`, `gpg-agent-bridge`, `libvirt-bridge`). Each unit's
`ConditionPathExists` on the matching port file under `/run/env/` means
it only starts when the launcher set up that particular bridge.

`--allow-docker` is the exception -- the launcher writes
`DOCKER_HOST=tcp://10.0.2.2:<port>` into `/run/env/.env` and lets the
agent's docker client speak TCP directly. Clients that hardcode
`/var/run/docker.sock` won't work; clients that honor `DOCKER_HOST` do.

## systemd service graph

```
   sandbox-setup.service    (oneshot: mounts .mounts shares, runs file
                             staging from .staged-manifest, applies xdg
                             binds from .xdg-home-mounts, links nix-profile
                             from .nix-profile-target)
        ↓
   network-lockdown.service (oneshot: reads .allowed-hosts, applies
                             iptables rules for .no-internet-access /
                             .disable-networking)
        ↓
   ssh-auth-bridge          (socat, if /run/env/.ssh-auth-port)
   gpg-agent-bridge         (socat, if /run/env/.gpg-agent-port)
   libvirt-bridge           (socat, if /run/env/.libvirt-port)
        ↓
   agent-run.service        (oneshot: exec the agent binary as `agent` user)
        ↓
   agent-shutdown.service   (poweroff after agent-run exits)
```

`agent-run` is `Type = oneshot` + `User = agent` + `StandardInput =
tty`, attached to `/dev/ttyS0`. This gives the agent a real terminal
(not a pty slave) on qemu's first serial port, which is what the
launcher connects to when you `nix run .#claude-microvm`.

`agent-run`'s PATH is built explicitly:
`$HOME/.local/bin` (silences claude's "not in PATH" warning),
`$HOME/.nix-profile/bin` (when `.nix-profile-target` was written),
`/run/current-system/sw/bin`, `/run/wrappers/bin`, `/sbin`, `/bin`.

## xdgRemaps

Each agent's `default.nix` declares
`xdgRemaps = [{ from = ".claude"; to = "$XDG_CONFIG_HOME/claude"; }
...]`. For the microvm backend, these are applied in two phases:

1. **Host**: the launcher's `_xdg_remap` function resolves each `to`
   (expanding `$XDG_CONFIG_HOME` etc.), adds the directory as a
   virtiofs share with a synthetic tag (`xdgremap-0`, `xdgremap-1`,
   ...), and writes `<tag>|<from>|<host_path>` to
   `/run/env/.xdg-home-mounts`. File-type remaps go through file
   staging with `HOMEREL:` dest prefix.
2. **Guest**: `sandbox-setup.service` reads `.xdg-home-mounts` and
   `mount --bind`s the virtiofs mount point onto `$REAL_HOME/<from>`.

This mirrors the Linux backend's [xdgRemap](bubblewrap.md#xdgremaps-opt-in)
semantics, including the opt-in default.

## Design decisions

### Why microvm-nix over raw qemu + initramfs

microvm-nix composes the NixOS module we already write for the agent
with the microvm interfaces into a bootable qemu command. We'd
otherwise maintain our own kernel + initramfs + cloud-init-style
config generator. Not worth it.

### `mountBase` lives at `/tmp/microvm-<agent>` with a flock

Only one instance per agent at a time. The lock file (`MOUNT_BASE.lock`)
is guarded by `flock -n`; a stale holder's PID is detected via
`kill -0` and the lock is reclaimed. Multiple *different* agents can
run side by side (they use different `mountBase` dirs).

### virtiofsd startup is polled, not assumed

Every extra `--mount` spawns its own `virtiofsd` alongside the main
share. The launcher polls the per-share unix socket for up to 50 x
0.1 s before handing qemu the runtime args. If the socket never shows
up *and* the daemon has already exited, the launcher prints a warning,
strips that device's `-chardev`/`-device` pair from the qemu argv (via
`sed`) and removes the line from `/run/env/.mounts` so the guest's
`sandbox-setup.service` doesn't try to mount a tag that was never
attached. The agent boots without that share rather than hanging on
an absent device.

### Cleanup order matters

`_cleanup()` kills socat bridges first (so they don't log spurious
connection errors when virtiofsd goes away), then virtiofsd, then
deletes `$MOUNT_BASE/env` + `$RUN_DIR`, then releases the flock. The
order is deliberate -- reversing it races virtiofsd's unix-socket close
against the env share removal and produces noise in dmesg.

## Optional: runsc (gVisor) inside the guest

`--runsc` (env `SANDBOX_RUNSC=1`, config `"runsc": true`) wraps the agent
in a gVisor container **inside** the microvm guest, layering Sentry on
top of the VM boundary. An escape now requires a Sentry bug **and** a
guest-kernel bug against Sentry's reduced surface **and** a QEMU/KVM bug
-- three distinct boundaries.

Independent of the standalone `<agent>-runsc` package
([runsc.md](runsc.md)), which runs gVisor on the host with no VM. The
flag here is microvm-only; bwrap and runsc backends warn-and-ignore it.

### How it fits into the guest

The launcher drops `/run/env/.use-runsc` into the env share when
`--runsc` is set, plus `/run/env/.runsc-platform` if overridden. Two
systemd units gate on `ConditionPathExists`; exactly one runs:

- **`agent-run.service`** (`!/run/env/.use-runsc`) -- direct path. Execs
  the agent as user `agent` on `/dev/ttyS0`.
- **`agent-run-runsc.service`** (`/run/env/.use-runsc`) -- runsc path.
  Runs as root, generates the OCI bundle at `/run/runsc-bundle`, and
  `exec`s `runsc run`. Agent ends up as `uid:gid = agent:agent` via the
  bundle's `process.user`.

`agent-shutdown.service` triggers `After=` both, so poweroff is
identical either way.

### OCI bundle (in-guest)

Generated fresh each boot under `/run/runsc-bundle/`:

- **`rootfs`** -- recursive bind of the guest's `/`, re-mounted `rslave`
  so runsc's container-internal mounts don't propagate out.
- **`config.json`** -- `jq` splices runtime bits
  (`process.user.uid/gid`, `cwd`, `args`, `env`, `hostname`) into a
  fixed template.

Template highlights:

- Mounts: `/proc`, `/dev`, `/dev/pts`, `/dev/shm`, `/sys`, `/tmp`
  (managed by runsc).
- Capabilities: only `CAP_NET_BIND_SERVICE` in bounding/effective/
  permitted. Everything else dropped.
- `RLIMIT_NOFILE` soft/hard = 1,048,576.
- Namespaces: `pid`, `ipc`, `uts`, `mount`. No `network` --
  `--network=host` inherits the guest netns and
  `network-lockdown.service`'s firewall rules.

### Container env

Assembled in three layers: (1) defaults `HOME`, `USER`, `LOGNAME`,
`PATH`, `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, `CURL_CA_BUNDLE`,
`WORKDIR`; (2) agent-baked `extraEnvVars` (same values
`agent-run.service` exports on the direct path); (3) every
`KEY=VALUE` from `/run/env/.env`, sourced via
`env -i bash -c '. .env; env -0'` and collected into `process.env`.

### Platform

`SANDBOX_RUNSC_PLATFORM={systrap,ptrace,kvm}` or `"runscPlatform"`.
Default `systrap`. `kvm` needs nested KVM (`kvm-intel nested=1` on the
host plus vmx/svm exposed to the guest) -- opt-in only.

### Known limits (in-guest runsc)

Same syscall-coverage caveats as standalone runsc -- see
[runsc.md#compatibility-limits](runsc.md#compatibility-limits) for
`io_uring` / `perf_event_open` / FUSE / nvidia / kvm behavior. Two
microvm-specific extras:

- **`--platform=kvm` not default.** Nested KVM requires host setup; if
  you've done it, opt in with the env or config key above.
- **`--allow-nvidia` with runsc is triple-nested** (host passthrough ->
  guest `/dev/nvidia*` -> Sentry nvproxy). Untested; turn `--runsc` off
  if you need GPU.
- **Guest image is ~40 MB larger** for the `gvisor` derivation. It's
  always included so the flag is a pure runtime toggle.

## Known limits

- **GPU passthrough requires vfio-pci** (`--allow-nvidia`). The NVIDIA
  GPU must be bound to `vfio-pci` on the host before the VM starts.
  This typically means a driver swap at boot; not ergonomic for
  desktop systems. Future work: support `virtio-gpu-pci` as a
  lightweight shared GPU for non-compute use cases.
- **No GUI/audio forwarding.** The guest has no display server socket.
  `--allow-gui` / `--allow-audio` print a warning and ignore. To get
  output out of a microvm agent, `ssh` into it from the host and use
  X/Wayland forwarding.
- **No nested KVM.** `--allow-kvm` inside a microvm is ignored -- a
  VM-inside-a-VM is disabled on most host kernels and slow where it's
  enabled.
- **File staging is one-way.** Files staged at boot are copies; the
  agent can't update `~/.gitconfig` on the host. Good for secrets,
  surprising for `git config --global`.
- **VM boot latency** is ~5-10 s on first run (cold virtiofsd),
  ~3-5 s on warm. Acceptable for interactive use, annoying for scripts
  that spin up and tear down many VMs.

## macOS (aarch64-darwin) support

Available on `aarch64-darwin` for the `claude` agent only as of this
pass. Other agents still fall through to `bwrap` (which on darwin is a
no-op with a warning -- effectively run-without-sandbox). Motivated by
Playwright/Chromium not running under macOS seatbelt; the microvm
gives Chromium a real Linux kernel to sandbox against.

### Prerequisite

A working nix-darwin `linux-builder` for `aarch64-linux`. The guest
NixOS system is built as `aarch64-linux` and routed to the builder via
Nix's remote-builder mechanism. Verify:

```
cat /etc/nix/machines | grep aarch64-linux
```

Without a builder, `nix build .#claude-microvm` fails with a "no
suitable builder" error. Enable via `nix.linux-builder.enable = true;`
in nix-darwin.

### Divergences from the Linux microvm path

| Aspect | Linux host | darwin host |
|---|---|---|
| Hypervisor accel | `-accel kvm -cpu host` | `-accel hvf -cpu max` |
| Fixed shares (`/nix/store`, `/run/env`) | virtiofs (vhost-user-fs) | 9p (virtio-9p, `version=9p2000.L`) |
| Extra `--mount` shares | virtiofs via `virtiofsd` | 9p via qemu `-virtfs` |
| runsc | supported | warn-and-ignore (no nested KVM under HVF) |
| NVIDIA passthrough | `--allow-nvidia` + vfio-pci | warn-and-ignore |

The accel rewrite is a `sed` pass on microvm.nix's generated runner
script (`lib/microvm-launcher.nix` -- matches both `-accel kvm` and
`accel=kvm` in `-machine`). The 9p fallback is driven by a
`useVirtiofs` flag threaded through `mk-microvm-sandbox.nix`,
`microvm-guest.nix`, and `microvm-launcher.nix`; the guest module
switches `share.proto` accordingly and `sandbox-setup` reads
`SANDBOX_FS_TYPE` to pick the `mount` flags.

### Why 9p and not virtiofs

`virtiofsd` has no darwin build in nixpkgs -- the rust-vmm project
dropped macOS support upstream. Options ranked by effort: 9p today,
packaging a darwin virtiofsd later, or rewriting the launcher on
Apple's Virtualization.framework via `vfkit` (cleanest, largest).
9p wins the MVP because it ships now and covers the motivating
workload.

### 9p limitations to know about

- **Hard-link counts are wrong** after cross-link operations -- git's
  pack-object writes hit this. `git clone`ing a large repo *into* a
  shared directory can corrupt pack files. Clone inside the VM's
  ephemeral `$HOME` or use `--mount` on a single-file disk image for
  git-heavy work.
- **Stat cache is aggressive**. File watchers with sub-second
  granularity may miss updates for ~1-2 s.
- **Symlinks to absolute paths outside the share** don't resolve
  inside the guest -- the target must live inside another share.
- **Unaffected** by the above: Playwright/Chromium, `npm install` +
  `node_modules`, Python venvs, most read-workloads, anything under
  `/nix/store` (which is read-only 9p on darwin but readonly-heavy so
  the caching is an advantage).

### Known issue: linux-builder store propagation

If a disabled-unit or other tiny NixOS-internal path was substituted
into the darwin store from `cache.nixos.org` but never propagated to
the builder's store, the build fails with:

```
error: getting attributes of path '/nix/store/...-service-disabled': No such file or directory
```

Workaround from a non-sandboxed shell (nix-daemon needs builder SSH
access, which most agent sandboxes block):

```
nix copy --to 'ssh-ng://builder@linux-builder?ssh-key=/etc/nix/builder_ed25519' \
  /nix/store/<missing-path>
```

Or force a full rebuild on the builder by clearing the old profile
generation that pinned the stale closure.
