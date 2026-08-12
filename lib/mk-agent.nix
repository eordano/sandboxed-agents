{
  lib,
  pkgs,
  microvm ? null,
  darwinNull ? false,
  spec,
  backend ? "bwrap",
}:

let
  inherit (spec) name;
  mv = spec.microvm or { };

  common = {
    agentName = name;
    inherit (spec) version;
    agentBinaryDrv = spec.binaryDrv;
    agentBinaryRelPath = spec.binaryRelPath;
    configFileName = spec.configFileName or "${name}-sandbox.json";
    configDir = spec.configDir or null;
    sandboxHomeDest = spec.sandboxHomeDest or ".${name}";
    xdgRemaps = spec.xdgRemaps or [ ];
    extraHomeAllow = spec.extraHomeAllow or [ ];
    enableYolo = spec.enableYolo or false;
    extraEnvVars = spec.extraEnvVars or { };
    sandboxInitLines = spec.sandboxInitLines or "";
    nativeCompletion = spec.nativeCompletion or null;
    enableEscapeHatch = spec.enableEscapeHatch or true;
  };

  darwinNullArgs = lib.optionalAttrs darwinNull {
    bubblewrap = null;
    tun2socks = null;
    slirp4netns = null;
    iproute2 = null;
    iptables = null;
    util-linux = null;
    python3 = null;
  };

in
if backend == "microvm" then
  import ./mk-microvm-sandbox.nix (
    (removeAttrs common [ "extraHomeAllow" ])
    // {
      inherit lib pkgs microvm;
      sandboxInitLines = mv.sandboxInitLines or common.sandboxInitLines;
      extraEnvVars = common.extraEnvVars // (mv.extraEnvVars or { });
      extraGuestPackages = mv.extraGuestPackages or [ ];
    }
  )
else
  pkgs.callPackage ./mk-sandbox.nix (
    common
    // {
      inherit backend;
      supportsDarwin = spec.supportsDarwin or false;
      apiBaseUrlEnvVars = spec.apiBaseUrlEnvVars or [ ];
    }
    // darwinNullArgs
  )
