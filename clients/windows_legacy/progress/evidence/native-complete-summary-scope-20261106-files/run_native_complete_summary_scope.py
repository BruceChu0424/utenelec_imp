from pathlib import Path
import datetime, hashlib, json, os, shutil, subprocess, traceback

ROOT=Path('D:/Projects/uten_imp')
OUT=ROOT/'build/loading-validation/native-complete-summary-scope-20261106'
TREE=OUT/'tree'
MSBUILD=Path('D:/Software/Visual Studio Installe/MSBuild/Current/Bin/MSBuild.exe')
CSC=MSBUILD.parent/'Roslyn/csc.exe'
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 review=json.loads((OUT/'review.json').read_bytes());runs=[]
 expected=dict(review['privateInputMap']);expected.update({x['path']:x['proposedSha256'] for x in review['changes']});expected[review['fixturePath']]=review['fixtureSha256']
 def stable():
  bad=[n for n,h in expected.items() if sha(TREE/n)!=h]
  if bad:raise RuntimeError('Private input drift: '+str(bad))
 stable()
 dependency='build/windows-wpf/dependencies/BouncyCastle.Cryptography.2.7.0/lib/net461/BouncyCastle.Cryptography.dll'
 dep=TREE/dependency;dep.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/dependency,dep)
 runner=OUT/'CoreScopeRunner.cs';runner.write_text('using System; using Uten.Legacy.Core.Tests; internal static class CoreScopeRunner { static int Main() { try { CoreContractChecks.Run(); Console.WriteLine("PASS original CoreContractChecks.Run including complete summary fixture; process=" + (Environment.Is64BitProcess ? "x64" : "x86")); return 0; } catch (Exception error) { Console.Error.WriteLine(error.ToString()); return 1; } } }\n','utf-8')
 receipt={'startedAtUtc':now(),'scope':'Debug net48 original CoreContractChecks.Run; proposal-only; no Desktop build/business UI/company database/packaging','privateInputs':expected,'dependencySha256':sha(dep),'runnerSha256':sha(runner),'runs':runs,'MainWritten':False,'runtimeBusinessAcceptanceInferred':False}
 try:
  for arch in ('x86','x64'):
   binary=OUT/'bin'/arch;binary.mkdir(parents=True,exist_ok=False)
   commands=[('build-'+arch,[str(MSBUILD),str(TREE/'clients/windows_legacy/Uten.Legacy.Core/Uten.Legacy.Core.csproj'),'/nologo','/m:1','/verbosity:minimal','/t:Rebuild','/warnaserror','/p:Configuration=Debug','/p:Platform='+arch,'/p:PlatformTarget='+arch,'/p:UtenBuildScope=summary-scope-final','/p:OutputPath='+str(binary)+os.sep]),('runner-compile-'+arch,[str(CSC),'/nologo','/warnaserror','/target:exe','/platform:'+arch,'/out:'+str(binary/'CoreScopeRunner.exe'),'/reference:'+str(binary/'Uten.Legacy.Core.dll'),str(runner)]),('corechecks-'+arch,[str(binary/'CoreScopeRunner.exe')])]
   for name,command in commands:
    stable();log=OUT/(name+'.log');start=now()
    with log.open('wb') as stream:run=subprocess.run(command,cwd=TREE,stdout=stream,stderr=subprocess.STDOUT,env=dict(os.environ,GIT_OPTIONAL_LOCKS='0'))
    runs.append({'name':name,'command':command,'startedAtUtc':start,'completedAtUtc':now(),'actualExitCode':run.returncode,'logSha256':sha(log)})
    stable()
    if run.returncode:raise RuntimeError('Actual RED: '+name)
   receipt.setdefault('binarySha256',{})[arch]=sha(binary/'Uten.Legacy.Core.dll')
  receipt['actualExitCode']=0
 except Exception as error:
  receipt['actualExitCode']=1;receipt['error']=str(error);(OUT/'validation-failure.log').write_text(traceback.format_exc(),'utf-8')
 finally:
  receipt['completedAtUtc']=now();(OUT/'validation.json').write_text(json.dumps(receipt,indent=2)+'\n','utf-8');print(json.dumps({'receipt':str(OUT/'validation.json'),'receiptSha256':sha(OUT/'validation.json'),'actualExitCode':receipt['actualExitCode']}))
 return receipt['actualExitCode']
if __name__=='__main__':raise SystemExit(main())
