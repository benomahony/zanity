"""List the inference linter's rules from its own config. With TYPESAFE_BASE_URL naming a System
One server, such as a local Kev, and NOULS_PARITY_RULES naming rules, instead run its own analyser
on each directory given, asking only those rules, and print every answer it kept: where, which
rule, how sure the model was, and whether that reached the threshold."""

import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

from _common import emit, files
from nouls.analyser import Analyser
from nouls.config import Config, load_config
from nouls.store import Store
from typesafe_sdk import AsyncTypeSafeClient

# Long enough for a laptop's Kev to answer every question about one function.
TIMEOUT = 900


def analyse(roots: list[str], wanted: set[str]) -> list[dict]:
    """Every answer the analyser keeps about roots, asking only the wanted rules."""
    assert wanted, "name the rules to ask in NOULS_PARITY_RULES"
    assert roots, "pass the directories to check"
    projects: list[tuple[Config, list[Path]]] = []
    for root in roots:
        config = load_config(Path(root).resolve())
        for name, rule in config.rules.items():
            rule.enabled = name in wanted
        projects.append((config, files([root], (".py",))))
    with tempfile.TemporaryDirectory(prefix="nouls-parity-") as temporary:
        path = Path(temporary) / "nouls.db"
        store = Store(path)
        try:
            asyncio.run(analyse_projects(projects, store))
            rows = store.rows(
                tuple[str, int, str, float, float, int],
                "SELECT path, line, rule, probability, threshold, fired FROM observations",
            )
            assert rows, f"the analyser kept no answers in {path}; check the server answered"
            return [{"path": p, "line": line, "end": line, "rule": rule, "probability": prob, "threshold": t, "fired": bool(fired)} for p, line, rule, prob, t, fired in rows]
        finally:
            store.db.close()


async def analyse_projects(projects: list[tuple[Config, list[Path]]], store: Store) -> None:
    """Ask the asynchronous analyser, keeping source-file reads off its event loop."""
    assert projects, "pass the prepared projects to analyse; analyse() prepares one per root"
    assert all(any(rule.enabled for rule in config.rules.values()) for config, _ in projects), f"each of {len(projects)} projects needs a selected rule; check NOULS_PARITY_RULES names rules in its config"
    async with AsyncTypeSafeClient(model=os.environ.get("TYPESAFE_DEFAULT_MODEL"), timeout=TIMEOUT) as client:
        for config, sources in projects:
            analyser = Analyser(config, client, store)
            for source in sources:
                language = config.language_for(source)
                if language is None:
                    continue
                text = await asyncio.to_thread(source.read_text)
                await analyser.analyse(text, language, source)


if __name__ == "__main__":
    root = Path(sys.argv[1]).resolve()
    wanted = {name for name in os.environ.get("NOULS_PARITY_RULES", "").split(",") if name}
    if os.environ.get("TYPESAFE_BASE_URL") and wanted:
        emit(analyse(sys.argv[1:], wanted))
    else:
        rules = sorted(load_config(root, None).rules)
        print(json.dumps({"rules": rules, "key": bool(os.environ.get("TYPESAFE_API_KEY", "").strip())}))
