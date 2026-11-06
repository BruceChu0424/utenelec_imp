import hashlib,json,shutil,subprocess,zipfile
from datetime import datetime,timezone
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3]
source=json.loads((base/'complete-source-input.json').read_text(encoding='utf-8'));acceptance=json.loads((base/'backend-current-acceptance.json').read_text(encoding='utf-8'))
assert acceptance['green'] and acceptance['sourceAggregateSha256']==source['aggregateSha256']
consumers=root/'build/loading-validation/flyway-deploy-tests/current1013-final-consumers-result.json';checks=json.loads(consumers.read_text(encoding='utf-8'))
assert checks['rows']==1013 and checks['allThreeValidatorsEqual'] and checks['rawRowsUnchanged'] and checks['rawAliasAndDescriptionNegativesRejected']
destination=root/'docs/99-项目治理/全平台整改交接/evidence/loading-20261104'/('backend-mainfa-'+source['aggregateSha256'][:8]);assert not destination.exists();destination.mkdir(parents=True)
shutil.copytree(base,destination/'current-validation',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
shutil.copytree(base.parent/'main-fa-composition',destination/'fa-composition',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
old=base.parent/'main-6fb-crosswalk-qualified';previous=destination/'original6fb-nine-infra-red';previous.mkdir()
for name in ['source-input.json','original-nine-red-seal.json','queue-execution.json','current-pg-execution.json','current-pg.log','golden-current-installed-history-raw.json','golden-current-installed-history-raw.tsv','golden-current-installed-history-receipt.json','fast-seven-source-bridge.json','compiled-patch-receipt.json','core-applicability-bridge.json']:
    shutil.copy2(old/name,previous/name)
shutil.copytree(old/'current-pg-receipt',previous/'receipt')
shared=base.parent/'preflight-version-identity';gold=destination/'original1009-history';gold.mkdir()
for name in ['golden-installed-history-raw.json','golden-installed-history-raw.tsv','golden-installed-history-receipt.json']:
    shutil.copy2(shared/name,gold/name)
oldfast=base.parent/'main-6fb-version-identity';red=destination/'original-fast-quote-red';red.mkdir()
for name in ['source-input.json','current-fast-execution.json','current-fast.log']:
    shutil.copy2(oldfast/name,red/name)
shutil.copytree(oldfast/'current-fast-receipt',red/'receipt')
shutil.copy2(consumers,destination/consumers.name)
shutil.copy2(root/'build/loading-validation/upstream-current-composition/backend-reviewed-resolutions.json',destination/'backend-reviewed-resolutions.json')
tree=subprocess.check_output(['git','-C','D:/Projects/uten_imp','ls-tree','-r','-z',source['upstreamMainHead']]);oids={}
for row in tree.split(b'\0'):
    if row:
        detail,name=row.split(b'\t');oids[name.decode('utf-8')]=detail.split()[2].decode()
delta=[]
for entry in source['files']:
    p=entry['path'];raw=(root/p).read_bytes();assert hashlib.sha256(raw).hexdigest()==entry['sha256']
    oid=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
    if oid==oids.get(p):continue
    target=destination/'source-delta'/p;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
    delta.append({'path':p,'mainBlobOid':oids.get(p),'sha256':entry['sha256'],'bytes':len(raw)})
summary={'atUtc':datetime.now(timezone.utc).isoformat(),'source':source['aggregateSha256'],'mainHead':source['upstreamMainHead'],'currentNativeJavaClasses':acceptance['currentNativeJavaClasses'],'currentNativeJavaTests':acceptance['currentNativeJavaTests'],'qualifiedPythonTests':81,'pythonNativeSource':acceptance['pythonNativeSource'],'sourceDelta':delta,'priorCoreArchive':'backend-main3068-374d8b8a (prior65/452 remains prior source; no current native count arithmetic)','sourceClockPolicy':'Current native whole10fast+15PG; priorPython81 exact non-Markdown input bridge. Original fast quote failure and ninePG infrastructure failure retained, never rewritten to native0.','mainWritten':False,'companyDbWritten':False,'commitPushPackageDeploy':False}
(destination/'stage-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
members=sorted(p for p in destination.rglob('*') if p.is_file());manifest=[{'path':p.relative_to(destination).as_posix(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in members]
(destination/'member-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');members.append(destination/'member-manifest.json');archive=destination/'backend-mainfa-final-evidence.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in members:z.write(p,p.relative_to(destination).as_posix())
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    for e in manifest:assert hashlib.sha256(z.read(e['path'])).hexdigest()==e['sha256']
receipt={'archivePath':archive.relative_to(root).as_posix(),'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'bytes':archive.stat().st_size,'members':len(members),'everyMemberShaAndZipCrcVerified':True,'sourceAggregateSha256':source['aggregateSha256'],'acceptanceSha256':hashlib.sha256((base/'backend-current-acceptance.json').read_bytes()).hexdigest()}
(destination/'archive-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8');(base/'durable-archive-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8');print(json.dumps(receipt))
