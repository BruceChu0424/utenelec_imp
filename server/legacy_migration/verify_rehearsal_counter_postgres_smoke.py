"""Actual counter verifier SQL and fail-closed mutations, disposable network-none PG."""
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid
from unittest.mock import patch

import verify_rehearsal_result as verifier
from test_verify_rehearsal_result import RUN


def main():
    real_run = subprocess.run
    name = 'uten-counter-verifier-' + uuid.uuid4().hex
    owned = real_run(['docker', 'run', '--rm', '-d', '--network', 'none', '--name', name,
                      '-e', 'POSTGRES_USER=uten', '-e', 'POSTGRES_PASSWORD=fixture-only', '-e', 'POSTGRES_DB=verifier',
                      'postgres:16-alpine'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()
    cases = []
    try:
        for _ in range(60):
            # Only the final server listens on TCP; the initialization server is socket-only.
            if real_run(['docker', 'exec', owned, 'pg_isready', '-h', '127.0.0.1', '-U', 'uten', '-d', 'verifier'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0: break
            time.sleep(.25)
        else: raise RuntimeError('Disposable PostgreSQL was not ready')

        def write_fixture(sql):
            result = real_run(['docker', 'exec', '-i', owned, 'psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'uten', '-d', 'verifier'], input=sql.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode: raise RuntimeError('Disposable counter fixture failed; details withheld')

        setup = """CREATE EXTENSION pgcrypto;
CREATE TABLE legacy_quantity_counter_import_sources(id uuid DEFAULT gen_random_uuid(),run_id uuid,source_kind text,source_legacy_id integer,target_table text,target_id uuid,source_file text,source_file_sha256 text,target_fields text[],target_snapshot_sha256 text);
CREATE FUNCTION fn_legacy_quantity_counter_bound_fields(text) RETURNS text[] LANGUAGE sql AS $$SELECT ARRAY['id','legacy_id','legacy_counter_import_run_id','qty','received_qty','returned_qty','shipped_qty']::text[]$$;
CREATE FUNCTION fn_legacy_finance_snapshot(j jsonb,f text[]) RETURNS jsonb LANGUAGE sql AS $$SELECT jsonb_object_agg(key,value) FROM jsonb_each(j) WHERE key=ANY(f)$$;
CREATE TABLE purchase_receipt_items(legacy_import_run_id uuid,qty numeric,returned_qty numeric);
"""
        sources = {}; baseline_insert = ''
        for number, (kind, table) in enumerate(verifier.COUNTER_SOURCES, 1):
            setup += 'CREATE TABLE ' + table + '(id uuid PRIMARY KEY,legacy_id integer,legacy_counter_import_run_id uuid,qty numeric,received_qty numeric,returned_qty numeric,shipped_qty numeric);\n'
            sources[kind] = {'rows': 1, 'source_file': table + '.csv', 'target_table': table, 'file_sha256': 'a' * 64,
                             'source_ids_sha256': hashlib.sha256((str(number) + '\n').encode()).hexdigest()}
            baseline_insert += "INSERT INTO %s VALUES(gen_random_uuid(),%s,'%s',10,20,1,20);\n" % (table, number, RUN)
            baseline_insert += "INSERT INTO legacy_quantity_counter_import_sources(run_id,source_kind,source_legacy_id,target_table,target_id,source_file,source_file_sha256,target_fields,target_snapshot_sha256) SELECT '%s','%s',legacy_id,'%s',id,'%s','%s',fn_legacy_quantity_counter_bound_fields('%s'),encode(digest(fn_legacy_finance_snapshot(to_jsonb(t),fn_legacy_quantity_counter_bound_fields('%s'))::text,'sha256'),'hex') FROM %s t;\n" % (RUN, kind, table, table + '.csv', 'a' * 64, kind, kind, table)
        write_fixture(setup)

        def redirected(argv, **kwargs):
            assert argv[:4] == ['docker', 'exec', '-i', 'uten-imp-postgres']
            argv = argv.copy(); argv[3] = owned
            return real_run(argv, **kwargs)

        with patch.object(verifier.subprocess, 'run', side_effect=redirected):
            db = verifier.ReadOnlyDatabase('verifier')
            write_fixture(baseline_insert)
            query = verifier.counter_baseline_sql(RUN, sources) + ';'
            verifier.validate_counter_baseline(db.query(query), sources); cases.append('valid_full_projection')
            mutations = {
                'changed_quantity': 'UPDATE purchase_order_items SET qty=11;',
                'null_target_run': 'UPDATE sales_order_items SET legacy_counter_import_run_id=NULL;',
                'wrong_target_run': "UPDATE sales_shipment_items SET legacy_counter_import_run_id=gen_random_uuid();",
                'missing_target': 'DELETE FROM sales_order_items;',
                'shortened_field_array': "UPDATE legacy_quantity_counter_import_sources SET target_fields=ARRAY['id'] WHERE source_kind='PURCHASE_ORDER_ITEM';",
                'wrong_file_sha': "UPDATE legacy_quantity_counter_import_sources SET source_file_sha256=repeat('b',64) WHERE source_kind='SALES_ORDER_ITEM';",
                'wrong_source_id': "UPDATE legacy_quantity_counter_import_sources SET source_legacy_id=777 WHERE source_kind='SALES_ORDER_ITEM';",
                'wrong_proof_run': "UPDATE legacy_quantity_counter_import_sources SET run_id=gen_random_uuid() WHERE source_kind='SALES_SHIPMENT_ITEM';",
                'extra_proof': 'INSERT INTO legacy_quantity_counter_import_sources SELECT * FROM legacy_quantity_counter_import_sources LIMIT 1;',
                'wrong_route': "UPDATE legacy_quantity_counter_import_sources SET source_kind='UNKNOWN' WHERE source_kind='SALES_ORDER_ITEM';",
            }
            for label, mutation in mutations.items():
                write_fixture('TRUNCATE purchase_order_items,sales_order_items,sales_shipment_items,legacy_quantity_counter_import_sources;\n' + baseline_insert + mutation)
                try: verifier.validate_counter_baseline(db.query(query), sources)
                except verifier.VerificationError: cases.append(label + '_rejected')
                else: raise AssertionError('Counter verifier accepted mutation ' + label)
        receipt = {'status': 'PASSED', 'isolated_network_none_postgresql': True, 'business_database_access': False,
                   'cases': cases, 'historical_review_is_finance_approval': False}
        Path(__file__).with_name('counter-postgres-smoke-result.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt))
    finally:
        real_run(['docker', 'rm', '-f', owned], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


if __name__ == '__main__': main()
