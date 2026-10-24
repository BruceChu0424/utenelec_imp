"""Disposable SQL/READ ONLY smoke; no source or candidate database is accessed."""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
from unittest.mock import patch

import verify_rehearsal_result as verifier
from test_verify_rehearsal_result import Fixture, RUN, ADMIN, MEDIA, PRIVATE_ACCOUNT, PRIVATE_HASH


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    real_run = subprocess.run
    name = 'uten-readonly-verifier-' + uuid.uuid4().hex
    container_id = real_run(['docker', 'run', '--rm', '-d', '--network', 'none', '--name', name,
                             '-e', 'POSTGRES_USER=uten', '-e', 'POSTGRES_PASSWORD=fixture-only',
                             '-e', 'POSTGRES_DB=verifier', 'postgres:16-alpine'],
                            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()
    try:
        for _ in range(60):
            # Only the final server listens on TCP; the initialization server is socket-only.
            ready = real_run(['docker', 'exec', container_id, 'pg_isready', '-h', '127.0.0.1', '-U', 'uten', '-d', 'verifier'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if ready.returncode == 0:
                break
            time.sleep(0.25)
        else:
            raise RuntimeError('Disposable PostgreSQL did not become ready')
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            expected = fixture.expected()
            summary = {'automatedCheckCount': 7, 'bomTopology': {
                'graph_sha256': expected['bom_graph_sha256'], 'retained_edges': 2,
                'target_edge_identity_verified': True, 'target_exclusion_identity_verified': True}}
            setup = """CREATE EXTENSION pgcrypto;
CREATE TABLE employees(id uuid PRIMARY KEY,code text,status text,is_deleted boolean DEFAULT false);
CREATE TABLE users(id uuid,login_account text,password_hash text,status text,is_super_admin boolean,is_deleted boolean,employee_id uuid);
CREATE TABLE goods(id uuid PRIMARY KEY,legacy_id integer,auto_created boolean DEFAULT false,is_deleted boolean DEFAULT false,status text DEFAULT '使用');
CREATE TABLE goods_bom_items(legacy_id integer,goods_id uuid,component_goods_id uuid,qty numeric(18,5),is_deleted boolean DEFAULT false);
CREATE TABLE goods_material_identity_evidence(product_goods_id uuid,material_goods_id uuid,status text,import_run_id uuid,is_deleted boolean DEFAULT false);
CREATE TABLE attachments(id uuid,owner_type text,lifecycle_state text);
CREATE TABLE flyway_schema_history(version text,success boolean);
CREATE TABLE legacy_migration_runs(run_id uuid,status text,reconciliation_status text,target text,migration_mode text,exit_code integer,rejected_count integer,export_manifest_sha256 text,checksum_manifest_sha256 text,migration_repository_commit text,reconciliation_summary jsonb,mapping_version text DEFAULT 'bootstrap-v13');
CREATE TABLE legacy_migration_reconciliation_items(run_id uuid,passed boolean);
CREATE TABLE legacy_migration_run_files(run_id uuid,file_name text,sha256 text,byte_size bigint);
"""
            employee_ids = [ADMIN] + [str(uuid.uuid4()) for _ in range(3)]
            for identity, code, status in zip(employee_ids, ['ADMIN', 'UT0001', 'UT0002', 'UT0003'], ['active', 'active', 'active', 'resigned']):
                setup += 'INSERT INTO employees VALUES(' + ','.join(map(literal, [identity, code, status])) + ',false);\n'
            setup += 'INSERT INTO users VALUES(' + ','.join(map(literal, [ADMIN, PRIVATE_ACCOUNT, PRIVATE_HASH, 'active'])) + ',true,false,' + literal(ADMIN) + ');\n'
            goods_ids = [str(uuid.uuid4()) for _ in range(3)]
            for identity, old_id in zip(goods_ids, [10, 11, 12]):
                setup += 'INSERT INTO goods(id,legacy_id) VALUES(' + literal(identity) + ',' + str(old_id) + ');\n'
            for old_id, component, qty in [(1, goods_ids[1], 1), (2, goods_ids[2], 2)]:
                setup += 'INSERT INTO goods_bom_items(legacy_id,goods_id,component_goods_id,qty) VALUES(' + str(old_id) + ',' + literal(goods_ids[0]) + ',' + literal(component) + ',' + str(qty) + ');\n'
            setup += 'INSERT INTO goods_material_identity_evidence(product_goods_id,material_goods_id,status,import_run_id) VALUES(' + ','.join(map(literal, [goods_ids[1], goods_ids[2], 'PENDING_QUANTITY', RUN])) + ');\n'
            setup += 'INSERT INTO attachments VALUES(' + literal(MEDIA) + ",'GOODS','CLEAN');\nINSERT INTO flyway_schema_history VALUES('907',true);\n"
            setup += 'INSERT INTO legacy_migration_runs VALUES(' + ','.join(map(literal, [RUN, 'SUCCESS', 'PASSED', '--bootstrap-all', 'BOOTSTRAP'])) + ',0,0,' + ','.join(map(literal, [fixture.manifest_sha, fixture.manifest_sha, '1' * 40, json.dumps(summary)])) + "::jsonb||jsonb_build_object('targetDatabase','verifier','targetSystemIdentifier',(SELECT system_identifier::text FROM pg_control_system())));\n"
            setup += 'INSERT INTO legacy_migration_reconciliation_items SELECT ' + literal(RUN) + ',true FROM generate_series(1,7);\n'
            for file_name, record in expected['files'].items():
                setup += 'INSERT INTO legacy_migration_run_files VALUES(' + ','.join(map(literal, [RUN, file_name, record['sha256']])) + ',' + str(record['bytes']) + ');\n'
            setup_result = real_run(['docker', 'exec', '-i', container_id, 'psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'uten', '-d', 'verifier'],
                                    input=setup.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if setup_result.returncode:
                raise RuntimeError('Disposable fixture setup failed; values withheld')

            def redirect_only_owned_container(argv, **kwargs):
                if argv[:4] != ['docker', 'exec', '-i', 'uten-imp-postgres']:
                    raise AssertionError('Unexpected verifier subprocess')
                argv = argv.copy(); argv[3] = container_id
                return real_run(argv, **kwargs)

            with patch.object(verifier.subprocess, 'run', side_effect=redirect_only_owned_container):
                db = verifier.ReadOnlyDatabase('verifier')
                tx = db.query("SELECT jsonb_build_object('readonly',current_setting('transaction_read_only'),'isolation',current_setting('transaction_isolation'));")
                assert tx == {'readonly': 'on', 'isolation': 'repeatable read'}
                result = verifier.verify_database(db, expected, json.loads(fixture.snapshot.read_text()), RUN, 907)
                assert result['status'] == 'PASSED'
                try:
                    db.query("SELECT 1; INSERT INTO employees(id,code,status) VALUES(gen_random_uuid(),'FORBIDDEN','active'); SELECT '{}'::jsonb;")
                except verifier.VerificationError:
                    pass
                else:
                    raise AssertionError('READ ONLY transaction allowed a write')
                counts = db.query("SELECT jsonb_build_object('employees',count(*)) FROM employees;")
                assert counts['employees'] == 4
                previous = dict(result, database='verifier', manifest_sha256=expected['manifest_sha256'], frozen_commit=expected['frozen_commit'])
                rename_result = real_run(['docker', 'exec', '-i', container_id, 'psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'uten', '-d', 'postgres'],
                                         input=b'ALTER DATABASE verifier RENAME TO verifier_active;', stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                assert rename_result.returncode == 0, 'Disposable database rename failed'
                renamed_db = verifier.ReadOnlyDatabase('verifier_active')
                renamed_result = verifier.verify_database(renamed_db, expected, json.loads(fixture.snapshot.read_text()), RUN, 907,
                                                          renamed_from='verifier', pre_rename_proof=previous)
                assert renamed_result['status'] == 'PASSED'
                assert renamed_result['database_identity'] == previous['database_identity']
            assert PRIVATE_ACCOUNT not in json.dumps(result) and PRIVATE_HASH not in json.dumps(result)
            receipt = {'status': 'PASSED', 'isolated_postgresql': True, 'business_database_access': False,
                       'sql_queries_compiled_and_executed': True, 'full_verifier_passed': True,
                       'repeatable_read_only_verified': True, 'actual_write_rejected': True,
                       'fixture_unchanged_after_rejected_write': True, 'actual_database_rename_reverified': True,
                       'same_database_oid_before_and_after_rename': True, 'fixture_cleanup_requested': True}
            Path(__file__).with_name('postgres-smoke-result.json').write_text(json.dumps(receipt, indent=2) + '\n')
            print(json.dumps(receipt))
    finally:
        real_run(['docker', 'rm', '-f', container_id], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


if __name__ == '__main__':
    main()
