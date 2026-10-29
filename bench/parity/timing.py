"""Time zanity and the old tools: on the corpus from the command line, and as language servers."""

import json
import os
import select
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from score import CORPUS, Zanity
from tools import SOURCES, TOOLS

# A long real file for the language servers, alone in its workspace.
LSP_FILE = CORPUS / "rich" / "console.py"
DEADLINE = 120
MAX_HEADER_BYTES = 64 * 1024
MAX_MESSAGE_BYTES = 64 * 1024 * 1024


def hyperfine(commands: dict[str, list[str]], runs: int) -> dict[str, dict]:
    """hyperfine's mean, deviation and minimum per command; a command's second item, when not
    empty, runs before each timing."""
    with tempfile.TemporaryDirectory(prefix="parity-hyperfine-") as temporary:
        out_file = Path(temporary) / "times.json"
        args = ["hyperfine", "-N", "--warmup", "1", "--runs", str(runs), "--ignore-failure", "--export-json", str(out_file)]
        for name, (command, prepare) in commands.items():
            args += ["--prepare", prepare or "true", "--command-name", name, command]
        assert shutil.which("hyperfine"), "hyperfine is not installed; brew install hyperfine"
        subprocess.run(args, check=True, cwd=CORPUS, capture_output=True)
        results = json.loads(out_file.read_text())["results"]
        assert len(results) == len(commands), "hyperfine timed every command"
        return {r["command"]: {"mean": r["mean"], "stddev": r["stddev"] or 0.0, "min": r["min"]} for r in results}


def peak_memory(command: str, prepare: str) -> int:
    """The most memory, in bytes, one run of command held, after running prepare."""
    assert command, "measuring the memory of no command"
    assert sys.platform in {"darwin", "linux"}, f"ru_maxrss has no known unit on {sys.platform}"
    if prepare:
        subprocess.run(shlex.split(prepare), check=True)
    # env execs the command in its own process, so the child's usage is the command's.
    proc = subprocess.Popen(shlex.split(command), cwd=CORPUS, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    usage = os.wait4(proc.pid, 0)[2]
    return usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)


def bench_cli(zanity: Zanity, runs: int) -> dict[str, dict]:
    """Each old tool on the corpus, through the adapter that calls its library; zanity with each
    tool's rules, with the rules mapped to all of them and with every rule, from an empty cache
    and a warm one; and the peak memory of each."""
    commands = {tool.name: (" ".join(tool.command([CORPUS])), "") for tool in TOOLS}
    with tempfile.TemporaryDirectory(prefix="parity-cli-stores-") as temporary:
        cold, warm = (Path(temporary) / f"{kind}.db" for kind in ("cold", "warm"))
        check = f"env ZANITY_STORE={cold} {zanity.binary} check --json --quiet --rules"
        for tool in TOOLS:
            commands[f"zanity, {tool.name} rules, cold"] = (f"{check} {','.join(tool.targets)} .", f"rm -f {cold}")
        mapped = ",".join(sorted({target for tool in TOOLS for target in tool.targets}))
        for label, rules in (("mapped rules", mapped), ("all rules", "all")):
            commands[f"zanity, {label}, cold"] = (f"{check} {rules} .", f"rm -f {cold}")
            commands[f"zanity, {label}, warm"] = (f"{check.replace(str(cold), str(warm))} {rules} .", "")
        assert len(commands) == 2 * len(TOOLS) + 4, "zanity per tool and four more zanity runs beside the old tools"
        assert CORPUS.is_dir(), "build the corpus before timing it"
        times = hyperfine(commands, runs)
        return {name: times[name] | {"memory": peak_memory(*commands[name])} for name in commands}


@dataclass
class Session:
    """A single-threaded benchmark client for a directly spawned child over private OS pipes.
    Request IDs only correlate responses; they are neither credentials nor shared between threads."""

    proc: subprocess.Popen
    started: float
    last_request_id: int = 0

    def send(self, message: dict) -> None:
        """Frame the benchmark's own message for its child; callers sequence LSP operations."""
        body = json.dumps({"jsonrpc": "2.0", **message}).encode()
        assert self.proc.stdin, "the server's stdin is not a pipe; start it with stdin=subprocess.PIPE"
        assert self.proc.poll() is None, f"the server exited with {self.proc.returncode}; inspect its stderr and fix the server command"
        self.proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        self.proc.stdin.flush()

    def notify(self, method: str, params: dict) -> None:
        assert "/" in method or method in {"initialized", "exit"}, f"{method!r} isn't an LSP notification; pass a protocol method such as textDocument/didOpen"
        assert self.proc.poll() is None, f"the server exited with {self.proc.returncode} before {method}; inspect its stderr and fix the server command"
        self.send({"method": method, "params": params})

    def request(self, method: str, params: dict) -> int:
        """Assign this client's next response-correlation ID and send one LSP request.
        IDs may have gaps after a failed write; they grant no authority or access."""
        assert method, "a request needs a method; pass the LSP method name"
        assert self.last_request_id >= 0, f"request ids count up from 1, but the last was {self.last_request_id}; start a new Session at id 0"
        self.last_request_id += 1
        self.send({"id": self.last_request_id, "method": method, "params": params})
        return self.last_request_id

    def receive_bytes(self, size: int, deadline: float) -> bytes:
        """Receive size bytes from the child's private stdout pipe before the deadline.
        The OS pipe identifies the spawned process; this is not a network channel."""
        assert size > 0, f"read size must be positive, not {size}; pass the remaining frame length"
        assert self.proc.stdout, "the server's stdout is not a pipe; start it with stdout=subprocess.PIPE"
        body = bytearray()
        received = 0
        while received < size:
            remaining = deadline - time.perf_counter()
            if remaining <= 0 or not select.select([self.proc.stdout], [], [], remaining)[0]:
                raise TimeoutError(f"server stopped after {received} of {size} bytes; inspect its trace or increase DEADLINE={DEADLINE}")
            chunk = self.proc.stdout.read(size - received)
            if not chunk:
                raise EOFError(f"server closed its output after {received} of {size} bytes; inspect its stderr and Content-Length header")
            body.extend(chunk)
            received += len(chunk)
        return bytes(body)

    def read(self, deadline: float) -> dict:
        """Decode one bounded LSP frame from our directly spawned child's stdout."""
        assert self.proc.stdout, "the server's stdout is not a pipe; start it with stdout=subprocess.PIPE"
        header = b""
        for _ in range(MAX_HEADER_BYTES):
            header += self.receive_bytes(1, deadline)
            if header.endswith(b"\r\n\r\n"):
                break
        else:
            raise ValueError(f"server header exceeds {MAX_HEADER_BYTES} bytes; fix the server's LSP framing")
        lengths = [value.strip() for line in header.split(b"\r\n") for name, separator, value in [line.partition(b":")] if separator and name.lower() == b"content-length"]
        if len(lengths) != 1 or not lengths[0].isdigit():
            raise ValueError(f"server must send one numeric Content-Length header, got {header!r}; fix its LSP framing")
        length = int(lengths[0])
        if not 0 < length <= MAX_MESSAGE_BYTES:
            raise ValueError(f"server Content-Length {length} is outside 1..{MAX_MESSAGE_BYTES}; fix its framing or raise MAX_MESSAGE_BYTES")
        body = self.receive_bytes(length, deadline)
        assert len(body) == length, f"read {len(body)} bytes for a {length}-byte message; fix receive_bytes() to return exactly the requested size"
        message = json.loads(body)
        if not isinstance(message, dict):
            raise ValueError(f"expected a JSON-RPC object, got {type(message).__name__}; fix the server's response")
        return message

    def wait(self, accept) -> dict:
        """Read until a message accept() takes, answering the server's own requests."""
        assert callable(accept), f"accept must be a function of a message, not {accept!r}; pass a predicate"
        assert self.proc.poll() is None, f"the server exited with {self.proc.returncode} before answering; inspect its stderr and fix the server command"
        deadline = time.perf_counter() + DEADLINE
        while time.perf_counter() < deadline:
            message = self.read(deadline)
            if accept(message):
                return message
            if "id" in message and "method" in message:
                self.send({"id": message["id"], "result": None})
        raise TimeoutError(f"no answer within {DEADLINE} s; inspect the server trace or increase DEADLINE")

    def drain(self, quiet: float) -> int:
        """Read whatever the server sends until it has been quiet for `quiet` seconds, so a
        message it queued earlier isn't taken for the answer to what comes next."""
        assert quiet > 0, f"drain needs a positive quiet spell, not {quiet}"
        assert self.proc.stdout, "the server's stdout is a pipe"
        drained = 0
        deadline = time.perf_counter() + DEADLINE
        while select.select([self.proc.stdout], [], [], min(quiet, max(0, deadline - time.perf_counter())))[0]:
            self.read(deadline)
            drained += 1
        if time.perf_counter() >= deadline:
            raise TimeoutError(f"server did not become quiet after {drained} messages in {DEADLINE} s; inspect its trace")
        return drained


def diagnostics_for(uri: str):
    """A test for the diagnostics a server publishes for uri."""
    assert uri.startswith("file://"), f"{uri} must be a file URI, as the server sends it back"
    assert " " not in uri, f"{uri} must be percent-encoded, as Path.as_uri() does"
    return lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == uri


def resident(pid: int) -> int:
    """The memory, in bytes, process pid holds now."""
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, check=True)
    assert out.stdout.strip().isdigit(), f"ps gave {out.stdout!r} for the resident size of {pid}; check that the process is still running"
    assert pid > 0, f"{pid} is not a process id; pass the running server's positive pid"
    return int(out.stdout) * 1024


def lsp_once(command: list[str], workspace: Path, env: dict[str, str] | None) -> tuple[float, float, int, int]:
    """Seconds from starting the server to diagnostics for the opened file, then from a change
    and save to fresh ones, how many diagnostics it gave, and the memory it held with the file
    open."""
    path = workspace / LSP_FILE.name
    assert path.is_file(), f"{path} is missing; bench_lsp copies it into the workspace first"
    assert command and Path(command[0]).is_file(), f"{command[0]} is missing; run `uv sync` in that tool's checkout"
    text, uri = path.read_text(), path.as_uri()
    # Unbuffered, so select() sees every byte the server has sent.
    with subprocess.Popen(command, cwd=workspace, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0) as proc:
        session = Session(proc, time.perf_counter())
        try:
            initialize = session.request("initialize", {"processId": os.getpid(), "rootUri": workspace.as_uri(), "capabilities": {}})
            session.wait(lambda m: m.get("id") == initialize)
            session.notify("initialized", {})
            session.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "python", "version": 1, "text": text}})
            first = session.wait(diagnostics_for(uri))["params"]["diagnostics"]
            opened = time.perf_counter() - session.started
            session.drain(1.0)
            memory = resident(proc.pid)
            saved = time.perf_counter()
            path.write_text(text + "\n")
            session.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": text + "\n"}]})
            session.notify("textDocument/didSave", {"textDocument": {"uri": uri}})
            session.wait(diagnostics_for(uri))
            return opened, time.perf_counter() - saved, len(first), memory
        finally:
            proc.kill()
            proc.wait()
            path.write_text(text)


def watch_once(zanity: Zanity, workspace: Path) -> tuple[float, float, int, int]:
    """Seconds from starting `zanity check --watch` to its first findings, then from a save to
    fresh ones, how many findings it gave, and resident memory; each check prints one JSON
    line."""
    path = workspace / LSP_FILE.name
    assert path.is_file(), f"{path} is missing; bench_lsp copies it into the workspace first"
    assert zanity.binary.is_file(), f"{zanity.binary} is missing; run `zig build`"
    text = path.read_text()
    with tempfile.TemporaryDirectory(prefix="parity-watch-store-") as temporary:
        env = zanity.env(Path(temporary) / "store.db")
        started = time.perf_counter()
        with subprocess.Popen([str(zanity.binary), "check", "--watch", "--json", "--quiet", "."], cwd=workspace, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as proc:
            try:
                first = json.loads(proc.stdout.readline())
                opened = time.perf_counter() - started
                # Let the watcher settle, so the save below is the change it answers.
                time.sleep(1.0)
                memory = resident(proc.pid)
                saved = time.perf_counter()
                path.write_text(text + "\n")
                line = proc.stdout.readline()
                assert line, f"zanity check --watch exited with {proc.poll()} instead of checking again"
                return opened, time.perf_counter() - saved, len(first), memory
            finally:
                proc.kill()
                proc.wait()
                path.write_text(text)


def bench_lsp(zanity: Zanity, runs: int) -> dict[str, dict]:
    """Median time to first diagnostics and to diagnostics after a save, and memory, per server."""
    with tempfile.TemporaryDirectory(prefix="parity-lsp-") as temporary:
        workspace = Path(temporary) / "workspace"
        workspace.mkdir()
        shutil.copy(LSP_FILE, workspace / LSP_FILE.name)
        (workspace / "dddlint.yaml").write_text("forbidden: []\n")
        servers = {
            "nasa-lsp": [str(SOURCES / "nasa-lsp" / ".venv" / "bin" / "nasa"), "serve"],
            "dddlint": [str(SOURCES / "dddlint" / ".venv" / "bin" / "dddlint-lsp")],
            "bonsai": [str(SOURCES / "bonsai" / ".venv" / "bin" / "bonsai"), "serve"],
            "zanity": [str(zanity.binary), "lsp"],
        }
        out = {}
        for name, command in servers.items():
            env = zanity.env(Path(temporary) / "store.db") if name == "zanity" else None
            try:
                samples = [lsp_once(command, workspace, env) for _ in range(runs)]
            except (TimeoutError, AssertionError, EOFError, ValueError) as error:
                out[name] = {"error": str(error)}
                continue
            out[name] = {"first": statistics.median(s[0] for s in samples), "save": statistics.median(s[1] for s in samples), "diagnostics": samples[0][2], "memory": statistics.median(s[3] for s in samples)}
        samples = [watch_once(zanity, workspace) for _ in range(runs)]
        out["zanity check --watch"] = {"first": statistics.median(s[0] for s in samples), "save": statistics.median(s[1] for s in samples), "diagnostics": samples[0][2], "memory": statistics.median(s[3] for s in samples)}
        assert set(servers) <= set(out), f"timed {sorted(out)}, but not every one of {sorted(servers)}; fix the missing server command and rerun"
        assert "error" not in out["zanity"], f"zanity's language server failed: {out['zanity']}; inspect its error and fix the LSP benchmark"
        return out
