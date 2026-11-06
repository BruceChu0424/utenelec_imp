import hashlib,json
from pathlib import Path
base=Path(__file__).resolve().parent;old=base.parent/'main-f6e-metadata'
a=json.loads((old/'source-input.json').read_text(encoding='utf-8'));b=json.loads((old/'complete-input-inventory.json').read_text(encoding='utf-8'));c=json.loads((base/'source-input.json').read_text(encoding='utf-8'))
previous={e['path']:e['sha256'] for e in a['files']+b['supplementalFiles']};current={e['path']:e['sha256'] for e in c['files']}
delta=[{'path':p,'oldSha256':previous.get(p),'currentSha256':current.get(p),'status':'added' if p not in previous else 'removed' if p not in current else 'changed'} for p in sorted(set(previous)|set(current)) if previous.get(p)!=current.get(p)]
names=['FulfillmentWorkbenchPageRead.java','ProductionDailyReportService.java','NativeTaskReadScopeInterceptor.java','InteractiveTaskReadScope.java','ProductionExecutionWorkbenchService.java','WarehouseInboundTaskCenterSql.java','WarehouseOutboundTaskCenterSql.java','DailyReportDraftClaimsPostgresTest.java','FulfillmentWorkbenchPageReadPostgresTest.java','InteractiveTaskReadScopePostgresTest.java']
producers=[]
for name in names:
    matches=[p for p in current if p.endswith('/'+name)];assert len(matches)==1,(name,matches)
    p=matches[0];assert previous.get(p)==current[p],p
    producers.append({'path':p,'priorAndCurrentSha256':current[p],'exactByteEquivalent':True})
oldTests=json.loads((old/'required-targets.json').read_text(encoding='utf-8'));teststatus=[]
for group in oldTests['groups'].values():
    for name in group['classes']:
        matches=[p for p in current if p.endswith('/'+name+'.java')];assert len(matches)==1
        p=matches[0];teststatus.append({'class':name,'path':p,'sourceByteEquivalent':previous.get(p)==current[p],'oldSha256':previous.get(p),'currentSha256':current[p]})
result={'oldSource':a['aggregateSha256'],'oldCompleteSource':b['completeInputInventoryAggregateSha256'],'currentSource':c['aggregateSha256'],'currentMain':c['upstreamMainHead'],'producerBridge':producers,'prior47ClassSourceInventory':teststatus,'delta':delta,'changed':sum(e['status']=='changed' for e in delta),'added':sum(e['status']=='added' for e in delta),'removed':sum(e['status']=='removed' for e in delta),'limits':'Producer byte equivalence proves the reviewed optimization implementation is retained. Shared latest migrations/services/exports and input pathsets changed; this is not a whole runtime closure or current green rerun. Final-fast/final-pg provide current native evidence; old47/289 or old53/377 are never added. Current metadata6growth and draft HTTP/service samples rerun independently.'}
(base/'source-equivalence-bridge.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps({k:result[k] for k in ('changed','added','removed')}))
