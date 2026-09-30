import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'audit_platform_tables.py'
spec = importlib.util.spec_from_file_location('audit_platform_tables', SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

class PlatformTableInventoryTest(unittest.TestCase):
    def test_ast_counts_generic_calls_but_not_comments_strings_or_constructor_declarations(self):
        fixture = """
        import 'package:flutter/material.dart';
        import 'package:pdf/widgets.dart' as pw;
        // DataTable(columns: [], rows: []);
        const text = 'MasterDataTableView<Item>(fake: true)';
        class Example {
          Example();
          Object table() => MasterDataTableView<Item>(
            tableKey: 'example.rows', idOf: (row) => row.id,
            columns: [MasterColumnDef<Item>(key: 'qty', label: '数量', type: 'number', value: (row) => row.qty)],
            items: const []);
          Object print() => pw.Table(children: const []);
          Object data() => UtenPrintTable(headers: const [], rows: const []);
        }
        """
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'example.dart').write_text(fixture, encoding='utf-8')
            raw = audit.scan(source=directory)
        self.assertEqual(['MasterDataTableView','Table','UtenPrintTable'], [call['component'] for call in raw['calls']])
        result = audit.build(raw)
        self.assertEqual(1,result['summary']['flutterCalls'])
        self.assertEqual({'flutter_table':1,'pdf_document_table':1,'print_data_specification':1},result['summary']['byKind'])
        call = result['tables'][0]
        self.assertEqual("'qty'", call['baseFields'][0]['key'])
        self.assertTrue(call['involvesQuantity'])
        self.assertEqual("'数量'",call['baseFields'][0]['label'])
        self.assertIn('end_to_end_persistence_permission_history_export_evidence_required',call['coverageGaps'])

    def test_shared_widget_and_index_key_do_not_claim_completed_coverage(self):
        raw={'sourceFileCount':1,'parseErrorFiles':[],'calls':[{
            'path':'lib/features/example/page.dart','line':1,'endLine':2,'component':'MasterDataTableView',
            'qualifiedType':'MasterDataTableView<Item>','ownerClass':'Example','ownerMember':'build',
            'arguments':{'rowKeyOf':'(row) => rows.indexOf(row).toString()'},'fileColumns':[],'filePreferences':[]}]}
        call=audit.build(raw)['tables'][0]
        self.assertTrue(call['sharedRenderer'])
        self.assertEqual('requires_end_to_end_acceptance',call['coverageStatus'])
        self.assertEqual('requires_manual_stability_review',call['rowIdentity']['status'])
        self.assertIsNone(call['involvesMoney'])
        self.assertIsNone(call['scope'])

    def test_expense_items_and_fixed_signature_do_not_share_projection_policy(self):
        base={'path':'lib/features/expense/widgets/expense_claim_print.dart','component':'Table','qualifiedType':'pw.Table'}
        self.assertEqual('current_table_projection_with_frozen_history',audit.print_policy({**base,'ownerMember':'_pdfItemsTable'}))
        self.assertEqual('purpose_specific_document',audit.print_policy({**base,'ownerMember':'_pdfSignTable'}))
        self.assertTrue(any(item['scope']=='payroll_slip' and item['policy']=='purpose_specific_document' for item in audit.PRINT_BOUNDARIES))

if __name__=='__main__': unittest.main()
