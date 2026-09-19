{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.155.1";

  platforms = {
    "x86_64-linux" = {
      asset = "codex-x86_64-unknown-linux-musl";
      sha256 = "sha256-oO+LLevDv3R+B7GgOTVN4xMArA3MInZJi6KBRwtdkRU=";
      codeModeHostAsset = "codex-code-mode-host-x86_64-unknown-linux-musl";
      codeModeHostSha256 = "sha256-n9CDdDr1W+gYrOs1HTcftRNvW2qjk48WcIc3PScGey0=";
    };
    "aarch64-linux" = {
      asset = "codex-aarch64-unknown-linux-musl";
      sha256 = "sha256-1sfmL71ojVLuBPOSnQYTcF0yqSCkLbehOeNm6vH0otc=";
      codeModeHostAsset = "codex-code-mode-host-aarch64-unknown-linux-musl";
      codeModeHostSha256 = "sha256-UW8u121K6WwgdNPAj0V27RvcXDqX4mc01zGd6LaGFoM=";
    };
    "x86_64-darwin" = {
      asset = "codex-x86_64-apple-darwin";
      sha256 = "sha256-/yKtC/KLhWjb+yjvDqZEUf5RcPoPkRi/dkymyyTCd5E=";
      codeModeHostAsset = "codex-code-mode-host-x86_64-apple-darwin";
      codeModeHostSha256 = "sha256-TR0jd6OYQsE/oHxw4t3RWS/07cSEbPMs6Q3wf1VoBmo=";
    };
    "aarch64-darwin" = {
      asset = "codex-aarch64-apple-darwin";
      sha256 = "sha256-XlpRRw3OJCP52WvRkdC7xMwOKEimgz31F46vR6B6N2g=";
      codeModeHostAsset = "codex-code-mode-host-aarch64-apple-darwin";
      codeModeHostSha256 = "sha256-6JVxCO69cJY7CQaFfOt/eitHfRlypxRwQcYl1AcbUIo=";
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
