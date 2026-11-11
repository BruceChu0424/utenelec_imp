"""Compile a fixture overlay, then invoke opt-in public services against an
explicit synthetic loopback configuration. No HTTP login/session changes.
"""
from pathlib import Path
import argparse,json,os,shutil,subprocess
p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--seed',required=True);p.add_argument('--build',required=True);p.add_argument('--out',required=True);p.add_argument('--method',choices=['approveActualOldProgramReceiptOnlyDrafts','stalePreviewViaSameOwnerRoutes','seedIndependentMaterialOrderCases'],required=True);p.add_argument('--gate');p.add_argument('--fixtures',required=True)
a=p.parse_args();base=Path(__file__).resolve().parent;root=base.parents[1];build=Path(a.build).resolve();out=Path(a.out).resolve()
if out.exists():raise SystemExit('Preserve prior run; choose a new output directory')
out.mkdir(parents=True);(out/'tmp').mkdir();config=json.loads(Path(a.config).read_text(encoding='utf-8-sig'))
if not config['jdbcUrl'].startswith('jdbc:postgresql://127.0.0.1:'):raise SystemExit('Explicit loopback fixture required')
if not (build/'test-classes').exists():shutil.copytree(Path(a.fixtures)/'test-classes',build/'test-classes')
classpath=(root.parent/'feedback-audit-20261110/audit/orders-returns/dependencies.txt').read_text().strip()
sources=[base/'FeedbackBPublicServicePrepTest.java',root/'server/src/test/java/com/uten/imp/businesschain/FeedbackBWebSeedTest.java',root/'server/src/test/java/com/uten/imp/testsupport/FixtureDatabaseProperties.java']
with (out/'fixture-compile.log').open('w') as log:
    result=subprocess.run(['javac','-proc:none','-encoding','UTF-8','-cp',';'.join([str(build/'classes'),str(build/'test-classes'),classpath]),'-d',str(build/'test-classes'),*[str(s) for s in sources]],stdout=log,stderr=subprocess.STDOUT)
if result.returncode:raise SystemExit('Compile failed; retained fixture-compile.log')
env=os.environ.copy();env.update(UTEN_REMEDIATION_B_ALLOW_SEED='true',UTEN_RUN_DB_TESTS='true',UTEN_REMEDIATION_B_JDBC_URL=config['jdbcUrl'],UTEN_REMEDIATION_B_DB_USER=config['username'],UTEN_REMEDIATION_B_DB_PASSWORD=config['password'],UTEN_REMEDIATION_B_ACCOUNT_PASSWORD=config['syntheticAccountPassword'],UTEN_REMEDIATION_B_JWT_SECRET=config['jwtSecret'],UTEN_REMEDIATION_B_HMAC_KEY=config['hmacKey'],UTEN_REMEDIATION_B_PGP_MASTER_KEY=config['pgpMasterKey'],UTEN_REMEDIATION_B_BOOTSTRAP_LOGIN=config['bootstrapLogin'],UTEN_REMEDIATION_B_BOOTSTRAP_PASSWORD=config['bootstrapPassword'],UTEN_B_PREP_SEED=str(Path(a.seed).resolve()),UTEN_B_PREP_BEFORE_OUTPUT=str(out/'before-approval.json'),UTEN_B_PREP_OUTPUT=str(out/'result.json'),TEMP=str(out/'tmp'),TMP=str(out/'tmp'),MAVEN_OPTS='-Xmx1400m')
if a.gate:env['UTEN_B_TRANSPORT_GATE']=str(Path(a.gate).resolve())
with (out/'public-service.log').open('w') as log:
    result=subprocess.run([shutil.which('mvn.cmd'),' -B'.strip(),'-o','-ntp','-f',str(root/'server/pom.xml'),'-Duten.build.directory='+str(build),'-Duten.test.tmpdir='+str(out/'tmp'),'-Duten.test.jvm.heap.args=-Xmx1800m','-Dtest=FeedbackBPublicServicePrepTest#'+a.method,'surefire:test'],env=env,stdout=log,stderr=subprocess.STDOUT)
(out/'exit.txt').write_text(str(result.returncode));raise SystemExit(result.returncode)
