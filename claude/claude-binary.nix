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
  version = "2.1.268";

  platformInfo =
    {
      "x86_64-linux" = {
        platform = "linux-x64";
        sha256 = "0lsn8ah98sm1f4qj6h15crdw8zzzahpf7f7zik514rvrpnvs54cn";
      };
      "aarch64-linux" = {
        platform = "linux-arm64";
        sha256 = "0qlgihbblww7jjgs9gdzss7c474y90ndcw7ixl4ixvrrz4qx0vqi";
      };
      "aarch64-darwin" = {
        platform = "darwin-arm64";
        sha256 = "0sn7ddqwvrxp8cqa2ahj9k654whdwrc1r7w543qp0dzq4da6va86";
      };
      "x86_64-darwin" = {
        platform = "darwin-x64";
        sha256 = "1sb7vb9vwmljdvp6gspkcnpw3hl0r7krl4n9in7g4ydbn1d0sk7r";
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

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ] ++ [
    binutils-unwrapped
  ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

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
