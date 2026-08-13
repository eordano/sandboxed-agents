{
  pkgs,
  callPackage,
  src,
}:

let
  aider = callPackage ./aider-binary.nix { inherit src; };
in
{
  name = "aider";
  inherit (aider) version;
  binaryDrv = aider;
  binaryRelPath = "bin/aider";

  supportsDarwin = true;
  apiBaseUrlEnvVars = [
    "ANTHROPIC_BASE_URL"
    "OPENAI_BASE_URL"
  ];
  configFileName = "aider-sandbox.json";
  configDir = ./config;
  sandboxHomeDest = ".aider";

  extraHomeAllow = [ ".local/share/aider" ];
  xdgRemaps = [
    {
      from = ".aider";
      to = "$XDG_CONFIG_HOME/aider";
    }
    {
      from = ".aider.conf.yml";
      to = "$XDG_CONFIG_HOME/aider/aider.conf.yml";
    }
    {
      from = ".aider.model.metadata.json";
      to = "$XDG_CONFIG_HOME/aider/aider.model.metadata.json";
    }
  ];

  extraEnvVars = {
    AIDER_ANALYTICS = "false";
    AIDER_CHECK_UPDATE = "false";
    AIDER_SHOW_RELEASE_NOTES = "false";
  };

  microvm = {
    extraGuestPackages = with pkgs; [
      python3
      git
    ];
    extraEnvVars = {
      AIDER_INPUT_HISTORY_FILE = "/tmp/.aider.input.history";
      AIDER_CHAT_HISTORY_FILE = "/tmp/.aider.chat.history.md";
    };
    sandboxInitLines = ''
      mkdir -p "$HOME/.local/bin"
      ln -sf "${aider}/bin/aider" "$HOME/.local/bin/aider"
    '';
  };
}
