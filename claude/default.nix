{
  pkgs,
  callPackage,
}:

let
  claude = callPackage ./claude-binary.nix { };
in
{
  name = "claude";
  inherit (claude) version;
  binaryDrv = claude;
  binaryRelPath = "bin/claude-achtung-achtung";

  supportsDarwin = true;
  enableYolo = true;
  apiBaseUrlEnvVars = [ "ANTHROPIC_BASE_URL" ];
  configFileName = "claude-sandbox.json";

  xdgRemaps = [
    {
      from = ".claude";
      to = "$XDG_CONFIG_HOME/claude";
    }
    {
      from = ".claude.json";
      to = "$XDG_CONFIG_HOME/claude/credentials.json";
    }
  ];

  extraEnvVars = {
    CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1";
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL = "1";
    DISABLE_AUTOUPDATER = "1";
    DISABLE_ERROR_REPORTING = "1";
    DISABLE_TELEMETRY = "1";
    DISABLE_UPGRADE_COMMAND = "1";
    # Set inside the sandbox only -- the bare claude-achtung-achtung escape
    # hatch must not claim to be sandboxed.
    IS_SANDBOX = "1";
  };

  sandboxInitLines = ''
    mkdir -p "$SANDBOX_HOME/.local/bin"
    ln -sf "@agent_binary@" "$SANDBOX_HOME/.local/bin/claude"
    if [ "$XDG_PATH_FIX" -eq 1 ]; then
      if [ -d "$HOME/.claude" ]; then
        _CLAUDE_HOME="$HOME/.claude"
      else
        _CLAUDE_HOME="$_REAL_CONFIG_HOME/claude"
      fi
    else
      _CLAUDE_HOME="$HOME/.claude"
    fi
    mkdir -p "$_CLAUDE_HOME"
    _CLAUDE_CFG="$_CLAUDE_HOME/.config.json"
    if [ -f "$_CLAUDE_CFG" ]; then
      if ! ${pkgs.jq}/bin/jq -e '.installMethod == "native"' "$_CLAUDE_CFG" >/dev/null 2>&1; then
        ${pkgs.jq}/bin/jq '.installMethod = "native" | .autoUpdates = false' "$_CLAUDE_CFG" > "$_CLAUDE_CFG.tmp" \
          && mv "$_CLAUDE_CFG.tmp" "$_CLAUDE_CFG"
      fi
    else
      echo '{"installMethod":"native","autoUpdates":false}' > "$_CLAUDE_CFG"
    fi
  '';

  microvm = {
    extraGuestPackages = with pkgs; [ nodejs ];
    sandboxInitLines = ''
      mkdir -p "$HOME/.claude" "$HOME/.local/bin"
      ln -sf "${claude}/bin/claude-achtung-achtung" "$HOME/.local/bin/claude"

      _CLAUDE_CFG="$HOME/.claude/.config.json"
      if [ ! -f "$_CLAUDE_CFG" ]; then
        echo '{"installMethod":"native","autoUpdates":false}' > "$_CLAUDE_CFG"
      fi

      if [ -f /run/env/.env ]; then
        cp /run/env/.env "$HOME/.claude/.env"
        chmod 0600 "$HOME/.claude/.env"
      fi
    '';
  };
}
