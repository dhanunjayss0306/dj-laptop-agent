"""A tiny fake LM Studio local server for tests.

Mimics LM Studio's OpenAI-compatible API at http://localhost:1234/v1:
  GET  /v1/models            -> loaded models: qwen3-8b (chat) and
                               nomic-embed-text-v1.5 (embeddings)
  POST /v1/chat/completions -> canned JSON action, chosen from the user
                               message (OpenAI response shape)
  POST /v1/embeddings       -> fake embeddings: a small bag-of-words
                               vector over a fixed vocabulary, so words
                               the query shares with a document make
                               their vectors similar (OpenAI response
                               shape)

Run it in a thread from the tests; it binds to 127.0.0.1 on a free port.
"""

import json
import math
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VOCAB = ["travel", "tourism", "virun", "sapss", "sanitation", "college",
         "operating", "system", "cricket", "kerala", "tourist", "pitch"]

CHAT_MODEL = "qwen3-8b"
EMBED_MODEL = "nomic-embed-text-v1.5"


def fake_embedding(text: str) -> list:
    """A small deterministic vector: counts of VOCAB words, normalized."""
    low = text.lower()
    vec = [float(low.count(w)) for w in VOCAB]
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]


def _canned_action(user_text: str) -> dict:
    low = user_text.lower()
    if "virun pitch" in low and "find" in low:
        return {"action": "search", "query": "Virun pitch"}
    if "travel and tourism" in low:
        return {"action": "open", "query": "travel and tourism"}
    if "organize" in low:
        return {"action": "organize", "query": "today"}
    if "summar" in low:
        return {"action": "summarize", "query": "Virun pitch"}
    if "notepad" in low:
        return {"action": "open_app", "query": "notepad"}
    return {"action": "search", "query": user_text}


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep test output clean
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/v1/models":
            self._send({"object": "list", "data": [
                {"id": CHAT_MODEL, "object": "model",
                 "owned_by": "organization-owner"},
                {"id": EMBED_MODEL, "object": "model",
                 "owned_by": "organization-owner"},
            ]})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/v1/embeddings":
            inputs = data.get("input", [])
            if isinstance(inputs, str):
                inputs = [inputs]
            self._send({
                "object": "list",
                "model": data.get("model", EMBED_MODEL),
                "data": [
                    {"object": "embedding", "index": i,
                     "embedding": fake_embedding(t)}
                    for i, t in enumerate(inputs)
                ],
            })
        elif self.path == "/v1/chat/completions":
            msgs = data.get("messages", [])
            user_text = next((m.get("content", "") for m in reversed(msgs)
                              if m.get("role") == "user"), "")
            if "summarize this file" in user_text.lower():
                content = ("- Virun is a travel app for tourists.\n"
                           "- It shows local guides and hidden places.\n"
                           "- Built for the SAMARTHA hackathon.")
            else:
                content = json.dumps(_canned_action(user_text))
            self._send({
                "id": "chatcmpl-test",
                "object": "chat.completion",
                "model": data.get("model", CHAT_MODEL),
                "choices": [{"index": 0,
                             "message": {"role": "assistant",
                                         "content": content},
                             "finish_reason": "stop"}],
            })
        else:
            self.send_response(404)
            self.end_headers()


def start_stub():
    """Start the stub on a free port. Returns (server, base_url).

    base_url includes the /v1 part, like the real LM Studio server:
    http://127.0.0.1:<port>/v1
    """
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}/v1"
