"""mitmproxy addon that sanitizes model API requests and restores responses."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from urllib.parse import urlparse

from mitmproxy import ctx, http

from privacy_core import ClassifierClient, MappingStore, Sanitizer


DEFAULT_HOSTS = "api.anthropic.com,api.openai.com,openrouter.ai,llm.decent.dev"


class PrivacyFilter:
    def __init__(self) -> None:
        state_home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
        mapping_path = Path(
            os.environ.get(
                "SANDBOX_PRIVACY_MAPPINGS",
                state_home / "sandboxed-agents/privacy-mappings.json",
            )
        )
        classifier_url = os.environ.get(
            "SANDBOX_PRIVACY_CLASSIFIER_URL",
            "https://llm.decent.dev/v1/pii/classify",
        )
        self.classifier_target = urlparse(classifier_url)
        self.hosts = {
            host.strip().lower()
            for host in os.environ.get("SANDBOX_PRIVACY_HOSTS", DEFAULT_HOSTS).split(",")
            if host.strip()
        }
        self.sanitizer = Sanitizer(
            MappingStore(mapping_path),
            ClassifierClient(
                classifier_url,
                token=os.environ.get("SANDBOX_PRIVACY_CLASSIFIER_TOKEN"),
                timeout=float(os.environ.get("SANDBOX_PRIVACY_CLASSIFIER_TIMEOUT", "15")),
            ),
        )

    def _selected(self, flow: http.HTTPFlow) -> bool:
        host = flow.request.pretty_host.lower()
        if host not in self.hosts:
            return False
        return not (
            host == (self.classifier_target.hostname or "").lower()
            and flow.request.path.startswith(self.classifier_target.path)
        )

    @staticmethod
    def _warn(flow: http.HTTPFlow, phase: str, detail: str) -> None:
        ctx.log.warn(
            f"privacy filter failed open during {phase} "
            f"for {flow.request.pretty_host}: {detail}"
        )

    async def request(self, flow: http.HTTPFlow) -> None:
        if not self._selected(flow) or not flow.request.raw_content:
            return
        content_type = flow.request.headers.get("content-type", "").split(";", 1)[0].lower()
        if content_type not in {"application/json", "application/x-ndjson"}:
            self._warn(
                flow,
                "request sanitization",
                f"unsupported content type: {content_type or 'missing'}",
            )
            return
        try:
            body = json.loads(flow.request.get_text(strict=True))
            sanitized = await asyncio.to_thread(self.sanitizer.sanitize_json, body)
            flow.request.set_text(json.dumps(sanitized, ensure_ascii=False, separators=(",", ":")))
        except Exception as exc:
            self._warn(flow, "request sanitization", f"{type(exc).__name__}: {exc}")

    def response(self, flow: http.HTTPFlow) -> None:
        if not self._selected(flow) or flow.response is None or not flow.response.raw_content:
            return
        content_type = flow.response.headers.get("content-type", "").split(";", 1)[0].lower()
        if content_type in {"application/json", "application/x-ndjson", "text/event-stream"}:
            try:
                restored = self.sanitizer.store.restore_json_bytes(flow.response.content)
            except Exception as exc:
                self._warn(flow, "response restoration", f"{type(exc).__name__}: {exc}")
            else:
                flow.response.content = restored



addons = [PrivacyFilter()]
