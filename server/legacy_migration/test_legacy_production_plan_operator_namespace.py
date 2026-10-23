"""All 15-column production plans and Sys_Operator-only frozen names.

Real PostgreSQL tests use their own temporary Docker container and roll back every
fixture. No application database, source CSV or frozen import layer is changed.
"""
import csv
import io
from pathlib import Path
import re
import subprocess
import time
import unittest
import uuid

import compose_bootstrap

HERE=Path(__file__).resolve().parent
LOADER=(HERE/'migrate_production.sql').read_text(encoding='utf-8-sig')
EXPORTER=(HERE/'export_legacy.ps1').read_text(encoding='utf-8-sig')
PLAN_COLUMNS=['legacy_id','bill_no','bill_date','f_style','delivery_date','workshop_name',
              'worker_name','seller_name','maker_legacy','approver_legacy','remark','status',
              'fulfill_bit','stop_bit','cancel_bit']
STAGING=LOADER[LOADER.index('CREATE TEMP TABLE plan_stage'):LOADER.index('CREATE TEMP TABLE item_stage')]
INSERT=re.search(r'INSERT INTO production_plans\s*\(.*?FROM plan_stage s;',LOADER,re.S).group()


def inline_copy(table,columns,rows):
    data=io.StringIO();writer=csv.writer(data,delimiter='|',lineterminator='\n')
    writer.writerow(columns);writer.writerows(rows)
    return "\\copy "+table+" FROM STDIN WITH (FORMAT csv, DELIMITER '|', HEADER true)\n"+data.getvalue()+"\\."


class ProductionAllColumnContractTest(unittest.TestCase):
    def test_real_all_export_and_initial_copy_have_exact_same_fifteen_columns(self):
        projection=re.search(r"^\$planSql\s*=\s*'SELECT (.*?) FROM F_Plan ORDER BY ID'",EXPORTER,re.M).group(1)
        actual=[re.search(r'\bAS\s+([a-z_]+)$',field.strip(),re.I).group(1) for field in projection.split(',')]
        stage=re.search(r'CREATE TEMP TABLE plan_stage\s*\((.*?)\);',LOADER,re.S).group(1)
        copied=[field.strip().split()[0] for field in stage.split(',')]
        self.assertEqual(actual,PLAN_COLUMNS)
        self.assertEqual(copied,actual)
        self.assertLess(STAGING.index('\\copy plan_stage'),STAGING.index('ADD COLUMN maker_name'))

    def test_only_sys_operator_dictionary_is_used_and_loader_stays_transaction_free(self):
        self.assertIn("FROM '/tmp/legacy_operators_ref.csv'",STAGING)
        executable='\n'.join(line for line in STAGING.splitlines() if not line.lstrip().startswith('--'))
        self.assertNotRegex(executable,r'\b(?:legacy_workers|employees?|worker_ref_stage)\b')
        self.assertNotIn('maker_id',INSERT)
        self.assertNotIn('approver_id',INSERT)
        compose_bootstrap.compose(LOADER.encode('utf-8'),'migrate_production.sql')


class ProductionPlanOperatorPostgresTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container='uten-production-operators-'+uuid.uuid4().hex[:12]
        subprocess.run(['docker','run','--detach','--name',cls.container,'-e',
                        'POSTGRES_PASSWORD=isolated-contract-only','postgres:16-alpine'],
                       check=True,capture_output=True)
        for _ in range(120):
            if subprocess.run(['docker','exec',cls.container,'pg_isready','-U','postgres'],capture_output=True).returncode==0:return
            time.sleep(.25)
        subprocess.run(['docker','rm','--force',cls.container],capture_output=True)
        raise RuntimeError('Private PostgreSQL fixture did not start')

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['docker','rm','--force',cls.container],check=True,capture_output=True)

    def fixture(self,plans,operators,assertions,error=None):
        raw=inline_copy('plan_stage',PLAN_COLUMNS,plans)
        op=inline_copy('production_operator_ref_stage',['legacy_id','name'],operators)
        sql=re.sub(r'^\\copy plan_stage.*$',lambda _:raw,STAGING,flags=re.M)
        sql=re.sub(r'^\\copy production_operator_ref_stage.*$',lambda _:op,sql,flags=re.M)
        fixture="""BEGIN;
CREATE TEMP TABLE production_plans(id uuid DEFAULT gen_random_uuid(),legacy_id int UNIQUE,bill_no text,bill_date date,
f_style text,delivery_date date,workshop_name text,worker_name text,seller_name text,maker_legacy_id int,approver_legacy_id int,
maker_name text,approver_name text,remark text,status smallint,is_closed boolean,is_stopped boolean,is_canceled boolean,
source_daily_report_id uuid,maker_id uuid,approver_id uuid);
CREATE TEMP TABLE employees(id uuid,legacy_id int,full_name text);
INSERT INTO employees VALUES('00000000-0000-4000-8000-000000000001',7,'Wrong worker with same ID'),
('00000000-0000-4000-8000-000000000002',88,'Worker without operator record');
CREATE TEMP TABLE auth_sessions(id uuid);
CREATE TEMP TABLE user_permission_overrides(id uuid);
"""
        body=fixture+sql+'\n'+INSERT+'\n'+assertions+"\nROLLBACK;\n"
        result=subprocess.run(['docker','exec','-i',self.container,'psql','-X','-q','-v','ON_ERROR_STOP=1','-U','postgres'],
                              input=body.encode('utf-8'),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        diagnostics=result.stderr.decode('utf-8',errors='replace')
        if error:
            self.assertNotEqual(result.returncode,0);self.assertIn(error,diagnostics)
        else:self.assertEqual(result.returncode,0,diagnostics)

    @staticmethod
    def plan(identity=101,maker=7,approver=8):
        return [identity,'SOURCE-PLAN-'+str(identity),'2026-07-20','Original mode','2026-07-24',
                '37','Original worker text','Original seller text',maker,approver,'Original historical remark',1,False,True,False]

    def test_operator_worker_collision_uses_operator_and_preserves_original_ids_and_source_fields(self):
        self.fixture([self.plan()],[[7,'Actual operator'],[8,'Actual approver']],"""
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM production_plans WHERE legacy_id=101
 AND maker_legacy_id=7 AND approver_legacy_id=8 AND maker_name='Actual operator' AND approver_name='Actual approver'
 AND worker_name='Original worker text' AND seller_name='Original seller text' AND workshop_name='37'
 AND remark='Original historical remark' AND status=1 AND NOT is_closed AND is_stopped AND NOT is_canceled
 AND maker_id IS NULL AND approver_id IS NULL AND source_daily_report_id IS NULL)
 OR (SELECT count(*) FROM employees)<>2 OR EXISTS(SELECT 1 FROM auth_sessions)
 OR EXISTS(SELECT 1 FROM user_permission_overrides)
 THEN RAISE EXCEPTION 'production source/operator namespace contract differs'; END IF; END $$;
""")

    def test_missing_operator_remains_null_even_when_worker_with_same_id_exists(self):
        self.fixture([self.plan(maker=88,approver=99)],[[7,'Unrelated operator']],"""
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM production_plans WHERE maker_legacy_id=88 AND approver_legacy_id=99
 AND maker_name IS NULL AND approver_name IS NULL AND maker_id IS NULL AND approver_id IS NULL)
 THEN RAISE EXCEPTION 'missing operator guessed a person'; END IF; END $$;
""")

    def test_zero_and_empty_operator_name_do_not_create_identity(self):
        self.fixture([self.plan(maker=0,approver=9)],[[9,'']],"""
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM production_plans WHERE maker_legacy_id=0 AND approver_legacy_id=9
 AND maker_name IS NULL AND approver_name IS NULL AND maker_id IS NULL AND approver_id IS NULL)
 THEN RAISE EXCEPTION 'zero/empty source was invented'; END IF; END $$;
""")

    def test_duplicate_operator_source_identity_fails_instead_of_choosing_first(self):
        self.fixture([self.plan()],[[7,'First'],[7,'Second']],'',error='duplicate key value')

    def test_seventeen_column_standalone_shape_is_rejected_as_not_all_export(self):
        row=self.plan();row[10:10]=['Do not trust separate snippet maker','Do not trust separate snippet approver']
        self.fixture([row],[],'',error='extra data after last expected column')


if __name__=='__main__':unittest.main()
