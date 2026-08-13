{
  pkgs,
  pkg,
  backend ? "bwrap",
}:
import ../../lib/tests/sandbox.nix {
  inherit pkgs pkg backend;
  agent = "hermes";
  mockApi = {
    # Newer hermes only honors config.yaml base_url for API-mode detection;
    # the anthropic client itself needs the env var.
    baseUrlEnv = "ANTHROPIC_BASE_URL";
    apiKeyEnv = "ANTHROPIC_API_KEY";
    dummyApiKey = "sk-ant-api03-test-dummy-key-for-sandbox";
    promptArgs = ''chat -q "say hello" --provider anthropic -Q --max-turns 1'';
    preAgentSetup = ''
      machine.succeed("mkdir -p /home/testuser/.hermes")
      machine.succeed(f"printf 'model:\\n  provider: anthropic\\n  base_url: http://{server_ip}:8090\\ncompression:\\n  enabled: true\\nterminal:\\n  backend: local\\n  cwd: .\\n' > /home/testuser/.hermes/config.yaml")
      machine.succeed("chown -R testuser:users /home/testuser/.hermes")
    '';
  };
}
