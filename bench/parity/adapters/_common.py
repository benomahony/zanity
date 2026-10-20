"""Shared by every adapter: walk the paths given, print findings as JSON."""

import json
import sys
from pathlib import Path

SKIP = {".venv", "venv", ".git", "__pycache__", "node_modules", "dist", "build"}


def files(args: list[str], suffixes: tuple[str, ...]) -> list[Path]:
    """The files under args with one of suffixes, skipping virtualenvs and build output."""
    assert args, "pass the adapter at least one file or directory to check"
    assert all(s.startswith(".") for s in suffixes), f"suffixes {suffixes} must start with a dot, as Path.suffix does"
    found: list[Path] = []
    for arg in args:
        path = Path(arg).resolve()
        if path.is_file():
            found.append(path)
            continue
        found.extend(
            p for p in sorted(path.rglob("*")) if p.suffix in suffixes and p.is_file() and not SKIP & set(p.parts)
        )
    return found


def emit(findings: list[dict]) -> None:
    unplaced = [f for f in findings if f["line"] < 0 or f["end"] < f["line"]]
    assert not unplaced, f"findings must end on or after the line they start: {unplaced[:3]}"
    assert all(f["rule"] for f in findings), f"every finding names its rule: {[f for f in findings if not f['rule']][:3]}"
    json.dump(findings, sys.stdout)


def finding(path: Path | str, line: int, rule: str, end: int | None = None) -> dict:
    assert rule, f"the finding at {path}:{line} has no rule; the adapter must name one"
    assert Path(path).exists(), f"{path} doesn't exist, so the tool reported a path the harness can't match"
    return {"path": str(Path(path).resolve()), "line": line, "end": end or line, "rule": rule}
