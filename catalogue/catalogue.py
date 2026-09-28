"""Inspect the catalogue; Python 3.11+, standard library only."""
from __future__ import annotations
import argparse,json
from pathlib import Path
from collections import Counter
from typing import Any
P=Path(__file__).parent
KINDS={'defect','policy_violation','risk_indicator'}
def validate(d:dict[str,Any])->None:
 assert __debug__, 'Do not disable validation with -O'
 assert d['schema_version']=='2.0'
 records=d['entries']+d['navigation'];ids=[e['id'] for e in records]
 assert len(ids)==len(set(ids)), 'Duplicate ID'
 known=set(ids);views={e['id'] for e in d['navigation'] if e['record_type']=='view'}
 for e in d['entries']:
  assert e['record_type'] in {'weakness','extension'}
  assert e['assessment_kind'] in KINDS
  assert e['classification_review'] in {'proposed','reviewed'}
  assert e['implementation_status'] in {'unsupported','partial','implemented'}
  assert e['definition'] and e['title']
  assert set(e['detection_methods']) <= {'static','runtime','configuration','specification','manual'}
  if e['implementation_status']!='unsupported':assert e['rule_ids'], 'Coverage needs rule IDs'
  if e['origin']=='extension':
   assert e['positive_example'] and e['negative_example'] and e['evidence_required']
 for e in d['navigation']:assert e['assessment_kind'] is None
 for e in records:assert set(e['source_views'])<=views
 for e in d['relationships']:
  assert e['source'] in known and e['target'] in known, f"Unresolved relationship {e}"
  assert e['view'] in views
 assert set(d['view_index'])==views
 for v,members in d['view_index'].items():
  assert set(members)<=known
  assert set(members)=={e['id'] for e in records if v in e['source_views']}

def main()->None:
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('command',choices=['validate','stats','search','show'])
 ap.add_argument('query',nargs='?',default='')
 ap.add_argument('--kind',choices=sorted(KINDS))
 ap.add_argument('--view',help='CWE view ID, e.g. CWE-699 or CWE-1305')
 ap.add_argument('--active',action='store_true',help='Exclude deprecated records; does not establish applicability')
 ap.add_argument('--file',type=Path,default=P/'catalogue.json')
 a=ap.parse_args();d=json.loads(a.file.read_text());validate(d)
 if a.view and a.view not in d['view_index']:ap.error('Unknown view ID')
 entries=[e for e in d['entries'] if (not a.kind or e['assessment_kind']==a.kind) and (not a.view or a.view in e['source_views']) and (not a.active or e['active'])]
 if a.command=='validate':print(f"Valid: {len(d['entries'])} families; {len(d['navigation'])} navigation records")
 elif a.command=='stats':print(json.dumps({'families':len(entries),'kinds':dict(Counter(e['assessment_kind'] for e in entries)),'implementation':dict(Counter(e['implementation_status'] for e in entries))},indent=2))
 elif a.command=='show':
  matches=[e for e in entries+d['navigation'] if e['id'].casefold()==a.query.casefold()]
  if not matches:ap.error('Unknown or filtered ID')
  print(json.dumps(matches[0],indent=2))
 else:
  for e in entries:
   if a.query.casefold() in (e['id']+' '+e['title']+' '+e['definition']).casefold():print(f"{e['id']}\t{e['assessment_kind']}\t{e['title']}")
if __name__=='__main__':main()
