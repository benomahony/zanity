"""Inspect complementary standards perspectives. Python 3.11+, standard library only."""
from __future__ import annotations
import argparse,json
from collections import Counter
from pathlib import Path
from typing import Any
P=Path(__file__).parent

def validate(catalogue:dict[str,Any],crosswalk:dict[str,Any])->None:
 assert __debug__, 'Do not run validation with -O'
 known={e['id'] for e in catalogue['entries']}
 q=crosswalk['iso25010']['subcharacteristics']
 # TODO: say why this must hold and what to look at when it fails.
 assert len(q)==40 and len({e['id'] for e in q})==40, f"expected len(q)==40 and len({{e['id'] for e in q}})==40, got q={q!r}"
 # TODO: say why this must hold and what to look at when it fails.
 assert len(crosswalk['iso25010']['characteristics'])==9, f"expected len(crosswalk['iso25010']['characteristics'])==9, got crosswalk['iso25010']['characteristics']={crosswalk['iso25010']['characteristics']!r}"
 # TODO: say why this must hold and what to look at when it fails.
 assert set(x['characteristic'] for x in q)==set(crosswalk['iso25010']['characteristics']), f"expected set(x['characteristic'] for x in q)==set(crosswalk['iso25010']['characteristics']), got q={q!r}, crosswalk['iso25010']['characteristics']={crosswalk['iso25010']['characteristics']!r}"
 for e in q:
  # TODO: say why this must hold and what to look at when it fails.
  assert e['family_ids'] and set(e['family_ids'])<=known, f"expected e['family_ids'] and set(e['family_ids'])<=known, got e['family_ids']={e['family_ids']!r}, e={e!r}, known={known!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert e['mapping_authority']=='author_proposed', f"expected e['mapping_authority']=='author_proposed', got e['mapping_authority']={e['mapping_authority']!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert e['catalogue_mapping_status'] in {'partial','complete','missing'}, f"expected e['catalogue_mapping_status'] in {{'partial','complete','missing'}}, got e['catalogue_mapping_status']={e['catalogue_mapping_status']!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert e['evidence_required'] and e['remaining_gap'], f"expected e['evidence_required'] and e['remaining_gap'], got e['evidence_required']={e['evidence_required']!r}, e={e!r}"
 s=crosswalk['iso5055'];rows=s['table_memberships']
 # TODO: say why this must hold and what to look at when it fails.
 assert len(rows)==194 and len({r['cwe_id'] for r in rows})==138, f"expected len(rows)==194 and len({{r['cwe_id'] for r in rows}})==138, got rows={rows!r}"
 # TODO: say why this must hold and what to look at when it fails.
 assert {r['table'] for r in rows}=={1,2,3,4}, f"expected {{r['table'] for r in rows}}=={{1,2,3,4}}, got rows={rows!r}"
 for r in rows:
  # TODO: say why this must hold and what to look at when it fails.
  assert r['catalogue_family_id'] in known, f"expected r['catalogue_family_id'] in known, got r['catalogue_family_id']={r['catalogue_family_id']!r}, known={known!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert r['parent_cwe_id'] is None or r['parent_cwe_id'] in known, f"expected r['parent_cwe_id'] is None or r['parent_cwe_id'] in known, got r['parent_cwe_id']={r['parent_cwe_id']!r}, r={r!r}, known={known!r}"
 patterns=s['xmi_patterns'];ids={p['source_id'] for p in patterns}
 # TODO: say why this must hold and what to look at when it fails.
 assert len(ids)==len(patterns)==275, f"expected len(ids)==len(patterns)==275, got ids={ids!r}, patterns={patterns!r}"
 for p in patterns:
  # TODO: say why this must hold and what to look at when it fails.
  assert p['cwe_id'] is None or p['cwe_id'] in known, f"expected p['cwe_id'] is None or p['cwe_id'] in known, got p['cwe_id']={p['cwe_id']!r}, p={p!r}, known={known!r}"
  for edge in p['relationships']:
   if edge['target_pattern_id'] not in ids:
    assert any(i.get('pattern')==p['source_id'] and i.get('target_pattern_id')==edge['target_pattern_id'] for i in s['issues']), 'Unrecorded unresolved source link'
 for c in s['xmi_categories']:
  # TODO: say why this must hold and what to look at when it fails.
  assert set(c['unresolved_members'])==set(c['member_pattern_ids'])-ids, f"expected set(c['unresolved_members'])==set(c['member_pattern_ids'])-ids, got c['unresolved_members']={c['unresolved_members']!r}, c['member_pattern_ids']={c['member_pattern_ids']!r}, ids={ids!r}"
 # TODO: say why this must hold and what to look at when it fails.
 assert len(s['conformance_gates'])==4, f"expected len(s['conformance_gates'])==4, got s['conformance_gates']={s['conformance_gates']!r}"

def main()->None:
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('command',choices=['validate','summary','quality','measure','issues'])
 ap.add_argument('query',nargs='?',default='')
 a=ap.parse_args();c=json.loads((P/'catalogue.json').read_text());s=json.loads((P/'standards-crosswalk.json').read_text());validate(c,s)
 if a.command=='validate':print('Standards links, inventories and documented unresolved references validated')
 elif a.command=='summary':
  print(json.dumps({'quality_characteristics':9,'quality_subcharacteristics':40,'quality_mapping_status':dict(Counter(x['catalogue_mapping_status'] for x in s['iso25010']['subcharacteristics'])),'measure_memberships':194,'unique_table_CWEs':138,'xmi_patterns':275,'issues':len(s['iso5055']['issues']),'detectors_implemented':0},indent=2))
 elif a.command=='quality':
  print(json.dumps([x for x in s['iso25010']['subcharacteristics'] if a.query.casefold() in (x['name']+' '+x['characteristic']).casefold()],indent=2))
 elif a.command=='measure':
  print(json.dumps([x for x in s['iso5055']['table_memberships'] if a.query.casefold() in (x['measure']+' '+x['cwe_id']).casefold()],indent=2))
 else:print(json.dumps(s['iso5055']['issues'],indent=2))
if __name__=='__main__':main()
