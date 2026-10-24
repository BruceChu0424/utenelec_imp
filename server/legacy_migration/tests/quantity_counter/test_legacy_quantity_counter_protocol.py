"""Run synthetic V908 real PostgreSQL regressions on a fresh private container.

Needs Java 21, Docker, and runtime dependencies containing Flyway, JDBC and
Jackson. Reads only repository code plus synthetic rows.json; never .env or
business inputs. The optional benchmark is separate from the normal assertions.
"""
from pathlib import Path
import argparse
import subprocess
import json
import uuid
import hashlib
import shutil
import time
import re

HERE = Path(__file__).resolve().parent
DATABASE = 'synthetic_counter_adversarial'


def call(args, timeout=600):
    return subprocess.run(args, capture_output=True, timeout=timeout)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--classpath-argfile', type=Path, required=True)
    parser.add_argument('--output-directory', type=Path, required=True)
    parser.add_argument('--migration', type=Path, help='Optional private V908 candidate override')
    parser.add_argument('--benchmark', action='store_true', help='Also time 1k/5k fully guarded source/target phases')
    args = parser.parse_args()
    repo = args.repo.resolve()
    source_migrations = repo/'server/src/main/resources/db/migration'
    migration = args.migration or source_migrations/'V908__legacy_initial_quantity_counter_provenance.sql'
    fixture = repo/'server/src/test/resources/legacy-bootstrap-fixture/rows.json'
    java_source = HERE/'CounterProtocolAdversarial.java'
    for source in (migration, fixture, java_source, args.classpath_argfile):
        if not source.is_file():
            parser.error(f'Missing required synthetic test/code input: {source}')
    suffix = uuid.uuid4().hex[:10]
    name = 'uten-counter-proof-test-'+suffix
    password = uuid.uuid4().hex
    stage = args.output_directory.resolve()/('execution-'+time.strftime('%Y%m%d-%H%M%S')+'-'+suffix)
    stage.mkdir(parents=True)
    migrations = stage/'migrations'
    migrations.mkdir()
    for source in source_migrations.glob('*.sql'):
        shutil.copy2(source, migrations/source.name)
    shutil.copy2(migration, migrations/migration.name)
    shutil.copy2(java_source, stage/java_source.name)
    shutil.copy2(Path(__file__), stage/Path(__file__).name)
    evidence = {
        'container': name, 'synthetic_only': True, 'candidate_connected': False,
        'application_configuration_read': False, 'real_business_inputs_read': False,
        'password_saved_in_evidence': False, 'forward_migration_sha256': digest(migration),
        'java_harness_sha256': digest(java_source), 'driver_sha256': digest(Path(__file__)),
        'synthetic_fixture_sha256': digest(fixture), 'container_removed': False,
        'migrations': {p.name: digest(p) for p in sorted(migrations.glob('*.sql'))},
    }
    created = False
    try:
        result = call(['docker', 'run', '--detach', '--name', name,
                       '--publish', '127.0.0.1::5432', '--env', 'POSTGRES_DB='+DATABASE,
                       '--env', 'POSTGRES_PASSWORD='+password, 'postgres:16-alpine'])
        assert result.returncode == 0, 'Own synthetic PostgreSQL could not start'
        created = True
        for _ in range(50):
            # Only the final server listens on TCP; the initialization server is socket-only.
            result = call(['docker', 'exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres', '-d', DATABASE], timeout=10)
            if result.returncode == 0:
                break
            time.sleep(.2)
        assert result.returncode == 0, 'Own synthetic PostgreSQL not ready'
        metadata = json.loads(call(['docker', 'inspect', name]).stdout)[0]
        port = metadata['NetworkSettings']['Ports']['5432/tcp'][0]
        assert port['HostIp'] == '127.0.0.1'
        evidence['isolation'] = {'database': DATABASE, 'host_binding': port,
                                 'image_id': metadata['Image'], 'other_database_connections': False}
        command = ['java', '-cp', '@'+str(args.classpath_argfile.resolve()), str(stage/java_source.name),
                   'jdbc:postgresql://127.0.0.1:'+port['HostPort']+'/'+DATABASE,
                   'postgres', password, str(migrations), str(fixture), str(stage/'test-receipt.json')]
        if args.benchmark:
            command.append('--benchmark')
        result = call(command)
        (stage/'synthetic-only.stdout.log').write_bytes(result.stdout)
        (stage/'synthetic-only.stderr.log').write_bytes(result.stderr)
        evidence['returncode'] = result.returncode
        evidence['full_flyway_ready'] = bool(re.search(rb'SYNTHETIC_FULL_FLYWAY_READY', result.stdout))
        receipt = stage/'test-receipt.json'
        if receipt.exists():
            actual = json.loads(receipt.read_text(encoding='utf-8'))
            evidence['passed'], evidence['failed'] = actual['passed'], actual['failed']
            evidence['failures'] = [r for r in actual['tests'] if r['status'] == 'FAIL']
            evidence['benchmarks'] = [{'rows': r['rows'], 'register_milliseconds': r['register_milliseconds'],
                                       'insert_and_deferred_milliseconds': r['insert_and_deferred_milliseconds']}
                                      for r in actual.get('benchmarks', [])]
    finally:
        if created:
            assert re.fullmatch('uten-counter-proof-test-[0-9a-f]{10}', name)
            evidence['container_removed'] = call(['docker', 'rm', '--force', name]).returncode == 0
        (stage/'driver-receipt.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding='utf-8')
    concise = {k: v for k, v in evidence.items() if k != 'migrations'}
    concise['receipt'] = str(stage/'driver-receipt.json')
    print(json.dumps(concise, ensure_ascii=False, indent=2), flush=True)
    if evidence.get('returncode') != 0 or evidence.get('failed', 1) != 0 or not evidence['container_removed']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
