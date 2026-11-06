import hashlib,json,shutil,subprocess,xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime,timezone
old=Path(__file__).resolve().parent;base=old.parent/'main-fa-gift-qualified';root=base.parents[3]
source=json.loads((base/'source-input.json').read_text(encoding='utf-8'));cas=json.loads((base/'single-test-cas-receipt.json').read_text(encoding='utf-8'))
subprocess.run(['C:/Program Files/LibreOffice/program/python.exe',str(base/'verify-source.py')],check=True)
manifest=json.loads((old/'compiled-class-byte-manifest.json').read_text(encoding='utf-8'));before={e['path']:e['sha256'] for e in manifest}
for p,h in before.items():assert hashlib.sha256((root/p).read_bytes()).hexdigest()==h,p
target=root/'server/target-loading-main-fa-final';simple='GiftPhysicalConservationEndToEndTest';relative='server/target-loading-main-fa-final/test-classes/com/uten/imp/businesschain/'+simple+'.class'
backup=base/'original-compiled-gift.class';assert not backup.exists();backup.write_bytes((root/relative).read_bytes())
xml=old/'current-pg-receipt'/('TEST-com.uten.imp.businesschain.'+simple+'.xml');props={e.attrib['name']:e.attrib['value'] for e in ET.parse(xml).getroot().findall('./properties/property')}
classpath=props['java.class.path'].replace('\\','/');assert 'target-loading-main-fa-final/test-classes' in classpath and 'target-loading-main-fa-final/classes' in classpath
args=['-g','-encoding','UTF-8','--release','21','-parameters','-proc:none','-cp',classpath,'-d',(target/'test-classes').as_posix(),(root/cas['path']).as_posix()]
argfile=base/'javac-gift.args';argfile.write_bytes(('\n'.join('"'+a.replace('"','\\"')+'"' for a in args)+'\n').encode('utf-8'))
compiler=shutil.which('javac');assert compiler and Path(compiler).is_file()
started=datetime.now(timezone.utc).isoformat();version=subprocess.check_output([compiler,'-version'],text=True).strip()
with (base/'javac-gift.log').open('wb') as log:run=subprocess.run([compiler,'@'+str(argfile)],stdout=log,stderr=subprocess.STDOUT,cwd=root/'server')
execution={'startedAtUtc':started,'completedAtUtc':datetime.now(timezone.utc).isoformat(),'actualExitCode':run.returncode,'source':source['aggregateSha256'],'priorFullCompileSource':cas['originalSource'],'command':[compiler,'@'+str(argfile)],'compilerVersion':version,'scope':'Exactly one whole affected test source compiled fresh; same release21, old current native0 full target; no Maven clean or production compilation.'}
(base/'javac-gift-execution.json').write_bytes((json.dumps(execution,indent=2)+'\n').encode('utf-8'));assert run.returncode==0,run.returncode
paths={p.relative_to(root).as_posix() for folder in ['classes','test-classes'] for p in (target/folder).rglob('*.class')};assert paths==set(before)
delta=[];after=[]
for p in sorted(paths):
    digest=hashlib.sha256((root/p).read_bytes()).hexdigest();after.append({'path':p,'sha256':digest})
    if digest!=before[p]:delta.append({'path':p,'beforeSha256':before[p],'afterSha256':digest})
assert [e['path'] for e in delta]==[relative],delta
(base/'compiled-class-byte-manifest.json').write_bytes((json.dumps(after,indent=2)+'\n').encode('utf-8'))
receipt={'source':source['aggregateSha256'],'originalFullCompileSource':cas['originalSource'],'originalFullCompileNativeExitCode':0,'currentSingleTestJavacActualExitCode':0,'allClassFilesChecked':len(paths),'allProductionAndOtherTestsClassBytesExact':True,'onlyClassDelta':delta,'targetReuseDoesNotRelabelOriginalFullCompile':True}
(base/'compiled-patch-receipt.json').write_bytes((json.dumps(receipt,indent=2)+'\n').encode('utf-8'));print(json.dumps(receipt))
