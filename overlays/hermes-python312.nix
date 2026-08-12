{
  pkgs,
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

  python = pkgs.python312;
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

  # Upstream's [all] deliberately excludes provider extras (they pip-install
  # lazily at first use, which cannot work in an immutable Nix venv inside a
  # network-restricted sandbox); bundle the Anthropic provider explicitly.
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

    ${lib.concatMapStringsSep "\n"
      (name: ''
        makeWrapper ${hermesVenv}/bin/${name} $out/bin/${name} \
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
