{
  lib,
  writeShellScript,
  cacert,
  agentName,
  configFileName,
  enableYolo ? false,
  sandboxHomeDest ? ".${agentName}",
  xdgRemaps ? [ ],
  homeAllowBlock,
  mountGroupBlock,
  configParseBlock,
  yoloInjectionBlock ? "",
  sandboxInitLines,
  extraEnvLines,
  configDeployLines,
  extraHomeDirCreateBlock,
  mkBackendDispatch,
  ...
}:
let
  isLikelyDir =
    path:
    let
      leaf = builtins.baseNameOf path;
      clean = lib.removePrefix "." leaf;
    in
    !lib.hasInfix "." clean;

  allAgentPaths = [ sandboxHomeDest ] ++ map (r: r.from) xdgRemaps;
  darwinAgentDirPaths = builtins.filter isLikelyDir allAgentPaths;
  darwinAgentWritePaths = map (p: ''"$HOME/${p}"'') allAgentPaths;
  darwinAgentDirCreates = map (p: ''"$HOME/${p}"'') darwinAgentDirPaths;
in
writeShellScript "${agentName}-sandbox" ''
      SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      SELF_BIN="$SELF_DIR/$(basename -- "$0")"
      DOC_README="$SELF_DIR/../share/doc/${agentName}-sandbox/README.md"

      ${mkBackendDispatch "bwrap"}

      _print_sandbox_help() {
        cat <<'HELP'
  Sandbox flags (macOS seatbelt). Every --allow-X has a --no-X counterpart and a
  SANDBOX_<X> env var. Precedence for booleans: CLI > env > config > default.

    --allow-ssh              Mount ~/.ssh read-only, ssh-agent socket            env SANDBOX_ALLOW_SSH
    --allow-ssh-write        Upgrade ~/.ssh to read-write                         env SANDBOX_ALLOW_SSH_WRITE
    --allow-gpg              Mount ~/.gnupg and gpg-agent socket                  env SANDBOX_ALLOW_GPG
    --allow-git              Mount ~/.gitconfig, ~/.git-credentials               env SANDBOX_ALLOW_GIT
    --allow-docker           Mount Docker socket                                  env SANDBOX_ALLOW_DOCKER
    --allow-libvirt          Allow libvirt socket dir (Homebrew + ~/.libvirt)     env SANDBOX_ALLOW_LIBVIRT
    --allow-fuse             Check macFUSE install (paths already reachable)     env SANDBOX_ALLOW_FUSE

    --backend BACKEND        Re-exec wrapper under BACKEND (bwrap|microvm)        env SANDBOX_BACKEND
                             Also reads `backend` from ${configFileName}.
    --sandbox-config FILE    Use FILE as sandbox config
    --mount PATH             Add PATH to allowed writes (ro:/path for read-only)
    --mount-home-cache       Mount ~/.cache/* for common dev tools                env SANDBOX_MOUNT_HOME_CACHE
    --mount-common-home-folders  Mount ~/.cargo, ~/.npm, ~/.go, etc.              env SANDBOX_MOUNT_COMMON_HOME
    --env KEY=VALUE          Pass env var into sandbox (repeatable)
    --extra-sandbox-exec-args ARG  Pass ARG verbatim to sandbox-exec (repeatable)

    (Note: /tmp and /private/tmp are always writable on macOS -- required for
     tool-calling. --mount-tmp / SANDBOX_MOUNT_TMP / config mountTmp are no-ops.)

    --sandbox-show-config    Print seatbelt profile without executing             env DRY_RUN
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

      ENABLE_SSH=0
      ENABLE_SSH_WRITE=0
      ENABLE_GPG=0
      ENABLE_GIT=0
      ENABLE_DOCKER=0
      ENABLE_LIBVIRT=0
      ENABLE_FUSE=0
      MOUNT_HOME_CACHE=0
      MOUNT_COMMON_HOME=0

      CLI_ENABLE_SSH=""
      CLI_ENABLE_SSH_WRITE=""
      CLI_ENABLE_GPG=""
      CLI_ENABLE_GIT=""
      CLI_ENABLE_DOCKER=""
      CLI_ENABLE_LIBVIRT=""
      CLI_ENABLE_FUSE=""
      CLI_MOUNT_HOME_CACHE=""
      CLI_MOUNT_COMMON_HOME=""

      SANDBOX_CONFIG_FILE="''${SANDBOX_CONFIG_FILE:-}"
      MOUNT_GROUPS=()
      EXTRA_MOUNTS=()
      EXTRA_ENVS=()
      EXTRA_SANDBOX_EXEC_ARGS=()
      AGENT_ARGS=()
      DRY_RUN=''${DRY_RUN:-}
      START_SHELL=''${START_SHELL:-}
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
          --allow-ssh)            CLI_ENABLE_SSH=1; shift ;;
          --no-allow-ssh|--no-ssh)   CLI_ENABLE_SSH=0; shift ;;
          --allow-ssh-write)      CLI_ENABLE_SSH_WRITE=1; shift ;;
          --no-allow-ssh-write|--no-ssh-write) CLI_ENABLE_SSH_WRITE=0; shift ;;
          --allow-gpg)            CLI_ENABLE_GPG=1; shift ;;
          --no-allow-gpg|--no-gpg)   CLI_ENABLE_GPG=0; shift ;;
          --allow-git)            CLI_ENABLE_GIT=1; shift ;;
          --no-allow-git|--no-git)   CLI_ENABLE_GIT=0; shift ;;
          --allow-docker)         CLI_ENABLE_DOCKER=1; shift ;;
          --no-allow-docker|--no-docker) CLI_ENABLE_DOCKER=0; shift ;;
          --allow-libvirt)        CLI_ENABLE_LIBVIRT=1; shift ;;
          --no-allow-libvirt|--no-libvirt) CLI_ENABLE_LIBVIRT=0; shift ;;
          --allow-fuse)           CLI_ENABLE_FUSE=1; shift ;;
          --no-allow-fuse|--no-fuse) CLI_ENABLE_FUSE=0; shift ;;
          ${
            if enableYolo then
              ''
                --yolo)        YOLO_CLI=1; shift ;;
                --no-yolo)     YOLO_CLI=0; shift ;;
              ''
            else
              ""
          }
          --sandbox-config)    SANDBOX_CONFIG_FILE="$2"; shift 2 || _reqval "$1" ;;
          --sandbox-config=*)  SANDBOX_CONFIG_FILE="''${1#*=}"; shift ;;
          --mount-home-cache)  CLI_MOUNT_HOME_CACHE=1; shift ;;
          --no-mount-home-cache) CLI_MOUNT_HOME_CACHE=0; shift ;;
          --mount-tmp|--no-mount-tmp)
            echo "Warning: $1 is a no-op on macOS; /tmp is always writable (required for tool calls)." >&2
            shift ;;
          --mount-common-home-folders)   CLI_MOUNT_COMMON_HOME=1; shift ;;
          --no-mount-common-home-folders) CLI_MOUNT_COMMON_HOME=0; shift ;;
          --mount)       EXTRA_MOUNTS+=("$2"); shift 2 || _reqval "$1" ;;
          --mount=*)     EXTRA_MOUNTS+=("''${1#*=}"); shift ;;
          --env)         EXTRA_ENVS+=("$2"); shift 2 || _reqval "$1" ;;
          --env=*)       EXTRA_ENVS+=("''${1#*=}"); shift ;;
          --sandbox-help) _print_sandbox_help; exit 0 ;;
          --sandbox-show-config) DRY_RUN=1; shift ;;
          --sandbox-open-shell) START_SHELL=1; shift ;;
          --socks-proxy|--socks-proxy=*)
            echo "Warning: --socks-proxy is not supported on macOS (no network namespace isolation)." >&2
            [[ "$1" == --socks-proxy ]] && shift 2 || shift ;;
          --allow-internet-access|--no-allow-internet-access|--no-internet-access|\
          --disable-networking|--no-disable-networking)
            echo "Warning: $1 is not supported on macOS (no network namespace isolation)." >&2
            shift ;;
          --allow-host)
            echo "Warning: --allow-host is not supported on macOS (no network namespace isolation)." >&2
            shift 2 || _reqval "$1" ;;
          --allow-host=*)
            echo "Warning: --allow-host is not supported on macOS (no network namespace isolation)." >&2
            shift ;;
          --allow-gui|--no-allow-gui|--no-gui|\
          --allow-nvidia|--no-allow-nvidia|--no-nvidia|\
          --allow-kvm|--no-allow-kvm|--no-kvm|\
          --allow-audio|--no-allow-audio|--no-audio|\
          --allow-home-access|--no-allow-home-access|--no-home-access)
            echo "Warning: $1 is not supported on macOS, ignoring." >&2
            shift ;;
          --runsc|--no-runsc)
            echo "Warning: --runsc is only supported on the microvm backend; not applicable on macOS." >&2
            shift ;;
          --extra-bubblewrap-args)
            echo "Warning: --extra-bubblewrap-args is not supported on macOS; use --extra-sandbox-exec-args." >&2
            shift 2 || _reqval "$1" ;;
          --extra-bubblewrap-args=*)
            echo "Warning: --extra-bubblewrap-args is not supported on macOS; use --extra-sandbox-exec-args." >&2
            shift ;;
          --extra-runsc-args|--extra-qemu-args)
            echo "Warning: $1 is not supported on macOS; use --extra-sandbox-exec-args." >&2
            shift 2 || _reqval "$1" ;;
          --extra-runsc-args=*|--extra-qemu-args=*)
            echo "Warning: ''${1%%=*} is not supported on macOS; use --extra-sandbox-exec-args." >&2
            shift ;;
          --extra-sandbox-exec-args)
            EXTRA_SANDBOX_EXEC_ARGS+=("$2"); shift 2 || _reqval "$1" ;;
          --extra-sandbox-exec-args=*)
            EXTRA_SANDBOX_EXEC_ARGS+=("''${1#*=}"); shift ;;
          *)
            AGENT_ARGS+=("$1"); shift ;;
        esac
      done

      USER=$(whoami)
      SANDBOX_HOME="$HOME"

      _REAL_CONFIG_HOME="''${XDG_CONFIG_HOME:-$HOME/.config}"
      _REAL_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
      _REAL_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
      XDG_PATH_FIX=0

      ${sandboxInitLines}
      ${configDeployLines}

    ${extraHomeDirCreateBlock}

      RW_PATHS=()
      RO_PATHS=()
      RW_PATHS+=( "$PWD" )

      HOME_ALLOW=(
    ${homeAllowBlock}
      )

      CACHE_DIRS=(
      )

      ${mountGroupBlock}

      ${configParseBlock}

      _resolve_bool ENABLE_SSH         CLI_ENABLE_SSH         SANDBOX_ALLOW_SSH         ssh      0
      _resolve_bool ENABLE_SSH_WRITE   CLI_ENABLE_SSH_WRITE   SANDBOX_ALLOW_SSH_WRITE   sshWrite 0
      _resolve_bool ENABLE_GPG         CLI_ENABLE_GPG         SANDBOX_ALLOW_GPG         gpg      0
      _resolve_bool ENABLE_GIT         CLI_ENABLE_GIT         SANDBOX_ALLOW_GIT         git      0
      _resolve_bool ENABLE_DOCKER      CLI_ENABLE_DOCKER      SANDBOX_ALLOW_DOCKER      docker   0
      _resolve_bool ENABLE_LIBVIRT     CLI_ENABLE_LIBVIRT     SANDBOX_ALLOW_LIBVIRT     libvirt  0
      _resolve_bool ENABLE_FUSE        CLI_ENABLE_FUSE        SANDBOX_ALLOW_FUSE        fuse     0
      _resolve_bool MOUNT_HOME_CACHE   CLI_MOUNT_HOME_CACHE   SANDBOX_MOUNT_HOME_CACHE  mountHomeCache 0
      _resolve_bool MOUNT_COMMON_HOME  CLI_MOUNT_COMMON_HOME  SANDBOX_MOUNT_COMMON_HOME mountCommonHomeFolders 0

      if [ -n "''${SANDBOX_MOUNT_TMP:-}" ]; then
        echo "Warning: SANDBOX_MOUNT_TMP is a no-op on macOS; /tmp is always writable." >&2
      fi
      if [ -n "$(_cfg_get mountTmp)" ]; then
        echo "Warning: config option 'mountTmp' is a no-op on macOS; /tmp is always writable." >&2
      fi

      ENABLE_GUI=0; ENABLE_NVIDIA=0; ENABLE_KVM=0; ENABLE_AUDIO=0

      ${yoloInjectionBlock}
      for mount_group in "''${MOUNT_GROUPS[@]}"; do
        _apply_mount_group "$mount_group"
      done

      if [ "$MOUNT_HOME_CACHE" -eq 1 ]; then
        _mount_group_caches
      fi
      if [ "$MOUNT_COMMON_HOME" -eq 1 ]; then
        _mount_group_common_tools
      fi

      for mount_path in "''${EXTRA_MOUNTS[@]}"; do
        if [[ "$mount_path" == ro:* ]]; then
          mount_path="''${mount_path#ro:}"
          [ -e "$mount_path" ] && RO_PATHS+=("$mount_path")
        else
          [ -e "$mount_path" ] && RW_PATHS+=("$mount_path")
        fi
      done

      for cache_dir in "''${CACHE_DIRS[@]}"; do
        [ -d "$HOME/.cache/$cache_dir" ] && RW_PATHS+=( "$HOME/.cache/$cache_dir" )
      done
      for home_path in "''${HOME_ALLOW[@]}"; do
        if [[ "$home_path" == .config/* ]]; then
          _resolved="$_REAL_CONFIG_HOME/''${home_path#.config/}"
          [ -e "$_resolved" ] && RW_PATHS+=( "$_resolved" )
        else
          [ -e "$HOME/$home_path" ] && RW_PATHS+=( "$HOME/$home_path" )
        fi
      done

      for _agent_dir in ${lib.concatStringsSep " " darwinAgentDirCreates}; do
        mkdir -p "$_agent_dir" 2>/dev/null || true
      done
      for _agent_path in ${lib.concatStringsSep " " darwinAgentWritePaths}; do
        RW_PATHS+=( "$_agent_path" )
      done

      RW_PATHS+=( "''${_CFG_PATHS[@]}" )
      RW_PATHS+=( "''${_CFG_HOME_PATTERNS[@]}" )
      if [ "$ENABLE_SSH" -eq 1 ] || [ "$ENABLE_SSH_WRITE" -eq 1 ]; then
        if [ -d "$HOME/.ssh" ]; then
          if [ "$ENABLE_SSH_WRITE" -eq 1 ]; then
            RW_PATHS+=( "$HOME/.ssh" )
          else
            RO_PATHS+=( "$HOME/.ssh" )
          fi
        fi
      fi
      if [ "$ENABLE_GPG" -eq 1 ]; then
        [ -d "$HOME/.gnupg" ] && RW_PATHS+=( "$HOME/.gnupg" )
      fi

      if [ "$ENABLE_GIT" -eq 1 ]; then
        [ -e "$HOME/.gitconfig" ]       && RO_PATHS+=( "$HOME/.gitconfig" )
        [ -e "$HOME/.git-credentials" ] && RW_PATHS+=( "$HOME/.git-credentials" )
      fi

      if [ "$ENABLE_DOCKER" -eq 1 ]; then
        _docker_sock=""
        case "''${DOCKER_HOST:-}" in
          unix://*) _docker_sock="''${DOCKER_HOST#unix://}" ;;
        esac
        if [ -z "$_docker_sock" ] || [ ! -S "$_docker_sock" ]; then
          for sock in "/var/run/docker.sock" "/run/docker.sock" \
                      "$HOME/.docker/run/docker.sock"; do
            [ -S "$sock" ] && { _docker_sock="$sock"; break; }
          done
        fi
        if [ -n "$_docker_sock" ] && [ -S "$_docker_sock" ]; then
          RW_PATHS+=( "$_docker_sock" )
        else
          echo "Warning: --allow-docker: no Docker socket found (probed DOCKER_HOST, /var/run, /run, ~/.docker/run)." >&2
        fi
      fi

      if [ "$ENABLE_LIBVIRT" -eq 1 ]; then
        _LIBVIRT_SOCK_FOUND=0
        _LIBVIRT_SOCK_DIRS=(
          /opt/homebrew/var/run/libvirt
          /usr/local/var/run/libvirt
          "$HOME/.libvirt"
        )
        if command -v brew >/dev/null 2>&1; then
          _brew_libvirt=$(brew --prefix libvirt 2>/dev/null)
          if [ -n "$_brew_libvirt" ] && [ -d "$_brew_libvirt/../../var/run/libvirt" ]; then
            _LIBVIRT_SOCK_DIRS+=("$_brew_libvirt/../../var/run/libvirt")
          fi
        fi
        for _p in "''${_LIBVIRT_SOCK_DIRS[@]}"; do
          if [ -d "$_p" ]; then
            RW_PATHS+=( "$_p" )
            _LIBVIRT_SOCK_FOUND=1
          fi
        done
        [ -d "$HOME/.config/libvirt" ] && RO_PATHS+=( "$HOME/.config/libvirt" )
        if [ "$_LIBVIRT_SOCK_FOUND" -eq 0 ]; then
          echo "Warning: --allow-libvirt: no libvirt socket directory found." >&2
          echo "  Looked in /opt/homebrew/var/run/libvirt, /usr/local/var/run/libvirt," >&2
          echo "  ~/.libvirt. Install libvirt (brew install libvirt) and start libvirtd." >&2
        fi
      fi

      if [ "$ENABLE_FUSE" -eq 1 ]; then
        if [ ! -d "/Library/Filesystems/macfuse.fs" ] && [ ! -d "/Library/Frameworks/macFUSE.framework" ]; then
          echo "Warning: --allow-fuse: macFUSE not detected." >&2
          echo "  Looked in /Library/Filesystems/macfuse.fs and /Library/Frameworks/macFUSE.framework." >&2
          echo "  Install with 'brew install --cask macfuse' (kext + reboot required)," >&2
          echo "  or use Fuse-T (kextless) from https://www.fuse-t.org/." >&2
        fi
      fi

      for key in socksProxy disableNetworking gui nvidia kvm audio; do
        _val=$(_cfg_get "$key")
        if [ -n "$_val" ] && [ "$_val" != "false" ]; then
          echo "Warning: config option '$key' is not supported on macOS, ignoring." >&2
        fi
      done
      unset _val

      EXTRA_SANDBOX_EXEC_ARGS=(
        "''${_CFG_EXTRA_SBX_EXEC_ARGS[@]+"''${_CFG_EXTRA_SBX_EXEC_ARGS[@]}"}"
        "''${EXTRA_SANDBOX_EXEC_ARGS[@]+"''${EXTRA_SANDBOX_EXEC_ARGS[@]}"}"
      )
      if [ "$(_cfg_get internetAccess)" = "false" ]; then
        echo "Warning: config option 'internetAccess: false' is not supported on macOS, ignoring." >&2
      fi

      DENY_PATHS=()
      DENY_PATHS+=( "$HOME/.ssh" )
      DENY_PATHS+=( "$HOME/.gnupg" )
      DENY_PATHS+=( "$HOME/.aws" "$HOME/.azure" "$HOME/.config/gcloud" )
      DENY_PATHS+=( "$HOME/.docker" )
      DENY_PATHS+=( "$HOME/.gitconfig" "$HOME/.git-credentials" )
      DENY_PATHS+=( "$HOME/.netrc" "$HOME/.kube" "$HOME/.terraform.d" )
      DENY_PATHS+=( "$HOME/.config/gh" "$HOME/.local/share/keyrings" )
      DENY_PATHS+=( "$HOME/.gnome-keyring" "$HOME/.password-store" )
      DENY_PATHS+=( "$HOME/.1password" "$HOME/.bitwarden" )

      _remove_deny() {
        local target="$1"
        local i
        for i in "''${!DENY_PATHS[@]}"; do
          if [[ "''${DENY_PATHS[$i]}" == "$target" ]]; then
            unset 'DENY_PATHS[$i]'
          fi
        done
      }

      if [ "$ENABLE_SSH" -eq 1 ] || [ "$ENABLE_SSH_WRITE" -eq 1 ]; then
        _remove_deny "$HOME/.ssh"
      fi
      if [ "$ENABLE_GPG" -eq 1 ]; then
        _remove_deny "$HOME/.gnupg"
      fi
      if [ "$ENABLE_GIT" -eq 1 ]; then
        _remove_deny "$HOME/.gitconfig"
        _remove_deny "$HOME/.git-credentials"
      fi
      if [ "$ENABLE_DOCKER" -eq 1 ]; then
        _remove_deny "$HOME/.docker"
      fi

      PROFILE='(version 1)
    (deny default)

    (allow process-exec)
    (allow process-fork)
    (allow signal (target self))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow ipc-posix-shm-read-data)
    (allow ipc-posix-shm-write-data)
    (allow ipc-posix-shm-write-create)
    (allow file-ioctl)

    (allow network-outbound)
      (allow network-inbound)
    (allow network-bind)
    (allow system-socket)

    (allow file-read*)

    (allow file-write*
      (subpath "/private/var/folders") (subpath "/var/folders")
      (subpath "/dev"))
    '

      PROFILE+="
    (allow file-write* (subpath \"/tmp\"))
    (allow file-write* (subpath \"/private/tmp\"))"

      _sb_path() {
        local p="$1"
        if [[ "$p" == *'"'* ]] || [[ "$p" == *')'* ]] || [[ "$p" == *'('* ]] || [[ "$p" == *'\'* ]] || [[ "$p" == *$'\n'* ]]; then
          echo "Warning: skipping path with unsafe characters for sandbox profile: $p" >&2
          return 1
        fi
        return 0
      }

      for p in "''${RW_PATHS[@]}"; do
        _sb_path "$p" && PROFILE+="
    (allow file-write* (subpath \"$p\"))"
      done

      for p in "''${RO_PATHS[@]}"; do
        _sb_path "$p" && PROFILE+="
    (allow file-read* (subpath \"$p\"))"
      done

      if { [ "$ENABLE_SSH" -eq 1 ] || [ "$ENABLE_SSH_WRITE" -eq 1 ]; } && [ -n "$SSH_AUTH_SOCK" ] && [ -e "$SSH_AUTH_SOCK" ]; then
        SOCK_DIR=$(dirname "$SSH_AUTH_SOCK")
        _sb_path "$SOCK_DIR" && PROFILE+="
    (allow file-write* (subpath \"$SOCK_DIR\"))"
      fi

      for p in "''${DENY_PATHS[@]}"; do
        [ -n "$p" ] && _sb_path "$p" && PROFILE+="
    (deny file-read* file-write* (subpath \"$p\"))"
      done

      ENV_ARGS=()
      ENV_ARGS+=( "PATH=/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$PATH" )
      ENV_ARGS+=( "HOME=$HOME" "USER=$USER" "LOGNAME=$USER" )
      [ -n "$TMPDIR" ] && ENV_ARGS+=( "TMPDIR=$TMPDIR" )
      [ -n "$TERM" ]  && ENV_ARGS+=( "TERM=$TERM" )
      [ -n "$SHELL" ] && ENV_ARGS+=( "SHELL=$SHELL" )
      ENV_ARGS+=( "SSL_CERT_FILE=''${SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}" )
      ENV_ARGS+=( "NIX_SSL_CERT_FILE=''${NIX_SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}" )
      ENV_ARGS+=( "CURL_CA_BUNDLE=''${CURL_CA_BUNDLE:-${cacert}/etc/ssl/certs/ca-bundle.crt}" )

      ${extraEnvLines}

      if [ "$ENABLE_SSH" -eq 1 ] || [ "$ENABLE_SSH_WRITE" -eq 1 ]; then
        [ -n "$SSH_AUTH_SOCK" ]  && ENV_ARGS+=( "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" )
      fi
      if [ "$ENABLE_GPG" -eq 1 ]; then
        [ -n "$GPG_AGENT_INFO" ] && ENV_ARGS+=( "GPG_AGENT_INFO=$GPG_AGENT_INFO" )
        [ -n "$GPG_TTY" ]        && ENV_ARGS+=( "GPG_TTY=$GPG_TTY" )
      fi

      [ "$ENABLE_DOCKER" -eq 1 ] && [ -n "$DOCKER_HOST" ] && ENV_ARGS+=( "DOCKER_HOST=$DOCKER_HOST" )
      [ "$ENABLE_LIBVIRT" -eq 1 ] && [ -n "$LIBVIRT_DEFAULT_URI" ] && ENV_ARGS+=( "LIBVIRT_DEFAULT_URI=$LIBVIRT_DEFAULT_URI" )

      for env_pair in "''${EXTRA_ENVS[@]}"; do
        [ -n "$env_pair" ] && ENV_ARGS+=( "$env_pair" )
      done

      if [ -n "$DRY_RUN" ]; then
        echo "sandbox-exec profile:"
        echo "$PROFILE"
        echo ""
        echo "Command: env ''${ENV_ARGS[*]} @agent_binary@ ''${AGENT_ARGS[*]}"
        exit 0
      fi

      if [ -n "$START_SHELL" ]; then
        exec /usr/bin/sandbox-exec "''${EXTRA_SANDBOX_EXEC_ARGS[@]+"''${EXTRA_SANDBOX_EXEC_ARGS[@]}"}" -p "$PROFILE" env "''${ENV_ARGS[@]}" "$SHELL"
      else
        exec /usr/bin/sandbox-exec "''${EXTRA_SANDBOX_EXEC_ARGS[@]+"''${EXTRA_SANDBOX_EXEC_ARGS[@]}"}" -p "$PROFILE" env "''${ENV_ARGS[@]}" @agent_binary@ "''${AGENT_ARGS[@]}"
      fi
''
