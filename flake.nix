{
  description = "Sandboxed AI coding agents -- Claude Code, Hermes, OpenCode, Codex, Gemini CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    opencode-src = {
      url = "github:anomalyco/opencode/v1.18.31";
      flake = false;
    };
    gemini-src = {
      url = "github:google-gemini/gemini-cli/v0.60.0";
      flake = false;
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cccp = {
      url = "github:eordano/cccp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      hermes-agent,
      opencode-src,
      gemini-src,
      home-manager,
      microvm,
      cccp,
    }:
    let
      inherit (nixpkgs) lib;

      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      allAgents = [
        "claude"
        "codex"
        "gemini"
        "hermes"
        "opencode"
      ];

      sandboxedAgentsOverlay = import ./overlays {
        inherit
          nixpkgs
          opencode-src
          gemini-src
          hermes-agent
          microvm
          cccp
          ;
      };

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ sandboxedAgentsOverlay ];
        };

      forSystems = systems: f: lib.genAttrs systems (system: f (pkgsFor system) system);

      derivationVariants =
        pkgs:
        removeAttrs pkgs.sandboxedAgents [
          "mkAgent"
          "variantName"
        ];

      mkApp = drv: name: {
        type = "app";
        program = "${drv}/bin/${name}";
        meta.description = "Sandboxed ${name} agent";
      };

      updateTools =
        pkgs: with pkgs; [
          bash
          curl
          jq
          nix
          gnused
          coreutils
          git
        ];

      nixFiles = lib.fileset.fileFilter (f: f.hasExt "nix") ./.;
      shFiles = lib.fileset.fileFilter (f: f.hasExt "sh") ./.;
      sourceOf =
        fileset:
        lib.fileset.toSource {
          root = ./.;
          inherit fileset;
        };
      nixSrc = sourceOf nixFiles;
      shSrc = sourceOf shFiles;
      lintSrc = sourceOf (lib.fileset.union nixFiles shFiles);

      mkUpdate = pkgs: name: {
        type = "app";
        program = "${pkgs.writeShellScript "run-update-${name}" ''
          export PATH=${lib.makeBinPath (updateTools pkgs)}:$PATH
          export REPO_ROOT="$PWD"
          exec bash ${./lib}/update.sh ${name}
        ''}";
        meta.description = "Update ${name}";
      };

    in
    {
      lib.hermesAgentSource = hermes-agent.outPath;

      lib.mkMicrovmSandbox =
        args:
        import ./lib/mk-microvm-sandbox.nix (
          {
            inherit (nixpkgs) lib;
            inherit microvm;
            inherit (args) pkgs;
          }
          // builtins.removeAttrs args [ "pkgs" ]
        );

      overlays = {
        default = sandboxedAgentsOverlay;
        gvisorFix = import ./overlays/gvisor-go126-fix.nix;
      };

      packages = forSystems allSystems (
        pkgs: _system:
        let
          variants = derivationVariants pkgs;
          privacyFilter = pkgs.callPackage ./plugins/privacy-filter/default.nix { };
          codesumPlugin = pkgs.runCommand "hermes-codesum-plugin" { } ''
            mkdir -p $out
            cp -R ${./plugins/codesum}/. $out/
          '';
        in
        variants
        // {
          privacy-filter = privacyFilter;
          codesum-plugin = codesumPlugin;
          default = variants.claude;
        }
      );

      apps = forSystems allSystems (
        pkgs: system:
        let
          variants = derivationVariants pkgs;
          stripBackendSuffix =
            name: lib.removeSuffix "-bwrap" (lib.removeSuffix "-runsc" (lib.removeSuffix "-microvm" name));
          variantApps = lib.mapAttrs (name: drv: mkApp drv (stripBackendSuffix name)) variants;
          updateApps = lib.listToAttrs (
            map (name: {
              name = "update-${name}";
              value = mkUpdate pkgs name;
            }) allAgents
          );
        in
        variantApps
        // updateApps
        // {
          default = mkApp variants.claude "claude";

          privacy-filter = mkApp (pkgs.callPackage ./plugins/privacy-filter/default.nix
            { }
          ) "sandbox-privacy-proxy";

          check-all = {
            type = "app";
            program = "${pkgs.writeShellScript "check-all" ''
              set -euo pipefail
              checks=(format shellcheck statix deadnix microvm-launcher-contract)
              microvm_pkgs=(${
                lib.concatMapStringsSep " " (n: ''"${n}"'') (
                  lib.filter (lib.hasSuffix "-microvm") (lib.attrNames variants)
                )
              })
              failed=0
              for c in "''${checks[@]}"; do
                echo "=== $c ==="
                if nix build ".#checks.${system}.$c" --no-link 2>&1; then
                  echo "  PASS"
                else
                  echo "  FAIL"
                  failed=1
                fi
              done
              if [ "''${#microvm_pkgs[@]}" -gt 0 ]; then
                echo "=== evaluate microvms (dry run) ==="
                microvm_args=()
                for p in "''${microvm_pkgs[@]}"; do
                  microvm_args+=(".#$p")
                done
                if nix build "''${microvm_args[@]}" --no-link --dry-run 2>&1; then
                  echo "  PASS"
                else
                  echo "  FAIL"
                  failed=1
                fi
              fi
              if [ "$failed" -eq 0 ]; then
                echo ""
                echo "All checks passed."
              else
                echo ""
                echo "Some checks failed."
                exit 1
              fi
            ''}";
            meta.description = "Run all lint checks";
          };

          update-all = {
            type = "app";
            program = "${pkgs.writeShellScript "update-all" ''
              set -euo pipefail
              export PATH=${lib.makeBinPath (updateTools pkgs)}:$PATH
              export REPO_ROOT="$PWD"
              for a in ${lib.concatStringsSep " " allAgents}; do
                echo "=== Updating $a ==="
                bash ${./lib}/update.sh "$a"
              done
            ''}";
            meta.description = "Update all agents";
          };
        }
      );

      formatter = forSystems allSystems (
        pkgs: _:
        pkgs.writeShellScriptBin "treefmt" ''
          export PATH=${
            lib.makeBinPath (
              with pkgs;
              [
                nixfmt
                shfmt
              ]
            )
          }:$PATH
          exec ${pkgs.treefmt}/bin/treefmt "$@"
        ''
      );

      devShells = forSystems allSystems (
        pkgs: _: {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixfmt
              shfmt
              shellcheck
              statix
              deadnix
            ];
          };
        }
      );

      checks = forSystems allSystems (
        pkgs: system:
        let
          lintChecks = {
            format =
              pkgs.runCommand "format-check"
                {
                  nativeBuildInputs = with pkgs; [
                    nixfmt
                    shfmt
                    findutils
                  ];
                }
                ''
                  cd ${lintSrc}
                  find . -name '*.nix' -exec nixfmt --check {} +
                  find . -name '*.sh' -exec shfmt -d -i 2 -ci {} +
                  touch $out
                '';
            shellcheck =
              pkgs.runCommand "shellcheck"
                {
                  nativeBuildInputs = with pkgs; [
                    shellcheck
                    findutils
                  ];
                }
                ''
                  cd ${shSrc}
                  find . -name '*.sh' -exec shellcheck -S warning {} +
                  touch $out
                '';
            statix = pkgs.runCommand "statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
              statix check ${nixSrc} --config ${./.statix.toml}
              touch $out
            '';
            deadnix = pkgs.runCommand "deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
              deadnix --fail ${nixSrc}
              touch $out
            '';
            privacy-filter =
              pkgs.runCommand "privacy-filter-test"
                {
                  nativeBuildInputs = [ pkgs.python3 ];
                }
                ''
                  cd ${./plugins/privacy-filter/scripts}
                  python3 -m unittest -v test_privacy_core.py
                  touch $out
                '';
            codesum-plugin =
              pkgs.runCommand "codesum-plugin-test"
                {
                  nativeBuildInputs = [ pkgs.python3 ];
                }
                ''
                  cp -R ${./plugins/codesum} ./codesum
                  chmod -R u+w ./codesum
                  python3 -m compileall -q ./codesum
                  touch $out
                '';
            microvm-launcher-contract =
              pkgs.runCommand "microvm-launcher-contract"
                {
                  nativeBuildInputs = [ pkgs.gnugrep ];
                }
                ''
                  launcher=${pkgs.sandboxedAgents.hermes-microvm}/bin/hermes
                  grep -F -- 'virtiofsd-run --user "$(' "$launcher"
                  grep -F -- '_VIRTIOFSD_READY_ATTEMPTS=300' "$launcher"
                  grep -F -- \
                    'virtiofsd process exited before its sockets became ready' \
                    "$launcher"
                  grep -F -- 'virtiofsd.log (last 40 lines)' "$launcher"
                  grep -F -- '--sandbox none' "$launcher"
                  grep -F -- '--translate-uid "map:1000:$HOST_UID:1"' "$launcher"
                  grep -F -- '--translate-gid "map:1000:$HOST_GID:1"' "$launcher"
                  grep -F -- 'kill "$VIRTIOFSD_PID" 2>/dev/null || true' "$launcher"
                  grep -F -- 'flock -u 200 || true' "$launcher"
                  grep -F -- '--forward-host-loopback requires a TCP port from 1 to 65535' "$launcher"
                  grep -F -- 'guestfwd=tcp:10.0.2.100:$_port-cmd:$_forwarder' "$launcher"
                  grep -F -- 'TCP:127.0.0.1:' "$launcher"
                  if "$launcher" \
                    --forward-host-loopback not-a-port \
                    --sandbox-show-config > invalid-port.out 2> invalid-port.err; then
                    echo 'invalid forward port was accepted' >&2
                    exit 1
                  fi
                  grep -F -- \
                    "got 'not-a-port'" \
                    invalid-port.err
                  grep -F -- \
                    '*:*) _RESOLVED_IPS="$_host"' \
                    ${./lib/microvm-guest.nix}
                  grep -F -- \
                    'network-lockdown: could not resolve allowed host' \
                    ${./lib/microvm-guest.nix}
                  grep -F -A 8 -- \
                    'chmod 0711 "$MOUNT_BASE/env"' \
                    "$launcher" > guest-control-mode-block
                  grep -F -- 'chmod 0666 "$EXIT_CODE_FILE"' guest-control-mode-block
                  grep -F -- 'chmod 0644 \' guest-control-mode-block
                  grep -F -- '"$ENV_FILE" \' guest-control-mode-block
                  grep -F -- '"$MOUNT_BASE/env/.user" \' guest-control-mode-block
                  grep -F -- '"$MOUNT_BASE/env/.home" \' guest-control-mode-block
                  grep -F -- '"$MOUNT_BASE/env/.workdir" \' guest-control-mode-block
                  grep -F -- '"$MOUNT_BASE/env/.mode" \' guest-control-mode-block
                  grep -F -- '"$MOUNT_BASE/env/.args"' guest-control-mode-block
                  grep -F -- 'chmod 0644 "$MOUNT_BASE/env/.allowed-hosts"' "$launcher"
                  grep -F -- 'guest agent exit status was not reported' "$launcher"
                  grep -F -- 'exit "$_GUEST_STATUS"' "$launcher"
                  test "$(grep -F -c '> /run/env/.exit-code' ${./lib/microvm-guest.nix})" -eq 2
                  touch $out
                '';
          };

          mkTest =
            backend: name:
            import (./. + "/${name}/tests/sandbox.nix") {
              inherit pkgs backend;
              pkg = pkgs.sandboxedAgents.${pkgs.sandboxedAgents.variantName backend name};
            };

          linuxChecks = lib.optionalAttrs (lib.elem system linuxSystems) (
            let
              tests = lib.genAttrs allAgents (mkTest "bwrap");
              runscTests = lib.genAttrs allAgents (mkTest "runsc");
            in
            lib.mapAttrs' (n: t: lib.nameValuePair "${n}-sandbox-test" t) tests
            // lib.mapAttrs' (n: t: lib.nameValuePair "${n}-sandbox-runsc-test" t) runscTests
            // {
              integration-test = pkgs.runCommand "integration-test" { } ''
                ${lib.concatMapStringsSep "\n" (n: ''echo "${n}: ${tests.${n}}"'') (builtins.attrNames tests)}
                ${lib.concatMapStringsSep "\n" (n: ''echo "${n}-runsc: ${runscTests.${n}}"'') (
                  builtins.attrNames runscTests
                )}
                touch $out
              '';
              home-manager-test = import ./lib/tests/home-manager.nix {
                inherit pkgs;
                home-manager-module = home-manager.nixosModules.home-manager;
                agentPackages = lib.genAttrs [
                  "claude"
                  "opencode"
                  "gemini"
                ] (name: self.packages.${system}.${name});
              };
            }
          );
        in
        lintChecks // linuxChecks
      );
    };
}
