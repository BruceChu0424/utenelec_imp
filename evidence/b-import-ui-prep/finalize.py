from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,subprocess
p=argparse.ArgumentParser();p.add_argument('--config',required=True);a=p.parse_args();base=Path(__file__).resolve().parent;root=base.parents[1]
config=json.loads(Path(a.config).read_text(encoding='utf-8-sig'));secrets=[config[k].encode() for k in ['password','syntheticAccountPassword','jwtSecret','hmacKey','pgpMasterKey','bootstrapPassword']]
def git(*args):return subprocess.check_output(['git','-C',str(root),*args]).decode().strip()
assert not git('diff','--name-only','31b25b93841d29b026ac02dce89eb3acb852c892','--','server/src/main','lib','server/pom.xml')
before=json.loads((base/'root-readonly-1.json').read_text(encoding='utf8'));after=json.loads((base/'root-readonly-after-actors.json').read_text(encoding='utf8'));seed=json.loads((base/'import-actors-final.json').read_text(encoding='utf8'))
oldGoods={r['id'] for r in before['goods']};oldActors={r['id'] for r in before['ordinaryActors']};newGoods=[r for r in after['goods'] if r['id'] not in oldGoods];newActors=[r for r in after['ordinaryActors'] if r['id'] not in oldActors]
checks={'oldGoodsSelectedFieldsUnchanged':before['goods']==[r for r in after['goods'] if r['id'] in oldGoods],'oldActorsAndGrantsUnchanged':before['ordinaryActors']==[r for r in after['ordinaryActors'] if r['id'] in oldActors],'mappedRolesUnchanged':before['roleMappings']==after['roleMappings'],'onlyTwoNewActors':{r['id'] for r in newActors}=={r['userId'] for r in seed['accounts'].values()},'onlyTwoNecessaryNewGoods':{r['id'] for r in newGoods}=={seed['bomPrerequisites']['parentId'],seed['bomPrerequisites']['componentId']},'noBomGlChartNoteAuxWrites':all(r['count']==next(x['count'] for x in after['counts'] if x['tab']==r['tab']) for r in before['counts'] if r['tab']!='goods')}
assert all(checks.values()),checks
(base/'only-new-fixture-proof.json').write_bytes(json.dumps({'status':'prep; no file upload/detect/apply/approve/GL','checks':checks},indent=2).encode('utf8'))
files=[]
for f in sorted(base.rglob('*')):
 if not f.is_file():continue
 rel=f.relative_to(base)
 if f.name=='manifest.json' or any(x in ['private','tmp','__pycache__'] or x.startswith('build-') for x in rel.parts[:-1]):continue
 raw=f.read_bytes();assert not any(s in raw for s in secrets),'Private value in '+str(rel)
 files.append({'file':rel.as_posix(),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
(base/'manifest.json').write_bytes(json.dumps({'status':'prep; original C audit/files unchanged; final actual Web remains Root','sourceBase':git('rev-parse','HEAD'),'capturedAtUtc':datetime.now(timezone.utc).isoformat(),'secretValueMatches':0,'files':files},ensure_ascii=False,indent=2).encode('utf8'));print('Bound '+str(len(files))+' prep artifacts; narrow fixture proof passed; no private values.')
