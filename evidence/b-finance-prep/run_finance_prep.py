"""One opt-in synthetic finance preparation in a fresh private build copy.
Root runtime/source build is read-only. No login, role configuration or GL calls.
"""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess
from datetime import datetime,timezone
p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--source-build',required=True);p.add_argument('--source-seed',required=True);p.add_argument('--run',required=True);p.add_argument('--reuse-private-build');a=p.parse_args()
base=Path(__file__).resolve().parent;root=base.parents[1];source=Path(a.source_build).resolve();run=Path(a.run).resolve();config=json.loads(Path(a.config).read_text(encoding='utf-8-sig'))
if not re.fullmatch(r'jdbc:postgresql://127\.0\.0\.1:26630/feedback',config['jdbcUrl']):raise SystemExit('Only the explicitly authorized isolated Root feedback database is accepted')
if run.exists():raise SystemExit('Preserve previous run; choose a new directory')
run.mkdir(parents=True);build=Path(a.reuse_private_build).resolve() if a.reuse_private_build else base/('build-'+run.name)
if a.reuse_private_build:
    if not build.is_relative_to(base) or not build.name.startswith('build-'):raise SystemExit('Reuse must stay in this prep worktree private build directory')
elif build.exists():raise SystemExit('Do not replace prior or running build')
def fingerprint(directory):
    digest=hashlib.sha256();count=0
    for f in sorted(directory.rglob('*')):
        if f.is_file():digest.update(f.relative_to(directory).as_posix().encode());digest.update(b'\0');digest.update(hashlib.sha256(f.read_bytes()).digest());count+=1
    return {'files':count,'sha256':digest.hexdigest()}
if not a.reuse_private_build:
    for name in ['classes','test-classes']:shutil.copytree(source/name,build/name)
origin=fingerprint(source/'classes');copied=fingerprint(build/'classes')
if origin!=copied:raise SystemExit('Private main copy is not byte-identical')
(run/'build-provenance.json').write_bytes(json.dumps({'kind':'prep; reused read-only Root eba5 program main bytes, only fixture overlay compiled','sourceBuild':str(source),'privateBuild':str(build),'sourceHeadObserved':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD']).decode().strip(),'copiedAtUtc':datetime.now(timezone.utc).isoformat(),'originalMain':origin,'copiedMain':copied},indent=2).encode('utf8'))
cp=(root.parent/'feedback-audit-20261110/audit/orders-returns/dependencies.txt').read_text().strip()
with (run/'compile.log').open('w') as log:
    result=subprocess.run(['javac','-proc:none','-encoding','UTF-8','-cp',';'.join([str(build/'classes'),str(build/'test-classes'),cp]),'-d',str(build/'test-classes'),str(base/'FeedbackBFinanceUiPrepTest.java')],stdout=log,stderr=subprocess.STDOUT)
(run/'compile.exit').write_text(str(result.returncode))
if result.returncode:raise SystemExit('Fixture compile failed; original output retained')
(run/'tmp').mkdir();env=os.environ.copy();env.update(UTEN_B_FINANCE_ALLOW_SEED='true',UTEN_REMEDIATION_B_ALLOW_SEED='true',UTEN_RUN_DB_TESTS='true',UTEN_REMEDIATION_B_JDBC_URL=config['jdbcUrl'],UTEN_REMEDIATION_B_DB_USER=config['username'],UTEN_REMEDIATION_B_DB_PASSWORD=config['password'],UTEN_REMEDIATION_B_ACCOUNT_PASSWORD=config['syntheticAccountPassword'],UTEN_REMEDIATION_B_JWT_SECRET=config['jwtSecret'],UTEN_REMEDIATION_B_HMAC_KEY=config['hmacKey'],UTEN_REMEDIATION_B_PGP_MASTER_KEY=config['pgpMasterKey'],UTEN_REMEDIATION_B_BOOTSTRAP_LOGIN=config['bootstrapLogin'],UTEN_REMEDIATION_B_BOOTSTRAP_PASSWORD=config['bootstrapPassword'],UTEN_B_FINANCE_SOURCE_SEED=str(Path(a.source_seed).resolve()),UTEN_B_FINANCE_OUTPUT=str(run/'finance-seed.json'),TEMP=str(run/'tmp'),TMP=str(run/'tmp'),MAVEN_OPTS='-Xmx1400m')
with (run/'finance-seed.log').open('w') as log:
    result=subprocess.run([shutil.which('mvn.cmd'),'-B','-o','-ntp','-f',str(root/'server/pom.xml'),'-Duten.build.directory='+str(build),'-Duten.test.tmpdir='+str(run/'tmp'),'-Duten.test.jvm.heap.args=-Xmx1800m','-Dtest=FeedbackBFinanceUiPrepTest#seedOnlyNewFinanceActorAndUnassignedStyles','surefire:test'],env=env,stdout=log,stderr=subprocess.STDOUT)
(run/'exit.txt').write_text(str(result.returncode))
for f in (build/'surefire-reports').glob('*FeedbackBFinanceUiPrepTest*'):shutil.copy2(f,run/f.name)
if fingerprint(source/'classes')!=origin:raise SystemExit('Source build changed concurrently; retain output and review origin')
print('Synthetic finance prep exit '+str(result.returncode)+'; credentials not printed')
raise SystemExit(result.returncode)
