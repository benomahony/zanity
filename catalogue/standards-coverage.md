# Standards coverage — 0.3.0

The catalogue now includes distinct, linked product-quality and structural-measure perspectives. Multiple standards may point to the same defect family. A link does not mean that every failure mode or detector is covered.

## ISO/IEC 25010:2023

All nine characteristics and 40 subcharacteristic names are indexed. The public ISO preview directly verifies the first 12 subcharacteristics. The remaining names are sourced from Table I of the linked research paper and corroborated where possible by the preview revision notes. This is a complete named roster from those sources, not a full normative clause review. Definitions are not reproduced; failure scenarios and mappings below are our own proposals.

| Characteristic | Subcharacteristic | Related families | Required evidence |
|---|---|---|---|
| Functional suitability | Functional completeness | EXT-DOMAIN-001 | Accepted requirements and end-to-end scenarios |
| Functional suitability | Functional correctness | EXT-DOMAIN-002, CWE-682 | Domain examples and numerical boundary cases |
| Functional suitability | Functional appropriateness | EXT-DOMAIN-001 | Goal-to-workflow acceptance scenarios |
| Performance efficiency | Time behaviour | CWE-1088, EXT-TIME-001 | Latency and throughput measurements under a declared workload |
| Performance efficiency | Resource utilization | CWE-401, CWE-770 | Resource profiles under sustained and peak workloads |
| Performance efficiency | Capacity | CWE-410, EXT-RESILIENCE-002 | Capacity envelope and saturation scenarios |
| Compatibility | Co-existence | CWE-770 | Co-located workload interference scenarios |
| Compatibility | Interoperability | EXT-ARCH-004, EXT-DELIVERY-001 | Consumer-provider semantic contract scenarios |
| Interaction capability | Appropriateness recognizability | EXT-QUALITY-001 | Representative users identifying supported and unsupported tasks |
| Interaction capability | Learnability | EXT-QUALITY-002 | First-use task studies with explicit success criteria |
| Interaction capability | Operability | EXT-HUMAN-001 | Task completion using declared devices and input modes |
| Interaction capability | User error protection | EXT-HUMAN-002 | Misuse scenarios and undo or confirmation requirements |
| Interaction capability | User engagement | EXT-QUALITY-003 | Defined engagement outcomes and representative-user evidence |
| Interaction capability | Inclusivity | EXT-HUMAN-001 | Access needs, language and device profiles with journey evidence |
| Interaction capability | User assistance | EXT-QUALITY-004 | Recovery journeys and contextual-help acceptance scenarios |
| Interaction capability | Self-descriptiveness | CWE-1111 | Interface comprehension and state-feedback studies |
| Reliability | Faultlessness | EXT-VERIFY-001, CWE-703 | Representative usage histories and independent behavioural checks |
| Reliability | Availability | EXT-RESILIENCE-003, CWE-833 | Availability objective and operational observations |
| Reliability | Fault tolerance | EXT-DISTRIBUTED-003 | Fault injection and declared degraded-mode contracts |
| Reliability | Recoverability | EXT-DELIVERY-004 | Restore rehearsals and recovery time and data-loss limits |
| Security | Confidentiality | CWE-200, EXT-PRIVACY-001 | Data-flow boundaries and access-control scenarios |
| Security | Integrity | CWE-345, EXT-DATA-004 | Tampering and concurrent-update scenarios |
| Security | Non-repudiation | CWE-347 | Signed records and evidence-validation requirements |
| Security | Accountability | CWE-778, EXT-OBS-002 | Audit continuity and identity-correlation scenarios |
| Security | Authenticity | CWE-287, CWE-295 | Identity proof and certificate validation scenarios |
| Security | Resistance | CWE-307, EXT-RESILIENCE-002 | Threat-driven stress scenarios and recovery objectives |
| Maintainability | Modularity | EXT-ARCH-001, CWE-1047 | Dependency policy and change-propagation evidence |
| Maintainability | Reusability | EXT-QUALITY-005 | Independent second-context integration scenarios |
| Maintainability | Analysability | EXT-OBS-002, CWE-1053 | Diagnosis exercises with available code and operational evidence |
| Maintainability | Modifiability | EXT-ARCH-004, CWE-1068 | Representative change tasks and regression evidence |
| Maintainability | Testability | EXT-VERIFY-002 | Controllability, observability and fault-seeding evidence |
| Flexibility | Adaptability | EXT-ARCH-003 | Supported-environment execution matrix |
| Flexibility | Scalability | EXT-RESILIENCE-002 | Scale-out and scale-in workload scenarios |
| Flexibility | Installability | EXT-BUILD-004, EXT-DELIVERY-003 | Fresh install, upgrade and removal scenarios |
| Flexibility | Replaceability | EXT-ARCH-004, EXT-DELIVERY-001 | Substitution and migration acceptance scenarios |
| Safety | Operational constraint | EXT-HUMAN-003 | Enforced limits and safety-boundary scenarios |
| Safety | Risk identification | EXT-QUALITY-006 | Hazard inventory and detection scenarios |
| Safety | Fail safe | EXT-HUMAN-003 | Fault injection against explicit safe-state requirements |
| Safety | Hazard warning | EXT-OBS-003, EXT-HUMAN-002 | Warning timing, clarity and delivery evidence |
| Safety | Safe integration | EXT-HUMAN-003 | Integration hazard analysis and cross-component scenarios |

Every link is marked **partial**, because a named scenario or related CWE does not establish complete coverage of a quality property. Six new requirement-dependent families fill previously unmapped areas: recognizability, learnability, engagement, assistance, reusability and risk identification.

## ISO 5055 / OMG ASCQM source audit

The public OMG PDF contains 194 table memberships spanning 138 distinct CWE IDs; every ID is present in our catalogue. Parent/contributor role labels are extracted from table cell shading and remain provisional where the source disagrees.

| Measure | Observed table rows | Observed parent/contributor colours | Narrative parent/contributor count |
|---|---:|---|---|
| Maintainability | 29 | 29 / 0 | 29 / 0 |
| Performance efficiency | 18 | 15 / 3 | 16 / 3 |
| Reliability | 74 | 35 / 39 | 35 / 39 |
| Security | 73 | 35 / 38 | 36 / 37 |

The separate normative XMI contains 275 pattern definitions: weakness definitions and detection-pattern definitions are kept distinct. Its 139 referenced CWE IDs all resolve in the catalogue. Relationships and four measure categories are indexed; these are specification metadata, not executed detector implementations.

### Discrepancies retained

- PDF tables versus CWE-1305: tables include CWE-1121; the view includes CWE-624 instead.
- PDF tables versus XMI: tables additionally contain CWE-1121; XMI additionally references CWE-1093 and CWE-624.
- XMI categories reference missing definition `id.wk.303`; two links from `id.sfgd.86` use `NA` and `character(0)` placeholders.
- Performance and security summary counts disagree with the observed table rows or shading.
- The ISO catalogue identifies ISO/IEC 5055:2021; OMG web metadata and PDF cover use inconsistent 2020/2023 release labels. Exact URLs, hashes and document identifiers are retained.

These observations prevent an unqualified ISO conformance claim. No source discrepancy has been silently repaired or treated as an omitted detector requirement. Clause 6 tables are informative; normative detector semantics and measurement calculations require additional implementation review.

## Checker conformance work

Automation, repeatability, declared inputs and independent reproducibility are recorded as separate implementation gates. All four are currently unimplemented. Detection-pattern semantics, counting rules and full ISO clause verification remain open, even though the source inventories are indexed.

## Sources

- ISO25010:2023-preview: https://cdn.standards.iteh.ai/samples/78176/13ff8ea97048443f99318920757df124/ISO-IEC-25010-2023.pdf
- ISO25010:2023-roster: https://www.cs.montana.edu/izurieta/pubs/Sheppard_CSR_2025.pdf
- ISO5055:OMG-PDF: https://www.omg.org/spec/ASCQM/ISO/5055/PDF
- ASCQM:20190531-XMI: https://www.omg.org/spec/ASCQM/20190531/ascqm.xmi
