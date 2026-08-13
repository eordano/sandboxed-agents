{
  lib,
  agentName,
  agentBinaryDrv,
  agentBinaryRelPath,
  mountBase,
  extraGuestPackages ? [ ],
  extraEnvVars ? { },
  configDir ? null,
  sandboxHomeDest ? ".${agentName}",
  sandboxInitLines ? "",
  useVirtiofs ? true,
}:

{ pkgs, ... }:

let
  agentBin = "${agentBinaryDrv}/${agentBinaryRelPath}";

  envExportLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: ''export ${k}="${v}"'') extraEnvVars
  );

  shareProto = if useVirtiofs then "virtiofs" else "9p";
in
{
  microvm = {
    hypervisor = "qemu";
    mem = 2049;
    vcpu = 2;
    virtiofsd.group = null;

    shares = [
      {
        tag = "nix-store";
        source = "/nix/store";
        mountPoint = "/nix/store";
        proto = shareProto;
      }
      {
        tag = "env-share";
        source = "${mountBase}/env";
        mountPoint = "/run/env";
        proto = shareProto;
      }
    ];

    interfaces = [
      {
        type = "user";
        id = "usernet";
        mac = "02:00:00:00:00:01";
      }
    ];
  };

  fileSystems."/nix/store".options = [ "ro" ];

  networking.hostName = "${agentName}-sandbox";
  networking.firewall.enable = false;

  users.users.agent = {
    isNormalUser = true;
    home = "/home/agent";
    group = "agent";
  };
  users.groups.agent = { };

  environment.systemPackages = [
    agentBinaryDrv
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.curl
    pkgs.docker-client
    pkgs.fuse3
    pkgs.git
    pkgs.gvisor
    pkgs.iptables
    pkgs.jq
    pkgs.libvirt
    pkgs.shadow
    pkgs.socat
    pkgs.util-linux
  ]
  ++ extraGuestPackages;

  boot.kernelModules = [
    "fuse"
  ]
  ++ lib.optionals (!useVirtiofs) [
    "9p"
    "9pnet_virtio"
  ];
  boot.supportedFilesystems = lib.optionals (!useVirtiofs) [ "9p" ];

  systemd.services.sandbox-setup = {
    description = "Set up sandbox user and mounts";
    after = [ "local-fs.target" ];
    before = [
      "agent-run.service"
      "network-lockdown.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.coreutils
      pkgs.shadow
      pkgs.util-linux
    ];
    environment.SANDBOX_FS_TYPE = if useVirtiofs then "virtiofs" else "9p";
    script = builtins.readFile ./microvm-sandbox-setup.sh;
  };

  systemd.services.ssh-auth-bridge = {
    description = "Bridge guest /run/ssh-auth.sock to host SSH agent via TCP";
    after = [
      "sandbox-setup.service"
      "network.target"
    ];
    before = [ "agent-run.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.bashInteractive}/bin/bash -c 'exec ${pkgs.socat}/bin/socat UNIX-LISTEN:/run/ssh-auth.sock,fork,mode=0600,user=agent TCP:10.0.2.2:$(cat /run/env/.ssh-auth-port)'";
      Restart = "no";
    };
    unitConfig.ConditionPathExists = "/run/env/.ssh-auth-port";
  };

  systemd.services.gpg-agent-bridge = {
    description = "Bridge guest /run/gpg-agent.sock to host gpg-agent via TCP";
    after = [
      "sandbox-setup.service"
      "network.target"
    ];
    before = [ "agent-run.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.bashInteractive}/bin/bash -c 'exec ${pkgs.socat}/bin/socat UNIX-LISTEN:/run/gpg-agent.sock,fork,mode=0600,user=agent TCP:10.0.2.2:$(cat /run/env/.gpg-agent-port)'";
      Restart = "no";
    };
    unitConfig.ConditionPathExists = "/run/env/.gpg-agent-port";
  };

  systemd.services.network-lockdown = {
    description = "Restrict internet access if requested";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "agent-run.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.gawk
      pkgs.glibc.bin
      pkgs.util-linux
    ];
    script = ''
      _ALLOWED_IPS=""
      if [ -f /run/env/.allowed-hosts ]; then
        # /etc/hosts is a read-only /nix/store symlink; copy, append, bind-mount.
        cp -L /etc/hosts /run/hosts.lockdown
        while IFS= read -r _host; do
          [ -z "$_host" ] && continue
          while IFS= read -r _ip; do
            [ -n "$_ip" ] || continue
            _ALLOWED_IPS="$_ALLOWED_IPS $_ip"
            echo "$_ip $_host" >> /run/hosts.lockdown
          done < <(getent ahosts "$_host" 2>/dev/null | awk '{print $1}' | sort -u)
        done < /run/env/.allowed-hosts
        mount --bind /run/hosts.lockdown /etc/hosts
      fi

      if [ -f /run/env/.disable-networking ]; then
        ${pkgs.iptables}/bin/iptables -P OUTPUT DROP
        ${pkgs.iptables}/bin/iptables -A OUTPUT -o lo -j ACCEPT
        for _ip in $_ALLOWED_IPS; do
          ${pkgs.iptables}/bin/iptables -A OUTPUT -d "$_ip" -j ACCEPT 2>/dev/null || true
        done
        if command -v ${pkgs.iptables}/bin/ip6tables >/dev/null 2>&1; then
          ${pkgs.iptables}/bin/ip6tables -P OUTPUT DROP
          ${pkgs.iptables}/bin/ip6tables -A OUTPUT -o lo -j ACCEPT
          for _ip in $_ALLOWED_IPS; do
            ${pkgs.iptables}/bin/ip6tables -A OUTPUT -d "$_ip" -j ACCEPT 2>/dev/null || true
          done
        fi
      elif [ -f /run/env/.no-internet-access ]; then
        ${pkgs.iptables}/bin/iptables -P OUTPUT DROP
        ${pkgs.iptables}/bin/iptables -A OUTPUT -o lo -j ACCEPT
        ${pkgs.iptables}/bin/iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -A OUTPUT -d 100.64.0.0/10 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -A OUTPUT -d 169.254.0.0/16 -j ACCEPT
        for _ip in $_ALLOWED_IPS; do
          ${pkgs.iptables}/bin/iptables -A OUTPUT -d "$_ip" -j ACCEPT 2>/dev/null || true
        done
        if command -v ${pkgs.iptables}/bin/ip6tables >/dev/null 2>&1; then
          ${pkgs.iptables}/bin/ip6tables -P OUTPUT DROP
          ${pkgs.iptables}/bin/ip6tables -A OUTPUT -o lo -j ACCEPT
          ${pkgs.iptables}/bin/ip6tables -A OUTPUT -d ::1/128 -j ACCEPT
          ${pkgs.iptables}/bin/ip6tables -A OUTPUT -d fc00::/7 -j ACCEPT
          ${pkgs.iptables}/bin/ip6tables -A OUTPUT -d fe80::/10 -j ACCEPT
          for _ip in $_ALLOWED_IPS; do
            ${pkgs.iptables}/bin/ip6tables -A OUTPUT -d "$_ip" -j ACCEPT 2>/dev/null || true
          done
        fi
      fi
    '';
  };

  systemd.services.libvirt-bridge = {
    description = "Bridge guest /run/libvirt-sock to host libvirt via TCP";
    after = [
      "sandbox-setup.service"
      "network.target"
    ];
    before = [ "agent-run.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.bashInteractive}/bin/bash -c 'exec ${pkgs.socat}/bin/socat UNIX-LISTEN:/run/libvirt-sock,fork,mode=0666 TCP:10.0.2.2:$(cat /run/env/.libvirt-port)'";
      Restart = "no";
    };
    unitConfig.ConditionPathExists = "/run/env/.libvirt-port";
  };

  systemd.services.agent-run = {
    description = "Run sandboxed ${agentName}";
    after = [
      "local-fs.target"
      "network-online.target"
      "network-lockdown.service"
      "sandbox-setup.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "network-lockdown.service"
      "sandbox-setup.service"
    ];
    wantedBy = [ "multi-user.target" ];

    unitConfig.ConditionPathExists = "!/run/env/.use-runsc";

    serviceConfig = {
      Type = "oneshot";
      User = "agent";
      StandardInput = "tty";
      StandardOutput = "tty";
      TTYPath = "/dev/ttyS0";
      TTYReset = true;
      TTYVHangup = true;
    };

    script = ''
      ${envExportLines}

      if [ -f /run/env/.env ]; then
        set -a
        . /run/env/.env
        set +a
      fi

      REAL_USER=$(cat /run/env/.user 2>/dev/null || echo "agent")
      REAL_HOME=$(cat /run/env/.home 2>/dev/null || echo "/home/agent")
      WORKDIR=$(cat /run/env/.workdir 2>/dev/null || echo "/home/agent")

      export HOME="$REAL_HOME"
      export USER="$REAL_USER"
      export LOGNAME="$REAL_USER"
      export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:/run/wrappers/bin:/sbin:/bin:$PATH"
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      export NIX_SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      export CURL_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

      export WORKDIR

      ${lib.optionalString (configDir != null) ''
        mkdir -p "$HOME/${sandboxHomeDest}"
        cp -rn ${configDir}/. "$HOME/${sandboxHomeDest}/" 2>/dev/null || true
        chmod -R u+w "$HOME/${sandboxHomeDest}" 2>/dev/null || true
      ''}

      ${sandboxInitLines}

      cd "$WORKDIR" 2>/dev/null || cd "$HOME"

      AGENT_MODE=$(cat /run/env/.mode 2>/dev/null || echo "agent")
      if [ "$AGENT_MODE" = "shell" ]; then
        exec ${pkgs.bashInteractive}/bin/bash -l
      else
        _AGENT_ARGS=()
        if [ -f /run/env/.args ]; then
          while IFS= read -r -d "" arg; do
            _AGENT_ARGS+=("''$arg")
          done < /run/env/.args
        fi
        exec ${agentBin} "''${_AGENT_ARGS[@]}"
      fi
    '';
  };

  systemd.services.agent-run-runsc = {
    description = "Run sandboxed ${agentName} under gVisor (runsc)";
    after = [
      "local-fs.target"
      "network-online.target"
      "network-lockdown.service"
      "sandbox-setup.service"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "network-lockdown.service"
      "sandbox-setup.service"
    ];
    wantedBy = [ "multi-user.target" ];

    unitConfig.ConditionPathExists = "/run/env/.use-runsc";

    serviceConfig = {
      Type = "oneshot";
      StandardInput = "tty";
      StandardOutput = "tty";
      TTYPath = "/dev/ttyS0";
      TTYReset = true;
      TTYVHangup = true;
      Delegate = "yes";
    };

    path = [
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.gvisor
      pkgs.jq
      pkgs.util-linux
    ];

    script = ''
      set -eu

      REAL_USER=$(cat /run/env/.user 2>/dev/null || echo "agent")
      REAL_HOME=$(cat /run/env/.home 2>/dev/null || echo "/home/agent")
      WORKDIR=$(cat /run/env/.workdir 2>/dev/null || echo "$REAL_HOME")
      MODE=$(cat /run/env/.mode 2>/dev/null || echo "agent")
      PLATFORM=$(cat /run/env/.runsc-platform 2>/dev/null || echo systrap)

      AGENT_UID=$(id -u agent)
      AGENT_GID=$(id -g agent)

      export HOME="$REAL_HOME"
      export USER="$REAL_USER"
      export LOGNAME="$REAL_USER"
      ${lib.optionalString (configDir != null) ''
        mkdir -p "$HOME/${sandboxHomeDest}"
        cp -rn ${configDir}/. "$HOME/${sandboxHomeDest}/" 2>/dev/null || true
        chmod -R u+w "$HOME/${sandboxHomeDest}" 2>/dev/null || true
      ''}
      ${sandboxInitLines}
      chown -R agent:agent "$HOME" 2>/dev/null || true

      declare -a CONTAINER_ENV=()
      CONTAINER_ENV+=("HOME=$REAL_HOME")
      CONTAINER_ENV+=("USER=$REAL_USER")
      CONTAINER_ENV+=("LOGNAME=$REAL_USER")
      CONTAINER_ENV+=("PATH=$REAL_HOME/.local/bin:$REAL_HOME/.nix-profile/bin:/run/current-system/sw/bin:/run/wrappers/bin:/sbin:/bin")
      CONTAINER_ENV+=("SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt")
      CONTAINER_ENV+=("NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt")
      CONTAINER_ENV+=("CURL_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt")
      CONTAINER_ENV+=("WORKDIR=$WORKDIR")

      ${envExportLines}
      for _k in ${lib.concatStringsSep " " (lib.attrNames extraEnvVars)}; do
        _v="''${!_k:-}"
        [ -n "$_v" ] && CONTAINER_ENV+=("$_k=$_v")
      done

      if [ -f /run/env/.env ]; then
        while IFS= read -r -d "" _pair; do
          [ -n "$_pair" ] && CONTAINER_ENV+=("$_pair")
        done < <(env -i ${pkgs.bashInteractive}/bin/bash -c 'set -a; . /run/env/.env 2>/dev/null; set +a; ${pkgs.coreutils}/bin/env -0')
      fi

      declare -a CONTAINER_ARGS=()
      if [ "$MODE" = "shell" ]; then
        CONTAINER_ARGS=("${pkgs.bashInteractive}/bin/bash" "-l")
      else
        CONTAINER_ARGS=("${agentBin}")
        if [ -f /run/env/.args ]; then
          while IFS= read -r -d "" _arg; do
            CONTAINER_ARGS+=("$_arg")
          done < /run/env/.args
        fi
      fi

      BUNDLE=/run/runsc-bundle
      rm -rf "$BUNDLE"
      mkdir -p "$BUNDLE/rootfs"

      mount --rbind / "$BUNDLE/rootfs"
      mount --make-rslave "$BUNDLE/rootfs"

      args_json=$(printf '%s\n' "''${CONTAINER_ARGS[@]}" | jq -R . | jq -s .)
      env_json=$(printf '%s\n' "''${CONTAINER_ENV[@]}"  | jq -R . | jq -s .)

      TERMINAL=true
      [ -t 0 ] && [ -t 1 ] || TERMINAL=false

      jq -n \
        --argjson uid "$AGENT_UID" \
        --argjson gid "$AGENT_GID" \
        --arg     cwd "$WORKDIR" \
        --arg     hostname "${agentName}-runsc" \
        --argjson args "$args_json" \
        --argjson env  "$env_json" \
        --argjson terminal "$TERMINAL" \
        '{
          ociVersion: "1.0.2",
          process: {
            terminal: $terminal,
            user: { uid: $uid, gid: $gid },
            args: $args,
            env:  $env,
            cwd:  $cwd,
            capabilities: {
              bounding:  ["CAP_NET_BIND_SERVICE"],
              effective: ["CAP_NET_BIND_SERVICE"],
              permitted: ["CAP_NET_BIND_SERVICE"]
            },
            rlimits: [{ type: "RLIMIT_NOFILE", soft: 1048576, hard: 1048576 }]
          },
          root: { path: "rootfs", readonly: false },
          hostname: $hostname,
          mounts: [
            { destination: "/proc",    type: "proc",   source: "proc" },
            { destination: "/dev",     type: "tmpfs",  source: "tmpfs",  options: ["nosuid","strictatime","mode=755"] },
            { destination: "/dev/pts", type: "devpts", source: "devpts", options: ["nosuid","noexec","newinstance","ptmxmode=0666","mode=0620"] },
            { destination: "/dev/shm", type: "tmpfs",  source: "shm",    options: ["nosuid","noexec","nodev","mode=1777"] },
            { destination: "/sys",     type: "sysfs",  source: "sysfs",  options: ["nosuid","noexec","nodev","ro"] },
            { destination: "/tmp",     type: "tmpfs",  source: "tmpfs",  options: ["nosuid","nodev","mode=1777"] }
          ],
          linux: {
            namespaces: [
              { type: "pid" },
              { type: "ipc" },
              { type: "uts" },
              { type: "mount" }
            ]
          }
        }' > "$BUNDLE/config.json"

      cd "$BUNDLE"
      exec runsc \
        --platform="$PLATFORM" \
        --network=host \
        --ignore-cgroups \
        --overlay2=root:memory \
        run agent
    '';
  };

  systemd.services.agent-shutdown = {
    description = "Shutdown after agent exits";
    after = [
      "agent-run.service"
      "agent-run-runsc.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl poweroff";
    };
  };

  boot.kernelParams = [ "console=ttyS0" ];
  systemd.services."serial-getty@ttyS0".enable = false;
  systemd.services."getty@tty1".enable = false;

  system.stateVersion = "24.11";
}
