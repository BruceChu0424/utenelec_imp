"""Copy preserved fdeda runtime, compile only fixture overlay, start own PG.

Never touches the unified Root database or original audit files. Private keys
are generated once and retained outside Git for both program generations.
"""
from pathlib import Path
import hashlib, json, os, secrets, shutil, subprocess

base = Path(__file__).resolve().parent
root = base.parents[1]
audit = root.parent / 'feedback-audit-20261110'
old = audit / 'audit/orders-returns/target'
build = base / 'build-old-fdeda'
private = base / 'private'
private.mkdir(exist_ok=True)
config_path = private / 'runtime.json'
if build.exists(): raise SystemExit('Choose a new build; do not overwrite runtime evidence')
if config_path.exists(): raise SystemExit('Choose a new private run; preserve existing keys')
config = {k: secrets.token_urlsafe(42) for k in ['password','syntheticAccountPassword','jwtSecret','hmacKey','pgpMasterKey','bootstrapPassword']}
config.update(jdbcUrl='jdbc:postgresql://127.0.0.1:26633/bremediation', username='bremediation', bootstrapLogin='b-legacy-bootstrap')
config_path.write_text(json.dumps(config, indent=2), encoding='utf8')
for name in ['classes','test-classes']:
    shutil.copytree(old / name, build / name)
def fingerprint(directory):
    files={p.relative_to(directory).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(directory.rglob('*')) if p.is_file()}
    digest=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return {'fileCount':len(files),'treeSha256':digest,'files':files}
receipt={'status':'prep','oldSource':'fdeda88b3d73b24b8691ad132caa765196b19a3d', 'oldSourceActualHead':subprocess.check_output(['git','-C',str(audit),'rev-parse','HEAD']).decode().strip(), 'copiedMain':fingerprint(build/'classes')}
classpath=(audit/'audit/orders-returns/dependencies.txt').read_text().strip()
cp=';'.join([str(build/'classes'),str(build/'test-classes'),classpath])
sources=[root/'server/src/test/java/com/uten/imp/businesschain/FeedbackBWebSeedTest.java',root/'server/src/test/java/com/uten/imp/testsupport/FixtureDatabaseProperties.java']
with (base/'legacy-fixture-compile.log').open('w') as log:
    result=subprocess.run(['javac','-encoding','UTF-8','-cp',cp,'-d',str(build/'test-classes'),*[str(s) for s in sources]],stdout=log,stderr=subprocess.STDOUT)
receipt['fixtureCompileExit']=result.returncode
(base/'legacy-runtime-provenance.json').write_text(json.dumps(receipt,indent=2),encoding='utf8')
if result.returncode: raise SystemExit('Fixture compile failed; see retained log')
env=os.environ.copy();env.update(POSTGRES_DB='bremediation',POSTGRES_USER='bremediation',POSTGRES_PASSWORD=config['password'])
result=subprocess.run(['docker','run','-d','--name','uten-feedback-b-legacy-prep-20261111','-p','127.0.0.1:26633:5432','-e','POSTGRES_DB','-e','POSTGRES_USER','-e','POSTGRES_PASSWORD','postgres:16-alpine'],env=env,capture_output=True,text=True)
(base/'legacy-container-start.log').write_text(result.stdout+result.stderr,encoding='utf8')
if result.returncode: raise SystemExit('Own PG start failed; see retained log')
print('Prepared unchanged old main classes and independent 26633/bremediation; credentials retained privately.')
