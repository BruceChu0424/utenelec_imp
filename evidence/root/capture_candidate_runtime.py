"""Read-only attestation of a frozen local backend and served Web build."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import re
import subprocess
import urllib.request

p = argparse.ArgumentParser()
p.add_argument('--attempt', required=True)
p.add_argument('--revision', required=True)
p.add_argument('--pid', required=True, type=int)
p.add_argument('--web-directory', required=True, type=Path)
p.add_argument('--web-receipt', required=True, type=Path)
p.add_argument('--output', required=True, type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
assert re.fullmatch(r'[a-z0-9-]+', a.attempt)
assert re.fullmatch(r'[a-f0-9]{40}', a.revision)
assert not a.output.exists(), 'Preserve old attestation'

def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args]).decode().strip()

assert git('rev-parse', 'HEAD') == a.revision, 'Freeze candidate before capture'
scopes = ['server/src/main/java', 'server/src/main/resources', 'server/pom.xml', 'lib']
assert not git('diff', '--name-only', 'HEAD', '--', *scopes), 'Product source is dirty'
base = root / 'evidence/root'
start = json.loads((base / f'logs/runtime-{a.attempt}-source-start.json').read_text(encoding='utf-8-sig'))
assert start['sourceStart'] == a.revision
server_log = base / f'logs/runtime-{a.attempt}-server.log'
assert f'with PID {a.pid} ' in server_log.read_text(encoding='utf8', errors='replace')
process = json.loads(subprocess.check_output([
    'powershell', '-NoProfile', '-Command',
    f'Get-CimInstance Win32_Process -Filter "ProcessId={a.pid}" | Select-Object ProcessId,ExecutablePath,CommandLine | ConvertTo-Json -Compress',
], encoding='utf8'))
assert process['ProcessId'] == a.pid
classes = base / f'runtime-maven-{a.attempt}/classes'
command_identity = process['CommandLine']
argfiles = []
for match in re.finditer(r'(?:^|\s)@(?:"([^"]+)"|(\S+))', command_identity):
    argfile = Path(match.group(1) or match.group(2)).resolve()
    assert argfile.is_relative_to((base / f'tmp/runtime/{a.attempt}').resolve()), 'Argument file left this runtime'
    argraw = argfile.read_bytes()
    command_identity += '\n' + argraw.decode('utf8')
    argfiles.append({'path': str(argfile), 'rawSha256': hashlib.sha256(argraw).hexdigest()})
assert str(classes).lower().replace('\\', '/') in command_identity.lower().replace('\\', '/'), 'PID does not run this private build'
manifest = []
digest = hashlib.sha256()
for path in sorted(classes.rglob('*')):
    if path.is_file() and (path.suffix == '.class' or path.parent.name == 'migration' and path.suffix == '.sql'):
        rel = path.relative_to(classes).as_posix()
        raw_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        digest.update(rel.encode('utf8') + b'\0' + bytes.fromhex(raw_hash))
        manifest.append({'path': rel, 'sha256': raw_hash})
assert manifest
web = json.loads(a.web_receipt.read_text(encoding='utf8'))
assert web['source'] == a.revision and web['exit'] == 0
settings = json.loads((base / 'private/runtime.json').read_text(encoding='utf-8-sig'))
script = a.web_directory / 'main.dart.js'
local_raw = script.read_bytes()
served_raw = urllib.request.urlopen(f'http://127.0.0.1:{settings["frontendPort"]}/main.dart.js', timeout=20).read()
assert local_raw == served_raw, 'Served Web script differs from reviewed build'
health = json.load(urllib.request.urlopen(f'http://127.0.0.1:{settings["backendPort"]}/actuator/health/readiness', timeout=20))
assert health['status'] == 'UP'
result = {
    'kind': 'local synthetic acceptance runtime; no publication or target-device claim',
    'capturedAtUtc': datetime.now(timezone.utc).isoformat(),
    'candidateRevision': a.revision, 'branch': git('branch', '--show-current'),
    'mainRevision': git('rev-parse', 'main'),
    'sourceGitObjects': {scope: git('rev-parse', a.revision + ':' + scope) for scope in scopes},
    'backend': {'pid': a.pid, 'executable': process['ExecutablePath'], 'port': settings['backendPort'],
        'classesDirectory': str(classes), 'argumentFiles': argfiles, 'classAndSqlCount': len(manifest),
        'compiledFingerprint': digest.hexdigest(),
        'compiledFingerprintBytes': 'sorted relative UTF-8 path + NUL + raw file SHA-256 bytes',
        'manifest': manifest, 'readiness': health['status']},
    'web': {'directory': str(a.web_directory.resolve()), 'receipt': str(a.web_receipt.resolve()),
        'port': settings['frontendPort'], 'mainDartJsBytes': len(local_raw),
        'mainDartJsRawSha256': hashlib.sha256(local_raw).hexdigest(), 'servedBytesMatch': True},
    'database': 'isolated loopback 127.0.0.1:26630/feedback',
}
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf8')
print(json.dumps({k: v for k, v in result.items() if k not in ('backend',)} | {
    'backend': {k: v for k, v in result['backend'].items() if k != 'manifest'}}, ensure_ascii=False))
