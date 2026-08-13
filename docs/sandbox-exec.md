# Seatbelt backend (macOS)

The macOS backend uses `sandbox-exec(1)` (Apple's seatbelt) to
confine the agent. seatbelt was picked over alternatives because:

- it's the only user-space, setuid-free isolation primitive that ships
  with macOS by default;
- the TCL-like profile language is declarative and matches our model of
  "deny by default, allow specific paths";
- it doesn't require code signing, entitlements, or kernel extensions.

For precedence rules and per-flag effects, see [flags.md](flags.md).

## The profile

The generated profile starts from `(deny default)` and layers narrow
allows on top:

```
(allow process-exec)     ; run the agent + children
(allow process-fork)
(allow signal (target self))
(allow file-ioctl)
(allow file-read*)       ; /nix/store, /etc, etc. -- agent can read
(allow file-write*
       (subpath "/Users/USER/Projects/foo")   ; per RW_PATHS
       (subpath "/tmp/...sandbox"))
(deny   file-read*
        (subpath "/Users/USER/.ssh")          ; per DENY_PATHS
        (subpath "/Users/USER/.aws")
        ...)
```

Two arrays drive the profile:

- **`RW_PATHS`** / **`RO_PATHS`** -- subpaths the agent can read/write.
  Populated from `--mount`, config `paths`/`homePatterns`, mount groups,
  and per-`--allow-X` handlers. `--allow-ssh` adds `~/.ssh` to
  `RO_PATHS` (lets the agent connect, can't rewrite
  `authorized_keys` / `known_hosts`); `--allow-ssh-write` upgrades to
  `RW_PATHS`. `--allow-gpg` always adds `~/.gnupg` to `RW_PATHS` --
  gpg needs to update its trust/cache database.
- **`DENY_PATHS`** -- hard-coded list of sensitive dirs that are always
  blocked (`~/.aws`, `~/.kube`, `~/.password-store`, ...). `--allow-ssh` /
  `--allow-gpg` / `--allow-docker` etc. **remove** the relevant entry
  from `DENY_PATHS` instead of layering another allow rule, because
  seatbelt's most-specific-match semantics make explicit removal
  cheaper to audit.

## Design decisions

### Why a seatbelt profile instead of a container

macOS has no process namespaces. `nix-shell`-style "jail" options (Docker
Desktop VMs, Virtualization.framework) would add 1-2 GB of overhead and
a second OS to keep in sync. The seatbelt profile is a single process
-- no lifecycle management.

### Linux-only flags silently no-op with a warning

Most `--allow-X` flags that don't make sense on macOS (`--allow-gui`,
`--allow-nvidia`, `--allow-kvm`, `--allow-audio`,
`--allow-home-access`, `--disable-networking`, `--allow-internet-access`,
`--allow-host`, `--socks-proxy`) print a one-line warning and continue.
They parse the `--no-*` counterparts too so CI scripts that set both
positive and negative forms don't error on macOS.

Reason: consistency. Scripts that work on Linux shouldn't fail on macOS
just because a particular toggle is unavailable. The warning is enough
signal that the feature isn't taking effect.

### Homebrew path detection for libvirt

`--allow-libvirt` probes, in order:

1. `/opt/homebrew/var/run/libvirt` (Apple Silicon Homebrew)
2. `/usr/local/var/run/libvirt` (Intel Homebrew)
3. `~/.libvirt`
4. `$(brew --prefix libvirt)/../../var/run/libvirt` if `brew` is present

`$HOME/.config/libvirt` is added read-only so `libvirtd.conf` can be read.
First hit wins; if nothing's there the user gets a hint about
`brew install libvirt`.

### macFUSE check, not bind

`--allow-fuse` doesn't try to mount `/dev/fuse` (seatbelt's default
profile already allows `(subpath "/dev")` rw). It just checks that
macFUSE or Fuse-T is installed and prints a hint if neither is. Makes
the flag a no-op on systems that already have FUSE working.

### Shared parser, selective consumption

The config parser (`configParseBlock` in `lib/shell-blocks.nix`) is
shared with Linux. Some of the values it extracts (`socksProxy`,
`cleanTmp`, `internetAccess`) are unused on macOS. The parser still
records them -- keeping the shared block simple -- and the macOS code
just never reads those variables. Config files written on a Linux host
work unchanged on macOS; unsupported fields are ignored.

For multiple profiles, use one config file per profile and pick with
`--sandbox-config FILE`. The unsupported macOS-only keys (`gui`,
`nvidia`, `kvm`, `audio`, `socksProxy`, `internetAccess: false`,
`disableNetworking`) emit a per-key warning when set.

### `XDG_PATH_FIX=0` on macOS

macOS ships without `XDG_CONFIG_HOME` set, and agents generally live at
`~/.config/claude` or `~/.claude` on this platform without any remap
needed. The `xdgRemaps` logic is turned off at script entry
(`XDG_PATH_FIX=0`) and the config key `"xdgRemap": true` is a silent
no-op on macOS. If anything ever needs the Linux-style XDG->dotfile
mapping on macOS, we'd have to plumb it through the seatbelt profile,
which seatbelt doesn't really support (no bind-mount equivalent).

## Known limits

- **No network isolation.** seatbelt can block `network-outbound` but
  not selectively. Our profile leaves networking fully open; relying on
  seatbelt for per-host filtering is unsupported. If you need that, run
  the agent inside a VM ([microvm](microvm.md)) or use a host-level
  packet filter.
- **No process isolation.** seatbelt restricts file/network/IPC but
  can't prevent the agent from `kill`ing other processes owned by the
  same user. Don't run user-mode pagers or editors while a sandboxed
  agent is active.
- **Profile caching.** seatbelt compiles the profile on each invocation
  (no cache). With large `RW_PATHS` lists we pay a small startup cost
  (~50 ms in practice); don't be alarmed.
