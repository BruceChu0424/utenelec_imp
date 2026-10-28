"""Synthetic Docker-only PostgreSQL rehearsal. Never reads connection settings or company data."""
import datetime as dt
import json
import os
import re
from pathlib import Path
import subprocess
import time
import unittest
import uuid
from prepare_employee_resigned_duplicate import render,PROTOCOL

HERE=Path(__file__).resolve().parent
MIGRATIONS=HERE.parent/"src/main/resources/db/migration"

@unittest.skipUnless(os.environ.get("UTEN_RUN_DB_TESTS","").lower()=="true","explicit local DB rehearsal only")
class ResignedDuplicatePostgresRehearsal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.name="uten-identity-maint-"+uuid.uuid4().hex[:12]
        subprocess.run(["docker","run","--rm","--detach","--name",cls.name,"-e","POSTGRES_HOST_AUTH_METHOD=trust","postgres:16-alpine"],check=True,capture_output=True,text=True)
        cls.addClassCleanup(lambda:subprocess.run(["docker","stop",cls.name],check=False,capture_output=True,text=True))
        for _ in range(80):
            ready=subprocess.run(["docker","exec",cls.name,"pg_isready","-U","postgres"],capture_output=True)
            if ready.returncode==0:break
            time.sleep(.1)
        else:raise RuntimeError("private synthetic Postgres did not start")
        cls.sql("""
        CREATE EXTENSION pgcrypto;
        CREATE TABLE employees(id uuid PRIMARY KEY,code text UNIQUE,full_name text,id_type text DEFAULT '身份证',
          department_id uuid,supervisor_id uuid,hire_date date DEFAULT DATE '2010-01-01',status text DEFAULT 'resigned',
          is_deleted boolean DEFAULT false,deleted_at timestamptz,version integer DEFAULT 0,
          permission_delegation_generation bigint DEFAULT 0,updated_at timestamptz DEFAULT now(),updated_by uuid);
        CREATE TABLE users(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),employee_id uuid REFERENCES employees(id),is_deleted boolean DEFAULT false);
        CREATE TABLE employee_sensitive(employee_id uuid PRIMARY KEY REFERENCES employees(id),id_card_enc text,id_card_hash text);
        CREATE TABLE employee_education(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),employee_id uuid REFERENCES employees(id),school text);
        CREATE TABLE employment_history(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),employee_id uuid REFERENCES employees(id),event_type text,event_date date);
        CREATE TABLE audit_log(id bigserial PRIMARY KEY,actor_id uuid,target_id text,payload jsonb);
        CREATE TABLE audit_log_archive(LIKE audit_log INCLUDING DEFAULTS);
        CREATE TABLE authorization_state(singleton_id integer PRIMARY KEY,epoch bigint DEFAULT 0,updated_at timestamptz DEFAULT now(),business_dataset_id uuid DEFAULT gen_random_uuid(),business_reset_generation integer DEFAULT 32);
        INSERT INTO authorization_state(singleton_id) VALUES(1);
        CREATE TABLE flyway_schema_history(installed_rank integer,version text,script text,checksum integer,success boolean);
        INSERT INTO flyway_schema_history VALUES(1,'937','V937__verified_employee_identity_aliases.sql',937,true),(2,'947','V947__employee_identity_account_row_lock.sql',947,true);
        CREATE FUNCTION fn_audit_track_table(text,text,text,boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
        CREATE FUNCTION fixture_audit_employee() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN INSERT INTO audit_log(target_id,payload) VALUES(NEW.id::text,jsonb_build_object('fixture','archive'));RETURN NEW;END $$;
        CREATE TRIGGER fixture_employee_audit AFTER UPDATE ON employees FOR EACH ROW EXECUTE FUNCTION fixture_audit_employee();
        CREATE FUNCTION fixture_employee_generation() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN IF NEW.is_deleted IS DISTINCT FROM OLD.is_deleted THEN NEW.permission_delegation_generation:=OLD.permission_delegation_generation+1;END IF;RETURN NEW;END $$;
        CREATE TRIGGER fixture_generation BEFORE UPDATE ON employees FOR EACH ROW EXECUTE FUNCTION fixture_employee_generation();
        """)
        cls.sql((MIGRATIONS/"V937__verified_employee_identity_aliases.sql").read_text(encoding="utf-8"))
        cls.sql((MIGRATIONS/"V947__employee_identity_account_row_lock.sql").read_text(encoding="utf-8"))
        # Use the actual V324 invalidation function, rather than assuming that
        # account-free employees cannot advance the global authorization epoch.
        v324=(MIGRATIONS/"V324__permission_delegation_assignment_scope_and_lock_order.sql").read_text(encoding="utf-8")
        invalidation=re.search(r"CREATE OR REPLACE FUNCTION fn_invalidate_employee_permission_delegations\(\).*?\$\$ LANGUAGE plpgsql;",v324,re.S)
        if invalidation is None:raise AssertionError("reviewed V324 employee invalidation function was not found")
        cls.sql(invalidation.group(0))
        cls.sql("CREATE TRIGGER fixture_actual_v324_epoch AFTER UPDATE ON employees FOR EACH ROW EXECUTE FUNCTION fn_invalidate_employee_permission_delegations()")
        refs={"clients":"owner_employee_id","suppliers":"owner_employee_id","goods":"owner_employee_id","moulds":"keeper_id",
          "departments":"manager_id","inbound_expectations":"owner_employee_id","procurement_arrival_exceptions":"owner_employee_id",
          "supplier_return_tasks":"owner_employee_id","website_inquiries":"assignee_employee_id","visitor_applications":"host_employee_id",
          "rd_tasks":"assignee_employee_id","production_execution_segments":"responsible_employee_id","fixed_assets":"custodian_employee_id",
          "deferred_expenses":"responsible_employee_id","task_claims":"claimed_by","hr_task_claims":"claimed_by","profile_change_requests":"employee_id"}
        for table,column in refs.items():
            cls.sql(f"CREATE TABLE {table}(id uuid DEFAULT gen_random_uuid(),{column} uuid,is_deleted boolean DEFAULT false,status text,lifecycle_status text,planned_visit_at timestamptz,released_at timestamptz)")
        cls.sql("CREATE TABLE production_plans(id uuid DEFAULT gen_random_uuid(),seller_id uuid,worker_id uuid,is_deleted boolean DEFAULT false,status integer)")

    @classmethod
    def sql(cls,sql,*,check=True):
        result=subprocess.run(["docker","exec","-i",cls.name,"psql","-X","-U","postgres","-d","postgres","-qAt","-v","ON_ERROR_STOP=1"],input=sql,text=True,encoding="utf-8",capture_output=True)
        if check and result.returncode:raise AssertionError(result.stderr)
        return result

    def seed_plan(self):
        retained=str(uuid.uuid4());duplicate=str(uuid.uuid4())
        self.sql(f"""INSERT INTO employees(id,code,full_name) VALUES('{retained}','CAN-{retained}','Synthetic review'),('{duplicate}','DUP-{duplicate}','Synthetic review');
          INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_hash) VALUES('{retained}','synthetic-canonical-cipher','synthetic-hash-{retained}'),('{duplicate}','synthetic-duplicate-cipher',NULL);
          INSERT INTO employee_education(employee_id,school) VALUES('{duplicate}','synthetic historical school');
          INSERT INTO employment_history(employee_id,event_type,event_date) VALUES('{duplicate}','onboard',DATE '2010-01-01');
          INSERT INTO audit_log(target_id,payload) VALUES('{duplicate}','{{"fixture":"original"}}');""")
        query="""SELECT jsonb_build_object('database',current_database(),'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
          'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
          'dataset_id',business_dataset_id::text,'generation',business_reset_generation,'migration_max',947,
          'migration_sha256',(SELECT encode(digest(jsonb_agg(jsonb_build_array(version,checksum) ORDER BY installed_rank)::text,'sha256'),'hex') FROM flyway_schema_history WHERE success)) FROM authorization_state WHERE singleton_id=1"""
        database=json.loads(self.sql(query).stdout.strip())
        sensitive={row[0]:row[1] for row in (line.split('|') for line in self.sql(f"SELECT employee_id,encode(digest(to_jsonb(s)::text,'sha256'),'hex') FROM employee_sensitive s WHERE employee_id IN('{retained}','{duplicate}')").stdout.splitlines())}
        return {"protocol":PROTOCOL,"captured_at":dt.datetime.now(dt.timezone.utc).isoformat(),"database_identity":database,
          "canonical":{"employee_id":retained,"code":"CAN-"+retained,"version":0},
          "duplicate":{"employee_id":duplicate,"code":"DUP-"+duplicate,"version":0,"reason":"Synthetic same-document review evidence"},
          "evidence":{"reference":"synthetic-proof","sha256":"a"*64,"canonical_sensitive_sha256":sensitive[retained],"duplicate_sensitive_sha256":sensitive[duplicate],"document_equal":True,"birth_equal":True,"valid_resident_id":True},
          "backup":{"reference":"synthetic-paired-backup","manifest_sha256":"b"*64,"verified":True},"maintenance_actor":"ops:synthetic-only"}

    def test_actual_v937_v947_guards_archive_without_rehire_preserve_and_replay(self):
        plan=self.seed_plan();retained=plan['canonical']['employee_id'];duplicate=plan['duplicate']['employee_id']
        dry=self.sql(render(plan));self.assertIn('APPLIED_IN_TRANSACTION',dry.stdout)
        self.assertEqual('f|0',self.sql(f"SELECT is_deleted,version FROM employees WHERE id='{duplicate}'").stdout.strip())
        before_epoch=int(self.sql('SELECT epoch FROM authorization_state').stdout.strip())
        committed=self.sql(render(plan,commit=True));self.assertIn('"preservation": "passed"',committed.stdout)
        self.assertIn('"authorization_epoch_delta": 2',committed.stdout)
        self.assertEqual(before_epoch+2,int(self.sql('SELECT epoch FROM authorization_state').stdout.strip()))
        self.assertEqual('t|resigned|1',self.sql(f"SELECT is_deleted,status,version FROM employees WHERE id='{duplicate}'").stdout.strip())
        self.assertEqual('f|resigned|0',self.sql(f"SELECT is_deleted,status,version FROM employees WHERE id='{retained}'").stdout.strip())
        self.assertEqual(duplicate,self.sql(f"SELECT employee_id FROM employee_education WHERE employee_id='{duplicate}'").stdout.strip())
        epoch=self.sql('SELECT epoch FROM authorization_state').stdout.strip()
        replay=self.sql(render(plan,commit=True));self.assertIn('ALREADY_APPLIED',replay.stdout)
        self.assertEqual(epoch,self.sql('SELECT epoch FROM authorization_state').stdout.strip())
        self.assertEqual('0',self.sql(f"SELECT count(*) FROM users WHERE employee_id IN('{retained}','{duplicate}')").stdout.strip())

    def test_accounts_responsibilities_and_sensitive_proof_drift_fail_closed(self):
        for failure in ('account','responsibility','sensitive'):
            plan=self.seed_plan();retained=plan['canonical']['employee_id'];duplicate=plan['duplicate']['employee_id']
            if failure=='account':self.sql(f"INSERT INTO users(employee_id) VALUES('{retained}')")
            if failure=='responsibility':self.sql(f"INSERT INTO suppliers(owner_employee_id,is_deleted) VALUES('{duplicate}',false)")
            if failure=='sensitive':self.sql(f"UPDATE employee_sensitive SET id_card_enc='drifted' WHERE employee_id='{duplicate}'")
            result=self.sql(render(plan,commit=True),check=False)
            self.assertNotEqual(0,result.returncode,(failure,result.stdout,result.stderr))
            self.assertEqual('f|0',self.sql(f"SELECT is_deleted,version FROM employees WHERE id='{duplicate}'").stdout.strip())
            self.assertEqual('0',self.sql(f"SELECT count(*) FROM employee_identity_aliases WHERE alias_employee_id='{duplicate}'").stdout.strip())

if __name__=='__main__':unittest.main()
