{
  pkgs,
  hermes-agent,
}:

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
    '';
  };
}
