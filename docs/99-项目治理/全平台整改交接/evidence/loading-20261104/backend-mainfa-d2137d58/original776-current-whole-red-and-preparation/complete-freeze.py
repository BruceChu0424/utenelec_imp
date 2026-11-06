import hashlib,json,sys,copy,subprocess
from pathlib import Path
from datetime import datetime,timezone
base=Path(__file__).resolve().parent;root=base.parents[3]
sys.path.insert(0,str(base.parent/'main-f6e-metadata'));from backend_inventory import source_paths
oldpath=base/'source-input.json';old=json.loads(oldpath.read_text(encoding='utf-8'));prior={e['path']:e['sha256'] for e in old['files']}
actual=source_paths(root)|set(old['additionalSourceDependencies']);added=sorted(actual-set(prior));removed=sorted(set(prior)-actual)
assert len(added)==1 and added[0]=='docs/03-页面/各部门申请流程.md' and not removed
changed=[p for p,h in prior.items() if hashlib.sha256((root/p).read_bytes()).hexdigest()!=h]
assert len(changed)==3 and all(p.startswith('docs/') and p.endswith('.md') for p in changed)
changed_rows=[]
for p in changed:
    raw=(root/p).read_bytes();main=subprocess.check_output(['git','-C','D:/Projects/uten_imp','show',old['upstreamMainHead']+':'+p]);assert raw==main
    changed_rows.append({'path':p,'priorSha256':prior[p],'currentAndExactMainSha256':hashlib.sha256(raw).hexdigest()})
now=copy.deepcopy(old);now['capturedAtUtc']=datetime.now(timezone.utc).isoformat();now['files']=[{'path':p,'sha256':hashlib.sha256((root/p).read_bytes()).hexdigest()} for p in sorted(actual)]
now['aggregateSha256']=hashlib.sha256(''.join(e['path']+'\0'+e['sha256']+'\n' for e in now['files']).encode()).hexdigest()
now['predecessorSourceAggregateSha256']=old['aggregateSha256'];now['predecessorManifestSha256']=hashlib.sha256(oldpath.read_bytes()).hexdigest();now['correction']='Add already-listed omitted Maven external Markdown resource; bind3 generic-adopted exact-Main Markdown resources. All Java,SQL,Python,contracts bytes unchanged.'
destination=base/'complete-source-input.json';assert not destination.exists();destination.write_text(json.dumps(now,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
py=json.loads((base/'python-execution.json').read_text(encoding='utf-8'));assert py['actualExitCode']==0 and py['sourceAggregateSha256']==old['aggregateSha256'] and py['tests']==81
bridge={'atUtc':datetime.now(timezone.utc).isoformat(),'priorManifestPreserved':True,'priorSource':old['aggregateSha256'],'completeSource':now['aggregateSha256'],'added':now['files'][[e['path'] for e in now['files']].index(added[0])],'changedMainKnowledgeMarkdown':changed_rows,'allOther7407InputsByteExact':True,'productionJavaChanges':0,'testJavaChanges':0,'python81NativeSource':old['aggregateSha256'],'python81QualifiedOnCompleteSource':True,'pythonBasis':'Only four Maven knowledge Markdown resources added/rebound; all six Python modules, their source/CLI/import/version fixtures/Guard and every non-Markdown input are raw-byte identical. Python verification operates on migration/code/contracts, not Maven knowledge Markdown. Original invocation remains old native clock.','pythonExecutionSha256':hashlib.sha256((base/'python-execution.json').read_bytes()).hexdigest(),'completeInputPaths':len(actual)}
(base/'complete-freeze-correction-and-python-bridge.json').write_text(json.dumps(bridge,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps(bridge,ensure_ascii=True))
