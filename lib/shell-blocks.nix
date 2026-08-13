{
  lib,
  jq,
  configFileName,
  configDir ? null,
  sandboxHomeDest,
  xdgRemaps ? [ ],
  extraEnvVars ? { },
  extraHomeAllow ? [ ],
  enableYolo ? false,
}:

let
  data = import ./data.nix;
  effectiveHomeAllow = extraHomeAllow ++ [ ".config/${configFileName}" ];

  homeAllowBlock = builtins.concatStringsSep "\n" (map (p: ''"${p}"'') effectiveHomeAllow);

  cacheDirsBlock = builtins.concatStringsSep "\n" data.cacheDirs;

  commonToolHomeAllowBlock = builtins.concatStringsSep "\n" data.commonToolHomeAllow;

  mountGroupBlock = ''
        _mount_group_common_tools() {
          while IFS= read -r _entry; do
            [ -n "$_entry" ] && HOME_ALLOW+=( "$_entry" )
          done <<'EOF_COMMON_TOOLS'
    ${commonToolHomeAllowBlock}
    EOF_COMMON_TOOLS
        }

        _mount_group_caches() {
          while IFS= read -r _entry; do
            [ -n "$_entry" ] && CACHE_DIRS+=( "$_entry" )
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
  '';

  configParseBlock = ''
    _find_config_up() {
      local _dir="$1" _name="$2"
      while true; do
        if [ -f "$_dir/$_name" ]; then
          printf '%s' "$_dir/$_name"
          return 0
        fi
        [ "$_dir" = "/" ] && return 1
        _dir="$(dirname "$_dir")"
      done
    }

    if [ -n "''${SANDBOX_CONFIG_FILE:-}" ]; then
      CONFIG_FILE="$SANDBOX_CONFIG_FILE"
    elif _FOUND=$(_find_config_up "$PWD" "${configFileName}"); then
      CONFIG_FILE="$_FOUND"
    else
      CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/${configFileName}"
    fi
    unset _FOUND

    _cfg_bool()     { return 1; }
    _cfg_tristate() { :; }
    _cfg_get()      { :; }

    _CFG_PATHS=()
    _CFG_HOME_PATTERNS=()
    _CFG_EXTRA_BWRAP_ARGS=()
    _CFG_EXTRA_RUNSC_ARGS=()
    _CFG_EXTRA_SBX_EXEC_ARGS=()
    _CFG_EXTRA_QEMU_ARGS=()
    declare -A _CFG_MAP=()

    if [ -f "$CONFIG_FILE" ]; then
      if ! _CFG_RAW=$(${jq}/bin/jq -r '
          if type != "object" then error("not a top-level object") else . end
          | (to_entries[]
               | select(.value | type == "boolean" or type == "string" or type == "number")
               | "S\t\(.key)\t\(.value)"),
            (.paths               // [] | .[]? | "P\t\(.)"),
            (.homePatterns        // [] | .[]? | "H\t\(.)"),
            (.extraEnvs           // [] | .[]? | "E\t\(.)"),
            (.mounts              // [] | .[]? | "M\t\(.)"),
            (.extraBubblewrapArgs  // [] | .[]? | "W\t\(.)"),
            (.extraRunscArgs       // [] | .[]? | "R\t\(.)"),
            (.extraSandboxExecArgs // [] | .[]? | "X\t\(.)"),
            (.extraQemuArgs        // [] | .[]? | "Q\t\(.)")
        ' "$CONFIG_FILE" 2>/dev/null); then
        echo "Error: $CONFIG_FILE is not valid JSON or not a top-level object." >&2
        exit 1
      fi

      while IFS=$'\t' read -r _tag _rest; do
        case "$_tag" in
          S)
            _k="''${_rest%%$'\t'*}"; _v="''${_rest#*$'\t'}"
            _CFG_MAP["$_k"]="$_v"
            ;;
          P)
            case "$_rest" in
              "~")   _expanded="$HOME" ;;
              "~/"*) _expanded="$HOME/''${_rest#~/}" ;;
              *)     _expanded="$_rest" ;;
            esac
            [ -e "$_expanded" ] && _CFG_PATHS+=( "$_expanded" )
            ;;
          H) [ -e "$HOME/$_rest" ] && _CFG_HOME_PATTERNS+=( "$HOME/$_rest" ) ;;
          E) [ -n "$_rest" ] && EXTRA_ENVS+=( "$_rest" ) ;;
          M) [ -n "$_rest" ] && MOUNT_GROUPS+=( "$_rest" ) ;;
          W) [ -n "$_rest" ] && _CFG_EXTRA_BWRAP_ARGS+=( "$_rest" ) ;;
          R) [ -n "$_rest" ] && _CFG_EXTRA_RUNSC_ARGS+=( "$_rest" ) ;;
          X) [ -n "$_rest" ] && _CFG_EXTRA_SBX_EXEC_ARGS+=( "$_rest" ) ;;
          Q) [ -n "$_rest" ] && _CFG_EXTRA_QEMU_ARGS+=( "$_rest" ) ;;
        esac
      done <<< "$_CFG_RAW"
      unset _CFG_RAW _tag _rest _k _v _expanded

      _cfg_get()  { printf '%s' "''${_CFG_MAP[$1]:-}"; }
      _cfg_bool() { [ "''${_CFG_MAP[$1]:-}" = "true" ]; }
      _cfg_tristate() {
        case "''${_CFG_MAP[$1]:-}" in
          true)  printf '1' ;;
          false) printf '0' ;;
        esac
      }

      _cfg_bool cleanTmp && CLEAN_TMP=1

      ${
        if enableYolo then
          ''
            if _cfg_bool yolo; then
              _YOLO_CONFIG=1
            fi
          ''
        else
          ""
      }

      if [ -z "''${SOCKS_PROXY:-}" ]; then
        _cfg_proxy=$(_cfg_get socksProxy)
        [ -n "$_cfg_proxy" ] && SOCKS_PROXY="$_cfg_proxy"
      fi
    fi

    _resolve_bool() {
      local out=$1 cli_var=$2 env_var=$3 cfg_key=$4 default=''${5:-0}
      local val=$default
      local cfg_val
      cfg_val=$(_cfg_tristate "$cfg_key" 2>/dev/null || true)
      [ -n "$cfg_val" ] && val=$cfg_val
      case "''${!env_var:-}" in
        1|true|yes|on)  val=1 ;;
        0|false|no|off) val=0 ;;
      esac
      case "''${!cli_var:-}" in
        1) val=1 ;;
        0) val=0 ;;
      esac
      printf -v "$out" '%s' "$val"
    }
  '';

  yoloInjectionBlock =
    if enableYolo then
      ''
        _YOLO_EFFECTIVE=0
        [ "''${_YOLO_CONFIG:-0}" = "1" ] && _YOLO_EFFECTIVE=1
        case "''${SANDBOX_YOLO:-}" in
          1|true|yes|on)  _YOLO_EFFECTIVE=1 ;;
          0|false|no|off) _YOLO_EFFECTIVE=0 ;;
        esac
        [ -n "''${YOLO_CLI:-}" ] && _YOLO_EFFECTIVE=$YOLO_CLI

        _is_subcommand=0
        case "''${AGENT_ARGS[0]:-}" in
          doctor|auth|install|mcp|agents) _is_subcommand=1 ;;
        esac
        if [ "$_YOLO_EFFECTIVE" = "1" ] && [ "$_is_subcommand" -eq 0 ]; then
          AGENT_ARGS+=("--allow-dangerously-skip-permissions" "--dangerously-skip-permissions")
        fi
      ''
    else
      "";

  extraHomeDirCreateBlock =
    let
      quoted = map (p: ''"${p}"'') effectiveHomeAllow;
      entries = builtins.concatStringsSep " " quoted;
    in
    ''
      for _entry in ${entries}; do
        if [[ "$_entry" == .config/* ]]; then
          _path="$_REAL_CONFIG_HOME/''${_entry#.config/}"
        else
          _path="$HOME/$_entry"
        fi
        [ -f "$_path" ] && continue
        if [ -d "$_path" ]; then
          :
        elif [ ! -e "$_path" ]; then
          _leaf="''${_entry##*/}"; _leaf="''${_leaf#.}"
          case "$_leaf" in *.*) continue ;; esac
          mkdir -p "$_path" 2>/dev/null || true
        fi
      done
    '';

  resolveHostExpr =
    path:
    if lib.hasPrefix "$XDG_CONFIG_HOME/" path then
      "$_REAL_CONFIG_HOME/${lib.removePrefix "$XDG_CONFIG_HOME/" path}"
    else if lib.hasPrefix "$XDG_DATA_HOME/" path then
      "$_REAL_DATA_HOME/${lib.removePrefix "$XDG_DATA_HOME/" path}"
    else if lib.hasPrefix "$XDG_CACHE_HOME/" path then
      "$_REAL_CACHE_HOME/${lib.removePrefix "$XDG_CACHE_HOME/" path}"
    else if lib.hasPrefix ".config/" path then
      "$_REAL_CONFIG_HOME/${lib.removePrefix ".config/" path}"
    else if lib.hasPrefix ".local/share/" path then
      "$_REAL_DATA_HOME/${lib.removePrefix ".local/share/" path}"
    else if lib.hasPrefix ".cache/" path then
      "$_REAL_CACHE_HOME/${lib.removePrefix ".cache/" path}"
    else
      "$HOME/${path}";

  isLikelyDir =
    path:
    let
      leaf = builtins.baseNameOf path;
      clean = lib.removePrefix "." leaf;
    in
    !lib.hasInfix "." clean;

  xdgRemapBlock =
    let
      mkRemap =
        { from, to }:
        let
          xdgExpr = resolveHostExpr to;
          dotfileExpr = "$HOME/${from}";
          sandboxDst = "$HOME/${from}";
          createDir = isLikelyDir from;
        in
        ''
          _xdg="${xdgExpr}"
          _dotfile="${dotfileExpr}"
          if [ -e "$_xdg" ]; then
            ALLOWLIST+=( "$_xdg:${sandboxDst}" )
          elif [ -e "$_dotfile" ]; then
            ALLOWLIST+=( "$_dotfile" )
          ${
            if createDir then
              ''
                else
                        mkdir -p "$_xdg" 2>/dev/null || true
                        ALLOWLIST+=( "$_xdg:${sandboxDst}" )''
            else
              ''
                else
                        true''
          }
          fi
        '';

      mkDotfile =
        { from, ... }:
        ''
          [ -e "$HOME/${from}" ] && ALLOWLIST+=( "$HOME/${from}" )
        '';

    in
    if xdgRemaps == [ ] then
      ""
    else
      ''
        if [ "$XDG_PATH_FIX" -eq 1 ]; then
          ${builtins.concatStringsSep "\n" (map mkRemap xdgRemaps)}
        else
          ${builtins.concatStringsSep "\n" (map mkDotfile xdgRemaps)}
        fi
      '';

  mkBackendDispatch = selfBackend: ''
    # Shared by every argv parser: `shift 2 || _reqval "$1"`. A failed
    # 2-shift leaves the args untouched, so $1 is still the flag name.
    _reqval() {
      echo "Error: $1 requires a value." >&2
      exit 2
    }

    _find_config_up() {
      local _dir="$1" _name="$2"
      while true; do
        if [ -f "$_dir/$_name" ]; then
          printf '%s' "$_dir/$_name"
          return 0
        fi
        [ "$_dir" = "/" ] && return 1
        _dir="$(dirname "$_dir")"
      done
    }

    _DISPATCH_BACKEND_CLI=""
    _DISPATCH_CFG_CLI=""
    _DISPATCH_KEEP=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --) shift; _DISPATCH_KEEP+=("--" "$@"); break ;;
        --backend)          _DISPATCH_BACKEND_CLI="''${2:-}"; shift 2 || _reqval "$1" ;;
        --backend=*)        _DISPATCH_BACKEND_CLI="''${1#--backend=}"; shift ;;
        --sandbox-config)   _DISPATCH_CFG_CLI="''${2:-}"; _DISPATCH_KEEP+=("$1" "''${2:-}"); shift 2 || _reqval "$1" ;;
        --sandbox-config=*) _DISPATCH_CFG_CLI="''${1#--sandbox-config=}"; _DISPATCH_KEEP+=("$1"); shift ;;
        *) _DISPATCH_KEEP+=("$1"); shift ;;
      esac
    done
    if [ "''${#_DISPATCH_KEEP[@]}" -gt 0 ]; then
      set -- "''${_DISPATCH_KEEP[@]}"
    else
      set --
    fi
    unset _DISPATCH_KEEP

    _DISPATCH_BACKEND="$_DISPATCH_BACKEND_CLI"
    [ -z "$_DISPATCH_BACKEND" ] && _DISPATCH_BACKEND="''${SANDBOX_BACKEND:-}"
    if [ -z "$_DISPATCH_BACKEND" ]; then
      if [ -n "$_DISPATCH_CFG_CLI" ]; then
        _DISPATCH_CFG_FILE="$_DISPATCH_CFG_CLI"
      elif [ -n "''${SANDBOX_CONFIG_FILE:-}" ]; then
        _DISPATCH_CFG_FILE="$SANDBOX_CONFIG_FILE"
      elif _FOUND=$(_find_config_up "$PWD" "${configFileName}"); then
        _DISPATCH_CFG_FILE="$_FOUND"
      else
        _DISPATCH_CFG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/${configFileName}"
      fi
      unset _FOUND
      if [ -f "$_DISPATCH_CFG_FILE" ]; then
        _DISPATCH_BACKEND=$(${jq}/bin/jq -r '.backend // empty' "$_DISPATCH_CFG_FILE" 2>/dev/null || true)
      fi
      unset _DISPATCH_CFG_FILE
    fi
    [ -z "$_DISPATCH_BACKEND" ] && _DISPATCH_BACKEND="${selfBackend}"

    if [ "$_DISPATCH_BACKEND" != "${selfBackend}" ]; then
      case "$_DISPATCH_BACKEND" in
        bwrap)   _DISPATCH_SUFFIX="sandbox" ;;
        runsc)   _DISPATCH_SUFFIX="runsc"   ;;
        microvm) _DISPATCH_SUFFIX="microvm" ;;
        *)
          echo "Error: unknown --backend '$_DISPATCH_BACKEND' (valid: bwrap, runsc, microvm)." >&2
          exit 2 ;;
      esac
      _DISPATCH_AGENT=$(basename "$0")
      case "$_DISPATCH_AGENT" in
        *-sandbox|*-runsc|*-microvm) _DISPATCH_AGENT="''${_DISPATCH_AGENT%-*}" ;;
      esac
      _DISPATCH_TARGET="''${_DISPATCH_AGENT}-''${_DISPATCH_SUFFIX}"
      _DISPATCH_PKG="''${_DISPATCH_AGENT}-''${_DISPATCH_BACKEND}"
      if ! command -v "$_DISPATCH_TARGET" >/dev/null 2>&1; then
        echo "Error: --backend $_DISPATCH_BACKEND requires '$_DISPATCH_TARGET' on PATH; install the corresponding package (e.g. nix profile install .#$_DISPATCH_PKG)." >&2
        exit 2
      fi
      exec "$_DISPATCH_TARGET" "$@"
    fi
    unset _DISPATCH_BACKEND_CLI _DISPATCH_CFG_CLI _DISPATCH_BACKEND _DISPATCH_AGENT _DISPATCH_SUFFIX _DISPATCH_TARGET _DISPATCH_PKG
  '';

  configDeployLines =
    if configDir != null then
      ''
        if [ -d "${configDir}" ]; then
          mkdir -p "$SANDBOX_HOME/${sandboxHomeDest}"
          cp -rn "${configDir}/." "$SANDBOX_HOME/${sandboxHomeDest}/" 2>/dev/null || true
          chmod -R u+w "$SANDBOX_HOME/${sandboxHomeDest}" 2>/dev/null || true
        fi
      ''
    else
      "";

  linuxExtraEnvLines =
    let
      lines = lib.mapAttrsToList (k: v: ''ENV_MAP[${k}]="${v}"'') extraEnvVars;
    in
    builtins.concatStringsSep "\n" lines;

  darwinExtraEnvLines =
    let
      lines = lib.mapAttrsToList (k: v: ''ENV_ARGS+=( "${k}=${v}" )'') extraEnvVars;
    in
    builtins.concatStringsSep "\n" lines;

in
{
  inherit
    homeAllowBlock
    cacheDirsBlock
    mountGroupBlock
    configParseBlock
    yoloInjectionBlock
    extraHomeDirCreateBlock
    xdgRemapBlock
    configDeployLines
    linuxExtraEnvLines
    darwinExtraEnvLines
    mkBackendDispatch
    ;
}
