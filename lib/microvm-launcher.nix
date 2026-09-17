{
  lib ? null,
  writeShellScript,
  coreutils,
  gnused,
  util-linux,
  virtiofsd ? null,
  socat,
  agentName,
  configFileName,
  vmRunnerDir,
  mountBase,
  commonToolHomeAllowBlock,
  cacheDirsBlock,
  configParseBlock,
  yoloInjectionBlock,
  mkBackendDispatch,
  boolFlagBlocks,
  yoloBlocks,
  xdgResolveBlock,
  xdgRemaps ? [ ],
  useVirtiofs ? true,
  isDarwin ? false,
  guestAgentUid,
  guestAgentGid,
  trustedSupervisor ? false,
  cpuModel ? null,
}:

let
  flagBlocks = boolFlagBlocks "microvm";
  xdgRemapSetupBlock =
    if xdgRemaps == [ ] then
      ""
    else
      let
        mkLine = r: ''
          _xdg_remap "${r.from}" "${r.to}"
        '';
      in
      ''
        if [ "$XDG_PATH_FIX" -eq 1 ]; then
          _XDG_REMAP_IDX=0
          _xdg_remap() {
            local from="$1" to_expr="$2"
            local host_path
            host_path=$(eval "printf '%s' \"$to_expr\"")
            if [ -d "$host_path" ]; then
              local tag="xdgremap-$_XDG_REMAP_IDX"
              _add_path "$host_path" rw
              echo "$tag|$from|$host_path" >> "$MOUNT_BASE/env/.xdg-home-mounts"
              _XDG_REMAP_IDX=$((_XDG_REMAP_IDX + 1))
            elif [ -f "$host_path" ]; then
              _FILES_TO_STAGE+=("$host_path=HOMEREL:$from")
            fi
          }
          ${lib.concatStrings (map mkLine xdgRemaps)}
        fi
      '';
in

writeShellScript "${agentName}-microvm" ''
    set -euo pipefail

    SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    SELF_BIN="$SELF_DIR/$(basename -- "$0")"
    DOC_README="$SELF_DIR/../share/doc/${agentName}-sandbox/README.md"

    ${mkBackendDispatch "microvm"}

    _print_sandbox_help() {
      cat <<'HELP'
  Sandbox flags (microvm). Every --allow-X / --mount-X / --disable-X has a
  --no-X counterpart and a SANDBOX_<X> env var. Precedence for booleans:
  CLI > env > config > default.

    --allow-ssh              Share ~/.ssh read-only into the VM                   env SANDBOX_ALLOW_SSH
    --allow-ssh-write        Share ~/.ssh read-write                              env SANDBOX_ALLOW_SSH_WRITE
    --allow-gpg              Bridge gpg-agent into the VM                         env SANDBOX_ALLOW_GPG
    --allow-git              Share ~/.gitconfig into the VM                       env SANDBOX_ALLOW_GIT
    --allow-docker           Forward Docker socket into the VM (via socat)        env SANDBOX_ALLOW_DOCKER
    --allow-libvirt          Forward libvirt socket into the VM (via socat)       env SANDBOX_ALLOW_LIBVIRT
    --allow-fuse             (always-on in microvm; accepted for compat)          env SANDBOX_ALLOW_FUSE
    --allow-nvidia           GPU passthrough (requires host IOMMU + vfio-pci)     env SANDBOX_ALLOW_NVIDIA
    --allow-internet-access  Allow internet access (default)                      env SANDBOX_INTERNET_ACCESS
    --no-internet-access     Block non-private egress (RFC1918/lo/link-local ok)   env SANDBOX_INTERNET_ACCESS=0
    --allow-host HOST        Allow traffic to HOST (repeatable -- no env var)
    --disable-networking     Block all non-localhost connections                  env SANDBOX_DISABLE_NETWORKING
    --runsc                  Wrap agent execution inside gVisor (runsc) in-guest  env SANDBOX_RUNSC
    --privacy-filter         Unsupported in microvm; accepted for parity            env SANDBOX_PRIVACY_FILTER

    --backend BACKEND        Re-exec wrapper under BACKEND (bwrap|runsc|microvm)  env SANDBOX_BACKEND
                             Also reads `backend` from ${configFileName}.
    --sandbox-config FILE    Use FILE as sandbox config
    --mount PATH             Share directory into the VM (repeatable -- no env var)
    --mount-home-cache       Share ~/.cache/* for common dev tools                env SANDBOX_MOUNT_HOME_CACHE
    --mount-common-home-folders  Share ~/.cargo, ~/.npm, ~/.go, etc.              env SANDBOX_MOUNT_COMMON_HOME
    --mount-tmp              Share /tmp into the VM                               env SANDBOX_MOUNT_TMP
    --env KEY=VALUE          Pass env var into the VM (repeatable)
    --workdir-read-only     Mount the invocation working directory read-only
                             (trusted-supervisor builds only)
    --forward-host-loopback PORT
                             Expose host 127.0.0.1:PORT at guest 10.0.2.100:PORT
    --extra-qemu-args ARG    Pass ARG verbatim to the QEMU runtime (repeatable)

    --sandbox-show-config    Print VM config without executing                    env DRY_RUN
    --sandbox-open-shell     Drop into a shell inside the VM                      env START_SHELL
    --sandbox-help           Show this help
  HELP
      ${yoloBlocks.help}
      echo
      echo "Wrapper: $SELF_BIN"
      [ -f "$DOC_README" ] && echo "README:  $DOC_README"
    }

    ${flagBlocks.init}

    SANDBOX_CONFIG_FILE="''${SANDBOX_CONFIG_FILE:-}"
    ALLOWED_HOSTS=()
    MOUNT_GROUPS=()
    EXTRA_MOUNTS=()
    EXTRA_ENVS=()
    HOST_LOOPBACK_FORWARDS=()
    EXTRA_QEMU_ARGS=()
    AGENT_ARGS=()
    TRUSTED_CONTROL_FILE=""
    WORKDIR_READ_ONLY=0
    DRY_RUN=""
    START_SHELL=""
    _FILES_TO_STAGE=()
    ${yoloBlocks.init}

    while [[ $# -gt 0 ]]; do
      case "$1" in
        ${flagBlocks.cases}
        --sandbox-config)    SANDBOX_CONFIG_FILE="''${2:-}"; shift 2 || _reqval "$1" ;;
        --sandbox-config=*)  SANDBOX_CONFIG_FILE="''${1#*=}"; shift ;;
        --mount)       EXTRA_MOUNTS+=("''${2:-}"); shift 2 || _reqval "$1" ;;
        --mount=*)     EXTRA_MOUNTS+=("''${1#*=}"); shift ;;
        --env)         EXTRA_ENVS+=("''${2:-}"); shift 2 || _reqval "$1" ;;
        --env=*)       EXTRA_ENVS+=("''${1#*=}"); shift ;;
        --trusted-control-file) TRUSTED_CONTROL_FILE="''${2:-}"; shift 2 || _reqval "$1" ;;
        --trusted-control-file=*) TRUSTED_CONTROL_FILE="''${1#*=}"; shift ;;
        --workdir-read-only) WORKDIR_READ_ONLY=1; shift ;;
        --forward-host-loopback) HOST_LOOPBACK_FORWARDS+=("''${2:-}"); shift 2 || _reqval "$1" ;;
        --forward-host-loopback=*) HOST_LOOPBACK_FORWARDS+=("''${1#*=}"); shift ;;
        --sandbox-help) _print_sandbox_help; exit 0 ;;
        --sandbox-show-config) DRY_RUN=1; shift ;;
        --sandbox-open-shell) START_SHELL=1; shift ;;
        ${yoloBlocks.cases}
        --allow-host)     ALLOWED_HOSTS+=("''${2:-}"); shift 2 || _reqval "$1" ;;
        --allow-host=*)   ALLOWED_HOSTS+=("''${1#*=}"); shift ;;
        --allow-gui|--no-allow-gui|--no-gui)
          echo "Warning: $1 is not supported in microvm mode." >&2
          echo "  The guest has no access to the host display server." >&2
          echo "  Workaround: ssh into the running VM from the host and use X/Wayland forwarding." >&2
          shift ;;
        --allow-audio|--no-allow-audio|--no-audio)
          echo "Warning: $1 is not supported in microvm mode." >&2
          echo "  The guest has no access to the host audio server (PulseAudio/PipeWire)." >&2
          echo "  Workaround: stream audio via a network-transparent backend (e.g. pulse --remote)." >&2
          shift ;;
        --allow-kvm|--no-allow-kvm|--no-kvm)
          echo "Warning: $1 is not supported in microvm mode." >&2
          echo "  The guest is itself a KVM guest; nested KVM is disabled by default and" >&2
          echo "  generally unreliable. Run VMs on the host instead." >&2
          shift ;;
        --allow-home-access|--no-allow-home-access|--no-home-access)
          echo "Warning: $1 is not supported in microvm mode." >&2
          echo "  The VM's \$HOME is always ephemeral; the host \$HOME is never exposed as-is." >&2
          echo "  Use --mount <path> or config \`paths\` / \`homePatterns\` to share specific dirs." >&2
          shift ;;
        --socks-proxy) echo "Warning: --socks-proxy is not supported in microvm mode, ignoring." >&2; shift 2 || _reqval "$1" ;;
        --socks-proxy=*) echo "Warning: --socks-proxy is not supported in microvm mode, ignoring." >&2; shift ;;
        --extra-bubblewrap-args) echo "Warning: --extra-bubblewrap-args is not supported in microvm mode; use --extra-qemu-args." >&2; shift 2 || _reqval "$1" ;;
        --extra-bubblewrap-args=*) echo "Warning: --extra-bubblewrap-args is not supported in microvm mode; use --extra-qemu-args." >&2; shift ;;
        --extra-runsc-args | --extra-sandbox-exec-args)
          echo "Warning: $1 is not supported in microvm mode; use --extra-qemu-args." >&2
          shift 2 || _reqval "$1" ;;
        --extra-runsc-args=* | --extra-sandbox-exec-args=*)
          echo "Warning: ''${1%%=*} is not supported in microvm mode; use --extra-qemu-args." >&2
          shift ;;
        --extra-qemu-args)   EXTRA_QEMU_ARGS+=("''${2:-}"); shift 2 || _reqval "$1" ;;
        --extra-qemu-args=*) EXTRA_QEMU_ARGS+=("''${1#*=}"); shift ;;
        *)             AGENT_ARGS+=("$1"); shift ;;
      esac
    done

    _VALIDATED_HOST_LOOPBACK_FORWARDS=()
    for _port in "''${HOST_LOOPBACK_FORWARDS[@]+"''${HOST_LOOPBACK_FORWARDS[@]}"}"; do
      case "$_port" in
        ""|*[!0-9]*)
          echo "Error: --forward-host-loopback requires a TCP port from 1 to 65535, got '$_port'." >&2
          exit 2
          ;;
      esac
      if [ "''${#_port}" -gt 5 ]; then
        echo "Error: --forward-host-loopback requires a TCP port from 1 to 65535, got '$_port'." >&2
        exit 2
      fi
      _port=$((10#$_port))
      if [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ]; then
        echo "Error: --forward-host-loopback requires a TCP port from 1 to 65535, got '$_port'." >&2
        exit 2
      fi
      _VALIDATED_HOST_LOOPBACK_FORWARDS+=("$_port")
    done
    HOST_LOOPBACK_FORWARDS=(
      "''${_VALIDATED_HOST_LOOPBACK_FORWARDS[@]+"''${_VALIDATED_HOST_LOOPBACK_FORWARDS[@]}"}"
    )
    unset _VALIDATED_HOST_LOOPBACK_FORWARDS _port

    MOUNT_BASE="${mountBase}"
    RUN_DIR=$(${coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/${agentName}-microvm-run.XXXXXX")
    LOCK_FILE="$MOUNT_BASE.lock"
    ${coreutils}/bin/mkdir -p "$MOUNT_BASE"
    if [ -L "$MOUNT_BASE" ] || [ ! -O "$MOUNT_BASE" ]; then
      echo "Error: $MOUNT_BASE exists and is not owned by you." >&2
      exit 1
    fi
    chmod 700 "$MOUNT_BASE"

    exec 200>"$LOCK_FILE"
    if ! ${util-linux}/bin/flock -n 200; then
      HOLDER_PID=$(cat "$MOUNT_BASE/.pid" 2>/dev/null || echo "")
      if [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
        echo "Error: Another ${agentName}-microvm instance is already running (PID $HOLDER_PID)." >&2
        exit 1
      fi
      rm -f "$LOCK_FILE"
      exec 200>"$LOCK_FILE"
      ${util-linux}/bin/flock -n 200 || { echo "Error: Could not acquire lock." >&2; exit 1; }
    fi
    echo $$ > "$MOUNT_BASE/.pid"

    VIRTIOFSD_PID=""
    EXTRA_VIRTIOFSD_PIDS=()
    DOCKER_SOCAT_PID=""
    LIBVIRT_SOCAT_PID=""
    SSH_SOCAT_PID=""
    GPG_SOCAT_PID=""
    _cleanup() {
      [ -n "$VIRTIOFSD_PID" ] && { kill "$VIRTIOFSD_PID" 2>/dev/null || true; wait "$VIRTIOFSD_PID" 2>/dev/null || true; }
      [ -n "$DOCKER_SOCAT_PID" ] && { kill "$DOCKER_SOCAT_PID" 2>/dev/null || true; wait "$DOCKER_SOCAT_PID" 2>/dev/null || true; }
      [ -n "$LIBVIRT_SOCAT_PID" ] && { kill "$LIBVIRT_SOCAT_PID" 2>/dev/null || true; wait "$LIBVIRT_SOCAT_PID" 2>/dev/null || true; }
      [ -n "$SSH_SOCAT_PID" ] && { kill "$SSH_SOCAT_PID" 2>/dev/null || true; wait "$SSH_SOCAT_PID" 2>/dev/null || true; }
      [ -n "$GPG_SOCAT_PID" ] && { kill "$GPG_SOCAT_PID" 2>/dev/null || true; wait "$GPG_SOCAT_PID" 2>/dev/null || true; }
      for pid in "''${EXTRA_VIRTIOFSD_PIDS[@]+"''${EXTRA_VIRTIOFSD_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
      done
      rm -rf "$MOUNT_BASE/env" "$RUN_DIR" || true
      rm -f "$MOUNT_BASE/.pid" || true
      ${util-linux}/bin/flock -u 200 || true
      true
    }
    trap '_cleanup' EXIT INT TERM

    ${configParseBlock}

    for _feat in gui kvm audio socksProxy; do
      case "$(_cfg_get "$_feat")" in
        ""|false|"0") ;;
        *) echo "Warning: config option '$_feat' is not supported in microvm mode, ignoring." >&2 ;;
      esac
    done

    _MV_PATHS=()
    for _p in "''${_CFG_PATHS[@]+"''${_CFG_PATHS[@]}"}"; do
      if [ -f "$_p" ]; then _FILES_TO_STAGE+=("$_p=$_p"); else _MV_PATHS+=("$_p"); fi
    done
    _CFG_PATHS=( "''${_MV_PATHS[@]+"''${_MV_PATHS[@]}"}" )
    _MV_HP=()
    for _p in "''${_CFG_HOME_PATTERNS[@]+"''${_CFG_HOME_PATTERNS[@]}"}"; do
      if [ -f "$_p" ]; then _FILES_TO_STAGE+=("$_p=$_p"); else _MV_HP+=("$_p"); fi
    done
    _CFG_HOME_PATTERNS=( "''${_MV_HP[@]+"''${_MV_HP[@]}"}" )
    unset _MV_PATHS _MV_HP _p

    EXTRA_QEMU_ARGS=(
      "''${_CFG_EXTRA_QEMU_ARGS[@]+"''${_CFG_EXTRA_QEMU_ARGS[@]}"}"
      "''${EXTRA_QEMU_ARGS[@]+"''${EXTRA_QEMU_ARGS[@]}"}"
    )

    ${flagBlocks.resolve}
    if [ "$ENABLE_PRIVACY_FILTER" -eq 1 ]; then
      echo "Warning: --privacy-filter is not supported in microvm mode (no SOCKS routing), ignoring." >&2
      ENABLE_PRIVACY_FILTER=0
    fi

    XDG_PATH_FIX=0
    ${xdgResolveBlock}

    if [ "$DISABLE_NETWORKING" -eq 1 ]; then
      INTERNET_ACCESS=0
    fi

    ${lib.optionalString isDarwin ''
      if [ "$ENABLE_RUNSC" -eq 1 ]; then
        echo "Warning: --runsc is not supported on the darwin microvm backend." >&2
        echo "  kvm runsc platform requires nested kvm (unavailable under HVF);" >&2
        echo "  systrap is untested in this configuration. Ignoring." >&2
        ENABLE_RUNSC=0
      fi
      if [ "$ENABLE_NVIDIA" -eq 1 ]; then
        echo "Warning: --allow-nvidia is not supported on the darwin microvm backend (no vfio-pci). Ignoring." >&2
        ENABLE_NVIDIA=0
      fi
    ''}

    ${yoloInjectionBlock}

    declare -A SEEN_PATHS
    MOUNT_PATHS=()

    _mount_group_common_tools() {
      while IFS= read -r _entry; do
        [ -n "$_entry" ] && _add_path "$HOME/$_entry"
      done <<'EOF_COMMON_TOOLS'
  ${commonToolHomeAllowBlock}
  EOF_COMMON_TOOLS
    }

    _mount_group_caches() {
      while IFS= read -r _entry; do
        [ -n "$_entry" ] && _add_path "$HOME/.cache/$_entry"
      done <<'EOF_CACHES'
  ${cacheDirsBlock}
  EOF_CACHES
    }

    _apply_mount_group() {
      case "$1" in
        "" ) ;;
        caches) _mount_group_caches ;;
        common-tools) _mount_group_common_tools ;;
        *)
          echo "Warning: unknown mount group '$1'. Supported: caches, common-tools." >&2
          ;;
      esac
    }

    _add_path() {
      local p="$1"
      local mode="''${2:-rw}"
      [ -d "$p" ] || return 0
      p=$(${coreutils}/bin/realpath "$p" 2>/dev/null || echo "$p")
      if ! [ -r "$p" ] || ! [ -x "$p" ]; then
        echo "Warning: skipping '$p' (not readable by $(whoami); cannot share into VM)." >&2
        return 0
      fi
      if [ -z "''${SEEN_PATHS[$p]:-}" ]; then
        SEEN_PATHS[$p]=1
        if [ "$mode" = "ro" ]; then
          MOUNT_PATHS+=("ro:$p")
        else
          MOUNT_PATHS+=("$p")
        fi
      fi
    }

    case "$HOME" in
      "$PWD" | "$PWD"/*)
        echo "Error: Refusing to run from \$HOME (\$PWD = $PWD)." >&2
        echo "Sharing the working directory would expose your entire home directory" >&2
        echo "read-write inside the VM." >&2
        echo "Run from a project directory instead:  cd ~/myproject && ${agentName} ..." >&2
        exit 1 ;;
    esac

    if [ "$WORKDIR_READ_ONLY" -eq 1 ]; then
      ${lib.optionalString (!trustedSupervisor) ''
        echo "Error: --workdir-read-only requires a trusted-supervisor build." >&2
        exit 2
      ''}
      _add_path "$PWD" ro
    else
      _add_path "$PWD"
    fi
    for p in "''${_CFG_PATHS[@]+"''${_CFG_PATHS[@]}"}"; do _add_path "$p"; done
    for p in "''${_CFG_HOME_PATTERNS[@]+"''${_CFG_HOME_PATTERNS[@]}"}"; do _add_path "$p"; done
    for mount_group in "''${MOUNT_GROUPS[@]+"''${MOUNT_GROUPS[@]}"}"; do _apply_mount_group "$mount_group"; done

    if [ "$MOUNT_HOME_CACHE" -eq 1 ]; then
      _mount_group_caches
    fi
    if [ "$MOUNT_COMMON_HOME" -eq 1 ]; then
      _mount_group_common_tools
    fi

    for mount_path in "''${EXTRA_MOUNTS[@]+"''${EXTRA_MOUNTS[@]}"}"; do
      case "$mount_path" in
        ro:*) _add_path "''${mount_path#ro:}" ro ;;
        *)
          if [ -f "$mount_path" ]; then
            _FILES_TO_STAGE+=("$mount_path=$mount_path")
          else
            _add_path "$mount_path"
          fi ;;
      esac
    done

    if [ "$MOUNT_TMP" -eq 1 ]; then
      _add_path /tmp
    fi

    if [ "$ENABLE_SSH_WRITE" -eq 1 ]; then
      _add_path "$HOME/.ssh" rw
    elif [ "$ENABLE_SSH" -eq 1 ]; then
      _add_path "$HOME/.ssh" ro
    fi
    if [ "$ENABLE_GPG" -eq 1 ]; then
      _add_path "$HOME/.gnupg" rw
    fi
    if [ "$ENABLE_GIT" -eq 1 ]; then
      [ -f "$HOME/.gitconfig" ]       && _FILES_TO_STAGE+=("$HOME/.gitconfig=$HOME/.gitconfig")
      [ -f "$HOME/.git-credentials" ] && _FILES_TO_STAGE+=("$HOME/.git-credentials=$HOME/.git-credentials")
    fi

    rm -rf "$MOUNT_BASE/env"
    ${coreutils}/bin/mkdir -p "$MOUNT_BASE/env" "$MOUNT_BASE/env/staged"
    umask 077

    ${xdgRemapSetupBlock}

    : > "$MOUNT_BASE/env/.staged-manifest"
    _STAGE_IDX=0
    for _entry in "''${_FILES_TO_STAGE[@]+"''${_FILES_TO_STAGE[@]}"}"; do
      _src="''${_entry%%=*}"
      _dst="''${_entry#*=}"
      [ -f "$_src" ] || continue
      _id="f$_STAGE_IDX"
      ${coreutils}/bin/cp --preserve=mode "$_src" "$MOUNT_BASE/env/staged/$_id" 2>/dev/null || continue
      _mode=$(stat -Lc '%a' "$_src" 2>/dev/null || stat -Lf '%OLp' "$_src" 2>/dev/null || echo "0600")
      printf '%s\t%s\t%s\n' "$_id" "$_dst" "$_mode" >> "$MOUNT_BASE/env/.staged-manifest"
      _STAGE_IDX=$((_STAGE_IDX + 1))
    done

    ENV_FILE="$MOUNT_BASE/env/.env"
    : > "$ENV_FILE"
    ${
      if trustedSupervisor then
        ''
          if [ -z "$TRUSTED_CONTROL_FILE" ] || [ ! -f "$TRUSTED_CONTROL_FILE" ] || [ -L "$TRUSTED_CONTROL_FILE" ]; then
            echo "Error: trusted supervisor requires one regular --trusted-control-file." >&2
            exit 2
          fi
          if [ "$WORKDIR_READ_ONLY" -ne 1 ]; then
            echo "Error: trusted supervisor requires --workdir-read-only." >&2
            exit 2
          fi
          _CONTROL_SIZE=$(${coreutils}/bin/stat -Lc '%s' "$TRUSTED_CONTROL_FILE")
          if [ "$_CONTROL_SIZE" -lt 1 ] || [ "$_CONTROL_SIZE" -gt 8388608 ]; then
            echo "Error: trusted control file must be between 1 and 8388608 bytes." >&2
            exit 2
          fi
          ${coreutils}/bin/cp --no-dereference -- "$TRUSTED_CONTROL_FILE" \
            "$MOUNT_BASE/env/.trusted-control"
          chmod 0600 "$MOUNT_BASE/env/.trusted-control"
        ''
      else
        ''
          if [ -n "$TRUSTED_CONTROL_FILE" ]; then
            echo "Error: --trusted-control-file requires a trusted-supervisor build." >&2
            exit 2
          fi
          if [ "$WORKDIR_READ_ONLY" -eq 1 ]; then
            echo "Error: --workdir-read-only requires a trusted-supervisor build." >&2
            exit 2
          fi
        ''
    }

    _env_write() { printf '%s=%q\n' "$1" "$2" >> "$ENV_FILE"; }
    _random_port() { echo $(( (RANDOM % 10000) + 40000 )); }

    for env in TERM LANG TZ; do
      [ -n "''${!env:-}" ] && _env_write "$env" "''${!env}"
    done
    for env_pair in "''${EXTRA_ENVS[@]+"''${EXTRA_ENVS[@]}"}"; do
      [ -n "$env_pair" ] || continue
      _env_write "''${env_pair%%=*}" "''${env_pair#*=}"
    done

    whoami > "$MOUNT_BASE/env/.user"
    echo "$HOME" > "$MOUNT_BASE/env/.home"
    echo "$PWD" > "$MOUNT_BASE/env/.workdir"

    _np_target=""
    for _np_src in "/etc/profiles/per-user/$(whoami)" "$HOME/.nix-profile"; do
      if [ -e "$_np_src" ]; then
        _resolved=$(${coreutils}/bin/readlink -f "$_np_src" 2>/dev/null || true)
        if [ -n "$_resolved" ] && [ -d "$_resolved" ]; then
          _np_target="$_resolved"
          break
        fi
      fi
    done
    if [ -n "$_np_target" ]; then
      echo "$_np_target" > "$MOUNT_BASE/env/.nix-profile-target"
      case "$_np_target" in
        /nix/store/*) : ;;
        *) _add_path "$_np_target" ro ;;
      esac
    fi

    if [ -n "$START_SHELL" ]; then
      echo "shell" > "$MOUNT_BASE/env/.mode"
    else
      echo "agent" > "$MOUNT_BASE/env/.mode"
    fi
    : > "$MOUNT_BASE/env/.args"
    if [ "''${#AGENT_ARGS[@]}" -gt 0 ]; then
      printf '%s\0' "''${AGENT_ARGS[@]}" > "$MOUNT_BASE/env/.args"
    fi

    if [ "$INTERNET_ACCESS" -eq 0 ]; then
      echo "1" > "$MOUNT_BASE/env/.no-internet-access"
    fi

    if [ "$DISABLE_NETWORKING" -eq 1 ]; then
      echo "1" > "$MOUNT_BASE/env/.disable-networking"
    fi

    if [ ''${#ALLOWED_HOSTS[@]} -gt 0 ]; then
      printf '%s\n' "''${ALLOWED_HOSTS[@]}" > "$MOUNT_BASE/env/.allowed-hosts"
    fi

    if [ "$ENABLE_RUNSC" -eq 1 ]; then
      echo "1" > "$MOUNT_BASE/env/.use-runsc"
      _RUNSC_PLATFORM=$(_cfg_get runscPlatform 2>/dev/null || true)
      [ -n "''${SANDBOX_RUNSC_PLATFORM:-}" ] && _RUNSC_PLATFORM="$SANDBOX_RUNSC_PLATFORM"
      case "$_RUNSC_PLATFORM" in
        systrap|ptrace|kvm) echo "$_RUNSC_PLATFORM" > "$MOUNT_BASE/env/.runsc-platform" ;;
        "") ;;
        *) echo "Warning: ignoring unknown runscPlatform '$_RUNSC_PLATFORM' (expected systrap|ptrace|kvm)." >&2 ;;
      esac
    fi

    if [ "$ENABLE_DOCKER" -eq 1 ]; then
      _DOCKER_SOCK=""
      case "''${DOCKER_HOST:-}" in
        unix://*) _DOCKER_SOCK="''${DOCKER_HOST#unix://}" ;;
      esac
      if [ -z "$_DOCKER_SOCK" ] || [ ! -S "$_DOCKER_SOCK" ]; then
        _DOCKER_SOCK=""
        for _sock in /var/run/docker.sock /run/docker.sock \
                     "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock" \
                     "$HOME/.docker/run/docker.sock"; do
          [ -S "$_sock" ] && { _DOCKER_SOCK="$_sock"; break; }
        done
      fi
      if [ -n "$_DOCKER_SOCK" ] && [ -S "$_DOCKER_SOCK" ]; then
        _DOCKER_PORT=$(_random_port)
        ${socat}/bin/socat TCP-LISTEN:"$_DOCKER_PORT",bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$_DOCKER_SOCK" &
        DOCKER_SOCAT_PID=$!
        _env_write DOCKER_HOST "tcp://10.0.2.2:$_DOCKER_PORT"
      else
        echo "Warning: --allow-docker: no Docker socket found (probed DOCKER_HOST, /var/run, /run, \$XDG_RUNTIME_DIR, ~/.docker/run)." >&2
      fi
    fi

    _ssh_on=0
    { [ "$ENABLE_SSH" -eq 1 ] || [ "$ENABLE_SSH_WRITE" -eq 1 ]; } && _ssh_on=1
    if [ "$_ssh_on" -eq 1 ] && [ -n "''${SSH_AUTH_SOCK:-}" ] && [ -S "''${SSH_AUTH_SOCK:-}" ]; then
      _SSH_PORT=$(_random_port)
      ${socat}/bin/socat TCP-LISTEN:"$_SSH_PORT",bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$SSH_AUTH_SOCK" &
      SSH_SOCAT_PID=$!
      echo "$_SSH_PORT" > "$MOUNT_BASE/env/.ssh-auth-port"
      _env_write SSH_AUTH_SOCK /run/ssh-auth.sock
    elif [ "$_ssh_on" -eq 1 ] && [ -n "''${SSH_AUTH_SOCK:-}" ]; then
      _env_write SSH_AUTH_SOCK "$SSH_AUTH_SOCK"
    fi

    if [ "$ENABLE_GPG" -eq 1 ]; then
      _GPG_SOCK=""
      if command -v gpgconf >/dev/null 2>&1; then
        _GPG_SOCK=$(gpgconf --list-dirs agent-socket 2>/dev/null || true)
      fi
      [ -z "$_GPG_SOCK" ] && _GPG_SOCK="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gnupg/S.gpg-agent"
      [ -z "$_GPG_SOCK" ] || [ ! -S "$_GPG_SOCK" ] && _GPG_SOCK="$HOME/.gnupg/S.gpg-agent"
      if [ -S "$_GPG_SOCK" ]; then
        _GPG_PORT=$(_random_port)
        ${socat}/bin/socat TCP-LISTEN:"$_GPG_PORT",bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$_GPG_SOCK" &
        GPG_SOCAT_PID=$!
        echo "$_GPG_PORT" > "$MOUNT_BASE/env/.gpg-agent-port"
      fi
      [ -n "''${GPG_TTY:-}" ] && _env_write GPG_TTY "$GPG_TTY"
    fi

    if [ "$ENABLE_LIBVIRT" -eq 1 ]; then
      _LIBVIRT_SOCK=""
      for _sock in /var/run/libvirt/libvirt-sock /run/libvirt/libvirt-sock \
                   "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/libvirt/libvirt-sock"; do
        [ -S "$_sock" ] && { _LIBVIRT_SOCK="$_sock"; break; }
      done
      if [ -n "$_LIBVIRT_SOCK" ]; then
        _LIBVIRT_PORT=$(_random_port)
        ${socat}/bin/socat TCP-LISTEN:"$_LIBVIRT_PORT",bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:"$_LIBVIRT_SOCK" &
        LIBVIRT_SOCAT_PID=$!
        echo "$_LIBVIRT_PORT" > "$MOUNT_BASE/env/.libvirt-port"
        _env_write LIBVIRT_DEFAULT_URI "qemu+unix:///system?socket=/run/libvirt-sock"
      else
        echo "Warning: --allow-libvirt: no libvirt socket found (tried /var/run/libvirt, /run/libvirt, \$XDG_RUNTIME_DIR/libvirt). Ignoring." >&2
      fi
    fi

    _NVIDIA_RUNTIME_ARGS=""
    if [ "$ENABLE_NVIDIA" -eq 1 ]; then
      _NVIDIA_PCI=""
      for _dev in /sys/bus/pci/devices/*/vendor; do
        if [ "$(cat "$_dev" 2>/dev/null)" = "0x10de" ]; then
          _pci_dir=$(dirname "$_dev")
          _class=$(cat "$_pci_dir/class" 2>/dev/null)
          if [[ "$_class" == 0x03* ]]; then
            _NVIDIA_PCI=$(basename "$_pci_dir")
            break
          fi
        fi
      done
      if [ -n "$_NVIDIA_PCI" ]; then
        _driver=$(basename "$(readlink "/sys/bus/pci/devices/$_NVIDIA_PCI/driver" 2>/dev/null)" 2>/dev/null)
        if [ "$_driver" = "vfio-pci" ]; then
          _NVIDIA_RUNTIME_ARGS=" -device vfio-pci,host=$_NVIDIA_PCI"
          echo "1" > "$MOUNT_BASE/env/.nvidia"
        else
          echo "Warning: --allow-nvidia: NVIDIA GPU $_NVIDIA_PCI is bound to '$_driver', not vfio-pci." >&2
          echo "  GPU passthrough skipped. Bind the GPU to vfio-pci to enable it:" >&2
          echo "  https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF" >&2
        fi
      else
        echo "Warning: --allow-nvidia: no NVIDIA GPU found." >&2
      fi
    fi

    EXIT_CODE_FILE="$MOUNT_BASE/env/.exit-code"
    : > "$EXIT_CODE_FILE"
    # virtiofs preserves the host UID, which does not name the guest's
    # unprivileged agent.  Keep the host parent private (MOUNT_BASE is 0700),
    # but make only the control directory traversable and the files consumed
    # by agent-run readable inside the single-purpose guest.
    chmod 0711 "$MOUNT_BASE/env"
    ${
      if trustedSupervisor then ''chmod 0600 "$EXIT_CODE_FILE"'' else ''chmod 0666 "$EXIT_CODE_FILE"''
    }
    chmod 0644 \
      "$ENV_FILE" \
      "$MOUNT_BASE/env/.user" \
      "$MOUNT_BASE/env/.home" \
      "$MOUNT_BASE/env/.workdir" \
      "$MOUNT_BASE/env/.mode" \
      "$MOUNT_BASE/env/.args"
    # The root-owned lockdown service must read this through UID-translated
    # virtiofs. It contains only the operator-supplied host allowlist.
    if [ -f "$MOUNT_BASE/env/.allowed-hosts" ]; then
      chmod 0644 "$MOUNT_BASE/env/.allowed-hosts"
    fi

    _MAX_MOUNTS=26
    if [ ''${#MOUNT_PATHS[@]} -gt $_MAX_MOUNTS ]; then
      echo "Error: too many shared directories (''${#MOUNT_PATHS[@]}); QEMU's microvm machine" >&2
      echo "  exhausts PCI slots beyond ~$_MAX_MOUNTS vhost-user-fs devices." >&2
      echo "  Reduce 'paths' in $CONFIG_FILE, drop a 'mounts' group (common-tools/caches)," >&2
      echo "  or remove --mount flags. Current shared directories:" >&2
      for _p in "''${MOUNT_PATHS[@]}"; do
        echo "    ''${_p#ro:}" >&2
      done
      exit 1
    fi

    : > "$MOUNT_BASE/env/.mounts"
    runtime_args=""
    idx=0
    HOST_UID=$(${coreutils}/bin/id -u)
    HOST_GID=$(${coreutils}/bin/id -g)

    for mpath_spec in "''${MOUNT_PATHS[@]}"; do
      _mode="rw"
      _mpath="$mpath_spec"
      if [[ "$mpath_spec" == ro:* ]]; then
        _mpath="''${mpath_spec#ro:}"
        _mode="ro"
      fi
      tag="extra-$idx"

      echo "$tag:$_mode:$_mpath" >> "$MOUNT_BASE/env/.mounts"

      ${
        if useVirtiofs then
          ''
            sock="$RUN_DIR/${agentName}-sandbox-virtiofs-$tag.sock"
            _ro_flag=""
            [ "$_mode" = "ro" ] && _ro_flag="--readonly"
            ${virtiofsd}/bin/virtiofsd \
              --socket-path="$sock" \
              --shared-dir="$_mpath" \
              $_ro_flag \
              --sandbox none \
              --translate-uid "map:${builtins.toString guestAgentUid}:$HOST_UID:1" \
              --translate-gid "map:${builtins.toString guestAgentGid}:$HOST_GID:1" \
              --cache=auto >> "$RUN_DIR/virtiofsd.log" 2>&1 &
            EXTRA_VIRTIOFSD_PIDS+=($!)
            runtime_args+=" -chardev socket,id=fs_extra_$idx,path=$sock"
            runtime_args+=" -device vhost-user-fs-pci,chardev=fs_extra_$idx,tag=$tag"
          ''
        else
          ''
            _9p_ro=""
            [ "$_mode" = "ro" ] && _9p_ro=",readonly=on"
            if [[ "$_mpath" == *,* || "$_mpath" == *=* ]]; then
              echo "Warning: mount path contains ',' or '=' which qemu -virtfs cannot encode: $_mpath" >&2
              echo "  skipping this mount." >&2
            else
              runtime_args+=" -virtfs local,path=$_mpath,mount_tag=$tag,security_model=passthrough,id=fs_extra_$idx$_9p_ro"
            fi
          ''
      }
      idx=$((idx + 1))
    done

    if [ -n "$DRY_RUN" ]; then
      echo "microvm mode (${agentName})"
      echo "  runner:    ${vmRunnerDir}/bin/microvm-run"
      echo "  user:      $(whoami)"
      echo "  workdir:   $PWD"
      echo "  fs:        ${if useVirtiofs then "virtiofs" else "9p"}"
      echo "  accel:     ${if isDarwin then "hvf" else "kvm"}"
      echo "  mounts:"
      while IFS=: read -r tag mode mpath; do
        if [ -z "$mpath" ]; then
          mpath="$mode"; mode="rw"
        fi
        echo "    $tag ($mode) -> $mpath"
      done < "$MOUNT_BASE/env/.mounts"
      if [ -s "$MOUNT_BASE/env/.staged-manifest" ]; then
        echo "  staged files:"
        while IFS=$'\t' read -r _id _dst _mode; do
          echo "    $_dst (mode $_mode)"
        done < "$MOUNT_BASE/env/.staged-manifest"
      fi
      [ -f "$MOUNT_BASE/env/.ssh-auth-port" ]  && echo "  ssh-auth bridge:  port $(cat "$MOUNT_BASE/env/.ssh-auth-port")"
      [ -f "$MOUNT_BASE/env/.gpg-agent-port" ] && echo "  gpg-agent bridge: port $(cat "$MOUNT_BASE/env/.gpg-agent-port")"
      [ -f "$MOUNT_BASE/env/.libvirt-port" ]   && echo "  libvirt bridge:   port $(cat "$MOUNT_BASE/env/.libvirt-port")"
      if [ -f "$MOUNT_BASE/env/.use-runsc" ]; then
        _plat=$(cat "$MOUNT_BASE/env/.runsc-platform" 2>/dev/null || echo systrap)
        echo "  runsc:            enabled (platform=$_plat)"
      fi
      echo "  env file:"
      ${gnused}/bin/sed 's/^/    /' "$ENV_FILE"
      exit 0
    fi

    ${lib.optionalString useVirtiofs ''
      _VIRTIOFSD_READY_ATTEMPTS=300

      idx=0
      for mpath in "''${MOUNT_PATHS[@]}"; do
        sock="$RUN_DIR/${agentName}-sandbox-virtiofs-extra-$idx.sock"
        pid="''${EXTRA_VIRTIOFSD_PIDS[$idx]}"
        for _ in $(seq 1 "$_VIRTIOFSD_READY_ATTEMPTS"); do
          [ -S "$sock" ] && break
          if ! kill -0 "$pid" 2>/dev/null; then
            echo "Warning: virtiofsd for $mpath exited early, skipping." >&2
            runtime_args=$(echo "$runtime_args" | ${gnused}/bin/sed "s/ -chardev socket,id=fs_extra_$idx,[^ ]* -device [^ ]*,tag=extra-$idx\( \|$\)/ /")
            ${gnused}/bin/sed -i "/^extra-$idx:/d" "$MOUNT_BASE/env/.mounts"
            break
          fi
          sleep 0.1
        done
        idx=$((idx + 1))
      done

      cd "$RUN_DIR"
      ${vmRunnerDir}/bin/virtiofsd-run --user "$(${coreutils}/bin/id -u)" >> "$RUN_DIR/virtiofsd.log" 2>&1 &
      VIRTIOFSD_PID=$!

      for _ in $(seq 1 "$_VIRTIOFSD_READY_ATTEMPTS"); do
        ready=1
        for sock in ${
          lib.optionalString (!trustedSupervisor) "${agentName}-sandbox-virtiofs-nix-store.sock"
        } \
                    ${agentName}-sandbox-virtiofs-env-share.sock; do
          [ -S "$RUN_DIR/$sock" ] || { ready=0; break; }
        done
        [ "$ready" -eq 1 ] && break
        kill -0 "$VIRTIOFSD_PID" 2>/dev/null || break
        sleep 0.1
      done

      if [ "$ready" -ne 1 ]; then
        echo "Error: virtiofsd sockets did not appear within 30 seconds." >&2
        if ! kill -0 "$VIRTIOFSD_PID" 2>/dev/null; then
          echo "Error: virtiofsd process exited before its sockets became ready." >&2
        fi
        if [ -s "$RUN_DIR/virtiofsd.log" ]; then
          echo "----- virtiofsd.log (last 40 lines) -----" >&2
          ${coreutils}/bin/tail -n 40 "$RUN_DIR/virtiofsd.log" >&2
          echo "----- end virtiofsd.log -----" >&2
        fi
        exit 1
      fi
    ''}

    ${lib.optionalString (!useVirtiofs) ''
      cd "$RUN_DIR"
    ''}

    PATCHED_RUNNER="$RUN_DIR/microvm-run"
    _HOST_LOOPBACK_FORWARD_ARGS=""
    for _port in "''${HOST_LOOPBACK_FORWARDS[@]+"''${HOST_LOOPBACK_FORWARDS[@]}"}"; do
      _forwarder="$RUN_DIR/host-loopback-$_port"
      {
        echo '#!/bin/sh'
        echo 'exec ${socat}/bin/socat STDIO TCP:127.0.0.1:'"$_port"
      } > "$_forwarder"
      chmod 0700 "$_forwarder"
      _HOST_LOOPBACK_FORWARD_ARGS+=",guestfwd=tcp:10.0.2.100:$_port-cmd:$_forwarder"
    done
    ${gnused}/bin/sed -E \
      -e 's|^runtime_args=$|runtime_args=''${runtime_args:-}|' \
      -e "s|-netdev 'user,id=usernet'|-netdev 'user,id=usernet$_HOST_LOOPBACK_FORWARD_ARGS'|" \
      ${lib.optionalString isDarwin "-e 's|-accel kvm[^ ]*|-accel hvf|g' -e 's|accel=kvm|accel=hvf|g' -e 's|-cpu host|-cpu max|g'"} \
      ${
        lib.optionalString (
          cpuModel != null && !isDarwin
        ) "-e ${lib.escapeShellArg "s|-cpu host|-cpu ${cpuModel}|g"}"
      } \
      ${vmRunnerDir}/bin/microvm-run > "$PATCHED_RUNNER"
    chmod +x "$PATCHED_RUNNER"

    runtime_args="$runtime_args$_NVIDIA_RUNTIME_ARGS"
    for _qa in "''${EXTRA_QEMU_ARGS[@]+"''${EXTRA_QEMU_ARGS[@]}"}"; do
      runtime_args="$runtime_args $(printf '%q' "$_qa")"
    done
    export runtime_args
    _QEMU_STATUS=0
    if "$PATCHED_RUNNER"; then
      _QEMU_STATUS=0
    else
      _QEMU_STATUS=$?
    fi
    ${lib.optionalString trustedSupervisor ''
      if [ "$_QEMU_STATUS" -ne 0 ]; then
        echo "Error: trusted guest terminated abnormally with QEMU status $_QEMU_STATUS; refusing its result." >&2
        exit 1
      fi
    ''}
    _GUEST_STATUS=""
    IFS= read -r _GUEST_STATUS < "$EXIT_CODE_FILE" || true
    case "$_GUEST_STATUS" in
      ""|*[!0-9]*) echo "Error: guest agent exit status was not reported (QEMU exited $_QEMU_STATUS)." >&2; exit 1 ;;
    esac
    if [ "$_GUEST_STATUS" -gt 255 ]; then
      echo "Error: guest agent reported invalid exit status $_GUEST_STATUS." >&2
      exit 1
    fi
    exit "$_GUEST_STATUS"
''
