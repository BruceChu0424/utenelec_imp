"""Build and execute the exact latest composed native read/output scopes locally."""
from pathlib import Path
import datetime, hashlib, json, re, subprocess

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'build/loading-validation/wpf-3068-current';OUT.mkdir(parents=True,exist_ok=True)
MSBUILD=Path('D:/Software/Visual Studio Installe/MSBuild/Current/Bin/MSBuild.exe')
SUFFIXES={'.cs','.csproj','.props','.targets','.xaml','.resx','.config','.manifest'}
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def inputs():
    names={p for p in (ROOT/'clients/windows_legacy').rglob('*') if p.is_file() and p.suffix.lower() in SUFFIXES
           and not any(part in {'bin','obj','build'} for part in p.relative_to(ROOT/'clients/windows_legacy').parts)}
    for project in (ROOT/'clients/windows_legacy').rglob('*.csproj'):
        for include in re.findall(r'<(?:EmbeddedResource|Resource)\b[^>]*\bInclude="([^"]+)"',project.read_text('utf-8-sig')):
            path=(project.parent/include).resolve()
            if not path.is_relative_to(ROOT) or not path.is_file():raise RuntimeError('Missing or escaped project resource: '+str(path))
            names.add(path)
    names.update([ROOT/'pubspec.yaml',ROOT/'windows/runner/resources/app_icon.ico',
                  ROOT/'build/windows-wpf/dependencies/BouncyCastle.Cryptography.2.7.0/lib/net461/BouncyCastle.Cryptography.dll'])
    return {p.relative_to(ROOT).as_posix():digest(p) for p in sorted(names)}
before=inputs();started=datetime.datetime.now(datetime.timezone.utc).isoformat()
(OUT/'source-input.json').write_text(json.dumps({'atUtc':started,'inputs':before},ensure_ascii=False,indent=2)+'\n','utf-8')
phases=[]
def run(name,command):
    phase={'name':name,'startedAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'command':command}
    with (OUT/(name+'.log')).open('w',encoding='utf-8') as log:
        result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    phase.update(exitCode=result.returncode,endedAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),logSha256=digest(OUT/(name+'.log')))
    phases.append(phase);(OUT/(name+'-exit.json')).write_text(json.dumps(phase,ensure_ascii=False,indent=2)+'\n','utf-8')
    if result.returncode:raise RuntimeError('Actual native phase failed: '+name)
    if inputs()!=before:raise RuntimeError('Native source/resource drift during '+name)
for architecture in ['x64','x86']:
    output=OUT/architecture;output.mkdir(exist_ok=True)
    run('build-'+architecture,[str(MSBUILD),'clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj',
        '/nologo','/m:1','/verbosity:minimal','/t:Build','/warnaserror',
        '/p:Configuration=Debug','/p:Platform='+architecture,'/p:UtenBuildScope=loading3068-final',
        '/p:OutDir='+str(output)+'\\'])
    for scope in ['unit-history-contracts','continuous-list-contracts','search-input-contracts','table-output-contracts']:
        run(scope+'-'+architecture,[str(output/'Uten.Legacy.Tests.exe'),'--'+scope])
after=inputs();assert after==before
receipt={'startedAtUtc':started,'endedAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
         'sourceInputs':len(before),'sourceDrift':[],'phases':phases,'buildWarningAsError':True,
         'architectures':['x64','x86'],'actualLocalNativeScopes':['history','continuous lists','search','table output selection/capabilities'],
         'fullErpAcceptance':False,'win7TargetPcAcceptance':False,'formalPackageOrDeployment':False,'mainWritten':False}
(OUT/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n','utf-8')
print(json.dumps({'phases':len(phases),'sourceInputs':len(before),'sourceDrift':[],'allExitZero':True}))
