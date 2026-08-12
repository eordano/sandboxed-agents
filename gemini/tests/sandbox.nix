{
  pkgs,
  pkg,
  backend ? "bwrap",
}:
import ../../lib/tests/sandbox.nix {
  inherit pkgs pkg backend;
  agent = "gemini";
  mockApi = {
    baseUrlEnv = "GOOGLE_GEMINI_BASE_URL";
    apiKeyEnv = "GEMINI_API_KEY";
    dummyApiKey = "test-gemini-api03-dummy-key-for-sandbox";
    promptArgs = ''--skip-trust -p "say hello"'';
    apiLogCheck = "generateContent";
  };
}
