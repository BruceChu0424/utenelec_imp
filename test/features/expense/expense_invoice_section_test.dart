// 发票登记区（V608）：表格渲染 + 登记弹窗（必填校验/保存走 addInvoice）+
// 打印报销单预览（A4 纸面四分区）。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_invoice.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/features/expense/widgets/expense_claim_print.dart';
import 'package:uten_imp/features/expense/widgets/expense_invoice_section.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';

class _FakeExpenseRepository extends Fake implements ExpenseRepository {
  final List<Map<String, dynamic>> addInvoiceCalls = [];
  ExpenseInvoiceCheckResult checkResult = const ExpenseInvoiceCheckResult(
    duplicated: false,
  );

  @override
  Future<ExpenseInvoiceCheckResult> checkInvoice(
    String invoiceNo, {
    String? invoiceCode,
    String? excludeClaimId,
    String? invoiceType,
    String? sellerName,
  }) async => checkResult;

  @override
  Future<ExpenseClaim> addInvoice(
    String claimId,
    ExpenseClaimInvoiceInput input,
  ) async {
    addInvoiceCalls.add({'claimId': claimId, 'input': input});
    return _claim();
  }
}

ExpenseClaim _claim({List<ExpenseClaimInvoice> invoices = const []}) =>
    ExpenseClaim(
      id: 'claim-1',
      claimNo: 'BX20260918000001',
      applicantId: 'emp-1',
      applicantName: '张三',
      title: '客户拜访差旅',
      items: const [],
      totalAmount: 84.8,
      status: ExpenseClaimStatus.draft,
      createdAt: DateTime(2026, 9, 18, 9),
      invoices: invoices,
      attachments: const [
        Attachment(
          id: 'attachment-1',
          ownerType: 'EXPENSE_CLAIM',
          ownerId: 'claim-1',
          storageKey: 'private-original',
          originalName: '凭证.pdf',
          sizeBytes: 1024,
        ),
      ],
    );

ExpenseClaimInvoice _invoice() => ExpenseClaimInvoice(
  id: 'invoice-1',
  lineNo: 1,
  type: ExpenseInvoiceType.digital,
  invoiceNo: '24312000000012345678',
  issueDate: DateTime(2026, 9, 17),
  sellerName: '上海某某酒店管理有限公司',
  totalAmount: 84.8,
  checkState: ExpenseInvoiceCheckState.verified,
);

Widget _app(
  _FakeExpenseRepository repo,
  SharedPreferences preferences, {
  required ExpenseClaim claim,
  required bool editable,
  Future<ExpenseSettings>? settings,
}) => ProviderScope(
  overrides: [
    expenseSettingsProvider.overrideWith(
      (ref) =>
          settings ?? Future.value(const ExpenseSettings(companyName: '测试公司')),
    ),
    expenseRepositoryProvider.overrideWithValue(repo),
    sharedPreferencesProvider.overrideWithValue(preferences),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    theme: ThemeData.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(1.4)),
      child: child!,
    ),
    home: Scaffold(
      body: ListView(
        children: [ExpenseInvoiceSection(claim: claim, editable: editable)],
      ),
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  _FakeExpenseRepository repo, {
  required ExpenseClaim claim,
  bool editable = true,
}) async {
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    _app(repo, preferences, claim: claim, editable: editable),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final edited in [false, true]) {
    testWidgets('late company prefill respects manual input: $edited', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = Completer<ExpenseSettings>();
      await tester.pumpWidget(
        _app(
          _FakeExpenseRepository(),
          prefs,
          claim: _claim(),
          editable: true,
          settings: settings.future,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('expense-invoice-add')));
      await tester.pumpAndSettle();
      final name = find.byKey(const Key('expense-invoice-buyer-name'));
      final tax = find.byKey(const Key('expense-invoice-buyer-tax'));
      if (edited) {
        await tester.enterText(name, '手工填写的购买方');
        await tester.enterText(tax, '123');
        await tester.enterText(tax, '');
      }
      settings.complete(
        const ExpenseSettings(
          companyName: '财务配置的公司',
          companyTaxNo: '91310000MA1FL8XX00',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(name).controller!.text,
        edited ? '手工填写的购买方' : '财务配置的公司',
      );
      expect(
        tester.widget<TextField>(tax).controller!.text,
        edited ? '' : '91310000MA1FL8XX00',
      );
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [390.0, 768.0, 1440.0]) {
    testWidgets('invoice entry at $width dp does not overflow', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(tester, _FakeExpenseRepository(), claim: _claim());
      await tester.tap(find.byKey(const Key('expense-invoice-add')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('invoice entry rejects fractional cents before saving', (
    tester,
  ) async {
    final repo = _FakeExpenseRepository();
    await _pump(tester, repo, claim: _claim());
    await tester.tap(find.byKey(const Key('expense-invoice-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('expense-invoice-no')),
      '24312000000012345678',
    );
    await tester.enterText(
      find.byKey(const Key('expense-invoice-total')),
      '84.801',
    );
    await tester.tap(find.byKey(const Key('expense-invoice-save')));
    await tester.pumpAndSettle();
    expect(repo.addInvoiceCalls, isEmpty);
  });

  testWidgets('renders invoice rows and total for approver review', (
    tester,
  ) async {
    await _pump(
      tester,
      _FakeExpenseRepository(),
      claim: _claim(invoices: [_invoice()]),
      editable: false,
    );

    expect(find.text('发票登记 (1)'), findsOneWidget);
    expect(find.textContaining('¥ 84.80'), findsOneWidget);
    expect(find.text('24312000000012345678'), findsOneWidget);
    expect(find.text('上海某某酒店管理有限公司'), findsOneWidget);
    expect(find.text('已人工查验'), findsOneWidget);
    // 只读模式不出登记按钮。
    expect(find.text('登记发票'), findsNothing);
  });

  testWidgets('add dialog blocks malformed invoice number', (tester) async {
    final repo = _FakeExpenseRepository();
    await _pump(tester, repo, claim: _claim());

    await tester.tap(find.byKey(const Key('expense-invoice-add')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('expense-invoice-no')),
      '12345',
    );
    await tester.enterText(
      find.byKey(const Key('expense-invoice-total')),
      '84.80',
    );
    await tester.tap(find.byKey(const Key('expense-invoice-save')));
    await tester.pumpAndSettle();
    // 形状不符：弹窗保持打开、未发起保存（警告经顶部通知提示）。
    expect(find.byKey(const Key('expense-invoice-save')), findsOneWidget);
    expect(repo.addInvoiceCalls, isEmpty);
  });

  testWidgets('add dialog saves digital invoice via addInvoice', (
    tester,
  ) async {
    final repo = _FakeExpenseRepository();
    await _pump(tester, repo, claim: _claim());

    await tester.tap(find.byKey(const Key('expense-invoice-add')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('expense-invoice-no')),
      '24312000000012345678',
    );
    await tester.enterText(
      find.byKey(const Key('expense-invoice-total')),
      '84.80',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('expense-invoice-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('expense-invoice-save')));
    await tester.pumpAndSettle();

    expect(repo.addInvoiceCalls.single['claimId'], 'claim-1');
    final input =
        repo.addInvoiceCalls.single['input'] as ExpenseClaimInvoiceInput;
    expect(input.invoiceNo, '24312000000012345678');
    expect(input.totalAmount, 84.8);
    expect(input.type, ExpenseInvoiceType.digital);
  });

  testWidgets('print preview renders the formal claim sheet', (tester) async {
    final claim = _claim(invoices: [_invoice()]).copyWith(
      status: ExpenseClaimStatus.paid,
      paidAt: DateTime(2026, 9, 19, 10),
    );
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          expenseSettingsProvider.overrideWith(
            (ref) async => const ExpenseSettings(companyName: '测试公司'),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  key: const Key('open-print'),
                  onPressed: () => showExpenseClaimPrintPreview(context, claim),
                  child: const Text('打印'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-print')));
    await tester.pumpAndSettle();

    // 四分区版式：标题 + 单号 + 事由 + 合计大写 + 附件张数 + 五格签字栏。
    expect(find.text('费用报销单'), findsOneWidget);
    expect(find.textContaining('BX20260918000001'), findsWidgets);
    expect(find.textContaining('客户拜访差旅'), findsOneWidget);
    expect(find.textContaining('人民币捌拾肆元捌角'), findsOneWidget);
    expect(find.textContaining('电子文件'), findsNWidgets(2));
    expect(find.text('报销人'), findsWidgets);
    expect(find.text('部门负责人'), findsOneWidget);
    expect(find.text('财务审核'), findsOneWidget);
    expect(find.text('批准人'), findsOneWidget);
    expect(find.text('出纳'), findsOneWidget);
  });
}
