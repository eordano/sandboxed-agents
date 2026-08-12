# SOCKS proxy on Linux (`--socks-proxy`)

When the user passes `--socks-proxy HOST:PORT` (or sets `"socksProxy":
"..."` in the config), the Linux backend routes all of the agent's public
internet traffic through that SOCKS5 server. Private networks
(RFC1918, loopback, link-local) keep going direct.

This is implemented in [bubblewrap.md](bubblewrap.md)'s network
namespace setup -- macOS ([sandbox-exec.md](sandbox-exec.md)) and microvm
([microvm.md](microvm.md)) both warn "not supported" and ignore the
flag, because neither has a clean seam to inject a userspace router.

## The flow

```
  agent -> tun0 (198.18.0.1/15) -> tun2socks -> SOCKS5 server
                ↓ (for RFC1918 dests)
             tap0 -> slirp4netns -> host network stack
```

Three moving parts:

1. **[slirp4netns]** creates a `tap0` in a fresh net namespace and
   proxies its traffic onto the host via qemu's slirp-style user-mode
   networking.
2. **A `tun0` device** is added with a bogus RFC6598 address
   (`198.18.0.1/15` -- reserved for benchmarking, unlikely to collide
   with anything real on the host) and made the default route.
3. **[tun2socks]** reads packets off `tun0`, wraps them in SOCKS5
   `CONNECT`, and forwards to the user's `$SOCKS_PROXY`.

The net namespace contains: `lo`, `tun0` (default route -> tun2socks),
`tap0` (specific routes for RFC1918 + loopback + link-local, so
internal traffic doesn't go through the proxy).

[slirp4netns]: https://github.com/rootless-containers/slirp4netns
[tun2socks]: https://github.com/xjasonlyu/tun2socks

## Why this combination

We picked this particular stack because it's the only one that:

- **needs no setuid binary** -- slirp4netns runs in the user's own net
  namespace, tun2socks is pure userspace, bwrap handles the namespace
  plumbing;
- **doesn't require the SOCKS proxy to know about RFC1918** -- the
  routing decision happens *before* tun2socks sees the packet, so
  private-network traffic is never sent to the proxy even
  accidentally;
- **works with any SOCKS5 server** -- no special proxy features needed
  (no HTTP CONNECT, no transparent mode).

Alternatives considered:

- **`HTTPS_PROXY` env var** -- Only works for programs that honor the
  env. Agents shell out to `curl`, `npm`, `pip`, `git` which all read
  it *differently*; auditing coverage is a game of whack-a-mole.
- **redsocks / 3proxy** -- Needs iptables `REDIRECT` inside the
  namespace, which means NAT tables, which means more code to get
  right when we only want TCP to go out.
- **`torsocks`-style LD_PRELOAD** -- Doesn't catch `connect(2)` from
  statically linked binaries (Go) and fails on non-glibc agents.

## Key detail: no egress gate by default

`--socks-proxy` is a routing decision, not a permission decision. The
agent can still reach RFC1918 hosts directly. If you want the agent
strictly limited to the SOCKS endpoint and RFC1918-internal hosts, pair
with `--disable-networking` + `--allow-host` for each external host
you want to allow through the proxy.

## Interaction with `--disable-networking` and `--no-internet-access`

- `--socks-proxy` alone: routes via proxy, no iptables filtering.
- `--socks-proxy` + `--no-internet-access` (or `internetAccess: false`): proxy is the only path
  to non-private addresses, and iptables additionally drops any packet
  that's not RFC1918/loopback or destined to an `--allow-host`
  entry's IP. Belt and suspenders.
- `--socks-proxy` + `--disable-networking`: iptables drops everything
  non-loopback. The SOCKS proxy is unreachable -- this configuration
  doesn't really make sense and we don't special-case it.

## Known limits

- **TCP only.** tun2socks implements SOCKS5 CONNECT for TCP and
  fake-UDP-over-SOCKS for UDP. The fake-UDP path has been flaky in
  practice (DNS lookups randomly timeout); we rely on the agent's
  DNS resolver going through TCP or falling back to the namespace's
  slirp4netns resolver for RFC1918 hosts.
- **No IPv6.** The `198.18.0.0/15` trick is v4-only. IPv6 traffic
  either drops (if the agent tries v6 first) or falls through to
  slirp's v4 NAT. In practice agents that default to v6 sometimes
  appear to hang for a few seconds while v6 times out and they
  retry v4 via the proxy.
- **No DNS-over-proxy.** DNS queries use the namespace's resolver
  (whatever slirp4netns hands out), not the SOCKS proxy's upstream
  DNS. If the user's SOCKS proxy is intended to anonymize DNS
  lookups, this leaks. Point the agent at a remote DNS-over-HTTPS
  resolver or use a proxy that rewrites DNS.
- **Latency.** Every TCP connection pays a full SOCKS5 handshake on
  top of the namespace boundary. Expected; measured ~10 ms overhead
  per connection vs direct.
