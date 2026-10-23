"""Adversarial movement acceptance in an owned network-none PostgreSQL.

No application database or environment file is read. Business names are TEMP
fixtures and every case rolls back. The original stock-balance tests can reuse
this owned fixture through the validation runner without changing those tests.
"""
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

import compose_bootstrap

HERE = Path(__file__).resolve().parent
CHECK = (HERE/'migrate_rehearsal_stock_movement_checks.sql').read_text(encoding='utf-8')
FINAL = (HERE/'migrate_rehearsal_stock_movement_summary.sql').read_text(encoding='utf-8')
FIXTURE = """
BEGIN;
SET LOCAL uten.bootstrap_run_id='00000000-0000-4000-8000-000000000099';
CREATE TEMP TABLE legacy_migration_runs(run_id uuid,status text,migration_mode text,reconciliation_summary jsonb);
CREATE TEMP TABLE legacy_migration_run_files(run_id uuid,file_name text,sha256 char(64));
CREATE TEMP TABLE warehouses(id uuid,code text,is_deleted boolean);
CREATE TEMP TABLE goods(id uuid,legacy_id int,unit_id uuid,owning_warehouse_id uuid);
CREATE TEMP TABLE colors(id uuid,legacy_id int);
CREATE TEMP TABLE units(id uuid,legacy_id int);
CREATE TEMP TABLE warehouse_target_stage(legacy_id int,action text,warehouse_id uuid);
CREATE TEMP TABLE bootstrap_warehouse_exclusions(source_file text,source_row_id text,legacy_warehouse_id int,reason text,goods_legacy_id int,qty numeric,amount numeric);
CREATE TEMP TABLE doc_stage(legacy_id int,doc_type text,bill_date date,status int,stock_legacy_id int,to_stock_legacy_id int);
CREATE TEMP TABLE item_stage(legacy_id int,bill_legacy_id int,doc_type text,goods_legacy_id int,color_legacy_id int,
 unit_legacy_id int,qty numeric(18,4),unit_rate numeric(18,6),amount numeric(18,4),surplus_qty numeric(18,4));
CREATE TEMP TABLE stock_documents(id uuid,legacy_id int,doc_type text,bill_date date,status int,warehouse_id uuid,to_warehouse_id uuid);
CREATE TEMP TABLE stock_document_items(id uuid,legacy_id int,bill_type text,doc_id uuid,goods_id uuid,color_id uuid,unit_id uuid,
 warehouse_id uuid,qty numeric,unit_rate numeric,base_qty numeric,amount_original numeric,amount_local numeric);
CREATE TEMP TABLE stock_movements(transaction_date timestamptz,movement_type smallint,source_doc_type text,source_doc_id uuid,
 source_item_id uuid,goods_id uuid,color_id uuid,warehouse_id uuid,direction smallint,qty numeric,unit_id uuid,unit_rate numeric,amount_local numeric);
INSERT INTO legacy_migration_runs VALUES('00000000-0000-4000-8000-000000000099','RUNNING','BOOTSTRAP','{"unrelatedEvidence":true}');
INSERT INTO warehouses SELECT ('30000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,lpad(n::text,3,'0'),false FROM generate_series(1,3)n;
INSERT INTO warehouse_target_stage VALUES
 (132,'SPLIT','30000000-0000-4000-8000-000000000001'),(126,'KEEP','30000000-0000-4000-8000-000000000003'),(131,'DROP',NULL);
INSERT INTO units VALUES('90000000-0000-4000-8000-000000000001',1);
INSERT INTO colors VALUES('20000000-0000-4000-8000-000000000345',345);
INSERT INTO goods SELECT ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,n,
 '90000000-0000-4000-8000-000000000001',('30000000-0000-4000-8000-'||lpad((n+1)::text,12,'0'))::uuid FROM generate_series(1,2)n;
INSERT INTO doc_stage VALUES
 (1,'OTHER_IN','2026-07-01',1,126,0),(2,'DRAW','2026-07-01',1,132,0),(3,'TRANSFER','2026-07-01',1,126,132),
 (4,'CHECK','2026-07-01',1,126,0),(5,'CHECK','2026-07-01',1,126,0),
 (6,'OTHER_OUT','2026-07-01',1,126,0),(7,'FINISHED_IN','2026-07-01',-1,126,0),(8,'OTHER_IN','2026-07-01',1,131,0);
INSERT INTO item_stage VALUES
 (1,1,'OTHER_IN',1,0,1,1,1,10,NULL),(2,2,'DRAW',1,0,1,2.5,1,25,NULL),(3,3,'TRANSFER',1,345,1,3,1,30,NULL),
 (4,4,'CHECK',2,0,1,0,1,0,-2),(5,5,'CHECK',1,0,1,-1,1,0,1),
 (6,6,'OTHER_OUT',1,0,1,0,1,7,NULL),(7,7,'FINISHED_IN',2,0,1,-1,1,-4,NULL),(8,8,'OTHER_IN',1,0,1,4,1,4,NULL);
INSERT INTO bootstrap_warehouse_exclusions VALUES('stock_other_in_i.csv','8',131,'DROPPED_WAREHOUSE_DOCUMENT',1,4,4);
INSERT INTO legacy_migration_run_files
 SELECT '00000000-0000-4000-8000-000000000099','stock_'||lower(doc_type)||'_i.csv',repeat('a',64) FROM doc_stage GROUP BY doc_type;
INSERT INTO stock_documents
 SELECT ('40000000-0000-4000-8000-'||lpad(d.legacy_id::text,12,'0'))::uuid,d.legacy_id,d.doc_type,d.bill_date,d.status,w.warehouse_id,t.warehouse_id
 FROM doc_stage d LEFT JOIN warehouse_target_stage w ON w.legacy_id=d.stock_legacy_id
 LEFT JOIN warehouse_target_stage t ON t.legacy_id=NULLIF(d.to_stock_legacy_id,0) WHERE d.legacy_id<>8;
INSERT INTO stock_document_items
 SELECT ('50000000-0000-4000-8000-'||lpad(i.legacy_id::text,12,'0'))::uuid,i.legacy_id,i.doc_type,d.id,g.id,c.id,u.id,
 CASE WHEN i.legacy_id IN(2,3) THEN '30000000-0000-4000-8000-000000000002'::uuid END,
 i.qty,i.unit_rate,round(i.qty*i.unit_rate,4),i.amount,i.amount
 FROM item_stage i JOIN stock_documents d ON d.legacy_id=i.bill_legacy_id AND d.doc_type=i.doc_type
 JOIN goods g ON g.legacy_id=i.goods_legacy_id LEFT JOIN colors c ON c.legacy_id=NULLIF(i.color_legacy_id,0)
 LEFT JOIN units u ON u.legacy_id=i.unit_legacy_id;
INSERT INTO stock_movements
 SELECT d.bill_date::timestamptz,CASE i.legacy_id WHEN 1 THEN 11 ELSE 5 END,'STOCK_DOC',d.id,i.id,i.goods_id,i.color_id,
 COALESCE(i.warehouse_id,d.warehouse_id),CASE i.legacy_id WHEN 1 THEN 1 ELSE -1 END,i.base_qty,i.unit_id,i.unit_rate,i.amount_local
 FROM stock_document_items i JOIN stock_documents d ON d.id=i.doc_id WHERE i.legacy_id IN(1,2);
INSERT INTO stock_movements
 SELECT d.bill_date::timestamptz,e.mt,'STOCK_DOC',d.id,i.id,i.goods_id,i.color_id,e.wh,e.dir,i.base_qty,i.unit_id,i.unit_rate,NULL
 FROM stock_document_items i JOIN stock_documents d ON d.id=i.doc_id
 CROSS JOIN(VALUES(8::smallint,(-1)::smallint,'30000000-0000-4000-8000-000000000003'::uuid),
 (7::smallint,1::smallint,'30000000-0000-4000-8000-000000000002'::uuid))e(mt,dir,wh) WHERE i.legacy_id=3;
INSERT INTO stock_movements
 SELECT d.bill_date::timestamptz,CASE i.legacy_id WHEN 4 THEN 10 ELSE 9 END,'STOCK_DOC',d.id,i.id,i.goods_id,i.color_id,d.warehouse_id,
 CASE i.legacy_id WHEN 4 THEN -1 ELSE 1 END,CASE i.legacy_id WHEN 4 THEN 2 ELSE 1 END,i.unit_id,i.unit_rate,NULL
 FROM stock_document_items i JOIN stock_documents d ON d.id=i.doc_id WHERE i.legacy_id IN(4,5);
"""


class StockMovementChecksPostgresTest(unittest.TestCase):
    fixture_container = None
    owns_container = False

    @classmethod
    def setUpClass(cls):
        cls.real_run = staticmethod(subprocess.run)
        if cls.fixture_container is None:
            name='uten-stock-ledger-tests-'+uuid.uuid4().hex
            cls.fixture_container=cls.real_run(['docker','run','--rm','-d','--network','none','--name',name,
                '-e','POSTGRES_USER=uten','-e','POSTGRES_PASSWORD=fixture-only','-e','POSTGRES_DB=uten_imp','postgres:16-alpine'],
                check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE).stdout.decode().strip()
            cls.owns_container=True
        try:
            mode=cls.real_run(['docker','inspect','--format','{{.HostConfig.NetworkMode}}',cls.fixture_container],
                check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE).stdout.decode().strip()
            if mode!='none': raise RuntimeError('Stock tests require an owned network-none PostgreSQL')
            for _ in range(80):
                if cls.real_run(['docker','exec',cls.fixture_container,'pg_isready','-h','127.0.0.1','-U','uten','-d','uten_imp'],
                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0: break
                time.sleep(.25)
            else: raise RuntimeError('Owned PostgreSQL did not become ready')
            sql="""CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE OR REPLACE FUNCTION fn_warehouse_root_id() RETURNS uuid LANGUAGE sql IMMUTABLE AS $$SELECT '30000000-0000-4000-8000-000000000001'::uuid$$;
CREATE OR REPLACE FUNCTION fn_warehouse_is_good_stock_leaf(p uuid) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$SELECT COALESCE(p IN('30000000-0000-4000-8000-000000000002'::uuid,'30000000-0000-4000-8000-000000000003'::uuid),false)$$;
CREATE OR REPLACE FUNCTION fn_weight_unit_kg_factor(p_code text) RETURNS numeric LANGUAGE sql IMMUTABLE STRICT AS $$SELECT CASE p_code WHEN 'G' THEN .001 WHEN 'KG' THEN 1 WHEN 'T' THEN 1000 WHEN 'JIN' THEN .5 WHEN 'LB' THEN .45359237 WHEN 'OZ' THEN .028349523125 END::numeric$$;"""
            result=cls.real_run(['docker','exec','-i',cls.fixture_container,'psql','-X','-q','-v','ON_ERROR_STOP=1','-U','uten','-d','uten_imp'],
                input=sql.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            if result.returncode: raise RuntimeError('Owned fixture function setup failed')
        except BaseException:
            cls.tearDownClass();raise

    @classmethod
    def tearDownClass(cls):
        if cls.owns_container and cls.fixture_container:
            cls.real_run(['docker','rm','-f',cls.fixture_container],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            cls.fixture_container=None;cls.owns_container=False

    def run_case(self,before='',after='',error=None,final=True,assertions='',expected_zero=1,expected_events=6):
        verify="""DO $$DECLARE j jsonb;BEGIN SELECT reconciliation_summary INTO j FROM legacy_migration_runs;
IF j->>'unrelatedEvidence' IS DISTINCT FROM 'true' OR j#>>'{stockMovementChecks,passed}' IS DISTINCT FROM 'true'
 OR (j#>>'{stockMovementChecks,nonpostingItems}')::int<>%d OR (j#>>'{stockMovementChecks,matchedMovements}')::int<>%d
 THEN RAISE EXCEPTION 'invalid stock movement summary'; END IF; END;$$;"""
        verify=verify%(expected_zero,expected_events)
        sql=FIXTURE+before+CHECK+verify+after+(FINAL if final else '')+assertions+'\nROLLBACK;'
        result=self.real_run(['docker','exec','-i',self.fixture_container,'psql','-X','-q','-v','ON_ERROR_STOP=1','-U','uten','-d','uten_imp'],
            input=sql.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        stderr=result.stderr.decode(errors='replace')
        if error is None: self.assertEqual(result.returncode,0,stderr)
        else: self.assertNotEqual(result.returncode,0);self.assertIn(error,stderr)

    def test_source_ledger_zero_money_and_check_surplus_conserved(self):
        self.run_case(assertions="""DO $$DECLARE j jsonb;BEGIN SELECT reconciliation_summary->'stockMovementChecks' INTO j FROM legacy_migration_runs;
IF j->>'entriesPersisted'<>'true' OR jsonb_array_length(j->'entries')<>1 OR (j#>>'{entries,0,amount_local}')::numeric<>7
 OR j#>>'{entries,0,reason}'<>'NONPOSTING_ZERO_QUANTITY' THEN RAISE EXCEPTION 'source nonposting amount or identity lost'; END IF;END;$$;""")

    def test_both_sql_helpers_pass_composition_and_temp_is_preserved(self):
        self.assertIn('bootstrap_stock_movement_nonposting',compose_bootstrap.PRESERVED_TEMP_TABLES)
        for name in ('migrate_rehearsal_stock_movement_checks.sql','migrate_rehearsal_stock_movement_summary.sql'):
            self.assertIn(b'stock',compose_bootstrap.compose((HERE/name).read_bytes(),name))

    def test_quantities_swapped_between_keys_fail(self):
        self.run_case(before='UPDATE stock_movements SET qty=qty+CASE WHEN movement_type=11 THEN 1 WHEN movement_type=5 THEN -1 ELSE 0 END;',error='ledger differs')

    def test_amounts_swapped_despite_same_total_fail(self):
        self.run_case(before='UPDATE stock_movements SET amount_local=amount_local+CASE WHEN movement_type=11 THEN 1 WHEN movement_type=5 THEN -1 ELSE 0 END;',error='ledger differs')

    def test_direction_tamper_fails(self): self.run_case(before='UPDATE stock_movements SET direction=-direction WHERE movement_type=11;',error='ledger differs')
    def test_warehouse_tamper_fails(self): self.run_case(before="UPDATE stock_movements SET warehouse_id='30000000-0000-4000-8000-000000000003' WHERE movement_type=5;",error='ledger differs')
    def test_missing_event_fails(self): self.run_case(before='DELETE FROM stock_movements WHERE movement_type=5;',error='ledger differs')
    def test_duplicate_null_color_event_fails(self): self.run_case(before='INSERT INTO stock_movements SELECT * FROM stock_movements WHERE movement_type=11;',error='ledger differs')
    def test_zero_item_fake_movement_fails(self): self.run_case(before="INSERT INTO stock_movements SELECT d.bill_date::timestamptz,12,'STOCK_DOC',d.id,i.id,i.goods_id,i.color_id,d.warehouse_id,-1,0,i.unit_id,i.unit_rate,i.amount_local FROM stock_document_items i JOIN stock_documents d ON d.id=i.doc_id WHERE i.legacy_id=6;",error='ledger differs')
    def test_zero_item_is_not_deleted(self): self.run_case(before='DELETE FROM stock_document_items WHERE legacy_id=6;',error='facts changed or disappeared')
    def test_zero_item_amount_is_not_truncated(self): self.run_case(before='UPDATE stock_document_items SET amount_original=0,amount_local=0 WHERE legacy_id=6;',error='facts changed or disappeared')
    def test_changed_source_rate_or_base_is_not_accepted(self): self.run_case(before='UPDATE stock_document_items SET unit_rate=2 WHERE legacy_id=2;',error='facts changed or disappeared')
    def test_eligible_negative_source_is_rejected_without_abs(self):
        self.run_case(before="UPDATE item_stage SET qty=-2.5 WHERE legacy_id=2; UPDATE stock_document_items SET qty=-2.5,base_qty=-2.5 WHERE legacy_id=2;",error='negative original base quantity')
    def test_check_zero_and_negative_base_still_post_signed_surplus(self): self.run_case()
    def test_recorded_null_rate_is_kept_and_existing_effective_one_is_checked(self):
        self.run_case(before='UPDATE item_stage SET unit_rate=NULL WHERE legacy_id=6;',assertions="DO $$BEGIN IF (SELECT reconciliation_summary#>>'{stockMovementChecks,entries,0,unit_rate}' FROM legacy_migration_runs) IS NOT NULL THEN RAISE EXCEPTION 'original null rate changed'; END IF; END;$$;")
    def test_nonposting_zero_amount_and_unknown_amount_are_preserved(self):
        for value in ('0','NULL'):
            with self.subTest(value=value): self.run_case(before=f'UPDATE item_stage SET amount={value} WHERE legacy_id=6; UPDATE stock_document_items SET amount_original={value},amount_local={value} WHERE legacy_id=6;')
    def test_new_source_with_no_nonposting_rows_finalizes_an_empty_array(self):
        self.run_case(before="""UPDATE item_stage SET qty=1 WHERE legacy_id=6;
UPDATE stock_document_items SET qty=1,base_qty=1 WHERE legacy_id=6;
INSERT INTO stock_movements SELECT d.bill_date::timestamptz,12,'STOCK_DOC',d.id,i.id,i.goods_id,i.color_id,d.warehouse_id,-1,1,i.unit_id,i.unit_rate,i.amount_local
FROM stock_document_items i JOIN stock_documents d ON d.id=i.doc_id WHERE i.legacy_id=6;""",expected_zero=0,expected_events=7,
            assertions="DO $$BEGIN IF (SELECT jsonb_array_length(reconciliation_summary#>'{stockMovementChecks,entries}') FROM legacy_migration_runs)<>0 THEN RAISE EXCEPTION 'empty source pending inventory was invented'; END IF; END;$$;")
    def test_recorded_positive_quantity_rounding_to_zero_keeps_exact_original_facts(self):
        self.run_case(before='UPDATE item_stage SET qty=.0001,unit_rate=.000001 WHERE legacy_id=6; UPDATE stock_document_items SET qty=.0001,unit_rate=.000001,base_qty=0 WHERE legacy_id=6;')
    def test_source_type_scoped_identity_duplicates_fail(self): self.run_case(before='INSERT INTO item_stage SELECT * FROM item_stage WHERE legacy_id=6;',error='duplicate type-scoped')
    def test_false_exclusion_plus_removed_target_does_not_hide_source_loss(self):
        self.run_case(before="INSERT INTO bootstrap_warehouse_exclusions VALUES('stock_other_out_i.csv','6',126,'UNASSIGNED_OWNING_WAREHOUSE',1,0,7); DELETE FROM stock_document_items WHERE legacy_id=6;",error='exclusions differ')
    def test_missing_source_exclusion_fails(self): self.run_case(before='DELETE FROM bootstrap_warehouse_exclusions;',error='exclusions differ')
    def test_changed_source_exclusion_amount_fails(self): self.run_case(before='UPDATE bootstrap_warehouse_exclusions SET amount=5;',error='exclusions differ')
    def test_later_pending_fact_tamper_fails(self): self.run_case(after='UPDATE bootstrap_stock_movement_nonposting SET amount_local=8;',error='source facts changed')
    def test_later_pending_item_tamper_fails(self): self.run_case(after='UPDATE stock_document_items SET amount_local=8 WHERE legacy_id=6;',error='source facts changed')
    def test_later_source_file_sha_tamper_fails(self): self.run_case(after="UPDATE legacy_migration_run_files SET sha256=repeat('b',64) WHERE file_name='stock_other_out_i.csv';",error='source facts changed')
    def test_later_pending_delete_fails(self): self.run_case(after='DELETE FROM bootstrap_stock_movement_nonposting;',error='source summary or event count')
    def test_pending_survives_other_staging_cleanup(self):
        self.run_case(after='DROP TABLE item_stage,doc_stage,warehouse_target_stage,bootstrap_warehouse_exclusions,rehearsal_stock_movement_source,rehearsal_stock_movement_expected,rehearsal_stock_movement_actual;')
    def test_entries_are_not_stored_in_hot_summary_before_final_module(self):
        self.run_case(final=False,assertions="DO $$BEGIN IF (SELECT reconciliation_summary#>'{stockMovementChecks,entries}' FROM legacy_migration_runs) IS NOT NULL THEN RAISE EXCEPTION 'large entries flushed before proof registrations finished'; END IF; END;$$;")


class StockMovementCompositionTest(unittest.TestCase):
    def test_source_validators_run_before_stock_cleanup_and_pending_flush_runs_last(self):
        import rehearse_local_import as importer
        self.assertEqual(importer.MODULES[-1],'migrate_rehearsal_stock_movement_summary.sql')
        self.assertGreater(importer.MODULES.index(importer.MODULES[-1]),importer.MODULES.index('migrate_rehearsal_code_sequences.sql'))
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary)
            for name in importer.MODULES: (directory/name).write_bytes(b'SELECT 1;\n')
            (directory/'migrate_rehearsal_stock_checks.sql').write_bytes(b'-- BALANCE_CHECK_UNCHANGED\nSELECT 1;\n')
            (directory/'migrate_rehearsal_stock_movement_checks.sql').write_bytes(b'-- MOVEMENT_SOURCE_CHECK\nSELECT 1;\n')
            with patch.object(importer,'HERE',directory): modules=dict(importer.executable_modules(directory))
            self.assertIn(b'BALANCE_CHECK_UNCHANGED',modules['migrate_stock_docs.sql'])
            self.assertIn(b'MOVEMENT_SOURCE_CHECK',modules['migrate_stock_docs.sql'])
            self.assertLess(modules['migrate_stock_docs.sql'].index(b'BALANCE_CHECK_UNCHANGED'),modules['migrate_stock_docs.sql'].index(b'MOVEMENT_SOURCE_CHECK'))


if __name__=='__main__':unittest.main()
