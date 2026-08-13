# Bubblewrap backend (Linux)

The Linux backend uses [bubblewrap](https://github.com/containers/bubblewrap)
to build a user-namespaced sandbox around the agent. bwrap was chosen over
`nsjail`, `firejail`, or hand-rolled namespace code because it:

- ships in nixpkgs with minimal closure;
- has first-class support for bind-mount allow-lists (`--bind`, `--ro-bind`,
  `--dev-bind`) instead of "copy on write everything";
- does user namespaces without setuid, so nothing in the sandbox has host
  root even if the agent escapes the jail;
- has a stable CLI and an audit trail we can print verbatim with
  `--sandbox-show-config`.

For the higher-level rules on how flags/env/config combine, plus the
per-backend flag reference, see [flags.md](flags.md).

## Filesystem strategy

A sandbox run gets two fresh, per-PID directories in `$TMPDIR`:

- `SANDBOX_HOME` -- bind-mounted onto the user's `$HOME` inside the jail.
  The agent can read/write freely here. Host's real `$HOME` is **not**
  visible unless explicitly allowed.
- `SANDBOX_TMP` -- mounted at `/tmp` inside the jail (unless `--mount-tmp`
  was passed, in which case real `/tmp` is shared).

Both are removed on exit when `cleanTmp: true` is set in the config;
otherwise they survive for post-mortem debugging.

Everything else is built up in the `ALLOWLIST` array:

```
  ALLOWLIST+=( "/etc" )                       # plain path -> rw bind
  ALLOWLIST+=( "ro:/run/current-system/sw" )  # "ro:" prefix -> ro bind
  ALLOWLIST+=( "dev:/dev/kvm" )               # "dev:" prefix -> --dev-bind
  ALLOWLIST+=( "$HOST_PATH:$GUEST_PATH" )     # "A:B" -> mount A at B
```

The generator walks the array at the end of the script and emits the
corresponding `--bind`/`--ro-bind`/`--dev-bind` flags to bwrap.

## `--allow-*` contract

Every `--allow-X` flag adds a small, predictable set of paths and env
forwards. Examples:

- `--allow-ssh` binds `~/.ssh` **read-only** by default plus the
  `SSH_AUTH_SOCK` socket and forwards the env var. The read-only
  default lets the agent read host keys and connect over ssh while
  preventing it from rewriting `authorized_keys` / `known_hosts` /
  `config`. `--allow-ssh-write` upgrades the bind to rw for the
  exceptional cases (`ssh-keygen`, `ssh-copy-id`) where the agent
  legitimately needs to write.
- `--allow-gpg` binds `~/.gnupg` rw and the gpg-agent socket (either the
  one `$GPG_AGENT_INFO` points at, or `$XDG_RUNTIME_DIR/gnupg/S.gpg-agent`),
  and forwards `GPG_AGENT_INFO` + `GPG_TTY`.
- `--allow-docker` probes sockets in order (`DOCKER_HOST` if `unix://...`,
  `/var/run`, `/run`, `$XDG_RUNTIME_DIR`, `~/.docker/run`), binds the
  first one found, warns if none match.

The source of truth for each flag's bindings is the `if [ "$ENABLE_X" -eq
1 ]; then ... fi` blocks in `lib/sandbox-linux.nix` -- they're
deliberately flat so it's easy to audit what a flag actually does.

## Design decisions

### `SANDBOX_HOME:$HOME` shadow

The sandbox's `$HOME` is a tempdir on the host, bind-mounted at the
agent's expected `$HOME`. Anything the agent writes to `~` lands in the
tempdir, not the real home. Files the agent needs from the real home
(config, credentials) are layered on top via individual `--bind` entries.

This matters when a hook script runs as the agent user -- it sees what
looks like a clean home without the user's secrets, unless those secrets
were explicitly allowed.

### PWD-shadows-HOME refuses to run

If the user runs the sandbox from inside `$HOME` (e.g. `cd ~ && claude`),
the bind of `$PWD` into the sandbox would cover the `$SANDBOX_HOME:$HOME`
shadow -- effectively exposing the real home. The script refuses with an
explanation and four exits:

1. Run from a project directory (the default fix).
2. Pass `--allow-home-access` to override.
3. Set `"allowHome": true` in config.
4. If `paths` / `homePatterns` already include `$HOME` read-only
   (`ro:.`), the run proceeds silently -- the user already opted in.
   If they include `$HOME` read-write (`.`), the run proceeds with a
   warning that the ephemeral-home isolation is weakened.

This check exists because the mistake is subtle (everything appears to
work) and the failure mode -- agent writes secrets into its own config --
is silent.

### `xdgRemaps` (opt-in)

Each agent can declare a list of `{ from = ".claude"; to =
"$XDG_CONFIG_HOME/claude"; }` pairs. When `xdgRemap` is enabled, the host
path (the XDG one if it exists, the dotfile if not) is bound onto the
guest's `~/.claude`. This keeps agent state in `$XDG_CONFIG_HOME` on the
host while the agent itself still uses the `~/.claude` path it expects.

The default is **off**; enable with `"xdgRemap": true` (or
`"noXdgRemap": false`) in the config, or `SANDBOX_XDG_REMAP=1` for a
single invocation. Both config keys are first-class -- see the
[xdgRemap section in flags.md](flags.md#xdgremap-opt-in) for precedence.

### Environment propagation

Only a hardcoded whitelist is forwarded into the sandbox: `PATH`,
`HOME`, `USER`, `LOGNAME`, `MAIL`, `TERM`, `SHELL`, `LANG`, `TZ`.
Everything else is dropped. Per-`--allow-X` handlers forward their
own extras (`SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, `DISPLAY`,
`WAYLAND_DISPLAY`, `DOCKER_HOST`, ...); `--env KEY=VAL` and config
`extraEnvs` can add more.

`SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, and `CURL_CA_BUNDLE` are set to
the bundled `cacert` path unless already present in the host
environment. Without this fallback, TLS would fail inside the sandbox
whenever the host's `/etc/ssl` isn't in the bind-mount list.

### `/etc/ssh/ssh_config` sanitization

If the host's `ssh_config` has an `Include` line pointing at a
`/nix/store` path (typical on NixOS), the launcher writes a cleaned
copy to the ephemeral tmp dir with those lines stripped, and binds
the sanitized copy at `/etc/ssh/ssh_config`. The included files
usually aren't in the allowlist, so leaving them in produces a warning
on every ssh invocation.

### `internetAccess=false` preflight

When internet access is disabled (`--no-internet-access`,
`internetAccess: false`, or `SANDBOX_INTERNET_ACCESS=0`) and the agent
was built with `apiBaseUrlEnvVars`, the launcher looks for one of those
vars in the `--env` overrides, resolves its hostname, and requires every
resulting IP to be in a private range (RFC1918, loopback, link-local,
CGNAT). The resolver is a small bundled Python script. If no override
is provided, or the override resolves to a non-private address, the agent
won't be able to reach its API -- so the launcher hard-errors. Pass
`--env <VAR>=http://<private-ip>:<port>` to point at a reachable
endpoint, or `--allow-internet-access` to lift the block entirely.

### SOCKS proxy normalization

`--socks-proxy` accepts `HOST:PORT`, `:PORT` (localhost), or a full
`socks5://HOST:PORT` URL; the value is normalized to the URL form.
IPv6 literals in brackets (`[::1]:9050`) are supported -- the launcher
strips the brackets for the namespace routing and validates the host
against `^[a-zA-Z0-9._:-]+$`.

### slirp4netns MTU

The userspace NAT is started with `--mtu=65520`, the maximum the
protocol supports. Large TLS record bursts from the agent otherwise
fragment inside the namespace and add measurable latency. The value
applies only inside the sandbox namespace -- the host's real MTU is
untouched.

### `homePatterns` with `.config/` prefix

`homePatterns` entries starting with `.config/` are resolved against
the host's `$XDG_CONFIG_HOME` (falling back to `$HOME/.config`) and
bound into the sandbox at `$HOME/.config/<rest>`. This lets a single
config entry work whether the user has `XDG_CONFIG_HOME` set or not,
without needing to spell out both paths.

### Network namespace & iptables

- Default: `--share-net` -- the agent gets real internet.
- `--disable-networking`: a user+net namespace is opened and iptables
  drops all non-loopback egress. `--allow-host HOST` adds an ACCEPT for
  the resolved IPs.
- `--no-internet-access` (or `internetAccess: false`): enters the
  net namespace; iptables drops non-private egress but RFC1918,
  loopback, link-local, and CGNAT stay reachable. Lift with
  `--allow-internet-access`.
- `--socks-proxy`: handled by [tun2socks](tun2socks.md).

iptables rules are installed inside the namespace, so they only apply to
the agent's view -- the host's real iptables state is untouched.

### Yolo injection

`--yolo` (claude only today) appends flags to the agent's own argv. The
precedence logic is in [flags.md](flags.md). It's surfaced as a distinct
flag rather than a `--allow-*` because it changes the agent's *internal*
permission model, not the sandbox boundary.

## Known limits

- `--allow-gui` binds the X11/Wayland sockets directly. Any agent that
  can open a window can also screenshot the host desktop.
- `--allow-nvidia` exposes `/dev/nvidia*` as device nodes -- the agent
  gets raw GPU access, not just a framebuffer.
- `--extra-bubblewrap-args` is an escape hatch. Users can pass anything
  bwrap accepts, including flags that break the isolation model. Treat
  it as "I know what I'm doing" mode.
