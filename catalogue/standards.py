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
 assert len(q)==40 and len({e['id'] for e in q})==40
 assert len(crosswalk['iso25010']['characteristics'])==9
 assert set(x['characteristic'] for x in q)==set(crosswalk['iso25010']['characteristics'])
 for e in q:
  assert e['family_ids'] and set(e['family_ids'])<=known
  assert e['mapping_authority']=='author_proposed'
  assert e['catalogue_mapping_status'] in {'partial','complete','missing'}
  assert e['evidence_required'] and e['remaining_gap']
 s=crosswalk['iso5055'];rows=s['table_memberships']
 assert len(rows)==194 and len({r['cwe_id'] for r in rows})==138
 assert {r['table'] for r in rows}=={1,2,3,4}
 for r in rows:
  assert r['catalogue_family_id'] in known
  assert r['parent_cwe_id'] is None or r['parent_cwe_id'] in known
 patterns=s['xmi_patterns'];ids={p['source_id'] for p in patterns}
 assert len(ids)==len(patterns)==275
 for p in patterns:
  assert p['cwe_id'] is None or p['cwe_id'] in known
  for edge in p['relationships']:
   if edge['target_pattern_id'] not in ids:
    assert any(i.get('pattern')==p['source_id'] and i.get('target_pattern_id')==edge['target_pattern_id'] for i in s['issues']), 'Unrecorded unresolved source link'
 for c in s['xmi_categories']:
  assert set(c['unresolved_members'])==set(c['member_pattern_ids'])-ids
 assert len(s['conformance_gates'])==4

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
