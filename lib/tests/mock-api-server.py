#!/usr/bin/env python3
import base64
import hashlib
import json
import struct
import sys
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

MOCK_TEXT = "SANDBOX_MOCK_RESPONSE_OK"
LOG_FILE = "/tmp/mock-api-requests.log"
WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

class Handler(BaseHTTPRequestHandler):
    def _log(self, body=None):
        with open(LOG_FILE, "a") as f:
            entry = {"method": self.command, "path": self.path,
                     "headers": dict(self.headers), "timestamp": time.time()}
            if body:
                try:
                    entry["body"] = json.loads(body)
                except Exception:
                    entry["body_raw"] = body[:2000]
            f.write(json.dumps(entry) + "\n")

    def _json_resp(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _sse_ok(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

    def _sse_write(self, data, event=None):
        prefix = f"event: {event}\n" if event else ""
        self.wfile.write(f"{prefix}data: {json.dumps(data)}\n\n".encode())
        self.wfile.flush()

    def _sse_done(self):
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    @staticmethod
    def _wants_stream(body):
        try:
            return json.loads(body).get("stream", False)
        except Exception:
            return False

    def _ws_handshake(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(
            hashlib.sha1((key + WS_MAGIC).encode()).digest()
        ).decode()
        self.wfile.write(
            f"HTTP/1.1 101 Switching Protocols\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            f"\r\n".encode()
        )
        self.wfile.flush()

    def _ws_read_frame(self):
        try:
            header = self.rfile.read(2)
            if len(header) < 2:
                return None, b""
            b1, b2 = header[0], header[1]
            opcode = b1 & 0x0F
            masked = bool(b2 & 0x80)
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self.rfile.read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.rfile.read(8))[0]
            mask = self.rfile.read(4) if masked else None
            data = self.rfile.read(length) if length else b""
            if masked and mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            return opcode, data
        except Exception:
            return None, b""

    def _ws_send_text(self, text):
        try:
            payload = text.encode("utf-8")
            frame = bytearray([0x81])
            n = len(payload)
            if n < 126: frame.append(n)
            elif n < 65536: frame.append(126); frame.extend(struct.pack("!H", n))
            else: frame.append(127); frame.extend(struct.pack("!Q", n))
            frame.extend(payload)
            self.wfile.write(bytes(frame))
            self.wfile.flush()
        except Exception:
            pass

    def _ws_close(self):
        try:
            self.wfile.write(bytes([0x88, 0x00]))
            self.wfile.flush()
        except Exception:
            pass

    def _handle_websocket(self):
        self._log()
        self._ws_handshake()

        for _ in range(50):
            opcode, data = self._ws_read_frame()
            if opcode is None or opcode == 0x8:
                break
            if opcode == 0x1:
                text = data.decode("utf-8", errors="replace")
                with open(LOG_FILE, "a") as f:
                    f.write(json.dumps({
                        "method": "WS_MESSAGE",
                        "path": self.path,
                        "ws_data": text[:4000],
                        "timestamp": time.time(),
                    }) + "\n")
                try:
                    msg = json.loads(text)
                    if msg.get("type") == "response.create":
                        self._ws_send_responses_events()
                        break
                except (json.JSONDecodeError, KeyError):
                    pass

        self._ws_close()

    @staticmethod
    def _responses_events(extra_content_events=False):
        ts = int(time.time())
        rid, iid = f"resp_test_{ts}", f"msg_{ts}"
        idx = {"item_id": iid, "output_index": 0, "content_index": 0}
        done_msg = {"type": "message", "id": iid, "role": "assistant",
                    "content": [{"type": "output_text", "text": MOCK_TEXT}],
                    "status": "completed"}
        resp_base = {"id": rid, "object": "response", "created_at": ts, "model": "gpt-4o-mini"}
        events = [
            {"type": "response.created", "response": {**resp_base, "status": "in_progress", "output": [], "usage": None}},
            {"type": "response.output_item.added", "item": {"type": "message", "id": iid, "role": "assistant", "content": [], "status": "in_progress"}},
        ]
        if extra_content_events:
            events.append({"type": "response.content_part.added", **idx, "part": {"type": "output_text", "text": ""}})
        events.append({"type": "response.output_text.delta", **idx, "delta": MOCK_TEXT})
        if extra_content_events:
            events.append({"type": "response.content_part.done", **idx, "part": {"type": "output_text", "text": MOCK_TEXT}})
        events += [
            {"type": "response.output_item.done", "item": done_msg},
            {"type": "response.completed", "response": {**resp_base, "status": "completed", "output": [done_msg],
                "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15,
                           "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}}},
        ]
        return events

    def _ws_send_responses_events(self):
        for data in self._responses_events(extra_content_events=True):
            self._ws_send_text(json.dumps(data))

    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self._handle_websocket()
            return
        self._log()
        self._json_resp({"status": "ok"})

    def do_OPTIONS(self):
        self._log()
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode() if n else ""
        self._log(body)

        if "messages" in self.path:
            self._anthropic(body)
        elif "chat/completions" in self.path:
            self._openai(body)
        elif "responses" in self.path:
            self._openai_responses(body)
        elif "generateContent" in self.path or "streamGenerateContent" in self.path:
            self._google_genai(body)
        else:
            self._json_resp({"status": "ok"})

    def _anthropic(self, body):
        (self._anthropic_sse if self._wants_stream(body) else self._anthropic_json)()

    def _anthropic_json(self):
        self._json_resp({
            "id": "msg_test_001", "type": "message", "role": "assistant",
            "content": [{"type": "text", "text": MOCK_TEXT}],
            "model": "claude-sonnet-4-20250514",
            "stop_reason": "end_turn", "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 5},
        })

    def _anthropic_sse(self):
        self._sse_ok()
        mid = "msg_test_" + str(int(time.time()))
        events = [
            ("message_start", {"type": "message_start", "message": {
                "id": mid, "type": "message", "role": "assistant", "content": [],
                "model": "claude-sonnet-4-20250514", "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 10, "output_tokens": 0}}}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ("ping", {"type": "ping"}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": MOCK_TEXT}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 5}}),
            ("message_stop", {"type": "message_stop"}),
        ]
        for name, data in events:
            self._sse_write(data, event=name)

    def _openai(self, body):
        (self._openai_sse if self._wants_stream(body) else self._openai_json)()

    def _openai_json(self):
        ts = int(time.time())
        self._json_resp({
            "id": "chatcmpl-test001", "object": "chat.completion",
            "created": ts, "model": "test-model",
            "choices": [{"index": 0,
                         "message": {"role": "assistant", "content": MOCK_TEXT},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
        })

    def _openai_sse(self):
        self._sse_ok()
        ts = int(time.time())
        cid = f"chatcmpl-test{ts}"
        base = {"id": cid, "object": "chat.completion.chunk", "created": ts, "model": "test-model"}
        self._sse_write({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": MOCK_TEXT}, "finish_reason": None}]})
        self._sse_write({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self._sse_done()

    def _openai_responses(self, body):
        (self._openai_responses_sse if self._wants_stream(body) else self._openai_responses_json)()

    def _openai_responses_json(self):
        ts = int(time.time())
        self._json_resp({
            "id": f"resp_test_{ts}", "object": "response",
            "created_at": ts, "model": "gpt-4o-mini", "status": "completed",
            "output": [{"type": "message", "id": f"msg_test_{ts}",
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": MOCK_TEXT}],
                        "status": "completed"}],
            "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15},
        })

    def _openai_responses_sse(self):
        self._sse_ok()
        for data in self._responses_events():
            self._sse_write(data)
        self._sse_done()

    def _google_genai(self, body):
        (self._google_genai_sse if "streamGenerateContent" in self.path else self._google_genai_json)()

    def _google_genai_json(self):
        self._json_resp({
            "candidates": [{"content": {"parts": [{"text": MOCK_TEXT}], "role": "model"},
                            "finishReason": "STOP", "index": 0}],
            "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 5,
                              "totalTokenCount": 15},
            "modelVersion": "gemini-2.5-pro",
        })

    def _google_genai_sse(self):
        self._sse_ok()
        self._sse_write({"candidates": [{"content": {"parts": [{"text": MOCK_TEXT}], "role": "model"},
                                         "finishReason": "STOP", "index": 0}]})

    def log_message(self, fmt, *args):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
    # Threading: a single stalled websocket/half-open connection must not
    # wedge every other request for the whole VM test.
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()
