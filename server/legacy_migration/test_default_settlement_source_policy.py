from copy import deepcopy
import csv
import json
from pathlib import Path
import tempfile
import unittest

import default_settlement_source_policy as policy
import compose_bootstrap


METHOD = dict(id='27300000-0000-4000-8100-000000000001', legacy_id=1,
              status='使用', is_deleted=False)


class DefaultSettlementSourcePolicyTest(unittest.TestCase):
    def inputs(self, directory, client=('0', '1'), supplier=('0', '')):
        for name, values in [('client.csv', client), ('supplier.csv', supplier)]:
            with (directory/name).open('w', encoding='utf-8', newline='') as out:
                writer=csv.writer(out, delimiter='|')
                writer.writerow(['legacy_id', 'price_style'])
                writer.writerows((index, value) for index, value in enumerate(values, 1))

    def test_zero_and_empty_have_no_default_but_positive_has_exact_uuid(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);self.inputs(root)
            result=policy.preflight(root, [METHOD], 'a'*64, root/'audit.json')
            self.assertEqual(result['status'], 'PREFLIGHT_PASSED')
            self.assertEqual(result['families'][0]['rows'][0]['raw_price_style'], '0')
            self.assertIsNone(result['families'][0]['rows'][0]['normalized_price_style'])
            self.assertEqual(result['families'][0]['rows'][1]['expected_method_id'], METHOD['id'])
            self.assertEqual([r['expected_method_id'] for r in result['families'][1]['rows']], [None,None])

    def test_unknown_positive_negative_disabled_deleted_and_ambiguous_reject(self):
        duplicate=METHOD | {'id':'27300000-0000-4000-8100-000000000002'}
        cases=[(('999',),[METHOD]),(('-1',),[METHOD]),
               (('1',),[METHOD | {'status':'禁用'}]),
               (('1',),[METHOD | {'is_deleted':True}]),(('1',),[METHOD,duplicate])]
        for values, methods in cases:
            with self.subTest(values=values, methods=methods), tempfile.TemporaryDirectory() as temp:
                root=Path(temp);self.inputs(root, supplier=values)
                with self.assertRaisesRegex(ValueError, 'preflight rejected'):
                    policy.preflight(root, methods, 'a'*64, root/'audit.json')
                self.assertEqual(json.loads((root/'audit.json').read_text(encoding='utf-8'))['status'], 'REJECTED')

    def test_source_duplicate_rejects_instead_of_hiding_an_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);self.inputs(root)
            (root/'supplier.csv').write_text('legacy_id|price_style\n1|0\n1|0\n')
            with self.assertRaisesRegex(ValueError,'Duplicate'):
                policy.inspect(root,[METHOD],'a'*64)

    def test_late_audit_binds_full_source_external_but_only_compact_summary(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);self.inputs(root)
            path=root/'audit.json';audit=policy.preflight(root,[METHOD],'a'*64,path)
            sql=policy.render_late_audit(audit,'00000000-0000-0000-0000-000000000001',path)
            self.assertIn('source.raw_price_style IS DISTINCT FROM expected.source_price_style',sql)
            self.assertNotIn('JOIN client_stage',sql)
            self.assertNotIn('JOIN supplier_stage',sql)
            self.assertIn('expected.legacy_id=target.legacy_id',sql)
            self.assertNotIn('WHERE legacy_id IS NOT NULL',sql)
            self.assertIn('target.default_settlement_method_id IS DISTINCT FROM expected.expected_method_id',sql)
            self.assertIn('source_zero_identity_sha256',sql)
            self.assertNotIn('"raw_price_style"',sql)
            self.assertNotIn("'.csv'",sql[sql.index('INSERT INTO legacy_migration_run_files'):])
            path.write_text('{}')
            with self.assertRaisesRegex(ValueError,'changed'):
                policy.render_late_audit(audit,'00000000-0000-0000-0000-000000000001',path)

    def test_coordinator_orders_preflight_before_claim_and_summary_after_hot_loops(self):
        text=Path(__file__).with_name('rehearse_local_import.py').read_text(encoding='utf-8')
        self.assertLess(text.index('settlement_audit=default_settlement_source_policy.preflight'),text.index('db.sql(claim)'))
        self.assertGreater(text.index('default_settlement_source_policy.render_late_audit'),text.index('for name,content in executable_modules'))
        self.assertLess(text.index('content+=default_settlement_source_policy.render_source_capture(name)'),text.index('yield name,content'))

    def test_capture_is_typed_minimal_and_before_real_composer_cleanup(self):
        self.assertIn(policy.SNAPSHOT_TABLE,compose_bootstrap.PRESERVED_TEMP_TABLES)
        for family in ('client','supplier'):
            name='migrate_'+family+'_data.sql'
            capture=policy.render_source_capture(name)
            compose_bootstrap.validate_sql(capture)
            composed=compose_bootstrap.compose(('SELECT 1;\n'+capture).encode(),name).decode()
            self.assertLess(composed.index('INSERT INTO pg_temp.'+policy.SNAPSHOT_TABLE),composed.index('DROP TABLE pg_temp.%I'))
            self.assertIn('SELECT \''+family+'s\',legacy_id,price_style FROM pg_temp.'+family+'_stage',capture)
            self.assertNotIn('name ',capture)
            self.assertNotIn('emp_id',capture)
        self.assertEqual(policy.render_source_capture('migrate_client_owner.sql'),'')
        self.assertEqual(policy.render_source_capture("anything'; DROP TABLE users; --"),'')


if __name__=='__main__':
    unittest.main()
