"""One handoff snapshot and shutdown of this task's verified local runtime."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import subprocess

root = Path(__file__).resolve().parents[2]
base = root / 'evidence/root'
private = base / 'private/handoff-20261111-stop-1'
receipt = base / 'handoff/runtime-stop-and-backup.json'
assert not private.exists() and not receipt.exists(), 'Preserve the previous handoff'
private.mkdir(parents=True)
settings = json.loads((base / 'private/runtime.json').read_text(encoding='utf-8-sig'))
assert settings['jdbcUrl'] == 'jdbc:postgresql://127.0.0.1:26630/feedback'
assert settings['username'] == 'feedback'
container = 'uten-feedback-final-20261110'
ports = json.loads(subprocess.check_output(['docker', 'inspect', '--format', '{{json .NetworkSettings.Ports}}', container]))
assert any(item['HostPort'] == '26630' for item in ports['5432/tcp'])
environment = os.environ.copy()
environment['PGPASSWORD'] = settings['password']
dump = private / 'feedback-full.dump'
with dump.open('xb') as stream, (private / 'pg-dump.stderr.log').open('xb') as error:
    subprocess.run(['docker', 'exec', '--env', 'PGPASSWORD', container,
                    'pg_dump', '--no-password', '-U', 'feedback', '-d', 'feedback', '-Fc'],
                   env=environment, stdout=stream, stderr=error, check=True)
with dump.open('rb') as stream, (private / 'dump-toc.txt').open('xb') as target:
    subprocess.run(['docker', 'exec', '-i', container, 'pg_restore', '--list'],
                   stdin=stream, stdout=target, stderr=subprocess.PIPE, check=True)

def powershell(command):
    return subprocess.check_output(['powershell', '-NoProfile', '-Command', command], encoding='utf8').strip()

stopped = []
for pid, token in [(6612, 'proxy-submit-hold.mjs layout0b5e-diagnostic-1'),
                   (30284, 'layout47-durable-1'), (33468, 'layout47-durable-1'),
                   (34992, 'start_server.ps1 -Attempt layout47-durable-1')]:
    raw = powershell(f'Get-CimInstance Win32_Process -Filter "ProcessId={pid}" | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress')
    if not raw:
        stopped.append({'pid': pid, 'state': 'already exited'})
        continue
    process = json.loads(raw)
    assert token.lower() in process['CommandLine'].lower(), f'PID {pid} ownership changed; do not stop'
    powershell(f"$ErrorActionPreference='Stop'; Stop-Process -Id {pid}")
    stopped.append({'pid': pid, 'state': 'stopped after exact task command ownership check'})
subprocess.run(['docker', 'stop', '--time', '20', container], check=True, stdout=subprocess.PIPE)
state = json.loads(subprocess.check_output(['docker', 'inspect', '--format', '{{json .State}}', container]))
assert not state['Running']
data = {'kind': 'user requested local merge and handoff; no further acceptance run',
    'capturedAtUtc': datetime.now(timezone.utc).isoformat(),
    'sourceHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, encoding='utf8').strip(),
    'dump': {'path': str(dump), 'bytes': dump.stat().st_size,
             'rawSha256': hashlib.sha256(dump.read_bytes()).hexdigest(),
             'format': 'full PostgreSQL custom archive; pg_restore --list verified; not restored',
             'private': True},
    'processes': stopped, 'container': container, 'containerRunning': state['Running'],
    'containerExitCode': state['ExitCode'], 'volumesRemoved': False,
    'companyOrMain8080RuntimeTouched': False,
    'reason': 'explicit user handoff; intentional stops are not test failures'}
receipt.parent.mkdir(parents=True, exist_ok=True)
receipt.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf8')
print(json.dumps(data, ensure_ascii=True))
