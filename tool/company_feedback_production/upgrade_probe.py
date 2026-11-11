from pathlib import Path
import subprocess as sp,sys,os,uuid,time,json,argparse,shutil
parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2]);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--build-dir',type=Path,required=True);parser.add_argument('--legacy-build',type=Path,required=True);parser.add_argument('--deps',type=Path,required=True)
a=parser.parse_args();root=a.root.resolve();p=a.output.resolve();source=Path(__file__).resolve().parent
p.mkdir(parents=True,exist_ok=True)
if (p/'candidate-upgrade-container.txt').exists():raise SystemExit('Use a fresh output directory; original databases and evidence are retained')
for directory in ['classes','test-classes']:shutil.copytree(a.build_dir/directory,p/'upgrade-current'/directory)
for name in ['FeedbackLegacyMaterialUpgradeFixture.java','FeedbackUpgradeRunner.java']:shutil.copyfile(source/name,p/name)
shutil.copyfile(a.deps,p/'deps-cp.txt')
dest=p/'upgrade-tests';dest.mkdir(exist_ok=True);tmp=p/'upgrade-tmp';tmp.mkdir(exist_ok=True)
deps=(p/'deps-cp.txt').read_text(encoding='utf8').strip()
def cp(prod):return ';'.join(str(x.resolve()) for x in [dest,p/'upgrade-current/test-classes',prod])+';'+deps
def run(cmd,args,log,env):
 arg=dest/(log+'.args');arg.write_text('\n'.join('"'+str(x).replace('\\','/')+'"' for x in args),encoding='utf8')
 with (p/(log+'.log')).open('wb') as stream:ret=sp.run([cmd,'@'+str(arg)],cwd=root/'server',env=env,stdout=stream,stderr=stream)
 if ret.returncode:raise RuntimeError(log+' exit '+str(ret.returncode))
def docker(args):
 ret=sp.run(['docker']+args,capture_output=True,text=True,encoding='utf8',errors='replace')
 if ret.returncode:raise RuntimeError(ret.stdout+ret.stderr)
 return ret.stdout.strip()
env=dict(os.environ,TMP=str(tmp),TEMP=str(tmp),UTEN_RUN_DB_TESTS='true',AUDIT_LEGACY_DIR=str(p))
current=p/'upgrade-current/classes';legacy=a.legacy_build.resolve()/'classes'
assert (legacy/'db/migration/V1128__goods_used_identity_delete_guard.sql').exists()
assert (current/'db/migration/V1130__verify_legacy_material_basis_and_linear_proof_sweep.sql').exists()
assert (current/'db/migration/V1131__settle_proof_peers_and_verify_legacy_demand_threshold.sql').exists()
from three_material_fixture import write_three_material_fixture
three_fixture=write_three_material_fixture(root,p)
run('javac',['-proc:none','-encoding','UTF-8','-cp',cp(current),'-d',dest,p/'FeedbackLegacyMaterialUpgradeFixture.java',p/'FeedbackUpgradeRunner.java',three_fixture],'upgrade-javac',env)
namefile=p/'candidate-upgrade-container.txt'
if namefile.exists():name=namefile.read_text().strip()
else:
 name='uten-remediate-a-upgrade-'+uuid.uuid4().hex[:8]
 docker(['run','-d','--name',name,'-p','127.0.0.1::5432','-e','POSTGRES_DB=audit_kit','-e','POSTGRES_PASSWORD=fixture-only','postgres:16-alpine']);namefile.write_text(name,encoding='utf8')
port=docker(['port',name,'5432/tcp']);assert port.startswith('127.0.0.1:');env['AUDIT_KIT_PG_PORT']=port.split(':')[-1]
for _ in range(100):
 if not sp.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode:break
 time.sleep(.2)
def java(phase,classes,label,extra=None):
 run('java',['-Xshare:off','-javaagent:'+next(x for x in deps.split(';') if '/mockito-core/' in x.replace('\\','/')),'-Xmx1500m','-Dfile.encoding=UTF-8','-Djava.io.tmpdir='+str(tmp),'-Dlogging.file.name='+str(p/(label+'-spring.log')),'-cp',cp(classes),'FeedbackUpgradeRunner',phase],label,dict(env,**(extra or {})))
if not (p/'old-final-id.txt').exists():java('old',legacy,'upgrade-v1128-public-baseline')
# Freeze a real pre-upgrade database, then isolate create/edit/approve paths.
with (p/'upgrade-v1128-before-candidate.dump').open('wb') as stream:sp.run(['docker','exec',name,'pg_dump','-U','postgres','-d','audit_kit','-Fc'],stdout=stream,check=True)
for mode in ['create','edit','approve','already1129']:
 database='candidate_'+mode
 exists=docker(['exec',name,'psql','-X','-qAt','-U','postgres','-c',"SELECT 1 FROM pg_database WHERE datname='"+database+"'"])
 if exists!='1':docker(['exec',name,'psql','-X','-v','ON_ERROR_STOP=1','-U','postgres','-c','CREATE DATABASE '+database+' TEMPLATE audit_kit'])
 special={'AUDIT_KIT_DATABASE':database,'AUDIT_KIT_OPERATION':'create' if mode=='already1129' else mode}
 if mode=='already1129':java('stage1129',current,'upgrade-existing-v1129-stage',dict(special,AUDIT_KIT_TARGET='1129'))
 java('current',current,'upgrade-candidate-'+mode,special)
 print('PASSED',mode,flush=True)
for mode in ['create','edit','approve']:
 database='candidate_three_'+mode
 docker(['exec',name,'psql','-X','-v','ON_ERROR_STOP=1','-U','postgres','-c','CREATE DATABASE '+database+' TEMPLATE audit_kit'])
 java('currentThree',current,'upgrade-three-'+mode,{'AUDIT_KIT_DATABASE':database,'AUDIT_THREE_OPERATION':mode})
 print('PASSED three-material',mode,flush=True)
(p/'upgrade-runtime-private.json').write_text(json.dumps({'container':name,'port':env['AUDIT_KIT_PG_PORT'],'database':'audit_kit','username':'postgres','password':'fixture-only'},indent=2),encoding='utf8')
print('PRESERVED isolated original and seven candidate databases; no accepted business ledger changed',flush=True)
