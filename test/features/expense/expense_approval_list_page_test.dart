// 报销审批列表（2026-09-10 部门/年月表头筛选接后端 + 批量驳回复用公共弹窗）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_batch_reject_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/pages/expense_approval_list_page.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakeExpenseRepository extends Fake implements ExpenseRepository {
  final List<Map<String, dynamic>> pendingCalls = [];
  final List<Map<String, dynamic>> historyCalls = [];
  final List<Map<String, int>> batchVersions = [];
  final List<List<String>> rejectBatchCalls = [];

  @override
  Future<PagedResult<ExpenseClaim>> listPending({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  }) async {
    pendingCalls.add({
      'page': page,
      'year': year,
      'month': month,
      'departmentId': departmentId,
    });
    return PagedResult(
      items: [_claim('c-1'), _claim('c-2')],
      page: page,
      size: size,
      total: 2,
      totalPages: 1,
    );
  }

  @override
  Future<PagedResult<ExpenseClaim>> listHistory({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  }) async {
    historyCalls.add({
      'page': page,
      'year': year,
      'month': month,
      'departmentId': departmentId,
      'category': category,
    });
    return PagedResult(
      items: [_claim('c-1').copyWith(status: ExpenseClaimStatus.paid)],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<Map<String, List<MasterFacetBucket>>> facets(
    ApprovalFacetQueue queue,
  ) async => {
    'departmentName': const [
      MasterFacetBucket(value: 'dept-1', count: 2, label: '研发部'),
    ],
    'yearMonth': const [MasterFacetBucket(value: '2026-09', count: 2)],
  };

  @override
  Future<ExpenseQueueSummary> summary() async => const ExpenseQueueSummary(
    pendingCount: 2,
    pendingAmount: 257.0,
    payableCount: 0,
    payableAmount: 0,
    monthSubmittedCount: 2,
    monthSubmittedAmount: 257.0,
    monthPaidCount: 0,
    monthPaidAmount: 0,
  );

  @override
  Future<int> rejectBatch(
    Iterable<String> ids,
    String reason, {
    Map<String, int> expectedVersions = const {},
  }) async {
    rejectBatchCalls.add([ids.toList().join(','), reason]);
    batchVersions.add(expectedVersions);
    return ids.length;
  }
}

ExpenseClaim _claim(String id) => ExpenseClaim(
  id: id,
  claimNo: 'BX2026073000001$id',
  version: id == 'c-1' ? 3 : 8,
  applicantId: 'emp-1',
  applicantName: '王小明',
  departmentId: 'dept-1',
  departmentName: '研发部',
  title: '差旅报销 $id',
  items: const [],
  totalAmount: 128.5,
  status: ExpenseClaimStatus.submitted,
  createdAt: DateTime(2026, 9, 9, 10),
  submittedAt: DateTime(2026, 9, 9, 11),
);

Widget _app(_FakeExpenseRepository repo, SharedPreferences preferences) =>
    ProviderScope(
      overrides: [
        expenseRepositoryProvider.overrideWithValue(repo),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({Perm.expenseApprove}),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ExpenseApprovalListPage(),
      ),
    );

MasterDataTableView<ExpenseClaim> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<ExpenseClaim>>(
      find.byWidgetPredicate((w) => w is MasterDataTableView<ExpenseClaim>),
    );

void main() {
  testWidgets(
    'processed finance history remains readable with category filters and no actions',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final repo = _FakeExpenseRepository();
      await tester.pumpWidget(_app(repo, preferences));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ExpenseApprovalListPage)),
      );
      container.read(approvalQueueProvider.notifier).state =
          ApprovalQueue.history;
      await tester.pumpAndSettle();
      expect(repo.historyCalls, hasLength(1));
      expect(_table(tester).selectable, isFalse);
      expect(_table(tester).batchActionsBuilder, isNull);
      _table(tester).onFilterChanged('category', 'TRAVEL');
      await tester.pumpAndSettle();
      expect(repo.historyCalls.last['category'], 'TRAVEL');
      expect(repo.historyCalls.last['page'], 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('department and month header facets are pushed to the backend', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeExpenseRepository();
    await tester.pumpWidget(_app(repo, preferences));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.facets['departmentName']!.single.value, 'dept-1');
    expect(table.facets['yearMonth']!.single.value, '2026-09');

    table.onFilterChanged('departmentName', 'dept-1');
    await tester.pumpAndSettle();
    expect(repo.pendingCalls.last['departmentId'], 'dept-1');
    expect(repo.pendingCalls.last['page'], 1);

    _table(tester).onFilterChanged('yearMonth', '2026-09');
    await tester.pumpAndSettle();
    expect(repo.pendingCalls.last['year'], 2026);
    expect(repo.pendingCalls.last['month'], 9);
    expect(repo.pendingCalls.last['departmentId'], 'dept-1');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('batch reject reuses the shared reason dialog', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeExpenseRepository();
    await tester.pumpWidget(_app(repo, preferences));
    await tester.pumpAndSettle();

    _table(tester).onSelectedIdsChanged!({'c-1', 'c-2'});
    await tester.pumpAndSettle();

    // 2026-09-24 统计条移入折叠头后矮视口下浮动批量条略低于折沿，先滚入视野。
    final reject = find.byKey(const Key('expense-batch-reject'));
    await tester.ensureVisible(reject);
    await tester.pumpAndSettle();
    await tester.tap(reject);
    await tester.pumpAndSettle();
    expect(find.byType(UtenBatchRejectDialog), findsOneWidget);
    expect(
      find.byKey(const Key('reviewer-responsibility-notice')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('uten-batch-reject-reason')),
      '发票缺失',
    );
    await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
    await tester.pumpAndSettle();

    // V608：批量驳回走后端单事务端点（一次调用携带全部单号），不再逐单循环。
    expect(repo.rejectBatchCalls.length, 1);
    expect(repo.rejectBatchCalls.single[0], 'c-1,c-2');
    expect(repo.rejectBatchCalls.single[1], '发票缺失');
    expect(repo.batchVersions.single, {'c-1': 3, 'c-2': 8});

    await tester.pumpWidget(const SizedBox());
  });
}
