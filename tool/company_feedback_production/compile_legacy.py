from pathlib import Path
import subprocess as sp,zipfile,os,shutil,argparse
parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2]);parser.add_argument('--output',type=Path,required=True)
a=parser.parse_args();root=a.root.resolve();p=a.output.resolve();p.mkdir(parents=True,exist_ok=True)
if (p/'legacy-compile.log').exists():raise SystemExit('Choose a fresh output directory to retain the prior build evidence')
fixture=p/'old-source';fixture.mkdir(exist_ok=True);(p/'tmp').mkdir(exist_ok=True);archive=p/'tmp/old.zip';tmp=p/'legacy-tmp';tmp.mkdir(exist_ok=True)
sp.run(['git','archive','--format=zip','-o',str(archive),'86dffb9db','server/src/main','server/pom.xml','contracts','assets/fonts'],cwd=root,check=True)
with zipfile.ZipFile(archive) as z:z.extractall(fixture)
env=dict(os.environ,TMP=str(tmp),TEMP=str(tmp),MAVEN_OPTS='-Xmx1900m -Djava.io.tmpdir='+str(tmp))
with (p/'legacy-compile.log').open('wb') as log:
  ret=sp.run([shutil.which('mvn'),'-B','-ntp','-Duten.build.directory='+str(p/'legacy-build'),'compile'],cwd=fixture/'server',env=env,stdout=log,stderr=log)
  raise SystemExit(ret.returncode)

