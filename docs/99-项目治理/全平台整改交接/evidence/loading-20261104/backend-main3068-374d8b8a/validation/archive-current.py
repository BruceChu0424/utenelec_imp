import concurrent.futures,hashlib,json,shutil,subprocess,zipfile
from datetime import datetime,timezone
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3]
source=json.loads((base/'source-input.json').read_text(encoding='utf-8'));acceptance=json.loads((base/'backend-current-acceptance.json').read_text(encoding='utf-8'));assert acceptance['green'] and acceptance['sourceAggregateSha256']==source['aggregateSha256']
head=source['upstreamMainHead'];prefix=source['aggregateSha256'][:8]
destination=root/'docs/99-项目治理/全平台整改交接/evidence/loading-20261104'/('backend-main3068-'+prefix);assert not destination.exists(),destination
destination.mkdir(parents=True)
tree=subprocess.check_output(['git','-C','D:/Projects/uten_imp','ls-tree','-r','-z',head]);oids={}
for row in tree.split(b'\0'):
    if row:
        entry,path=row.split(b'\t');oids[path.decode('utf-8')]=entry.split()[2].decode()
def changed(entry):
    p=entry['path'];data=(root/p).read_bytes();assert hashlib.sha256(data).hexdigest()==entry['sha256'],p
    identity=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    return (p,data,oids.get(p)) if oids.get(p)!=identity else None
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:delta=[e for e in pool.map(changed,source['files']) if e]
readme='docs/数据迁移/README.md';delta.append((readme,(root/readme).read_bytes(),oids[readme]))
source_delta=[]
for p,data,oid in delta:
    target=destination/'source-delta'/p;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    source_delta.append({'path':p,'mainBlobOid':oid,'candidateSha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
shutil.copytree(base,destination/'validation',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
composition=root/'build/loading-validation/upstream-3068f-backend-preview'
for name in ('review.json','staging-review.json','adoption-receipt.json','old-six-peer-source-bridge.json','root-new-six-independent-peer.json'):
    p=composition/name;assert p.is_file(),p;shutil.copy2(p,destination/name)
shutil.copy2(root/'build/loading-validation/upstream-current-composition/backend-reviewed-resolutions.json',destination/'backend-reviewed-resolutions.json')
summary={'archivedAtUtc':datetime.now(timezone.utc).isoformat(),'baseMain':head,'candidateCompleteSource':source['aggregateSha256'],'candidateInputPaths':len(source['files']),'sourceDelta':source_delta,'javaCurrentClasses':acceptance['javaUniqueClasses'],'javaCurrentTests':acceptance['javaUniqueTests'],'legacyCurrentTests':acceptance['legacyCurrent']['tests'],'knownNextStagePreflightDefect':'preflight-original-subversion-rejection.json preserves the real old integer-only metadata entry failure. Core65 performance/business guards are completed at this immutable source; this is not a claim that the whole offline bootstrap entry is already compatible. The separately authorized version-identity producer/consumer repair follows with a new source clock.','scope':'This completed core3068 stage is separate from oldf6/0d49 and original058da/a5ed results. No historical counts added; no Main/company DB writes/commit/push/application-package/deploy.'}
(destination/'stage-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
members=[p for p in destination.rglob('*') if p.is_file()]
manifest=[{'path':str(p.relative_to(destination)).replace('\\','/'),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in sorted(members)]
(destination/'member-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');members.append(destination/'member-manifest.json')
archive=destination/'backend-main3068-evidence.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted(members):z.write(p,str(p.relative_to(destination)).replace('\\','/'))
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    for e in manifest:assert hashlib.sha256(z.read(e['path'])).hexdigest()==e['sha256']
receipt={'archivePath':str(archive.relative_to(root)).replace('\\','/'),'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'bytes':archive.stat().st_size,'members':len(members),'zipCrcAndAllMemberShaVerified':True,'currentAcceptanceSha256':hashlib.sha256((base/'backend-current-acceptance.json').read_bytes()).hexdigest(),'sourceAggregateSha256':source['aggregateSha256']}
(destination/'archive-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8');(base/'durable-archive-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8');print(json.dumps(receipt))
