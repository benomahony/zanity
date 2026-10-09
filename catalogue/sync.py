"""Write zanity's rule mapping (the `.catalogue` field of each rule in src/rules.zig) into the catalogue.

src/rules.zig is the source of truth. A catalogue.json copied from the engineering-error-catalogue repository comes with
empty `rule_ids`, so run this after copying one in too; `zig build test` fails until they agree.

    python3 catalogue/sync.py
"""

import json
import re
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
    unmapped = sorted(rule for rule, ids in rules.items() if not ids)
    assert not unmapped, f"{', '.join(unmapped)} in src/rules.zig list an empty .catalogue; name the catalogue entries they detect, or remove the field"
    return rules


def sync() -> None:
    catalogue = json.loads((HERE / "catalogue.json").read_text())
    entries = {e["id"]: e for e in catalogue["entries"]}
    assert entries, "catalogue/catalogue.json has no entries; copy catalogue.json from the engineering-error-catalogue repository, then run this again"
    by_entry: dict[str, list[str]] = {}
    for rule, ids in mapping().items():
        for entry in ids:
            assert entry in entries, f"rule {rule} in src/rules.zig maps to {entry}, which catalogue.json does not have; fix the ID, or copy catalogue.json from the engineering-error-catalogue repository"
            by_entry.setdefault(entry, []).append(rule)
    for entry in catalogue["entries"]:
        rules = sorted(by_entry.get(entry["id"], []))
        entry["rule_ids"] = rules
        entry["implementation_status"] = "partial" if rules else "unsupported"
    (HERE / "catalogue.json").write_text(json.dumps(catalogue, indent=2) + "\n")
    print(f"{len(by_entry)} of {len(entries)} catalogue families now name zanity rules")


if __name__ == "__main__":
    sync()
