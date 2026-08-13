{
  nixpkgs,
  opencode-src,
  gemini-src,
  aider-src,
  hermes-agent,
  microvm,
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
    "aider"
  ];
  linuxSystems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  agentSrcs = {
    opencode = opencode-src;
    gemini = gemini-src;
    aider = aider-src;
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
  # opencode's upstream package marks x86_64-darwin as a badPlatform, so the
  # variant cannot even evaluate there.
  agentsForBackendSystem =
    backend:
    lib.subtractLists (lib.optional (system == "x86_64-darwin") "opencode") (
      if backend == "microvm" && isDarwin then [ "claude" ] else allAgents
    );

  specExtraArgs =
    name:
    lib.optionalAttrs (name == "hermes") {
      hermes-agent = final.callPackage ./hermes-python312.nix {
        hermes-agent-src = hermes-agent-inputs.src;
        inherit (hermes-agent-inputs) uv2nix pyproject-nix pyproject-build-systems;
      };
    }
    // lib.optionalAttrs (agentSrcs ? ${name}) { src = agentSrcs.${name}; };

  loadSpec = name: final.callPackage (../. + "/${name}/default.nix") (specExtraArgs name);

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
