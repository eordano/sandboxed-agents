"""codesum — fast code summarization via Cerebras qwen-3.8-27b.

Handlers receive (args: dict, **kwargs) and return JSON strings.
ctx is injected via set_ctx() from __init__.py at registration time.
"""

import fnmatch
import hashlib
import json
import os
import re
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

_ctx = None  # PluginContext, set by register()

PROVIDER = "cerebras"
MODEL = "qwen-3.8-27b"
MAX_CHARS = 60_000          # per-file char budget sent to the model
DEFAULT_MAX_FILES = 30
WORKERS = 4

TEXT_EXTS = {
    ".py", ".js", ".ts", ".tsx", ".jsx", ".mjs", ".go", ".rs", ".c", ".cc",
    ".cpp", ".h", ".hpp", ".java", ".rb", ".sh", ".bash", ".zsh", ".fish",
    ".nix", ".el", ".org", ".lua", ".vim", ".hs", ".ml", ".clj", ".ex",
    ".exs", ".erl", ".kt", ".swift", ".scala", ".pl", ".r", ".jl", ".zig",
    ".d", ".proto", ".graphql", ".tf", ".sql", ".css", ".html", ".yaml",
    ".yml", ".toml", ".md",
}
SKIP_PATTERNS = [
    "*.lock", "*-lock.json", "*.min.js", "*.min.css", "*.svg", "*.map",
    "package-lock.json", "yarn.lock", "flake.lock",
]
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__",
             "dist", "build", "target", ".direnv", "result"}

_DETAIL_PROMPTS = {
    "brief": (
        "Summarize this source file in 2-3 sentences: what it is for and "
        "what its most important exported symbols do. No preamble."
    ),
    "normal": (
        "Summarize this source file compactly (~10 lines) with these "
        "sections:\n"
        "PURPOSE: one sentence.\n"
        "KEY SYMBOLS: the important functions/classes/vars with one-line "
        "descriptions and notable signatures.\n"
        "DEPENDENCIES: imports/modules/files it relies on.\n"
        "GOTCHAS: side effects, global state, tricky invariants, TODO/FIXME "
        "(write 'none' if none).\n"
        "Be terse and factual. No preamble, no code blocks."
    ),
    "deep": (
        "Thoroughly summarize this source file. Cover: overall purpose; "
        "every significant function/class with its signature, behavior, and "
        "callers/callees where evident; data structures; dependencies; side "
        "effects and global state; error handling; anything surprising or "
        "fragile. Stay factual and organized with short headings. No "
        "preamble."
    ),
}

_SYSTEM = (
    "You are a fast code-reading assistant. You produce accurate, terse "
    "summaries of source code for another engineer or AI agent. Never "
    "invent symbols that are not in the code. /no_think"
)


def set_ctx(ctx):
    global _ctx
    _ctx = ctx


# ---------------------------------------------------------------- cache

_cache_lock = threading.Lock()


def _cache_conn():
    """Open a short-lived, thread-local sqlite connection (or None)."""
    conn = None
    try:
        from plugins.plugin_storage import plugin_data_dir
        data_dir = plugin_data_dir("codesum")
    except Exception:
        home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
        data_dir = home / "plugin-data" / "codesum"
    try:
        import sqlite3
        data_dir.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(data_dir / "data.db"), timeout=15)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS summaries ("
            "key TEXT PRIMARY KEY, path TEXT, model TEXT, detail TEXT, "
            "summary TEXT, created REAL)"
        )
        conn.commit()
        return conn
    except Exception:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
        return None


def _cache_get(key: str):
    with _cache_lock:
        conn = _cache_conn()
        if conn is None:
            return None
        try:
            row = conn.execute(
                "SELECT summary FROM summaries WHERE key = ?", (key,)
            ).fetchone()
            return row[0] if row else None
        except Exception:
            return None
        finally:
            conn.close()


def _cache_put(key: str, path: str, detail: str, summary: str):
    with _cache_lock:
        conn = _cache_conn()
        if conn is None:
            return
        try:
            conn.execute(
                "INSERT OR REPLACE INTO summaries VALUES (?,?,?,?,?,?)",
                (key, path, MODEL, detail, summary, time.time()),
            )
            conn.commit()
        except Exception:
            pass
        finally:
            conn.close()


def _cache_key(content: str, detail: str) -> str:
    h = hashlib.sha256(content.encode("utf-8", "replace")).hexdigest()
    return f"{MODEL}:{detail}:{h}"


# ---------------------------------------------------------------- llm

def _strip_think(text: str) -> str:
    return re.sub(r"<think>.*?</think>", "", text or "", flags=re.S).strip()


def _llm(messages, max_tokens=1024):
    """Call Cerebras qwen-3.8-27b; retry once (transient errors, or the
    reasoning budget swallowing the whole completion), then fall back to
    the user's active model."""
    first_err = None
    for attempt in range(2):
        try:
            r = _ctx.llm.complete(
                messages=messages, provider=PROVIDER, model=MODEL,
                temperature=0.2,
                # Reasoning tokens count against the completion budget on
                # this model; over-provision so content isn't starved.
                max_tokens=max_tokens * (3 if attempt else 2),
                timeout=60, purpose="codesum",
            )
            text = _strip_think(r.text)
            if not text:
                raise RuntimeError("empty content (reasoning ate the budget)")
            return text, f"{r.provider}:{r.model}"
        except Exception as e:
            first_err = f"{type(e).__name__}: {e}"
            if attempt == 0:
                time.sleep(1.0)
    # fallback: user's active provider/model (always permitted)
    r = _ctx.llm.complete(
        messages=messages, temperature=0.2, max_tokens=max_tokens,
        timeout=120, purpose="codesum-fallback",
    )
    return _strip_think(r.text), f"{r.provider}:{r.model} (fallback: {first_err})"


# ---------------------------------------------------------------- files

def _skip(path: Path) -> bool:
    if path.suffix.lower() not in TEXT_EXTS:
        return True
    name = path.name
    return any(fnmatch.fnmatch(name, p) for p in SKIP_PATTERNS)


def _collect(root: Path, max_files: int):
    """Return (files, skipped_count). Git-aware when inside a repo."""
    if root.is_file():
        return [root], 0
    files, skipped = [], 0
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--cached", "--others",
             "--exclude-standard"],
            capture_output=True, text=True, timeout=15,
        )
        candidates = ([root / line for line in out.stdout.splitlines()]
                      if out.returncode == 0 else None)
    except Exception:
        candidates = None
    if candidates is None:
        candidates = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            candidates.extend(Path(dirpath) / f for f in filenames)
    for p in sorted(candidates):
        if not p.is_file() or _skip(p):
            skipped += 1
            continue
        files.append(p)
    if len(files) > max_files:
        skipped += len(files) - max_files
        files = files[:max_files]
    return files, skipped


def _read(path: Path) -> str:
    text = path.read_text(encoding="utf-8", errors="replace")
    if len(text) > MAX_CHARS:
        half = MAX_CHARS // 2
        text = (text[:half]
                + f"\n\n[... {len(text) - MAX_CHARS} chars omitted ...]\n\n"
                + text[-half:])
    return text


# ---------------------------------------------------------------- core

def _summarize_one(path: Path, detail: str, no_cache: bool):
    try:
        content = _read(path)
    except Exception as e:
        return {"path": str(path), "error": f"read failed: {e}"}
    key = _cache_key(content, detail)
    if not no_cache:
        cached = _cache_get(key)
        if cached is not None:
            return {"path": str(path), "summary": cached, "cached": True}
    prompt = (f"{_DETAIL_PROMPTS[detail]}\n\nFile: {path}\n"
              f"```\n{content}\n```")
    try:
        summary, model_used = _llm(
            [{"role": "system", "content": _SYSTEM},
             {"role": "user", "content": prompt}],
            max_tokens=2048 if detail == "deep" else 1024,
        )
    except Exception as e:
        return {"path": str(path), "error": f"llm failed: {e}"}
    _cache_put(key, str(path), detail, summary)
    return {"path": str(path), "summary": summary, "cached": False,
            "model": model_used}


def summarize_code(args: dict, **kwargs) -> str:
    if _ctx is None:
        return json.dumps({"error": "plugin context not initialized"})
    raw = (args.get("path") or "").strip()
    if not raw:
        return json.dumps({"error": "No path provided"})
    path = Path(os.path.expanduser(raw)).resolve()
    if not path.exists():
        return json.dumps({"error": f"Path not found: {path}"})
    detail = args.get("detail") or "normal"
    if detail not in _DETAIL_PROMPTS:
        detail = "normal"
    max_files = int(args.get("max_files") or DEFAULT_MAX_FILES)
    no_cache = bool(args.get("no_cache"))

    files, skipped = _collect(path, max_files)
    if not files:
        return json.dumps({"error": f"No summarizable source files under {path}",
                           "skipped": skipped})
    conn = _cache_conn()  # warm the schema once; per-op connections after
    if conn is not None:
        conn.close()
    if len(files) == 1:
        results = [_summarize_one(files[0], detail, no_cache)]
    else:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            results = list(pool.map(
                lambda f: _summarize_one(f, detail, no_cache),
                files))

    out = {"path": str(path), "detail": detail, "files": results,
           "skipped_files": skipped}

    ok = [r for r in results if "summary" in r]
    if len(ok) > 1:
        joined = "\n\n".join(
            f"== {r['path']} ==\n{r['summary']}" for r in ok)[:MAX_CHARS]
        try:
            overview, _ = _llm(
                [{"role": "system", "content": _SYSTEM},
                 {"role": "user", "content":
                  "Given these per-file summaries, write a short architecture "
                  "overview (5-10 lines): what this codebase/directory does, "
                  "how the pieces fit together, and where to start reading. "
                  "No preamble.\n\n" + joined}],
                max_tokens=1024,
            )
            out["overview"] = overview
        except Exception as e:
            out["overview_error"] = str(e)
    return json.dumps(out)


def slash_codesum(raw_args: str) -> str:
    """/codesum <path> [brief|normal|deep] — human-facing wrapper."""
    parts = (raw_args or "").split()
    if not parts:
        return "Usage: /codesum <path> [brief|normal|deep]"
    detail = "normal"
    if len(parts) > 1 and parts[-1] in _DETAIL_PROMPTS:
        detail = parts[-1]
        parts = parts[:-1]
    result = json.loads(summarize_code(
        {"path": " ".join(parts), "detail": detail}))
    if "error" in result:
        return f"codesum error: {result['error']}"
    lines = []
    for r in result["files"]:
        tag = " (cached)" if r.get("cached") else ""
        body = r.get("summary") or f"ERROR: {r.get('error')}"
        lines.append(f"--- {r['path']}{tag} ---\n{body}")
    if result.get("overview"):
        lines.append(f"=== OVERVIEW ===\n{result['overview']}")
    if result.get("skipped_files"):
        lines.append(f"({result['skipped_files']} files skipped)")
    return "\n\n".join(lines)
