#!/usr/bin/python3
"""Temporary root ExecCondition: permit only a signed release/database pairing.

Read-only, deliberately separate from Operations/updater state. Every rejection
returns 1 (systemd skips startup). The maintenance drop-in also disables Restart
so an interpreter crash, signal, or timeout cannot create a restart storm.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import urllib.parse
import uuid

CONFIG = Path('/etc/uten-imp/cutover-start-guard.json')
CURRENT = Path('/opt/uten-imp/current')
RELEASES = Path('/opt/uten-imp/releases')
SIGNERS_ROOT = Path('/etc/uten-imp-updater')
PGDATA = '/data/postgresql/16/main'
VERSION = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z')
SHA256 = re.compile(r'[0-9a-f]{64}\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
REQUIRED_PAYLOADS = ('web/version.json', 'server/uten-imp-server.jar', 'server/uten-imp-migrator.jar')
SQL = """BEGIN READ ONLY; SET LOCAL statement_timeout='5s'; SET LOCAL lock_timeout='1s';
SET LOCAL search_path=pg_catalog;
SELECT json_build_object('database','uten_imp','databaseOid',d.oid::bigint,
'port',current_setting('port')::int,'dataDirectory',current_setting('data_directory'),
'systemIdentifier',c.system_identifier::text,'databaseAllowsConnections',d.datallowconn,
'runtimeConnect',has_database_privilege('uten',d.oid,'CONNECT'),'runtimeLogin',r.rolcanlogin,
'runtimePasswordUnexpired',r.rolvaliduntil IS NULL OR r.rolvaliduntil > current_timestamp,
'observer',current_user) FROM pg_database d CROSS JOIN pg_control_system() c
CROSS JOIN pg_roles r WHERE d.datname='uten_imp' AND r.rolname='uten';
COMMIT;"""


class Rejected(ValueError):
    pass


def require(condition):
    if not condition:
        raise Rejected('Cutover identity does not match')


def parents_safe(path):
    require(path.is_absolute())
    for parent in reversed((path.parent, *path.parent.parents)):
        info = parent.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022)


def open_owned(path, maximum, *, private=False):
    parents_safe(path)
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_uid == 0 and before.st_nlink == 1
            and not before.st_mode & 0o022 and 0 < before.st_size <= maximum)
    if private:
        require(before.st_gid == 0 and stat.S_IMODE(before.st_mode) == 0o600)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    after = os.fstat(fd)
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        os.close(fd)
        raise Rejected('Cutover file changed')
    return os.fdopen(fd, 'rb')


def read_owned(path, maximum, *, private=False):
    with open_owned(path, maximum, private=private) as stream:
        data = stream.read(maximum + 1)
    require(0 < len(data) <= maximum)
    return data


def digest_owned(path, maximum=1024**3):
    with open_owned(path, maximum) as stream:
        before = os.fstat(stream.fileno())
        digest = hashlib.sha256()
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
        require((before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_size, after.st_mtime_ns, after.st_ctime_ns))
    return digest.hexdigest()


def unique_json(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            require(key not in value)
            value[key] = item
        return value
    value = json.loads(raw, object_pairs_hook=pairs)
    require(isinstance(value, dict))
    return value


def validate_config(config):
    require(set(config) == {'format', 'maintenanceId', 'runtimeProfile', 'systemIdentifier', 'dataDirectory',
                            'allowedSigners', 'allowedSignersSha256', 'signerIdentity', 'namespace', 'pairs'})
    require(config['format'] == 'uten-imp-cutover-guard-v2')
    require(config['runtimeProfile'] in {'prod', 'internal-test'})
    require(str(uuid.UUID(config['maintenanceId'])) == config['maintenanceId'])
    require(isinstance(config['systemIdentifier'], str)
            and re.fullmatch(r'[0-9]{16,24}', config['systemIdentifier']) is not None)
    require(config['dataDirectory'] == PGDATA)
    require(isinstance(config['allowedSigners'], str)
            and Path(config['allowedSigners']).is_relative_to(SIGNERS_ROOT)
            and '..' not in Path(config['allowedSigners']).parts)
    require(SHA256.fullmatch(config['allowedSignersSha256']) is not None)
    for field in ('signerIdentity', 'namespace'):
        require(isinstance(config[field], str) and re.fullmatch(r'[A-Za-z0-9._-]{1,128}', config[field]) is not None)
    require(isinstance(config['pairs'], dict) and set(config['pairs']) == {'old', 'new'})
    for pair in config['pairs'].values():
        require(isinstance(pair, dict) and set(pair) == {'databaseOid', 'version', 'commitSha',
            'releaseDirectory', 'sumsSha256', 'signatureSha256'})
        require(type(pair['databaseOid']) is int and 0 < pair['databaseOid'] < 2**32)
        require(isinstance(pair['version'], str) and VERSION.fullmatch(pair['version']) is not None)
        require(COMMIT.fullmatch(pair['commitSha']) is not None)
        require(pair['releaseDirectory'] == str(RELEASES / pair['version']))
        require(SHA256.fullmatch(pair['sumsSha256']) is not None and SHA256.fullmatch(pair['signatureSha256']) is not None)
    old, new = config['pairs']['old'], config['pairs']['new']
    require(old['databaseOid'] != new['databaseOid'] and old['commitSha'] != new['commitSha'])
    require(tuple(map(int, old['version'][1:].split('.'))) < tuple(map(int, new['version'][1:].split('.'))))


def runtime_environment(environment, profile):
    # UTEN_DB_* is only authoritative under the reviewed local profile and
    # canonical launcher. Fail closed on higher-priority Spring/Java channels,
    # including relaxed-binding spellings; do not mistake ignored JAVA_OPTS for
    # an automatic JVM input or reject reviewed heap flags in ExecStart.
    require(profile in {'prod', 'internal-test'} and environment.get('UTEN_PROFILE') == profile)
    for name in environment:
        normalized = re.sub(r'[^A-Za-z0-9]', '', name).upper()
        require(not normalized.startswith(('SPRINGDATASOURCE', 'SPRINGCONFIG', 'SPRINGPROFILES', 'SPRINGMAIN'))
                and normalized not in {'SPRINGAPPLICATIONJSON', 'JAVATOOLOPTIONS', 'JAVAOPTIONS', 'JDKJAVAOPTIONS'})
    raw = environment.get('UTEN_DB_URL', '')
    require(raw.startswith('jdbc:postgresql://'))
    parsed = urllib.parse.urlparse(raw.removeprefix('jdbc:'))
    require(parsed.hostname == '127.0.0.1' and parsed.port == 5432 and parsed.path == '/uten_imp'
            and not parsed.username and not parsed.password and not parsed.fragment
            and parsed.query in {'', 'currentSchema=public'})
    require(environment.get('UTEN_DB_USER') == 'uten')


def current_identity():
    parents_safe(CURRENT)
    info = CURRENT.lstat()
    require(stat.S_ISLNK(info.st_mode) and info.st_uid == 0)
    return CURRENT.resolve(strict=True), (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_ctime_ns)


def inventory(raw):
    result = {}
    for line in raw.decode('ascii').splitlines():
        match = re.fullmatch(r'([0-9a-fA-F]{64})  (?:\./)?([A-Za-z0-9._/-]+)', line)
        require(match is not None)
        checksum, name = match.groups()
        require(not name.startswith('/') and '..' not in name and '//' not in name and name not in result)
        result[name] = checksum.lower()
    require(all(name in result for name in REQUIRED_PAYLOADS))
    return result


def verified_release(config, pair):
    directory = Path(pair['releaseDirectory'])
    require(directory.resolve(strict=True) == directory)
    sums = read_owned(directory / 'SHA256SUMS', 1024**2)
    signature = directory / 'SHA256SUMS.sig'
    require(hashlib.sha256(sums).hexdigest() == pair['sumsSha256'])
    require(digest_owned(signature, 16384) == pair['signatureSha256'])
    signers = Path(config['allowedSigners'])
    require(digest_owned(signers, 65536) == config['allowedSignersSha256'])
    # Reverify the authenticated inventory; do not trust an updater log or a
    # newly rendered metadata string. Child receives no inherited app secrets.
    subprocess.run(['/usr/bin/ssh-keygen', '-Y', 'verify', '-f', str(signers), '-I', config['signerIdentity'],
                    '-n', config['namespace'], '-s', str(signature)], input=sums, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'}, check=True, timeout=5)
    recorded = inventory(sums)
    for name in REQUIRED_PAYLOADS:
        require(digest_owned(directory / name) == recorded[name])
    metadata = unique_json(read_owned(directory / 'web/version.json', 16384))
    require(metadata.get('schemaVersion') == 1 and metadata.get('product') == 'uten-imp'
            and metadata.get('version') == pair['version'] and metadata.get('commitSha') == pair['commitSha'])


def database_identity():
    result = subprocess.run(['/usr/sbin/runuser', '-u', 'postgres', '--', '/usr/bin/psql',
        '-X', '-qAt', '-w', '-v', 'ON_ERROR_STOP=1', '-h', '/run/postgresql', '-p', '5432',
        '-U', 'postgres', '-d', 'postgres', '-c', SQL], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8', 'PGCONNECT_TIMEOUT': '5'},
        check=True, timeout=10)
    require(0 < len(result.stdout) <= 16384)
    return unique_json(result.stdout)


def evaluate(config, environment, observe=database_identity):
    validate_config(config)
    runtime_environment(environment, config['runtimeProfile'])
    physical, before = current_identity()
    # systemd applies WorkingDirectory to this condition and the main command.
    # Always inspect this real process cwd, never a caller-supplied attestation.
    require(Path.cwd().resolve(strict=True) == physical)
    matching = [pair for pair in config['pairs'].values() if pair['releaseDirectory'] == str(physical)]
    require(len(matching) == 1)
    pair = matching[0]
    verified_release(config, pair)
    database = observe()
    require(set(database) == {'database', 'databaseOid', 'port', 'dataDirectory', 'systemIdentifier',
                            'databaseAllowsConnections', 'runtimeConnect', 'runtimeLogin', 'runtimePasswordUnexpired', 'observer'})
    require(database['database'] == 'uten_imp' and type(database['port']) is int and database['port'] == 5432
            and database['dataDirectory'] == config['dataDirectory']
            and database['systemIdentifier'] == config['systemIdentifier'] and database['observer'] == 'postgres'
            and database['databaseAllowsConnections'] is True and database['runtimeConnect'] is True
            and database['runtimeLogin'] is True and database['runtimePasswordUnexpired'] is True
            and type(database['databaseOid']) is int
            and database['databaseOid'] == pair['databaseOid'])
    # Root's exclusive maintenance window must also forbid rename/current
    # mutations between this check and JVM connection. A startup gate is not a
    # replacement for stopping every writer before the logical database swap.
    require(current_identity() == (physical, before) and Path.cwd().resolve(strict=True) == physical)


def main():
    try:
        require(os.geteuid() == 0 and len(sys.argv) == 1)
        config = unique_json(read_owned(CONFIG, 16384, private=True))
        evaluate(config, os.environ)
    except Exception:
        # Never expose argv, environment, raw PostgreSQL errors or config values.
        print('UTEN_CUTOVER_GUARD: startup skipped; verify maintenance pairing', file=sys.stderr)
        return 1
    print('UTEN_CUTOVER_GUARD: signed release/database pairing accepted')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
