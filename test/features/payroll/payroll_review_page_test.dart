// 工资审核页（2026-09-10 明细多选下线：审核只有整批语义）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/payroll/models/payroll_batch.dart';
import 'package:uten_imp/features/payroll/models/payroll_slip.dart';
import 'package:uten_imp/features/payroll/pages/payroll_review_page.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';
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
    expect(table.selectable, isFalse, reason: '工资审核无逐条语义，明细表不开多选');
    expect(table.batchActionsBuilder, isNull);
    expect(find.byKey(const Key('payroll-review-batch-approve')), findsNothing);
    expect(find.textContaining('批量通过'), findsNothing);
    // 整批审核入口仍在（底部操作条）
    expect(find.text('审核通过'), findsOneWidget);
    expect(find.text('驳回'), findsOneWidget);
    expect(repo.approveCalls, 0);

    await tester.pumpWidget(const SizedBox());
  });
}
