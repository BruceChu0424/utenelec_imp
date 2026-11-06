from pathlib import Path
import argparse,datetime,hashlib,json,os,re,subprocess,traceback
ROOT=Path('D:/Projects/uten_imp');OUT=ROOT/'build/loading-validation/wpf-goods-summary-20261106'
MSBUILD=Path('D:/Software/Visual Studio Installe/MSBuild/Current/Bin/MSBuild.exe')
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--frame',required=True);args=parser.parse_args();frame=args.frame
 if not re.fullmatch('v[4-9][0-9]?',frame):raise RuntimeError('Explicit fresh final frame required')
 TREE=OUT/('tree-'+frame)
 before=json.loads((OUT/'inputs-before.json').read_bytes());review=json.loads((OUT/(frame+'-review.json')).read_bytes());expected=dict(before);expected.update({x['path']:x['proposedSha256'] for x in review['leaves']})
 runner=OUT/(frame+'-GoodsFinalRunner.cs');runner.write_text('''using System; using System.Linq; using System.Reflection; using Uten.Legacy.Core.Tests; using Uten.Legacy.Desktop.Features.Goods;
internal static class GoodsFinalRunner { [STAThread] static int Main(string[] args) { try {
 if (args.Length != 1) throw new ArgumentException();
 if (args[0] == "models") { CoreContractChecks.Run(); Console.WriteLine("PASS original CoreContractChecks.Run"); int count=GoodsReadContractChecks.Run(); Console.WriteLine("PASS original GoodsReadContractChecks.Run; assertions="+count); }
 else if (args[0] == "ui") { var assembly=Assembly.LoadFrom(System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"Uten.Legacy.Tests.exe")); var type=assembly.GetType("Uten.Legacy.Tests.UiContractChecks",true); var runUi=assembly.GetType("Uten.Legacy.Tests.Program",true).GetMethods(BindingFlags.NonPublic|BindingFlags.Static).Single(method=>method.Name=="RunUi"&&!method.IsGenericMethod); foreach(var name in new[]{"RunContinuousLists","RunSearchReadCoalescing","RunGoodsCurrency"}) { object result=null; Action check=()=>result=type.GetMethod(name,BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,null); runUi.Invoke(null,new object[]{check}); Console.WriteLine("PASS original "+name+"; assertions="+result); } }
 else throw new ArgumentException(); Console.WriteLine("PASS final goods frame; process="+(Environment.Is64BitProcess?"x64":"x86")); return 0;
 } catch(Exception error) { while(error is TargetInvocationException && error.InnerException!=null) error=error.InnerException; Console.Error.WriteLine("FAIL "+error.GetType().Name+": "+error.Message); Console.Error.WriteLine(error.StackTrace); return 1; } } }
''','utf-8')
 runs=[];receipt={'startedAtUtc':now(),'privateInputMap':expected,'runnerSha256':sha(runner),'actualRuns':runs,'scope':'Final exact '+frame+' original Core/Goods methods and original Program.RunUi-context native Goods/Unit continuous, search coalescing, identity and currency UI methods; goods10001 rows/101 bounded batches + retry owned wait/cancel. Not a rerun of unrelated Updater or a Win7 target/production acceptance.','MainWritten':False}
 def stable():
  bad=[n for n,h in expected.items() if sha(TREE/n)!=h]
  if bad:raise RuntimeError('Private source/resource drift: '+str(bad))
 try:
  for arch in ('x86','x64'):
   dest=OUT/'bin'/frame/arch;dest.mkdir(parents=True,exist_ok=False)
   commands=[('build-'+arch,[str(MSBUILD),str(TREE/'clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj'),'/nologo','/m:1','/verbosity:minimal','/t:Rebuild','/warnaserror','/p:Configuration=Debug','/p:Platform='+arch,'/p:PlatformTarget='+arch,'/p:UtenBuildScope=goods-summary-final-v3','/p:OutDir='+str(dest)+os.sep]),('runner-compile-'+arch,[str(MSBUILD.parent/'Roslyn/csc.exe'),'/nologo','/warnaserror','/target:exe','/platform:'+arch,'/out:'+str(dest/'GoodsFinalRunner.exe'),'/reference:'+str(dest/'Uten.Legacy.Core.dll'),'/reference:'+str(dest/'Uten.Legacy.Desktop.exe'),str(runner)]),('core-goods-'+arch,[str(dest/'GoodsFinalRunner.exe'),'models']),('native-ui-'+arch,[str(dest/'GoodsFinalRunner.exe'),'ui'])]
   for name,command in commands:
    name=frame+'-'+name;stable();log=OUT/(name+'.log');start=now()
    with log.open('wb') as stream:run=subprocess.run(command,cwd=TREE,stdout=stream,stderr=subprocess.STDOUT,env=dict(os.environ,GIT_OPTIONAL_LOCKS='0'))
    runs.append({'name':name,'command':command,'startedAtUtc':start,'completedAtUtc':now(),'actualExitCode':run.returncode,'logSha256':sha(log)})
    stable()
    if run.returncode:raise RuntimeError('Actual RED: '+name)
  receipt['actualExitCode']=0
 except Exception as error:
  receipt['actualExitCode']=1;receipt['error']=str(error);(OUT/(frame+'-failure.log')).write_text(traceback.format_exc(),'utf-8')
 finally:
  receipt['completedAtUtc']=now();receiptPath=OUT/(frame+'-validation.json');receiptPath.write_text(json.dumps(receipt,indent=2)+'\n','utf-8');print(json.dumps({'receipt':str(receiptPath),'sha256':sha(receiptPath),'actualExitCode':receipt['actualExitCode']}))
 return receipt['actualExitCode']
if __name__=='__main__':raise SystemExit(main())
