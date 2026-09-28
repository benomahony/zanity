# Coverage audit — 0.3.0

## Closed ingestion gaps

All 969 weakness records in the pinned CWE 4.20 dictionary are imported. CWE-862, CWE-863, CWE-352 and CWE-1427 are present. All prior IDs remain. Full XML relationships replace the incomplete CSV hierarchy. Categories/views are separated from families.

## Expanded engineering coverage

| Added group | Families |
|---|---|
| Time | elapsed-time clocks; calendar/timezone interpretation; expiry boundaries; ambiguous timestamps |
| Async | cancellation; task ownership; unawaited operations; shutdown ordering |
| Resilience | retry amplification; backpressure; starvation; poison messages |
| Data | join multiplicity; aggregation grain; cache invalidation; lost updates |
| Supply chain | dependency identity; artifact substitution; incompatible resolution; transitive execution |
| Privacy | collection minimisation; retention; deletion propagation; purpose restriction |
| Agents | unsupported claims; delegated authority; tool-output trust; premature success reports |

These 28 original families supplement the existing 32; six further quality families are added in 0.3.0. All include definitions, positive/negative scenarios, detection approaches and evidence requirements. Scenarios are not executable test fixtures. Privacy entries refer to declared policy and contracts; they do not encode legal advice.

## Remaining work

1. Review provisional classifications for the selected target. Defect defaults and policy/risk overrides are transparent, but are not an exhaustive semantic adjudication.
2. Reconcile local extension overlap with CWE and avoid duplicate findings.
3. Define applicability by language/version, framework, architecture and execution environment. Do not infer all entries apply everywhere.
4. Integrate real detectors, including compiler/type errors, framework rules and dependency advisories. Currently zero implemented detectors.
5. Build executable positive/negative fixtures and adversarial boundary cases for each detector's actual promise.
6. Complete ISO quality-model and safety/hazard analysis audits for the target domain. Accessibility, localisation and human factors still require wider scenario inventories.
7. Broaden AI evaluation beyond these four agent families where relevant: stochastic reliability, model/data drift, evaluation contamination and statistical validity need dedicated domain profiles.
8. Review graph views defined by filters rather than explicit membership; empty indexes must not be treated as evidence of absence.
9. Expand data engineering profiles where required (lineage, schema evolution, late events, missingness and sampling bias).

Report catalogue membership, reviewed applicability, implemented rule coverage and measured detection performance separately. No single global coverage percentage is justified by the family count.

## Standards update

ISO 25010 quality characteristics and subcharacteristics, ISO 5055-linked PDF table memberships and OMG XMI pattern indexes are now represented. See standards-coverage.md for precise inventory coverage, partial mapping status and unresolved source inconsistencies. Further work is normative verification and detection implementation, not simply adding these standards as citations.
