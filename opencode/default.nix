{
  pkgs,
  callPackage,
  src,
}:

let
  opencode = callPackage ./opencode-binary.nix { inherit src; };
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

  microvm = {
    extraGuestPackages = with pkgs; [ nodejs ];
    sandboxInitLines = ''
      mkdir -p "$HOME/.local/bin"
      ln -sf "${opencode}/bin/opencode" "$HOME/.local/bin/opencode"
    '';
  };
}
