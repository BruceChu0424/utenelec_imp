from pathlib import Path
import hashlib,json,subprocess
from datetime import datetime,timezone
base=Path(__file__).resolve().parent;root=base.parents[1]
def git(*args):return subprocess.check_output(['git','-C',str(root),*args]).decode().strip()
def tree(directory):
    digest=hashlib.sha256();count=0
    for file in sorted(directory.rglob('*')):
        if file.is_file():
            relative=file.relative_to(directory).as_posix();digest.update(relative.encode());digest.update(b'\0');digest.update(hashlib.sha256(file.read_bytes()).digest());count+=1
    return {'files':count,'sha256':digest.hexdigest(),'algorithm':'sorted relative UTF-8 path + NUL + raw file SHA-256'}
candidate='6e1bfd38a5b6f8db1ce565abcd9216ec8b2919e2'
if git('diff','--name-only',candidate,'--','server/src/main','server/pom.xml'):raise SystemExit('Product source changed')
provenance={'status':'prep; final integrated Web not run by B','capturedAtUtc':datetime.now(timezone.utc).isoformat(),'candidate':candidate,'mainObserved':git('rev-parse','main'),'branch':git('branch','--show-current'),'sourceGitObjects':{path:git('rev-parse',candidate+':'+path) for path in ['server/src/main/java','server/src/main/resources','server/pom.xml']},'compiledCurrent':tree(base/'build-current-6e/classes'),'isolatedPg':'127.0.0.1:26633; bremediation (original first run) and bremediation_retry (restored old dump then successful upgrade)','rootLiveDatabase':'read-only RR snapshots only; no login/ACL/seed/schema/server changes','oldDumpSha256':hashlib.sha256((base/'private/old-program-before-upgrade.dump').read_bytes()).hexdigest()}
(base/'prep-provenance.json').write_text(json.dumps(provenance,indent=2),encoding='utf8')
files=[]
for file in sorted(base.rglob('*')):
    if not file.is_file():continue
    relative=file.relative_to(base)
    if any(part=='private' or part=='tmp' or part.startswith('build-') or part=='__pycache__' for part in relative.parts):continue
    if file.name=='evidence-manifest.json':continue
    files.append({'file':relative.as_posix(),'bytes':file.stat().st_size,'sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
(base/'evidence-manifest.json').write_text(json.dumps({'status':'prep; exact raw bytes, original failures retained','files':files},ensure_ascii=False,indent=2),encoding='utf8')
print('Bound '+str(len(files))+' prep source/evidence artifacts; no private values printed.')
