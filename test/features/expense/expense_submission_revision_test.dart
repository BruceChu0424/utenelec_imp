import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_invoice.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/pages/expense_approval_detail_page.dart';
import 'package:uten_imp/features/expense/pages/expense_detail_page.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/widgets/expense_invoice_section.dart';
import 'package:uten_imp/features/expense/widgets/expense_submission_revision.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Map<String, dynamic> _item(
  String id,
  String amount, {
  String description = '停车费',
}) => {
  'id': id,
  'category': 'TRANSPORT',
  'date': '2026-09-22',
  'description': description,
  'amount': amount,
};
String _snapshot(
  List<Map<String, dynamic>> items, {
  List<Map<String, dynamic>> invoices = const [],
}) => jsonEncode({
  'schemaVersion': 1,
  'title': '拜访客户',
  'remark': null,
  'totalAmount': '35.00',
  'items': items,
  'invoices': invoices,
});
ExpenseClaim _claim({
  ExpenseClaimStatus status = ExpenseClaimStatus.submitted,
  String? before,
  String? current,
  bool resubmission = true,
  List<ExpenseClaimInvoice> invoices = const [],
}) => ExpenseClaim(
  id: 'claim',
  claimNo: 'BX202609230001',
  applicantId: 'employee',
  applicantName: '申请人',
  title: '拜访客户',
  items: [
    ExpenseItem(
      id: 'live',
      category: ExpenseCategory.transport,
      amount: 35,
      date: DateTime(2026, 9, 22),
      description: '停车费',
    ),
  ],
  totalAmount: 35,
  status: status,
  createdAt: DateTime(2026, 9, 23),
  previousSubmissionSnapshot: before,
  submissionSnapshot: current,
  resubmission: resubmission,
  invoices: invoices,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ExpenseClaim? claim,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1440, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue({}),
        if (claim != null)
          expenseDetailProvider.overrideWith((ref, id) async => claim),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'malformed prior items are not presented as a trustworthy comparison',
    () {
      final claim = _claim(
        before: _snapshot([{}]),
        current: _snapshot([_item('current', '35')]),
      );
      expect(ExpenseSubmissionRevision.fromClaim(claim), isNull);
    },
  );

  test(
    'rebuilt IDs and numeric formatting preserve unchanged duplicate business rows',
    () {
      final rows = expenseItemRevisionRows(
        [_item('old1', '10.00'), _item('old2', '10')],
        [_item('new1', '10.0'), _item('new2', '10.000')],
      );
      expect(rows.map((row) => row.kind), [
        UtenRevisionKind.unchanged,
        UtenRevisionKind.unchanged,
      ]);
    },
  );

  test(
    'unique amount edit becomes a complete old/new pair; additions and removals stay visible',
    () {
      final rows = expenseItemRevisionRows(
        [
          _item('old1', '1234567890123456.78'),
          _item('old2', '20', description: '已删'),
        ],
        [
          _item('new1', '1234567890123456.79'),
          _item('new2', '30', description: '新项'),
        ],
      );
      expect(rows.map((row) => row.kind), [
        UtenRevisionKind.removed,
        UtenRevisionKind.added,
        UtenRevisionKind.removed,
        UtenRevisionKind.added,
      ]);
      expect(rows[0].value['amount'], '1234567890123456.78');
      expect(rows[1].value['amount'], '1234567890123456.79');
      expect(rows[1].value['description'], '停车费');
      expect(rows[1].changedKeys, {'amount'});
      expect(rows[2].label, '已删除');
      expect(rows[3].label, '新增');
      expect(rows[3].changedKeys, isEmpty);
    },
  );

  test(
    'ambiguous same-category rows are not arbitrarily paired after modification',
    () {
      final rows = expenseItemRevisionRows(
        [_item('old1', '10'), _item('old2', '20')],
        [_item('new1', '30'), _item('new2', '40')],
      );
      expect(rows.map((row) => row.label), ['已删除', '已删除', '新增', '新增']);
    },
  );

  test(
    'invoice number is text while invoice amount retains exact numeric comparison',
    () {
      final rows = expenseInvoiceRevisionRows(
        [
          {'id': 'invoice', 'invoiceNo': '00000001', 'totalAmount': '10.00'},
        ],
        [
          {'id': 'invoice', 'invoiceNo': '00000002', 'totalAmount': '10.000'},
        ],
      );
      expect(rows, hasLength(2));
      expect(rows[0].value['invoiceNo'], '00000001');
      expect(rows[1].value['invoiceNo'], '00000002');
      expect(rows[1].changedKeys, {'invoiceNo'});
    },
  );

  test(
    'draft and rejected edits cannot show stale submitted rows as current',
    () {
      final before = _snapshot([_item('old', '10')]);
      final current = _snapshot([_item('new', '20')]);
      for (final status in [
        ExpenseClaimStatus.draft,
        ExpenseClaimStatus.rejected,
      ]) {
        expect(
          ExpenseSubmissionRevision.fromClaim(
            _claim(status: status, before: before, current: current),
          ),
          isNull,
        );
      }
      final submitted = _claim(before: before, current: current);
      expect(ExpenseSubmissionRevision.fromClaim(submitted), isNotNull);
      expect(
        submitted
            .copyWith(status: ExpenseClaimStatus.reviewing)
            .submissionSnapshot,
        current,
      );
    },
  );

  testWidgets(
    'legacy resubmission without a baseline states the gap and shows no fabricated diff',
    (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: ExpenseSubmissionChangeSummary(
            claim: _claim(current: _snapshot([_item('new', '35')])),
          ),
        ),
      );
      expect(find.textContaining('上次提交内容未留存或暂不可读'), findsOneWidget);
      expect(find.byType(UtenRevisionStrike), findsNothing);
    },
  );

  for (final approval in [false, true]) {
    testWidgets(
      '${approval ? 'approval' : 'applicant'} detail renders submitted expense revisions',
      (tester) async {
        final claim = _claim(
          before: _snapshot([_item('old', '20')]),
          current: _snapshot([_item('new', '35')]),
        );
        await _pump(
          tester,
          approval
              ? const ExpenseApprovalDetailPage(claimId: 'claim')
              : const ExpenseDetailPage(claimId: 'claim'),
          claim: claim,
        );
        expect(
          find.byKey(
            Key(
              approval
                  ? 'expense-approval-items-revision'
                  : 'expense-detail-items-revision',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byType(UtenRevisionStrike), findsOneWidget);
        expect(find.text('报销单修改'), findsOneWidget);
        expect(find.text('本次共 1 项 · 合计 ¥ 35.00'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'invoice diff keeps the current invoice verification action reachable',
    (tester) async {
      final claim = _claim(
        before: _snapshot(
          [],
          invoices: [
            {
              'id': 'invoice',
              'lineNo': 1,
              'invoiceType': 'DIGITAL',
              'invoiceNo': '00000000000000000001',
              'totalAmount': '20',
            },
          ],
        ),
        current: _snapshot(
          [],
          invoices: [
            {
              'id': 'invoice',
              'lineNo': 1,
              'invoiceType': 'DIGITAL',
              'invoiceNo': '00000000000000000001',
              'totalAmount': '35',
            },
          ],
        ),
        invoices: [
          const ExpenseClaimInvoice(
            id: 'invoice',
            lineNo: 1,
            type: ExpenseInvoiceType.digital,
            invoiceNo: '00000000000000000001',
            totalAmount: 35,
            checkState: ExpenseInvoiceCheckState.unchecked,
          ),
        ],
      );
      await _pump(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: ExpenseInvoiceSection(
              claim: claim,
              editable: false,
              canVerify: true,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const Key('expense-invoice-revision-table')),
        findsOneWidget,
      );
      final changedAmount = tester.widget<Text>(find.text('35'));
      expect(changedAmount.style?.fontWeight, FontWeight.w800);
      expect(changedAmount.style?.color, UtenColors.errorText);
      final verify = find.textContaining('#1 · 未查验');
      expect(verify, findsOneWidget);
      await tester.tap(verify);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
