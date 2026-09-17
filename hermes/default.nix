{
  pkgs,
  hermes-agent,
  cccp ? null,
}:

let
  inherit (pkgs) lib;
  cccpPlugin = "${cccp}/share/cccp/plugin/hermes";
  cccpEnabledWarning = cfg: ''
    if [ -f "${cfg}" ] && ! grep -qw cccp "${cfg}"; then
      echo "Warning: ${cfg} does not list cccp under plugins.enabled; run 'hermes plugins enable cccp' inside the sandbox to sync transcripts with cccp." >&2
    fi
  '';
  cccpLinkLines = home: ''
    _cccp_plugin="${home}/plugins/cccp"
    mkdir -p "${home}/plugins"
    if [ -L "$_cccp_plugin" ] || [ ! -e "$_cccp_plugin" ] || rmdir "$_cccp_plugin" 2>/dev/null; then
      ln -sfn "${cccpPlugin}" "$_cccp_plugin"
    fi
  '';
in
{
  name = "hermes";
  inherit (hermes-agent) version;
  binaryDrv = hermes-agent;
  binaryRelPath = "bin/hermes";

  supportsDarwin = true;
  apiBaseUrlEnvVars = [ "ANTHROPIC_BASE_URL" ];
  configFileName = "hermes-sandbox.json";
  configDir = ./config;
  sandboxHomeDest = ".hermes";

  extraHomeAllow = [ ".local/share/hermes" ];
  xdgRemaps = [
    {
      from = ".hermes";
      to = "$XDG_CONFIG_HOME/hermes";
    }
  ];

  extraEnvVars = {
    DISABLE_AUTOUPDATER = "1";
    DISABLE_TELEMETRY = "1";
  };

  extraSandboxPackages = lib.optional (cccp != null) cccp;

  sandboxInitLines = lib.optionalString (cccp != null) ''
    if [ -d "${cccpPlugin}" ]; then
      if [ "$(uname -s)" = Darwin ]; then
        ${cccpLinkLines "$HOME/.hermes"}
      else
        EXTRA_MOUNTS+=( "${cccpPlugin}:$HOME/.hermes/plugins/cccp" )
      fi
      ${cccpEnabledWarning "$HOME/.hermes/config.yaml"}
      ${cccpEnabledWarning "$_REAL_CONFIG_HOME/hermes/config.yaml"}
    fi
  '';

  microvm = {
    extraGuestPackages = with pkgs; [
      nodejs
      python3
    ];
    extraEnvVars = {
      HERMES_MANAGED = "true";
      HERMES_INTERACTIVE = "1";
      HERMES_REDACT_SECRETS = "1";
      TERMINAL_ENV = "local";
    };
    sandboxInitLines = ''
      export HERMES_HOME="$HOME/.hermes"
      export MESSAGING_CWD="$WORKDIR"
      export TERMINAL_CWD="$WORKDIR"
      export HERMES_SESSION_SOURCE="cli"

      mkdir -p "$HERMES_HOME/bin" "$HERMES_HOME/mcp-tokens" \
               "$HERMES_HOME/skills" "$HERMES_HOME/memories" \
               "$HERMES_HOME/cron" "$HERMES_HOME/sessions" \
               "$HOME/.local/bin"
      ln -sf "${hermes-agent}/bin/hermes" "$HERMES_HOME/bin/hermes"
      ln -sf "${hermes-agent}/bin/hermes" "$HOME/.local/bin/hermes"

      touch "$HERMES_HOME/.managed"

      if [ -f /run/env/.env ]; then
        cp /run/env/.env "$HERMES_HOME/.env"
        chmod 0600 "$HERMES_HOME/.env"
      fi

      ${lib.optionalString (cccp != null) ''
        if [ -d "${cccpPlugin}" ]; then
          ${cccpLinkLines "$HERMES_HOME"}
          ${cccpEnabledWarning "$HERMES_HOME/config.yaml"}
        fi
      ''}
    '';
  };
}
