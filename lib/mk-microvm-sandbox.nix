{
  lib,
  pkgs,
  microvm,
  agentName,
  version,
  agentBinaryDrv,
  agentBinaryRelPath,
  configFileName ? "${agentName}-sandbox.json",
  extraEnvVars ? { },
  extraGuestPackages ? [ ],
  configDir ? null,
  sandboxHomeDest ? ".${agentName}",
  sandboxInitLines ? "",
  xdgRemaps ? [ ],
  enableYolo ? false,
  enableEscapeHatch ? true,
  pname ? "${agentName}-microvm",
  nativeCompletion ? null,
}:

let
  data = import ./data.nix;
  mountBase = "/tmp/microvm-${agentName}";

  commonToolHomeAllowBlock = builtins.concatStringsSep "\n" data.commonToolHomeAllow;
  cacheDirsBlock = builtins.concatStringsSep "\n" data.cacheDirs;

  blocks = import ./shell-blocks.nix {
    inherit
      lib
      configFileName
      sandboxHomeDest
      xdgRemaps
      enableYolo
      ;
    inherit (pkgs) jq;
  };

  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  useVirtiofs = !isDarwin;
  guestSystem = if isDarwin then "aarch64-linux" else pkgs.stdenv.hostPlatform.system;
  guestPkgs = if isDarwin then import pkgs.path { system = guestSystem; } else pkgs;

  vmSystem = lib.nixosSystem {
    system = guestSystem;
    modules = [
      microvm.nixosModules.microvm
      (import ./microvm-guest.nix {
        inherit
          lib
          agentName
          agentBinaryDrv
          agentBinaryRelPath
          mountBase
          extraGuestPackages
          extraEnvVars
          configDir
          sandboxHomeDest
          sandboxInitLines
          useVirtiofs
          ;
      })
      { nixpkgs.pkgs = guestPkgs; }
    ];
  };

  vmRunnerDir = "${vmSystem.config.microvm.runner.qemu}";

  launcher = import ./microvm-launcher.nix {
    inherit lib;
    inherit (pkgs)
      writeShellScript
      coreutils
      gnused
      util-linux
      socat
      ;
    virtiofsd = if useVirtiofs then pkgs.virtiofsd else null;
    inherit
      agentName
      configFileName
      vmRunnerDir
      mountBase
      commonToolHomeAllowBlock
      cacheDirsBlock
      xdgRemaps
      enableYolo
      useVirtiofs
      isDarwin
      ;
    inherit (blocks) configParseBlock yoloInjectionBlock mkBackendDispatch;
  };

  allowDirScript = pkgs.writeShellScript "${agentName}-allow-dir" ''
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/${configFileName}"

    if [ ! -f "$CONFIG_FILE" ]; then
      mkdir -p "$(dirname "$CONFIG_FILE")"
      echo '{"paths":[],"homePatterns":[]}' > "$CONFIG_FILE"
    fi

    DIR="$(pwd)"

    if ${pkgs.jq}/bin/jq -e --arg dir "$DIR" '
      (.paths // []) | index($dir) != null
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "Directory already allowed: $DIR"; exit 0
    fi

    ${pkgs.jq}/bin/jq --arg dir "$DIR" '.paths += [$dir]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" \
      && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "Added to allowed paths: $DIR"
  '';

  canRunBinary = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
  mkUpstreamCompletion =
    shell: cfg:
    pkgs.runCommand "${agentName}-upstream-${shell}" { } ''
      set -e
      export ${
        lib.concatStringsSep " " (
          lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") (cfg.envVars or { })
        )
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
  catMany = lib.concatStringsSep " ";

  completions = import ./completions.nix {
    inherit lib agentName enableYolo;
    backend = "microvm";
    upstreamBashFunc = if hasUpstream "bash" then nativeCompletion.bash.funcName or null else null;
    upstreamZshFunc = if hasUpstream "zsh" then nativeCompletion.zsh.funcName or null else null;
  };
  bashCompletionFile = pkgs.writeTextFile {
    name = "${agentName}.bash";
    text = completions.bash;
  };
  zshCompletionFile = pkgs.writeTextFile {
    name = "_${agentName}";
    text = completions.zsh;
  };
  fishCompletionFile = pkgs.writeTextFile {
    name = "${agentName}.fish";
    text = completions.fish;
  };

  forgetDirScript = pkgs.writeShellScript "${agentName}-forget-dir" ''
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/${configFileName}"

    if [ ! -f "$CONFIG_FILE" ]; then
      echo "No config file at: $CONFIG_FILE"; exit 0
    fi

    DIR="$(pwd)"

    if ! ${pkgs.jq}/bin/jq -e --arg dir "$DIR" '
      (.paths // []) | index($dir) != null
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "Directory not in allowed list: $DIR"; exit 0
    fi

    ${pkgs.jq}/bin/jq --arg dir "$DIR" '
      .paths |= map(select(. != $dir))
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "Removed from allowed paths: $DIR"
  '';

in
pkgs.stdenv.mkDerivation {
  inherit pname version;

  phases = [ "installPhase" ];

  nativeBuildInputs = [ pkgs.installShellFiles ];

  installPhase = ''
    mkdir -p $out/bin

    cp ${launcher} $out/bin/${agentName}
    chmod +x $out/bin/${agentName}

    ln -s $out/bin/${agentName} $out/bin/${agentName}-microvm

    cp ${allowDirScript}     $out/bin/${agentName}-allow-dir
    cp ${forgetDirScript}    $out/bin/${agentName}-forget-dir
    chmod +x $out/bin/${agentName}-allow-dir \
             $out/bin/${agentName}-forget-dir

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
    description = "MicroVM-sandboxed ${agentName} environment";
    license = licenses.mit;
    mainProgram = agentName;
    platforms = platforms.linux ++ [ "aarch64-darwin" ];
  };
}
