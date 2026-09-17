{
  nixpkgs,
  opencode-src,
  gemini-src,
  hermes-agent,
  microvm,
  cccp ? null,
}:
let
  hermes-agent-inputs = {
    src = hermes-agent;
    inherit (hermes-agent.inputs) uv2nix pyproject-nix pyproject-build-systems;
  };
  gvisorFix = import ./gvisor-go126-fix.nix;
  flakeLib = nixpkgs.lib;

  backends = [
    "bwrap"
    "microvm"
    "runsc"
  ];
  allAgents = [
    "claude"
    "hermes"
    "opencode"
    "codex"
    "gemini"
  ];
  linuxSystems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  agentSrcs = {
    opencode = opencode-src;
    gemini = gemini-src;
  };
in
final: prev:
let
  inherit (final) lib;
  inherit (final.stdenv.hostPlatform) system;
  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = lib.elem system linuxSystems;

  defaultBackend = if isLinux then "runsc" else "bwrap";
  variantName = backend: name: if backend == defaultBackend then name else "${name}-${backend}";
  backendsForSystem =
    if isLinux then
      backends
    else if system == "aarch64-darwin" then
      [
        "bwrap"
        "microvm"
      ]
    else
      [ "bwrap" ];
  agentsForBackendSystem =
    backend:
    lib.subtractLists (lib.optional (system == "x86_64-darwin") "opencode") (
      if backend == "microvm" && isDarwin then [ "claude" ] else allAgents
    );

  specExtraArgs =
    name:
    lib.optionalAttrs (name == "hermes") {
      # Upstream Hermes requires Python <3.14, so its package overlay pins 3.13.
      hermes-agent = final.callPackage ./hermes-python313.nix {
        claudeAgent = final.callPackage ../claude/claude-binary.nix { };
        codexAgent = final.callPackage ../codex/codex-binary-prebuilt.nix { };
        opencodeAgent =
          if system == "x86_64-darwin" then
            null
          else
            final.callPackage ../opencode/opencode-binary.nix { src = opencode-src; };
        hermes-agent-src = hermes-agent-inputs.src;
        inherit (hermes-agent-inputs) uv2nix pyproject-nix pyproject-build-systems;
      };
    }
    // lib.optionalAttrs (agentSrcs ? ${name}) { src = agentSrcs.${name}; };

  cccpPackage =
    if cccp != null && cccp.packages ? ${system} then cccp.packages.${system}.default else null;

  loadSpec =
    name:
    let
      f = import (../. + "/${name}/default.nix");
    in
    final.callPackage f (
      specExtraArgs name // lib.optionalAttrs (lib.functionArgs f ? cccp) { cccp = cccpPackage; }
    );

  mkAgent =
    backend: name:
    import ../lib/mk-agent.nix {
      inherit backend;
      lib = flakeLib;
      pkgs = final;
      microvm = if backend == "microvm" then microvm else null;
      darwinNull = isDarwin;
      spec = loadSpec name;
    };

  variants = lib.listToAttrs (
    lib.concatMap (
      backend:
      lib.concatMap (
        name:
        let
          drv = mkAgent backend name;
        in
        [
          {
            name = variantName backend name;
            value = drv;
          }
        ]
        ++ lib.optional (backend == defaultBackend) {
          name = "${name}-${backend}";
          value = drv;
        }
      ) (agentsForBackendSystem backend)
    ) backendsForSystem
  );
in
(gvisorFix final prev)
// {
  sandboxedAgents = variants // {
    inherit mkAgent variantName;
  };
}
