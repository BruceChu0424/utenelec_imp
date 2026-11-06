import concurrent.futures,hashlib,json,shutil,sys,xml.etree.ElementTree as ET
from datetime import datetime,timezone
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3]
sys.path.insert(0,str(base.parent/'main-f6e-metadata'));from backend_inventory import source_paths
source=json.loads((base/'source-input.json').read_text(encoding='utf-8'));required=json.loads((base/'required-targets.json').read_text(encoding='utf-8'))
expected={e['path']:e['sha256'] for e in source['files']};assert len(expected)==len(source['files'])
semantic_path=root/'build/loading-validation/upstream-current-composition/backend-reviewed-resolutions.json';semantic_raw=semantic_path.read_bytes();semantic_sha=hashlib.sha256(semantic_raw).hexdigest();assert semantic_sha=='c097008aaf5d0ce78bbd05592e202f00c42cddd69216ca3ef665bb5e192cd6ac'
semantic=json.loads(semantic_raw);assert semantic['mainHead']==source['upstreamMainHead'] and len(semantic['entries'])==4
for e in semantic['entries']:assert e['reviewedMainHead']==source['upstreamMainHead'] and hashlib.sha256((root/e['path']).read_bytes()).hexdigest()==e['resolvedCandidateSha256']
assert hashlib.sha256(''.join(p+'\0'+expected[p]+'\n' for p in sorted(expected)).encode()).hexdigest()==source['aggregateSha256']==required['source']
assert source_paths(root)==set(expected),'Current complete pathset changed'
def check(p):return p if hashlib.sha256((root/p).read_bytes()).hexdigest()!=expected[p] else None
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:drift=[p for p in pool.map(check,sorted(expected)) if p]
assert not drift,drift
compile=json.loads((base/'compile-execution.json').read_text(encoding='utf-8-sig'));assert compile['state']=='completed' and compile['actualExitCode']==0 and compile['sourceAggregateSha256']==source['aggregateSha256']
external=json.loads((base/'external-resources.json').read_text(encoding='utf-8'))
for e in external:assert (root/e['sourcePath']).read_bytes()==(root/e['compiledPath']).read_bytes(),e
sql_source=root/'server/src/main/resources/db/migration';sql_compiled=root/'server/target-loading-main-3068-output-fixed/classes/db/migration'
source_names={p.name for p in sql_source.glob('V*.sql')};compiled_names={p.name for p in sql_compiled.glob('V*.sql')};assert source_names==compiled_names and len(source_names)==1009
def migration_check(name):
    original=(sql_source/name).read_bytes();assert original==(sql_compiled/name).read_bytes(),name
    return {'name':name,'sha256':hashlib.sha256(original).hexdigest()}
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:compiled_migrations=list(pool.map(migration_check,sorted(source_names)))
(base/'compiled-migration-resources.json').write_text(json.dumps(compiled_migrations,indent=2)+'\n',encoding='utf-8')
groups=[];allkeys=[]
for label,rule in required['groups'].items():
    directory=base/(label+'-receipt');execution=json.loads((directory/'execution.json').read_text(encoding='utf-8-sig'))
    assert execution['state']=='completed' and execution['sourceAggregateSha256']==source['aggregateSha256'] and execution['selection'].split(',')==rule['classes']
    classes=[];cases=[]
    for p in sorted(directory.glob('TEST-*.xml')):
        xml=ET.parse(p).getroot();assert int(xml.attrib['tests'])>0,p
        classes.append(xml.attrib['name'].rsplit('.',1)[-1]);local=[]
        for c in xml.findall('testcase'):
            status='failed' if c.find('failure') is not None else 'error' if c.find('error') is not None else 'skipped' if c.find('skipped') is not None else 'passed'
            local.append({'class':c.attrib['classname'],'case':c.attrib['name'],'status':status})
        assert len(local)==int(xml.attrib['tests'])
        for name,status in [('failures','failed'),('errors','error'),('skipped','skipped')]:assert int(xml.attrib[name])==sum(c['status']==status for c in local)
        cases+=local
    assert len(classes)==len(set(classes)) and set(classes)==set(rule['classes']),(label,classes)
    keys=[(c['class'],c['case']) for c in cases];assert len(keys)==len(set(keys));allkeys+=keys
    counts={s:sum(c['status']==s for c in cases) for s in ('passed','failed','error','skipped')}
    group={'label':label,'actualExitCode':execution['actualExitCode'],'classes':len(classes),'tests':len(cases),'counts':counts,'cases':cases,'green':execution['actualExitCode']==0 and counts['failed']==counts['error']==counts['skipped']==0}
    (directory/'seal.json').write_text(json.dumps(group,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');groups.append(group)
assert len(allkeys)==len(set(allkeys))
legacy=json.loads((base/'legacy-execution.json').read_text(encoding='utf-8'));assert legacy['actualExitCode']==0 and legacy['errors']==legacy['failed']==legacy['skipped']==0
pg_execution=json.loads((base/'final-pg-execution.json').read_text(encoding='utf-8-sig'))
started=datetime.fromisoformat(pg_execution['startedAtUtc'].replace('Z','+00:00')).timestamp();completed=datetime.fromisoformat(pg_execution['completedAtUtc'].replace('Z','+00:00')).timestamp()
sample_path=base/'current-source-claims-sample/current-task-service-comparison.json'
sample_observation=json.loads((base/'current-source-claims-sample/provenance.json').read_text(encoding='utf-8'))
assert sample_observation['sourceAggregateSha256']==source['aggregateSha256'] and sample_observation['qualifiedClassTests']==10 and sample_observation['qualifiedClassFailedErrorsSkipped']==0
assert sample_observation['sampleSha256']==hashlib.sha256(sample_path.read_bytes()).hexdigest()
assert started<=sample_path.stat().st_mtime<=datetime.fromisoformat(sample_observation['capturedAtUtc']).timestamp()<=completed
assert len([c for g in groups for c in g['cases'] if c['class'].endswith('.DailyReportDraftClaimsPostgresTest') and c['case']=='aRealDraftOnPageElevenIsNotTruncatedOrExpandedIntoDetails' and c['status']=='passed'])==1
sample=json.loads(sample_path.read_text(encoding='utf-8'));assert sample['activeDraftHeaders']==1001 and sample['acceptedTaskSegments']==1 and sample['globalHeaderBatches']==11 and sample['selectedHeaderBatches']==1 and sample['sameRealDraftClaimRetained'] is True
shutil.copy2(sample_path,base/'final-pg-receipt'/sample_path.name)
shutil.copy2(base/'current-source-claims-sample/provenance.json',base/'final-pg-receipt/current-claims-initial-observation.json')
growth=[]
for scenario in ('warehouse-metadata','workbench-page-detail'):
    for history in (10000,100000,1000000):
        p=base/'final-pg-growth'/f'{scenario}-history-{history}.json';assert started<=p.stat().st_mtime<=completed
        d=json.loads(p.read_text(encoding='utf-8'));assert d['scenario']==scenario and d['historicalRows']==history and d['fixedActiveRows']==50
        assert d['before']['samples']==d['after']['samples']==3
        growth.append({'path':str(p.relative_to(root)).replace('\\','/'),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'scenario':scenario,'history':history,'fixedActive':50,'before':d['before'],'after':d['after']})
log=(base/'final-pg.log').read_text(encoding='utf-8',errors='replace');assert 'Successfully applied 1009 migrations to schema "public", now at version v1070' in log
empty_path=base/'final-pg-empty-latency.json';assert started<=empty_path.stat().st_mtime<=completed
empty=json.loads(empty_path.read_text(encoding='utf-8'));assert empty['schemaVersion']=='1070' and empty['legacySqlPerRequest']==6 and empty['optimizedSqlPerRequest']==1 and len(empty['legacySamplesMs'])==len(empty['optimizedSamplesMs'])==9
performance={'source':source['aggregateSha256'],'actualRun':'final-pg','actualNativeExitCode':pg_execution['actualExitCode'],'currentClaimsSample':sample,'currentClaimsSampleSha256':hashlib.sha256(sample_path.read_bytes()).hexdigest(),'currentClaimsInitialObservation':sample_observation,'currentClaimsCompletedClassTests':10,'emptyWorkbench':empty,'emptyWorkbenchSha256':hashlib.sha256(empty_path.read_bytes()).hexdigest(),'growth':growth,'limits':'Disposable structural SQL/service fixtures only. Exact broad metadata remains dependent on history N. Claims timing excludes HTTP/JWT/native-publication/client rows/actions-ready. Actual HTTP identity/revocation tests are separately in this same current native-run ledger. Initial observation honestly remains then-running state; this completed whole native receipt independently binds same-source green10. No production SLA or addition to old sample times.'}
(base/'current-performance-evidence.json').write_text(json.dumps(performance,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
result={'sealedAtUtc':datetime.now(timezone.utc).isoformat(),'sourceAggregateSha256':source['aggregateSha256'],'upstreamMainHead':source['upstreamMainHead'],'sourceFilesChecked':len(expected),'sourceDrift':[],'reviewedSemanticManifestSha256':semantic_sha,'reviewedSemanticCandidatePathsExact':4,'externalCompiledResourcesExact':len(external),'compiledMigrationResourcesExact':len(compiled_migrations),'freshCompileActualExitCode':compile['actualExitCode'],'groups':groups,'javaUniqueClasses':sum(g['classes'] for g in groups),'javaUniqueTests':len(allkeys),'legacyCurrent':legacy,'green':all(g['green'] for g in groups),'historicalCountsAdded':False,'companyDbWritten':False,'mainWritten':False}
(base/'backend-current-acceptance.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:result[k] for k in ('green','javaUniqueClasses','javaUniqueTests','sourceFilesChecked','externalCompiledResourcesExact')}));sys.exit(0 if result['green'] else 1)
