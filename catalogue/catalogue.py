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
 # TODO: say why this must hold and what to look at when it fails.
 assert d['schema_version']=='2.0', f"expected d['schema_version']=='2.0', got d['schema_version']={d['schema_version']!r}"
 records=d['entries']+d['navigation'];ids=[e['id'] for e in records]
 assert len(ids)==len(set(ids)), 'Duplicate ID'
 known=set(ids);views={e['id'] for e in d['navigation'] if e['record_type']=='view'}
 for e in d['entries']:
  # TODO: say why this must hold and what to look at when it fails.
  assert e['record_type'] in {'weakness','extension'}, f"expected e['record_type'] in {{'weakness','extension'}}, got e['record_type']={e['record_type']!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert e['assessment_kind'] in KINDS, f"expected e['assessment_kind'] in KINDS, got e['assessment_kind']={e['assessment_kind']!r}, KINDS={KINDS!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert e['classification_review'] in {'proposed','reviewed'}, f"expected e['classification_review'] in {{'proposed','reviewed'}}, got e['classification_review']={e['classification_review']!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert e['implementation_status'] in {'unsupported','partial','implemented'}, f"expected e['implementation_status'] in {{'unsupported','partial','implemented'}}, got e['implementation_status']={e['implementation_status']!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert e['definition'] and e['title'], f"expected e['definition'] and e['title'], got e['definition']={e['definition']!r}, e={e!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert set(e['detection_methods']) <= {'static','runtime','configuration','specification','manual'}, f"expected set(e['detection_methods']) <= {{'static','runtime','configuration','specification','manual'}}, got e['detection_methods']={e['detection_methods']!r}"
  if e['implementation_status']!='unsupported':assert e['rule_ids'], 'Coverage needs rule IDs'
  if e['origin']=='extension':
   # TODO: say why this must hold and what to look at when it fails.
   assert e['positive_example'] and e['negative_example'] and e['evidence_required'], f"expected e['positive_example'] and e['negative_example'] and e['evidence_required'], got e['positive_example']={e['positive_example']!r}, e={e!r}"
 # TODO: say why this must hold and what to look at when it fails.
 for e in d['navigation']:assert e['assessment_kind'] is None, f"expected e['assessment_kind'] is None, got e['assessment_kind']={e['assessment_kind']!r}"
 # TODO: say why this must hold and what to look at when it fails.
 for e in records:assert set(e['source_views'])<=views, f"expected set(e['source_views'])<=views, got e['source_views']={e['source_views']!r}, views={views!r}"
 for e in d['relationships']:
  assert e['source'] in known and e['target'] in known, f"Unresolved relationship {e}"
  # TODO: say why this must hold and what to look at when it fails.
  assert e['view'] in views, f"expected e['view'] in views, got e['view']={e['view']!r}, views={views!r}"
 # TODO: say why this must hold and what to look at when it fails.
 assert set(d['view_index'])==views, f"expected set(d['view_index'])==views, got d['view_index']={d['view_index']!r}, views={views!r}"
 for v,members in d['view_index'].items():
  # TODO: say why this must hold and what to look at when it fails.
  assert set(members)<=known, f"expected set(members)<=known, got members={members!r}, known={known!r}"
  # TODO: say why this must hold and what to look at when it fails.
  assert set(members)=={e['id'] for e in records if v in e['source_views']}, f"expected set(members)=={{e['id'] for e in records if v in e['source_views']}}, got members={members!r}, records={records!r}, v={v!r}"

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
