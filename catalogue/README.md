# Engineering error catalogue

`catalogue.json` is the engineering error catalogue 0.3.0: 1,035 families, 969 from the CWE 4.20 dictionary and 66 of the catalogue's own. It comes from the catalogue's release unchanged except for each family's `rule_ids` and `implementation_status`, which say which zanity rules detect it. The `standards_crosswalk` file it names is not kept here.

zanity's own scripts:

- `sync.py` writes the `.catalogue` field of each rule in `src/rules.zig`, the source of truth, into `catalogue.json`. `zig build test` fails until they agree.
- `triage.py` writes `TRIAGE.md`, the families no rule detects yet, grouped by how a check could find them.

```sh
python3 catalogue/sync.py && python3 catalogue/triage.py
```

To move to a newer catalogue, copy its `catalogue.json` over this one and run both scripts.

## Attribution

CWE content is maintained by MITRE and its contributors; its IDs, names, descriptions and other metadata are kept as published, with links. No endorsement is implied and no new licence is assigned to it. See https://cwe.mitre.org/about/termsofuse.html before redistributing it.
