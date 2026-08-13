{
  pkgs,
  pkg,
  backend ? "bwrap",
}:
import ../../lib/tests/sandbox.nix {
  inherit pkgs pkg backend;
  agent = "aider";
  mockApi = {
    baseUrlEnv = "ANTHROPIC_BASE_URL";
    apiKeyEnv = "ANTHROPIC_API_KEY";
    dummyApiKey = "sk-ant-api03-test-dummy-key-for-sandbox";
    promptArgs = ''--no-git --yes-always --no-pretty --model claude-3-haiku-20240307 --message "say hello"'';
  };
}
