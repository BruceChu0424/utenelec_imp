import hashlib,json
from pathlib import Path
from datetime import datetime,timezone
base=Path(__file__).resolve().parent;root=base.parents[3]
current=json.loads((base/'complete-source-input.json').read_text(encoding='utf-8'));prior=json.loads((base.parent/'main-3068-output-fixed/source-input.json').read_text(encoding='utf-8'));six=json.loads((base.parent/'main-6fb-crosswalk-qualified/source-input.json').read_text(encoding='utf-8'));older=json.loads((base.parent/'main-6fb-crosswalk-qualified/core-applicability-bridge.json').read_text(encoding='utf-8'))
cur={e['path']:e['sha256'] for e in current['files']};old={e['path']:e['sha256'] for e in prior['files']};prev={e['path']:e['sha256'] for e in six['files']}
prod=[p for p in cur if p.startswith('server/src/main/java/')];changed=[{'path':p,'priorCoreSha256':old.get(p),'previous6fbSha256':prev.get(p),'currentSha256':cur[p]} for p in prod if old.get(p)!=cur[p]]
exact=[]
for e in older['exactReadProducerBridge']:
    assert cur[e['path']]==e['sameRawSha256'],e
    exact.append(e)
required=json.loads((base/'required-targets.json').read_text(encoding='utf-8'));native={name for group in required['groups'].values() for name in group['classes']}
cases=[]
for e in older['coreClassLedger']:
    p=e['path'];assert p in cur
    cases.append({'class':e['class'],'path':p,'priorCoreSha256':e['priorSha256'],'previous6fbSha256':e['currentSha256'],'currentSha256':cur[p],'testByteEqualPriorCore':cur[p]==e['priorSha256'],'testByteEqualPrevious6fb':cur[p]==e['currentSha256'],'currentWholeNativeSelected':e['class'] in native,'oldResultRelabelled':False,'priorApplicabilityNoteRetained':e['applicability']})
prior_sql={p:h for p,h in old.items() if p.startswith('server/src/main/resources/db/migration/') and p.endswith('.sql')};current_sql={p:h for p,h in cur.items() if p.startswith('server/src/main/resources/db/migration/') and p.endswith('.sql')}
matches=[];not_body_equal=[]
for p,h in prior_sql.items():
    found=[q for q,s in current_sql.items() if s==h]
    if found:matches.append({'priorPath':p,'currentPath':found[0],'sameRawBodySha256':h})
    else:not_body_equal.append({'priorPath':p,'priorSha256':h})
result={'atUtc':datetime.now(timezone.utc).isoformat(),'priorCoreSource':prior['aggregateSha256'],'previous6fbSource':six['aggregateSha256'],'currentSource':current['aggregateSha256'],'productionJavaTotal':len(prod),'productionJavaByteEqualPriorCore':len(prod)-len(changed),'changedProductionPaths':changed,'exactReadProducerBridge':exact,'coreClassLedger':cases,'priorMigrationBodyMatches':matches,'priorMigrationBodiesNotCurrentByteEqual':not_body_equal,'currentWholeNativeSelection':sorted(native),'sourceClockPolicy':'Prior core65/452 and 6fb ninePG33pass+1infraerror remain their actual clocks. Exact-source read producers and test sources are traceable here; do not add them arithmetically to current native totals or infer full-context runtime equivalence from one file. Current complete compile/whole selected PG validate newly composed source/SQL/weight/lineage/lifecycle/readonly/concurrency boundaries.','mainWritten':False,'companyDbWritten':False}
(base/'prior-current-applicability-bridge.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'productionJava':len(prod),'rawEqualPriorCore':len(prod)-len(changed),'changedProduction':len(changed),'exactReadProducers':len(exact),'coreClasses':len(cases),'priorSqlRawBodyMatched':len(matches),'priorSqlNotRawMatched':not_body_equal},ensure_ascii=True))
