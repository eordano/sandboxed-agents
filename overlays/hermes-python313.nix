{
  pkgs,
  claudeAgent,
  codexAgent,
  opencodeAgent ? null,
  hermes-agent-src,
  uv2nix,
  pyproject-nix,
  pyproject-build-systems,
}:
let
  inherit (pkgs) lib stdenv callPackage;

  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = hermes-agent-src; };
  hacks = callPackage pyproject-nix.build.hacks { };

  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

  # Upstream requires Python >=3.11,<3.14; nixpkgs' default is already 3.14,
  # so keep the newest interpreter inside Hermes' supported range.
  python = pkgs.python313;
  isAarch64Darwin = stdenv.hostPlatform.system == "aarch64-darwin";

  mkPrebuiltPassthru = dependencies: {
    inherit dependencies;
    optional-dependencies = { };
    dependency-groups = { };
  };

  mkPrebuiltOverride =
    final: from: dependencies:
    hacks.nixpkgsPrebuilt {
      inherit from;
      prev = {
        nativeBuildInputs = [ final.pyprojectHook ];
        passthru = mkPrebuiltPassthru dependencies;
      };
    };

  missingSetuptoolsPkgs = [
    "alibabacloud-credentials-api"
    "alibabacloud-endpoint-util"
    "alibabacloud-gateway-spi"
    "alibabacloud-tea"
    "alibabacloud-gateway-dingtalk"
  ];

  setuptoolsBuildSystemFixes =
    final: prev:
    lib.genAttrs missingSetuptoolsPkgs (
      name:
      prev.${name}.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [ ])
          ++ (final.resolveBuildSystem {
            setuptools = [ ];
            wheel = [ ];
          });
      })
    );

  pythonPackageOverrides =
    final: prev:
    setuptoolsBuildSystemFixes final prev
    // {
      hermes-agent = prev.hermes-agent.overrideAttrs (_: {
        HERMES_NIX_BUILD = "1";
      });
    }
    // (
      if isAarch64Darwin then
        {
          numpy = mkPrebuiltOverride final python.pkgs.numpy { };
          av = mkPrebuiltOverride final python.pkgs.av { };
          humanfriendly = mkPrebuiltOverride final python.pkgs.humanfriendly { };

          coloredlogs = mkPrebuiltOverride final python.pkgs.coloredlogs {
            humanfriendly = [ ];
          };

          onnxruntime = mkPrebuiltOverride final python.pkgs.onnxruntime {
            coloredlogs = [ ];
            numpy = [ ];
            packaging = [ ];
          };

          ctranslate2 = mkPrebuiltOverride final python.pkgs.ctranslate2 {
            numpy = [ ];
            pyyaml = [ ];
          };

          faster-whisper = mkPrebuiltOverride final python.pkgs.faster-whisper {
            av = [ ];
            ctranslate2 = [ ];
            huggingface-hub = [ ];
            onnxruntime = [ ];
            tokenizers = [ ];
            tqdm = [ ];
          };
        }
      else
        { }
    );

  pythonSet = (callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      overlay
      pythonPackageOverrides
    ]
  );

  hermesVenv = pythonSet.mkVirtualEnv "hermes-agent-env" {
    hermes-agent = [
      "all"
      "anthropic"
    ];
  };

  bundledSkills = lib.cleanSourceWith {
    src = hermes-agent-src + "/skills";
    filter = path: _type: !(lib.hasInfix "/index-cache/" path);
  };

  claudeCompanion = pkgs.writeShellScriptBin "claude" ''
    exec ${claudeAgent}/bin/claude-achtung-achtung "$@"
  '';
  companionPath = lib.makeBinPath (
    [
      claudeCompanion
      codexAgent
    ]
    ++ lib.optional (opencodeAgent != null) opencodeAgent
  );

  runtimeDeps = with pkgs; [
    nodejs_24
    ripgrep
    git
    openssh
    ffmpeg
    tirith
  ];

  runtimePath = lib.makeBinPath runtimeDeps;

  pyprojectVersion =
    (builtins.fromTOML (builtins.readFile (hermes-agent-src + "/pyproject.toml"))).project.version;
in
stdenv.mkDerivation {
  pname = "hermes-agent";
  version = pyprojectVersion;

  dontUnpack = true;
  dontBuild = true;
  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/hermes-agent $out/bin
    cp -r ${bundledSkills} $out/share/hermes-agent/skills

    # Keep both companion commands in Hermes' runtime closure.
    test -x ${claudeCompanion}/bin/claude
    test -x ${codexAgent}/bin/codex
    ${lib.optionalString (opencodeAgent != null) "test -x ${opencodeAgent}/bin/opencode"}

    # Upstream derives its root py-modules in setup.py; make sure the wheel
    # still ships the registry, which delegate_task imports lazily only after
    # a child is spawned.
    ${hermesVenv}/bin/python -c 'from hermes_state_registry import get_shared_session_db'

    ${lib.concatMapStringsSep "\n"
      (name: ''
        makeWrapper ${hermesVenv}/bin/${name} $out/bin/${name} \
          --prefix PATH : "${companionPath}" \
          --suffix PATH : "${runtimePath}" \
          --set HERMES_BUNDLED_SKILLS $out/share/hermes-agent/skills
      '')
      [
        "hermes"
        "hermes-agent"
        "hermes-acp"
      ]
    }

    runHook postInstall
  '';

  meta = with lib; {
    description = "AI agent with advanced tool-calling capabilities";
    homepage = "https://github.com/NousResearch/hermes-agent";
    mainProgram = "hermes";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
