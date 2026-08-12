_: prev: {
  gvisor = prev.callPackage ./gvisor/package.nix {
    buildGoModule = prev.buildGo126Module;
  };
}
