{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.147.0";

  platforms = {
    "x86_64-linux" = {
      asset = "codex-x86_64-unknown-linux-musl";
      sha256 = "sha256-Akbi53ODTgfw+1JJ7W660S5FkeYI+Me7l91qlpBUTDY=";
    };
    "aarch64-linux" = {
      asset = "codex-aarch64-unknown-linux-musl";
      sha256 = "sha256-62d8gPZmsauLSx0IO2bo1hSxKB2WC7b5/Yypj1izi5A=";
    };
    "x86_64-darwin" = {
      asset = "codex-x86_64-apple-darwin";
      sha256 = "sha256-NueC9x2BZMw3wricZJSPIYDpovhFayfmYNp1vGtVdOI=";
    };
    "aarch64-darwin" = {
      asset = "codex-aarch64-apple-darwin";
      sha256 = "sha256-dZhLgfkqcbDA9LO1ytgOXFcXfk2Mi0seE9twOyDcQ1g=";
    };
  };

  plat =
    platforms.${stdenv.hostPlatform.system}
      or (throw "codex prebuilt: unsupported system ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${version}/${plat.asset}.tar.gz";
    inherit (plat) sha256;
  };

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;
  dontPatchELF = true;

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 ${plat.asset} $out/bin/codex
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
