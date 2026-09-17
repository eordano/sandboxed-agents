# codesum

Hermes plugin: a fast code-reading agent. Registers a `summarize_code` tool
(the main agent calls it instead of reading big files raw) and a
`/codesum <path> [brief|normal|deep]` slash command. Both summarize a file or
directory via Cerebras `qwen-3.8-27b` — chosen because Cerebras serves it at
~1000 tok/s, so a 30-file repo scan costs seconds, not minutes.

Design notes:

- **ctx.llm, not a subagent** — one bounded completion per file through the
  host's plugin LLM lane; credentials stay host-owned, calls are audited under
  `purpose=codesum`. Directory runs fan out over a small thread pool and end
  with a roll-up architecture overview.
- **Trust gate** — pinning `provider=cerebras` / `model=qwen-3.8-27b` requires
  operator opt-in. The colmena `hermes-all` module grants exactly that pair
  (`plugins.entries.codesum` in the generated config.yaml); without the grant
  the plugin falls back to the user's active model rather than failing.
- **Content-hash cache** — summaries land in a sqlite DB under
  `<HERMES_HOME>/plugin-data/codesum/`, keyed by sha256 of file content +
  detail level, so unchanged files are never re-sent.
- **Reasoning-budget quirk** — qwen-3.8-27b spends completion tokens on
  reasoning and can return empty content; `_llm()` over-provisions
  `max_tokens` and retries once before falling back.

Deployed by `modules/desktop/agents/hermes.nix` (`programs.hermes.plugins`),
which copies this directory into `~/.hermes/plugins/codesum` on activation.
