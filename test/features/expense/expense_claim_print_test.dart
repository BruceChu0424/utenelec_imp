import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_claim_event.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/widgets/expense_claim_print.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
