{
  lib,
  pkgs,
  callPackage,
  src,
  cccp ? null,
}:

let
  opencode = callPackage ./opencode-binary.nix { inherit src; };
  seedCccpPlugin =
    configHome:
    lib.optionalString (cccp != null) ''
      _CCCP_PLUGIN_SRC="${cccp}/share/cccp/plugin/opencode/cccp.js"
      _CCCP_PLUGIN_DST="${configHome}/opencode/plugin/cccp.js"
      if [ -f "$_CCCP_PLUGIN_SRC" ]; then
        if [ ! -e "$_CCCP_PLUGIN_DST" ] || ${pkgs.gnugrep}/bin/grep -q '^// @cccp-plugin opencode' "$_CCCP_PLUGIN_DST"; then
          if ! ${pkgs.diffutils}/bin/cmp -s "$_CCCP_PLUGIN_SRC" "$_CCCP_PLUGIN_DST" 2>/dev/null; then
            mkdir -p "$(dirname "$_CCCP_PLUGIN_DST")"
            cp "$_CCCP_PLUGIN_SRC" "$_CCCP_PLUGIN_DST" && chmod u+w "$_CCCP_PLUGIN_DST"
          fi
        else
          echo "Warning: $_CCCP_PLUGIN_DST is not the cccp plugin; leaving it alone, so cccp will not record this opencode session." >&2
        fi
      fi
    '';
in
{
  name = "opencode";
  inherit (opencode) version;
  binaryDrv = opencode;
  binaryRelPath = "bin/opencode";

  supportsDarwin = true;
  apiBaseUrlEnvVars = [
    "ANTHROPIC_BASE_URL"
    "OPENAI_BASE_URL"
  ];
  configFileName = "opencode-sandbox.json";
  configDir = ./config;
  sandboxHomeDest = ".config/opencode";

  extraHomeAllow = [
    ".opencode"
    ".config/opencode"
    ".local/share/opencode"
  ];

  extraEnvVars = {
    DISABLE_AUTOUPDATER = "1";
    DISABLE_TELEMETRY = "1";
  };

  extraSandboxPackages = lib.optional (cccp != null) cccp;

  argvGuardLines = ''
    if [ ''${#AGENT_ARGS[@]} -eq 0 ] && [ ! -t 0 ] && [ -z "$START_SHELL" ] && [ -z "$DRY_RUN" ]; then
      echo "opencode: no subcommand and stdin is not a terminal, so the TUI cannot run; an ACP harness must invoke 'opencode acp' (Buzz: set the agent's runtime to opencode)." >&2
      exit 2
    fi
  '';

  sandboxInitLines = seedCccpPlugin "$_REAL_CONFIG_HOME";

  microvm = {
    extraGuestPackages = with pkgs; [ nodejs ] ++ lib.optional (cccp != null) cccp;
    sandboxInitLines = ''
      mkdir -p "$HOME/.local/bin"
      ln -sf "${opencode}/bin/opencode" "$HOME/.local/bin/opencode"
      ${seedCccpPlugin "$HOME/.config"}
    '';
  };
}
