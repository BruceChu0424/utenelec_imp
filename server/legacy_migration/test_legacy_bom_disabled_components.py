"""Real PostgreSQL importer tests with V903's exact guard on TEMP fixtures.

No migration or business table is changed. The guard is installed in pg_temp,
every fixture table shadows its application namesake, and all DML rolls back.
"""
from pathlib import Path
import re
import subprocess
import unittest

import compose_bootstrap


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LOADER = (HERE / "migrate_goods_bom.sql").read_text(encoding="utf-8")
V903 = (ROOT / "server/src/main/resources/db/migration/V903__disabled_goods_bom_retirement.sql").read_text(encoding="utf-8")
GUARD = re.search(r"CREATE OR REPLACE FUNCTION guard_goods_bom_operational_goods\(\).*?END \$\$;", V903, re.S).group()
GUARD = GUARD.replace("FUNCTION guard_goods_bom_operational_goods()", "FUNCTION pg_temp.guard_goods_bom_operational_goods()", 1)
FIXTURE = """
BEGIN;
CREATE TEMP TABLE goods(id uuid default gen_random_uuid(),legacy_id int unique,status text,
 is_deleted boolean default false,auto_created boolean default false);
CREATE TEMP TABLE colors(id uuid,legacy_id int);
CREATE TEMP TABLE suppliers(id uuid,legacy_id int);
CREATE TEMP TABLE goods_bom_items(id uuid default gen_random_uuid(),legacy_id int,goods_id uuid,component_goods_id uuid,
 color_legacy_id int,qty numeric NOT NULL,price numeric,total numeric,vend_legacy_id int,summary text,
 color_id uuid,default_supplier_id uuid,bom_status boolean,sstatus boolean,sort_order bigint,
 is_deleted boolean default false,deleted_at timestamptz,updated_at timestamptz);
INSERT INTO goods(legacy_id,status,is_deleted,auto_created) VALUES
 (1,'使用',false,false),(2,'禁用',false,false),(3,'使用',false,false),(4,'禁用',false,false),
 (5,'使用',true,false),(6,'使用',false,true),(7,NULL,false,false);
"""
STAGE_ROWS = """INSERT INTO bom_stage VALUES
 (101,1,3,0,2,3,6,0,'usable',false,false),
 (102,2,3,0,4,5,20,0,'disabled parent retained',false,false),
 (103,1,4,0,1.25,8,10,0,'disabled component',false,false),
 (104,2,4,0,2,7,14,0,'both disabled',false,false),
 (105,1,4,0,0,NULL,NULL,0,'qty reason first',false,false),
 (106,999,4,0,1,1,1,0,'missing parent',false,false),
 (107,1,5,0,1,1,1,0,'deleted child',false,false),
 (108,1,6,0,1,1,1,0,'historical anchor',false,false),
 (109,1,999,0,NULL,NULL,NULL,0,'undefined quantity',false,false),
 (110,1,3,0,-1,1,-1,0,'negative quantity',false,false),
 (111,1,7,0,0.5,2,1,0,'not explicitly disabled',false,false);
"""


class LegacyBomDisabledComponentsPostgresTest(unittest.TestCase):
    def run_fixture(self, rows=STAGE_ROWS, *, error=None):
        loader = re.sub(r"^\\copy bom_stage.*$", lambda match: rows, LOADER, flags=re.MULTILINE)
        assertions = """
DO $$ DECLARE blocked boolean:=false; BEGIN
 IF (SELECT count(*) FROM goods_bom_items)<>3
 OR (SELECT count(*) FROM bootstrap_bom_exclusions)<>8
 OR (SELECT count(*) FROM bootstrap_bom_exclusions WHERE reason='EXCLUDED_DISABLED_COMPONENT')<>2
 OR (SELECT count(*) FROM bootstrap_bom_exclusions WHERE reason='EXCLUDED_NON_OPERATIONAL_MASTER')<>3
 OR (SELECT count(*) FROM bootstrap_bom_exclusions WHERE reason='EXCLUDED_NON_POSITIVE_QTY')<>3
 OR NOT EXISTS(SELECT 1 FROM goods_bom_items edge JOIN goods parent ON parent.id=edge.goods_id
     WHERE parent.legacy_id=2 AND edge.legacy_id=102 AND edge.qty=4 AND edge.total=20)
 OR NOT EXISTS(SELECT 1 FROM bootstrap_bom_exclusions WHERE source_legacy_id=103
     AND source_qty=1.25 AND source_price=8 AND source_total=10)
 OR NOT EXISTS(SELECT 1 FROM bootstrap_bom_exclusions WHERE source_legacy_id=109
     AND source_qty IS NULL AND reason='EXCLUDED_NON_POSITIVE_QTY')
 OR EXISTS(SELECT 1 FROM goods_bom_items edge JOIN goods child ON child.id=edge.component_goods_id WHERE child.status='禁用')
 THEN RAISE EXCEPTION 'legacy disabled-component source/exclusion facts do not reconcile'; END IF;
 BEGIN
   INSERT INTO goods_bom_items(goods_id,component_goods_id,qty)
   SELECT parent.id,child.id,1 FROM goods parent,goods child WHERE parent.legacy_id=1 AND child.legacy_id=4;
 EXCEPTION WHEN check_violation THEN blocked:=true;
 END;
 IF NOT blocked THEN RAISE EXCEPTION 'V903 disabled-component guard was bypassed'; END IF;
END; $$;
ROLLBACK;
"""
        trigger = "CREATE TRIGGER temp_v903_guard BEFORE INSERT OR UPDATE ON goods_bom_items FOR EACH ROW EXECUTE FUNCTION pg_temp.guard_goods_bom_operational_goods();"
        result = subprocess.run(["docker", "exec", "-i", "uten-imp-postgres", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "uten", "-d", "uten_imp"],
                                input=(FIXTURE + GUARD + trigger + loader + assertions).encode("utf-8"),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        diagnostics = result.stderr.decode("utf-8", errors="replace")
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, diagnostics)
        else:
            self.assertEqual(result.returncode, 0, diagnostics)

    def test_disabled_components_are_excluded_with_quantities_and_disabled_parent_recipe_is_preserved(self):
        self.run_fixture()

    def test_duplicate_source_edge_identity_is_rejected(self):
        self.run_fixture(STAGE_ROWS + "INSERT INTO bom_stage SELECT * FROM bom_stage WHERE legacy_id=101;",
                         error="one non-null unique source identity")

    def test_loader_remains_accepted_by_transaction_composition_guard(self):
        self.assertIn(b"EXCLUDED_DISABLED_COMPONENT", compose_bootstrap.compose(LOADER.encode("utf-8"), "migrate_goods_bom.sql"))


if __name__ == "__main__":
    unittest.main()
