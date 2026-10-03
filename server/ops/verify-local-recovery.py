#!/usr/bin/env python3
"""Read-only local snapshot -> a new network-isolated PG container + exact media.

Never restores into an existing container/database and never deletes a source or
an older backup. Evidence contains private database/object identities; keep its
output outside Git. The stopped restore container is retained for investigation.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=kwargs.pop('timeout', 30), **kwargs)


class Session:
    def __init__(self, container, database, user, log):
        self.process = subprocess.Popen(
            ['docker', 'exec', '-i', container, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1',
             '-U', user, '-d', database], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=log, text=True, encoding='utf-8')
        self.query("SET statement_timeout='60s'; SET timezone='UTC'; SET extra_float_digits=3;")

    def query(self, sql):
        marker = 'end_' + uuid.uuid4().hex
        self.process.stdin.write(sql + '\n\\echo ' + marker + '\n')
        self.process.stdin.flush()
        lines = []
        for line in self.process.stdout:
            if line.rstrip('\r\n') == marker:
                return '\n'.join(lines)
            lines.append(line.rstrip('\r\n'))
        raise RuntimeError('Database evidence session ended; inspect private log')

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.write('ROLLBACK;\n\\q\n')
            self.process.stdin.flush()
            self.process.wait(timeout=10)
        if self.process.returncode:
            raise RuntimeError('Database evidence session failed')


def quote(value):
    return '"' + value.replace('"', '""') + '"'


def fingerprint(session):
    tables = session.query("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;").splitlines()
    result = {}
    for table in tables:
        # Order-independent, duplicate-sensitive digest covers every stored field,
        # including exact numeric values, identities and references, not just counts.
        raw = session.query("SELECT json_build_object('rows',count(*),'row_digest',md5(COALESCE(string_agg(h,'' ORDER BY h),''))) "
                            'FROM (SELECT md5(to_jsonb(t)::text) h FROM public.' + quote(table) + ' t) rows;')
        result[table] = json.loads(raw)
    return result


def media_references(session):
    ordinary = json.loads(session.query("SELECT COALESCE(json_agg(x),'[]') FROM (SELECT 'ordinary' AS kind,storage_provider,storage_key,storage_version,size_bytes AS bytes,sha256 FROM attachments WHERE lifecycle_state='CLEAN') x;"))
    refs = list(ordinary)
    for table in ('sales_quote_template_candidates', 'sales_quote_template_versions', 'goods_cost_imports'):
        refs.extend(json.loads(session.query("SELECT COALESCE(json_agg(x),'[]') FROM (SELECT 'private' AS kind,storage_provider,storage_key,storage_version,storage_size AS bytes,storage_sha256 AS sha256 FROM " + table + ' WHERE storage_provider IS NOT NULL) x;')))
    return refs


def restore_local_media(refs, media_root, destination):
    verified = []
    for ref in refs:
        if ref['storage_provider'] != 'local' or ref['storage_version'] is not None:
            raise ValueError('This local rehearsal cannot declare unsupported providers restored')
        key = Path(ref['storage_key'])
        if key.is_absolute() or '..' in key.parts:
            raise ValueError('Invalid object key')
        source = (media_root / key).resolve(strict=True)
        if not source.is_relative_to(media_root):
            raise ValueError('Object escapes configured media directory')
        content = source.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        if len(content) != ref['bytes'] or digest != ref['sha256'].lower():
            raise ValueError('Original bytes differ from snapshot metadata')
        target = destination / key
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.read_bytes() != content:
            raise ValueError('Conflicting immutable object identities')
        target.write_bytes(content)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError('Restored original hash mismatch')
        verified.append({**ref, 'verified_sha256': digest})
    return verified


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-container', required=True)
    parser.add_argument('--source-database', required=True)
    parser.add_argument('--source-user', required=True)
    parser.add_argument('--local-media-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    media_root = options.local_media_root.resolve(strict=True)
    run_id = uuid.uuid4().hex[:12]
    target = 'uten-recovery-' + run_id
    label = 'uten.recovery.run=' + run_id
    manifest = {'format': 'uten-local-recovery-v2', 'run_id': run_id,
                'source_container': options.source_container, 'source_database': options.source_database,
                'restore_container': target, 'outcome': 'RUNNING', 'business_source_read_only': True,
                'network': 'none', 'application_download_verified': False}
    started = time.monotonic()
    created = False
    source = restored = None
    with (output / 'restore-private.log').open('w', encoding='utf-8') as log:
        try:
            source = Session(options.source_container, options.source_database, options.source_user, log)
            source.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;')
            snapshot = source.query('SELECT pg_export_snapshot();')
            assert source.query('SHOW transaction_read_only;') == 'on'
            manifest['source_facts'] = fingerprint(source)
            refs = media_references(source)
            dump = output / 'database.dump'
            with dump.open('xb') as stream:
                run(['docker', 'exec', '-e', 'PGOPTIONS=-c default_transaction_read_only=on',
                     options.source_container, 'pg_dump', '-U', options.source_user, '-d', options.source_database,
                     '-Fc', '--no-owner', '--no-acl', '--snapshot=' + snapshot], stdout=stream, stderr=log, timeout=600)
            manifest['dump_bytes'] = dump.stat().st_size
            manifest['dump_sha256'] = hashlib.sha256(dump.read_bytes()).hexdigest()
            manifest['media'] = restore_local_media(refs, media_root, output / 'media' / 'final')
            source.close(); source = None
            run(['docker', 'run', '-d', '--pull', 'never', '--name', target, '--label', label,
                 '--network', 'none', '--cpus', '0.75', '--memory', '1g', '--memory-swap', '1g',
                 '--pids-limit', '128', '-e', 'POSTGRES_HOST_AUTH_METHOD=trust',
                 '-e', 'POSTGRES_USER=' + options.source_user, '-e', 'POSTGRES_DB=uten_recovery',
                 'postgres:16-alpine'], stdout=log, stderr=log)
            created = True
            for attempt in range(60):
                if subprocess.run(['docker', 'exec', target, 'pg_isready', '-U', options.source_user,
                                   '-d', 'uten_recovery'], stdout=log, stderr=log, timeout=5).returncode == 0:
                    break
                time.sleep(0.5)
            else:
                raise RuntimeError('Private restore database never became ready')
            with dump.open('rb') as stream:
                run(['docker', 'exec', '-i', target, 'pg_restore', '-U', options.source_user,
                     '-d', 'uten_recovery', '--exit-on-error', '--no-owner', '--no-acl'], stdin=stream, stdout=log, stderr=log, timeout=600)
            restored = Session(target, 'uten_recovery', options.source_user, log)
            restored.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;')
            manifest['restored_facts'] = fingerprint(restored)
            manifest['table_differences'] = [name for name in manifest['source_facts']
                                           if manifest['source_facts'][name] != manifest['restored_facts'].get(name)]
            if manifest['source_facts'] != manifest['restored_facts']:
                raise AssertionError('Restored table counts or row digests differ')
            if refs != media_references(restored):
                # SQL iteration order is not a business fact.
                if sorted(map(lambda x: json.dumps(x, sort_keys=True), refs)) != sorted(map(lambda x: json.dumps(x, sort_keys=True), media_references(restored))):
                    raise AssertionError('Restored media reference set differs')
            manifest['outcome'] = 'EXACT_DATABASE_AND_LOCAL_ORIGINALS_VERIFIED'
        except BaseException as error:
            manifest['outcome'] = 'FAILED'
            manifest['failure_type'] = type(error).__name__
            raise
        finally:
            if source is not None:
                source.close()
            if restored is not None:
                restored.close()
            if created:
                actual = json.loads(subprocess.check_output(['docker', 'inspect', target], text=True))[0]
                if actual['Config']['Labels'].get('uten.recovery.run') != run_id or actual['Name'] != '/' + target:
                    raise RuntimeError('Refusing to stop a container without matching ownership')
                run(['docker', 'stop', '--time', '10', target], stdout=log, stderr=log)
            manifest['duration_seconds'] = round(time.monotonic() - started, 3)
            (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({key: manifest[key] for key in ('outcome', 'restore_container', 'dump_bytes', 'duration_seconds')}))


if __name__ == '__main__':
    main()
