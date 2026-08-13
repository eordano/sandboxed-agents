{
  writeText,
  runCommand,
  coreutils,
  bash,
  cacert,
}:

let
  mkConfig =
    {
      agentName,
      defaultPlatform ? "systrap",
    }:
    {
      ociVersion = "1.0.2";

      process = {
        terminal = true;
        user = {
          uid = 0;
          gid = 0;
        };
        args = [ "/bin/sh" ];
        env = [ "PATH=/run/current-system/sw/bin:/bin:/usr/bin" ];
        cwd = "/";
        capabilities = {
          bounding = [ ];
          effective = [ ];
          permitted = [ ];
          ambient = [ ];
        };
        rlimits = [
          {
            type = "RLIMIT_NOFILE";
            hard = 65536;
            soft = 65536;
          }
        ];
        noNewPrivileges = true;
      };

      root = {
        path = "rootfs";
        readonly = true;
      };

      hostname = "${agentName}-runsc";

      mounts = [
        {
          destination = "/proc";
          type = "proc";
          source = "proc";
        }
        {
          destination = "/dev";
          type = "tmpfs";
          source = "tmpfs";
          options = [
            "nosuid"
            "strictatime"
            "mode=755"
            "size=65536k"
          ];
        }
        {
          destination = "/sys";
          type = "tmpfs";
          source = "tmpfs";
          options = [
            "nosuid"
            "noexec"
            "nodev"
            "ro"
          ];
        }
        {
          destination = "/etc";
          type = "tmpfs";
          source = "tmpfs";
          options = [
            "nosuid"
            "nodev"
            "mode=755"
          ];
        }
      ];

      linux = {
        namespaces = [
          { type = "pid"; }
          { type = "ipc"; }
          { type = "uts"; }
          { type = "mount"; }
        ];
        uidMappings = [
          {
            hostID = 0;
            containerID = 0;
            size = 1;
          }
        ];
        gidMappings = [
          {
            hostID = 0;
            containerID = 0;
            size = 1;
          }
        ];
      };

      annotations = {
        "dev.gvisor.internal.platform" = defaultPlatform;
      };
    };

  mkBundle =
    {
      agentName,
      defaultPlatform ? "systrap",
    }:
    let
      configJson = writeText "${agentName}-runsc-config-template.json" (
        builtins.toJSON (mkConfig {
          inherit agentName defaultPlatform;
        })
      );
    in
    runCommand "${agentName}-runsc-bundle"
      {
        passthru = {
          inherit configJson;
        };
      }
      ''
        mkdir -p $out/rootfs

        mkdir -p $out/rootfs/{proc,dev,sys,tmp,etc,home,root,var,run,nix}
        mkdir -p $out/rootfs/usr/bin
        mkdir -p $out/rootfs/usr/lib

        ln -s /run/current-system/sw/bin $out/rootfs/bin
        ln -s /run/current-system/sw/sbin $out/rootfs/sbin
        ln -s /run/current-system/sw/lib $out/rootfs/lib
        ln -s ${bash}/bin/sh $out/rootfs/usr/bin/sh
        ln -s ${coreutils}/bin/env $out/rootfs/usr/bin/env

        mkdir -p $out/rootfs/lib64
        for ld in \
          /run/current-system/sw/lib/ld-linux-x86-64.so.2 \
          /run/current-system/sw/lib/ld-linux-aarch64.so.1; do
          ln -sf "$ld" $out/rootfs/lib64/"$(basename "$ld")"
        done

        cp ${configJson} $out/config-template.json

        ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/ca-bundle.crt
      '';
in
{
  inherit mkBundle;
}
