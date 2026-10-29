"""A stand-in for TypeSafe's System One API, for testing `zanity check --infer` offline.

Answers each noul question from markers in the source of the function, file, setting line or project
files it is about: a comment
`judge: <rule>` makes that rule's question answer 0.95, anything else 0.05.
`mock: too-large` refuses the request as Jev refuses one over its input limit, and
`mock: unauthorized` refuses it as a wrong key is refused.
Each request is appended to the file named by MOCK_TYPESAFE_LOG, with the model and the
Authorization header it carried, so tests can see what was asked and with which key. Prints the port it listens on, then serves until killed or until its
stdin closes: the test holds stdin open, so a test that dies without killing the mock still
takes it down, and the mock can't hold the build's output open forever.
"""

import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# The real caller batches at most 64 questions. Larger requests indicate a broken test/client.
MAX_QUESTIONS = 64
MAX_REQUEST_BYTES = 16 * 1024 * 1024
BODY_TIMEOUT_SECONDS = 30
SOURCE_FIELDS = ("function", "line", "files", "repeated", "source")
YES_PROBABILITY = 0.95
NO_PROBABILITY = 0.05
MOCK_TOKENS_PER_REQUEST = 1
LOG_LOCK = threading.Lock()


def validated_questions(questions: dict) -> dict:
    """Check each named noul after decode_mock_request validates the batch's type and size.
    Invalid names or question shapes raise ValueError for the handler's HTTP 400 response."""
    assert questions, "decode_mock_request must reject empty question batches before validating their entries"
    assert len(questions) <= MAX_QUESTIONS, f"{len(questions)} questions bypassed the {MAX_QUESTIONS}-question limit; split the batch first"
    for name, question in questions.items():
        if not isinstance(name, str) or not name or not isinstance(question, dict):
            raise ValueError("each question needs a nonempty name and an object value; send named noul questions")
        if question.get("type") != "noul" or not isinstance(question.get("instructions"), str):
            raise ValueError(f"question {name!r} needs type 'noul' and string instructions; use the System One question format")
    return questions


def decode_mock_request(data: bytes) -> tuple[str, str, dict]:
    """Validate one already bounded body from the test client. JSON, shape and type failures
    raise ValueError for do_POST's HTTP 400 response; no request data configures the server."""
    assert data, "read_request must reject empty bodies before decoding them"
    assert len(data) <= MAX_REQUEST_BYTES, f"{len(data)} request bytes bypassed the {MAX_REQUEST_BYTES}-byte limit; fix read_request"
    body = json.loads(data)
    if not isinstance(body, dict):
        raise ValueError("request must be a JSON object; send model, state and questions fields")
    model, state, questions = (body.get(name) for name in ("model", "state", "questions"))
    if not isinstance(model, str) or not model.strip():
        raise ValueError("model must be a nonempty string; send the test client's model name")
    if not isinstance(state, dict):
        raise ValueError("state must be an object; send exactly one source field")
    sources = [state[name] for name in SOURCE_FIELDS if name in state]
    if len(sources) != 1:
        raise ValueError(f"state must contain one source field from {SOURCE_FIELDS}; send the unit's source")
    source = sources[0]
    if not isinstance(source, str) or not source:
        raise ValueError("the state source must be a nonempty string; send the unit's source text")
    if not isinstance(questions, dict) or not 0 < len(questions) <= MAX_QUESTIONS:
        raise ValueError(f"questions must be an object with 1..{MAX_QUESTIONS} named questions; split larger batches")
    return model, source, validated_questions(questions)


def record_request(source: str, questions: dict, model: str, authorization: str) -> None:
    """Append one test record to the parent-configured log. The path never comes from a
    request; the lock covers append, flush and close across concurrent handler threads.
    Authorization is the fixture client's dummy header, recorded for assertions, not verified."""
    assert source, "decode_mock_request must validate source text before recording a request"
    assert model, "decode_mock_request must validate the model before recording a request"
    log = os.environ.get("MOCK_TYPESAFE_LOG")
    if not log:
        return
    record = {"function": source.splitlines()[0], "questions": sorted(questions), "model": model, "authorization": authorization}
    record_json = json.dumps(record) + "\n"
    with LOG_LOCK, open(log, "a", encoding="utf-8") as output:
        recorded = output.write(record_json)
        if recorded != len(record_json):
            raise OSError(f"mock log recorded {recorded} characters; check the test log's storage")


class Handler(BaseHTTPRequestHandler):
    """Stateless fixture endpoint for the test-owned loopback listener, not an authenticated
    service. Repeated requests intentionally return the same marker-derived answers. The
    Authorization header is only recorded so tests can check their dummy credential was sent."""

    def read_request(self) -> tuple[str, str, dict]:
        """Read one length-delimited JSON body with a size/time bound. All malformed input
        raises ValueError, UnicodeError or TimeoutError for do_POST to turn into an HTTP error."""
        assert self.command == "POST", f"read_request handles POST, not {self.command}; call it only from do_POST"
        body_timeout = self.connection.gettimeout()
        assert body_timeout == BODY_TIMEOUT_SECONDS, f"mock body timeout is {body_timeout}; set it to {BODY_TIMEOUT_SECONDS} seconds before reading a request"
        if self.headers.get("Transfer-Encoding") is not None:
            raise ValueError("chunked bodies are not supported; send one Content-Length header")
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) != 1:
            raise ValueError("send exactly one Content-Length header with the JSON body size")
        declared_length = lengths[0]
        if not declared_length.isascii() or not declared_length.isdigit():
            raise ValueError("send a nonnegative numeric Content-Length header")
        length = int(declared_length)
        if not 0 < length <= MAX_REQUEST_BYTES:
            raise ValueError(f"body length {length} is outside 1..{MAX_REQUEST_BYTES}; send a bounded JSON request")
        if self.headers.get_content_type() != "application/json":
            raise ValueError("send the JSON request with Content-Type: application/json")
        deadline = time.monotonic() + BODY_TIMEOUT_SECONDS
        data = bytearray()
        received = 0
        while received < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("the mock's request-body deadline expired")
            self.connection.settimeout(remaining)
            chunk = self.rfile.read1(length - received)
            if not chunk:
                raise ValueError(f"body ended at {received} of {length} bytes; send the complete JSON request")
            data.extend(chunk)
            received += len(chunk)
        return decode_mock_request(bytes(data))

    def reply_json(self, status: int, payload: dict) -> None:
        """Write the fixture's standard JSON response; socket failures propagate to do_POST."""
        assert 200 <= status <= 599, f"invalid mock HTTP status {status}; use a standard success or error status"
        assert "detail" in payload or {"model", "answers", "usage"} <= payload.keys(), f"mock reply fields {sorted(payload)} lack error detail or model/answers/usage; build a System One response"
        reply = json.dumps(payload).encode()
        response_bytes = len(reply)
        self.connection.settimeout(BODY_TIMEOUT_SECONDS)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(response_bytes))
        self.end_headers()
        written = self.wfile.write(reply)
        if written != response_bytes:
            raise OSError(f"mock response wrote {written} of {response_bytes} bytes; check the test client's connection")

    def do_POST(self) -> None:
        """Serve only the local fixture route. The main block binds 127.0.0.1; OS pipe lifetime
        ties this process to its parent test. No source/header grants authority or changes policy.
        Invalid requests get 400, body stalls 408 and log failures 500; disconnected clients
        are reported on stderr. Concurrent log appends are serialized and each file is closed."""
        assert self.command == "POST", f"HTTP dispatch called do_POST for {self.command}; fix the handler registration"
        bound_host = self.server.server_address[0]
        assert bound_host == "127.0.0.1", f"the mock is bound to {bound_host}; use the main block's loopback-only listener"
        self.close_connection = True
        self.connection.settimeout(BODY_TIMEOUT_SECONDS)
        status, payload = 404, {"detail": "Only /v1/systemone is mocked; use that test endpoint."}
        if self.path == "/v1/systemone":
            try:
                model, source, questions = self.read_request()
                judged = set(re.findall(r"judge: ([a-z-]+)", source))
                answers = {name: {"type": "noul", "noul": YES_PROBABILITY if name in judged else NO_PROBABILITY} for name in questions}
                record_request(source, questions, model, self.headers.get("Authorization", ""))
                status, payload = 200, {"model": model, "answers": answers, "usage": {"input_tokens": MOCK_TOKENS_PER_REQUEST, "output_tokens": MOCK_TOKENS_PER_REQUEST}}
                if "mock: too-large" in source:
                    status, payload = 400, {"detail": {"error_type": "max_tokens_exceeded"}}
                if "mock: unauthorized" in source:
                    status, payload = 401, {"detail": "Invalid API key"}
            except (ValueError, UnicodeError, RecursionError) as error:
                status, payload = 400, {"detail": str(error)}
            except TimeoutError:
                status, payload = 408, {"detail": f"Send the complete request body within {BODY_TIMEOUT_SECONDS} seconds."}
            except OSError as error:
                print(f"mock request failed: {error}; check the test client's connection and MOCK_TYPESAFE_LOG path", file=sys.stderr)
                status, payload = 500, {"detail": "The mock could not record the request; check the test log path and connection."}
        try:
            self.reply_json(status, payload)
        except OSError as error:
            print(f"mock response failed: {error}; keep the test client connected until its response is complete", file=sys.stderr)

    def log_message(self, format: str, *args: object) -> None:
        """Keeps the test output clean; requests are recorded in MOCK_TYPESAFE_LOG instead."""
        assert "%" in format, f"http.server passed the log format {format!r} with no placeholder; check how this Python's http.server calls log_message"
        assert format.count("%") >= len(args), f"the log format {format!r} has fewer placeholders than its {len(args)} values; check how this Python's http.server calls log_message"


def exit_when_parent_goes() -> None:
    """Exits once stdin reaches end of file, which happens when the test that started the mock ends."""
    assert not sys.stdin.closed, "the mock's stdin was closed before it could watch for its parent exiting"
    assert not sys.stdin.isatty(), "the mock was started from a terminal; tests start it with stdin as a pipe they hold open"
    sys.stdin.buffer.read()
    os._exit(0)


if __name__ == "__main__":
    threading.Thread(target=exit_when_parent_goes, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    sys.exit(server.serve_forever())
