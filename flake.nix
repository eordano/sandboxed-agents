{
  description = "Sandboxed AI coding agents -- Claude Code, Hermes, OpenCode, Codex, Gemini CLI, Aider";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    hermes-agent = {
      # Pinned: rev 476f009f (0.19.0, 2026-07-25) added a setup.py guard that
      # hard-fails wheel/sdist builds ("Building wheels or sdists for
      # hermes-agent is not supported"), which breaks how this flake packages it.
      # 8967e73e is the last rev that builds. Revisit once packaging follows
      # upstream's Nix distribution instead of building from source.
      url = "github:NousResearch/hermes-agent/8967e73e67838c8a67cc412e9c8eb9d791cc1f20";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    opencode-src = {
      url = "github:anomalyco/opencode/v1.18.18";
      flake = false;
    };
    gemini-src = {
      url = "github:google-gemini/gemini-cli/v0.55.1";
      flake = false;
    };
    aider-src = {
      url = "github:Aider-AI/aider/v0.86.2";
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
  };

  outputs =
    {
      self,
      nixpkgs,
      hermes-agent,
      opencode-src,
      gemini-src,
      aider-src,
      home-manager,
      microvm,
    }:
    let
      inherit (nixpkgs) lib;

      # x86_64-darwin dropped: nixpkgs 26.11 (nixos-unstable) no longer supports it.
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
        "aider"
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
          aider-src
          hermes-agent
          microvm
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

      mkUpdate = pkgs: name: {
        type = "app";
        program = "${pkgs.writeShellScript "run-update-${name}" ''
          export PATH=${lib.makeBinPath (updateTools pkgs)}:$PATH
          export REPO_ROOT="$PWD"
          exec bash ${./.}/lib/update.sh ${name}
        ''}";
        meta.description = "Update ${name}";
      };

    in
    {
      overlays = {
        default = sandboxedAgentsOverlay;
        gvisorFix = import ./overlays/gvisor-go126-fix.nix;
      };

      packages = forSystems allSystems (
        pkgs: _system:
        let
          variants = derivationVariants pkgs;
        in
        variants // { default = variants.claude; }
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

          check-all = {
            type = "app";
            program = "${pkgs.writeShellScript "check-all" ''
              set -euo pipefail
              checks=(format shellcheck statix deadnix)
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
                bash ${./.}/lib/update.sh "$a"
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
                  cd ${self}
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
                  cd ${self}
                  find . -name '*.sh' -exec shellcheck -S warning {} +
                  touch $out
                '';
            statix = pkgs.runCommand "statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
              statix check ${self} --config ${./.statix.toml}
              touch $out
            '';
            deadnix = pkgs.runCommand "deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
              deadnix --fail ${self}
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
                  "aider"
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
