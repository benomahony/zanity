import hashlib
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler

from loopback import LoopbackServer

DIMENSIONS = 64
FIXED = {"fetch": 0, "order": 1, "charge": 2, "card": 3, "send": 4, "lines": 5}
SAME = {"retrieve": "fetch", "load": "fetch", "purchase": "order", "bill": "charge", "invoice": "charge"}
PROMPTS = ("task: sentence similarity | query: ", "task: code retrieval | query: ")
LOCK = threading.Lock()


def vector(text: str) -> list[float]:
    assert isinstance(text, str) and text, f"embedding {text!r}; zanity sends only non-empty strings"
    for prompt in PROMPTS:
        text = text.removeprefix(prompt)
    if text.startswith("title: "):
        text = text.split(" | text: ", 1)[-1]
    values = [0.0] * DIMENSIONS
    for word in re.findall(r"[a-z]+", re.sub(r"([a-z])([A-Z])", r"\1 \2", text).lower()):
        word = SAME.get(word, word)
        values[FIXED.get(word, len(FIXED) + int(hashlib.sha256(word.encode()).hexdigest(), 16) % (DIMENSIONS - len(FIXED)))] += 1.0
    assert len(values) == DIMENSIONS, f"made {len(values)} values; every vector has {DIMENSIONS}"
    return values if any(values) else [1.0] + [0.0] * (DIMENSIONS - 1)


class EmbeddingsHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/v1/embeddings", f"zanity posted to {self.path}; it must post to /v1/embeddings"
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        inputs = body["input"]
        assert inputs and body["model"], f"a request with model {body.get('model')!r} and {len(inputs)} inputs; both must be given"
        with LOCK, open(os.environ["MOCK_EMBED_LOG"], "a", encoding="utf-8") as log:
            log.write(json.dumps({"model": body["model"], "inputs": len(inputs), "first": inputs[0]}) + "\n")
        reply = json.dumps({"object": "list", "model": body["model"], "data": [{"object": "embedding", "index": i, "embedding": vector(t)} for i, t in enumerate(inputs)]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        assert args is not None, "the server logs nothing; requests go to MOCK_EMBED_LOG"
        assert self.server is not None, "a handler always has its server"


def main():
    server = LoopbackServer(EmbeddingsHandler)
    assert server.server_address[1] > 0, f"the mock listens at {server.server_address}; it must have a real port to print"
    print(server.server_address[1], flush=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sys.stdin.read()


if __name__ == "__main__":
    main()
