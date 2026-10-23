import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import capture_finance_seed_baseline as capture


DB='uten_imp_rehearsal_20990101_v1'
def snapshot():
    return dict(database=DB,database_identity=dict(system_identifier='123',database_oid='456'),
        schema_version=914,successful_migration_count=1,failed_migration_count=0,
        applied_sql=[dict(script='V914__fixture.sql',checksum=7)],
        business_counts=dict(goods=0,users=1,accounts=0,source_legacy_styles=0,gl_entries=0),
        payment_styles=[dict(id='seed',legacy_source_import_run_id=None)],
        posting_roles=[dict(role_key='AR_CONTROL',style_id='seed')])


class FinanceSeedBaselineTests(unittest.TestCase):
    def validate(self,value):
        return capture.validate_snapshot(value,DB,914,{'V914__fixture.sql':7})

    def test_readonly_snapshot_contract_accepts_matching_fresh_schema(self):
        self.assertEqual(self.validate(snapshot())['schema_version'],914)
        self.assertIn('READ ONLY',capture.SQL)

    def test_cannot_relabel_an_older_schema(self):
        value=snapshot();value['schema_version']=913
        with self.assertRaises(ValueError):self.validate(value)

    def test_existing_business_data_cannot_become_seed_evidence(self):
        for field in ('goods','accounts','source_legacy_styles','gl_entries'):
            value=snapshot();value['business_counts'][field]=1
            with self.subTest(field=field),self.assertRaises(ValueError):self.validate(value)

    def test_source_provenance_cannot_become_system_seed(self):
        value=snapshot();value['payment_styles'][0]['legacy_source_import_run_id']='old-run'
        with self.assertRaises(ValueError):self.validate(value)

    def test_missing_or_changed_native_sql_inventory_is_rejected(self):
        for change in ('checksum','duplicate','count'):
            value=snapshot()
            if change=='checksum':value['applied_sql'][0]['checksum']=8
            elif change=='duplicate':value['applied_sql']*=2
            else:value['successful_migration_count']=2
            with self.subTest(change=change),self.assertRaises(ValueError):self.validate(value)

    def test_role_uuid_must_belong_to_captured_seed(self):
        value=snapshot();value['posting_roles'][0]['style_id']='outside'
        with self.assertRaises(ValueError):self.validate(value)

    def test_canonical_database_is_rejected_before_any_subprocess(self):
        with patch.object(capture.subprocess,'check_output') as command:
            with self.assertRaises(ValueError):capture.capture(Path('.'),'uten_imp',914,Path('unused.json'))
            command.assert_not_called()

    def test_existing_evidence_is_never_overwritten_or_queried(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'baseline.json';out.write_text('keep')
            with patch.object(capture.subprocess,'check_output') as command:
                with self.assertRaises(ValueError):capture.capture(Path('.'),DB,914,out)
                command.assert_not_called()
            self.assertEqual(out.read_text(),'keep')


if __name__=='__main__':unittest.main()
