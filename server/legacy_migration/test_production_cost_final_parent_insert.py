"""Production cost import keeps its exact projection without business-row updates."""
from pathlib import Path
import re
import subprocess
import time
import unittest
import uuid

import compose_bootstrap

HERE=Path(__file__).resolve().parent
LOADER=(HERE/'migrate_production.sql').read_text(encoding='utf-8')
PREPARED=LOADER[LOADER.index('CREATE TEMP TABLE cost_prepared AS'):LOADER.index('-- 5b.')]
INSERT=LOADER[LOADER.index('DO $$',LOADER.index('-- 5b.')):LOADER.index('-- ======================== 6.')]


class ProductionCostFinalParentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container='uten-cost-parent-'+uuid.uuid4().hex[:12]
        subprocess.run(['docker','run','--detach','--network','none','--name',cls.container,
                        '-e','POSTGRES_PASSWORD=isolated-contract-only','postgres:16-alpine'],check=True,capture_output=True)
        for _ in range(120):
            # The image's initialization server exposes only a temporary Unix
            # socket. TCP readiness identifies the final server, not that phase.
            if subprocess.run(['docker','exec',cls.container,'pg_isready','-h','127.0.0.1','-U','postgres','-d','postgres'],capture_output=True).returncode==0:return
            time.sleep(.25)
        subprocess.run(['docker','rm','--force',cls.container],capture_output=True)
        raise RuntimeError('Private PostgreSQL fixture did not start')

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['docker','rm','--force',cls.container],check=True,capture_output=True)

    def test_full_projection_parent_edges_and_guards_without_second_business_update(self):
        compose_bootstrap.compose(LOADER.encode(),'migrate_production.sql')
        stages='\n'.join(re.search(r'CREATE TEMP TABLE '+name+r'\s*\(.*?\);',LOADER,re.S).group()
                         for name in ('plan_stage','item_stage','cost_stage'))
        setup='''BEGIN;
CREATE TEMP TABLE goods(id uuid DEFAULT gen_random_uuid(),legacy_id int);
CREATE TEMP TABLE colors(LIKE goods INCLUDING DEFAULTS);
CREATE TEMP TABLE suppliers(LIKE goods INCLUDING DEFAULTS);
CREATE TEMP TABLE sales_order_cost_items(LIKE goods INCLUDING DEFAULTS);
CREATE TEMP TABLE production_plan_items(LIKE goods INCLUDING DEFAULTS);
'''+stages+'''
INSERT INTO goods(legacy_id) VALUES(501),(502);
INSERT INTO colors(legacy_id) VALUES(9);
INSERT INTO suppliers(legacy_id) VALUES(88);
INSERT INTO sales_order_cost_items(legacy_id) VALUES(77);
INSERT INTO plan_stage(legacy_id,bill_no,bill_date) VALUES
 (1,'H2018','2018-12-31'),(2,'H2019','2019-01-01'),(3,'H1970','1970-01-01'),(4,'H2033','2033-06-01');
INSERT INTO item_stage(legacy_id,plan_legacy_id) VALUES(101,1),(102,2),(103,3),(104,4);
INSERT INTO production_plan_items(legacy_id) VALUES(101),(102),(103),(104);
INSERT INTO cost_stage(legacy_id,bill_item_legacy_id,parent_legacy_id,goods_legacy_id,color_legacy_id,mgoods_legacy_id,mcolor_legacy_id,
 supplier_legacy_id,soc_item_legacy_id,qty,price,total,summary,source_doc_no)
 SELECT n,line,parent,501,9,502,9,88,77,CASE WHEN n=3 THEN -12.3456 ELSE 12.3456 END,-0.1250,-1.5432,'original source text','SOURCE:5'
 FROM (VALUES (1,101,0),(2,101,1),(3,101,2),(4,102,0),(5,102,4),
              (6,102,1),(7,102,99999),(8,99999,0),(9,103,8),(10,104,0),(11,104,10)) s(n,line,parent);
'''
        target='''
CREATE TEMP TABLE production_plan_costs(LIKE cost_prepared INCLUDING DEFAULTS);
ALTER TABLE production_plan_costs ADD PRIMARY KEY(id),ADD UNIQUE(legacy_id),
 ADD FOREIGN KEY(parent_id) REFERENCES production_plan_costs(id),ALTER COLUMN bill_item_id SET NOT NULL;
CREATE TEMP TABLE actual_writes(operation text);
CREATE FUNCTION pg_temp.record_cost_write() RETURNS trigger LANGUAGE plpgsql AS $$
 BEGIN INSERT INTO actual_writes VALUES(TG_OP);RETURN NEW;END $$;
CREATE TRIGGER cost_write_guard AFTER INSERT OR UPDATE ON production_plan_costs
 FOR EACH ROW EXECUTE FUNCTION pg_temp.record_cost_write();
'''
        assertions='''
DO $$ BEGIN
 IF (SELECT count(*) FROM production_plan_costs)<>10 THEN RAISE EXCEPTION 'source disposition differs';END IF;
 IF EXISTS(SELECT 1 FROM production_plan_costs actual JOIN cost_prepared expected USING(legacy_id)
           WHERE to_jsonb(actual)-'parent_id' IS DISTINCT FROM to_jsonb(expected)-'parent_id')
 THEN RAISE EXCEPTION 'a complete original business projection changed';END IF;
 IF EXISTS(SELECT 1 FROM production_plan_costs actual LEFT JOIN production_plan_costs parent
           ON parent.legacy_id=actual.parent_legacy_id AND parent.bill_date=actual.bill_date
           WHERE actual.parent_id IS DISTINCT FROM parent.id)
 THEN RAISE EXCEPTION 'parent graph differs from original final-update semantics';END IF;
 IF EXISTS(SELECT 1 FROM actual_writes WHERE operation='UPDATE')
 THEN RAISE EXCEPTION 'business rows were updated a second time';END IF;
 IF (SELECT count(*) FROM actual_writes WHERE operation='INSERT')<>10
 THEN RAISE EXCEPTION 'normal insert guards did not see every source row';END IF;
 IF (SELECT count(*) FROM production_plan_costs WHERE parent_id IS NOT NULL)<>4
 THEN RAISE EXCEPTION 'valid parent edges were lost';END IF;
END $$;
ROLLBACK;
'''
        result=subprocess.run(['docker','exec','-i','-e','PGPASSWORD=isolated-contract-only',self.container,
                               'psql','-h','127.0.0.1','-d','postgres','-X','-q','-v','ON_ERROR_STOP=1','-U','postgres'],
                              input=(setup+PREPARED+target+INSERT+assertions).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))


if __name__=='__main__':unittest.main()
