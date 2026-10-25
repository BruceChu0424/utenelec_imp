"""Owned PostgreSQL fixture for V926; never connects a host/Main/company DB.

Run with Python 3 and Docker: python -m unittest <this file>.  The fixture has
no published ports/network and an explicit random ownership label.  It checks
real separate LOGIN sessions, including SECURITY DEFINER and SET ROLE paths.
"""
from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import time
import unittest
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[3]
MIGRATION = ROOT / "src/main/resources/db/migration/V926__imported_business_documents_archive_only.sql"
LEGACY = "00000000-0000-0000-0000-000000000001"
NATIVE = "00000000-0000-0000-0000-000000000002"
CHILD = "00000000-0000-0000-0000-000000000003"
NATIVE_CHILD = "00000000-0000-0000-0000-000000000004"
RUN_ONLY = "00000000-0000-0000-0000-000000000005"
STOCK_DOC = "00000000-0000-0000-0000-000000000006"
GOOD = "00000000-0000-0000-0000-000000000007"
BALANCE = "00000000-0000-0000-0000-000000000008"
CURRENT_RECEIPT = "00000000-0000-0000-0000-000000000009"
LEGACY_ORDER_ITEM = "00000000-0000-0000-0000-000000000010"
CURRENT_ORDER_ITEM = "00000000-0000-0000-0000-000000000011"
LEGACY_FLOW = "00000000-0000-0000-0000-000000000013"
LEGACY_RECEIPT = "00000000-0000-0000-0000-000000000014"
LEGACY_RECEIPT_ITEM = "00000000-0000-0000-0000-000000000015"
NATIVE_RECEIPT_ITEM = "00000000-0000-0000-0000-000000000016"
OLD_IQC = "00000000-0000-0000-0000-000000000030"
NATIVE_IQC = "00000000-0000-0000-0000-000000000031"
OLD_PAYMENT_PROOF = "00000000-0000-0000-0000-000000000032"
NATIVE_PAYMENT_PROOF = "00000000-0000-0000-0000-000000000033"
OLD_FQC = "00000000-0000-0000-0000-000000000034"
NATIVE_FQC = "00000000-0000-0000-0000-000000000035"


class ImportedBusinessArchivePostgresTest(unittest.TestCase):
    token = uuid.uuid4().hex
    container = None
    docker = shutil.which("docker")

    @classmethod
    def command(cls, *args, input_text=None, check=True):
        return subprocess.run([cls.docker, *args], input=input_text, text=True,
                              capture_output=True, encoding="utf-8", check=check)

    @classmethod
    def sql(cls, text, user="uten_migrator", check=True):
        return cls.command("exec", "-i", cls.container, "psql", "-X", "-q", "-A", "-t",
                           "-v", "ON_ERROR_STOP=1", "-U", user, "-d", "uten_archive_fixture",
                           input_text="\\set VERBOSITY verbose\n" + text, check=check)

    @classmethod
    def setUpClass(cls):
        if not cls.docker:
            raise unittest.SkipTest("Docker is required for the owned PostgreSQL fixture")
        image = cls.command("image", "inspect", "postgres:16-alpine", check=False)
        if image.returncode:
            raise unittest.SkipTest("The official postgres:16-alpine fixture image is unavailable")
        created = cls.command("run", "--detach", "--network", "none",
                              "--tmpfs", "/var/lib/postgresql/data:rw,size=512m",
                              "--label", "uten.archive-guard-fixture=" + cls.token,
                              "--env", "POSTGRES_PASSWORD=owned-archive-fixture-only",
                              "--env", "POSTGRES_DB=uten_archive_fixture", "postgres:16-alpine")
        cls.container = created.stdout.strip()
        try:
            for _ in range(60):
                ready = cls.command("exec", cls.container, "pg_isready", "-U", "postgres", check=False)
                if ready.returncode == 0:
                    break
                time.sleep(.25)
            else:
                raise RuntimeError("Owned PostgreSQL fixture did not become ready")
            cls.sql("""
                CREATE ROLE uten LOGIN NOSUPERUSER PASSWORD 'runtime-fixture-only';
                CREATE ROLE uten_migrator LOGIN NOSUPERUSER PASSWORD 'owner-fixture-only';
                ALTER DATABASE uten_archive_fixture OWNER TO uten_migrator;
                GRANT CREATE ON SCHEMA public TO uten_migrator;
                """, user="postgres")
            cls.sql("""
                CREATE TABLE sales_orders(id uuid PRIMARY KEY,legacy_id int,legacy_import_run_id uuid,
                    status smallint,qty numeric,amount numeric,remark text);
                CREATE TABLE sales_order_items(id uuid PRIMARY KEY,order_id uuid REFERENCES sales_orders(id),
                    legacy_id int,qty numeric,extra_columns jsonb DEFAULT '[]');
                CREATE TABLE sales_order_cost_items(id uuid PRIMARY KEY,item_id uuid REFERENCES sales_order_items(id),qty numeric);
                CREATE TABLE purchase_orders(id uuid PRIMARY KEY,legacy_id int);
                CREATE TABLE purchase_order_items(id uuid PRIMARY KEY,order_id uuid REFERENCES purchase_orders(id));
                CREATE TABLE purchase_receipts(id uuid PRIMARY KEY,legacy_id int);
                CREATE TABLE purchase_receipt_items(id uuid PRIMARY KEY,receipt_id uuid REFERENCES purchase_receipts(id),
                    order_item_id uuid REFERENCES purchase_order_items(id),qty numeric);
                CREATE TABLE procurement_inspection_items(id uuid PRIMARY KEY,receipt_type text,receipt_id uuid,receipt_item_id uuid,qty numeric);
                CREATE TABLE procurement_inspection_events(id uuid PRIMARY KEY,item_id uuid REFERENCES procurement_inspection_items(id),qty numeric);
                CREATE TABLE procurement_order_approval_cases(id uuid PRIMARY KEY,order_type text,order_id uuid,order_item_id uuid,status text);
                CREATE TABLE procurement_iqc_rejection_cases(id uuid PRIMARY KEY,receipt_type text,receipt_id uuid,receipt_item_id uuid);
                CREATE TABLE finance_receipts(id uuid PRIMARY KEY,legacy_import_run_id uuid,amount numeric);
                CREATE TABLE finance_expenses(id uuid PRIMARY KEY,legacy_id int);
                CREATE TABLE expense_claims(id uuid PRIMARY KEY,finance_expense_id uuid REFERENCES finance_expenses(id));
                CREATE TABLE production_daily_reports(id uuid PRIMARY KEY,legacy_id int);
                CREATE TABLE production_fqc_inspections(id uuid PRIMARY KEY,source_report_id uuid REFERENCES production_daily_reports(id));
                CREATE TABLE finance_reconciliations(id uuid PRIMARY KEY,legacy_id int,legacy_import_run_id uuid,
                    source_doc_type text,source_doc_id uuid,reversal_of_id uuid REFERENCES finance_reconciliations(id),amount numeric);
                CREATE TABLE stock_documents(id uuid PRIMARY KEY,legacy_id int);
                CREATE TABLE stock_movements(id uuid PRIMARY KEY,source_doc_type text,source_doc_id uuid,qty numeric);
                CREATE TABLE goods(id uuid PRIMARY KEY,legacy_id int,name text);
                CREATE TABLE goods_bom_items(id uuid PRIMARY KEY,goods_id uuid REFERENCES goods(id),qty numeric);
                CREATE TABLE employees(id uuid PRIMARY KEY,legacy_id int,name text);
                CREATE TABLE warehouses(id uuid PRIMARY KEY,legacy_id int,name text);
                CREATE TABLE stock_balances(id uuid PRIMARY KEY,goods_id uuid REFERENCES goods(id),qty numeric,amount_local numeric);
                CREATE TABLE stock_value_pools(id uuid PRIMARY KEY,legacy_balance_id uuid REFERENCES stock_balances(id),state text);
                CREATE TABLE platform_record_fields(scope text,record_id uuid,source_document_id uuid,cells jsonb,
                    PRIMARY KEY(scope,record_id));
                CREATE TABLE attachments(id uuid PRIMARY KEY,owner_type text,owner_id uuid,name text);
                CREATE TABLE attachment_upload_sessions(id uuid PRIMARY KEY,owner_type text,owner_id uuid,state text);
                CREATE TABLE company_files(id uuid PRIMARY KEY,legacy_id int,title text);
                """)
            cls.sql(MIGRATION.read_text(encoding="utf-8"))
            cls.sql(f"""
                INSERT INTO sales_orders VALUES('{LEGACY}',101,NULL,-1,9,81,'original'),('{NATIVE}',NULL,NULL,0,1,2,'native');
                INSERT INTO sales_order_items VALUES('{CHILD}','{LEGACY}',NULL,9,'[]'),('{NATIVE_CHILD}','{NATIVE}',NULL,1,'[]');
                INSERT INTO sales_order_cost_items VALUES('00000000-0000-0000-0000-000000000012','{CHILD}',9);
                INSERT INTO finance_receipts VALUES('{RUN_ONLY}','11111111-1111-1111-1111-111111111111',81);
                INSERT INTO finance_reconciliations VALUES('{LEGACY_FLOW}',1001,NULL,'RECEIPT','{RUN_ONLY}',NULL,81);
                INSERT INTO stock_documents VALUES('{STOCK_DOC}',42);
                INSERT INTO goods VALUES('{GOOD}',99,'current master');
                INSERT INTO goods_bom_items VALUES('{GOOD}','{GOOD}',3);
                INSERT INTO employees VALUES('{GOOD}',99,'employee');
                INSERT INTO warehouses VALUES('{GOOD}',99,'warehouse');
                INSERT INTO stock_balances VALUES('{BALANCE}','{GOOD}',15,90);
                INSERT INTO stock_value_pools VALUES('{BALANCE}','{BALANCE}','LEGACY_UNVERIFIED');
                INSERT INTO purchase_orders VALUES('{LEGACY}',101),('{NATIVE}',NULL);
                INSERT INTO purchase_order_items VALUES('{LEGACY_ORDER_ITEM}','{LEGACY}'),('{CURRENT_ORDER_ITEM}','{NATIVE}');
                INSERT INTO purchase_receipts VALUES('{CURRENT_RECEIPT}',NULL);
                INSERT INTO purchase_receipts VALUES('{LEGACY_RECEIPT}',102);
                INSERT INTO purchase_receipt_items VALUES('{LEGACY_RECEIPT_ITEM}','{LEGACY_RECEIPT}','{LEGACY_ORDER_ITEM}',9),
                    ('{NATIVE_RECEIPT_ITEM}','{CURRENT_RECEIPT}','{CURRENT_ORDER_ITEM}',1);
                INSERT INTO procurement_iqc_rejection_cases VALUES('{OLD_IQC}','PURCHASE','{LEGACY_RECEIPT}','{LEGACY_RECEIPT_ITEM}'),
                    ('{NATIVE_IQC}','PURCHASE','{CURRENT_RECEIPT}','{NATIVE_RECEIPT_ITEM}');
                INSERT INTO finance_expenses VALUES('{OLD_PAYMENT_PROOF}',99),('{NATIVE_PAYMENT_PROOF}',NULL);
                INSERT INTO expense_claims VALUES('{OLD_PAYMENT_PROOF}','{OLD_PAYMENT_PROOF}'),('{NATIVE_PAYMENT_PROOF}','{NATIVE_PAYMENT_PROOF}');
                INSERT INTO production_daily_reports VALUES('{OLD_FQC}',99),('{NATIVE_FQC}',NULL);
                INSERT INTO production_fqc_inspections VALUES('{OLD_FQC}','{OLD_FQC}'),('{NATIVE_FQC}','{NATIVE_FQC}');
                INSERT INTO company_files VALUES('{GOOD}',99,'current company file');
                ALTER TABLE finance_receipts ADD COLUMN status smallint NOT NULL DEFAULT 0;
                ALTER TABLE finance_receipts ADD COLUMN is_deleted boolean NOT NULL DEFAULT false;
                INSERT INTO finance_receipts(id,legacy_import_run_id,amount)VALUES('00000000-0000-0000-0000-000000000036',NULL,2);
                INSERT INTO procurement_order_approval_cases VALUES('00000000-0000-0000-0000-000000000037','PURCHASE','{LEGACY}',NULL,'PENDING'),
                    ('00000000-0000-0000-0000-000000000038','PURCHASE','{NATIVE}',NULL,'PENDING');
                GRANT USAGE ON SCHEMA public TO uten;
                GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE ON ALL TABLES IN SCHEMA public TO uten;
                CREATE FUNCTION owned_archive_mutator() RETURNS void LANGUAGE sql SECURITY DEFINER
                    SET search_path=pg_catalog,public AS $$UPDATE public.sales_orders SET remark='definer' WHERE legacy_id=101$$;
                GRANT EXECUTE ON FUNCTION owned_archive_mutator() TO uten;
                """)
        except BaseException:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        if cls.container is not None:
            current = cls.command("inspect", cls.container, check=False)
            if current.returncode == 0:
                metadata = json.loads(current.stdout)[0]
                if metadata["Id"] != cls.container or metadata["Config"]["Labels"].get("uten.archive-guard-fixture") != cls.token:
                    raise RuntimeError("Refusing to remove a container outside this exact owned fixture")
                cls.command("rm", "--force", cls.container)
            cls.container = None

    def refused(self, statement):
        result = self.sql(statement, user="uten", check=False)
        self.assertNotEqual(0, result.returncode, statement)
        self.assertIn("55000", result.stderr, result.stderr)
        self.assertIn("imported_business_document_archive_only", result.stderr, result.stderr)

    def test_legacy_header_and_run_only_are_immutable(self):
        for statement in [f"UPDATE sales_orders SET remark='edit' WHERE id='{LEGACY}';",
                          f"UPDATE sales_orders SET status=1 WHERE id='{LEGACY}';",
                          f"UPDATE sales_orders SET legacy_id=NULL,legacy_import_run_id=NULL WHERE id='{LEGACY}';",
                          f"DELETE FROM sales_orders WHERE id='{LEGACY}';",
                          f"UPDATE finance_receipts SET amount=0 WHERE id='{RUN_ONLY}';",
                          "INSERT INTO sales_orders(id,legacy_id,status)VALUES(gen_random_uuid(),999,0);"]:
            with self.subTest(statement=statement): self.refused(statement)
        self.assertEqual("9|81|original", self.sql(f"SELECT qty,amount,remark FROM sales_orders WHERE id='{LEGACY}'").stdout.strip())

    def test_child_reparent_source_and_extra_columns_cannot_bypass(self):
        for statement in [f"UPDATE sales_order_items SET qty=0 WHERE id='{CHILD}';",
                          f"DELETE FROM sales_order_items WHERE id='{CHILD}';",
                          f"UPDATE sales_order_items SET extra_columns='[1]' WHERE id='{CHILD}';",
                          f"UPDATE sales_order_items SET order_id='{NATIVE}' WHERE id='{CHILD}';",
                          f"UPDATE sales_order_items SET order_id='{LEGACY}' WHERE id='{NATIVE_CHILD}';",
                          f"INSERT INTO sales_order_items(id,order_id,qty)VALUES(gen_random_uuid(),'{LEGACY}',1);",
                          "UPDATE sales_order_cost_items SET qty=0;",
                          f"INSERT INTO purchase_receipt_items VALUES(gen_random_uuid(),'{CURRENT_RECEIPT}','{LEGACY_ORDER_ITEM}',1);"]:
            with self.subTest(statement=statement): self.refused(statement)

    def test_polymorphic_fields_attachments_and_movement_source(self):
        for statement in [f"INSERT INTO stock_movements VALUES(gen_random_uuid(),'STOCK_DOC','{STOCK_DOC}',1);",
                          f"INSERT INTO platform_record_fields VALUES('sales_order','{LEGACY}',NULL,'[]');",
                          f"INSERT INTO platform_record_fields VALUES('sales_order_item','{CHILD}',NULL,'[]');",
                          f"INSERT INTO platform_record_fields VALUES('sales_order_item',gen_random_uuid(),'{LEGACY}','[]');",
                          f"INSERT INTO attachments VALUES(gen_random_uuid(),'SALES_ORDER','{LEGACY}','blocked');"]:
            with self.subTest(statement=statement): self.refused(statement)
        self.sql(f"INSERT INTO platform_record_fields VALUES('goods','{GOOD}',NULL,'[]');", user="uten")
        self.sql(f"INSERT INTO attachments VALUES(gen_random_uuid(),'GOODS','{GOOD}','allowed');", user="uten")

    def test_security_definer_and_runtime_set_role_do_not_gain_maintenance(self):
        self.refused("SELECT owned_archive_mutator();")
        self.sql("GRANT uten_migrator TO uten;", user="postgres")
        try:
            self.refused(f"SET ROLE uten_migrator;UPDATE sales_orders SET remark='role' WHERE id='{LEGACY}';")
        finally:
            self.sql("REVOKE uten_migrator FROM uten;", user="postgres")
        self.assertEqual("f", self.sql("SELECT fn_imported_business_document_maintenance_allowed();", user="uten").stdout.strip())

    def test_native_business_master_bom_and_current_stock_stay_writable(self):
        self.sql(f"""
            UPDATE sales_orders SET remark='native edit' WHERE id='{NATIVE}';
            UPDATE sales_order_items SET qty=2 WHERE id='{NATIVE_CHILD}';
            INSERT INTO purchase_receipt_items VALUES(gen_random_uuid(),'{CURRENT_RECEIPT}','{CURRENT_ORDER_ITEM}',1);
            UPDATE goods SET name='changed master' WHERE id='{GOOD}';
            UPDATE employees SET name='changed employee' WHERE id='{GOOD}';
            UPDATE warehouses SET name='changed warehouse' WHERE id='{GOOD}';
            UPDATE goods_bom_items SET qty=4 WHERE id='{GOOD}';
            UPDATE stock_balances SET qty=14,amount_local=84 WHERE id='{BALANCE}';
            UPDATE stock_value_pools SET state='current opening fixture' WHERE id='{BALANCE}';
            """, user="uten")
        guarded = self.sql("""SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
            WHERE t.tgname='trg_00_imported_business_archive_only'
            AND c.relname IN('goods','employees','warehouses','goods_bom_items','stock_balances','stock_value_pools');""").stdout.strip()
        self.assertEqual("0", guarded)

    def test_boolean_lookup_matches_root_child_and_nonbusiness_boundaries(self):
        value = self.sql(f"""SELECT fn_imported_business_document('sales_orders','{LEGACY}'),
            fn_imported_business_document('sales_order_items','{CHILD}'),
            fn_imported_business_document('finance_receipts','{RUN_ONLY}'),
            fn_imported_business_document('sales_orders','{NATIVE}'),
            fn_imported_business_document('goods','{GOOD}'),
            fn_imported_business_document('stock_balances','{BALANCE}');""", user="uten").stdout.strip()
        self.assertEqual("t|t|t|f|f|f", value)
        self.assertEqual("0", self.sql("SELECT count(*) FROM pg_trigger WHERE tgname='trg_00_imported_business_archive_only' AND tgenabled<>'A';").stdout.strip())

    def test_real_non_superuser_owner_can_perform_separate_audited_maintenance(self):
        self.assertEqual("f|t", self.sql("SELECT rolsuper,fn_imported_business_document_maintenance_allowed() FROM pg_roles WHERE rolname=current_user;").stdout.strip())
        self.sql(f"UPDATE sales_orders SET remark='owner maintenance' WHERE id='{LEGACY}';")
        self.sql(f"UPDATE sales_orders SET remark='original' WHERE id='{LEGACY}';")

    def test_runtime_truncate_cannot_bypass_row_guards(self):
        self.refused("TRUNCATE sales_orders CASCADE;")
        self.assertEqual("2", self.sql("SELECT count(*) FROM sales_orders;").stdout.strip())

    def test_real_account_flow_table_and_reversal_source_are_protected(self):
        self.refused(f"UPDATE finance_reconciliations SET amount=0 WHERE id='{LEGACY_FLOW}';")
        self.refused(f"INSERT INTO finance_reconciliations VALUES(gen_random_uuid(),NULL,NULL,NULL,NULL,'{LEGACY_FLOW}',-81);")
        self.refused(f"INSERT INTO finance_reconciliations VALUES(gen_random_uuid(),NULL,NULL,'RECEIPT','{RUN_ONLY}',NULL,81);")
        self.refused(f"INSERT INTO finance_reconciliations VALUES(gen_random_uuid(),NULL,NULL,'RECEIPT_FEE','{RUN_ONLY}',NULL,1);")
        self.assertEqual("t", self.sql(f"SELECT fn_imported_business_document('finance_reconciliations','{LEGACY_FLOW}');",user="uten").stdout.strip())
        self.assertEqual("finance_receipts|finance_receipts|finance_reconciliations",self.sql("SELECT fn_imported_business_document_scope_table('RECEIPT'),fn_imported_business_document_scope_table('DIRECT_RECEIPT'),fn_imported_business_document_scope_table('ACCOUNT_FLOW');",user="uten").stdout.strip())

    def test_actual_shared_procurement_source_pairs_and_fk_descendants(self):
        self.refused(f"INSERT INTO procurement_inspection_items VALUES(gen_random_uuid(),'PURCHASE','{LEGACY_RECEIPT}',NULL,1);")
        self.refused(f"INSERT INTO procurement_inspection_items VALUES(gen_random_uuid(),'PURCHASE','{CURRENT_RECEIPT}','{LEGACY_RECEIPT_ITEM}',1);")
        self.refused(f"INSERT INTO procurement_order_approval_cases VALUES(gen_random_uuid(),'PURCHASE','{LEGACY}',NULL,'PENDING');")
        self.refused(f"INSERT INTO procurement_order_approval_cases VALUES(gen_random_uuid(),'PURCHASE','{NATIVE}','{LEGACY_ORDER_ITEM}','PENDING');")
        native_inspection="00000000-0000-0000-0000-000000000017"
        old_inspection="00000000-0000-0000-0000-000000000018"
        self.sql(f"INSERT INTO procurement_inspection_items VALUES('{old_inspection}','PURCHASE','{LEGACY_RECEIPT}','{LEGACY_RECEIPT_ITEM}',9);")
        self.refused(f"INSERT INTO procurement_inspection_events VALUES(gen_random_uuid(),'{old_inspection}',1);")
        self.sql(f"INSERT INTO procurement_inspection_items VALUES('{native_inspection}','PURCHASE','{CURRENT_RECEIPT}','{NATIVE_RECEIPT_ITEM}',1);",user="uten")
        self.sql(f"INSERT INTO procurement_inspection_events VALUES(gen_random_uuid(),'{native_inspection}',1);",user="uten")
        self.sql(f"INSERT INTO procurement_order_approval_cases VALUES(gen_random_uuid(),'PURCHASE','{NATIVE}','{CURRENT_ORDER_ITEM}','PENDING');",user="uten")

    def test_current_source_subqueries_keep_native_rows_and_lock_semantics(self):
        result=self.sql("""BEGIN;
            SELECT line.id FROM
              (SELECT * FROM sales_orders archive_origin WHERE NOT fn_imported_business_document('sales_orders',archive_origin.id)) document
              JOIN (SELECT * FROM sales_order_items archive_origin WHERE NOT fn_imported_business_document('sales_order_items',archive_origin.id)) line
                ON line.order_id=document.id
            FOR UPDATE OF line,document;
            ROLLBACK;""",user="uten").stdout.strip()
        self.assertEqual(NATIVE_CHILD,result)

    def test_registered_attachment_aliases_follow_real_business_ancestors(self):
        for owner_type,old,current in [
                ('PROCUREMENT_IQC_REJECTION',OLD_IQC,NATIVE_IQC),
                ('EXPENSE_PAYMENT_PROOF',OLD_PAYMENT_PROOF,NATIVE_PAYMENT_PROOF),
                ('PRODUCTION_QUALITY_INSPECTION',OLD_FQC,NATIVE_FQC)]:
            with self.subTest(owner_type=owner_type):
                self.refused(f"INSERT INTO attachments VALUES(gen_random_uuid(),'{owner_type}','{old}','old write');")
                self.refused(f"INSERT INTO attachment_upload_sessions VALUES(gen_random_uuid(),'{owner_type}','{old}','RESERVED');")
                attachment=self.sql(f"INSERT INTO attachments VALUES(gen_random_uuid(),'{owner_type}','{current}','native') RETURNING id;",user="uten").stdout.strip()
                self.sql(f"UPDATE attachments SET name='native changed' WHERE id='{attachment}';DELETE FROM attachments WHERE id='{attachment}';",user="uten")
                old_attachment=self.sql(f"INSERT INTO attachments VALUES(gen_random_uuid(),'{owner_type}','{old}','original') RETURNING id;").stdout.strip()
                self.refused(f"UPDATE attachments SET name='overwrite' WHERE id='{old_attachment}';")
                self.refused(f"DELETE FROM attachments WHERE id='{old_attachment}';")
        for owner_type in ['GOODS','EMPLOYEE','COMPANY_FILE']:
            attachment=self.sql(f"INSERT INTO attachments VALUES(gen_random_uuid(),'{owner_type}','{GOOD}','permitted') RETURNING id;",user="uten").stdout.strip()
            self.sql(f"UPDATE attachments SET name='permitted edit' WHERE id='{attachment}';DELETE FROM attachments WHERE id='{attachment}';",user="uten")

    def test_operational_draft_and_finance_queue_counts_use_actual_provenance(self):
        self.assertEqual('2|1',self.sql("SELECT COUNT(*),COUNT(*) FILTER(WHERE NOT fn_imported_business_document('finance_receipts',o.id)) FROM finance_receipts o WHERE NOT is_deleted AND status=0;",user="uten").stdout.strip())
        cohort="c.id IN('00000000-0000-0000-0000-000000000037','00000000-0000-0000-0000-000000000038')"
        self.assertEqual('1',self.sql("SELECT count(*) FROM procurement_order_approval_cases c WHERE "+cohort+" AND c.status='PENDING' AND NOT fn_imported_business_document('procurement_order_approval_cases',c.id);",user="uten").stdout.strip())
        self.assertEqual('PURCHASE|1',self.sql("SELECT c.order_type,count(*) FROM procurement_order_approval_cases c WHERE "+cohort+" AND c.status='PENDING' AND NOT fn_imported_business_document('procurement_order_approval_cases',c.id) GROUP BY c.order_type;",user="uten").stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
