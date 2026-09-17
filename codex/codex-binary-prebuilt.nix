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
      codeModeHostAsset = "codex-code-mode-host-x86_64-unknown-linux-musl";
      codeModeHostSha256 = "sha256-po33zKI8bafN4XVnfffeYcc6I0rdEzOhJUuG1kGvAfc=";
    };
    "aarch64-linux" = {
      asset = "codex-aarch64-unknown-linux-musl";
      sha256 = "sha256-WDtI3zKAQhO9zTOMLlrbBrNDQIIfp1enJswKUk+jPCc=";
      codeModeHostAsset = "codex-code-mode-host-aarch64-unknown-linux-musl";
      codeModeHostSha256 = "sha256-IK76MCwgIrSW4ykRv5VKX3bH/XSca9ufvXEeMrZty/o=";
    };
    "x86_64-darwin" = {
      asset = "codex-x86_64-apple-darwin";
      sha256 = "sha256-EhnIN9j4E7STpCTBJcADi12coWJ5vG0/5s4Dej4Ypuc=";
      codeModeHostAsset = "codex-code-mode-host-x86_64-apple-darwin";
      codeModeHostSha256 = "sha256-oPphQeWR9E3C2GpYnP55chIxe/ufo6bHMTHk27kzh/4=";
    };
    "aarch64-darwin" = {
      asset = "codex-aarch64-apple-darwin";
      sha256 = "sha256-NEMQoKWRwbGS4E/v8wQyGmmQfJSYuqrDMcp+FuvO+dc=";
      codeModeHostAsset = "codex-code-mode-host-aarch64-apple-darwin";
      codeModeHostSha256 = "sha256-UA7ioC6lmK5RkFLn19jiAdHbAZhvMMIU70FDZF3Ib60=";
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
