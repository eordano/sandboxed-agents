# Privacy Filter

Host-side, reversible PII pseudonymization for model API traffic from Codex,
Claude Code, OpenCode, and Hermes. It is a mitmproxy addon because an in-agent
hook could read the private mapping store and accidentally send it to a model.

## Behavior and security boundary

- The mapping file stays on the host and is rejected unless it has mode `0600`.
- The proxy fails open: if classification or restoration fails, JSON is
  malformed, or a model-bound body has an unsupported content type, it logs a
  local warning and forwards the original content unchanged.
- Previously learned values are replaced before classification, giving them a
  stable HMAC-derived pseudonym across agents and sessions.
- JSON and SSE responses are de-pseudonymized before the sandbox sees them.
- PII is sent to the configured classifier. The default is
  `https://llm.decent.dev/v1/pii/classify`; point the setting at a loopback
  Speaches-plus instance to keep classifier input on the host.

Classifier detection is probabilistic, and fail-open behavior prioritizes
availability over confidentiality: a classifier outage or format failure can
send unsanitized PII upstream. This is therefore not a hard DLP or "never leak"
boundary. Seed important exact values in the local mapping database by first
using them with a classifier that recognizes them, and prefer a reliable local
classifier to reduce bypasses.

## Run

```bash
nix run .#privacy-filter
# In another terminal:
claude --privacy-filter
```

The proxy listens as SOCKS5 on `127.0.0.1:1080`. mitmproxy's generated CA must
be mounted into the sandbox and trusted by the relevant runtime:

```bash
claude \
  --privacy-filter \
  --mount ro:$HOME/.mitmproxy/mitmproxy-ca-cert.pem:/run/privacy/ca.pem \
  --env SSL_CERT_FILE=/run/privacy/ca.pem \
  --env NODE_EXTRA_CA_CERTS=/run/privacy/ca.pem
```

Use `--privacy-filter` with `codex`, `opencode`, or `hermes` as well. The
sandbox setting is off by default; `SANDBOX_PRIVACY_FILTER=1` and config
`"privacyFilter": true` are equivalent. An explicit `socksProxy` overrides the
default host proxy endpoint. Hermes may
also need `--env REQUESTS_CA_BUNDLE=/run/privacy/ca.pem` for Python HTTP clients.

Configuration is environment-based because it belongs to the host proxy, not
the sandboxed agent:

| Variable | Default |
|---|---|
| `SANDBOX_PRIVACY_CLASSIFIER_URL` | `https://llm.decent.dev/v1/pii/classify` |
| `SANDBOX_PRIVACY_CLASSIFIER_TOKEN` | unset |
| `SANDBOX_PRIVACY_CLASSIFIER_TIMEOUT` | `15` |
| `SANDBOX_PRIVACY_MAPPINGS` | `$XDG_STATE_HOME/sandboxed-agents/privacy-mappings.json` |
| `SANDBOX_PRIVACY_HOSTS` | Anthropic, OpenAI, OpenRouter, and `llm.decent.dev` |
| `SANDBOX_PRIVACY_LISTEN` | `127.0.0.1:1080` |

For a loopback HTTP classifier, explicitly set
`SANDBOX_PRIVACY_ALLOW_HTTP=1`. Do not use that override for a non-loopback
address.
