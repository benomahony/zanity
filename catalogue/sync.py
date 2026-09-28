"""Write zanity's rule mapping (the `.catalogue` field of each rule in src/rules.zig) into the catalogue.

src/rules.zig is the source of truth. `import_cwe.py` rebuilds catalogue.json and catalogue.yaml with
empty `rule_ids`, so run this after every import too; `zig build test` fails until they agree.

    uv run --with 'PyYAML>=6,<7' python catalogue/sync.py
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HERE = ROOT / "catalogue"
RULE = re.compile(r'\.name = "([^"]+)".*?\.catalogue = &\.\{([^}]*)\}')


def mapping() -> dict[str, list[str]]:
    rules: dict[str, list[str]] = {}
    for line in (ROOT / "src" / "rules.zig").read_text().splitlines():
        match = RULE.search(line)
        if match:
            rules[match.group(1)] = re.findall(r'"([^"]+)"', match.group(2))
    assert rules, "found no rules with a .catalogue field in src/rules.zig; is the file where this script expects it?"
    return rules


def main() -> None:
    try:
        import yaml
    except ImportError:
        sys.exit("catalogue.yaml must stay equal to catalogue.json, and writing it needs PyYAML. Run:\n"
                 "    uv run --with 'PyYAML>=6,<7' python catalogue/sync.py")
    catalogue = json.loads((HERE / "catalogue.json").read_text())
    entries = {e["id"]: e for e in catalogue["entries"]}
    by_entry: dict[str, list[str]] = {}
    for rule, ids in mapping().items():
        for entry in ids:
            assert entry in entries, f"rule {rule} in src/rules.zig maps to {entry}, which catalogue.json does not have; fix the ID or re-import"
            by_entry.setdefault(entry, []).append(rule)
    for entry in catalogue["entries"]:
        rules = sorted(by_entry.get(entry["id"], []))
        entry["rule_ids"] = rules
        entry["implementation_status"] = "partial" if rules else "unsupported"
    (HERE / "catalogue.json").write_text(json.dumps(catalogue, indent=2) + "\n")
    (HERE / "catalogue.yaml").write_text(yaml.safe_dump(catalogue, sort_keys=False, allow_unicode=True))
    summary_path = HERE / "summary.json"
    summary = json.loads(summary_path.read_text())
    summary["implemented_detectors"] = len(by_entry)
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"{len(by_entry)} of {len(entries)} catalogue families now name zanity rules")


if __name__ == "__main__":
    main()
