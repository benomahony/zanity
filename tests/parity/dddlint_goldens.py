import shutil
import sys
from pathlib import Path

from dddlint.check import check
from dddlint.cli import _collect
from dddlint.config import Config

SCENARIOS: dict[str, dict[str, str]] = {
    "drift_across_word_order": {
        "billing.py": "class CustomerAccount:\n    pass\n\n\ndef account_customer():\n    return 1\n",
    },
    "drift_across_files": {
        "orders.py": "def order_total():\n    return 1\n",
        "reports.py": "def total_order():\n    return 2\n",
    },
    "case_only_across_kinds_is_convention": {
        "invoice.py": "class Invoice:\n    pass\n\n\ndef invoice():\n    return Invoice()\n",
    },
    "directional_names_are_not_drift": {
        "money.py": "def usd_to_gbp(x):\n    return x\n\n\ndef gbp_to_usd(x):\n    return x\n",
    },
    "duplicate_across_files": {
        "a.py": "def charge():\n    return 1\n",
        "b.py": "def charge():\n    return 2\n",
    },
    "duplicate_methods_across_classes": {
        "shapes.py": "class Circle:\n    def area(self):\n        return 1\n\n\nclass Square:\n    def area(self):\n        return 2\n",
    },
    "dunder_names_are_exempt": {
        "models.py": "class A:\n    def __init__(self):\n        pass\n\n\nclass B:\n    def __init__(self):\n        pass\n",
    },
    "distinct_names_are_quiet": {
        "service.py": "class Ledger:\n    def post_entry(self):\n        return 1\n\n\ndef reconcile():\n    return 2\n",
    },
}

RULES = "name-drift,duplicate-name"

out = Path(sys.argv[1])
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)
for name, files in SCENARIOS.items():
    root = out / name
    root.mkdir()
    for relative, text in files.items():
        (root / relative).write_text(text)
    collected = _collect(root, [], root, paths=True)
    findings = [f for f in check(collected, Config()) if f.rule in {"drift", "duplicate"}]
    lines = [f"rules: {RULES}", "exit: 0"]
    columns = {(d.path, d.line, d.name): d.col for d in collected}
    for f in sorted(findings, key=lambda f: (str(f.path), f.line, f.col, f.rule)):
        rule = "name-drift" if f.rule == "drift" else "duplicate-name"
        col = columns.get((f.path, f.line, f.name), f.col)
        lines.append(f"{f.path.relative_to(root)}:{f.line + 1}:{col + 1}: warning [{rule}]")
    (out / f"{name}.expected").write_text("\n".join(lines) + "\n")
print(f"{len(SCENARIOS)} cases")
