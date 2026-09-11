// 工资条列表（2026-09-10 状态表头筛选 = 分段口径，下推后端并回第 1 页）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/payroll/models/payroll_slip.dart';
import 'package:uten_imp/features/payroll/pages/payroll_slip_list_page.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakePayrollRepository extends Fake implements PayrollRepository {
  final List<Map<String, dynamic>> slipCalls = [];

  @override
  Future<PagedResult<PayrollSlip>> listSlips({
    String? status,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  }) async {
    slipCalls.add({'status': status, 'page': page});
    return PagedResult(
      items: [
        PayrollSlip(
          id: 's-1',
          employeeId: 'emp-1',
          employeeName: '王小明',
          employeeCode: 'UT0001',
          year: 2026,
          month: 8,
          items: const [],
          grossIncome: 10000,
          totalDeduction: 2000,
          netIncome: 8000,
          status: PayrollSlipStatus.published,
          publishedAt: DateTime(2026, 9, 1, 9),
        ),
      ],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }
}

void main() {
  testWidgets('status header facet switches the segment and reloads page 1', (
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
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PayrollSlipListPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<PayrollSlip>>(
      find.byKey(const Key('payroll-slip-table')),
    );
    expect(table.facets['status']!.map((b) => b.value), [
      'published',
      'viewed',
      'downloaded',
    ]);
    expect(table.filters['status'], isNull, reason: '「全部」段不选中任何状态');

    table.onFilterChanged('status', 'viewed');
    await tester.pumpAndSettle();

    expect(repo.slipCalls.last['status'], 'VIEWED');
    expect(repo.slipCalls.last['page'], 1);
    final refreshed = tester.widget<MasterDataTableView<PayrollSlip>>(
      find.byKey(const Key('payroll-slip-table')),
    );
    expect(refreshed.filters['status'], 'viewed');

    await tester.pumpWidget(const SizedBox());
  });
}
