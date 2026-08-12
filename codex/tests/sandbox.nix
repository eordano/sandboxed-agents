{
  pkgs,
  pkg,
  backend ? "bwrap",
}:
import ../../lib/tests/sandbox.nix {
  inherit pkgs pkg backend;
  agent = "codex";
  mockApi = {
    baseUrlEnv = "";
    apiKeyEnv = "OPENAI_API_KEY";
    dummyApiKey = "sk-test-dummy-key-for-codex-sandbox-testing";
    promptArgs = ''-c 'model_provider="openai-key"' exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "say hello"'';
    preAgentSetup = ''
      _codex_base_url = f"http://{server_ip}:8090"
      machine.succeed(
          f"su - testuser -c 'mkdir -p /home/testuser/.codex && cat > /home/testuser/.codex/config.toml << TOML\n"
          f"[model_providers.openai-key]\n"
          f"name = \"OpenAI (API key)\"\n"
          f"env_key = \"OPENAI_API_KEY\"\n"
          f"base_url = \"{_codex_base_url}\"\n"
          f"TOML\n'"
      )
    '';
    apiLogCheck = "responses";
    skipApiKeyCheck = true;
  };
}
