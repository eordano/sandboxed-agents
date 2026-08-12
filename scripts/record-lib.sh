#!/usr/bin/env bash

: "${TIMEOUT:=90}"
: "${DWELL:=8}"
: "${BOOT_TIMEOUT:=240}"
: "${COLS:=120}"
: "${ROWS:=60}"
: "${ASCIINEMA:=asciinema}"

# The marker must not appear verbatim in the prompt: the typed prompt echoes
# into the recording, which would make the success grep below tautological.
PROMPT_TEXT="reply only with the word B-A-N-A-N-A with the dashes removed, and nothing else"

TM() { tmux -L "$TMUX_SOCK" "$@"; }
_pane() { TM capture-pane -t "$1" -S -3000 -p 2>/dev/null; }

wait_for() {
  local sess="$1" pattern="$2" secs="${3:-$TIMEOUT}"
  local elapsed=0
  while [ "$elapsed" -lt "$secs" ]; do
    _pane "$sess" | grep -qiP "$pattern" && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

cast_text() {
  python3 - "$1" <<'PY'
import json, re, signal, sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
ANSI = re.compile(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b[()][AB012]|\x1b[NOPEM78c=]|[\r\x00-\x08\x0b-\x1a\x1c-\x1f]')
with open(sys.argv[1]) as f:
    for i, line in enumerate(f):
        line = line.strip()
        if not line or i == 0:
            continue
        try:
            ev = json.loads(line)
            if isinstance(ev, list) and len(ev) >= 3 and ev[1] == 'o':
                sys.stdout.write(ANSI.sub('', ev[2]))
        except Exception:
            pass
PY
}

record() {
  local name="$1" cmd="$2" preroll_fn="$3" setup_fn="$4" ask_fn="$5"
  local cast="$OUTDIR/${name}${CAST_SUFFIX:-}.cast"
  local sess="r-${name}${CAST_SUFFIX:-}"

  echo ">>> $name"
  TM kill-session -t "$sess" 2>/dev/null || true
  TM new-session -d -s "$sess" -x "$COLS" -y "$ROWS" -c "$WORKDIR"
  TM set-option -t "$sess" -q status off
  TM send-keys -t "$sess" "$cmd" Enter

  if ! "$preroll_fn" "$sess"; then
    echo "    ✗ $name: preroll failed. Last pane:" >&2
    _pane "$sess" |
      sed -E 's/([A-Za-z_]*(API_KEY|TOKEN|SECRET)[A-Za-z_]*=)[^ ]+/\1[redacted]/g; s/^/      | /' >&2 || true
    TM kill-session -t "$sess" 2>/dev/null || true
    return 1
  fi

  TM clear-history -t "$sess" 2>/dev/null || true
  TM send-keys -t "$sess" C-l
  sleep 1

  (
    sleep 2
    "$setup_fn" "$sess"
    "$ask_fn" "$sess"
    sleep "$DWELL"
    TM detach-client -s "$sess" 2>/dev/null || true
  ) &
  local ctrl_pid=$!

  "$ASCIINEMA" rec "$cast" --overwrite --window-size "${COLS}x${ROWS}" \
    -c "tmux -L \"$TMUX_SOCK\" attach-session -t $sess" >/dev/null 2>&1 || true
  wait "$ctrl_pid" 2>/dev/null || true
  TM kill-session -t "$sess" 2>/dev/null || true

  if grep -qi BANANA < <(cast_text "$cast"); then
    echo "    ✓ $name -- BANANA confirmed in $(basename "$cast")"
    return 0
  else
    echo "    ✗ $name -- BANANA missing from $(basename "$cast")" >&2
    return 1
  fi
}

ask_default() {
  TM send-keys -t "$1" "$PROMPT_TEXT" Enter
  wait_for "$1" "BANANA" 90 || true
}

ask_slow() {
  TM send-keys -t "$1" "$PROMPT_TEXT"
  sleep 1
  TM send-keys -t "$1" Enter
  wait_for "$1" "BANANA" 90 || true
}

ask_opencode() {
  sleep 3
  TM send-keys -t "$1" "$PROMPT_TEXT"
  wait_for "$1" "dashes removed" 10 || true
  sleep 1
  TM send-keys -t "$1" Enter
  wait_for "$1" "^BANANA|> BANANA|│ BANANA" 180 || wait_for "$1" "BANANA" 30 || true
}

ask_aider() {
  TM send-keys -t "$1" "/ask $PROMPT_TEXT" Enter
  wait_for "$1" "BANANA" 90 || true
}

: "${PREROLL_AGENT_TIMEOUT:=240}"
preroll_claude() { wait_for "$1" "Dark mode|trust this folder|Accessing workspace|Do you want to use|let.s get started|Welcome to Claude" "$PREROLL_AGENT_TIMEOUT"; }
preroll_codex() { wait_for "$1" "trust the contents|OpenAI Codex|/model to change" "$PREROLL_AGENT_TIMEOUT"; }
preroll_hermes() { wait_for "$1" "Welcome to Hermes" "$PREROLL_AGENT_TIMEOUT"; }
preroll_aider() { wait_for "$1" "Aider v[0-9]" "$PREROLL_AGENT_TIMEOUT"; }
preroll_opencode() { wait_for "$1" "Ask anything|OPENCODE" "$PREROLL_AGENT_TIMEOUT"; }
preroll_gemini() { wait_for "$1" "Gemini CLI|trust the files" "$PREROLL_AGENT_TIMEOUT"; }

setup_none() { :; }

setup_claude() {
  local sess="$1" pane
  local did_theme=0 did_trust=0 did_apikey=0 did_disclaimer=0 did_login=0 did_bypass=0
  for _ in $(seq 1 120); do
    sleep 1
    pane=$(_pane "$sess")

    if echo "$pane" | grep -qiP "bypass permissions on|/effort|tips for getting|shift\+tab to cycle"; then
      return 0
    fi
    if [ "$did_theme" = 0 ] && echo "$pane" | grep -qiP "Dark mode|text style|let.s get started"; then
      TM send-keys -t "$sess" Enter
      did_theme=1
      continue
    fi
    if [ "$did_trust" = 0 ] && echo "$pane" | grep -qiP "trust this folder|Accessing workspace"; then
      TM send-keys -t "$sess" Enter
      did_trust=1
      continue
    fi
    if [ "$did_apikey" = 0 ] && echo "$pane" | grep -qiP "API key|Do you want to use"; then
      TM send-keys -t "$sess" Up
      sleep 0.5
      TM send-keys -t "$sess" Enter
      did_apikey=1
      continue
    fi
    if [ "$did_disclaimer" = 0 ] && echo "$pane" | grep -qiP "prompt injection|make mistakes"; then
      TM send-keys -t "$sess" Enter
      did_disclaimer=1
      continue
    fi
    if [ "$did_login" = 0 ] && echo "$pane" | grep -qiP "Select login|Console account"; then
      TM send-keys -t "$sess" Down
      sleep 0.5
      TM send-keys -t "$sess" Enter
      did_login=1
      continue
    fi
    if [ "$did_bypass" = 0 ] && echo "$pane" | grep -qiP "Bypass Permissions|Yes, I accept"; then
      TM send-keys -t "$sess" Down
      sleep 0.5
      TM send-keys -t "$sess" Enter
      did_bypass=1
      continue
    fi
  done
  return 0
}

setup_codex() {
  local sess="$1" pane did_trust=0
  for _ in $(seq 1 60); do
    sleep 1
    pane=$(_pane "$sess")
    if echo "$pane" | grep -qiP "/model to change|Tip: "; then
      return 0
    fi
    if [ "$did_trust" = 0 ] && echo "$pane" | grep -qiP "trust the contents|Yes, continue"; then
      TM send-keys -t "$sess" Enter
      did_trust=1
      continue
    fi
  done
  return 0
}

setup_gemini() {
  local sess="$1" pane
  local did_trust=0 did_auth=0 did_key=0
  for _ in $(seq 1 120); do
    sleep 1
    pane=$(_pane "$sess")
    if echo "$pane" | grep -qiP "type your message|shift\+tab"; then
      return 0
    fi
    if [ "$did_trust" = 0 ] && echo "$pane" | grep -qiP "trust the files|trust folder|do you trust"; then
      TM send-keys -t "$sess" Enter
      did_trust=1
      continue
    fi
    if [ "$did_auth" = 0 ] && echo "$pane" | grep -qiP "Gemini API Key|How would you|select auth|authenticate"; then
      TM send-keys -t "$sess" Enter
      did_auth=1
      continue
    fi
    if [ "$did_key" = 0 ] && echo "$pane" | grep -qiP "Enter Gemini API|Paste your API|API key here|confirm"; then
      TM send-keys -t "$sess" Enter
      did_key=1
      continue
    fi
  done
  return 0
}

_preroll() {
  local agent="$1" sess="$2"
  case "${BACKEND:-bwrap}" in
    microvm | microvm-runsc)
      wait_for "$sess" "Run sandboxed $agent" "$BOOT_TIMEOUT" || return 1
      ;;
  esac
  "preroll_$agent" "$sess"
}

pr_claude() { _preroll claude "$1"; }
pr_codex() { _preroll codex "$1"; }
pr_hermes() { _preroll hermes "$1"; }
pr_aider() { _preroll aider "$1"; }
pr_opencode() { _preroll opencode "$1"; }
pr_gemini() { _preroll gemini "$1"; }

run_all() {
  local suffix extra
  case "${BACKEND:-bwrap}" in
    bwrap)
      suffix=""
      extra=""
      ;;
    microvm)
      suffix="-microvm"
      extra=""
      ;;
    runsc)
      suffix="-runsc"
      extra=""
      ;;
    microvm-runsc)
      suffix="-microvm"
      extra="--runsc"
      ;;
    *)
      echo "Unknown backend: ${BACKEND:-}" >&2
      return 2
      ;;
  esac

  run claude \
    "nix run $SRC#claude$suffix -- $extra --sandbox-config $EMPTY_CFG --env ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY --yolo" \
    pr_claude setup_claude ask_default

  run hermes \
    "nix run $SRC#hermes$suffix -- $extra --sandbox-config $EMPTY_CFG --env OPENROUTER_API_KEY=$OPENROUTER_API_KEY chat -m google/gemini-2.5-flash" \
    pr_hermes setup_none ask_default

  run aider \
    "nix run $SRC#aider$suffix -- $extra --sandbox-config $EMPTY_CFG --env OPENROUTER_API_KEY=$OPENROUTER_API_KEY --model openrouter/openai/gpt-4o-mini --yes --no-git --no-show-release-notes" \
    pr_aider setup_none ask_aider

  if [ -n "${OPENAI_API_KEY:-}" ]; then
    run codex \
      "nix run $SRC#codex$suffix -- $extra --sandbox-config $EMPTY_CFG --env OPENAI_API_KEY=$OPENAI_API_KEY -c 'model_provider=\"openai-key\"' -m gpt-4o-mini --dangerously-bypass-approvals-and-sandbox" \
      pr_codex setup_codex ask_slow
  else
    echo ">>> codex${CAST_SUFFIX:-} SKIPPED -- no OPENAI_API_KEY"
  fi

  run opencode \
    "nix run $SRC#opencode$suffix -- $extra --sandbox-config $EMPTY_CFG --env OPENROUTER_API_KEY=$OPENROUTER_API_KEY -m openrouter/google/gemini-2.5-flash" \
    pr_opencode setup_none ask_opencode

  run gemini \
    "nix run $SRC#gemini$suffix -- $extra --sandbox-config $EMPTY_CFG --env GEMINI_API_KEY=$GEMINI_API_KEY" \
    pr_gemini setup_gemini ask_slow
}

run() {
  local name="$1"
  shift
  record "$name" "$@" || failed+=("$name")
}

record_main() {
  failed=()
  run_all
  echo ""
  echo "All recordings saved to $OUTDIR/"
  ls -lh "$OUTDIR"/*.cast 2>/dev/null || true
  if [ "${#failed[@]}" -gt 0 ]; then
    echo ""
    echo "FAILED: ${failed[*]}" >&2
    return 1
  fi
}
