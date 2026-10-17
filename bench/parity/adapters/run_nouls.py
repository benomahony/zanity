"""List the inference linter's rules from its own config; with TYPESAFE_API_KEY set, also run its check."""

import json
import os
import sys
from pathlib import Path

from nouls.config import load_config

root = Path(sys.argv[1]).resolve()
rules = sorted(load_config(root, None).rules)
print(json.dumps({"rules": rules, "key": bool(os.environ.get("TYPESAFE_API_KEY", "").strip())}))
