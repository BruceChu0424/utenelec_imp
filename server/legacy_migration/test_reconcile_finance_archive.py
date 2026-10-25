import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC=importlib.util.spec_from_file_location('archive_reconcile',Path(__file__).with_name('reconcile_modules.py'))
reconcile=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(reconcile)

class FinanceArchiveReconciliationTest(unittest.TestCase):
    def test_only_explicit_account_flow_or_reviewed_cash_source_may_have_archive_count(self):
        self.assertIn("financeArchiveOnly",reconcile.archived_rows('m_allcheck.csv'))
        for source in ('m_get.csv','m_paid.csv'):
            self.assertIn('financeCashSourceArchive',reconcile.archived_rows(source))
            self.assertIn("archived->>'source_file'=",reconcile.archived_rows(source))
        for source in reconcile.document_queries():
            if source not in ('m_allcheck.csv','m_get.csv','m_paid.csv'):self.assertEqual(reconcile.archived_rows(source),'0')
    def test_generated_sql_keeps_archive_distinct_from_excluded_and_active(self):
        with tempfile.TemporaryDirectory() as folder:
            manifest=Path(folder)/'inputs.json'
            manifest.write_text(json.dumps({'files':[{'file':'m_allcheck.csv','rows':30627}]}),encoding='utf-8')
            output=io.StringIO()
            with patch.object(reconcile,'document_queries',return_value={'m_allcheck.csv':('finance_reconciliations','SELECT count(*) FROM finance_reconciliations WHERE legacy_id IS NOT NULL')}),patch.object(reconcile,'emit_master_identity_checks'),patch('sys.argv',['reconcile',str(manifest),'00000000-0000-4000-8000-000000000001']),contextlib.redirect_stdout(output):
                reconcile.main()
            sql=output.getvalue()
        self.assertIn('archived bigint NOT NULL',sql)
        self.assertIn('expected <> actual + excluded + archived',sql)
        self.assertIn("'excluded', excluded, 'archived', archived",sql)
        self.assertIn("'passed', expected = actual + excluded + archived",sql)
        self.assertNotIn('rejected',sql)

if __name__=='__main__':unittest.main()
