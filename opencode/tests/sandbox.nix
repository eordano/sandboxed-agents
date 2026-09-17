{
  pkgs,
  pkg,
  backend ? "bwrap",
}:
import ../../lib/tests/sandbox.nix {
  inherit pkgs pkg backend;
  agent = "opencode";
  mockApi = {
    baseUrlEnv = "ANTHROPIC_BASE_URL";
    apiKeyEnv = "ANTHROPIC_API_KEY";
    dummyApiKey = "sk-ant-api03-test-dummy-key-for-sandbox";
    promptArgs = ''run "say hello" -m anthropic/claude-sonnet-4-5'';
    preAgentSetup = ''
      machine.log("Test 12a: cccp plugin is seeded iff cccp is on the sandbox PATH")
      machine.succeed(sh("if command -v cccp >/dev/null 2>&1; then grep -q cccp-plugin ~/.config/opencode/plugin/cccp.js; else ! test -e ~/.config/opencode/plugin/cccp.js; fi"))
      machine.succeed("su - testuser -c 'mkdir -p /home/testuser/.config/opencode/plugin && echo // mine > /home/testuser/.config/opencode/plugin/cccp.js'")
      _mine = machine.succeed(sh("cat ~/.config/opencode/plugin/cccp.js") + " 2>&1")
      assert "// mine" in _mine, f"user plugin file was clobbered: {_mine[:300]}"
      if "cccp" in machine.succeed(sh("command -v cccp || true")):
          assert "not the cccp plugin" in _mine, f"missing clobber warning: {_mine[:300]}"
      machine.succeed("rm /home/testuser/.config/opencode/plugin/cccp.js")
    '';
  };
}
