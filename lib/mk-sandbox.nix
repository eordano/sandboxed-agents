{
  lib,
  stdenv,
  writeShellScript,
  writeText,
  writeTextFile,
  installShellFiles,
  runCommand ? null,
  cacert,
  jq,
  bubblewrap ? null,
  gvisor ? null,
  coreutils ? null,
  bash ? null,
  tun2socks ? null,
  slirp4netns ? null,
  iproute2 ? null,
  iptables ? null,
  util-linux ? null,
  python3 ? null,
  backend ? "bwrap",
  agentName,
  version,
  agentBinaryDrv,
  agentBinaryRelPath,
  extraHomeAllow ? [ ],
  configFileName ? "${agentName}-sandbox.json",
  sandboxInitLines ? "",
  extraEnvVars ? { },
  enableYolo ? false,
  xdgRemaps ? [ ],
  configDir ? null,
  sandboxHomeDest ? ".${agentName}",
  supportsDarwin ? false,
  apiBaseUrlEnvVars ? [ ],
  enableEscapeHatch ? true,
  pname ? "${agentName}-sandbox",
  nativeCompletion ? null,
}:

let
  blocks = import ./shell-blocks.nix {
    inherit
      lib
      jq
      configFileName
      configDir
      sandboxHomeDest
      xdgRemaps
      extraEnvVars
      extraHomeAllow
      enableYolo
      ;
  };

  runscBundle =
    if backend == "runsc" then
      (import ./runsc-bundle.nix {
        inherit
          writeText
          runCommand
          coreutils
          bash
          cacert
          ;
      }).mkBundle
        {
          inherit agentName;
        }
    else
      null;

  sandboxWrapper =
    let
      sharedArgs = {
        inherit
          writeShellScript
          writeText
          cacert
          agentName
          configFileName
          sandboxInitLines
          enableYolo
          ;
        inherit (blocks)
          homeAllowBlock
          mountGroupBlock
          configParseBlock
          yoloInjectionBlock
          extraHomeDirCreateBlock
          xdgRemapBlock
          configDeployLines
          mkBackendDispatch
          ;
      };
    in
    if stdenv.isDarwin && supportsDarwin then
      import ./sandbox-darwin.nix (
        sharedArgs
        // {
          inherit
            lib
            jq
            sandboxHomeDest
            xdgRemaps
            ;
          extraEnvLines = blocks.darwinExtraEnvLines;
        }
      )
    else if backend == "runsc" then
      import ./sandbox-linux.nix (
        sharedArgs
        // {
          inherit
            jq
            gvisor
            tun2socks
            slirp4netns
            iproute2
            iptables
            util-linux
            python3
            apiBaseUrlEnvVars
            ;
          backend = "runsc";
          bundle = runscBundle;
          extraEnvLines = blocks.linuxExtraEnvLines;
        }
      )
    else
      import ./sandbox-linux.nix (
        sharedArgs
        // {
          inherit
            jq
            bubblewrap
            tun2socks
            slirp4netns
            iproute2
            iptables
            util-linux
            python3
            apiBaseUrlEnvVars
            ;
          backend = "bwrap";
          extraEnvLines = blocks.linuxExtraEnvLines;
        }
      );

  allowDirScript = writeShellScript "${agentName}-allow-dir" ''
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/${configFileName}"

    if [ ! -f "$CONFIG_FILE" ]; then
      mkdir -p "$(dirname "$CONFIG_FILE")"
      echo '{"paths":[],"homePatterns":[]}' > "$CONFIG_FILE"
    fi

    DIR="$(pwd)"

    if ${jq}/bin/jq -e --arg dir "$DIR" '
      (.paths // []) | index($dir) != null
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "Directory already allowed: $DIR"; exit 0
    fi

    ${jq}/bin/jq --arg dir "$DIR" '.paths += [$dir]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" \
      && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "Added to allowed paths: $DIR"
  '';

  completionsBackend = if stdenv.isDarwin && supportsDarwin then "darwin" else backend;

  canRunBinary = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

  mkUpstreamCompletion =
    shell: cfg:
    runCommand "${agentName}-upstream-${shell}" { } ''
      set -e
      ${lib.optionalString (cfg.envVars or { } != { })
        "export ${
          lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") cfg.envVars)
        }"
      }
      if ${agentBinaryDrv}/${agentBinaryRelPath} ${lib.escapeShellArgs cfg.args} > "$out" 2>/dev/null; then
        :
      else
        echo "# upstream completion generation failed for ${agentName} (${shell})" > "$out"
      fi
    '';

  hasUpstream = shell: canRunBinary && nativeCompletion != null && (nativeCompletion ? ${shell});

  upstreamBash = lib.optional (hasUpstream "bash") (
    mkUpstreamCompletion "bash" nativeCompletion.bash
  );
  upstreamZsh = lib.optional (hasUpstream "zsh") (mkUpstreamCompletion "zsh" nativeCompletion.zsh);
  upstreamFish = lib.optional (hasUpstream "fish") (
    mkUpstreamCompletion "fish" nativeCompletion.fish
  );

  completions = import ./completions.nix {
    inherit lib agentName enableYolo;
    backend = completionsBackend;
    upstreamBashFunc = if hasUpstream "bash" then nativeCompletion.bash.funcName or null else null;
    upstreamZshFunc = if hasUpstream "zsh" then nativeCompletion.zsh.funcName or null else null;
  };

  bashCompletionFile = writeTextFile {
    name = "${agentName}.bash";
    text = completions.bash;
  };
  zshCompletionFile = writeTextFile {
    name = "_${agentName}";
    text = completions.zsh;
  };
  fishCompletionFile = writeTextFile {
    name = "${agentName}.fish";
    text = completions.fish;
  };

  catMany = lib.concatStringsSep " ";

  forgetDirScript = writeShellScript "${agentName}-forget-dir" ''
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/${configFileName}"

    if [ ! -f "$CONFIG_FILE" ]; then
      echo "No config file at: $CONFIG_FILE"; exit 0
    fi

    DIR="$(pwd)"

    if ! ${jq}/bin/jq -e --arg dir "$DIR" '
      (.paths // []) | index($dir) != null
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "Directory not in allowed list: $DIR"; exit 0
    fi

    ${jq}/bin/jq --arg dir "$DIR" '
      .paths |= map(select(. != $dir))
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "Removed from allowed paths: $DIR"
  '';

in
stdenv.mkDerivation {
  inherit pname version;

  phases = [ "installPhase" ];

  # No buildInputs: the wrapper references every tool by interpolated store
  # path, which already pins the runtime closure.
  nativeBuildInputs = [ installShellFiles ];

  installPhase = ''
    mkdir -p $out/bin

    cp ${sandboxWrapper} $out/bin/${agentName}
    chmod +x $out/bin/${agentName}
    substituteInPlace $out/bin/${agentName} \
      --replace-fail '@agent_binary@' '${agentBinaryDrv}/${agentBinaryRelPath}'

    ln -s $out/bin/${agentName} $out/bin/${agentName}-${
      if backend == "runsc" then "runsc" else "sandbox"
    }

    cp ${allowDirScript}    $out/bin/${agentName}-allow-dir
    cp ${forgetDirScript}   $out/bin/${agentName}-forget-dir
    chmod +x $out/bin/${agentName}-allow-dir \
             $out/bin/${agentName}-forget-dir

    ${lib.optionalString (configDir != null) ''
      mkdir -p $out/share/${agentName}-config
      cp -r ${configDir}/. $out/share/${agentName}-config/
    ''}

    mkdir -p $out/share/doc/${agentName}-sandbox
    cp ${../README.md} $out/share/doc/${agentName}-sandbox/README.md

    mkdir -p _comp
    cat ${catMany upstreamBash} ${bashCompletionFile} > _comp/${agentName}.bash
    {
      echo '${completions.zshCompdef}'
      ${lib.optionalString (upstreamZsh != [ ]) ''
        awk '/^if \[ "\$funcstack\[1\]"/ { exit } { print }' ${catMany upstreamZsh} \
          | grep -v '^#compdef'
      ''}
      grep -v '^#compdef' ${zshCompletionFile}
    } > _comp/_${agentName}
    cat ${catMany upstreamFish} ${fishCompletionFile} > _comp/${agentName}.fish

    installShellCompletion --cmd ${agentName} \
      --bash _comp/${agentName}.bash \
      --zsh _comp/_${agentName} \
      --fish _comp/${agentName}.fish

    ${lib.optionalString enableEscapeHatch ''
      ln -s ${agentBinaryDrv}/${agentBinaryRelPath} $out/bin/${agentName}-achtung-achtung
    ''}
  '';

  meta = with lib; {
    description = "Sandboxed ${agentName} environment";
    license = licenses.mit;
    mainProgram = agentName;
    platforms =
      if supportsDarwin then
        [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ]
      else
        platforms.linux;
  };
}
