{
  lib,
  agentName,
  enableYolo ? false,
  backend ? "bwrap",
  upstreamBashFunc ? null,
  upstreamZshFunc ? null,
}:

let
  isMicrovm = backend == "microvm";
  isDarwin = backend == "darwin";
  isLinuxSandbox = backend == "bwrap" || backend == "runsc";

  boolFlagsCore = [
    {
      f = "--allow-ssh";
      d = "Mount ~/.ssh read-only + ssh-agent socket";
    }
    {
      f = "--allow-ssh-write";
      d = "Upgrade ~/.ssh mount to read-write";
    }
    {
      f = "--allow-gpg";
      d = "Mount ~/.gnupg and gpg-agent socket";
    }
    {
      f = "--allow-git";
      d = "Mount ~/.gitconfig and ~/.git-credentials";
    }
    {
      f = "--allow-docker";
      d = "Mount the Docker socket";
    }
    {
      f = "--allow-libvirt";
      d = "Mount libvirt socket and config";
    }
    {
      f = "--allow-fuse";
      d = "Mount /dev/fuse and user runtime dir";
    }
    {
      f = "--allow-internet-access";
      d = "Allow internet access (default)";
    }
    {
      f = "--no-internet-access";
      d = "Block non-private egress";
    }
    {
      f = "--disable-networking";
      d = "Block all non-localhost connections";
    }
    {
      f = "--mount-home-cache";
      d = "Mount ~/.cache/* for common dev tools";
    }
    {
      f = "--mount-common-home-folders";
      d = "Mount ~/.cargo, ~/.npm, ~/.go, etc.";
    }
    {
      f = "--mount-tmp";
      d = "Mount real /tmp instead of ephemeral tmp";
    }
    {
      f = "--sandbox-open-shell";
      d = "Drop into a shell inside the sandbox";
    }
    {
      f = "--sandbox-show-config";
      d = "Print sandbox profile without executing";
    }
    {
      f = "--sandbox-help";
      d = "Show sandbox wrapper help";
    }
  ];

  boolFlagsLinuxOnly = [
    {
      f = "--allow-gui";
      d = "Mount X11/Wayland sockets";
    }
    {
      f = "--allow-nvidia";
      d = "Mount NVIDIA device nodes and libraries";
    }
    {
      f = "--allow-kvm";
      d = "Mount /dev/kvm and /dev/vfio";
    }
    {
      f = "--allow-audio";
      d = "Mount PulseAudio/PipeWire and /dev/snd";
    }
    {
      f = "--allow-home-access";
      d = "Allow running from \$HOME (weakens isolation)";
    }
  ];

  boolFlagsMicrovmOnly = [
    {
      f = "--allow-nvidia";
      d = "GPU passthrough (requires host IOMMU + vfio-pci)";
    }
    {
      f = "--runsc";
      d = "Wrap agent execution inside gVisor (runsc) in-guest";
    }
    {
      f = "--no-runsc";
      d = "Disable in-guest runsc wrapping";
    }
  ];

  yoloFlags = lib.optionals enableYolo [
    {
      f = "--yolo";
      d = "Bypass agent permission checks (dangerous)";
    }
    {
      f = "--no-yolo";
      d = "Disable yolo mode";
    }
  ];

  boolFlags =
    boolFlagsCore
    ++ lib.optionals isLinuxSandbox boolFlagsLinuxOnly
    ++ lib.optionals isMicrovm boolFlagsMicrovmOnly
    ++ yoloFlags;

  negBases = [
    "ssh"
    "ssh-write"
    "gpg"
    "git"
    "docker"
    "fuse"
    "libvirt"
  ]
  ++ lib.optionals isLinuxSandbox [
    "gui"
    "nvidia"
    "kvm"
    "audio"
    "home-access"
  ]
  ++ lib.optionals isMicrovm [ "nvidia" ];

  expandedNegs = lib.concatMap (base: [
    {
      f = "--no-allow-${base}";
      d = "Disable --allow-${base}";
    }
    {
      f = "--no-${base}";
      d = "Disable --allow-${base}";
    }
  ]) negBases;

  mountNegs = [
    {
      f = "--no-disable-networking";
      d = "Re-enable networking";
    }
    {
      f = "--no-mount-home-cache";
      d = "Disable --mount-home-cache";
    }
    {
      f = "--no-mount-common-home-folders";
      d = "Disable --mount-common-home-folders";
    }
    {
      f = "--no-mount-tmp";
      d = "Disable --mount-tmp";
    }
  ];

  negations = expandedNegs ++ mountNegs;

  argFlagsCore = [
    {
      f = "--allow-host";
      d = "Allow traffic to HOST (repeatable)";
      type = "host";
      repeat = true;
    }
    {
      f = "--backend";
      d = "Re-exec under backend (bwrap|runsc|microvm)";
      type = "enum";
      values = [
        "bwrap"
        "runsc"
        "microvm"
      ];
      repeat = false;
    }
    {
      f = "--sandbox-config";
      d = "Use FILE as sandbox config";
      type = "file";
      repeat = false;
    }
    {
      f = "--socks-proxy";
      d = "Route public traffic through SOCKS5 HOST:PORT";
      type = "any";
      repeat = false;
    }
    {
      f = "--mount";
      d = "Add PATH to allowed mounts (prefix ro: for read-only)";
      type = "file";
      repeat = true;
    }
    {
      f = "--env";
      d = "Pass env var into sandbox (KEY=VAL, repeatable)";
      type = "any";
      repeat = true;
    }
  ];

  argFlagsBwrapOrRunsc = [
    {
      f = "--extra-bubblewrap-args";
      d = "Pass ARG verbatim to bubblewrap";
      type = "any";
      repeat = true;
    }
    {
      f = "--extra-runsc-args";
      d = "Pass ARG verbatim to runsc";
      type = "any";
      repeat = true;
    }
  ];

  argFlagsDarwin = [
    {
      f = "--extra-sandbox-exec-args";
      d = "Pass ARG verbatim to sandbox-exec";
      type = "any";
      repeat = true;
    }
    {
      f = "--extra-bubblewrap-args";
      d = "Pass ARG verbatim (accepted for compat)";
      type = "any";
      repeat = true;
    }
  ];

  argFlagsMicrovm = [
    {
      f = "--extra-qemu-args";
      d = "Pass ARG verbatim to the QEMU runtime";
      type = "any";
      repeat = true;
    }
  ];

  argFlags =
    argFlagsCore
    ++ lib.optionals isLinuxSandbox argFlagsBwrapOrRunsc
    ++ lib.optionals isDarwin argFlagsDarwin
    ++ lib.optionals isMicrovm argFlagsMicrovm;

  allFlags = boolFlags ++ negations ++ argFlags;

  bashFlagList = lib.concatMapStringsSep " " (e: e.f) allFlags;
  bashArgFlagCase = lib.concatMapStringsSep "\n    " (
    e:
    let
      action =
        if e.type == "file" then
          ''COMPREPLY=( $(compgen -f -- "$cur") ); return 0''
        else if e.type == "enum" then
          ''COMPREPLY=( $(compgen -W "${lib.concatStringsSep " " e.values}" -- "$cur") ); return 0''
        else
          "return 0";
    in
    "${e.f}) ${action} ;;"
  ) argFlags;

  primaryAlias =
    if isMicrovm then
      "${agentName}-microvm"
    else if backend == "runsc" then
      "${agentName}-runsc"
    else
      "${agentName}-sandbox";

  allCmds = [
    agentName
    primaryAlias
  ];

  bashCompletes = lib.concatMapStringsSep "\n" (
    c: "complete -o default -F _${agentName}_sandbox_complete ${c}"
  ) allCmds;

  bashUpstreamCall =
    if upstreamBashFunc != null then
      ''
        _saved_upstream=()
        if declare -F ${upstreamBashFunc} >/dev/null 2>&1; then
          local _saved_compreply=("''${COMPREPLY[@]}")
          COMPREPLY=()
          ${upstreamBashFunc} "''${COMP_WORDS[0]}" "$cur" "$prev" 2>/dev/null || true
          _saved_upstream=("''${COMPREPLY[@]}")
          COMPREPLY=("''${_saved_compreply[@]}")
        fi
      ''
    else
      "_saved_upstream=()";

  bash = ''
    _${agentName}_sandbox_complete() {
      local cur prev _saved_upstream
      COMPREPLY=()
      cur="''${COMP_WORDS[COMP_CWORD]}"
      prev="''${COMP_WORDS[COMP_CWORD-1]}"

      case "$prev" in
        ${bashArgFlagCase}
      esac

      ${bashUpstreamCall}

      if [[ "$cur" == -* ]]; then
        local flags="${bashFlagList}"
        local _our=( $(compgen -W "$flags" -- "$cur") )
        COMPREPLY=( "''${_saved_upstream[@]}" "''${_our[@]}" )
        return 0
      fi

      if [ "''${#_saved_upstream[@]}" -gt 0 ]; then
        COMPREPLY=( "''${_saved_upstream[@]}" )
      else
        COMPREPLY=( $(compgen -f -- "$cur") )
      fi
      return 0
    }
    ${bashCompletes}
  '';

  zshEscape = s: lib.replaceStrings [ "[" "]" ] [ "\\[" "\\]" ] s;
  zshFlagLine =
    e:
    let
      argFlag = lib.findFirst (a: a.f == e.f) null argFlags;
      arg =
        if argFlag == null then
          ""
        else if argFlag.type == "file" then
          ":path:_files"
        else if argFlag.type == "host" then
          ":host:_hosts"
        else if argFlag.type == "enum" then
          ":value:(${lib.concatStringsSep " " argFlag.values})"
        else
          ":arg: ";
      repeat = argFlag != null && argFlag.repeat;
      prefix = if repeat then "*" else "";
    in
    "'${prefix}${e.f}[${zshEscape e.d}]${arg}'";
  zshFlagLines = lib.concatMapStringsSep " \\\n    " zshFlagLine allFlags;

  zshCompdefLine = lib.concatStringsSep " " allCmds;

  zshUpstreamCall =
    if upstreamZshFunc != null then
      ''
        if (( $+functions[${upstreamZshFunc}] )); then
          ${upstreamZshFunc} "$@"
        fi
      ''
    else
      "";

  zsh = ''
    _${agentName}_sandbox() {
      _arguments -s -S \
        ${zshFlagLines} \
        '*::args:_files' && return 0
      ${zshUpstreamCall}
    }

    _${agentName}_sandbox "$@"
  '';

  fishEscape = s: lib.replaceStrings [ "'" ] [ "\\'" ] s;
  fishLine =
    cmd: e:
    let
      long = lib.removePrefix "--" e.f;
      argFlag = lib.findFirst (a: a.f == e.f) null argFlags;
      mode =
        if argFlag == null then
          ""
        else if argFlag.type == "file" then
          " -r -F"
        else if argFlag.type == "enum" then
          " -x -a \"${lib.concatStringsSep " " argFlag.values}\""
        else
          " -x";
    in
    "complete -c ${cmd}${mode} -l ${long} -d '${fishEscape e.d}'";

  fishForCmd = cmd: lib.concatStringsSep "\n" (map (fishLine cmd) allFlags);

  fish = lib.concatStringsSep "\n\n" (map fishForCmd allCmds);

in
{
  inherit bash zsh fish;
  aliases = allCmds;
  zshCompdef = "#compdef " + zshCompdefLine;
}
