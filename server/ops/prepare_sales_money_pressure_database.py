"""Create one durable, loopback-only synthetic benchmark database; never reset or reuse an ERP DB."""
import argparse
import json
import pathlib
import re
import secrets
import subprocess
import time


def run(*args, input_text=None):
    return subprocess.check_output(args, input=None if input_text is None else input_text.encode(), stderr=subprocess.STDOUT).decode().strip()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--name', required=True, help='Unique lowercase synthetic run suffix, such as 20260907-500k-r2')
parser.add_argument('--config', required=True, type=pathlib.Path, help='Connection file in an access-restricted local folder')
args = parser.parse_args()
if not re.fullmatch(r'[a-z0-9][a-z0-9-]{2,50}', args.name):
    raise SystemExit('Use a unique lowercase run suffix.')
config_path = args.config.resolve()
if config_path.exists():
    raise SystemExit('Connection file already exists. Resume it with run_sales_money_pressure.ps1; no database was changed.')
if not config_path.parent.is_dir():
    raise SystemExit('Create an access-restricted parent directory before running this command.')
container = 'uten-sales-pressure-' + args.name
volume = container + '-data'
database = 'uten_pressure_' + args.name.replace('-', '_')
for command in (('docker', 'container', 'inspect', container), ('docker', 'volume', 'inspect', volume)):
    if subprocess.run(command, capture_output=True).returncode == 0:
        raise SystemExit('The named container or volume already exists; no existing database was changed.')
password = secrets.token_hex(32)
token = secrets.token_hex(32)
run('docker', 'volume', 'create', '--label', 'com.uten.audit.purpose=synthetic-sales-money-pressure', volume)
# Secrets pass through stdin to docker's env-file, never command arguments or output.
# Docker run does not support /dev/stdin as a Windows client env-file; keep this
# short-lived file in the same restricted directory as the resulting config.
env_path = config_path.with_suffix('.init.env')
try:
    env_path.write_text(f'POSTGRES_USER=pressure_runner\nPOSTGRES_PASSWORD={password}\nPOSTGRES_DB={database}\n', encoding='utf-8')
    container_id = run('docker', 'run', '-d', '--name', container,
        '--label', 'com.uten.audit.purpose=synthetic-sales-money-pressure',
        '--env-file', str(env_path), '-p', '127.0.0.1::5432',
        '--mount', f'type=volume,src={volume},dst=/var/lib/postgresql/data', 'postgres:16-alpine')
finally:
    env_path.unlink(missing_ok=True)
for attempt in range(90):
    ready = subprocess.run(['docker', 'exec', container, 'pg_isready', '-h', '127.0.0.1', '-U', 'pressure_runner', '-d', database], capture_output=True)
    if ready.returncode == 0:
        break
    time.sleep(1)
else:
    raise SystemExit('Dedicated container created but PostgreSQL did not become ready; inspect it without deleting data.')
info = json.loads(run('docker', 'inspect', container))[0]
binding = info['NetworkSettings']['Ports']['5432/tcp']
assert len(binding) == 1 and binding[0]['HostIp'] == '127.0.0.1'
assert info['Id'] == container_id and info['Config']['Labels']['com.uten.audit.purpose'] == 'synthetic-sales-money-pressure'
assert any(m.get('Name') == volume and m['Destination'] == '/var/lib/postgresql/data' for m in info['Mounts'])
sql = f"""
CREATE SCHEMA audit_pressure;
CREATE TABLE audit_pressure.database_identity (
    singleton boolean PRIMARY KEY CHECK(singleton), identity_token text NOT NULL,
    purpose text NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
INSERT INTO audit_pressure.database_identity VALUES(TRUE,'{token}','synthetic-sales-money-pressure',now());
"""
run('docker', 'exec', '-i', container, 'psql', '-U', 'pressure_runner', '-d', database, '-v', 'ON_ERROR_STOP=1', input_text=sql)
config = {'container': container, 'containerId': container_id, 'volume': volume,
          'host': '127.0.0.1', 'port': int(binding[0]['HostPort']), 'database': database,
          'user': 'pressure_runner', 'password': password, 'identityToken': token}
config_path.write_text(json.dumps(config, indent=2), encoding='utf-8')
print(json.dumps({'created': True, 'container': container, 'database': database,
                  'loopbackOnly': True, 'configPath': str(config_path), 'purpose': 'synthetic benchmark; not company data'}))
