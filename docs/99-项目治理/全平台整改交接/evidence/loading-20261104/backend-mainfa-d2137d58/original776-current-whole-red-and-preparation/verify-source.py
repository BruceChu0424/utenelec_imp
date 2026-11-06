import hashlib,json,sys,subprocess
from pathlib import Path
from datetime import datetime,timezone
base=Path(__file__).resolve().parent; root=base.parents[3]
sys.path.insert(0,str(base.parent/'main-f6e-metadata'))
from backend_inventory import source_paths
source_path=base/'complete-source-input.json'
source=json.loads(source_path.read_text(encoding='utf-8'))
expected={e['path']:e['sha256'] for e in source['files']}
assert len(expected)==len(source['files'])==7411
actual_paths=source_paths(root)|set(source['additionalSourceDependencies'])
assert actual_paths==set(expected),{'added':sorted(actual_paths-set(expected)),'removed':sorted(set(expected)-actual_paths)}
drift=[p for p,h in expected.items() if hashlib.sha256((root/p).read_bytes()).hexdigest()!=h]
assert not drift,drift
aggregate=hashlib.sha256(''.join(p+'\0'+expected[p]+'\n' for p in sorted(expected)).encode()).hexdigest()
assert aggregate==source['aggregateSha256']
main=subprocess.check_output(['git','-C','D:/Projects/uten_imp','rev-parse','HEAD'],text=True).strip()
assert main==source['upstreamMainHead']
entries=subprocess.check_output(['git','-C','D:/Projects/uten_imp','ls-tree','-r','-z',main,'--','server/src/main/resources/db/migration'])
committed=[];sql=[]
for row in entries.split(b'\0'):
    if not row:continue
    detail,path=row.split(b'\t');p=path.decode()
    if not p.endswith('.sql'):continue
    sql.append((p,detail.split()[2].decode()))
blobs=subprocess.check_output(['git','-C','D:/Projects/uten_imp','cat-file','--batch'],input=(''.join(oid+'\n' for _,oid in sql)).encode());offset=0
for p,oid in sql:
    end=blobs.index(b'\n',offset);header=blobs[offset:end].split();size=int(header[2]);offset=end+1
    raw=blobs[offset:offset+size];offset+=size+1
    assert raw==(root/p).read_bytes(),p
    committed.append(p)
assert len(committed)==1009
pin=root/'build/loading-validation/upstream-current-composition/backend-reviewed-resolutions.json'
assert hashlib.sha256(pin.read_bytes()).hexdigest()=='aa5fa4419fdeb95c96acafe7268c8726e0f7fe35a31300c0413d39f513dbd37d'
review=json.loads(pin.read_text(encoding='utf-8'));assert review['mainHead']==main and len(review['entries'])==4
for e in review['entries']:assert hashlib.sha256((root/e['path']).read_bytes()).hexdigest()==e['resolvedCandidateSha256']
receipt={'atUtc':datetime.now(timezone.utc).isoformat(),'sourceAggregateSha256':aggregate,'sourceFiles':len(expected),'sourcePathsetAndBytesDrift':[],'mainHead':main,'committedMainSqlRawEqual':len(committed),'migrations':len(list((root/'server/src/main/resources/db/migration').glob('V*.sql'))),'fourSemanticPinsSha256':hashlib.sha256(pin.read_bytes()).hexdigest()}
(base/'resumption-source-verification.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8');print(json.dumps(receipt))
