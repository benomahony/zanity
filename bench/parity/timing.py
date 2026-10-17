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


def hyperfine(commands: dict[str, list[str]], runs: int) -> dict[str, dict]:
    """hyperfine's mean, deviation and minimum per command; a command's second item, when not
    empty, runs before each timing."""
    out_file = Path(tempfile.mkdtemp(prefix="parity-hyperfine-")) / "times.json"
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
    cold, warm = (Path(tempfile.mkdtemp(prefix=f"parity-{kind}-")) / "store.db" for kind in ("cold", "warm"))
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
    """One language server over stdio, from the moment it starts."""

    proc: subprocess.Popen
    started: float
    next_id: int = 0

    def send(self, message: dict) -> None:
        body = json.dumps({"jsonrpc": "2.0", **message}).encode()
        assert self.proc.stdin, "the server's stdin is a pipe"
        assert self.proc.poll() is None, f"the server exited with {self.proc.returncode}"
        self.proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        self.proc.stdin.flush()

    def notify(self, method: str, params: dict) -> None:
        assert "/" in method or method in {"initialized", "exit"}, f"{method!r} isn't an LSP notification"
        assert self.proc.poll() is None, f"the server exited with {self.proc.returncode} before {method}"
        self.send({"method": method, "params": params})

    def request(self, method: str, params: dict) -> int:
        assert method, "a request needs a method"
        assert self.next_id >= 0, f"request ids count up from 1, but the last was {self.next_id}"
        self.next_id += 1
        self.send({"id": self.next_id, "method": method, "params": params})
        return self.next_id

    def read(self) -> dict:
        assert self.proc.stdout, "the server's stdout is a pipe"
        header = b""
        for _ in range(64):
            line = self.proc.stdout.readline()
            assert line, "the server closed its output"
            if line.strip() == b"":
                break
            header += line
        length = int(header.lower().split(b"content-length:")[1].split(b"\r\n")[0])
        assert length > 0, f"every message has a body, but the header said {length}: {header!r}"
        body = b""
        # An unbuffered pipe hands back what has arrived so far, so read until the body is whole.
        while len(body) < length:
            chunk = self.proc.stdout.read(length - len(body))
            assert chunk, f"the server closed its output {len(body)} bytes into a {length}-byte message"
            body += chunk
        return json.loads(body)

    def wait(self, accept) -> dict:
        """Read until a message accept() takes, answering the server's own requests."""
        assert callable(accept), f"accept must be a function of a message, not {accept!r}"
        assert self.proc.poll() is None, f"the server exited with {self.proc.returncode} before answering"
        deadline = time.perf_counter() + DEADLINE
        while time.perf_counter() < deadline:
            message = self.read()
            if accept(message):
                return message
            if "id" in message and "method" in message:
                self.send({"id": message["id"], "result": None})
        raise TimeoutError(f"no answer within {DEADLINE} s")

    def drain(self, quiet: float) -> int:
        """Read whatever the server sends until it has been quiet for `quiet` seconds, so a
        message it queued earlier isn't taken for the answer to what comes next."""
        assert quiet > 0, f"drain needs a positive quiet spell, not {quiet}"
        assert self.proc.stdout, "the server's stdout is a pipe"
        drained = 0
        while select.select([self.proc.stdout], [], [], quiet)[0]:
            self.read()
            drained += 1
        return drained


def diagnostics_for(uri: str):
    """A test for the diagnostics a server publishes for uri."""
    assert uri.startswith("file://"), f"{uri} must be a file URI, as the server sends it back"
    assert " " not in uri, f"{uri} must be percent-encoded, as Path.as_uri() does"
    return lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == uri


def resident(pid: int) -> int:
    """The memory, in bytes, process pid holds now."""
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, check=True)
    assert out.stdout.strip().isdigit(), f"ps gave {out.stdout!r} for the resident size of {pid}"
    assert pid > 0, f"{pid} is not a process id"
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
    proc = subprocess.Popen(command, cwd=workspace, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
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
        path.write_text(text)
        proc.kill()
        proc.wait()


def watch_once(zanity: Zanity, workspace: Path) -> tuple[float, float, int]:
    """Seconds from starting `zanity check --watch` to its first findings, then from a save to
    fresh ones, and how many findings it gave; each check prints one JSON line."""
    path = workspace / LSP_FILE.name
    assert path.is_file(), f"{path} is missing; bench_lsp copies it into the workspace first"
    assert zanity.binary.is_file(), f"{zanity.binary} is missing; run `zig build`"
    text = path.read_text()
    env = zanity.env(Path(tempfile.mkdtemp(prefix="parity-watch-store-")) / "store.db")
    started = time.perf_counter()
    proc = subprocess.Popen([str(zanity.binary), "check", "--watch", "--json", "--quiet", "."], cwd=workspace, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        first = json.loads(proc.stdout.readline())
        opened = time.perf_counter() - started
        # Let the watcher settle, so the save below is the change it answers.
        time.sleep(1.0)
        saved = time.perf_counter()
        path.write_text(text + "\n")
        line = proc.stdout.readline()
        assert line, f"zanity check --watch exited with {proc.poll()} instead of checking again"
        return opened, time.perf_counter() - saved, len(first)
    finally:
        path.write_text(text)
        proc.kill()
        proc.wait()


def bench_lsp(zanity: Zanity, runs: int) -> dict[str, dict]:
    """Median time to first diagnostics and to diagnostics after a save, and memory, per server."""
    workspace = Path(tempfile.mkdtemp(prefix="parity-lsp-"))
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
        env = zanity.env(Path(tempfile.mkdtemp(prefix="parity-lsp-store-")) / "store.db") if name == "zanity" else None
        try:
            samples = [lsp_once(command, workspace, env) for _ in range(runs)]
        except (TimeoutError, AssertionError) as error:
            out[name] = {"error": str(error)}
            continue
        out[name] = {"first": statistics.median(s[0] for s in samples), "save": statistics.median(s[1] for s in samples), "diagnostics": samples[0][2], "memory": statistics.median(s[3] for s in samples)}
    samples = [watch_once(zanity, workspace) for _ in range(runs)]
    out["zanity check --watch"] = {"first": statistics.median(s[0] for s in samples), "save": statistics.median(s[1] for s in samples), "diagnostics": samples[0][2]}
    assert set(servers) <= set(out), f"timed {sorted(out)}, but not every one of {sorted(servers)}"
    assert "error" not in out["zanity"], f"zanity's language server failed: {out['zanity']}"
    return out
