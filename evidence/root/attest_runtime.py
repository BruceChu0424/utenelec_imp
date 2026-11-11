from pathlib import Path
import hashlib
import json
import subprocess
from datetime import datetime, timezone

root=Path(__file__).resolve().parents[2]
launch='2bc2f98ba0a9f991afaa13c68e093dc6de94fe7d'
output=Path(__file__).parent/'runtime-prepare-1-provenance.json'
if output.exists():raise SystemExit('Preserve previous runtime provenance')
def git(*args):return subprocess.check_output(['git','-C',str(root),*args]).decode().strip()
paths=['server/src/main/java','server/src/main/resources','server/pom.xml']
unchanged=git('diff','--name-only',launch,'HEAD','--',*paths).splitlines()
if unchanged:raise SystemExit('Backend source changed since the observed launch; record the actual delta instead')
classes=Path(__file__).parent/'runtime-maven-prepare-1/classes'
digest=hashlib.sha256();count=0
for file in sorted(classes.rglob('*')):
    if file.is_file() and (file.suffix=='.class' or file.parent.name=='migration' and file.suffix=='.sql'):
        relative=file.relative_to(classes).as_posix()
        digest.update(relative.encode());digest.update(b'\0');digest.update(hashlib.sha256(file.read_bytes()).digest());count+=1
result={'kind':'preparation runtime; not final acceptance','capturedAtUtc':datetime.now(timezone.utc).isoformat(),
        'launchSourceObserved':launch,'currentHead':git('rev-parse','HEAD'),'backendSourceUnchangedSinceLaunch':True,
        'sourceGitObjects':{path:git('rev-parse',launch+':'+path) for path in paths},
        'applicationPidFromOwnStartupLog':59440,'backendPort':28630,'database':'127.0.0.1:26630/feedback',
        'compiledDirectory':str(classes),'compiledClassAndSqlFiles':count,
        'compiledFingerprint':digest.hexdigest(),'compiledFingerprintBytes':'sorted relative path UTF-8 + NUL + raw SHA-256 per actual class/SQL file'}
output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps(result,ensure_ascii=False,indent=2))
