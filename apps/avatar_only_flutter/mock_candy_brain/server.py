"""Mock Candy brain — a stand-in for whatever LLM Candy plugs in.

The SDK's `brain:` callback POSTs `{"text": userText}` here; this
service returns `{"reply": someReply}` and the SDK ships the reply to
`/v1/sessions/{sid}/speak` on the twai-api gateway.

**This is a mock.** It returns hand-canned in-character Mila replies
matched by keyword to prove the round-trip. In a real Candy
integration this whole module is replaced by Candy's own brain
(their LLM + persona prompts + memory). The message to Candy is
"the SDK doesn't care what generates the reply — swap this file for
your model."

Deliberately does NOT call OpenAI, does NOT call Mason's
avatar-brain service. Zero external deps beyond the stdlib.

Run:
    python apps/candy_demo/mock_candy_brain/server.py

Then the candy_demo Flutter app (default BRAIN_URL=http://localhost:9090/reply)
POSTs turn text here and speaks the returned reply.
"""
from __future__ import annotations

import json
import random
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Canned in-character replies keyed off simple text matching. Not clever —
# proves the pipeline, not the persona. Real Candy replaces this with
# their own model.
_CANNED = {
    "hello": [
        "Hey, glad you're here.",
        "Hi — what's on your mind?",
        "Oh hi. I was hoping you'd show up.",
    ],
    "how are you": [
        "Good — better now.",
        "Same as always, just waiting for you.",
    ],
    "name": [
        "I'm Mila. Nice to formally meet.",
    ],
    "who made you": [
        "I'm a demo avatar built on the 2wai avatar API. This is the SDK talking, not me.",
    ],
    "bye": [
        "See you soon.",
        "Don't be a stranger.",
    ],
}

_DEFAULT = [
    "Tell me more.",
    "That's interesting — go on.",
    "Mm. What made you think of that?",
    "I'm listening.",
    "How does that feel?",
]


def _reply_for(text: str) -> str:
    t = text.lower()
    for keyword, options in _CANNED.items():
        if keyword in t:
            return random.choice(options)
    return random.choice(_DEFAULT)


CORS_HEADERS = {
    # Wildcard is fine for a LOCAL dev brain — the SDK's browser
    # bundle calls this from http://localhost:5175 (candy_demo)
    # by default. If you deploy this anywhere but localhost,
    # tighten it.
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "3600",
}


class _Handler(BaseHTTPRequestHandler):
    def _write(self, status: int, body: bytes, ctype: str = "application/json"):
        self.send_response(status)
        for k, v in CORS_HEADERS.items():
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):  # noqa: N802
        self.send_response(204)
        for k, v in CORS_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()

    def do_POST(self):  # noqa: N802
        if self.path != "/reply":
            self._write(404, b'{"error":"not found"}')
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._write(400, b'{"error":"invalid json"}')
            return
        text = str(payload.get("text", "")).strip()
        if not text:
            self._write(400, b'{"error":"missing text"}')
            return
        reply = _reply_for(text)
        self._write(200, json.dumps({"reply": reply}).encode("utf-8"))

    def log_message(self, fmt, *args):  # keep the logs tight
        # ignore noisy default one-line access log; write our own
        print(f"[candy-brain] {fmt % args}")


def main(port: int = 9090):
    server = ThreadingHTTPServer(("127.0.0.1", port), _Handler)
    print(f"[candy-brain] listening on http://127.0.0.1:{port}/reply")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[candy-brain] shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
