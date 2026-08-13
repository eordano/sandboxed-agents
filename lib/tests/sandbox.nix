{
  pkgs,
  agent,
  pkg,
  mockApi ? null,
  backend ? "bwrap",
}:

let
  mockApiServer = ./mock-api-server.py;

  mockCurlScript = pkgs.writeShellScript "test-mock-curl" ''
    curl -sf -X POST "http://$1:8090/v1/messages" \
      -H "Content-Type: application/json" \
      -d '{"model":"test","max_tokens":10,"messages":[{"role":"user","content":"hi"}],"stream":true}'
  '';
in
pkgs.testers.nixosTest {
  name = "${agent}-sandbox-${backend}";

  nodes.machine =
    { pkgs, ... }:
    {
      virtualisation.vlans = [
        1
        2
      ];
      environment.systemPackages = [
        pkg
        pkgs.curl
      ];
      security.unprivilegedUsernsClone = true;
      users.users.testuser = {
        isNormalUser = true;
        home = "/home/testuser";
      };
      # Loopback-only service: reachable from the host, must not be reachable
      # from inside the sandbox's network namespace.
      systemd.services.loopback-http = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          mkdir -p /tmp/loopback
          echo 'loopback-canary' > /tmp/loopback/index.html
          ${pkgs.python3}/bin/python3 -m http.server 8080 --bind 127.0.0.1 -d /tmp/loopback
        '';
      };
    };

  nodes.blocked =
    { pkgs, ... }:
    {
      virtualisation.vlans = [ 1 ];
      networking.firewall.allowedTCPPorts = [ 8080 ];
      systemd.services.http = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          echo 'you-should-not-see-this' > /tmp/index.html
          ${pkgs.python3}/bin/python3 -m http.server 8080 -d /tmp
        '';
      };
    };

  nodes.server =
    { pkgs, ... }:
    {
      virtualisation.vlans = [ 2 ];
      networking.firewall.allowedTCPPorts = [
        1080
        8080
        8090
      ];
      environment.systemPackages = [ pkgs.microsocks ];
      systemd.services.microsocks = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.microsocks}/bin/microsocks -p 1080";
      };
      systemd.services.http = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          echo 'proxy-test-ok' > /tmp/index.html
          ${pkgs.python3}/bin/python3 -m http.server 8080 -d /tmp
        '';
      };
      systemd.services.mock-api = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          ${pkgs.python3}/bin/python3 ${mockApiServer} 8090
        '';
      };
    };

  nodes.another =
    { pkgs, ... }:
    {
      virtualisation.vlans = [ 2 ];
      networking.firewall.allowedTCPPorts = [ 8080 ];
      systemd.services.http = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          echo 'another-test-ok' > /tmp/index.html
          ${pkgs.python3}/bin/python3 -m http.server 8080 -d /tmp
        '';
      };
    };

  testScript = ''
    def sh(cmd, extra_flags=""):
        return f"echo '{cmd}' | su - testuser -c 'cd {wd} && ${agent} --sandbox-open-shell {extra_flags}'"

    def sh_socks(cmd):
        return sh(cmd, f"--socks-proxy {server_ip}:1080")

    def sh_home(cmd, extra=""):
        return f"echo '{cmd}' | su - testuser -c 'cd /home/testuser && ${agent} --sandbox-open-shell {extra}'"

    def canary_sh(cmd, extra_flags=""):
        return f"echo '{cmd}' | su - testuser -c 'cd {wd} && export SECRET_CANARY_CREDENTIAL=SUPER_SECRET_DO_NOT_LEAK_42 && ${agent} --sandbox-open-shell {extra_flags}'"

    CANARY = "SUPER_SECRET_DO_NOT_LEAK_42"

    start_all()
    machine.wait_for_unit("multi-user.target")
    server.wait_for_unit("microsocks.service")
    server.wait_for_unit("http.service")
    server.wait_for_unit("mock-api.service")
    blocked.wait_for_unit("http.service")
    another.wait_for_unit("http.service")
    server.wait_for_open_port(1080)
    server.wait_for_open_port(8080)
    server.wait_for_open_port(8090)
    blocked.wait_for_open_port(8080)
    another.wait_for_open_port(8080)

    blocked_ip = blocked.succeed("ip -4 addr show eth1 | grep -oP 'inet \\K[^/]+'").strip()
    server_ip = server.succeed("ip -4 addr show eth1 | grep -oP 'inet \\K[^/]+'").strip()
    another_ip = another.succeed("ip -4 addr show eth1 | grep -oP 'inet \\K[^/]+'").strip()

    wd = "/home/testuser/testproject"
    machine.succeed(f"su - testuser -c 'mkdir -p {wd}'")

    machine.succeed(f"ping -c 1 {blocked_ip}")
    machine.succeed(f"ping -c 1 {server_ip}")
    server.fail(f"ping -c 1 -W 3 {blocked_ip}")

    machine.log("Test 1: basic sandbox")
    machine.succeed(sh("echo hello") + " | grep -q hello")

    machine.log("Test 2: filesystem isolation")
    machine.succeed("echo secret > /host-secret.txt && chmod 644 /host-secret.txt")
    machine.succeed("su - testuser -c 'cat /host-secret.txt'")  # control: readable outside the sandbox
    machine.fail(sh("cat /host-secret.txt"))

    machine.log("Test 3: network")
    machine.succeed(sh("ip link show lo"))

    machine.log("Test 4: SOCKS proxy")
    machine.succeed(sh_socks("ip link show tun0"))
    out = machine.succeed(sh_socks("ip route show; ip link show; cat /proc/net/route"))
    assert "default dev tun0" in out, f"Expected 'default dev tun0' in:\n{out}"

    machine.succeed(sh_socks(f"curl -sf http://{server_ip}:8080/index.html") + " | grep -q proxy-test-ok")
    machine.succeed(sh_socks(f"curl -sf http://{another_ip}:8080/index.html") + " | grep -q another-test-ok")

    machine.succeed(sh(f"curl -sf http://{server_ip}:8080/index.html") + " | grep -q proxy-test-ok")
    machine.succeed(sh(f"curl -sf http://{blocked_ip}:8080/index.html") + " | grep -q you-should-not-see-this")

    blocked.succeed("ip addr add 198.51.100.1/32 dev eth1")
    machine.succeed(f"ip route add 198.51.100.1/32 via {blocked_ip}")

    machine.log("Test 5: SOCKS network boundary")
    machine.wait_for_open_port(8080)
    machine.succeed("curl -sf http://127.0.0.1:8080/index.html | grep -q loopback-canary")  # control
    machine.fail(sh_socks("curl -sf --max-time 5 http://198.51.100.1:8080/index.html"))
    machine.fail(sh_socks("curl -sf --max-time 5 http://127.0.0.1:8080/index.html"))

    machine.log("Test 6: --disable-networking blocks non-localhost")
    def sh_nopi(cmd):
        return sh(cmd, "--disable-networking")

    machine.fail(sh_nopi(f"curl -sf --max-time 5 http://{server_ip}:8080/index.html"))
    machine.fail(sh_nopi(f"curl -sf --max-time 5 http://{blocked_ip}:8080/index.html"))

    machine.log("Test 7: --disable-networking with --allow-host")
    def sh_allowhost(cmd):
        return sh(cmd, f"--disable-networking --allow-host {server_ip}")

    machine.succeed(sh_allowhost(f"curl -sf http://{server_ip}:8080/index.html") + " | grep -q proxy-test-ok")
    machine.fail(sh_allowhost(f"curl -sf --max-time 5 http://{blocked_ip}:8080/index.html"))

    machine.log("Test 8: --disable-networking blocks public")
    machine.succeed(sh("curl -sf --max-time 5 http://198.51.100.1:8080/index.html") + " | grep -q you-should-not-see-this")
    machine.fail(sh_nopi("curl -sf --max-time 5 http://198.51.100.1:8080/index.html"))

    machine.log("Test 9: --disable-networking warnings")
    machine.succeed(
        f"echo 'true' | su - testuser -c 'cd {wd} && ${agent} --sandbox-open-shell --disable-networking' 2>/tmp/nopi-warn-none.log"
    )
    machine.succeed("grep -q 'no API base URL override detected' /tmp/nopi-warn-none.log")

    ${
      if mockApi != null then
        if mockApi.baseUrlEnv != "" then
          ''
            machine.succeed(
                f"echo 'true' | su - testuser -c 'cd {wd} && ${agent} --sandbox-open-shell --disable-networking --env ${mockApi.baseUrlEnv}=http://{server_ip}:8090' 2>/tmp/nopi-warn-priv.log"
            )
            machine.fail("grep -q 'internet access is disabled' /tmp/nopi-warn-priv.log")

            machine.succeed(
                f"echo 'true' | su - testuser -c 'cd {wd} && ${agent} --sandbox-open-shell --disable-networking --env ${mockApi.baseUrlEnv}=http://8.8.8.8:8080' 2>/tmp/nopi-warn-pub.log"
            )
            machine.succeed("grep -q 'resolves to non-private address' /tmp/nopi-warn-pub.log")
          ''
        else
          ""
      else
        ""
    }

    machine.log("Test 10: credential isolation")
    machine.succeed(
        f"su - testuser -c 'cd {wd} && export SECRET_CANARY_CREDENTIAL={CANARY} && echo env | ${agent} --sandbox-open-shell' > /tmp/cred-test.log 2>&1"
    )
    machine.fail(f"grep -q {CANARY} /tmp/cred-test.log")

    scan_out = machine.succeed(canary_sh(
        f"grep -r {CANARY} / --exclude-dir=proc --exclude-dir=dev --exclude-dir=sys --exclude-dir=nix 2>/dev/null; exit 0"
    ))
    assert CANARY not in scan_out, f"CREDENTIAL LEAK: canary found: {scan_out[:500]}"

    machine.fail(canary_sh(f"grep -a {CANARY} /proc/self/environ"))

    machine.log("Test 11: mock API via SOCKS")
    machine.succeed(sh_socks(f"${mockCurlScript} {server_ip}") + " | grep -q SANDBOX_MOCK_RESPONSE_OK")

    api_log = server.succeed("cat /tmp/mock-api-requests.log")
    assert "/messages" in api_log, "Mock server did not receive messages request"
    server.succeed("truncate -s 0 /tmp/mock-api-requests.log")

    ${
      if mockApi != null then
        ''
          machine.log("Test 12: end-to-end agent -> mock API")
          ${mockApi.preAgentSetup or ""}
          _mock_prompt = ${builtins.toJSON mockApi.promptArgs}
          ${
            if mockApi ? baseUrlEnv && mockApi.baseUrlEnv != "" then
              ''_mock_url_env = f"--env ${mockApi.baseUrlEnv}=http://{server_ip}:8090 "''
            else
              ''_mock_url_env = ""''
          }
          _mock_env = _mock_url_env + "--env ${mockApi.apiKeyEnv}=${mockApi.dummyApiKey}"
          _mock_cmd = f"timeout 120 su - testuser -c 'cd {wd} && ${agent} --socks-proxy {server_ip}:1080 {_mock_env} {_mock_prompt}' 2>&1"
          agent_out = machine.succeed(_mock_cmd)
          assert "SANDBOX_MOCK_RESPONSE_OK" in agent_out, f"Expected SANDBOX_MOCK_RESPONSE_OK in agent output, got: {agent_out[:500]}"

          agent_api_log = server.succeed("cat /tmp/mock-api-requests.log")
          _api_log_check = '${mockApi.apiLogCheck or "messages"}'
          assert _api_log_check in agent_api_log, f"Expected '{_api_log_check}' in agent API log"
          ${
            if mockApi.skipApiKeyCheck or false then
              ""
            else
              ''
                assert "${mockApi.dummyApiKey}" in agent_api_log, "Dummy API key not found in request headers"
              ''
          }
        ''
      else
        ""
    }

    machine.log("Test 13: data persistence")
    machine.succeed(sh("echo PERSIST_CANARY > testproject-file.txt && echo EPHEMERAL_CANARY > ~/ephemeral-file.txt"))
    machine.succeed(sh("cat testproject-file.txt") + " | grep -q PERSIST_CANARY")
    machine.fail(sh("cat ~/ephemeral-file.txt"))

    machine.log("Test 14: home guard")
    machine.fail(sh_home("echo hello") + " 2>/dev/null")
    machine.succeed(sh_home("echo hello", "--allow-home-access") + " | grep -q hello")

    machine.log("Test 15: home files survive sandbox")
    machine.succeed("su - testuser -c 'echo Hello > /home/testuser/Hello'")
    machine.succeed(sh_home("true", "--allow-home-access"))
    machine.succeed("su - testuser -c 'test -f /home/testuser/Hello && grep -q Hello /home/testuser/Hello'")
  '';
}
