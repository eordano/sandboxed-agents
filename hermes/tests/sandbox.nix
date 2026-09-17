{
  pkgs,
  pkg,
  backend ? "bwrap",
}:
import ../../lib/tests/sandbox.nix {
  inherit pkgs pkg backend;
  agent = "hermes";
  mockApi = {
    baseUrlEnv = "ANTHROPIC_BASE_URL";
    apiKeyEnv = "ANTHROPIC_API_KEY";
    dummyApiKey = "sk-ant-api03-test-dummy-key-for-sandbox";
    promptArgs = ''chat -q "say hello" --provider anthropic -Q --max-turns 1'';
    preAgentSetup = ''
      machine.succeed("mkdir -p /home/testuser/.hermes")
      machine.succeed(f"printf 'model:\\n  provider: anthropic\\n  base_url: http://{server_ip}:8090\\ncompression:\\n  enabled: true\\nterminal:\\n  backend: local\\n  cwd: .\\nplugins:\\n  enabled:\\n  - cccp\\n' > /home/testuser/.hermes/config.yaml")
      machine.succeed("chown -R testuser:users /home/testuser/.hermes")
      machine.log("hermes: a cccp package on the sandbox PATH that carries the plugin implies ~/.hermes/plugins/cccp is shipped")
      machine.succeed(sh("_c=$(command -v cccp) || exit 0; _p=$(dirname \"$_c\")/../share/cccp/plugin/hermes; [ -d \"$_p\" ] || exit 0; test -f ~/.hermes/plugins/cccp/plugin.yaml && test -f ~/.hermes/plugins/cccp/__init__.py"))
    '';
  };
}
