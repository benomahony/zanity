"""A stand-in for TypeSafe's System One API, for testing `zanity check --infer` offline.

Answers each noul question from markers in the source of the function, setting line or project
files it is about: a comment
`judge: <rule>` makes that rule's question answer 0.95, anything else 0.05.
Each request is appended to the file named by MOCK_TYPESAFE_LOG, so tests can
see what was asked. Prints the port it listens on, then serves until killed.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        assert self.path == "/v1/systemone", f"zanity called {self.path}; only /v1/systemone is mocked"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.headers.get("Authorization", "").startswith("Bearer "), "zanity sent no API key"
        state = body["state"]
        source = state.get("function") or state.get("line") or state.get("files")
        judged = set(re.findall(r"judge: ([a-z-]+)", source))
        answers = {name: {"type": "noul", "noul": 0.95 if name in judged else 0.05} for name in body["questions"]}
        log = os.environ.get("MOCK_TYPESAFE_LOG")
        if log:
            with open(log, "a") as f:
                f.write(json.dumps({"function": source.splitlines()[0], "questions": sorted(body["questions"])}) + "\n")
        reply = json.dumps({"model": body["model"], "answers": answers, "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, format: str, *args: object) -> None:
        """Keeps the test output clean; requests are recorded in MOCK_TYPESAFE_LOG instead."""
        assert "%" in format, f"http.server passed the log format {format!r} with no placeholder; check how this Python's http.server calls log_message"
        assert format.count("%") >= len(args), f"the log format {format!r} has fewer placeholders than its {len(args)} values; check how this Python's http.server calls log_message"


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    sys.exit(server.serve_forever())
