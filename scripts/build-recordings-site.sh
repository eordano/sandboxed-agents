#!/usr/bin/env bash

set -euo pipefail

SITE_DIR="${1:-/tmp/recordings}"
VENDOR_DIR="$SITE_DIR/vendor"
PLAYER_VERSION="3.15.1"
PLAYER_CDN="https://cdn.jsdelivr.net/npm/asciinema-player@${PLAYER_VERSION}/dist/bundle"

mkdir -p "$VENDOR_DIR"

for asset in asciinema-player.min.js asciinema-player.css; do
  if [ ! -s "$VENDOR_DIR/$asset" ]; then
    echo "[build-site] fetching vendor/$asset" >&2
    curl -fsSL "$PLAYER_CDN/$asset" -o "$VENDOR_DIR/$asset" || {
      rm -f "$VENDOR_DIR/$asset"
      echo "[build-site] warning: failed to fetch $asset" >&2
    }
  fi
done

cat >"$SITE_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>sandboxed-agents -- recordings</title>
  <link rel="stylesheet" href="vendor/asciinema-player.css" />
  <style>
    :root {
      --bg: #0d1117;
      --fg: #c9d1d9;
      --muted: #8b949e;
      --border: #30363d;
      --bwrap: #3fb950;
      --runsc: #58a6ff;
      --microvm: #f0883e;
      --microvm-runsc: #d2a8ff;
      --card-bg: #161b22;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--bg); color: var(--fg); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
    header { padding: 24px 32px 16px; border-bottom: 1px solid var(--border); }
    header h1 { margin: 0 0 8px; font-size: 20px; font-weight: 600; }
    header p { margin: 0; color: var(--muted); font-size: 13px; }
    .toolbar { padding: 16px 32px; display: flex; gap: 24px; flex-wrap: wrap; align-items: center; border-bottom: 1px solid var(--border); }
    .toolbar .group { display: flex; gap: 6px; align-items: center; }
    .toolbar .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; margin-right: 4px; }
    .toolbar button {
      background: transparent; color: var(--fg); border: 1px solid var(--border);
      padding: 4px 10px; border-radius: 4px; font-size: 12px; cursor: pointer;
      font-family: inherit; transition: all 0.15s;
    }
    .toolbar button:hover { background: #1c2128; }
    .toolbar button.active { background: #1c2128; border-color: var(--fg); }
    .toolbar button.bulk { color: var(--muted); margin-left: 4px; font-style: italic; }
    .toolbar button.bulk:hover { color: var(--fg); }
    .toolbar button.active[data-backend="bwrap"] { border-color: var(--bwrap); color: var(--bwrap); }
    .toolbar button.active[data-backend="runsc"] { border-color: var(--runsc); color: var(--runsc); }
    .toolbar button.active[data-backend="microvm"] { border-color: var(--microvm); color: var(--microvm); }
    .toolbar button.active[data-backend="microvm-runsc"] { border-color: var(--microvm-runsc); color: var(--microvm-runsc); }
    .grid {
      display: grid; gap: 20px; padding: 24px 32px;
      grid-template-columns: repeat(auto-fit, minmax(520px, 1fr));
    }
    .card {
      background: var(--card-bg); border: 1px solid var(--border); border-radius: 6px;
      overflow: hidden; display: flex; flex-direction: column;
    }
    .card.hidden { display: none; }
    .card header.ch {
      padding: 10px 14px; display: flex; justify-content: space-between; align-items: center;
      border-bottom: 1px solid var(--border); border-top: none;
    }
    .card header.ch .agent { font-weight: 600; font-size: 14px; }
    .pill {
      font-size: 11px; padding: 2px 8px; border-radius: 10px;
      text-transform: uppercase; letter-spacing: 0.05em; font-weight: 500;
    }
    .pill[data-backend="bwrap"] { background: rgba(63,185,80,0.15); color: var(--bwrap); }
    .pill[data-backend="runsc"] { background: rgba(88,166,255,0.15); color: var(--runsc); }
    .pill[data-backend="microvm"] { background: rgba(240,136,62,0.15); color: var(--microvm); }
    .pill[data-backend="microvm-runsc"] { background: rgba(210,168,255,0.15); color: var(--microvm-runsc); }
    .player { min-height: 360px; background: #000; }
    .placeholder {
      padding: 40px 20px; color: var(--muted); font-size: 13px;
      text-align: center; font-family: monospace;
    }
  </style>
</head>
<body>
  <header>
    <h1>sandboxed-agents -- terminal recordings</h1>
    <p>Six agents x four backends (bubblewrap, runsc, microvm, microvm+runsc). Each asks the agent to reply with the word BANANA.</p>
  </header>
  <div class="toolbar">
    <div class="group">
      <span class="label">Backend</span>
      <button data-backend="bwrap" class="active">bubblewrap</button>
      <button data-backend="runsc" class="active">runsc</button>
      <button data-backend="microvm" class="active">microvm</button>
      <button data-backend="microvm-runsc" class="active">microvm+runsc</button>
      <button class="bulk" data-bulk="backend" data-action="all">all</button>
      <button class="bulk" data-bulk="backend" data-action="none">none</button>
    </div>
    <div class="group">
      <span class="label">Agent</span>
      <button data-agent="claude" class="active">claude</button>
      <button data-agent="codex" class="active">codex</button>
      <button data-agent="gemini" class="active">gemini</button>
      <button data-agent="hermes" class="active">hermes</button>
      <button data-agent="aider" class="active">aider</button>
      <button data-agent="opencode" class="active">opencode</button>
      <button class="bulk" data-bulk="agent" data-action="all">all</button>
      <button class="bulk" data-bulk="agent" data-action="none">none</button>
    </div>
  </div>
  <div class="grid" id="grid"></div>

  <script src="vendor/asciinema-player.min.js"></script>
  <script>
    const AGENTS = ["claude", "codex", "gemini", "hermes", "aider", "opencode"];
    const BACKENDS = ["bwrap", "runsc", "microvm", "microvm-runsc"];
    const grid = document.getElementById("grid");

    const cards = [];
    for (const backend of BACKENDS) {
      for (const agent of AGENTS) {
        const card = document.createElement("div");
        card.className = "card";
        card.dataset.agent = agent;
        card.dataset.backend = backend;
        card.innerHTML = `
          <header class="ch">
            <span class="agent">${agent}</span>
            <span class="pill" data-backend="${backend}">${backend}</span>
          </header>
          <div class="player" id="p-${agent}-${backend}"></div>
        `;
        grid.appendChild(card);
        cards.push({ card, agent, backend });

        const castUrl = `casts/${agent}-${backend}.cast`;
        fetch(castUrl, { method: "HEAD" }).then(r => {
          const el = document.getElementById(`p-${agent}-${backend}`);
          if (r.ok) {
            AsciinemaPlayer.create(castUrl, el, {
              cols: 120, rows: 60, fit: "width", idleTimeLimit: 2,
              theme: "monokai",
            });
          } else {
            el.innerHTML = `<div class="placeholder">no cast -- run scripts/record-agents.sh ${backend}</div>`;
          }
        }).catch(() => {
          const el = document.getElementById(`p-${agent}-${backend}`);
          el.innerHTML = `<div class="placeholder">failed to load</div>`;
        });
      }
    }

    function refresh() {
      const activeBackends = new Set(Array.from(document.querySelectorAll("button[data-backend].active")).map(b => b.dataset.backend));
      const activeAgents = new Set(Array.from(document.querySelectorAll("button[data-agent].active")).map(b => b.dataset.agent));
      for (const { card, agent, backend } of cards) {
        card.classList.toggle("hidden", !activeBackends.has(backend) || !activeAgents.has(agent));
      }
    }

    for (const btn of document.querySelectorAll(".toolbar button:not(.bulk)")) {
      btn.addEventListener("click", () => {
        btn.classList.toggle("active");
        refresh();
      });
    }
    for (const btn of document.querySelectorAll(".toolbar button.bulk")) {
      btn.addEventListener("click", () => {
        const attr = `data-${btn.dataset.bulk}`;
        const want = btn.dataset.action === "all";
        for (const t of document.querySelectorAll(`.toolbar button[${attr}]`)) {
          t.classList.toggle("active", want);
        }
        refresh();
      });
    }
  </script>
</body>
</html>
HTML

echo "[build-site] wrote $SITE_DIR/index.html"
