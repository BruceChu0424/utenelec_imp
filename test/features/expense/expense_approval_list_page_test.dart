// 报销审批列表（2026-09-10 部门/年月表头筛选接后端 + 批量驳回复用公共弹窗）。
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_batch_reject_dialog.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/pages/expense_approval_list_page.dart';
import 'package:uten_imp/features/expense/pages/expense_approval_detail_page.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/providers/expense_action_eligibility.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakeExpenseRepository extends Fake implements ExpenseRepository {
  List<ExpenseClaim> pendingItems = [_claim('c-1'), _claim('c-2')];
  ExpenseClaim? detail;
  final detailCalls = <String>[];
  Completer<int>? rejectGate;

  @override
  Future<ExpenseClaim> getById(String id) async {
    detailCalls.add(id);
    return detail ?? _claim(id);
  }

  ExpenseQueueSummary queueSummary = const ExpenseQueueSummary(
    pendingCount: 2,
    pendingAmount: 257.0,
    payableCount: 0,
    payableAmount: 0,
    monthSubmittedCount: 2,
    monthSubmittedAmount: 257.0,
    monthPaidCount: 0,
    monthPaidAmount: 0,
    actionablePendingCount: 2,
  );
  final List<Map<String, dynamic>> pendingCalls = [];
  final List<Map<String, dynamic>> historyCalls = [];
  final List<int> payableCalls = [];

  @override
  Future<PagedResult<ExpenseClaim>> listPayable({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
    String? sort,
    String? order,
    String? claimNo,
  }) async {
    payableCalls.add(page);
    return PagedResult(
      items: [
        _claim('payable-1').copyWith(status: ExpenseClaimStatus.approved),
      ],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  final List<Map<String, int>> batchVersions = [];
  final List<List<String>> rejectBatchCalls = [];
  final List<List<String>> approveBatchCalls = [];

  @override
  Future<int> approveBatch(
    Iterable<String> ids, {
    Map<String, int> expectedVersions = const {},
  }) async {
    approveBatchCalls.add(ids.toList());
    batchVersions.add(expectedVersions);
    return ids.length;
  }

  @override
  Future<PagedResult<ExpenseClaim>> listPending({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
    String? sort,
    String? order,
    String? claimNo,
  }) async {
    pendingCalls.add({
      'page': page,
      'year': year,
      'month': month,
      'departmentId': departmentId,
      'claimNo': claimNo,
      'sort': sort,
      'order': order,
    });
    return PagedResult(
      items: pendingItems,
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
    String? sort,
    String? order,
    String? claimNo,
  }) async {
    historyCalls.add({
      'page': page,
      'year': year,
      'month': month,
      'departmentId': departmentId,
      'category': category,
      'claimNo': claimNo,
      'sort': sort,
      'order': order,
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
    // 2026-09-25 单号列统一：报销单号桶（claimNo）随 facets 响应下发。
    'claimNo': const [MasterFacetBucket(value: 'BX2026073000001', count: 1)],
  };

  @override
  Future<ExpenseQueueSummary> summary() async => queueSummary;

  @override
  Future<int> rejectBatch(
    Iterable<String> ids,
    String reason, {
    Map<String, int> expectedVersions = const {},
  }) async {
    rejectBatchCalls.add([ids.toList().join(','), reason]);
    batchVersions.add(expectedVersions);
    return rejectGate == null ? ids.length : await rejectGate!.future;
  }
}

ExpenseClaim _claim(String id, {String applicantId = 'emp-1'}) => ExpenseClaim(
  id: id,
  claimNo: 'BX2026073000001$id',
  version: id == 'c-1' ? 3 : 8,
  applicantId: applicantId,
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

class _Reviewer extends SessionNotifier {
  _Reviewer(
    this.permissions, {
    this.employeeId = 'reviewer-employee',
    this.readOnly = false,
  });
  final Set<String> permissions;
  final String? employeeId;
  final bool readOnly;
  int intent = 0;
  @override
  int get requestIntentEpoch => intent;
  SessionState identity({
    String id = 'reviewer-user',
    String? employee,
    Set<String>? grants,
  }) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: id,
      code: 'R',
      name: '审批员',
      employeeId: employee ?? employeeId,
      permissions: (grants ?? permissions).toList(),
    ),
    impersonationReadOnly: readOnly,
  );
  @override
  SessionState build() => identity();
  void replace(SessionState next) {
    if (!state.isSameIdentity(next)) intent++;
    state = next;
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://expense.test/api')));
  Completer<void>? captureGate;
  Completer<void>? captureStarted;
  @override
  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) async {
    if (captureGate != null) {
      if (captureStarted?.isCompleted == false) captureStarted!.complete();
      await captureGate!.future;
    }
    return super.captureRequestScope(isCurrent: isCurrent);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async => const {};
}

Widget _app(
  _FakeExpenseRepository repo,
  SharedPreferences preferences, {
  ApprovalQueue? initialQueue,
  Set<String> permissions = const {Perm.expenseApprove},
  _Reviewer? reviewer,
  _Api? api,
  Widget? home,
}) {
  final session = reviewer ?? _Reviewer(permissions);
  return ProviderScope(
    overrides: [
      expenseRepositoryProvider.overrideWithValue(repo),
      sharedPreferencesProvider.overrideWithValue(preferences),
      sessionProvider.overrideWith(() => session),
      apiClientProvider.overrideWithValue(api ?? _Api()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home ?? ExpenseApprovalListPage(initialQueue: initialQueue),
    ),
  );
}

MasterDataTableView<ExpenseClaim> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<ExpenseClaim>>(
      find.byWidgetPredicate((w) => w is MasterDataTableView<ExpenseClaim>),
    );

void main() {
  testWidgets('确认框等待时撤权再恢复，旧确认不会提交或清掉新选择', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final reviewer = _Reviewer({Perm.expenseView, Perm.expenseApprove});
    final repo = _FakeExpenseRepository();
    await tester.pumpWidget(_app(repo, preferences, reviewer: reviewer));
    await tester.pumpAndSettle();
    _table(tester).onSelectedIdsChanged!({'c-1'});
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('expense-batch-reject')));
    await tester.tap(find.byKey(const Key('expense-batch-reject')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExpenseApprovalListPage)),
    );
    reviewer.replace(reviewer.identity(grants: {Perm.expenseView}));
    container.read(expenseActionEligibilityProvider);
    reviewer.replace(reviewer.identity());
    container.read(expenseActionEligibilityProvider);
    await tester.pumpAndSettle();
    _table(tester).onSelectedIdsChanged!({'c-2'});
    await tester.pump();
    expect(_table(tester).selectedIds, {'c-2'});
    await tester.enterText(
      find.byKey(const Key('uten-batch-reject-reason')),
      '旧意图不应重放',
    );
    await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
    await tester.pumpAndSettle();
    expect(repo.rejectBatchCalls, isEmpty);
    expect(_table(tester).selectedIds, {'c-2'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('批量通过同样全选排除本人并冻结他人原版本', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final reviewer = _Reviewer({
      Perm.expenseView,
      Perm.expenseApprove,
      Perm.attachmentView,
      Perm.attachmentDownload,
    });
    final own = _claim('own', applicantId: 'reviewer-employee');
    final repo = _FakeExpenseRepository()
      ..pendingItems = [own, _claim('other')];
    await tester.pumpWidget(_app(repo, preferences, reviewer: reviewer));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('master-data-table-select-all')),
    );
    await tester.tap(find.byKey(const Key('master-data-table-select-all')));
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, {'other'});
    await tester.ensureVisible(find.byKey(const Key('expense-batch-approve')));
    await tester.tap(find.byKey(const Key('expense-batch-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认批量通过'));
    await tester.pumpAndSettle();
    expect(repo.approveBatchCalls.single, ['other']);
    expect(repo.batchVersions.single, {'other': 8});
    expect(repo.rejectBatchCalls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('混合本人和他人待审单：真实表头全选只选可审批行，稳定行键和本人详情保留', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final reviewer = _Reviewer({Perm.expenseView, Perm.expenseApprove});
    final own = _claim('own', applicantId: 'reviewer-employee');
    final repo = _FakeExpenseRepository()
      ..pendingItems = [own, _claim('other')];
    await tester.pumpWidget(_app(repo, preferences, reviewer: reviewer));
    await tester.pumpAndSettle();
    expect(_table(tester).idOf!(own), isNull);
    expect(_table(tester).rowKeyOf!(own), 'own');
    expect(_table(tester).onRowTap, isNotNull);
    await tester.ensureVisible(
      find.byKey(const Key('master-data-table-select-all')),
    );
    await tester.tap(find.byKey(const Key('master-data-table-select-all')));
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, {'other'});
    await tester.ensureVisible(find.byKey(const Key('expense-batch-reject')));
    await tester.tap(find.byKey(const Key('expense-batch-reject')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-batch-reject-reason')),
      '补充凭证',
    );
    await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
    await tester.pumpAndSettle();
    expect(repo.rejectBatchCalls.single.first, 'other');
    expect(repo.batchVersions.single, {'other': 8});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    repo.detail = own;
    await tester.pumpWidget(
      _app(
        repo,
        preferences,
        reviewer: _Reviewer({Perm.expenseView, Perm.expenseApprove}),
        home: const ExpenseApprovalDetailPage(claimId: 'own'),
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.detailCalls, contains('own'));
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).floatingActionButton,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final unresolved in [false, true]) {
    testWidgets('只读模拟或未解析员工身份不会因approve码开放选择：unresolved=$unresolved', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final repo = _FakeExpenseRepository();
      final reviewer = _Reviewer(
        {Perm.expenseView, Perm.expenseApprove},
        employeeId: unresolved ? null : 'reviewer-employee',
        readOnly: !unresolved,
      );
      await tester.pumpWidget(_app(repo, preferences, reviewer: reviewer));
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(2));
      expect(_table(tester).selectable, isFalse);
      expect(_table(tester).idOf!(_table(tester).items.first), isNull);
      expect(_table(tester).batchActionsBuilder, isNull);
      expect(repo.rejectBatchCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('换身份、撤权和重新授权均清除旧选择', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final reviewer = _Reviewer({Perm.expenseView, Perm.expenseApprove});
    await tester.pumpWidget(
      _app(_FakeExpenseRepository(), preferences, reviewer: reviewer),
    );
    await tester.pumpAndSettle();
    _table(tester).onSelectedIdsChanged!({'c-1'});
    await tester.pump();
    reviewer.replace(
      reviewer.identity(id: 'second', employee: 'second-employee'),
    );
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, isEmpty);
    _table(tester).onSelectedIdsChanged!({'c-2'});
    await tester.pump();
    reviewer.replace(
      reviewer.identity(
        id: 'second',
        employee: 'second-employee',
        grants: {Perm.expenseView},
      ),
    );
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, isEmpty);
    expect(_table(tester).selectable, isFalse);
    reviewer.replace(
      reviewer.identity(id: 'second', employee: 'second-employee'),
    );
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final identityChange in [false, true]) {
    testWidgets('凭据等待期间A-B-A或撤权恢复不能复活旧批量意图：identity=$identityChange', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final reviewer = _Reviewer({Perm.expenseView, Perm.expenseApprove});
      final api = _Api();
      final repo = _FakeExpenseRepository();
      await tester.pumpWidget(
        _app(repo, preferences, reviewer: reviewer, api: api),
      );
      await tester.pumpAndSettle();
      _table(tester).onSelectedIdsChanged!({'c-1'});
      await tester.pumpAndSettle();
      api.captureGate = Completer<void>();
      api.captureStarted = Completer<void>();
      await tester.ensureVisible(find.byKey(const Key('expense-batch-reject')));
      await tester.tap(find.byKey(const Key('expense-batch-reject')));
      await tester.pump();
      await api.captureStarted!.future;
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ExpenseApprovalListPage)),
      );
      reviewer.replace(
        identityChange
            ? reviewer.identity(id: 'second', employee: 'second-employee')
            : reviewer.identity(grants: {Perm.expenseView}),
      );
      container.read(expenseActionEligibilityProvider);
      reviewer.replace(reviewer.identity());
      container.read(expenseActionEligibilityProvider);
      await tester.pump();
      api.captureGate!.complete();
      await tester.pumpAndSettle();
      expect(repo.rejectBatchCalls, isEmpty);
      expect(_table(tester).selectedIds, isEmpty);
      expect(find.byType(UtenBatchRejectDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('旧批量响应不清空新身份选择、不显示旧成功消息', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final reviewer = _Reviewer({Perm.expenseView, Perm.expenseApprove});
    final repo = _FakeExpenseRepository()..rejectGate = Completer<int>();
    await tester.pumpWidget(_app(repo, preferences, reviewer: reviewer));
    await tester.pumpAndSettle();
    _table(tester).onSelectedIdsChanged!({'c-1'});
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('expense-batch-reject')));
    await tester.tap(find.byKey(const Key('expense-batch-reject')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-batch-reject-reason')),
      '补充凭证',
    );
    await tester.tap(find.byKey(const Key('uten-batch-reject-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(repo.rejectBatchCalls, hasLength(1));
    reviewer.replace(
      reviewer.identity(id: 'second', employee: 'second-employee'),
    );
    await tester.pumpAndSettle();
    _table(tester).onSelectedIdsChanged!({'c-2'});
    await tester.pump();
    repo.rejectGate!.complete(1);
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, {'c-2'});
    expect(find.textContaining('已驳回 1 单报销'), findsNothing);
    expect(repo.rejectBatchCalls, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('missing task counts never promote legacy browsing totals to tasks', () {
    final summary = ExpenseQueueSummary.fromJson({
      'pendingCount': 7,
      'payableCount': 5,
    });
    expect(summary.pendingCount, 7);
    expect(summary.payableCount, 5);
    expect(summary.actionablePendingCount, 0);
    expect(summary.actionablePayableCount, 0);
  });

  for (final handles in [false, true]) {
    testWidgets('报销浏览数量和实际办理数量独立呈现：handles=$handles', (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final repo = _FakeExpenseRepository()
        ..queueSummary = const ExpenseQueueSummary(
          pendingCount: 7,
          pendingAmount: 700,
          payableCount: 5,
          payableAmount: 500,
          monthSubmittedCount: 12,
          monthSubmittedAmount: 1200,
          monthPaidCount: 0,
          monthPaidAmount: 0,
          actionablePendingCount: 2,
          actionablePayableCount: 1,
        );
      await tester.pumpWidget(
        _app(
          repo,
          preferences,
          initialQueue: ApprovalQueue.pending,
          permissions: {
            Perm.expenseView,
            if (handles) ...[Perm.expenseApprove, Perm.expensePay],
          },
        ),
      );
      await tester.pumpAndSettle();
      final toolbar = tester.widget<UtenFilterToolbar<ApprovalQueue>>(
        find.byWidgetPredicate(
          (widget) => widget is UtenFilterToolbar<ApprovalQueue>,
        ),
      );
      final pending = toolbar.segments.singleWhere(
        (segment) => segment.value == ApprovalQueue.pending,
      );
      final payable = toolbar.segments.singleWhere(
        (segment) => segment.value == ApprovalQueue.payable,
      );
      expect(pending.count, handles ? 2 : 7);
      expect(payable.count, handles ? 1 : 5);
      expect(
        pending.countForm,
        handles
            ? UtenSegmentCountForm.actionable
            : UtenSegmentCountForm.browsing,
      );
      expect(payable.countForm, pending.countForm);
      expect(find.textContaining('待审批 7 单'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('只读报销账号可切换待审和历史，行可打开但不出现审批选择及动作', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeExpenseRepository();
    await tester.pumpWidget(
      _app(
        repo,
        preferences,
        initialQueue: ApprovalQueue.pending,
        permissions: const {Perm.expenseView},
      ),
    );
    await tester.pumpAndSettle();
    expect(_table(tester).items, hasLength(2));
    expect(_table(tester).onRowTap, isNotNull);
    expect(_table(tester).selectable, isFalse);
    expect(_table(tester).batchActionsBuilder, isNull);
    expect(find.text('待付款'), findsOneWidget);
    expect(find.text('全部单据'), findsOneWidget);
    expect(repo.rejectBatchCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final queue in [ApprovalQueue.payable, ApprovalQueue.history]) {
    testWidgets('明确队列入口只读请求所选队列，不先加载待审批：$queue', (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final repo = _FakeExpenseRepository();
      await tester.pumpWidget(
        _app(
          repo,
          preferences,
          initialQueue: queue,
          permissions: const {Perm.expenseApprove, Perm.expensePay},
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.pendingCalls, isEmpty);
      expect(
        queue == ApprovalQueue.payable ? repo.payableCalls : repo.historyCalls,
        hasLength(1),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ExpenseApprovalListPage)),
      );
      expect(container.read(approvalQueueProvider), queue);
      expect(
        _table(tester).items.single.status,
        queue == ApprovalQueue.payable
            ? ExpenseClaimStatus.approved
            : ExpenseClaimStatus.paid,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('无付款权限的待付款深链不能调用付款队列', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeExpenseRepository();
    await tester.pumpWidget(
      _app(repo, preferences, initialQueue: ApprovalQueue.payable),
    );
    await tester.pumpAndSettle();
    expect(repo.pendingCalls, hasLength(1));
    expect(repo.payableCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('同一报销页切换深链队列时清除旧勾选，重新加载正确队列', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeExpenseRepository();
    await tester.pumpWidget(
      _app(
        repo,
        preferences,
        initialQueue: ApprovalQueue.pending,
        permissions: const {Perm.expenseApprove, Perm.expensePay},
      ),
    );
    await tester.pumpAndSettle();
    _table(tester).onSelectedIdsChanged!({'c-1'});
    await tester.pump();
    await tester.pumpWidget(
      _app(
        repo,
        preferences,
        initialQueue: ApprovalQueue.payable,
        permissions: const {Perm.expenseApprove, Perm.expensePay},
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.payableCalls, hasLength(1));
    expect(_table(tester).items.single.status, ExpenseClaimStatus.approved);
    expect(_table(tester).selectedIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('claimNo header filter and sort hit the backend', (tester) async {
    // 2026-09-25 单号列统一：报销单号列头值筛选（服务端精确匹配）与排序
    // （claimNo 白名单）下推后端；桶来自服务端 facets（claimNo 键）。
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeExpenseRepository();
    await tester.pumpWidget(_app(repo, preferences));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.facets['claimNo']!.single.value, 'BX2026073000001');
    // 2026-10-06 全站口径：状态列排第一可见列；单号列按 key 定位。
    expect(table.columns.first.key, 'status');
    final claimNo = table.columns.singleWhere((c) => c.key == 'claimNo');
    expect(claimNo.sortable, isTrue);

    table.onFilterChanged('claimNo', 'BX2026073000001');
    await tester.pumpAndSettle();
    expect(repo.pendingCalls.last['claimNo'], 'BX2026073000001');
    expect(repo.pendingCalls.last['page'], 1);

    _table(tester).onSortChange?.call('claimNo', false);
    await tester.pumpAndSettle();
    expect(repo.pendingCalls.last['sort'], 'claimNo');
    expect(repo.pendingCalls.last['order'], 'desc');

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
