// 工资审核页（2026-09-10 明细多选下线：审核只有整批语义）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/payroll/models/payroll_batch.dart';
import 'package:uten_imp/features/payroll/models/payroll_slip.dart';
import 'package:uten_imp/features/payroll/pages/payroll_review_page.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';
import 'package:uten_imp/shared/ai/page_context/ai_page_context.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakePayrollRepository extends Fake implements PayrollRepository {
  int approveCalls = 0;

  @override
  Future<PagedResult<PayrollBatch>> listBatches({
    int page = 1,
    int size = 20,
    int? year,
    int? month,
    String? status,
    String? departmentId,
  }) async => PagedResult(
    items: [_batch()],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<PayrollBatch> getBatch(String id) async => _batch();

  @override
  Future<PayrollBatch?> approveBatch(String id) async {
    approveCalls++;
    return _batch();
  }
}

PayrollBatch _batch() => PayrollBatch(
  id: 'batch-1',
  year: 2026,
  month: 8,
  status: PayrollBatchStatus.submitted,
  headcount: 2,
  grossIncome: 20000,
  totalDeduction: 4000,
  netIncome: 16000,
  slips: [_slip('s-1', '张三'), _slip('s-2', '李四')],
);

PayrollSlip _slip(String id, String name) => PayrollSlip(
  id: id,
  employeeId: 'emp-$id',
  employeeName: name,
  employeeCode: 'UT$id',
  year: 2026,
  month: 8,
  items: const [],
  grossIncome: 10000,
  totalDeduction: 2000,
  netIncome: 8000,
  status: PayrollSlipStatus.pending,
  publishedAt: null,
);

void main() {
  testWidgets('slip detail table has no misleading per-row batch approve', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakePayrollRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          payrollRepositoryProvider.overrideWithValue(repo),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({Perm.payrollReview}),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PayrollReviewPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<PayrollSlip>>(
      find.byWidgetPredicate((w) => w is MasterDataTableView<PayrollSlip>),
    );
    // 2026-10-10 审核页防看岔行口径：勾选是纯阅读辅助（单选互斥的选中高亮，
    // 不画勾选框列也不驻「已选」胶囊），
    // 审计 A2 禁的红线是「勾选却整批生效」的误导按钮——批量动作恒不允许。
    expect(table.selectable, isTrue, reason: '防看岔行的纯阅读勾选');
    // 同日口径修订：最前列不画勾选框列、选中互斥（点其他行自动换选）。
    expect(table.showSelectionColumn, isFalse, reason: '防看岔勾选不显示多选框列');
    expect(table.singleSelection, isTrue, reason: '防看岔勾选单选互斥');
    expect(table.showSelectionSummary, isFalse, reason: '单选高亮自明，不驻已选胶囊');
    expect(table.batchActionsBuilder, isNull, reason: '工资审核只有整批语义，明细勾选永不挂批量动作');
    expect(find.byKey(const Key('payroll-review-batch-approve')), findsNothing);
    expect(find.textContaining('批量通过'), findsNothing);
    // 整批审核入口仍在（底部操作条）
    expect(find.text('审核通过'), findsOneWidget);
    expect(find.text('驳回'), findsOneWidget);
    expect(repo.approveCalls, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the AI page snapshot of the payroll review page carries no amount (ADR-150)',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final pageContext = AiPageContextController();
      addTearDown(pageContext.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            payrollRepositoryProvider.overrideWithValue(
              _FakePayrollRepository(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({Perm.payrollReview}),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) =>
                AiPageContextScope(controller: pageContext, child: child!),
            home: const PayrollReviewPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The payroll routes are never read at all (aiPageContentWithheld);
      // the columns are also marked, so even a capture holds no amount.
      expect(aiPageContentWithheld('/payroll/review'), isTrue);
      final snapshot = pageContext.capture(AppLocalizationsZh()).snapshot!;
      final encoded = jsonEncode(snapshot);
      for (final amount in [
        '10000',
        '8000',
        '2000',
        '20000',
        '16000',
        '4000',
      ]) {
        expect(encoded, isNot(contains(amount)), reason: amount);
      }
      final slips = (snapshot['tables']! as List)
          .cast<Map<String, Object?>>()
          .firstWhere(
            (table) => (table['columns']! as List).any(
              (column) => (column as Map)['label'] == '实发',
            ),
          );
      expect(
        (slips['rows']! as List).cast<Map<String, Object?>>().first['cells'],
        ['UTs-1', '张三', '', '', ''],
      );
      expect(snapshot['withheld'], containsAll(['应发', '扣减', '实发']));

      await tester.pumpWidget(const SizedBox());
    },
  );
}
