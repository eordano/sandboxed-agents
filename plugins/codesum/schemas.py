"""Tool schemas — what the LLM sees."""

SUMMARIZE_CODE = {
    "name": "summarize_code",
    "description": (
        "Quickly read and summarize source code using a fast auxiliary model "
        "(Cerebras qwen-3.8-27b). Use this INSTEAD of reading large files raw: "
        "it returns a compact structured summary (purpose, key symbols, "
        "dependencies, gotchas) per file, plus an architecture overview for "
        "directories. Accepts a single file or a directory (git-aware, skips "
        "ignored/binary/lock files). Results are cached by content hash, so "
        "re-summarizing unchanged files is instant and free."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Absolute or relative path to a source file or directory.",
            },
            "detail": {
                "type": "string",
                "enum": ["brief", "normal", "deep"],
                "description": "Summary depth. brief=2-3 lines, normal=structured ~10 lines (default), deep=thorough per-symbol notes.",
            },
            "max_files": {
                "type": "integer",
                "description": "Max files to summarize on a directory run (default 30).",
            },
            "no_cache": {
                "type": "boolean",
                "description": "Force re-summarization even if a cached summary exists.",
            },
        },
        "required": ["path"],
    },
}
