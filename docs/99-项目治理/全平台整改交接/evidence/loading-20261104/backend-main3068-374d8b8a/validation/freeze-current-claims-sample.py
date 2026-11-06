import hashlib,json,shutil,xml.etree.ElementTree as ET
from datetime import datetime,timezone
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3]
source=json.loads((base/'source-input.json').read_text(encoding='utf-8'));execution=json.loads((base/'final-pg-execution.json').read_text(encoding='utf-8-sig'))
assert execution['state']=='running' and execution['sourceAggregateSha256']==source['aggregateSha256']
xml=root/'server/target-loading-main-3068-output-fixed/surefire-reports/TEST-com.uten.imp.businesschain.DailyReportDraftClaimsPostgresTest.xml';suite=ET.parse(xml).getroot()
assert int(suite.attrib['tests'])==10 and all(int(suite.attrib[k])==0 for k in ('errors','failures','skipped'))
case=[c for c in suite.findall('testcase') if c.attrib['name']=='aRealDraftOnPageElevenIsNotTruncatedOrExpandedIntoDetails'];assert len(case)==1 and all(case[0].find(k) is None for k in ('failure','error','skipped'))
producer=root/'server/build/loading-validation/daily-report-draft-claims/current-task-service-comparison.json';sample=json.loads(producer.read_text(encoding='utf-8'));now=datetime.now(timezone.utc);started=datetime.fromisoformat(execution['startedAtUtc'].replace('Z','+00:00')).timestamp()
assert started<=producer.stat().st_mtime<=now.timestamp() and sample['activeDraftHeaders']==1001 and sample['acceptedTaskSegments']==1 and sample['globalHeaderBatches']==11 and sample['selectedHeaderBatches']==1 and sample['sameRealDraftClaimRetained'] is True
destination=base/'current-source-claims-sample';assert not destination.exists();destination.mkdir();shutil.copy2(producer,destination/producer.name);shutil.copy2(xml,destination/xml.name)
receipt={'capturedAtUtc':now.isoformat(),'sourceAggregateSha256':source['aggregateSha256'],'sampleProducerModifiedAtUtc':datetime.fromtimestamp(producer.stat().st_mtime,timezone.utc).isoformat(),'producerPath':str(producer.relative_to(root)).replace('\\','/'),'sampleSha256':hashlib.sha256(producer.read_bytes()).hexdigest(),'qualifiedClassTests':10,'qualifiedClassFailedErrorsSkipped':0,'originalObservedWholeRunState':execution['state'],'originalObservedWholeRunNativeExit':execution['actualExitCode'],'scope':'Same current source real public service fixture. Observation occurred while PG22 whole run was still active; its completed native receipt is required independently. Not HTTP/client/SLA; no substitution of earlier sample times.'}
(destination/'provenance.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps(receipt))
