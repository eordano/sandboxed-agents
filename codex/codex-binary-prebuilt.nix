{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.156.1";

  platforms = {
    "x86_64-linux" = {
      asset = "codex-x86_64-unknown-linux-musl";
      sha256 = "sha256-r/RlOag6/4bjxixZK84sUNlTkfnfKJr68DpQwB0UUz0=";
      codeModeHostAsset = "codex-code-mode-host-x86_64-unknown-linux-musl";
      codeModeHostSha256 = "sha256-qSnaqfagvdwAwMnmQC3xF7ElrNlvnVVPbJnDLH5mxgg=";
    };
    "aarch64-linux" = {
      asset = "codex-aarch64-unknown-linux-musl";
      sha256 = "sha256-VY4SqqbayzNexHJAv5ch24pUdGgG1k8BGFpAP0T3m3I=";
      codeModeHostAsset = "codex-code-mode-host-aarch64-unknown-linux-musl";
      codeModeHostSha256 = "sha256-QBmBOLA3mP+owNpMgnqMpYlndOoQS3EQwqLAx1YMvpQ=";
    };
    "x86_64-darwin" = {
      asset = "codex-x86_64-apple-darwin";
      sha256 = "sha256-VeNFht7lNyDdlEUQImMv/8njtVskcVrN2UU/01ZqVN8=";
      codeModeHostAsset = "codex-code-mode-host-x86_64-apple-darwin";
      codeModeHostSha256 = "sha256-/JaNnnIS1/ux4VRtKDbzsHxfOIEJwFuEKMHz8wkdcgk=";
    };
    "aarch64-darwin" = {
      asset = "codex-aarch64-apple-darwin";
      sha256 = "sha256-K9ZK8U3t1HeV8va/1dElz3kZmswse6IiFE4IEnERpco=";
      codeModeHostAsset = "codex-code-mode-host-aarch64-apple-darwin";
      codeModeHostSha256 = "sha256-JiXQI+K24D0rzEN6Pg4IMcJdPHItKFRjio50kh/3m9k=";
    };
  };

  plat =
    platforms.${stdenv.hostPlatform.system}
      or (throw "codex prebuilt: unsupported system ${stdenv.hostPlatform.system}");

  assetUrl =
    asset: "https://github.com/openai/codex/releases/download/rust-v${version}/${asset}.tar.gz";

in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  srcs = [
    (fetchurl {
      url = assetUrl plat.asset;
      inherit (plat) sha256;
    })
    (fetchurl {
      url = assetUrl plat.codeModeHostAsset;
      sha256 = plat.codeModeHostSha256;
    })
  ];

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;
  dontPatchELF = true;

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 ${plat.asset} $out/bin/codex
    install -Dm755 ${plat.codeModeHostAsset} $out/bin/codex-code-mode-host
    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenAI codex CLI (prebuilt static binary from upstream releases)";
    homepage = "https://github.com/openai/codex";
    license = licenses.asl20;
    mainProgram = "codex";
    platforms = lib.attrNames platforms;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
