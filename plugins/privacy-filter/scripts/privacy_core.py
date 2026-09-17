"""PII pseudonymization core with no mitmproxy dependency."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import tempfile
import threading
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any


TOKEN_RE = re.compile(r"\[PII:[a-z0-9_]+:[0-9a-f]{16}\]")
LABEL_RE = re.compile(r"^[a-z0-9_]{1,64}$")
DATA_URL_RE = re.compile(r"^data:[^,;]+(?:;[^,;]+)*;base64,", re.IGNORECASE)


class PrivacyError(RuntimeError):
    """Raised when a request cannot be sanitized safely."""


@dataclass(frozen=True)
class Span:
    start: int
    end: int
    label: str


class MappingStore:
    """A mode-0600, atomic, reversible private-value mapping store."""

    def __init__(self, path: Path):
        self.path = path.expanduser()
        self._lock = threading.RLock()
        self._data = self._load()

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            return {"version": 1, "salt": secrets.token_hex(32), "mappings": {}}
        mode = self.path.stat().st_mode & 0o777
        if mode & 0o077:
            raise PrivacyError(f"mapping file must not be group/world accessible: {self.path}")
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise PrivacyError(f"cannot read mapping file: {exc}") from exc
        if data.get("version") != 1 or not isinstance(data.get("mappings"), dict):
            raise PrivacyError("unsupported or malformed mapping file")
        try:
            bytes.fromhex(data["salt"])
        except (KeyError, TypeError, ValueError) as exc:
            raise PrivacyError("mapping file has an invalid salt") from exc
        for private, entry in data["mappings"].items():
            if not isinstance(private, str) or not isinstance(entry, dict):
                raise PrivacyError("mapping file has an invalid entry")
            if not isinstance(entry.get("replacement"), str) or not isinstance(entry.get("label"), str):
                raise PrivacyError("mapping file has an invalid entry")
        return data

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.path.parent, 0o700)
        fd, tmp_name = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=self.path.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(self._data, handle, ensure_ascii=False, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp_name, self.path)
            os.chmod(self.path, 0o600)
        except BaseException:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass
            raise

    def get_or_create(self, private: str, label: str) -> str:
        if not private:
            raise PrivacyError("refusing to map an empty value")
        if not LABEL_RE.fullmatch(label):
            raise PrivacyError(f"classifier returned invalid label: {label!r}")
        with self._lock:
            old = self._data["mappings"].get(private)
            if old is not None:
                return old["replacement"]
            digest = hmac.new(
                bytes.fromhex(self._data["salt"]), private.encode("utf-8"), hashlib.sha256
            ).hexdigest()[:16]
            replacement = f"[PII:{label}:{digest}]"
            if any(v["replacement"] == replacement for v in self._data["mappings"].values()):
                raise PrivacyError("pseudonym collision; request blocked")
            self._data["mappings"][private] = {"label": label, "replacement": replacement}
            self._save()
            return replacement

    def sanitize_known(self, text: str) -> str:
        with self._lock:
            entries = sorted(self._data["mappings"].items(), key=lambda item: len(item[0]), reverse=True)
        for private, entry in entries:
            text = text.replace(private, entry["replacement"])
        return text

    def restore_json_bytes(self, body: bytes) -> bytes:
        """Restore tokens in JSON or SSE without breaking JSON string escaping."""
        with self._lock:
            entries = sorted(
                self._data["mappings"].items(),
                key=lambda item: len(item[1]["replacement"]),
                reverse=True,
            )
        for private, entry in entries:
            escaped = json.dumps(private, ensure_ascii=False)[1:-1].encode("utf-8")
            body = body.replace(entry["replacement"].encode("ascii"), escaped)
        return body


class ClassifierClient:
    def __init__(self, url: str, token: str | None = None, timeout: float = 15.0):
        if not url.startswith("https://") and os.environ.get("SANDBOX_PRIVACY_ALLOW_HTTP") != "1":
            raise PrivacyError("classifier URL must use HTTPS (or set SANDBOX_PRIVACY_ALLOW_HTTP=1)")
        self.url = url
        self.token = token
        self.timeout = timeout

    def classify(self, text: str) -> list[Span]:
        request = urllib.request.Request(
            self.url,
            data=json.dumps({"text": text}).encode("utf-8"),
            headers={"content-type": "application/json"},
            method="POST",
        )
        if self.token:
            request.add_header("authorization", f"Bearer {self.token}")
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=self.timeout) as response:
                payload = json.load(response)
        except Exception as exc:
            raise PrivacyError(f"classifier unavailable: {type(exc).__name__}") from exc
        if not isinstance(payload, dict) or not isinstance(payload.get("spans"), list):
            raise PrivacyError("classifier returned a malformed response")
        spans: list[Span] = []
        for raw in payload["spans"]:
            try:
                span = Span(int(raw["start"]), int(raw["endExclusive"]), raw["label"])
            except (KeyError, TypeError, ValueError) as exc:
                raise PrivacyError("classifier returned a malformed span") from exc
            if not (0 <= span.start < span.end <= len(text)) or not LABEL_RE.fullmatch(span.label):
                raise PrivacyError("classifier returned an invalid span")
            start, end = span.start, span.end
            while start < end and text[start].isspace():
                start += 1
            while end > start and text[end - 1].isspace():
                end -= 1
            span = Span(start, end, span.label)
            spans.append(span)
        spans.sort(key=lambda span: (span.start, span.end))
        for left, right in zip(spans, spans[1:]):
            if right.start < left.end:
                raise PrivacyError("classifier returned overlapping spans")
        return spans


class Sanitizer:
    def __init__(self, store: MappingStore, classifier: ClassifierClient):
        self.store = store
        self.classifier = classifier

    def sanitize_text(self, text: str) -> str:
        if not text:
            return text
        if DATA_URL_RE.match(text):
            raise PrivacyError("opaque base64 data URL blocked")
        text = self.store.sanitize_known(text)
        token_spans = [match.span() for match in TOKEN_RE.finditer(text)]
        spans = self.classifier.classify(text)
        for span in reversed(spans):
            if any(span.start < end and start < span.end for start, end in token_spans):
                continue
            private = text[span.start : span.end]
            replacement = self.store.get_or_create(private, span.label)
            text = text[: span.start] + replacement + text[span.end :]
        return text

    def sanitize_json(self, value: Any) -> Any:
        strings: list[str] = []

        def collect(item: Any) -> None:
            if isinstance(item, str):
                strings.append(item)
            elif isinstance(item, list):
                for child in item:
                    collect(child)
            elif isinstance(item, dict):
                for child in item.values():
                    collect(child)

        collect(value)
        unique = list(dict.fromkeys(strings))
        workers = min(8, len(unique))
        if workers:
            with ThreadPoolExecutor(max_workers=workers) as pool:
                replacements = dict(zip(unique, pool.map(self.sanitize_text, unique)))
        else:
            replacements = {}

        def rebuild(item: Any) -> Any:
            if isinstance(item, str):
                return replacements[item]
            if isinstance(item, list):
                return [rebuild(child) for child in item]
            if isinstance(item, dict):
                return {key: rebuild(child) for key, child in item.items()}
            return item

        return rebuild(value)
