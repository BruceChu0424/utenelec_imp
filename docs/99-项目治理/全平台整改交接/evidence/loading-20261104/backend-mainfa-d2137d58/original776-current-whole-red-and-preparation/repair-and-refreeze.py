import copy,hashlib,json,os
from pathlib import Path
from datetime import datetime,timezone
base=Path(__file__).resolve().parent;root=base.parents[3];repair=base/'gift-physical-weight-repair'
queue=json.loads((base/'queue-execution.json').read_text(encoding='utf-8-sig'));assert queue['state']=='completed' and queue['actualExitCode']==1 and queue['pgExitCode']==1
acceptance=json.loads((base/'backend-current-acceptance.json').read_text(encoding='utf-8'));assert not acceptance['green']
source=json.loads((base/'complete-source-input.json').read_text(encoding='utf-8'));expected={e['path']:e['sha256'] for e in source['files']}
assert not [p for p,h in expected.items() if hashlib.sha256((root/p).read_bytes()).hexdigest()!=h]
review=json.loads((repair/'review.json').read_text(encoding='utf-8'));approval=json.loads((repair/'root-review.json').read_text(encoding='utf-8'))
assert approval['diffSha256']==review['diffSha256']==hashlib.sha256((repair/'review.diff').read_bytes()).hexdigest()
assert approval['beforeSha256']==review['beforeSha256'] and approval['stagedSha256']==review['stagedSha256']
for p,h in review['supportingSourceSha256'].items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==h
path=root/review['path'];before=path.read_bytes();after=(repair/'staged.raw').read_bytes();assert hashlib.sha256(before).hexdigest()==review['beforeSha256'] and hashlib.sha256(after).hexdigest()==review['stagedSha256']
destination=base.parent/'main-fa-gift-qualified';assert not destination.exists();destination.mkdir()
path.write_bytes(after);assert path.read_bytes()==after
now=copy.deepcopy(source);now['capturedAtUtc']=datetime.now(timezone.utc).isoformat()
for e in now['files']:
    if e['path']==review['path']:e['sha256']=review['stagedSha256']
now['aggregateSha256']=hashlib.sha256(''.join(e['path']+'\0'+e['sha256']+'\n' for e in sorted(now['files'],key=lambda e:e['path'])).encode()).hexdigest()
now['predecessorSourceAggregateSha256']=source['aggregateSha256'];now['correction']='Exactly one test updated to Main frozen-source weight inheritance; all production,SQL,Python,resources/contracts and other tests raw-byte identical.'
(destination/'source-input.json').write_bytes((json.dumps(now,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
receipt={'atUtc':datetime.now(timezone.utc).isoformat(),'path':review['path'],'beforeSha256':review['beforeSha256'],'afterSha256':review['stagedSha256'],'reviewDiffSha256':review['diffSha256'],'originalSource':source['aggregateSha256'],'currentSource':now['aggregateSha256'],'original15PgActualExitCode':queue['pgExitCode'],'originalAcceptanceSha256':hashlib.sha256((base/'backend-current-acceptance.json').read_bytes()).hexdigest(),'onlyOneTestChanged':True,'productionSqlPythonContractResourceChanges':0,'mainWritten':False,'nativeCurrentPassClaimed':False}
(destination/'single-test-cas-receipt.json').write_bytes((json.dumps(receipt,indent=2)+'\n').encode('utf-8'));print(json.dumps(receipt))
