from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,subprocess
p=argparse.ArgumentParser();p.add_argument('--runtime-config',required=True);a=p.parse_args()
base=Path(__file__).resolve().parent;root=base.parents[1]
config=json.loads(Path(a.runtime_config).read_text(encoding='utf-8-sig'))
secrets=[config[k].encode() for k in ['password','syntheticAccountPassword','jwtSecret','hmacKey','pgpMasterKey','bootstrapPassword']]
def git(*args):return subprocess.check_output(['git','-C',str(root),*args]).decode().strip()
assert not git('diff','--name-only','55d74b716acf49e8b6d81024f062cdebe46e518b','--','server/src/main','server/pom.xml','lib')
files=[];bad=[]
for f in sorted(base.rglob('*')):
    if not f.is_file():continue
    relative=f.relative_to(base)
    if any(part in ['tmp','private','__pycache__'] or part.startswith('build-') for part in relative.parts[:-1]):continue
    if f.name=='manifest.json':continue
    raw=f.read_bytes()
    if any(secret in raw for secret in secrets):bad.append(relative.as_posix())
    files.append({'file':relative.as_posix(),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
if bad:raise SystemExit('Private value found in: '+','.join(bad))
receipt={'status':'prep: new ordinary finance actor and unassigned synthetic accounts; not Web acceptance','sourceBase':git('rev-parse','HEAD'),'mainObserved':git('rev-parse','main'),'capturedAtUtc':datetime.now(timezone.utc).isoformat(),'secretValueMatchCount':0,'files':files}
(base/'manifest.json').write_bytes(json.dumps(receipt,ensure_ascii=False,indent=2).encode('utf8'))
print('Bound '+str(len(files))+' nonprivate files; 0 private value matches.')
