"""Single-transaction source completion and immutable native monthly contract."""
import ast
from pathlib import Path
import textwrap
import unittest

HERE=Path(__file__).resolve().parent

class FinanceMonthlyFinalizationOrderTest(unittest.TestCase):
    def test_final_success_is_uncommitted_before_deferred_and_only_audit_follows(self):
        source=(HERE/'rehearse_local_import.py').read_text(encoding='utf-8')
        terminal=source.index("UPDATE legacy_migration_runs SET status='SUCCESS',reconciliation_status='PASSED',exit_code=0,")
        structural=source.rindex('Rehearsal structural reconciliation failed',0,terminal)
        reconciliation=source.index('sql += reconcile_sql(manifest_path, run_id)')
        final=source.index("sql += compose_bootstrap.compose((HERE / 'migrate_finalize_checks.sql')")
        audit=source.index("sql += compose_bootstrap.compose((HERE / 'migrate_audit_summary.sql')")
        commit=source.index("sql += 'COMMIT;",audit)
        self.assertLess(reconciliation,structural)
        self.assertLess(structural,terminal)
        self.assertLess(terminal,final)
        self.assertLess(final,audit)
        self.assertLess(audit,commit)
        # After finalization there must be exactly the known audit/report write
        # and COMMIT. A future loader/metadata mutation must be reviewed here.
        tail=source[final:commit+len("sql += 'COMMIT;\\n'")]
        statements=ast.parse(textwrap.dedent('        '+tail)).body
        self.assertEqual(len(statements),3)
        audit_sql=(HERE/'migrate_audit_summary.sql').read_text(encoding='utf-8')
        self.assertIn('INSERT INTO audit_log (',audit_sql)
        self.assertNotIn('UPDATE account_flow_monthly_summaries',audit_sql)
        self.assertNotIn('INSERT INTO finance_reconciliations',audit_sql)

    def test_final_monthly_projection_follows_all_source_flows_before_openings(self):
        source=(HERE/'migrate_finance.sql').read_text(encoding='utf-8')
        flow=source.index("::uuid, 'ACCOUNT_FLOW', to_jsonb(legacy_row.*))")
        rebuild=source.index('SELECT fn_rebuild_account_flow_monthly_summaries(NULL);')
        check=source.index('SELECT fn_assert_account_flow_monthly_integrity(NULL);')
        opening=source.index("::uuid, 'AR_OPENING', to_jsonb(legacy_row.*))")
        self.assertLess(flow,rebuild)
        self.assertLess(rebuild,check)
        self.assertLess(check,opening)
        self.assertEqual(source.count('SELECT fn_rebuild_account_flow_monthly_summaries(NULL);'),1)
        self.assertIn("CONSTRAINT='legacy_account_flow_final_monthly_nonnegative'",source)

if __name__=='__main__':unittest.main()
