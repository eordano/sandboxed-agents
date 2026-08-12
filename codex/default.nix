{
  pkgs,
  callPackage,
}:

let
  codex = callPackage ./codex-binary-prebuilt.nix { };
in
{
  name = "codex";
  inherit (codex) version;
  binaryDrv = codex;
  binaryRelPath = "bin/codex";

  supportsDarwin = true;
  apiBaseUrlEnvVars = [ "OPENAI_BASE_URL" ];
  configFileName = "codex-sandbox.json";
  configDir = ./config;
  sandboxHomeDest = ".codex";

  extraHomeAllow = [ ".local/share/codex" ];
  xdgRemaps = [
    {
      from = ".codex";
      to = "$XDG_CONFIG_HOME/codex";
    }
  ];

  extraEnvVars = {
    DISABLE_AUTOUPDATER = "1";
    DISABLE_TELEMETRY = "1";
  };

  nativeCompletion = {
    bash = {
      args = [
        "completion"
        "bash"
      ];
      funcName = "_codex";
    };
    zsh = {
      args = [
        "completion"
        "zsh"
      ];
      funcName = "_codex";
    };
    fish = {
      args = [
        "completion"
        "fish"
      ];
    };
  };

  sandboxInitLines = ''
    for _e in "''${EXTRA_ENVS[@]}"; do
      if [[ "$_e" == OPENAI_API_KEY=* ]]; then
        AGENT_ARGS=(-c 'model_providers.openai-key.name="OpenAI (API key)"' -c 'model_providers.openai-key.env_key="OPENAI_API_KEY"' "''${AGENT_ARGS[@]}")
        break
      fi
    done
  '';

  microvm = {
    extraGuestPackages = with pkgs; [ nodejs ];
    sandboxInitLines = ''
      mkdir -p "$HOME/.local/bin"
      ln -sf "${codex}/bin/codex" "$HOME/.local/bin/codex"
    '';
  };
}
