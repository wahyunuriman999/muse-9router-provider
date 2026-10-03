#!/usr/bin/env python3
"""muse-relay bridge: OpenAI-compatible HTTP server that serves answers from
a Muse agent (async relay).

How it works:
  POST /v1/chat/completions  -> job written to queue/, HTTP connection HELD
                                open (long-poll) until the scheduled Muse
                                worker writes done/<jobid>.json (max 600s).
  GET  /v1/models            -> model list.

The worker is a scheduled job (e.g. every 2 min) whose agent IS Muse: it reads
queued jobs, answers with full memory/tools/skills, and writes the done file.
Typical latency: 2-6 minutes per request. This is honest async relay, NOT a
synchronous model API.

Configuration via environment (all optional):
  MUSE_RELAY_DATA_DIR  runtime data dir (queue/done/stale),
                       default ~/muse-9router-provider-data
  MUSE_RELAY_KEY_FILE  bearer-key file, default ~/.muse-9router-provider/.relay-key
  MUSE_RELAY_PORT      bind port, default 20129
  MUSE_RELAY_MODEL_ID  model id served, default muse-agent

Auth: Authorization: Bearer <key-from-key-file>. Binds 127.0.0.1 only.
"""
import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
BASE = os.environ.get("MUSE_RELAY_DATA_DIR",
                       os.path.join(HOME, "muse-9router-provider-data"))
QUEUE = os.path.join(BASE, "queue")
DONE = os.path.join(BASE, "done")
STALE = os.path.join(BASE, "stale")
LOG = os.path.join(BASE, "bridge.log")
KEY_FILE = os.environ.get("MUSE_RELAY_KEY_FILE",
                          os.path.join(HOME, ".muse-9router-provider", ".relay-key"))
PORT = int(os.environ.get("MUSE_RELAY_PORT", "20129"))
HOLD_SECS = 600
POLL_SECS = 2
MODEL_ID = os.environ.get("MUSE_RELAY_MODEL_ID", "muse-agent")
DEDUP_WINDOW_SECS = 600

try:
    with open(KEY_FILE) as f:
        BRIDGE_KEY = f.read().strip()
except OSError:
    sys.stderr.write(f"muse-relay: key file missing: {KEY_FILE}\n")
    sys.stderr.write("Run scripts/setup-relay.sh first.\n")
    sys.exit(1)
if not BRIDGE_KEY:
    sys.stderr.write(f"muse-relay: key file empty: {KEY_FILE}\n")
    sys.exit(1)


def _msg_hash(messages):
    import hashlib
    canon = json.dumps(messages, sort_keys=True, ensure_ascii=True)
    return hashlib.sha256(canon.encode()).hexdigest()[:16]


def _find_pending_dup(msg_hash):
    """Find a queued job with identical messages created recently and not
    yet answered (no done file). Returns job_id or None."""
    now = time.time()
    try:
        names = os.listdir(QUEUE)
    except OSError:
        return None
    for name in names:
        if not name.endswith(".json"):
            continue
        p = os.path.join(QUEUE, name)
        try:
            with open(p) as f:
                job = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if now - job.get("created_at", 0) > DEDUP_WINDOW_SECS:
            continue
        if _msg_hash(job.get("messages", [])) != msg_hash:
            continue
        jid = job.get("id")
        if jid and not os.path.exists(os.path.join(DONE, jid + ".json")):
            return jid
    return None


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "muse-relay/1.0"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self):
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {BRIDGE_KEY}"

    def do_GET(self):
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            if not self._auth_ok():
                return self._send(401, {"error": {"message": "invalid bridge key", "type": "auth"}})
            return self._send(200, {
                "object": "list",
                "data": [{
                    "id": MODEL_ID,
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": "muse-relay",
                }],
            })
        if self.path.rstrip("/") == "/health":
            return self._send(200, {"ok": True})
        return self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path.rstrip("/") not in ("/v1/chat/completions", "/chat/completions"):
            return self._send(404, {"error": {"message": "not found"}})
        if not self._auth_ok():
            return self._send(401, {"error": {"message": "invalid bridge key", "type": "auth"}})
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = 0
        if length <= 0 or length > 1_000_000:
            return self._send(400, {"error": {"message": "bad body"}})
        try:
            req = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, OSError):
            return self._send(400, {"error": {"message": "invalid json"}})
        messages = req.get("messages")
        if not isinstance(messages, list) or not messages:
            return self._send(400, {"error": {"message": "messages[] required"}})

        # Dedup: retries/hedges of the same prompt attach to the pending job
        # instead of spawning duplicate worker runs.
        msg_hash = _msg_hash(messages)
        want_stream = bool(req.get("stream", False))
        job_id = _find_pending_dup(msg_hash)
        if job_id:
            log(f"dedup: reusing pending job {job_id}")
        else:
            job_id = uuid.uuid4().hex[:12]
            job = {
                "id": job_id,
                "model": req.get("model", MODEL_ID),
                "messages": messages,
                "stream": want_stream,
                "created_at": time.time(),
            }
            tmp = os.path.join(QUEUE, job_id + ".tmp")
            final = os.path.join(QUEUE, job_id + ".json")
            with open(tmp, "w") as f:
                json.dump(job, f)
            os.replace(tmp, final)
            log(f"job {job_id} queued ({len(messages)} msgs)")

        # Hold the connection until the worker answers (long-poll).
        done_path = os.path.join(DONE, job_id + ".json")
        deadline = time.time() + HOLD_SECS
        try:
            while time.time() < deadline:
                if os.path.exists(done_path):
                    try:
                        with open(done_path) as f:
                            res = json.load(f)
                        # Do NOT delete: deduped waiters may still need it.
                        # The watchdog janitor removes done files >30 min old.
                    except OSError:
                        time.sleep(POLL_SECS)
                        continue
                    content = res.get("content", "")
                    log(f"job {job_id} answered ({len(content)} chars)")
                    if want_stream:
                        return self._send_sse(job_id, req.get("model", MODEL_ID), content)
                    return self._send(200, {
                        "id": f"chatcmpl-mr-{job_id}",
                        "object": "chat.completion",
                        "created": int(time.time()),
                        "model": req.get("model", MODEL_ID),
                        "choices": [{
                            "index": 0,
                            "message": {"role": "assistant", "content": content},
                            "finish_reason": "stop",
                        }],
                        "usage": {
                            "prompt_tokens": 0,
                            "completion_tokens": 0,
                            "total_tokens": 0,
                        },
                    })
                time.sleep(POLL_SECS)
        except (BrokenPipeError, ConnectionResetError):
            log(f"job {job_id} client disconnected, job left for worker")
            return
        log(f"job {job_id} TIMEOUT after {HOLD_SECS}s (job left in queue)")
        return self._send(504, {"error": {
            "message": "muse-relay worker timeout: no answer within 600s. The job is still queued; retry later.",
            "type": "timeout",
        }})

    def _send_sse(self, job_id, model, content):
        """Single-chunk SSE stream: valid event-stream for streaming clients."""
        cid = f"chatcmpl-mr-{job_id}"
        created = int(time.time())
        chunk1 = {"id": cid, "object": "chat.completion.chunk", "created": created,
                  "model": model, "choices": [{"index": 0,
                    "delta": {"role": "assistant", "content": content},
                    "finish_reason": None}]}
        chunk2 = {"id": cid, "object": "chat.completion.chunk", "created": created,
                  "model": model, "choices": [{"index": 0, "delta": {},
                    "finish_reason": "stop"}]}
        body = (f"data: {json.dumps(chunk1)}\n\n"
                f"data: {json.dumps(chunk2)}\n\n"
                "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(QUEUE, exist_ok=True)
    os.makedirs(DONE, exist_ok=True)
    os.makedirs(STALE, exist_ok=True)
    with open(os.path.join(BASE, "bridge.pid"), "w") as f:
        f.write(str(os.getpid()))
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    log(f"bridge started on 127.0.0.1:{PORT} (model {MODEL_ID})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
