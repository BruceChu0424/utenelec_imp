"""Exercise V909 acceptance SQL with disposable synthetic PostgreSQL only."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
from unittest.mock import patch

import verify_receipt_order_references as receipt
import verify_rehearsal_result as verifier
from test_verify_rehearsal_result import Fixture, RUN
from test_verify_receipt_order_references import populate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists(): raise ValueError('Refusing to overwrite a prior smoke receipt')
    real_run = subprocess.run
    name = 'uten-receipt-order-verifier-' + uuid.uuid4().hex
    owned = real_run(['docker', 'run', '--rm', '-d', '--network', 'none', '--name', name,
                      '-e', 'POSTGRES_USER=uten', '-e', 'POSTGRES_PASSWORD=fixture-only', '-e', 'POSTGRES_DB=verifier',
                      'postgres:16-alpine'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()
    cases = []
    try:
        for _ in range(60):
            if real_run(['docker', 'exec', owned, 'pg_isready', '-h', '127.0.0.1', '-U', 'uten', '-d', 'verifier'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0: break
            time.sleep(.25)
        else: raise RuntimeError('Disposable PostgreSQL was not ready')

        def write(sql):
            result = real_run(['docker', 'exec', '-i', owned, 'psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'uten', '-d', 'verifier'],
                              input=sql.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                args.output.with_suffix('.stderr.private.log').write_bytes(result.stderr)
                raise RuntimeError('Disposable receipt verifier fixture failed; server details withheld')

        def identity(label): return str(uuid.uuid5(uuid.NAMESPACE_OID, label))
        def literal(value): return "'" + str(value).replace("'", "''") + "'"

        setup = """CREATE EXTENSION pgcrypto;
CREATE TABLE legacy_procurement_receipt_import_sources(id uuid DEFAULT gen_random_uuid(),run_id uuid,source_kind text,source_legacy_id integer,target_table text,target_id uuid,source_file text,source_row_sha256 text,source_file_sha256 text,target_fields text[],target_snapshot_sha256 text);
CREATE FUNCTION fn_legacy_finance_snapshot(j jsonb,f text[]) RETURNS jsonb LANGUAGE sql AS $$SELECT jsonb_object_agg(key,value) FROM jsonb_each(j) WHERE key=ANY(f)$$;
"""
        tables = ['legacy_procurement_receipt_import_sources']
        for kind, table, _, header_table, _, upstream_table, _ in receipt.ROUTES:
            setup += f'CREATE TABLE {header_table}(id uuid PRIMARY KEY,legacy_id integer);\n'
            setup += f'CREATE TABLE {upstream_table}(id uuid PRIMARY KEY,legacy_id integer);\n'
            columns = []
            types = {'id': 'uuid PRIMARY KEY', 'legacy_id': 'integer', 'legacy_import_run_id': 'uuid',
                     'receipt_id': 'uuid', 'order_item_id': 'uuid', 'order_item_legacy_id': 'integer'}
            for field in receipt.COMMON_FIELDS + receipt.EXTRA_FIELDS[kind]: columns.append(field + ' ' + types.get(field, 'text'))
            setup += f'CREATE TABLE {table}(' + ','.join(columns) + ');\n'
            tables += [table, header_table, upstream_table]
        write(setup)
        with tempfile.TemporaryDirectory() as temporary:
            expected = populate(Fixture(Path(temporary)))['receipt_order_sources']
            inserts = ''
            fixtures = {
                'PURCHASE_ITEM': {'headers': [101, 102], 'upstream': [31, 32], 'items': [(11, 101, 31), (12, 101, 99), (13, 102, 0)]},
                'SUBCONTRACT_ITEM': {'headers': [201], 'upstream': [41], 'items': [(21, 201, 41), (22, 201, 88), (23, 201, 0)]},
            }
            for kind, table, source_file, header_table, _, upstream_table, _ in receipt.ROUTES:
                data = fixtures[kind]
                for old in data['headers']:
                    inserts += f'INSERT INTO {header_table} VALUES({literal(identity(header_table+str(old)))},{old});\n'
                for old in data['upstream']:
                    inserts += f'INSERT INTO {upstream_table} VALUES({literal(identity(upstream_table+str(old)))},{old});\n'
                for old, head, upstream in data['items']:
                    target = identity(table+str(old))
                    real_link = literal(identity(upstream_table+str(upstream))) if upstream in data['upstream'] else 'NULL'
                    original = str(upstream) if upstream else 'NULL'
                    inserts += f"INSERT INTO {table}(id,legacy_id,legacy_import_run_id,receipt_id,order_item_id,order_item_legacy_id,qty) VALUES({literal(target)},{old},{literal(RUN)},{literal(identity(header_table+str(head)))},{real_link},{original},'10');\n"
                fields = 'ARRAY[' + ','.join(literal(field) for field in sorted(receipt.COMMON_FIELDS + receipt.EXTRA_FIELDS[kind])) + ']::text[]'
                inserts += f"INSERT INTO legacy_procurement_receipt_import_sources(run_id,source_kind,source_legacy_id,target_table,target_id,source_file,source_row_sha256,source_file_sha256,target_fields,target_snapshot_sha256) SELECT '{RUN}','{kind}',legacy_id,'{table}',id,'{source_file}',repeat('a',64),'{expected[kind]['file_sha256']}',{fields},encode(digest(fn_legacy_finance_snapshot(to_jsonb(t),{fields})::text,'sha256'),'hex') FROM {table} t;\n"

            def redirected(argv, **kwargs):
                assert argv[:4] == ['docker', 'exec', '-i', 'uten-imp-postgres']
                argv = argv.copy(); argv[3] = owned
                return real_run(argv, **kwargs)

            refresh = "UPDATE legacy_procurement_receipt_import_sources p SET target_snapshot_sha256=encode(digest(fn_legacy_finance_snapshot(to_jsonb(t),p.target_fields)::text,'sha256'),'hex') FROM purchase_receipt_items t WHERE p.target_id=t.id;"
            mutations = {
                'changed_new_original_id': 'UPDATE purchase_receipt_items SET order_item_legacy_id=98 WHERE legacy_id=12;',
                'changed_id_and_forged_matching_projection': 'UPDATE purchase_receipt_items SET order_item_legacy_id=98 WHERE legacy_id=12;' + refresh,
                'source_positive_id_cleared': 'UPDATE purchase_receipt_items SET order_item_legacy_id=NULL WHERE legacy_id=12;',
                'illegal_zero_snapshot': 'UPDATE purchase_receipt_items SET order_item_legacy_id=0 WHERE legacy_id=13;',
                'wrong_real_upstream': f"UPDATE purchase_receipt_items SET order_item_id='{identity('purchase_order_items32')}' WHERE legacy_id=11;" + refresh,
                'known_source_upstream_left_null': 'UPDATE purchase_receipt_items SET order_item_id=NULL WHERE legacy_id=11;' + refresh,
                'fabricated_upstream_order': f"INSERT INTO purchase_order_items VALUES('{identity('fabricated99')}',99);",
                'fabricated_upstream_with_forged_matching_proof': f"INSERT INTO purchase_order_items VALUES('{identity('fabricated99')}',99); UPDATE purchase_receipt_items SET order_item_id='{identity('fabricated99')}' WHERE legacy_id=12;" + refresh,
                'missing_target': 'DELETE FROM subcontract_receipt_items WHERE legacy_id=22;',
                'missing_proof': "DELETE FROM legacy_procurement_receipt_import_sources WHERE source_kind='SUBCONTRACT_ITEM' AND source_legacy_id=22;",
                'wrong_target_run': 'UPDATE purchase_receipt_items SET legacy_import_run_id=gen_random_uuid() WHERE legacy_id=11;',
                'wrong_proof_run': "UPDATE legacy_procurement_receipt_import_sources SET run_id=gen_random_uuid() WHERE source_kind='PURCHASE_ITEM' AND source_legacy_id=11;",
                'wrong_proof_route': "UPDATE legacy_procurement_receipt_import_sources SET source_kind='UNKNOWN' WHERE source_kind='PURCHASE_ITEM' AND source_legacy_id=11;",
                'wrong_file_sha': "UPDATE legacy_procurement_receipt_import_sources SET source_file_sha256=repeat('b',64) WHERE source_kind='PURCHASE_ITEM';",
                'invalid_source_row_sha': "UPDATE legacy_procurement_receipt_import_sources SET source_row_sha256='invalid' WHERE source_kind='PURCHASE_ITEM';",
                'shortened_projection_field_array': "UPDATE legacy_procurement_receipt_import_sources SET target_fields=ARRAY['id','legacy_id','order_item_legacy_id'] WHERE source_kind='PURCHASE_ITEM';" + refresh,
                'quantity_changed': "UPDATE purchase_receipt_items SET qty='11' WHERE legacy_id=11;",
                'included_drop_source_header': f"INSERT INTO purchase_receipts VALUES('{identity('dropped103')}',103);",
                'changed_real_receipt_parent': f"UPDATE purchase_receipt_items SET receipt_id='{identity('purchase_receipts102')}' WHERE legacy_id=11;" + refresh,
                'unproved_online_receipt_row': "INSERT INTO purchase_receipt_items(id,qty) VALUES(gen_random_uuid(),'10');",
                'extra_item_proof': "INSERT INTO legacy_procurement_receipt_import_sources SELECT * FROM legacy_procurement_receipt_import_sources LIMIT 1;",
            }
            with patch.object(verifier.subprocess, 'run', side_effect=redirected):
                db = verifier.ReadOnlyDatabase('verifier')
                query = receipt.acceptance_sql(RUN, expected) + ';'
                write(inserts)
                receipt.validate(db.query(query), expected); cases.append('valid_drop_aware_two_family_projection')
                for label, mutation in mutations.items():
                    write('TRUNCATE ' + ','.join(tables) + ';\n' + inserts + mutation)
                    try: receipt.validate(db.query(query), expected)
                    except ValueError: cases.append(label + '_rejected')
                    else: raise AssertionError('Receipt acceptance verifier accepted mutation ' + label)
        result = {'status': 'PASSED', 'isolated_network_none_postgresql': True, 'business_database_access': False,
                  'synthetic_only': True, 'cases': cases, 'guard_semantics_changed': False,
                  'production_guard_full_flyway_test': False}
        with args.output.open('x', encoding='utf-8') as stream:
            stream.write(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))
    finally:
        real_run(['docker', 'rm', '-f', owned], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


if __name__ == '__main__': main()
