{
  pkgs,
  home-manager-module,
  agentPackages,
}:

pkgs.testers.nixosTest {
  name = "home-manager-integration";

  nodes.machine =
    { ... }:
    {
      imports = [ home-manager-module ];

      security.unprivilegedUsernsClone = true;

      users.users.testuser = {
        isNormalUser = true;
        home = "/home/testuser";
      };

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        users.testuser = {
          home.stateVersion = "25.05";

          programs.claude-code = {
            enable = true;
            package = agentPackages.claude;
            settings = {
              permissions = {
                allow = [ "Bash(git log:*)" ];
              };
            };
          };

          programs.aider-chat = {
            enable = true;
            package = agentPackages.aider;
            settings = {
              dark-mode = true;
            };
          };

          programs.opencode = {
            enable = true;
            package = agentPackages.opencode;
            settings = {
              autoupdate = false;
            };
          };

          programs.gemini-cli = {
            enable = true;
            package = agentPackages.gemini;
            settings = {
              privacy = {
                usageStatisticsEnabled = false;
              };
            };
          };
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    wd = "/home/testuser/testproject"
    machine.succeed(f"su - testuser -c 'mkdir -p {wd}'")

    def sh(agent, cmd):
        return f"echo '{cmd}' | su - testuser -c 'cd {wd} && {agent} --sandbox-open-shell'"

    machine.log("Test 1: host config files")
    machine.succeed("test -e /home/testuser/.claude/settings.json")
    machine.succeed("test -e /home/testuser/.aider.conf.yml")
    machine.succeed("test -d /home/testuser/.config/opencode")
    machine.succeed("test -e /home/testuser/.gemini/settings.json")

    machine.log("Test 2: config visible in sandbox")
    machine.succeed(sh("claude", "cat ~/.claude/settings.json") + " | grep -q 'git log'")
    machine.succeed(sh("aider", "cat ~/.aider.conf.yml") + " | grep -q dark-mode")
    machine.succeed(sh("opencode", "cat ~/.config/opencode/opencode.json") + " | grep -q autoupdate")
    machine.succeed(sh("gemini", "cat ~/.gemini/settings.json") + " | grep -q usageStatisticsEnabled")

    machine.log("Test 3: idempotent across invocations")
    machine.succeed(sh("claude", "cat ~/.claude/settings.json") + " | grep -q 'git log'")
    machine.succeed(sh("gemini", "cat ~/.gemini/settings.json") + " | grep -q usageStatisticsEnabled")
  '';
}
