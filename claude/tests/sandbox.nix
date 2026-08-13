{
  pkgs,
  pkg,
  backend ? "bwrap",
}:
import ../../lib/tests/sandbox.nix {
  inherit pkgs pkg backend;
  agent = "claude";
  mockApi = {
    baseUrlEnv = "ANTHROPIC_BASE_URL";
    apiKeyEnv = "ANTHROPIC_API_KEY";
    dummyApiKey = "sk-ant-api03-test-dummy-key-for-sandbox";
    promptArgs = ''-p "say hello"'';
  };
}
