"""Real PostgreSQL guards + mapper regression in an always-rolled-back schema.

No public business rows are written. Set UTEN_OWNER_CUSTODY_TEST_DATABASE to a
disposable rehearsal schema host (default the failed retained candidate).
"""
import csv
import io
import json
import os
from pathlib import Path
import re
import subprocess
import unittest
import uuid

import compose_bootstrap

HERE=Path(__file__).resolve().parent
DB=os.environ.get('UTEN_OWNER_CUSTODY_TEST_DATABASE','uten_imp_rehearsal_20261022')


def quoted(value):
    return "'"+str(value).replace("'","''")+"'"


def identity(value):
    return str(uuid.UUID(int=value))


def psql(sql):
    result=subprocess.run(['docker','exec','-i','uten-imp-postgres','psql','-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-U','uten','-d',DB],input=sql.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if result.returncode:
        raise AssertionError(result.stderr.decode('utf-8',errors='replace'))
    return result.stdout.decode('utf-8')


def copy_inline(table,rows):
    stream=io.StringIO()
    writer=csv.writer(stream,delimiter='|',lineterminator='\n')
    if rows:
        writer.writerow(list(rows[0]))
        writer.writerows(row.values() for row in rows)
    return "\\copy "+table+" FROM STDIN WITH (FORMAT csv,DELIMITER '|',HEADER true)\n"+stream.getvalue()+"\\.\n"


def module(name,rows=None):
    sql=compose_bootstrap.compose((HERE/name).read_bytes(),name).decode()
    if rows is not None:
        import re
        sql=re.sub(r"\\copy ([a-z_]+) FROM '/tmp/[^']+' WITH \(FORMAT csv, DELIMITER '\|', HEADER true\)",lambda match:copy_inline(match[1],rows).rstrip(),sql)
    return sql


def stage_fields(name,table):
    body=re.search(r'CREATE TEMP TABLE '+table+r'\s*\((.*?)\);',(HERE/name).read_text(encoding='utf-8'),re.S)[1]
    return [match[1] for line in body.splitlines() if (match:=re.match(r'\s*([a-z_][a-z0-9_]*)\s+(?:int|text|numeric)',line))]


def assert_sql(condition,message):
    return "DO $$ BEGIN IF NOT ("+condition+") THEN RAISE EXCEPTION "+quoted(message)+"; END IF; END $$;\n"


@unittest.skipUnless(os.environ.get('UTEN_RUN_OWNER_CUSTODY_DB_TESTS')=='1','set UTEN_RUN_OWNER_CUSTODY_DB_TESTS=1 for disposable PostgreSQL fixture')
class LegacyOwnerCustodyPostgresTest(unittest.TestCase):
    def test_real_master_guards_and_all_owner_mappers(self):
        schema='owner_fixture_'+uuid.uuid4().hex
        run=identity(900)
        sql="BEGIN;\nCREATE SCHEMA "+schema+";\nSET LOCAL search_path="+schema+",public;\nSET LOCAL app.legacy_import='on';\nSET LOCAL uten.bootstrap_run_id="+quoted(run)+";\n"
        sql+="""CREATE TABLE employees(id uuid,legacy_id int,code text,full_name text,status text,is_deleted boolean,department_id uuid);
CREATE TABLE users(id uuid,employee_id uuid,login_account text,is_super_admin boolean,status text,is_deleted boolean);
CREATE TABLE departments(id uuid,name text);
CREATE TABLE legacy_migration_runs(run_id uuid,status text,started_at timestamptz DEFAULT now(),reconciliation_summary jsonb);
CREATE TABLE clients(LIKE public.clients INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
CREATE TABLE suppliers(LIKE public.suppliers INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
CREATE TABLE goods(LIKE public.goods INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
CREATE TABLE client_categories(id uuid,legacy_id int,is_deleted boolean);
CREATE TABLE supplier_categories(id uuid,legacy_id int,is_deleted boolean);
CREATE TABLE material_categories(id uuid,parent_id uuid,legacy_id int);
CREATE TABLE system_master_category_registry(id uuid,client_category_id uuid,supplier_category_id uuid);
CREATE TABLE settlement_methods(id uuid,legacy_id int,status text,is_deleted boolean);
CREATE TABLE client_default_settlement_migration_issues(LIKE public.client_default_settlement_migration_issues INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
CREATE TABLE category_master_code_sequences(master_type text PRIMARY KEY,last_seq bigint);
"""
        sql+="INSERT INTO legacy_migration_runs VALUES ("+quoted(run)+",'RUNNING',now(),jsonb_build_object('targetDatabase',current_database()));\n"
        for num,lid,status,deleted in [(1,None,'active',False),(2,545,'resigned',False),(3,501,'active',False),(4,502,'probation',False),(5,503,'onLeave',False),(6,504,'active',True),(7,505,'unknown',False),(8,506,'active',False),(9,506,'active',False)]:
            sql+="INSERT INTO employees VALUES ("+quoted(identity(num))+","+(str(lid) if lid else 'NULL')+","+quoted('ADMIN' if num==1 else 'UT'+str(num))+",'fixture',"+quoted(status)+","+str(deleted).lower()+",NULL);\n"
        sql+="INSERT INTO users VALUES ("+quoted(identity(20))+","+quoted(identity(1))+",'17665410007',true,'active',false);\n"
        sql+="INSERT INTO client_categories VALUES ("+quoted(identity(30))+",-1,false); INSERT INTO supplier_categories VALUES ("+quoted(identity(31))+",-1,false);\n"
        sql+="INSERT INTO system_master_category_registry VALUES ('27500000-0000-4000-8000-000000000001',"+quoted(identity(30))+","+quoted(identity(31))+");\n"
        for table in ['clients','suppliers','goods']:
            sql+="CREATE TRIGGER fixture_current_owner BEFORE INSERT OR UPDATE OF owner_employee_id ON "+table+" FOR EACH ROW EXECUTE FUNCTION public.fn_require_current_employee_reference_strict('owner_employee_id');\n"
        sql+="""DO $$ BEGIN
 BEGIN INSERT INTO clients(legacy_id,name,code,owner_employee_id) VALUES (9999,'fixture rejected','bad-owner','00000000-0000-0000-0000-000000000002');
 RAISE EXCEPTION 'strict guard did not reject resigned owner'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
"""
        # Use real staging column order, synthetic values only. This tests the entire
        # first-failure client loader rather than a hand-copied projection.
        client_fields=stage_fields('migrate_client_data.sql','client_stage')
        sources=['545','501','502','503','504','505','999','某人','','0','2147483648','506']
        clients=[]
        for number,source in enumerate(sources,101):
            row=dict.fromkeys(client_fields,'')
            row.update(legacy_id=str(number),parent_legacy='0',name='fixture',code='C'+str(number),emp_id=source,credit='0',init_total='0',init_total2='0',exchange_rate='1',tday='0',status='使用')
            clients.append(row)
        sql+=module('migrate_client_data.sql',clients)
        sql+=assert_sql("(SELECT owner_employee_id FROM clients WHERE legacy_id=101)="+quoted(identity(1))+"::uuid",'retired client owner must be ADMIN')
        for lid,employee in [(102,3),(103,4),(104,5)]:
            sql+=assert_sql("(SELECT owner_employee_id FROM clients WHERE legacy_id="+str(lid)+")="+quoted(identity(employee))+"::uuid",'genuine current employee mapping')
        sql+=assert_sql("(SELECT count(*) FROM clients WHERE legacy_id IN (109,110) AND owner_employee_id IS NULL)=2",'public clients remain public')
        sql+=assert_sql("(SELECT count(*) FROM clients WHERE legacy_id IN (105,106,107,108,111,112) AND owner_employee_id="+quoted(identity(1))+"::uuid)=6",'unavailable source identities stay private with ADMIN')
        sql+=assert_sql("(SELECT emp_id FROM clients WHERE legacy_id=108)='某人'",'never guess or replace raw source actor')
        sql+=assert_sql("(SELECT status FROM employees WHERE legacy_id=545)='resigned'",'retired source employee unchanged')
        supplier_fields=stage_fields('migrate_supplier_data.sql','supplier_stage')
        suppliers=[]
        for number,source in enumerate(['545','501','','unknown'],201):
            row=dict.fromkeys(supplier_fields,'')
            row.update(legacy_id=str(number),parent_legacy='0',name='fixture',code='S'+str(number),emp_id=source,init_total='0',init_total2='0',exchange_rate='1',tday='0',status='使用')
            suppliers.append(row)
        sql+=module('migrate_supplier_data.sql',suppliers)
        sql+=assert_sql("(SELECT count(*) FROM suppliers WHERE legacy_id IN (201,204) AND owner_employee_id="+quoted(identity(1))+"::uuid)=2",'supplier unavailable owners held privately')
        sql+=module('migrate_client_owner.sql')
        sql+=module('migrate_client_owner.sql')
        sql+=assert_sql("(SELECT jsonb_array_length(reconciliation_summary#>'{currentOwnerCustody,migrate_client_data.sql,entries}') FROM legacy_migration_runs)=7",'module evidence survives subsequent mappers')
        sql+="INSERT INTO material_categories VALUES ("+quoted(identity(40))+",NULL,2978),("+quoted(identity(41))+","+quoted(identity(40))+",12345),("+quoted(identity(42))+",NULL,98765);\n"
        sql+="INSERT INTO goods(legacy_id,code,name,category_id,code_sequence) VALUES (301,'G301','fixture',"+quoted(identity(41))+",1),(302,'G302','fixture',"+quoted(identity(42))+",2);\n"
        sql+=module('migrate_goods_owner.sql')
        sql+=assert_sql("(SELECT owner_employee_id FROM goods WHERE legacy_id=301)="+quoted(identity(1))+"::uuid",'private foreign goods owned by retired employee need ADMIN')
        sql+=assert_sql("(SELECT owner_employee_id FROM goods WHERE legacy_id=302) IS NULL",'public goods stay public')
        sql+="""CREATE TABLE sales_orders(id uuid,legacy_id int,seller_legacy_id int,seller_id uuid,owner_employee_id uuid,is_deleted boolean DEFAULT false);
CREATE TABLE sales_shipments(id uuid,legacy_id int,seller_legacy_id int,owner_employee_id uuid,is_deleted boolean DEFAULT false);
CREATE TABLE sales_other_shipments(id uuid,legacy_id int,seller_legacy_id int,owner_employee_id uuid,is_deleted boolean DEFAULT false);
CREATE TABLE sales_returns(id uuid,legacy_id int,seller_legacy_id int,owner_employee_id uuid,is_deleted boolean DEFAULT false);
CREATE TABLE sales_order_items(id uuid,order_id uuid,is_deleted boolean DEFAULT false);
CREATE TABLE sales_shipment_items(id uuid,shipment_id uuid,order_item_id uuid,is_deleted boolean DEFAULT false);
CREATE TABLE sales_return_items(return_id uuid,out_item_id uuid,order_item_id uuid,is_deleted boolean DEFAULT false);
CREATE MATERIALIZED VIEW sales_monthly_mv AS SELECT owner_employee_id,count(*) AS rows FROM sales_orders GROUP BY owner_employee_id;
"""
        for table in ('sales_orders','sales_shipments','sales_other_shipments','sales_returns'):
            sql+="CREATE TRIGGER fixture_sales_current_owner BEFORE INSERT OR UPDATE OF owner_employee_id ON "+table+" FOR EACH ROW EXECUTE FUNCTION public.fn_require_current_employee_reference('owner_employee_id');\n"
        sql+="INSERT INTO sales_orders(id,legacy_id,seller_legacy_id,seller_id) VALUES ("+quoted(identity(401))+",401,545,"+quoted(identity(2))+"),("+quoted(identity(402))+",402,501,"+quoted(identity(3))+");\n"
        sql+="INSERT INTO sales_other_shipments(id,legacy_id,seller_legacy_id) VALUES ("+quoted(identity(403))+",403,545);\n"
        sql+="INSERT INTO sales_shipments(id,legacy_id,seller_legacy_id) VALUES ("+quoted(identity(404))+",404,545),("+quoted(identity(405))+",405,999);\n"
        sql+="INSERT INTO sales_order_items(id,order_id) VALUES ("+quoted(identity(501))+","+quoted(identity(401))+"),("+quoted(identity(502))+","+quoted(identity(402))+");\n"
        sql+="INSERT INTO sales_shipment_items(id,shipment_id,order_item_id) VALUES ("+quoted(identity(503))+","+quoted(identity(404))+","+quoted(identity(501))+"),("+quoted(identity(504))+","+quoted(identity(405))+","+quoted(identity(502))+");\n"
        sql+="INSERT INTO sales_returns(id,legacy_id,seller_legacy_id) VALUES ("+quoted(identity(406))+",406,545),("+quoted(identity(407))+",407,0);\n"
        sql+="INSERT INTO sales_return_items(return_id,out_item_id,order_item_id) VALUES ("+quoted(identity(406))+","+quoted(identity(503))+","+quoted(identity(501))+"),("+quoted(identity(407))+","+quoted(identity(503))+",NULL);\n"
        sql+=module('migrate_sales_owner.sql')
        for table,lid in [('sales_orders',401),('sales_other_shipments',403),('sales_shipments',404),('sales_returns',406),('sales_returns',407)]:
            sql+=assert_sql("(SELECT owner_employee_id FROM "+table+" WHERE legacy_id="+str(lid)+")="+quoted(identity(1))+"::uuid",'unavailable sales ownership and upstream custody stay private')
        sql+=assert_sql("(SELECT owner_employee_id FROM sales_shipments WHERE legacy_id=405)="+quoted(identity(3))+"::uuid",'linked source current owner is inherited')
        sql+=assert_sql("(SELECT seller_id FROM sales_orders WHERE legacy_id=401)="+quoted(identity(2))+"::uuid AND (SELECT seller_legacy_id FROM sales_orders WHERE legacy_id=401)=545",'historical seller UUID and legacy identity remain unchanged')
        sql+=module('migrate_sales_owner.sql')
        sql+=assert_sql("(SELECT jsonb_array_length(reconciliation_summary#>'{currentOwnerCustody,migrate_sales_owner.sql,entries}') FROM legacy_migration_runs)=5",'repeat mapping retains all pending handover evidence')
        # The helper must reject an unavailable/wrong protected administrator.
        sql+="UPDATE users SET is_super_admin=false;\n"
        sql+="DO $$ BEGIN BEGIN PERFORM * FROM pg_temp.legacy_owner_resolution('545'); RAISE EXCEPTION USING ERRCODE='UT999',MESSAGE='missing admin was accepted'; EXCEPTION WHEN SQLSTATE 'P0001' THEN NULL; END; END $$;\nUPDATE users SET is_super_admin=true;\n"
        sql+="SELECT 'OWNER_CUSTODY_FIXTURE_PASSED';\nROLLBACK;\n"
        output=psql(sql)
        self.assertIn('OWNER_CUSTODY_FIXTURE_PASSED',output)
        self.assertEqual('0',psql('SELECT count(*) FROM pg_namespace WHERE nspname='+quoted(schema)+';').strip())


if __name__=='__main__':
    unittest.main()
