{
  pkgs,
  lib,
  callPackage,
  cccp ? null,
}:

let
  codex = callPackage ./codex-binary-prebuilt.nix { };
  cccpHooks = "${cccp}/share/cccp/plugin/codex/hooks.json";
  cccpHookLines = home: ''
    if [ -f "${cccpHooks}" ]; then
      mkdir -p "${home}/cccp"
      _CODEX_HOOKS="${home}/hooks.json"
      if [ ! -e "$_CODEX_HOOKS" ]; then
        cp "${cccpHooks}" "$_CODEX_HOOKS" && chmod u+w "$_CODEX_HOOKS"
      elif ${pkgs.gnugrep}/bin/grep -q 'cccp watch hook-start --agent codex' "$_CODEX_HOOKS"; then
        ${pkgs.diffutils}/bin/cmp -s "${cccpHooks}" "$_CODEX_HOOKS" || { cp "${cccpHooks}" "$_CODEX_HOOKS" && chmod u+w "$_CODEX_HOOKS"; }
      else
        echo "Warning: $_CODEX_HOOKS is not the cccp hooks file; leaving it alone, so cccp will not record codex sessions." >&2
      fi
    fi
  '';
in
{
  name = "codex";
  inherit (codex) version;
  binaryDrv = codex;
  binaryRelPath = "bin/codex";

  extraBinaries = [ "codex-code-mode-host" ];
  extraSandboxPackages = lib.optional (cccp != null) cccp;

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
  ''
  + lib.optionalString (cccp != null) ''
    if [ "$XDG_PATH_FIX" -eq 1 ] && [ ! -d "$HOME/.codex" ]; then
      _CODEX_HOME="$_REAL_CONFIG_HOME/codex"
    else
      _CODEX_HOME="$HOME/.codex"
    fi
    mkdir -p "$_CODEX_HOME"
    ${cccpHookLines "$_CODEX_HOME"}
  '';

  microvm = {
    extraGuestPackages = with pkgs; [ nodejs ];
    sandboxInitLines = ''
      mkdir -p "$HOME/.local/bin"
      ln -sf "${codex}/bin/codex" "$HOME/.local/bin/codex"
      ln -sf "${codex}/bin/codex-code-mode-host" "$HOME/.local/bin/codex-code-mode-host"
    ''
    + lib.optionalString (cccp != null) ''
      mkdir -p "$HOME/.codex"
      ${cccpHookLines "$HOME/.codex"}
    '';
  };
}
