{
  lib,
  mitmproxy,
  writeShellApplication,
}:

writeShellApplication {
  name = "sandbox-privacy-proxy";
  runtimeInputs = [ mitmproxy ];
  text = ''
    listen="''${SANDBOX_PRIVACY_LISTEN:-127.0.0.1:1080}"
    exec mitmdump --mode "socks5@$listen" \
      --set connection_strategy=lazy \
      --scripts ${./scripts}/mitm_addon.py \
      "$@"
  '';
  meta = {
    description = "Opt-in, fail-open PII pseudonymizing proxy for sandboxed AI agents";
    license = lib.licenses.mit;
    mainProgram = "sandbox-privacy-proxy";
    platforms = lib.platforms.unix;
  };
}
