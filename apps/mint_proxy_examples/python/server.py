"""twai-api mint proxy — Python 3.11+ / FastAPI.

Fronts https://twai-api.<...>.azurecontainerapps.io with a browser-safe
facade the 2wai Flutter SDK can point at. Reads SK_KEY from the
environment; the browser never sees it.

Env:
    SK_KEY           = sk_test_... or sk_live_... (required)
    UPSTREAM         = https://twai-api.<...>.azurecontainerapps.io
                       (default: staging URL below)
    ALLOWED_ORIGIN   = https://myapp.com  (default: * — do NOT ship *)
    PORT             = 8787  (default)

Run:
    pip install -r requirements.txt
    SK_KEY=sk_test_... uvicorn server:app --host 0.0.0.0 --port 8787

Then point the SDK at http://localhost:8787.
"""
from __future__ import annotations

import os
import sys
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware

SK = os.environ.get("SK_KEY")
if not SK:
    print("FATAL: SK_KEY env var is required", file=sys.stderr)
    sys.exit(1)

UPSTREAM = os.environ.get(
    "UPSTREAM",
    "https://twai-api.purpleglacier-ffec85d8.westus2.azurecontainerapps.io",
)
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "*")

app = FastAPI(title="twai-api mint proxy", version="0.1.0")

# See README on tightening CORS for production.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[ALLOWED_ORIGIN] if ALLOWED_ORIGIN != "*" else ["*"],
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "X-Requested-With"],
    expose_headers=[
        "x-request-id",
        "x-twai-concurrent-sessions",
        "x-twai-max-concurrent-sessions",
        "retry-after",
    ],
)

_client = httpx.AsyncClient(timeout=30.0)

_EXPOSED = (
    "x-request-id",
    "x-twai-concurrent-sessions",
    "x-twai-max-concurrent-sessions",
    "retry-after",
)


async def _proxy(method: str, path: str, body: Any | None = None) -> Response:
    """Every SDK call routes through here — we add the sk_ server-side."""
    try:
        r = await _client.request(
            method,
            UPSTREAM + path,
            headers={"Authorization": f"Bearer {SK}"},
            json=body,
        )
    except httpx.HTTPError as e:
        return Response(
            content=f'{{"error":"upstream fetch failed: {e}"}}',
            status_code=502,
            media_type="application/json",
        )
    headers = {h: r.headers[h] for h in _EXPOSED if h in r.headers}
    return Response(
        content=r.content,
        status_code=r.status_code,
        media_type=r.headers.get("content-type", "application/json"),
        headers=headers,
    )


@app.post("/v1/sessions")
async def create_session(request: Request) -> Response:
    body = await request.json()
    return await _proxy("POST", "/v1/sessions", body)


@app.post("/v1/sessions/{sid}/speak")
async def speak(sid: str, request: Request) -> Response:
    body = await request.json()
    return await _proxy("POST", f"/v1/sessions/{sid}/speak", body)


@app.post("/v1/sessions/{sid}/interrupt")
async def interrupt(sid: str) -> Response:
    return await _proxy("POST", f"/v1/sessions/{sid}/interrupt")


@app.delete("/v1/sessions/{sid}")
async def delete_session(sid: str) -> Response:
    return await _proxy("DELETE", f"/v1/sessions/{sid}")


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}
