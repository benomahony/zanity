# Engineering error catalogue 0.3.0

A broad, inspectable foundation for a checker: **969 CWE weaknesses + 66 original engineering families = 1,035 families**. Includes all 422 categories and 59 views separately as navigation. Categories and views are not defects. All records from the CWE 4.20 Weaknesses, Categories and Views sections are retained, including hardware and deprecated records.

This package implements catalogue import, validation and inspection, not a source-code scanner. No detectors are claimed implemented. Complete ingestion of one dictionary is not exhaustive coverage of every engineering error.

## What changed

- Replaced the two-view CSV union with the complete, pinned CWE 4.20 XML dictionary.
- Preserved all original family IDs, including all 32 previous extensions.
- Added 28 engineering families for time, async execution, distributed resilience, data correctness, supply chain, privacy lifecycle and AI/agent behaviour.
- Added defect / policy violation / risk indicator classification, separate from implementation status and classification review status.
- Imported definitions, platform metadata, mapping notes and detection guidance.
- Preserved typed, view-scoped relationships and built traversable view membership indexes.
- Retained 25 deprecated weakness records for traceability; `--active` excludes them. Active does not mean applicable, verified or safe to enforce.

## Classification semantics

| Kind | Meaning | Required finding evidence |
|---|---|---|
| `defect` | Violates language semantics, a behavioural contract or a required protection | Applicable contract plus a reproducible counterexample or justified static proof |
| `policy_violation` | Violates an explicit project, architecture or operational rule | Identified policy/version and evidence that the rule is violated |
| `risk_indicator` | Suggests increased risk without establishing a concrete violation | Observed signal, relevant context and uncertainty; never describe it as a confirmed bug |

The labels are **author-proposed routing, not classifications issued by CWE**. All are marked `classification_review: proposed`. Imports use a provisional defect default with explicit policy/risk overrides listed in `import_cwe.py`; this is not a completed semantic review of 969 entries. Review each applicable family before enabling enforcement. High complexity, for example, is a risk indicator until an explicit project limit makes it a policy violation. A family label alone never establishes a defect in a particular program.

Keep severity, confidence, applicability and evidence separate. Policies must be supplied by the project; missing configuration is not itself a violation of a policy that was never specified. A rule may produce a review candidate while another rule produces proof of the same family. Multiple labels may refer to one underlying defect, so deduplicate using evidence and defect identity, not taxonomy labels.

## Files

- `catalogue.json`: canonical inventory, navigation, edges and view indexes (schema 2.0).
- `catalogue.yaml`: equivalent YAML export.
- `extensions.json`: editable source for all 66 original engineering families.
- `cwe-4.20.xml.zip`: unchanged upstream snapshot, with original upstream content and attribution.
- `import_cwe.py`: reproducible importer; requires Python 3.11+ and PyYAML.
- `catalogue.py`: inspection and validation CLI; Python 3.11+ standard library only.
- `summary.json`, `coverage-audit.md`, `validation.md`: counts, remaining gaps and verification results.

```bash
python catalogue.py validate
python catalogue.py stats --active
python catalogue.py stats --view CWE-1305
python catalogue.py search authorization
python catalogue.py search '' --kind risk_indicator
python catalogue.py show CWE-1427
python catalogue.py show EXT-ASYNC-001
```

Rebuild JSON/YAML after editing `extensions.json` or the explicit classification overrides:

```bash
python -m pip install 'PyYAML==6.0.3'
python import_cwe.py
python catalogue.py validate
```

Validation uses production assertions. Do not run with `-O`. The package has no source-code scanning command. Rule IDs remain empty and implementation status remains unsupported until actual detectors exist.

## Source and navigation semantics

Source: https://cwe.mitre.org/data/xml/cwec_v4.20.xml.zip

Version and publication date come from the XML root. Retrieval date and archive SHA-256 are recorded in `catalogue.json`. The archive is pinned and rebuilds work offline. Refreshing to a different upstream release requires deliberate version/hash review and ID reconciliation.

`source_views` is derived by traversing explicit HasMember/ParentOf and reverse ChildOf/MemberOf edges within each view. It is graph reachability, not a guessed topic label. Relationships remain scoped to their upstream view. Views defined by filters without an explicit reachable membership graph can have empty indexes; this does not prove they have no applicable weaknesses. The original views reconcile exactly to their downloaded CSV ID sets: 399 (CWE-699) and 138 (CWE-1305).

Imported hardware weaknesses remain available and retain platform metadata. There is no guessed software-only default that could silently discard shared weaknesses. A target profile should make applicability decisions explicitly. Deprecated records remain available but should not become new rules without reviewing their mapping and replacement guidance.

CWE-1305 is the CISQ **2020** view. This package does not claim ISO 5055 compliance. ISO 25010 now has a separate quality crosswalk; see standards-coverage.md for source and verification limits. NIST BF remains a reference framework. Local extension overlap with CWE remains an explicit review task; adding an extension does not claim CWE lacks a related concept.

## Attribution

CWE content is maintained by MITRE and its contributors. Original IDs, names, descriptions and other upstream metadata are preserved with links; original source material is included unmodified in its archive. No endorsement is implied and no new licence is assigned to upstream content. See https://cwe.mitre.org/about/termsofuse.html before redistribution.

References:
- https://cwe.mitre.org/data/downloads.html
- https://cwe.mitre.org/data/definitions/699.html
- https://cwe.mitre.org/data/definitions/1305.html
- https://www.it-cisq.org/standards/code-quality-standards/
- https://www.iso.org/standard/78176.html
- https://csrc.nist.gov/pubs/sp/800/231/final

## Complementary standards perspectives (0.3.0)

See `standards-coverage.md` for the readable coverage matrix and discrepancies, and `standards-crosswalk.json` / `.yaml` for machine-readable links. Product qualities, structural measures, weaknesses and detector patterns remain distinct records with many-to-many relationships. Classification labels do not restrict these relationships.

```bash
python standards.py validate
python standards.py summary
python standards.py quality safety
python standards.py measure reliability
python standards.py issues
```

Upstream standards PDFs and XMI are not bundled in this release; their source URLs and byte hashes are recorded. The crosswalk is a reviewed working inventory. Regenerating it from an updated standard requires source review, not automatic substitution. The CWE importer preserves the separate standards files. All 40 quality links remain partial and all actual detector implementations remain unsupported. This update does not claim all ISO standards are covered.
