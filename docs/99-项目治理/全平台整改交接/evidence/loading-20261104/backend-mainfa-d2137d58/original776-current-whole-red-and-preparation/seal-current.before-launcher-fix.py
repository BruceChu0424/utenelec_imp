import hashlib,importlib.util,json,subprocess,sys,xml.etree.ElementTree as ET
from datetime import datetime,timezone
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3]
subprocess.run([sys.executable,str(base/'verify-source.py')],check=True)
source=json.loads((base/'complete-source-input.json').read_text(encoding='utf-8'));required=json.loads((base/'required-targets.json').read_text(encoding='utf-8'))
assert required['source']==source['aggregateSha256']
compile=json.loads((base/'compile-execution.json').read_text(encoding='utf-8-sig'));assert compile['state']=='completed' and compile['actualExitCode']==0 and compile['sourceAggregateSha256']==source['aggregateSha256']
groups=[];keys=[]
for label,rule in required['groups'].items():
    folder=base/(label+'-receipt');execution=json.loads((folder/'execution.json').read_text(encoding='utf-8-sig'))
    assert execution['state']=='completed' and execution['selection'].split(',')==rule['classes'] and execution['sourceAggregateSha256']==source['aggregateSha256']
    classes=[];cases=[]
    for path in sorted(folder.glob('TEST-*.xml')):
        suite=ET.parse(path).getroot();assert int(suite.attrib['tests'])>0,path;classes.append(suite.attrib['name'].rsplit('.',1)[-1]);local=[]
        for c in suite.findall('testcase'):
            status='failed' if c.find('failure') is not None else 'error' if c.find('error') is not None else 'skipped' if c.find('skipped') is not None else 'passed'
            local.append({'class':c.attrib['classname'],'case':c.attrib['name'],'status':status})
        assert len(local)==int(suite.attrib['tests'])
        for attr,status in [('failures','failed'),('errors','error'),('skipped','skipped')]:assert int(suite.attrib[attr])==sum(c['status']==status for c in local)
        cases+=local
    assert len(classes)==len(set(classes)) and set(classes)==set(rule['classes']),(label,classes)
    localkeys=[(c['class'],c['case']) for c in cases];assert len(localkeys)==len(set(localkeys));keys+=localkeys
    counts={s:sum(c['status']==s for c in cases) for s in ['passed','failed','error','skipped']}
    receipt={'label':label,'source':source['aggregateSha256'],'actualExitCode':execution['actualExitCode'],'classes':len(classes),'tests':len(cases),'counts':counts,'cases':cases,'green':execution['actualExitCode']==0 and counts['failed']==counts['error']==counts['skipped']==0}
    (folder/'seal.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');groups.append(receipt)
assert len(keys)==len(set(keys))
external=json.loads((base/'external-resources.json').read_text(encoding='utf-8'));assert len(external)==296
for e in external:assert (root/e['sourcePath']).read_bytes()==(root/e['compiledPath']).read_bytes(),e
original=root/'server/src/main/resources/db/migration';compiled=root/'server/target-loading-main-fa-final/classes/db/migration';names={p.name for p in original.glob('V*.sql')}
assert names=={p.name for p in compiled.glob('V*.sql')} and len(names)==1013
for name in names:assert (original/name).read_bytes()==(compiled/name).read_bytes(),name
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module
verifier=load('fa_candidate_verifier',root/'server/legacy_migration/verify_candidate.py');records=verifier.migration_inventory(root);contract=verifier.version_contract(root)
assert len(records)==1013 and sum('.' in r[0] for r in records)==14 and contract.require_integer_flyway_head(r[0] for r in records)==1074
canonical=(verifier.CHECKSUM_HEADER+'\n'+''.join(f'{v}\t{n}\t{c}\n' for v,n,c in records)).encode('utf-8')
official=root/'server/target-loading-main-fa-final/uten-imp-flyway-checksums.tsv';assert official.read_bytes()==canonical
(base/'canonical-source-checksums.tsv').write_bytes(canonical)
tools=load('fa_release_tools',root/'deploy/release/release_tools.py');metadata=tools.migration_metadata(original,official)
(base/'source-metadata-snapshot-1013.json').write_text(json.dumps(metadata,ensure_ascii=False,sort_keys=True,indent=2)+'\n',encoding='utf-8')
python_bridge=json.loads((base/'complete-freeze-correction-and-python-bridge.json').read_text(encoding='utf-8'));assert python_bridge['completeSource']==source['aggregateSha256'] and python_bridge['python81QualifiedOnCompleteSource']
classes=[]
for folder in ['classes','test-classes']:
    for path in sorted((root/'server/target-loading-main-fa-final'/folder).rglob('*.class')):
        classes.append({'path':path.relative_to(root).as_posix(),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
assert classes
(base/'compiled-class-byte-manifest.json').write_text(json.dumps(classes,indent=2)+'\n',encoding='utf-8')
pin=root/'build/loading-validation/upstream-current-composition/backend-reviewed-resolutions.json'
result={'sealedAtUtc':datetime.now(timezone.utc).isoformat(),'sourceAggregateSha256':source['aggregateSha256'],'sourceFilesChecked':len(source['files']),'upstreamMainHead':source['upstreamMainHead'],'sourcePathsetAndBytesDrift':[],'freshCompileActualExitCode':0,'compiledMigrationResourcesExact':1013,'externalCompiledResourcesExact':296,'compiledClassCount':len(classes),'reviewedSemanticManifestSha256':hashlib.sha256(pin.read_bytes()).hexdigest(),'groups':groups,'currentNativeJavaClasses':sum(g['classes'] for g in groups),'currentNativeJavaTests':len(keys),'currentNativePythonTests':0,'qualifiedPythonTests':81,'pythonNativeSource':python_bridge['priorSource'],'canonicalJavaPythonTsvSha256':hashlib.sha256(canonical).hexdigest(),'sqlHead':1074,'returnSchemaGate':1073,'mappingVersion':'bootstrap-v22','originalRawHistoryAndCanonicalIdentitySeparate':True,'original6fbNinePgInfraRedPreserved':True,'originalFastQuoteRedPreserved':True,'green':all(g['green'] for g in groups),'mainWritten':False,'companyDbWritten':False,'sourceCommitPushPackageDeploy':False}
(base/'backend-current-acceptance.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps({k:result[k] for k in ['green','sourceFilesChecked','currentNativeJavaClasses','currentNativeJavaTests','qualifiedPythonTests','compiledClassCount','sqlHead']}));raise SystemExit(0 if result['green'] else 1)
