"""Rebuild JSON/YAML from the pinned upstream snapshot and original extensions. Requires PyYAML."""
from pathlib import Path
import json, zipfile, hashlib, xml.etree.ElementTree as ET
from collections import Counter, defaultdict
import yaml
P=Path(__file__).parent
NS={'c':'http://cwe.mitre.org/cwe-7'}
def text(e): return ' '.join(''.join(e.itertext()).split()) if e is not None else ''
def cid(v): return 'CWE-'+v

def build():
 data=(P/'cwe-4.20.xml.zip').read_bytes()
 z=zipfile.ZipFile(P/'cwe-4.20.xml.zip');root=ET.fromstring(z.read(z.namelist()[0]))
 records=[];edges=[]
 # Classification is our provisional routing, not an assertion by CWE.
 policy={1044,1053,1068,1099,1110,1111,1112,1113,1114,1115,1116,1117,1118,1127}
 risk={242,477,561,563,676,1041,1042,1043,1048,1052,1054,1055,1056,1062,1064,1071,1074,1075,1080,1085,1086,1090,1092,1095,1101,1103,1104,1106,1107,1108,1109,1119,1121,1122,1123,1124,1126}
 for section,tag,kind in [('Weaknesses','Weakness','weakness'),('Categories','Category','category'),('Views','View','view')]:
  for x in root.findall(f'c:{section}/c:{tag}',NS):
   ident=cid(x.attrib['ID']);num=int(x.attrib['ID'])
   r={'id':ident,'title':x.attrib['Name'],'origin':'cwe','record_type':kind,'source_url':f'https://cwe.mitre.org/data/definitions/{num}.html','upstream_status':x.attrib['Status'],'active':x.attrib['Status']!='Deprecated','source_views':[]}
   if kind=='weakness':
    r.update({'abstraction':x.attrib.get('Abstraction'),'definition':text(x.find('c:Description',NS)),'assessment_kind':'policy_violation' if num in policy else 'risk_indicator' if num in risk else 'defect','classification_review':'proposed','classification_basis':'Author-maintained routing: explicit quality-policy and risk overrides; other CWE weaknesses provisionally treated as defects. Review against the target contract before enforcement.','mapping_notes':text(x.find('c:Mapping_Notes',NS)),'applicable_platforms':[{'kind':a.tag.split('}')[-1],**a.attrib} for a in x.findall('c:Applicable_Platforms/*',NS)],'upstream_detection_methods':[{'method':text(a.find('c:Method',NS)),'description':text(a.find('c:Description',NS)),'effectiveness':text(a.find('c:Effectiveness',NS))} for a in x.findall('c:Detection_Methods/c:Detection_Method',NS)],'detection_methods':[],'detection_review':'unreviewed','implementation_status':'unsupported','rule_ids':[],'tags':[]})
   else:
    r.update({'definition':text(x.find('c:Summary' if kind=='category' else 'c:Objective',NS)),'assessment_kind':None})
   records.append(r)
   for a in x.findall('c:Related_Weaknesses/c:Related_Weakness',NS):
    edges.append({'source':ident,'target':cid(a.attrib['CWE_ID']),'relation':a.attrib['Nature'],'view':cid(a.attrib['View_ID']),'ordinal':a.attrib.get('Ordinal')})
   for a in [*x.findall('c:Relationships/c:Has_Member',NS),*x.findall('c:Members/c:Has_Member',NS)]:
    edges.append({'source':ident,'target':cid(a.attrib['CWE_ID']),'relation':'HasMember','view':cid(a.attrib['View_ID']),'ordinal':None})
 # Directed membership/child closure, confined to each view. Preserve raw edges separately.
 by_view=defaultdict(lambda:defaultdict(set))
 for e in edges:
  if e['relation'] in {'HasMember','ParentOf'}: by_view[e['view']][e['source']].add(e['target'])
  elif e['relation'] in {'ChildOf','MemberOf'}: by_view[e['view']][e['target']].add(e['source'])
 indexes={}
 for r in records:
  if r['record_type']!='view':continue
  v=r['id']; seen=set();stack=list(by_view[v].get(v,set()))
  while stack:
   n=stack.pop()
   if n in seen:continue
   seen.add(n);stack.extend(by_view[v].get(n,set())-seen)
  indexes[v]=sorted(seen)
 for r in records:r['source_views']=sorted(v for v,ids in indexes.items() if r['id'] in ids)
 extensions=json.loads((P/'extensions.json').read_text())
 entries=sorted([r for r in records if r['record_type']=='weakness'],key=lambda r:int(r['id'][4:]))+extensions
 nav=[r for r in records if r['record_type']!='weakness']
 cat={'schema_version':'2.0','catalogue_version':'0.3.0','source':{'url':'https://cwe.mitre.org/data/xml/cwec_v4.20.xml.zip','version':root.attrib['Version'],'published':root.attrib['Date'],'retrieved':'2026-09-27','sha256':hashlib.sha256(data).hexdigest()},'scope':'All Weakness, Category and View records in the pinned CWE XML; original engineering extensions. Not an exhaustive inventory of every engineering failure.','entries':entries,'navigation':nav,'relationships':edges,'view_index':indexes}
 cat['standards_crosswalk']='standards-crosswalk.json'
 (P/'catalogue.json').write_text(json.dumps(cat,indent=2)+'\n')
 (P/'catalogue.yaml').write_text(yaml.safe_dump(cat,sort_keys=False,allow_unicode=True))
 summary={'catalogue_version':'0.3.0','cwe_version':root.attrib['Version'],'cwe_weaknesses':len(entries)-len(extensions),'extensions':len(extensions),'total_families':len(entries),'categories':sum(r['record_type']=='category' for r in nav),'views':len(indexes),'deprecated_weaknesses':sum(not r['active'] for r in entries),'assessment_kinds':dict(Counter(r['assessment_kind'] for r in entries)),'implemented_detectors':0}
 summary.update({k:v for k,v in json.loads((P/'summary.json').read_text()).items() if k.startswith(('iso','ascqm'))})
 (P/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(summary)
if __name__=='__main__':build()
