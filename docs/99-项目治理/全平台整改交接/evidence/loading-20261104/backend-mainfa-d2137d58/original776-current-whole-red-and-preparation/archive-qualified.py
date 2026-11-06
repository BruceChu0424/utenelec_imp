import hashlib,json,shutil,subprocess,zipfile
from pathlib import Path
from datetime import datetime,timezone
old=Path(__file__).resolve().parent;base=old.parent/'main-fa-gift-qualified';root=base.parents[3]
source=json.loads((base/'source-input.json').read_text(encoding='utf-8'));acceptance=json.loads((base/'backend-current-acceptance.json').read_text(encoding='utf-8'));assert acceptance['green'] and acceptance['originalWholeRedPreserved'] and acceptance['sourceAggregateSha256']==source['aggregateSha256']
destination=root/'docs/99-项目治理/全平台整改交接/evidence/loading-20261104'/('backend-mainfa-'+source['aggregateSha256'][:8]);assert not destination.exists();destination.mkdir(parents=True)
shutil.copytree(old,destination/'original776-current-whole-red-and-preparation',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
shutil.copytree(base,destination/'current-qualified',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
shutil.copytree(old.parent/'main-fa-composition',destination/'fa-source-composition',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
previous=destination/'original6fb-nine-infrastructure-red';previous.mkdir();six=old.parent/'main-6fb-crosswalk-qualified'
for name in ['source-input.json','original-nine-red-seal.json','queue-execution.json','current-pg-execution.json','current-pg.log','golden-current-installed-history-raw.json','golden-current-installed-history-raw.tsv','golden-current-installed-history-receipt.json','fast-seven-source-bridge.json','compiled-patch-receipt.json','core-applicability-bridge.json']:
    shutil.copy2(six/name,previous/name)
shutil.copytree(six/'current-pg-receipt',previous/'whole-receipt')
oldfast=old.parent/'main-6fb-version-identity';red=destination/'original777-fast-quote-red';red.mkdir()
for name in ['source-input.json','current-fast-execution.json','current-fast.log']:shutil.copy2(oldfast/name,red/name)
shutil.copytree(oldfast/'current-fast-receipt',red/'whole-receipt')
original=old.parent/'preflight-version-identity';gold=destination/'original1009-history';gold.mkdir()
for name in ['golden-installed-history-raw.json','golden-installed-history-raw.tsv','golden-installed-history-receipt.json']:shutil.copy2(original/name,gold/name)
consumer=root/'build/loading-validation/flyway-deploy-tests/current1013-final-consumers-result.json';shutil.copy2(consumer,destination/consumer.name)
shutil.copy2(root/'build/loading-validation/upstream-current-composition/backend-reviewed-resolutions.json',destination/'backend-reviewed-resolutions.json')
tree=subprocess.check_output(['git','-C','D:/Projects/uten_imp','ls-tree','-r','-z',source['upstreamMainHead']]);oids={}
for row in tree.split(b'\0'):
    if row:
        detail,name=row.split(b'\t');oids[name.decode('utf-8')]=detail.split()[2].decode()
delta=[]
for e in source['files']:
    p=e['path'];raw=(root/p).read_bytes();assert hashlib.sha256(raw).hexdigest()==e['sha256']
    oid=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
    if oid==oids.get(p):continue
    target=destination/'current-source-delta'/p;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw);delta.append({'path':p,'mainBlobOid':oids.get(p),'sha256':e['sha256'],'bytes':len(raw)})
summary={'atUtc':datetime.now(timezone.utc).isoformat(),'source':source['aggregateSha256'],'mainHead':source['upstreamMainHead'],'sourceDelta':delta,'currentNativeJavaClasses':acceptance['currentNativeJavaClasses'],'currentNativeJavaTests':acceptance['currentNativeJavaTests'],'qualifiedCurrentJavaClasses':acceptance['qualifiedCurrentJavaClasses'],'qualifiedCurrentJavaTests':acceptance['qualifiedCurrentJavaTests'],'qualifiedPythonTests':81,'clockPolicy':'Original current-source10fast126 natural0 and original15PG native1 remain original776 clocks; all actual pass classes are exact source+whole compiled class-byte bridged after one test-only correction, with current-source GiftPhysical whole6 native0. PriorPython81 remains original3c native, qualified by exact non-Markdown input bridge and one unused Java test delta. Original older quote/infra failures and old1009/1010/raw current1013 histories retained. No all-current native25 or summed oldCore65/452 claim.','sourceSqlCount':1013,'head':1074,'returnGate':1073,'all1009MainSqlRawPreserved':True,'mappingVersion':'bootstrap-v22','mainWritten':False,'companyDbWritten':False,'commitPushPackageDeploy':False}
(destination/'stage-summary.json').write_bytes((json.dumps(summary,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
members=sorted(p for p in destination.rglob('*') if p.is_file());manifest=[{'path':p.relative_to(destination).as_posix(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in members]
(destination/'member-manifest.json').write_bytes((json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode('utf-8'));members.append(destination/'member-manifest.json');archive=destination/'backend-mainfa-final-evidence.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in members:z.write(p,p.relative_to(destination).as_posix())
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    for e in manifest:assert hashlib.sha256(z.read(e['path'])).hexdigest()==e['sha256']
receipt={'archivePath':archive.relative_to(root).as_posix(),'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'bytes':archive.stat().st_size,'members':len(members),'everyMemberShaAndZipCrcVerified':True,'sourceAggregateSha256':source['aggregateSha256'],'acceptanceSha256':hashlib.sha256((base/'backend-current-acceptance.json').read_bytes()).hexdigest()}
(destination/'archive-receipt.json').write_bytes((json.dumps(receipt,indent=2)+'\n').encode('utf-8'));(base/'durable-archive-receipt.json').write_bytes((json.dumps(receipt,indent=2)+'\n').encode('utf-8'));print(json.dumps(receipt))
