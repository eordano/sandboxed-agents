{
  lib,
  stdenv,
  fetchurl,
  writeShellScript,
  cacert,
  binutils-unwrapped,
  autoPatchelfHook ? null,
}:

let
  version = "2.1.228";

  platformInfo =
    {
      "x86_64-linux" = {
        platform = "linux-x64";
        sha256 = "16acm624ylg6qkmii9850cx65imhrr97zkcw2w0fp8s1d5g9hdfm";
      };
      "aarch64-linux" = {
        platform = "linux-arm64";
        sha256 = "0hpr65w3xf6a9r1nz9mjrrjdlbnlki8mccf4381gfys935i00r16";
      };
      "aarch64-darwin" = {
        platform = "darwin-arm64";
        sha256 = "0ivj9dwpp1c7w4y33fbacjnilnvm6w2fydkg6h43mw6fa89lnj23";
      };
      "x86_64-darwin" = {
        platform = "darwin-x64";
        sha256 = "1cq9vj545wykgckadvcanpzsdi6xv998hzd5fxnx8r7v1spg2lkq";
      };
    }
    .${stdenv.hostPlatform.system} or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";

  claudeWrapper = writeShellScript "claude-achtung-achtung" ''
    export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export NIX_SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export CURL_CA_BUNDLE="${cacert}/etc/ssl/certs/ca-bundle.crt"

    if [ -n "''${ANTHROPIC_API_KEY:-}" ] && [ -z "''${CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR:-}" ]; then
      __KEY="$ANTHROPIC_API_KEY"
      unset ANTHROPIC_API_KEY
      __KEYFILE=$(mktemp)
      printf %s "$__KEY" > "$__KEYFILE"
      unset __KEY
      export CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR=3
      exec 3<"$__KEYFILE"
      rm -f "$__KEYFILE"
      exec @claude_native@ "$@"
    fi

    exec @claude_native@ "$@"
  '';

in
stdenv.mkDerivation {
  pname = "claude-native";
  inherit version;

  src = fetchurl {
    url = "${gcsBase}/${version}/${platformInfo.platform}/claude";
    inherit (platformInfo) sha256;
  };

  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;

  nativeBuildInputs = lib.optionals stdenv.isLinux [ autoPatchelfHook ] ++ [ binutils-unwrapped ];
  buildInputs = lib.optionals stdenv.isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/claude-native
    chmod +x $out/bin/claude-native

    if [ "$(strings $out/bin/claude-native | grep -cxF '${version}')" -eq 0 ]; then
      echo "ERROR: claude binary does not contain version string '${version}'." >&2
      echo "       The declared sha256 probably points at an older release's bytes." >&2
      echo "       Run claude/update.sh (or bump hashes alongside the version)." >&2
      exit 1
    fi

    cp ${claudeWrapper} $out/bin/claude-achtung-achtung
    chmod +x $out/bin/claude-achtung-achtung
    substituteInPlace $out/bin/claude-achtung-achtung \
      --replace-fail '@claude_native@' "$out/bin/claude-native"
  '';
}
