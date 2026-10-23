import csv
from decimal import Decimal
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

import compose_bootstrap
from validate_legacy_bom_topology import inspect,prepare,quantity,render_sql


def goods(*identities):
    return [dict(legacy_id=str(identity),status='使用') for identity in identities]


def edge(identity,parent,child,qty='1',**extra):
    return dict(legacy_id=str(identity),goods_legacy_id=str(parent),component_legacy_id=str(child),qty=qty,**extra)


class BomTopologyRulesTest(unittest.TestCase):
    def test_diamond_and_isolated_nodes_have_deterministic_graph_hash_and_depth(self):
        source=[edge(1,1,2),edge(2,1,3),edge(3,2,4),edge(4,3,4)]
        result=inspect(goods(1,2,3,4,5),source)
        self.assertTrue(result['summary']['valid'])
        self.assertEqual(4,result['summary']['graph_nodes'])
        self.assertEqual(1,result['summary']['graph_roots'])
        self.assertEqual(2,result['summary']['max_depth_edges'])
        self.assertEqual(1,result['summary']['isolated_operational_master_nodes'])
        self.assertEqual(result['summary']['graph_sha256'],inspect(goods(5,4,3,2,1),list(reversed(source)))['summary']['graph_sha256'])

    def test_precise_filtering_and_conservation_match_loader_precedence(self):
        masters=goods(1,2,3,4,5)
        masters[1]['status']='禁用'
        masters[2]['auto_created']='true'
        masters[3]['is_deleted']='true'
        result=inspect(masters,[edge(1,1,2),edge(2,1,3),edge(3,4,5),edge(4,1,999),edge(5,1,2,'0'),edge(6,2,5)])
        self.assertEqual(1,result['summary']['retained_edges'])  # disabled parent is allowed
        self.assertEqual({'EXCLUDED_DISABLED_COMPONENT':1,'EXCLUDED_NON_OPERATIONAL_MASTER':3,'EXCLUDED_NON_POSITIVE_QTY':1},result['summary']['exclusions_by_reason'])
        self.assertTrue(result['summary']['source_conservation'])

    def test_numeric_precision_is_postgresql_half_away_from_zero(self):
        self.assertEqual(Decimal('0.00000'),quantity('0.000004',where='fixture'))
        self.assertEqual(Decimal('0.00001'),quantity('0.000005',where='fixture'))
        self.assertEqual(Decimal('-0.00001'),quantity('-0.000005',where='fixture'))
        result=inspect(goods(1,2),[edge(1,1,2,'0.000004')])
        self.assertEqual(1,result['summary']['exclusions_by_reason']['EXCLUDED_NON_POSITIVE_QTY'])
        for value in ['NaN','Infinity','10000000000000']:
            with self.subTest(value=value),self.assertRaises(ValueError):quantity(value,where='fixture')

    def test_scc_excludes_acyclic_downstream_residue_and_finds_self_loop(self):
        result=inspect(goods(1,2,3,4,5),[edge(1,1,2),edge(2,2,1),edge(3,2,3),edge(4,4,4),edge(5,4,5)])
        self.assertFalse(result['summary']['valid'])
        self.assertEqual([[1,2],[4]],result['cycles'])
        self.assertIsNone(result['summary']['max_layers'])
        self.assertIn('RAISE EXCEPTION',render_sql(result,'0'*64,'1'*64))

    def test_parent_component_duplicates_are_invalid_even_with_different_colors(self):
        result=inspect(goods(1,2),[edge(1,1,2,color_legacy_id='3'),edge(2,1,2,color_legacy_id='4')])
        self.assertFalse(result['summary']['valid'])
        self.assertEqual(1,result['summary']['duplicate_active_parent_component_groups'])

    def test_source_identity_duplicates_are_invalid_even_for_exclusions(self):
        result=inspect(goods(1,2),[edge(1,1,2,'0'),edge(1,1,999)])
        self.assertFalse(result['summary']['valid'])
        self.assertEqual([1],result['summary']['duplicate_source_ids'])

    def test_deep_graph_does_not_use_python_recursion(self):
        result=inspect(goods(*range(10002)),[edge(number,number-1,number) for number in range(1,10002)])
        self.assertTrue(result['summary']['valid'])
        self.assertEqual(10001,result['summary']['max_depth_edges'])

    def test_static_sql_batches_and_binds_bidirectional_target_and_exclusion_gate(self):
        result=inspect(goods(*range(1003)),[edge(number,0,number) for number in range(1,1002)])
        sql=render_sql(result,'0'*64,'1'*64)
        self.assertEqual(2,sql.count('INSERT INTO expected_bom_topology_edges VALUES'))
        self.assertIn('LEFT JOIN expected_bom_topology_edges',sql)
        self.assertIn('expected_bom_topology_exclusions',sql)
        self.assertIn(result['summary']['graph_sha256'],sql)
        self.assertNotIn('\\copy',sql)  # preserves final executable CSV inventory
        compose_bootstrap.compose(sql.encode(),'goods_bom_topology.sql')

    def test_prepared_artifacts_bind_input_and_reject_bad_graph(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);good=root/'goods.csv';bom=root/'goods_bom.csv'
            good.write_text('legacy_id|status\n1|使用\n2|使用\n',encoding='utf-8')
            bom.write_text('legacy_id|goods_legacy_id|component_legacy_id|qty\n1|1|2|1\n2|2|1|1\n',encoding='utf-8')
            summary=prepare(good,bom,root/'out')
            self.assertFalse(summary['valid'])
            manifest=json.loads((root/'out/bom_topology_manifest.json').read_text(encoding='utf-8'))
            self.assertFalse(manifest['valid'])
            self.assertEqual(2,len(manifest['inputs']))
            self.assertIn('RAISE EXCEPTION',(root/'out/goods_bom_topology.sql').read_text())


@unittest.skipUnless(os.environ.get('UTEN_RUN_BOM_TOPOLOGY_DB_TESTS')=='1','set UTEN_RUN_BOM_TOPOLOGY_DB_TESTS=1 for real rolled-back PostgreSQL fixtures')
class BomTopologyTargetPostgresTest(unittest.TestCase):
    def run_fixture(self,*,corrupt=False):
        schema='bom_topology_fixture_'+uuid.uuid4().hex
        run=str(uuid.uuid4())
        result=inspect(goods(1,2,3,4),[edge(1,1,2,'1.234567'),edge(2,2,3,'0.5'),edge(3,1,4,'0')])
        sql=f"BEGIN; CREATE SCHEMA {schema}; SET LOCAL search_path={schema},public; SET LOCAL uten.bootstrap_run_id='{run}';\n"
        sql+="""CREATE TABLE goods(id uuid PRIMARY KEY,legacy_id int,is_deleted boolean DEFAULT false,auto_created boolean DEFAULT false,status text DEFAULT '使用');
CREATE TABLE goods_bom_items(id uuid,legacy_id int,goods_id uuid,component_goods_id uuid,qty numeric(18,5),is_deleted boolean DEFAULT false);
CREATE TABLE bootstrap_bom_exclusions(source_file text,source_legacy_id int,parent_legacy_id int,component_legacy_id int,source_qty numeric,reason text);
CREATE TABLE legacy_migration_runs(run_id uuid,status text,reconciliation_summary jsonb);
"""
        for identity in range(1,5):sql+=f"INSERT INTO goods(id,legacy_id) VALUES ('{uuid.UUID(int=identity)}',{identity});\n"
        sql+=f"INSERT INTO legacy_migration_runs VALUES ('{run}','RUNNING','{{}}');\n"
        sql+=f"INSERT INTO goods_bom_items(id,legacy_id,goods_id,component_goods_id,qty) VALUES ('{uuid.UUID(int=11)}',1,'{uuid.UUID(int=1)}','{uuid.UUID(int=3 if corrupt else 2)}',1.23457),('{uuid.UUID(int=12)}',2,'{uuid.UUID(int=2)}','{uuid.UUID(int=3)}',0.50000);\n"
        sql+="INSERT INTO bootstrap_bom_exclusions VALUES ('goods_bom.csv',3,1,4,0.00000,'EXCLUDED_NON_POSITIVE_QTY');\n"
        sql+=compose_bootstrap.compose(render_sql(result,'0'*64,'1'*64).encode(),'goods_bom_topology.sql').decode()
        sql+="SELECT 'BOM_TOPOLOGY_PG_PASSED'; ROLLBACK;\n"
        db=os.environ.get('UTEN_OWNER_CUSTODY_TEST_DATABASE','uten_imp_rehearsal_20261022')
        command=['docker','exec','-i','uten-imp-postgres','psql','-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-U','uten','-d',db]
        actual=subprocess.run(command,input=sql.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        if corrupt:
            self.assertNotEqual(0,actual.returncode)
            self.assertIn('target edge identities',actual.stderr.decode())
        else:
            self.assertEqual(0,actual.returncode,actual.stderr.decode())
            self.assertIn('BOM_TOPOLOGY_PG_PASSED',actual.stdout.decode())
        check=subprocess.run(command,input=f"SELECT count(*) FROM pg_namespace WHERE nspname='{schema}';".encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
        self.assertEqual('0',check.stdout.decode().strip())

    def test_exact_valid_target_and_same_count_wrong_identity_rejection(self):
        self.run_fixture()
        self.run_fixture(corrupt=True)


if __name__=='__main__':unittest.main()
