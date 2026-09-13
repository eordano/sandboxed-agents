{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.154.0";

  platforms = {
    "x86_64-linux" = {
      asset = "codex-x86_64-unknown-linux-musl";
      sha256 = "sha256-1+GLJZeujyQvXzHunpDe70jbye3WNNmGj7ZDXQjAfwI=";
    };
    "aarch64-linux" = {
      asset = "codex-aarch64-unknown-linux-musl";
      sha256 = "sha256-WDtI3zKAQhO9zTOMLlrbBrNDQIIfp1enJswKUk+jPCc=";
    };
    "x86_64-darwin" = {
      asset = "codex-x86_64-apple-darwin";
      sha256 = "sha256-EhnIN9j4E7STpCTBJcADi12coWJ5vG0/5s4Dej4Ypuc=";
    };
    "aarch64-darwin" = {
      asset = "codex-aarch64-apple-darwin";
      sha256 = "sha256-NEMQoKWRwbGS4E/v8wQyGmmQfJSYuqrDMcp+FuvO+dc=";
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
