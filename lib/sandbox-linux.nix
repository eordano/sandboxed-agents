{
  backend ? "bwrap",
  writeShellScript,
  writeText,
  bubblewrap ? null,
  gvisor ? null,
  jq ? null,
  bundle ? null,
  tun2socks,
  slirp4netns,
  iproute2,
  iptables,
  util-linux,
  python3,
  cacert,
  agentName,
  configFileName,
  homeAllowBlock,
  mountGroupBlock,
  configParseBlock,
  yoloInjectionBlock ? "",
  sandboxInitLines,
  extraEnvLines,
  configDeployLines,
  extraHomeDirCreateBlock,
  xdgRemapBlock ? "",
  enableYolo ? false,
  apiBaseUrlEnvVars ? [ ],
  mkBackendDispatch,
}:

assert builtins.elem backend [
  "bwrap"
  "runsc"
];
assert backend != "bwrap" || bubblewrap != null;
assert backend != "runsc" || (gvisor != null && jq != null && bundle != null);

let
  isRunsc = backend == "runsc";
  suffix = if isRunsc then "runsc" else "sandbox";
  scriptName = "${agentName}-${suffix}";

  nsScriptTemplate = writeText "${agentName}-${suffix}-ns-script" ''
    #!/usr/bin/env bash
    rm -f @NS_SCRIPT@
    read < @COORD_FIFO@
    rm -f @COORD_FIFO@

    ${iproute2}/bin/ip link set dev lo up

    if [ -n "@SOCKS_PROXY@" ]; then
      ${iproute2}/bin/ip tuntap add mode tun dev tun0
      ${iproute2}/bin/ip addr add 198.18.0.1/15 dev tun0
      ${iproute2}/bin/ip link set dev tun0 up

      ${iproute2}/bin/ip route add @PROXY_HOST@ via 10.0.2.2 dev tap0 2>/dev/null || true
      ${iproute2}/bin/ip route replace 10.0.0.0/8 via 10.0.2.2 dev tap0 2>/dev/null || true
      ${iproute2}/bin/ip route replace 172.16.0.0/12 via 10.0.2.2 dev tap0 2>/dev/null || true
      ${iproute2}/bin/ip route replace 192.168.0.0/16 via 10.0.2.2 dev tap0 2>/dev/null || true
      ${iproute2}/bin/ip route replace 100.64.0.0/10 via 10.0.2.2 dev tap0 2>/dev/null || true
      ${iproute2}/bin/ip route replace 127.0.0.0/8 dev lo 2>/dev/null || true
      ${iproute2}/bin/ip route replace 169.254.0.0/16 via 10.0.2.2 dev tap0 2>/dev/null || true
      ${iproute2}/bin/ip route replace default dev tun0

      ${tun2socks}/bin/tun2socks -device tun0 -proxy "@SOCKS_PROXY@" > /dev/null 2>&1 &
      TUN2SOCKS_PID=$!
      trap "kill $TUN2SOCKS_PID 2>/dev/null" EXIT
    fi

    _fw() {
      local cmd="$1"; shift
      local nets="$1"; shift
      command -v "$cmd" >/dev/null 2>&1 || return 0
      "$cmd" -P OUTPUT DROP
      "$cmd" -A OUTPUT -o lo -j ACCEPT
      for _n in $nets; do "$cmd" -A OUTPUT -d "$_n" -j ACCEPT 2>/dev/null || true; done
      for _ip in @HOST_IPS@; do "$cmd" -A OUTPUT -d "$_ip" -j ACCEPT 2>/dev/null || true; done
    }
    if [ @DISABLE_NETWORKING@ -eq 1 ]; then
      _fw ${iptables}/bin/iptables  ""
      _fw ${iptables}/bin/ip6tables ""
    elif [ @INTERNET_ACCESS@ -eq 0 ]; then
      _fw ${iptables}/bin/iptables  "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16"
      _fw ${iptables}/bin/ip6tables "::1/128 fc00::/7 fe80::/10"
    fi

    . @CMD_FILE@
  '';

  helpIntroLine =
    if isRunsc then
      "  Sandbox flags (runsc / gVisor). Every --allow-X / --mount-X / --disable-X has a"
    else
      "  Sandbox flags (bubblewrap). Every --allow-X / --mount-X / --disable-X has a";

  helpGuiLine =
    if isRunsc then
      "    --allow-gui              Mount X11/Wayland, DRI, fonts, themes                env SANDBOX_ALLOW_GUI"
    else
      "    --allow-gui              Mount X11/Wayland, DRI, fonts, themes, audio         env SANDBOX_ALLOW_GUI";

  helpNvidiaLine =
    if isRunsc then
      "    --allow-nvidia           Mount NVIDIA devices; launch with --nvproxy          env SANDBOX_ALLOW_NVIDIA"
    else
      "    --allow-nvidia           Mount NVIDIA devices and OpenGL driver               env SANDBOX_ALLOW_NVIDIA";

  helpLibvirtLine =
    if isRunsc then
      "    --allow-libvirt          Mount libvirt socket                                 env SANDBOX_ALLOW_LIBVIRT"
    else
      "    --allow-libvirt          Mount libvirt sockets                                env SANDBOX_ALLOW_LIBVIRT";

  helpMountLine =
    if isRunsc then
      "    --mount PATH             Bind-mount PATH (ro:/path or /host:/guest)           (repeatable)"
    else
      "    --mount PATH             Bind-mount PATH (ro:/path or /host:/guest)           (repeatable -- no env var)";

  helpEnvLine =
    if isRunsc then
      "    --env KEY=VALUE          Pass env var into sandbox (repeatable)"
    else
      "    --env KEY=VALUE          Pass env var into sandbox (repeatable -- no env var override)";

  helpExtraArgsLine =
    if isRunsc then
      "    --extra-runsc-args ARG   Pass ARG verbatim to runsc (repeatable -- escape hatch)"
    else
      "    --extra-bubblewrap-args ARG  Pass ARG verbatim to bwrap (repeatable -- escape hatch)";

  helpShowConfigLine =
    if isRunsc then
      "    --sandbox-show-config    Print runsc command without executing                env DRY_RUN"
    else
      "    --sandbox-show-config    Print sandbox command without executing              env DRY_RUN";

  extraArgsVarName = if isRunsc then "EXTRA_RUNSC_ARGS" else "EXTRA_BWRAP_ARGS";

  extraArgsCase =
    if isRunsc then
      ''
        --extra-runsc-args) EXTRA_RUNSC_ARGS+=("$2"); shift 2 || _reqval "$1" ;;
        --extra-runsc-args=*) EXTRA_RUNSC_ARGS+=("''${1#*=}"); shift ;;
        --extra-bubblewrap-args|--extra-qemu-args|--extra-sandbox-exec-args)
          echo "Warning: $1 is not supported by the runsc backend; use --extra-runsc-args." >&2
          shift 2 || _reqval "$1" ;;
        --extra-bubblewrap-args=*|--extra-qemu-args=*|--extra-sandbox-exec-args=*)
          echo "Warning: ''${1%%=*} is not supported by the runsc backend; use --extra-runsc-args." >&2
          shift ;;
      ''
    else
      ''
        --extra-bubblewrap-args) EXTRA_BWRAP_ARGS+=("$2"); shift 2 || _reqval "$1" ;;
        --extra-bubblewrap-args=*) EXTRA_BWRAP_ARGS+=("''${1#*=}"); shift ;;
        --extra-runsc-args|--extra-qemu-args|--extra-sandbox-exec-args)
          echo "Warning: $1 is not supported by the bwrap backend; use --extra-bubblewrap-args." >&2
          shift 2 || _reqval "$1" ;;
        --extra-runsc-args=*|--extra-qemu-args=*|--extra-sandbox-exec-args=*)
          echo "Warning: ''${1%%=*} is not supported by the bwrap backend; use --extra-bubblewrap-args." >&2
          shift ;;
      '';

  bundleSetup =
    if isRunsc then
      ''
        BUNDLE_DIR="''${TMPDIR:-/tmp}/${agentName}-runsc-bundle-$$"
        CONTAINER_ID="${agentName}-$$"
        mkdir -p "$BUNDLE_DIR/state"
      ''
    else
      "";

  cleanupExtra =
    if isRunsc then
      ''
        ${gvisor}/bin/runsc --root="$BUNDLE_DIR/state" delete -force "$CONTAINER_ID" >/dev/null 2>&1 || true
        rm -rf "$BUNDLE_DIR"
      ''
    else
      "";

  rootfsCopy =
    if isRunsc then
      ''
        cp -a ${bundle}/rootfs "$BUNDLE_DIR/rootfs"
        chmod -R u+w "$BUNDLE_DIR/rootfs"
      ''
    else
      "";

  allowlistExtraStatic = if isRunsc then "" else ''"ro:/etc"'';

  etcPrepare =
    if isRunsc then
      ''
        ETC_STAGE="$BUNDLE_DIR/etc-stage"
        mkdir -p "$ETC_STAGE"

        if [ "$DISABLE_NETWORKING" -eq 1 ]; then
          printf 'nameserver 1.1.1.1\n' > "$ETC_STAGE/resolv.conf"
        elif [ -f /etc/resolv.conf ]; then
          cp -L /etc/resolv.conf "$ETC_STAGE/resolv.conf" 2>/dev/null || \
            printf 'nameserver 1.1.1.1\n' > "$ETC_STAGE/resolv.conf"
        fi

        if [ -f /etc/hosts ]; then
          cp -L /etc/hosts "$ETC_STAGE/hosts"
          chmod u+w "$ETC_STAGE/hosts"
        else
          printf '127.0.0.1 localhost\n::1 localhost\n' > "$ETC_STAGE/hosts"
        fi
      ''
    else
      ''
        CLEAN_SSH_CONFIG=""
        if [ -f /etc/ssh/ssh_config ]; then
          CLEAN_SSH_CONFIG="$SANDBOX_TMP/ssh_config"
          sed '/^[[:space:]]*Include.*\/nix\/store/d' /etc/ssh/ssh_config > "$CLEAN_SSH_CONFIG"
        fi
      '';

  hostsResolve =
    if isRunsc then
      ''
        _RESOLVED_HOST_IPS=()
        for _host in "''${ALLOWED_HOSTS[@]}"; do
          while IFS= read -r _line; do
            _ip="''${_line%% *}"
            [ -n "$_ip" ] && _RESOLVED_HOST_IPS+=("$_ip")
            [ -n "$_line" ] && echo "$_line" >> "$ETC_STAGE/hosts"
          done < <(${python3}/bin/python3 -c "
        import socket, sys
        host = sys.argv[1]
        try:
            results = socket.getaddrinfo(host, None)
            seen = set()
            for r in results:
                ip = r[4][0]
                if ip not in seen:
                    seen.add(ip)
                    print(ip + ' ' + host)
        except Exception:
            print(host + ' ' + host)
        " "$_host" 2>/dev/null)
        done
      ''
    else
      ''
        _RESOLVED_HOST_IPS=()
        CUSTOM_HOSTS=""
        if [ ''${#ALLOWED_HOSTS[@]} -gt 0 ]; then
          CUSTOM_HOSTS="$SANDBOX_TMP/hosts"
          if [ -f /etc/hosts ]; then
            cp /etc/hosts "$CUSTOM_HOSTS"
            chmod u+w "$CUSTOM_HOSTS"
          else
            printf '127.0.0.1 localhost\n::1 localhost\n' > "$CUSTOM_HOSTS"
          fi
          echo "" >> "$CUSTOM_HOSTS"
        fi
        for _host in "''${ALLOWED_HOSTS[@]}"; do
          while IFS= read -r _line; do
            _ip="''${_line%% *}"
            [ -n "$_ip" ] && _RESOLVED_HOST_IPS+=("$_ip")
            [ -n "$_line" ] && echo "$_line" >> "$CUSTOM_HOSTS"
          done < <(${python3}/bin/python3 -c '
        import socket, sys
        host = sys.argv[1]
        try:
          seen = set()
          for r in socket.getaddrinfo(host, None):
            ip = r[4][0]
            if ip not in seen:
              seen.add(ip)
              print(ip + " " + host)
        except Exception:
          print(host + " " + host)
        ' "$_host")
        done
      '';

  runscEtcExtras =
    if isRunsc then
      ''
        _UID=$(id -u)
        _GID=$(id -g)
        cat > "$ETC_STAGE/passwd" <<EOF
        root:x:0:0:root:/root:/bin/sh
        $USER:x:$_UID:$_GID:$USER:$HOME:/bin/sh
        EOF
        cat > "$ETC_STAGE/group" <<EOF
        root:x:0:
        $USER:x:$_GID:
        EOF

        if [ -f /etc/ssh/ssh_config ]; then
          sed '/^[[:space:]]*Include.*\/nix\/store/d' /etc/ssh/ssh_config > "$ETC_STAGE/ssh_config"
        fi
      ''
    else
      "";

  buildRunCmd =
    if isRunsc then
      ''
        MOUNT_OBJECTS=()
        _add_mount() {
          local src="$1" dst="$2" mode="$3"
          [ -e "$src" ] || return 0
          local opts
          if [ "$mode" = "ro" ]; then
            opts='["rbind","ro","rprivate"]'
          else
            opts='["rbind","rprivate"]'
          fi
          MOUNT_OBJECTS+=("$(${jq}/bin/jq -nc --arg src "$src" --arg dst "$dst" --argjson opts "$opts" \
            '{destination:$dst,type:"bind",source:$src,options:$opts}')")
        }

        for p in "''${ALLOWLIST[@]}"; do
          if [[ "$p" == ro:* ]]; then
            x="''${p#ro:}"; _add_mount "$x" "$x" ro
          elif [[ "$p" == dev:* ]]; then
            x="''${p#dev:}"; _add_mount "$x" "$x" rw
          elif [[ "$p" == *:* ]]; then
            src="''${p%%:*}"; dst="''${p#*:}"; _add_mount "$src" "$dst" rw
          else
            _add_mount "$p" "$p" rw
          fi
        done

        for _f in resolv.conf hosts passwd group ssh_config; do
          if [ -e "$ETC_STAGE/$_f" ]; then
            if [ "$_f" = "ssh_config" ]; then
              _add_mount "$ETC_STAGE/$_f" "/etc/ssh/ssh_config" ro
            else
              _add_mount "$ETC_STAGE/$_f" "/etc/$_f" ro
            fi
          fi
        done

        for _f in nsswitch.conf services protocols; do
          [ -f "/etc/$_f" ] && _add_mount "/etc/$_f" "/etc/$_f" ro
        done

        if [ -d /etc/ssl/certs ]; then
          _add_mount "/etc/ssl/certs" "/etc/ssl/certs" ro
        else
          _add_mount "${cacert}/etc/ssl/certs" "/etc/ssl/certs" ro
        fi

        ENV_ARR="[]"
        for k in "''${!ENV_MAP[@]}"; do
          ENV_ARR=$(${jq}/bin/jq -nc --argjson cur "$ENV_ARR" --arg kv "$k=''${ENV_MAP[$k]}" \
            '$cur + [$kv]')
        done

        if [ -n "$START_SHELL" ]; then
          _target=$(readlink -f "$(which "$SHELL")" 2>/dev/null || which "$SHELL")
          ARGS_JSON=$(${jq}/bin/jq -nc --arg t "$_target" '[$t]')
        else
          ARGS_JSON=$(${jq}/bin/jq -nc --arg t "@agent_binary@" --args '[$t] + $ARGS.positional' -- "''${AGENT_ARGS[@]}")
        fi

        MOUNTS_JSON=$(printf '%s\n' "''${MOUNT_OBJECTS[@]}" | ${jq}/bin/jq -cs '.')

        UID_MAP=$(${jq}/bin/jq -nc --argjson h $_UID \
          '[{hostID:$h, containerID:0, size:1}]')
        GID_MAP=$(${jq}/bin/jq -nc --argjson h $_GID \
          '[{hostID:$h, containerID:0, size:1}]')

        TERMINAL="true"
        [ -t 0 ] && [ -t 1 ] || TERMINAL="false"

        ${jq}/bin/jq \
          --argjson mounts "$MOUNTS_JSON" \
          --argjson env "$ENV_ARR" \
          --argjson args "$ARGS_JSON" \
          --argjson uidmap "$UID_MAP" \
          --argjson gidmap "$GID_MAP" \
          --arg cwd "$PWD" \
          --arg platform "$RUNSC_PLATFORM" \
          --argjson terminal "$TERMINAL" \
          '.mounts += $mounts
           | .process.env = $env
           | .process.args = $args
           | .process.cwd = $cwd
           | .process.terminal = $terminal
           | .linux.uidMappings = $uidmap
           | .linux.gidMappings = $gidmap
           | .annotations["dev.gvisor.internal.platform"] = $platform' \
          ${bundle}/config-template.json > "$BUNDLE_DIR/config.json"

        RUNSC_ARGS=(
          --root="$BUNDLE_DIR/state"
          --platform="$RUNSC_PLATFORM"
          --network=host
          --rootless
          --ignore-cgroups
          --overlay2=root:memory
          --host-uds=open
        )
        if [ "$ENABLE_NVIDIA" -eq 1 ]; then
          RUNSC_ARGS+=( --nvproxy )
        fi
        if [ ''${#_CFG_EXTRA_RUNSC_ARGS[@]} -gt 0 ]; then
          RUNSC_ARGS+=( "''${_CFG_EXTRA_RUNSC_ARGS[@]}" )
        fi
        RUNSC_ARGS+=( "''${EXTRA_RUNSC_ARGS[@]}" )

        RUN_CMD=( ${gvisor}/bin/runsc "''${RUNSC_ARGS[@]}" run --bundle "$BUNDLE_DIR" "$CONTAINER_ID" )
      ''
    else
      ''
        args=(
          --die-with-parent
          --ro-bind /nix /nix
        )

        if [ -n "$SOCKS_PROXY" ] || [ "$INTERNET_ACCESS" -eq 0 ] || [ "$DISABLE_NETWORKING" -eq 1 ]; then
          args+=( --ro-bind /proc /proc --dev /dev --unshare-pid --unshare-ipc --unshare-uts )
        else
          args+=( --proc /proc --dev /dev --unshare-all --share-net )
        fi

        env_args=()
        for _k in "''${!ENV_MAP[@]}"; do
          env_args+=( --setenv "$_k" "''${ENV_MAP[$_k]}" )
        done

        args+=(
          --tmpfs /usr
          --dir /usr/bin
          --clearenv
          "''${env_args[@]}"
        )

        for p in "''${ALLOWLIST[@]}"; do
          if [[ "$p" == ro:* ]]; then
            p="''${p#ro:}"
            [ -e "$p" ] && args+=( --ro-bind "$p" "$p" )
          elif [[ "$p" == dev:* ]]; then
            p="''${p#dev:}"
            [ -e "$p" ] && args+=( --dev-bind "$p" "$p" )
          elif [[ "$p" == *:* ]]; then
            src="''${p%%:*}"
            dst="''${p#*:}"
            [ -e "$src" ] && args+=( --bind "$src" "$dst" )
          else
            [ -e "$p" ] && args+=( --bind "$p" "$p" )
          fi
        done

        if [ -f "$CLEAN_SSH_CONFIG" ] && [ -f /etc/ssh/ssh_config ] && [ ! -L /etc/ssh/ssh_config ]; then
          args+=( --ro-bind "$CLEAN_SSH_CONFIG" /etc/ssh/ssh_config )
        fi

        if [ -n "$CUSTOM_HOSTS" ] && [ -f "$CUSTOM_HOSTS" ]; then
          _hosts_dest=/etc/hosts
          if [ -L /etc/hosts ]; then
            _resolved=$(readlink -f /etc/hosts 2>/dev/null || true)
            if [ -n "$_resolved" ] && [ -f "$_resolved" ]; then
              _hosts_dest="$_resolved"
            fi
          fi
          args+=( --ro-bind "$CUSTOM_HOSTS" "$_hosts_dest" )
        fi

        if [ ''${#_CFG_EXTRA_BWRAP_ARGS[@]} -gt 0 ]; then
          args+=( "''${_CFG_EXTRA_BWRAP_ARGS[@]}" )
        fi
        if [ ''${#EXTRA_BWRAP_ARGS[@]} -gt 0 ]; then
          args+=( "''${EXTRA_BWRAP_ARGS[@]}" )
        fi

        if [ -n "$START_SHELL" ]; then
          BWRAP_TARGET=$(readlink -f "$(which "$SHELL")" 2>/dev/null || which "$SHELL")
        else
          BWRAP_TARGET="@agent_binary@"
        fi

        RUN_CMD=( ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$BWRAP_TARGET" )
        if [ -z "$START_SHELL" ]; then
          RUN_CMD+=( "''${AGENT_ARGS[@]}" )
        fi
      '';

  dryRunPrint =
    if isRunsc then
      ''
        echo "runsc mode (${agentName})"
        echo "  bundle:   $BUNDLE_DIR"
        echo "  platform: $RUNSC_PLATFORM"
        echo "  command:  ''${RUN_CMD[*]}"
        echo "  config:"
        ${jq}/bin/jq . "$BUNDLE_DIR/config.json" | sed 's/^/    /'
      ''
    else
      ''
        echo "''${RUN_CMD[@]}"
      '';

  runscPlatformSetup =
    if isRunsc then
      ''
        RUNSC_PLATFORM=$(_cfg_get runscPlatform 2>/dev/null || true)
        [ -z "$RUNSC_PLATFORM" ] && RUNSC_PLATFORM="systrap"
      ''
    else
      "";

  guiExtras =
    if isRunsc then
      ""
    else
      ''
        [ -d "$XDG_RUNTIME_DIR/pulse" ]    && ALLOWLIST+=( "$XDG_RUNTIME_DIR/pulse" )
        [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && ALLOWLIST+=( "$XDG_RUNTIME_DIR/pipewire-0" )
      '';

in
writeShellScript scriptName ''
  SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  SELF_BIN="$SELF_DIR/$(basename -- "$0")"
  DOC_README="$SELF_DIR/../share/doc/${agentName}-sandbox/README.md"

  ${mkBackendDispatch backend}

  _print_sandbox_help() {
    cat <<'HELP'
  ${helpIntroLine}
  --no-X counterpart and a SANDBOX_<X> env var. Precedence for booleans:
  CLI > env > config > default.

    --allow-ssh              Mount ~/.ssh read-only, ssh-agent socket            env SANDBOX_ALLOW_SSH
    --allow-ssh-write        Upgrade ~/.ssh to read-write                         env SANDBOX_ALLOW_SSH_WRITE
    --allow-gpg              Mount ~/.gnupg and gpg-agent socket                  env SANDBOX_ALLOW_GPG
    --allow-git              Mount ~/.gitconfig, ~/.git-credentials               env SANDBOX_ALLOW_GIT
    --allow-docker           Mount Docker socket                                  env SANDBOX_ALLOW_DOCKER
    --allow-fuse             Mount /dev/fuse and user runtime dir                 env SANDBOX_ALLOW_FUSE
  ${helpGuiLine}
  ${helpNvidiaLine}
    --allow-kvm              Mount /dev/kvm and /dev/vfio                         env SANDBOX_ALLOW_KVM
    --allow-audio            Mount PulseAudio/PipeWire and /dev/snd               env SANDBOX_ALLOW_AUDIO
  ${helpLibvirtLine}
    --allow-home-access      Allow running from $HOME (weakens isolation)        env SANDBOX_ALLOW_HOME
    --allow-internet-access  Allow internet access (default)                      env SANDBOX_INTERNET_ACCESS
    --no-internet-access     Block non-private egress (RFC1918/lo/link-local ok)   env SANDBOX_INTERNET_ACCESS=0
    --allow-host HOST        Allow traffic to HOST (repeatable -- no env var)
    --disable-networking     Block all non-localhost connections                  env SANDBOX_DISABLE_NETWORKING

    --backend BACKEND        Re-exec wrapper under BACKEND (bwrap|runsc|microvm)  env SANDBOX_BACKEND
                             Also reads `backend` from ${configFileName}.
    --socks-proxy HOST:PORT  Route public traffic through SOCKS5 proxy            env SANDBOX_SOCKS_PROXY
    --sandbox-config FILE    Use FILE as sandbox config
  ${helpMountLine}
    --mount-home-cache       Mount ~/.cache/* for common dev tools                env SANDBOX_MOUNT_HOME_CACHE
    --mount-common-home-folders  Mount ~/.cargo, ~/.npm, ~/.go, etc.              env SANDBOX_MOUNT_COMMON_HOME
    --mount-tmp              Mount real /tmp instead of ephemeral sandbox tmp     env SANDBOX_MOUNT_TMP
  ${helpEnvLine}
  ${helpExtraArgsLine}
  ${helpShowConfigLine}
    --sandbox-open-shell     Drop into a shell inside the sandbox                 env START_SHELL
    --sandbox-help           Show this help
  HELP
    ${
      if enableYolo then
        ''
          echo "  --yolo                   Skip permission prompts (claude only)      env SANDBOX_YOLO"
          echo "  --no-yolo                Force prompts even if config/env enables it"''
      else
        ""
    }
    echo
    echo "Wrapper: $SELF_BIN"
    [ -f "$DOC_README" ] && echo "README:  $DOC_README"
  }

  ENABLE_FUSE=0
  ENABLE_LIBVIRT=0
  ENABLE_GUI=0
  ENABLE_NVIDIA=0
  ENABLE_KVM=0
  ENABLE_AUDIO=0
  ENABLE_DOCKER=0
  ENABLE_SSH=0
  ENABLE_SSH_WRITE=0
  ENABLE_GPG=0
  ENABLE_GIT=0
  ALLOW_HOME=0
  INTERNET_ACCESS=1
  DISABLE_NETWORKING=0
  MOUNT_HOME_CACHE=0
  MOUNT_TMP=0
  MOUNT_COMMON_HOME=0

  CLI_ENABLE_FUSE=""
  CLI_ENABLE_LIBVIRT=""
  CLI_ENABLE_GUI=""
  CLI_ENABLE_NVIDIA=""
  CLI_ENABLE_KVM=""
  CLI_ENABLE_AUDIO=""
  CLI_ENABLE_DOCKER=""
  CLI_ENABLE_SSH=""
  CLI_ENABLE_SSH_WRITE=""
  CLI_ENABLE_GPG=""
  CLI_ENABLE_GIT=""
  CLI_ALLOW_HOME=""
  CLI_INTERNET_ACCESS=""
  CLI_DISABLE_NETWORKING=""
  CLI_MOUNT_HOME_CACHE=""
  CLI_MOUNT_TMP=""
  CLI_MOUNT_COMMON_HOME=""

  SOCKS_PROXY=""
  ALLOWED_HOSTS=()
  SANDBOX_CONFIG_FILE="''${SANDBOX_CONFIG_FILE:-}"
  CLEAN_TMP=0
  MOUNT_GROUPS=()
  EXTRA_MOUNTS=()
  ${extraArgsVarName}=()
  EXTRA_ENVS=()
  AGENT_ARGS=()
  DRY_RUN=''${DRY_RUN:-}
  START_SHELL=''${START_SHELL:-}
  XDG_PATH_FIX=0
  ${
    if enableYolo then
      ''
        YOLO_CLI=""
        _YOLO_CONFIG=0''
    else
      ""
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-fuse)           CLI_ENABLE_FUSE=1; shift ;;
      --no-allow-fuse|--no-fuse) CLI_ENABLE_FUSE=0; shift ;;
      --allow-ssh)            CLI_ENABLE_SSH=1; shift ;;
      --no-allow-ssh|--no-ssh)   CLI_ENABLE_SSH=0; shift ;;
      --allow-ssh-write)      CLI_ENABLE_SSH_WRITE=1; shift ;;
      --no-allow-ssh-write|--no-ssh-write) CLI_ENABLE_SSH_WRITE=0; shift ;;
      --allow-gpg)            CLI_ENABLE_GPG=1; shift ;;
      --no-allow-gpg|--no-gpg)   CLI_ENABLE_GPG=0; shift ;;
      --allow-git)            CLI_ENABLE_GIT=1; shift ;;
      --no-allow-git|--no-git)   CLI_ENABLE_GIT=0; shift ;;
      --allow-libvirt)        CLI_ENABLE_LIBVIRT=1; shift ;;
      --no-allow-libvirt|--no-libvirt) CLI_ENABLE_LIBVIRT=0; shift ;;
      --allow-gui)            CLI_ENABLE_GUI=1; shift ;;
      --no-allow-gui|--no-gui)   CLI_ENABLE_GUI=0; shift ;;
      --allow-nvidia)         CLI_ENABLE_NVIDIA=1; shift ;;
      --no-allow-nvidia|--no-nvidia) CLI_ENABLE_NVIDIA=0; shift ;;
      --allow-kvm)            CLI_ENABLE_KVM=1; shift ;;
      --no-allow-kvm|--no-kvm)   CLI_ENABLE_KVM=0; shift ;;
      --allow-audio)          CLI_ENABLE_AUDIO=1; shift ;;
      --no-allow-audio|--no-audio) CLI_ENABLE_AUDIO=0; shift ;;
      --allow-docker)         CLI_ENABLE_DOCKER=1; shift ;;
      --no-allow-docker|--no-docker) CLI_ENABLE_DOCKER=0; shift ;;
      --allow-home-access)    CLI_ALLOW_HOME=1; shift ;;
      --no-allow-home-access|--no-home-access) CLI_ALLOW_HOME=0; shift ;;
      --allow-internet-access) CLI_INTERNET_ACCESS=1; shift ;;
      --no-internet-access)    CLI_INTERNET_ACCESS=0; shift ;;
      --allow-host)     ALLOWED_HOSTS+=("$2"); shift 2 || _reqval "$1" ;;
      --allow-host=*)   ALLOWED_HOSTS+=("''${1#*=}"); shift ;;
      --disable-networking)   CLI_DISABLE_NETWORKING=1; shift ;;
      --no-disable-networking) CLI_DISABLE_NETWORKING=0; shift ;;
      --sandbox-config)    SANDBOX_CONFIG_FILE="$2"; shift 2 || _reqval "$1" ;;
      --sandbox-config=*)  SANDBOX_CONFIG_FILE="''${1#*=}"; shift ;;
      --socks-proxy)    SOCKS_PROXY="$2"; shift 2 || _reqval "$1" ;;
      --socks-proxy=*)  SOCKS_PROXY="''${1#*=}"; shift ;;
      --mount-home-cache)   CLI_MOUNT_HOME_CACHE=1; shift ;;
      --no-mount-home-cache) CLI_MOUNT_HOME_CACHE=0; shift ;;
      --mount-tmp)          CLI_MOUNT_TMP=1; shift ;;
      --no-mount-tmp)        CLI_MOUNT_TMP=0; shift ;;
      --mount-common-home-folders)   CLI_MOUNT_COMMON_HOME=1; shift ;;
      --no-mount-common-home-folders) CLI_MOUNT_COMMON_HOME=0; shift ;;
      --mount)          EXTRA_MOUNTS+=("$2"); shift 2 || _reqval "$1" ;;
      --mount=*)        EXTRA_MOUNTS+=("''${1#*=}"); shift ;;
      ${extraArgsCase}
      --env)            EXTRA_ENVS+=("$2"); shift 2 || _reqval "$1" ;;
      --env=*)          EXTRA_ENVS+=("''${1#*=}"); shift ;;
      --runsc|--no-runsc)
        echo "Warning: --runsc is only supported on the microvm backend; use ${agentName}-microvm to enable in-guest gVisor." >&2
        shift ;;
      --runsc=*|--no-runsc=*)
        echo "Warning: --runsc is only supported on the microvm backend; use ${agentName}-microvm to enable in-guest gVisor." >&2
        shift ;;
      --sandbox-help)   _print_sandbox_help; exit 0 ;;
      --sandbox-show-config) DRY_RUN=1; shift ;;
      --sandbox-open-shell) START_SHELL=1; shift ;;
      ${
        if enableYolo then
          ''
            --yolo)        YOLO_CLI=1; shift ;;
            --no-yolo)     YOLO_CLI=0; shift ;;
          ''
        else
          ""
      }
      *)                AGENT_ARGS+=("$1"); shift ;;
    esac
  done

  ${bundleSetup}
  SANDBOX_HOME="''${TMPDIR:-/tmp}/${agentName}-${suffix}-home-$$"
  SANDBOX_TMP="''${TMPDIR:-/tmp}/${agentName}-${suffix}-tmp-$$"

  _cleanup() {
    [ -n "''${SLIRP_PID:-}" ] && kill "$SLIRP_PID" 2>/dev/null || true
    ${cleanupExtra}
    if [ "$CLEAN_TMP" -eq 1 ]; then rm -rf "$SANDBOX_HOME" "$SANDBOX_TMP"; fi
    rm -f "''${TMPDIR:-/tmp}/${agentName}-${suffix}-coord-$$" \
          "''${TMPDIR:-/tmp}/${agentName}-${suffix}-ns-$$" \
          "''${TMPDIR:-/tmp}/${agentName}-${suffix}-cmd-$$"
  }
  trap '_cleanup' EXIT

  (umask 077; mkdir -p "$SANDBOX_TMP" "$SANDBOX_HOME" "$SANDBOX_HOME/.cache" "$SANDBOX_HOME/.config")
  (umask 077; mkdir -p "$SANDBOX_HOME/''${PWD#"$HOME"}")
  USER=$(whoami)

  _REAL_CONFIG_HOME="''${XDG_CONFIG_HOME:-$HOME/.config}"
  _REAL_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
  _REAL_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"

  ${sandboxInitLines}
  ${configDeployLines}
  ${rootfsCopy}

  _path_under_tmp() {
    case "$1" in /tmp|/tmp/*) return 0 ;; *) return 1 ;; esac
  }

  ALLOWLIST=()

  if [ "$MOUNT_TMP" -eq 1 ]; then
    ALLOWLIST+=( "/tmp" )
  else
    ALLOWLIST+=( "$SANDBOX_TMP:/tmp" )
    if _path_under_tmp "$HOME"; then mkdir -p "$SANDBOX_TMP''${HOME#/tmp}"; fi
    if _path_under_tmp "$PWD";  then mkdir -p "$SANDBOX_TMP''${PWD#/tmp}";  fi
  fi

  ALLOWLIST+=(
    "$SANDBOX_HOME:$HOME"
    "$PWD"
    ${allowlistExtraStatic}
    "/nix"
    "ro:/run/current-system/sw"
    "ro:/bin/sh"
    "ro:/usr/bin/env"
  )

  HOME_ALLOW=(
  ${homeAllowBlock}
  )

  CACHE_DIRS=(
  )

  ${mountGroupBlock}

  ${extraHomeDirCreateBlock}

  ${xdgRemapBlock}
  ${configParseBlock}

  _resolve_bool ENABLE_FUSE       CLI_ENABLE_FUSE       SANDBOX_ALLOW_FUSE     fuse     0
  _resolve_bool ENABLE_SSH        CLI_ENABLE_SSH        SANDBOX_ALLOW_SSH      ssh      0
  _resolve_bool ENABLE_SSH_WRITE  CLI_ENABLE_SSH_WRITE  SANDBOX_ALLOW_SSH_WRITE sshWrite 0
  _resolve_bool ENABLE_GPG        CLI_ENABLE_GPG        SANDBOX_ALLOW_GPG      gpg      0
  _resolve_bool ENABLE_GIT        CLI_ENABLE_GIT        SANDBOX_ALLOW_GIT      git      0
  _resolve_bool ENABLE_LIBVIRT    CLI_ENABLE_LIBVIRT    SANDBOX_ALLOW_LIBVIRT  libvirt  0
  _resolve_bool ENABLE_GUI        CLI_ENABLE_GUI        SANDBOX_ALLOW_GUI      gui      0
  _resolve_bool ENABLE_NVIDIA     CLI_ENABLE_NVIDIA     SANDBOX_ALLOW_NVIDIA   nvidia   0
  _resolve_bool ENABLE_KVM        CLI_ENABLE_KVM        SANDBOX_ALLOW_KVM      kvm      0
  _resolve_bool ENABLE_AUDIO      CLI_ENABLE_AUDIO      SANDBOX_ALLOW_AUDIO    audio    0
  _resolve_bool ENABLE_DOCKER     CLI_ENABLE_DOCKER     SANDBOX_ALLOW_DOCKER   docker   0
  _resolve_bool ALLOW_HOME        CLI_ALLOW_HOME        SANDBOX_ALLOW_HOME     allowHome 0
  _resolve_bool INTERNET_ACCESS   CLI_INTERNET_ACCESS   SANDBOX_INTERNET_ACCESS   internetAccess 1
  _resolve_bool DISABLE_NETWORKING CLI_DISABLE_NETWORKING SANDBOX_DISABLE_NETWORKING disableNetworking 0
  _resolve_bool MOUNT_HOME_CACHE  CLI_MOUNT_HOME_CACHE  SANDBOX_MOUNT_HOME_CACHE mountHomeCache 0
  _resolve_bool MOUNT_TMP         CLI_MOUNT_TMP         SANDBOX_MOUNT_TMP      mountTmp 0
  _resolve_bool MOUNT_COMMON_HOME CLI_MOUNT_COMMON_HOME SANDBOX_MOUNT_COMMON_HOME mountCommonHomeFolders 0

  _CFG_XDG=$(_cfg_tristate xdgRemap 2>/dev/null || true)
  case "$_CFG_XDG" in 1) XDG_PATH_FIX=1 ;; 0) XDG_PATH_FIX=0 ;; esac
  _CFG_NOXDG=$(_cfg_tristate noXdgRemap 2>/dev/null || true)
  case "$_CFG_NOXDG" in 0) XDG_PATH_FIX=1 ;; 1) XDG_PATH_FIX=0 ;; esac
  case "''${SANDBOX_XDG_REMAP:-}" in
    1|true|yes|on)  XDG_PATH_FIX=1 ;;
    0|false|no|off) XDG_PATH_FIX=0 ;;
  esac

  ${runscPlatformSetup}

  if [ -z "$SOCKS_PROXY" ] && [ -n "''${SANDBOX_SOCKS_PROXY:-}" ]; then
    SOCKS_PROXY="$SANDBOX_SOCKS_PROXY"
  fi

  ${yoloInjectionBlock}

  if [ "$DISABLE_NETWORKING" -eq 1 ]; then INTERNET_ACCESS=0; fi

  for mount_group in "''${MOUNT_GROUPS[@]}"; do
    _apply_mount_group "$mount_group"
  done

  if [ "$MOUNT_HOME_CACHE" -eq 1 ]; then _mount_group_caches; fi
  if [ "$MOUNT_COMMON_HOME" -eq 1 ]; then _mount_group_common_tools; fi

  for mount_path in "''${EXTRA_MOUNTS[@]}"; do
    ALLOWLIST+=("$mount_path")
  done

  for cache_dir in "''${CACHE_DIRS[@]}"; do
    if [ -d "$HOME/.cache/$cache_dir" ]; then
      ALLOWLIST+=( "$HOME/.cache/$cache_dir" )
    fi
  done

  _HOME_IN_EXTRAALLOW_RW=0
  _HOME_IN_EXTRAALLOW_RO=0
  for home_path in "''${HOME_ALLOW[@]}"; do
    if [[ "$home_path" == "ro:." || "$home_path" == "ro:./" ]]; then
      _HOME_IN_EXTRAALLOW_RO=1
      ALLOWLIST+=( "ro:$HOME" )
    elif [[ "$home_path" == "." || "$home_path" == "./" ]]; then
      _HOME_IN_EXTRAALLOW_RW=1
      ALLOWLIST+=( "$HOME" )
    elif [[ "$home_path" == .config/* ]]; then
      src="$_REAL_CONFIG_HOME/''${home_path#.config/}"
      [ -e "$src" ] && ALLOWLIST+=( "$src:$HOME/.config/''${home_path#.config/}" )
    else
      [ -e "$HOME/$home_path" ] && ALLOWLIST+=( "$HOME/$home_path" )
    fi
  done

  ALLOWLIST+=( "''${_CFG_PATHS[@]}" )
  ALLOWLIST+=( "''${_CFG_HOME_PATTERNS[@]}" )

  if [ "$ENABLE_FUSE" -eq 1 ]; then
    ALLOWLIST+=( "dev:/dev/fuse" )
    [ -d "/run/user/$(id -u)" ] && ALLOWLIST+=( "/run/user/$(id -u)" )
  fi

  if [ "$ENABLE_SSH" -eq 1 ] || [ "$ENABLE_SSH_WRITE" -eq 1 ]; then
    if [ -e "$HOME/.ssh" ]; then
      if [ "$ENABLE_SSH_WRITE" -eq 1 ]; then
        ALLOWLIST+=( "$HOME/.ssh" )
      else
        ALLOWLIST+=( "ro:$HOME/.ssh" )
      fi
    fi
    [ -n "''${SSH_AUTH_SOCK:-}" ] && [ -e "$SSH_AUTH_SOCK" ] && ALLOWLIST+=( "$SSH_AUTH_SOCK" )
  fi

  if [ "$ENABLE_GPG" -eq 1 ]; then
    [ -d "$HOME/.gnupg" ] && ALLOWLIST+=( "$HOME/.gnupg" )
    if [ -n "''${GPG_AGENT_INFO:-}" ]; then
      GPG_SOCK=$(echo "$GPG_AGENT_INFO" | cut -d: -f1)
      [ -e "$GPG_SOCK" ] && ALLOWLIST+=( "$GPG_SOCK" )
    fi
    [ -S "/run/user/$(id -u)/gnupg/S.gpg-agent" ] && ALLOWLIST+=( "/run/user/$(id -u)/gnupg/S.gpg-agent" )
  fi

  if [ "$ENABLE_GIT" -eq 1 ]; then
    for p in "$HOME/.gitconfig" "$HOME/.git-credentials"; do
      [ -e "$p" ] && ALLOWLIST+=( "$p" )
    done
  fi

  if [ "$ENABLE_LIBVIRT" -eq 1 ]; then
    for sock in "/var/run/libvirt/libvirt-sock" "/run/libvirt/libvirt-sock" \
                "/run/user/$(id -u)/libvirt/libvirt-sock"; do
      [ -S "$sock" ] && ALLOWLIST+=( "$sock" )
    done
  fi

  if [ "$ENABLE_GUI" -eq 1 ]; then
    [ -d "/tmp/.X11-unix" ]        && ALLOWLIST+=( "/tmp/.X11-unix" )
    [ -f "$HOME/.Xauthority" ]     && ALLOWLIST+=( "$HOME/.Xauthority" )
    [ -n "''${WAYLAND_DISPLAY:-}" ] && [ -e "''${XDG_RUNTIME_DIR:-}/$WAYLAND_DISPLAY" ] && \
      ALLOWLIST+=( "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" )
    [ -S "''${XDG_RUNTIME_DIR:-}/bus" ] && ALLOWLIST+=( "$XDG_RUNTIME_DIR/bus" )
    [ -d "/dev/dri" ]              && ALLOWLIST+=( "dev:/dev/dri" )
    for _d in /usr/share/fonts /run/current-system/sw/share/fonts "$HOME/.local/share/fonts" \
              /usr/share/icons /run/current-system/sw/share/icons; do
      [ -d "$_d" ] && ALLOWLIST+=( "ro:$_d" )
    done
    for _d in .config/gtk-3.0 .config/gtk-4.0 .config/qt5ct .config/qt6ct; do
      [ -d "$HOME/$_d" ] && ALLOWLIST+=( "ro:$HOME/$_d" )
    done
    ${guiExtras}
  fi

  if [ "$ENABLE_NVIDIA" -eq 1 ]; then
    for dev in /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
      [ -e "$dev" ] && ALLOWLIST+=( "dev:$dev" )
    done
    for dev in /dev/nvidia[0-9]*; do
      [ -c "$dev" ] && ALLOWLIST+=( "dev:$dev" )
    done
    [ -d "/dev/nvidia-caps" ]    && ALLOWLIST+=( "dev:/dev/nvidia-caps" )
    [ -d "/run/opengl-driver" ]  && ALLOWLIST+=( "ro:/run/opengl-driver" )
  fi

  if [ "$ENABLE_KVM" -eq 1 ]; then
    [ -c "/dev/kvm" ]   && ALLOWLIST+=( "dev:/dev/kvm" )
    [ -d "/dev/vfio" ]  && ALLOWLIST+=( "dev:/dev/vfio" )
  fi

  if [ "$ENABLE_AUDIO" -eq 1 ]; then
    [ -d "''${XDG_RUNTIME_DIR:-}/pulse" ]      && ALLOWLIST+=( "$XDG_RUNTIME_DIR/pulse" )
    [ -S "''${XDG_RUNTIME_DIR:-}/pipewire-0" ] && ALLOWLIST+=( "$XDG_RUNTIME_DIR/pipewire-0" )
    [ -d "/dev/snd" ]                          && ALLOWLIST+=( "dev:/dev/snd" )
    [ -S "''${XDG_RUNTIME_DIR:-}/bus" ]        && ALLOWLIST+=( "$XDG_RUNTIME_DIR/bus" )
  fi

  if [ "$ENABLE_DOCKER" -eq 1 ]; then
    _docker_sock=""
    case "''${DOCKER_HOST:-}" in
      unix://*) _docker_sock="''${DOCKER_HOST#unix://}" ;;
    esac
    if [ -z "$_docker_sock" ] || [ ! -S "$_docker_sock" ]; then
      for sock in "/var/run/docker.sock" "/run/docker.sock" \
                  "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock" \
                  "$HOME/.docker/run/docker.sock"; do
        [ -S "$sock" ] && { _docker_sock="$sock"; break; }
      done
    fi
    if [ -n "$_docker_sock" ] && [ -S "$_docker_sock" ]; then
      ALLOWLIST+=( "$_docker_sock" )
    else
      echo "Warning: --allow-docker: no Docker socket found (probed DOCKER_HOST, /var/run, /run, \$XDG_RUNTIME_DIR, ~/.docker/run)." >&2
    fi
  fi

  _PWD_SHADOWS_HOME=0
  case "$HOME" in
    "$PWD") _PWD_SHADOWS_HOME=1 ;;
    "$PWD"/*) _PWD_SHADOWS_HOME=1 ;;
  esac

  if [ "$_PWD_SHADOWS_HOME" -eq 1 ]; then
    if [ "$ALLOW_HOME" -eq 1 ]; then
      :
    elif [ "$_HOME_IN_EXTRAALLOW_RO" -eq 1 ]; then
      :
    elif [ "$_HOME_IN_EXTRAALLOW_RW" -eq 1 ]; then
      echo "Warning: Running from \$HOME with home directory in allowed paths." >&2
      echo "The sandbox ephemeral home isolation is weakened." >&2
    else
      echo "Error: Refusing to run from \$HOME (\$PWD = $PWD)." >&2
      echo "The working-directory bind-mount would shadow the ephemeral sandbox home," >&2
      echo "exposing your real home directory inside the sandbox." >&2
      echo "" >&2
      echo "Options:" >&2
      echo "  1. Run from a project directory:  cd ~/myproject && ${agentName} ..." >&2
      echo "  2. Pass --allow-home-access to override" >&2
      echo "  3. Set \"allowHome\": true in ~/.config/${configFileName}" >&2
      exit 1
    fi
  fi

  ${etcPrepare}

  ${hostsResolve}

  ${runscEtcExtras}

  whitelisted_envs=( "PATH" "HOME" "USER" "LOGNAME" "MAIL" "TERM" "SHELL" "LANG" "TZ" )
  declare -A ENV_MAP
  for env in "''${whitelisted_envs[@]}"; do
    [ -n "''${!env:-}" ] && ENV_MAP[$env]="''${!env}"
  done
  ENV_MAP[SSL_CERT_FILE]="''${SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}"
  ENV_MAP[NIX_SSL_CERT_FILE]="''${NIX_SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}"
  ENV_MAP[CURL_CA_BUNDLE]="''${CURL_CA_BUNDLE:-${cacert}/etc/ssl/certs/ca-bundle.crt}"
  ENV_MAP[PATH]="$HOME/.local/bin:$PATH"
  ENV_MAP[SHELL]="$(readlink -f "$(which "$SHELL")" 2>/dev/null || which "$SHELL")"

  ${extraEnvLines}

  _fwd_env() { for _v in "$@"; do [ -n "''${!_v:-}" ] && ENV_MAP[$_v]="''${!_v}"; done; }

  { [ "$ENABLE_SSH" -eq 1 ] || [ "$ENABLE_SSH_WRITE" -eq 1 ]; } && _fwd_env SSH_AUTH_SOCK
  [ "$ENABLE_GPG" -eq 1 ]    && _fwd_env GPG_AGENT_INFO GPG_TTY
  [ "$ENABLE_GUI" -eq 1 ]    && _fwd_env DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE QT_QPA_PLATFORM
  [ "$ENABLE_AUDIO" -eq 1 ]  && _fwd_env XDG_RUNTIME_DIR PULSE_SERVER DBUS_SESSION_BUS_ADDRESS
  [ "$ENABLE_DOCKER" -eq 1 ] && _fwd_env DOCKER_HOST
  if [ "$ENABLE_NVIDIA" -eq 1 ]; then
    ENV_MAP[LD_LIBRARY_PATH]="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    _fwd_env CUDA_VISIBLE_DEVICES
  fi

  for env_pair in "''${EXTRA_ENVS[@]}"; do
    env_key="''${env_pair%%=*}"
    env_val="''${env_pair#*=}"
    [ -n "$env_key" ] && ENV_MAP[$env_key]="$env_val"
  done

  if [ -n "$SOCKS_PROXY" ]; then
    case "$SOCKS_PROXY" in
      socks5://*|socks://*) ;;
      :*) SOCKS_PROXY="socks5://127.0.0.1$SOCKS_PROXY" ;;
      *) SOCKS_PROXY="socks5://$SOCKS_PROXY" ;;
    esac
    if ! [[ "$SOCKS_PROXY" =~ ^socks5?://[A-Za-z0-9._-]+(:[0-9]+)?$ ]] &&
       ! [[ "$SOCKS_PROXY" =~ ^socks5?://\[[0-9A-Fa-f:.]+\](:[0-9]+)?$ ]]; then
      echo "Error: invalid --socks-proxy value: $SOCKS_PROXY" >&2
      exit 1
    fi
  fi

  ${
    if apiBaseUrlEnvVars != [ ] then
      let
        varsArray = builtins.concatStringsSep " " (map (v: ''"${v}"'') apiBaseUrlEnvVars);
        varsList = builtins.concatStringsSep ", " apiBaseUrlEnvVars;
      in
      ''
        if [ "$INTERNET_ACCESS" -eq 0 ] && [ -z "$DRY_RUN" ]; then
          _nopi_found_url=""
          for _env_pair in "''${EXTRA_ENVS[@]}"; do
            _env_key="''${_env_pair%%=*}"
            _env_val="''${_env_pair#*=}"
            for _url_var in ${varsArray}; do
              if [ "$_env_key" = "$_url_var" ]; then
                _nopi_found_url="$_env_val"
                break 2
              fi
            done
          done

          _nopi_warn=0
          if [ -z "$_nopi_found_url" ]; then
            _nopi_warn=1
            _nopi_msg="no API base URL override detected (checked: ${varsList})"
          else
            _nopi_msg=$(${python3}/bin/python3 -c '
        import socket, ipaddress, urllib.parse, sys
        url = sys.argv[1]
        host = urllib.parse.urlparse(url).hostname
        if not host:
            print("could not parse host from " + repr(url)); sys.exit(1)
        try:
            results = socket.getaddrinfo(host, None)
        except socket.gaierror as e:
            print("could not resolve " + repr(host) + " (" + str(e) + ")"); sys.exit(1)
        for family, _, _, _, addr in results:
            ip = ipaddress.ip_address(addr[0])
            if not ip.is_private:
                print("host " + repr(host) + " resolves to non-private address " + str(ip)); sys.exit(1)
        ' "$_nopi_found_url" 2>&1) && _nopi_warn=0 || _nopi_warn=1
          fi

          if [ "$_nopi_warn" -eq 1 ]; then
            echo "" >&2
            echo "Error: internet access is disabled (internetAccess=false) but $_nopi_msg." >&2
            echo "The agent will not be able to reach its API endpoints." >&2
            echo "Use --env <BASE_URL_VAR>=http://<private-ip>:<port> to set a reachable endpoint," >&2
            echo "or pass --allow-internet-access to enable internet access." >&2
            echo "" >&2
            if [ -z "$START_SHELL" ] && [ ''${#ALLOWED_HOSTS[@]} -eq 0 ]; then
              exit 1
            fi
          fi
        fi
      ''
    else
      ""
  }

  _dedup_allowlist() {
    local _n=''${#ALLOWLIST[@]}
    [ "$_n" -le 1 ] && return 0
    local -a _new=()
    local -a _mode=()
    local -a _path=()
    local -a _keep=()
    local i j e m p src dst
    for ((i=0; i<_n; i++)); do
      e="''${ALLOWLIST[$i]}"
      case "$e" in
        ro:*)  m=ro;  p="''${e#ro:}" ;;
        dev:*) _mode[$i]=dev;   _path[$i]="''${e#dev:}"; _keep[$i]=1; continue ;;
        *:*)
          src="''${e%%:*}"; dst="''${e#*:}"
          if [ "$src" != "$dst" ]; then
            _mode[$i]=remap; _path[$i]="$src"; _keep[$i]=1; continue
          fi
          m=rw; p="$src"
          ;;
        *)     m=rw;  p="$e" ;;
      esac
      [ "''${#p}" -gt 1 ] && p="''${p%/}"
      _mode[$i]="$m"
      _path[$i]="$p"
      _keep[$i]=1
    done
    for ((i=0; i<_n; i++)); do
      [ "''${_keep[$i]}" -eq 1 ] || continue
      case "''${_mode[$i]}" in dev|remap) continue ;; esac
      for ((j=0; j<_n; j++)); do
        [ "$i" -eq "$j" ] && continue
        [ "''${_keep[$j]}" -eq 1 ] || continue
        [ "''${_mode[$j]}" = "''${_mode[$i]}" ] || continue
        if [ "''${_path[$j]}" = "''${_path[$i]}" ]; then
          [ "$j" -lt "$i" ] && { _keep[$i]=0; break; }
          continue
        fi
        case "''${_path[$i]}" in
          "''${_path[$j]}"/*) _keep[$i]=0; break ;;
        esac
      done
    done
    for ((i=0; i<_n; i++)); do
      [ "''${_keep[$i]}" -eq 1 ] && _new+=("''${ALLOWLIST[$i]}")
    done
    ALLOWLIST=("''${_new[@]}")
  }
  _dedup_allowlist

  ${buildRunCmd}

  if [ -n "$DRY_RUN" ]; then
    ${dryRunPrint}
    exit 0
  fi

  _needs_ns=0
  if [ -n "$SOCKS_PROXY" ] || [ "$INTERNET_ACCESS" -eq 0 ] || [ "$DISABLE_NETWORKING" -eq 1 ]; then
    _needs_ns=1
  fi

  if [ "$_needs_ns" -eq 1 ]; then
    if [ -n "$SOCKS_PROXY" ]; then
      _proxy_stripped=$(echo "$SOCKS_PROXY" | sed -E 's|socks5?://||')
      if [[ "$_proxy_stripped" == \[* ]]; then
        PROXY_HOST=$(echo "$_proxy_stripped" | sed -E 's|^\[||;s|\].*||')
      else
        PROXY_HOST=$(echo "$_proxy_stripped" | sed -E 's|:[0-9]+$||')
      fi
      if ! [[ "$PROXY_HOST" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
        echo "Error: Invalid proxy host: $PROXY_HOST" >&2
        exit 1
      fi
    fi

    COORD_FIFO="''${TMPDIR:-/tmp}/${agentName}-${suffix}-coord-$$"
    mkfifo "$COORD_FIFO"

    RUN_QUOTED=$(printf '%q ' "''${RUN_CMD[@]}")

    _HOST_IPS_STR=""
    for _ip in "''${_RESOLVED_HOST_IPS[@]}"; do
      _HOST_IPS_STR="$_HOST_IPS_STR $_ip"
    done

    NS_SCRIPT="''${TMPDIR:-/tmp}/${agentName}-${suffix}-ns-$$"
    CMD_FILE="''${TMPDIR:-/tmp}/${agentName}-${suffix}-cmd-$$"
    echo "$RUN_QUOTED" > "$CMD_FILE"
    sed \
      -e "s|@NS_SCRIPT@|$NS_SCRIPT|g" \
      -e "s|@COORD_FIFO@|$COORD_FIFO|g" \
      -e "s|@SOCKS_PROXY@|$SOCKS_PROXY|g" \
      -e "s|@PROXY_HOST@|''${PROXY_HOST:-}|g" \
      -e "s|@DISABLE_NETWORKING@|$DISABLE_NETWORKING|g" \
      -e "s|@INTERNET_ACCESS@|$INTERNET_ACCESS|g" \
      -e "s|@HOST_IPS@|$_HOST_IPS_STR|g" \
      -e "s|@CMD_FILE@|$CMD_FILE|g" \
      ${nsScriptTemplate} > "$NS_SCRIPT"
    chmod +x "$NS_SCRIPT"

    ${util-linux}/bin/unshare --user --map-root-user --net -- bash "$NS_SCRIPT" <&0 &
    NS_PID=$!

    SLIRP_FIFO="''${TMPDIR:-/tmp}/${agentName}-${suffix}-slirp-ready-$$"
    mkfifo "$SLIRP_FIFO"
    exec {SLIRP_READY_FD}<> "$SLIRP_FIFO"
    rm -f "$SLIRP_FIFO"

    ${slirp4netns}/bin/slirp4netns --configure --mtu=65520 --ready-fd=$SLIRP_READY_FD $NS_PID tap0 >/dev/null 2>&1 &
    SLIRP_PID=$!

    _slirp_ready=0
    if read -t 3 -u $SLIRP_READY_FD 2>/dev/null; then
      _slirp_ready=1
    else
      for _ in $(seq 1 200); do
        if grep -E "^tap0[[:space:]]+00000000" /proc/$NS_PID/net/route >/dev/null 2>&1; then
          _slirp_ready=1; break
        fi
        kill -0 $SLIRP_PID 2>/dev/null || break
        sleep 0.05
      done
    fi
    exec {SLIRP_READY_FD}<&-
    if [ "$_slirp_ready" -ne 1 ]; then
      echo "Warning: slirp4netns not ready -- network may not be available." >&2
    fi

    echo "ready" > "$COORD_FIFO"
    wait $NS_PID 2>/dev/null
    exit $?
  fi

  exec "''${RUN_CMD[@]}"
''
