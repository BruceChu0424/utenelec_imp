"""Real PostgreSQL adversarial checks using rollback-only temporary fixtures.

Every business table name is shadowed by a TEMP table before any fixture DML.
The stock-check SQL cannot alter the real application's data in these tests.
Requires the local uten-imp-postgres container; no packages or credentials read.
"""
from pathlib import Path
import subprocess
import unittest

import compose_bootstrap


SQL_FILE = Path(__file__).with_name("migrate_rehearsal_stock_checks.sql")
CHECK_SQL = SQL_FILE.read_text(encoding="utf-8")
FIXTURE = """
BEGIN;
SET LOCAL uten.bootstrap_run_id='00000000-0000-4000-8000-000000000099';
CREATE TEMP TABLE legacy_migration_runs(run_id uuid,status text,migration_mode text,reconciliation_summary jsonb);
CREATE TEMP TABLE goods(id uuid,legacy_id int,unit_id uuid);
CREATE TEMP TABLE colors(id uuid,legacy_id int);
CREATE TEMP TABLE unit_measurement_profiles(unit_id uuid,measurement_dimension text,mass_unit_code text);
CREATE TEMP TABLE stock_balances(warehouse_id uuid,goods_id uuid,color_id uuid,qty numeric,
 amount_local numeric,weight numeric,weight_estimated boolean);
CREATE TEMP TABLE legacy_latest_balance_stage(stock_legacy int,goods_legacy int,color_legacy int,year int,fact_qty numeric,total numeric);
CREATE TEMP TABLE latest_stock_balance_stage(warehouse_id uuid,goods_id uuid,color_id uuid,year int,fact_qty numeric,total numeric);
CREATE TEMP TABLE warehouse_target_stage(legacy_id int,action text,warehouse_id uuid);
CREATE TEMP TABLE goods_split_warehouse_stage(goods_legacy_id int,warehouse_id uuid);
CREATE TEMP TABLE bootstrap_warehouse_exclusions(source_file text,source_row_id text,legacy_warehouse_id int,
 reason text,goods_legacy_id int,qty numeric,amount numeric);
INSERT INTO legacy_migration_runs VALUES ('00000000-0000-4000-8000-000000000099','RUNNING','BOOTSTRAP','{"existingEvidence":true}');
INSERT INTO goods SELECT ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,n,
 CASE WHEN n=1 THEN '90000000-0000-4000-8000-000000000001'::uuid ELSE NULL END FROM generate_series(1,5) n;
INSERT INTO colors VALUES ('20000000-0000-4000-8000-000000000345',345);
INSERT INTO unit_measurement_profiles VALUES ('90000000-0000-4000-8000-000000000001','MASS','KG');
INSERT INTO warehouse_target_stage VALUES
 (132,'SPLIT','30000000-0000-4000-8000-000000000001'),
 (123,'MERGE','30000000-0000-4000-8000-000000000002'),
 (126,'KEEP','30000000-0000-4000-8000-000000000003'),(131,'DROP',NULL);
INSERT INTO goods_split_warehouse_stage VALUES
 (1,'30000000-0000-4000-8000-000000000002'),(2,'30000000-0000-4000-8000-000000000003'),
 (3,NULL),(4,'30000000-0000-4000-8000-000000000003'),(5,'30000000-0000-4000-8000-000000000003');
INSERT INTO legacy_latest_balance_stage VALUES
 (132,1,0,2026,2.5,25),(123,1,0,2026,1.5,15),(126,2,345,2026,-3,-9),
 (131,2,0,2026,-10,-50),(132,3,0,2026,7,21),(126,4,0,2026,0,12),(126,5,0,2026,0,0);
INSERT INTO latest_stock_balance_stage VALUES
 ('30000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',NULL,2026,4,40),
 ('30000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000345',2026,-3,-9),
 ('30000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000004',NULL,2026,0,12),
 ('30000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000005',NULL,2026,0,0);
INSERT INTO stock_balances VALUES
 ('30000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',NULL,4,40,4,FALSE),
 ('30000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000345',-3,-9,NULL,FALSE);
INSERT INTO bootstrap_warehouse_exclusions VALUES
 ('stock_goods.csv','{"stock_legacy":131,"goods_legacy":2,"color_legacy":0,"year":2026}',131,'DROPPED_WAREHOUSE_BALANCE',2,-10,-50),
 ('stock_goods.csv','{"stock_legacy":132,"goods_legacy":3,"color_legacy":0,"year":2026}',132,'UNASSIGNED_OWNING_WAREHOUSE',3,7,21);
"""


class RehearsalStockChecksPostgresTest(unittest.TestCase):
    def run_sql(self, mutation="", *, expected_error=None):
        assertions = """
DO $$ DECLARE summary jsonb; BEGIN
 SELECT reconciliation_summary INTO summary FROM legacy_migration_runs;
 IF summary->>'existingEvidence'<>'true'
 OR summary#>>'{stockBalanceChecks,passed}'<>'true'
 OR (summary#>>'{stockBalanceChecks,matchedNonzeroKeys}')::int<>2
 OR (summary#>>'{stockBalanceChecks,matchedNoColorKeys}')::int<>1
 OR (summary#>>'{stockBalanceChecks,negativeBalanceKeys}')::int<>1
 OR (summary#>>'{stockBalanceChecks,massUnitWeightKeys}')::int<>1
 OR (summary#>>'{stockBalanceChecks,sourceAmountChecksum}')::numeric<>14
 OR (summary#>>'{stockBalanceChecks,retainedAmountChecksum}')::numeric<>31
 OR (summary#>>'{stockBalanceChecks,excludedAmountChecksum}')::numeric<>-29
 OR (summary#>>'{stockBalanceChecks,zeroQuantityAmountChecksum}')::numeric<>12
 OR jsonb_array_length(summary#>'{stockBalanceChecks,exclusionsByReason}')<>2
 THEN RAISE EXCEPTION 'incorrect stock validation summary'; END IF;
END; $$;
ROLLBACK;
"""
        result = subprocess.run(["docker", "exec", "-i", "uten-imp-postgres", "psql", "-X", "-q",
                                 "-v", "ON_ERROR_STOP=1", "-U", "uten", "-d", "uten_imp"],
                                input=(FIXTURE + mutation + CHECK_SQL + assertions).encode("utf-8"),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        error = result.stderr.decode("utf-8", errors="replace")
        if expected_error is None:
            self.assertEqual(result.returncode, 0, error)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected_error, error)

    def test_clean_balances_null_color_exclusions_and_known_weight_pass(self):
        self.run_sql()

    def test_cross_key_quantity_swap_fails_despite_same_total(self):
        self.run_sql("UPDATE stock_balances SET qty=qty+CASE WHEN qty>0 THEN 1 ELSE -1 END;",
                     expected_error="signed quantities or amounts")

    def test_cross_key_amount_swap_fails_despite_same_total(self):
        self.run_sql("UPDATE stock_balances SET amount_local=amount_local+CASE WHEN qty>0 THEN 1 ELSE -1 END;",
                     expected_error="signed quantities or amounts")

    def test_missing_key_fails(self):
        self.run_sql("DELETE FROM stock_balances WHERE qty<0;", expected_error="signed quantities or amounts")

    def test_extra_zero_key_fails(self):
        self.run_sql("INSERT INTO stock_balances SELECT warehouse_id,goods_id,color_id,0,total,NULL,FALSE "
                     "FROM latest_stock_balance_stage WHERE goods_id='10000000-0000-4000-8000-000000000004';",
                     expected_error="signed quantities or amounts")

    def test_duplicate_null_color_key_fails(self):
        self.run_sql("INSERT INTO stock_balances SELECT * FROM stock_balances WHERE color_id IS NULL;",
                     expected_error="duplicate dimensions")

    def test_loader_stage_tampering_fails_independent_reconstruction(self):
        self.run_sql("UPDATE latest_stock_balance_stage SET total=999 WHERE fact_qty>0;",
                     expected_error="independently resolved source facts")

    def test_missing_exclusion_fails(self):
        self.run_sql("DELETE FROM bootstrap_warehouse_exclusions WHERE legacy_warehouse_id=131;",
                     expected_error="exclusions omit, duplicate or change")

    def test_duplicate_exclusion_fails(self):
        self.run_sql("INSERT INTO bootstrap_warehouse_exclusions SELECT * FROM bootstrap_warehouse_exclusions;",
                     expected_error="exclusions omit, duplicate or change")

    def test_exclusion_changed_color_fails(self):
        self.run_sql("UPDATE bootstrap_warehouse_exclusions SET source_row_id="
                     "jsonb_set(source_row_id::jsonb,'{color_legacy}','345')::text WHERE legacy_warehouse_id=131;",
                     expected_error="exclusions omit, duplicate or change")

    def test_weight_without_mass_evidence_is_not_invented(self):
        self.run_sql("UPDATE stock_balances SET weight=1 WHERE qty<0;", expected_error="invents unknown weight")

    def test_mass_unit_weight_mismatch_fails(self):
        self.run_sql("UPDATE stock_balances SET weight=99 WHERE qty>0;", expected_error="governed mass-unit evidence")

    def test_estimated_weight_is_not_accepted_as_exact(self):
        self.run_sql("UPDATE stock_balances SET weight_estimated=TRUE WHERE qty>0;",
                     expected_error="governed mass-unit evidence")

    def test_source_nonzero_color_without_identity_fails(self):
        self.run_sql("DELETE FROM colors;", expected_error="unresolved source or target dimension")

    def test_validator_is_accepted_by_composition_guard(self):
        self.assertIn(b"stock-dimension-facts-v1", compose_bootstrap.compose(SQL_FILE.read_bytes(), SQL_FILE.name))


if __name__ == "__main__":
    unittest.main()
