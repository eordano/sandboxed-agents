{
  pkgs,
  callPackage,
  src,
  fetchNpmDeps,
}:

let
  gemini-cli = callPackage ./gemini-binary.nix { inherit src fetchNpmDeps; };
in
{
  name = "gemini";
  inherit (gemini-cli) version;
  binaryDrv = gemini-cli;
  binaryRelPath = "bin/gemini";

  supportsDarwin = true;
  apiBaseUrlEnvVars = [ "GOOGLE_GEMINI_BASE_URL" ];
  configFileName = "gemini-sandbox.json";
  configDir = ./config;
  sandboxHomeDest = ".gemini";

  extraHomeAllow = [ ".local/share/gemini" ];
  xdgRemaps = [
    {
      from = ".gemini";
      to = "$XDG_CONFIG_HOME/gemini";
    }
  ];

  extraEnvVars = {
    GEMINI_TELEMETRY_OPT_OUT = "1";
  };

  microvm = {
    extraGuestPackages = with pkgs; [ python3 ];
    sandboxInitLines = ''
      mkdir -p "$HOME/.local/bin" "$HOME/.gemini"
      ln -sf "${gemini-cli}/bin/gemini" "$HOME/.local/bin/gemini"
    '';
  };
}
