"""Create an isolated projection-test database in this run's preserved upgrade container."""
from pathlib import Path
import argparse
import json
import re
import subprocess
import uuid

parser = argparse.ArgumentParser(__doc__)
parser.add_argument('--upgrade-output', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
source = a.upgrade_output.resolve(strict=True)
out = a.output.resolve()
if out.exists():
    raise SystemExit('Choose a new private config output; previous evidence is retained')
cfg = json.loads((source / 'upgrade-runtime-private.json').read_text(encoding='utf-8-sig'))
name = cfg['container']
if not re.fullmatch(r'uten-remediate-a-upgrade-[0-9a-f]{8}', name):
    raise SystemExit('Only the dedicated container created by upgrade_probe is allowed')
port = subprocess.check_output(['docker', 'port', name, '5432/tcp'], text=True).strip()
if port != '127.0.0.1:' + str(cfg['port']):
    raise SystemExit('The dedicated loopback PostgreSQL port changed')
database = 'feedback_projection_' + uuid.uuid4().hex[:8]
subprocess.run(['docker', 'exec', name, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-c',
                'CREATE DATABASE ' + database], check=True, stdout=subprocess.DEVNULL)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps({'jdbcUrl': 'jdbc:postgresql://' + port + '/' + database,
                          'username': cfg['username'], 'password': cfg['password']}, indent=2), encoding='utf-8')
print(json.dumps({'config': str(out), 'database': database, 'port': cfg['port'],
                  'rootRuntimeDatabaseUsed': False}))
