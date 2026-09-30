import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_claim_event.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/widgets/expense_claim_print.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'submitted printing uses frozen rows and custom fields without current record requests',
    () async {
      final claim = ExpenseClaim(
        id: 'claim',
        claimNo: 'BX1',
        applicantId: 'user',
        applicantName: '测试',
        title: '测试',
        items: [
          ExpenseItem(
            id: 'today',
            category: ExpenseCategory.transport,
            amount: 99,
            date: DateTime.utc(2026, 9, 29),
            description: '今日资料',
          ),
        ],
        totalAmount: 12.5,
        status: ExpenseClaimStatus.submitted,
        createdAt: DateTime.utc(2026, 9, 29),
        submissionSnapshot: jsonEncode({
          'schemaVersion': 2,
          'invoices': <Map<String, dynamic>>[],
          'items': [
            {
              'id': 'frozen',
              'category': 'TRANSPORT',
              'date': '2026-09-28',
              'description': '该次提交',
              'amount': '12.50',
              'platformFields': {
                'recordId': 'frozen',
                'version': 1,
                'canWrite': false,
                'cells': [
                  {
                    'columnId': 'f1',
                    'value': '保留原值',
                    'definition': {'id': 'f1', 'type': 'TEXT'},
                  },
                  {
                    'columnId': 'f2',
                    'value': null,
                    'masked': true,
                    'definition': {'id': 'f2', 'type': 'NUMBER'},
                  },
                ],
              },
            },
          ],
        }),
      );
      const projection = TableColumnProjection(
        tableKey: 'expense.claim.items',
        scope: 'expense_claim_item',
        columns: [
          TableProjectedColumn(
            key: 'description',
            label: '说明',
            width: 200,
            type: 'text',
          ),
          TableProjectedColumn(
            key: 'platform:f1',
            label: '新增资料',
            width: 100,
            type: 'text',
          ),
          TableProjectedColumn(
            key: 'platform:f2',
            label: '受限资料',
            width: 100,
            type: 'number',
          ),
          TableProjectedColumn(
            key: 'platform:new',
            label: '后来新增',
            width: 100,
            type: 'text',
          ),
        ],
      );
      final table = await expensePrintItemsTable(claim, projection: projection);
      expect(table.rows, [
        ['该次提交', '保留原值', '***', ''],
      ]);
      expect(table.rowIds, ['frozen']);
      expect(table.factValues, [
        {'amount': '12.50'},
      ]);
      final legacy = ExpenseClaim(
        id: claim.id,
        claimNo: claim.claimNo,
        applicantId: claim.applicantId,
        applicantName: claim.applicantName,
        title: claim.title,
        items: claim.items,
        totalAmount: claim.totalAmount,
        status: claim.status,
        createdAt: claim.createdAt,
        submissionSnapshot: jsonEncode({
          'schemaVersion': 1,
          'invoices': <Map<String, dynamic>>[],
          'items': [
            {
              'id': 'old',
              'category': 'TRANSPORT',
              'date': '2026-09-28',
              'description': '旧提交',
              'amount': '12.50',
            },
          ],
        }),
      );
      expect(
        (await expensePrintItemsTable(legacy, projection: projection)).rows,
        [
          ['旧提交', '', '', ''],
        ],
      );
    },
  );

  test(
    'custom claim preview and PDF use the exact visible item projection',
    () async {
      final claim = ExpenseClaim(
        id: 'claim',
        claimNo: 'BX1',
        applicantId: 'user',
        applicantName: '测试',
        title: '测试',
        items: [
          ExpenseItem(
            id: 'item',
            category: ExpenseCategory.transport,
            amount: 12.5,
            date: DateTime.utc(2026, 9, 29),
            description: '说明内容',
          ),
        ],
        totalAmount: 12.5,
        status: ExpenseClaimStatus.draft,
        createdAt: DateTime.utc(2026, 9, 29),
      );
      const projection = TableColumnProjection(
        tableKey: 'expense.claim.items',
        columns: [
          TableProjectedColumn(
            key: 'description',
            label: '当前说明',
            width: 320,
            type: 'text',
          ),
          TableProjectedColumn(
            key: 'category',
            label: '科目',
            width: 120,
            type: 'text',
          ),
        ],
      );
      final items = await expensePrintItemsTable(claim, projection: projection);
      expect(items.headers, ['当前说明', '科目']);
      expect(items.rows, [
        ['说明内容', '交通费'],
      ]);
      expect(items.columnWidths, [320, 120]);
      expect(items.columnKeys, ['description', 'category']);
      final pdf = await buildExpenseClaimPdf(claim, itemsTable: items);
      expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
      expect(expensePrintAuditLines(claim).first, contains('BX1'));
      expect(claim.totalAmount, 12.5);
    },
  );

  test(
    'A4 claim contains all items across pages and all correction events',
    () async {
      final claim = ExpenseClaim(
        id: 'qa-claim',
        claimNo: 'BX20260919000001',
        applicantId: 'qa-employee',
        applicantName: '测试员工(仅供格式核验)',
        departmentName: '测试部门',
        title: '测试报销单：多页明细及修订轨迹',
        remark: '本文件使用虚构数据，仅核验打印格式。',
        items: [
          for (var index = 0; index < 60; index++)
            ExpenseItem(
              id: 'item-$index',
              category: ExpenseCategory.transport,
              amount: 84.8,
              date: DateTime.utc(2026, 9, 18),
              description: '第 ${index + 1} 项：测试业务出行凭证。长说明应自动换行，全部内容保留在打印件中。',
            ),
        ],
        totalAmount: 5088,
        status: ExpenseClaimStatus.submitted,
        createdAt: DateTime.utc(2026, 9, 18, 8),
        events: [
          ExpenseClaimEvent(
            type: ExpenseClaimEventType.created,
            actorName: '测试员工',
            occurredAt: DateTime.utc(2026, 9, 18, 8),
          ),
          ExpenseClaimEvent(
            type: ExpenseClaimEventType.submitted,
            actorName: '测试员工',
            occurredAt: DateTime.utc(2026, 9, 18, 9),
          ),
          ExpenseClaimEvent(
            type: ExpenseClaimEventType.rejected,
            actorName: '测试审核人',
            remark: '补充原件',
            occurredAt: DateTime.utc(2026, 9, 18, 10),
          ),
          ExpenseClaimEvent(
            type: ExpenseClaimEventType.edited,
            actorName: '测试员工',
            occurredAt: DateTime.utc(2026, 9, 18, 11),
          ),
          ExpenseClaimEvent(
            type: ExpenseClaimEventType.submitted,
            actorName: '测试员工',
            occurredAt: DateTime.utc(2026, 9, 18, 12),
          ),
        ],
      );
      final audit = expensePrintAuditLines(claim);
      expect(audit.where((line) => line.contains('提交审批')), hasLength(2));
      expect(audit.any((line) => line.contains('补充原件')), isTrue);
      final bytes = await buildExpenseClaimPdf(claim, companyName: '测试公司(虚构)');
      expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
      expect(
        RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length,
        greaterThan(1),
      );
      if (Platform.environment['UTEN_EXPENSE_QA_PDF'] == '1') {
        await Directory('build/expense-qa').create(recursive: true);
        await File('build/expense-qa/sample.pdf').writeAsBytes(bytes);
      }
    },
  );
}
