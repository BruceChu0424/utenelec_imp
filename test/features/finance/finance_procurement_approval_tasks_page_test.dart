import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_tasks_page.dart';
import 'package:uten_imp/features/finance/providers/finance_procurement_approval_count_provider.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _FakeWorkflowRepo implements FinanceProcurementWorkflowRepository {
  _FakeWorkflowRepo(this.items);

  final List<FinanceProcurementApprovalTask> items;
  final List<List<FinanceProcurementDecisionItem>> approvedBatches = [];
  final List<({List<FinanceProcurementDecisionItem> items, String reason})>
  rejectedBatches = [];
  String? lastKeyword;
  FinanceProcurementOrderType? lastOrderType;

  @override
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
    FinanceProcurementOrderType? orderType,
    String? keyword,
  }) async {
    lastKeyword = keyword;
    lastOrderType = orderType;
    return FinanceProcurementApprovalPage(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  Future<int> pendingApprovalCount() async => items.length;

  @override
  Future<Map<String, int>> approvalTypeCounts() async => {
    'PURCHASE': items
        .where((task) => task.orderType == FinanceProcurementOrderType.purchase)
        .length,
    'SUBCONTRACT': items
        .where(
          (task) => task.orderType == FinanceProcurementOrderType.subcontract,
        )
        .length,
  };

  @override
  Future<FinanceProcurementApprovalReview> review(String caseId) async {
    return FinanceProcurementApprovalReview.fromJson({
      'caseId': caseId,
      'orderId': 'order-1',
      'orderType': 'PURCHASE',
      'billNo': 'PO-2026-001',
      'status': 'PENDING',
      'attempt': 1,
      'version': 3,
      'allowedActions': const ['APPROVE', 'REJECT'],
    });
  }

  @override
  Future<void> approveOrdersBatch(
    List<FinanceProcurementDecisionItem> items, {
    String? remark,
  }) async {
    approvedBatches.add(List.of(items));
  }

  @override
  Future<void> rejectOrdersBatch(
    List<FinanceProcurementDecisionItem> items,
    String reason,
  ) async {
    rejectedBatches.add((items: List.of(items), reason: reason));
  }
}

class _FinanceReviewerSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'finance-reviewer',
      code: 'FIN001',
      name: '财务李四',
      roles: [],
    ),
  );
}

FinanceProcurementApprovalTask _task({
  required String caseId,
  required String orderId,
  required String orderType,
  required String billNo,
  List<String> allowedActions = const ['APPROVE', 'REJECT'],
}) => FinanceProcurementApprovalTask.fromJson({
  'caseId': caseId,
  'orderId': orderId,
  'orderType': orderType,
  'billNo': billNo,
  'supplierName': orderType == 'PURCHASE' ? '供应商A' : '委外商B',
  'warehouseName': '一号仓',
  'amount': orderType == 'PURCHASE' ? '1200.50' : '800.00',
  'submittedByName': '张三',
  'submittedAt': '2026-08-18T02:00:00+08:00',
  'expectedDate': '2026-09-01',
  'attempt': 1,
  'status': 'PENDING',
  'version': 3,
  'allowedActions': allowedActions,
});

Future<GoRouter> _pumpPage(
  WidgetTester tester,
  _FakeWorkflowRepo repository, {
  Size size = const Size(1400, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: '/finance/procurement-approvals',
    routes: [
      GoRoute(
        path: '/finance/procurement-approvals',
        builder: (_, _) => const FinanceProcurementApprovalTasksPage(),
      ),
      GoRoute(
        path: '/finance/procurement-approvals/:caseId',
        builder: (_, state) =>
            Scaffold(body: Text('审核详情 ${state.pathParameters['caseId']}')),
      ),
      GoRoute(
        path: '/purchase/orders/:id',
        builder: (_, state) =>
            Scaffold(body: Text('采购详情 ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/subcontract/orders/:id',
        builder: (_, state) =>
            Scaffold(body: Text('委外详情 ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.financeOrderApprovalView,
          Perm.financeOrderApprovalApprove,
          Perm.financeOrderApprovalReject,
        }),
        sessionProvider.overrideWith(_FinanceReviewerSessionNotifier.new),
        financeProcurementApprovalCountProvider.overrideWith(
          (ref) async => repository.items.length,
        ),
        financeProcurementWorkflowRepositoryProvider.overrideWithValue(
          repository,
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets(
    'uses a selectable table and atomic bottom-right approve/reject actions',
    (tester) async {
      final repository = _FakeWorkflowRepo([
        _task(
          caseId: 'case-1',
          orderId: 'order-1',
          orderType: 'PURCHASE',
          billNo: 'PO-2026-001',
        ),
        _task(
          caseId: 'case-2',
          orderId: 'order-2',
          orderType: 'SUBCONTRACT',
          billNo: 'SO-2026-002',
        ),
      ]);
      await _pumpPage(tester, repository);

      expect(
        find.byKey(const Key('finance-approval-type-cards')),
        findsNothing,
      );
      expect(find.byType(Card), findsNothing);
      expect(
        find.byKey(const Key('finance-approval-task-table')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('finance-approval-approve-case-1')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('finance-approval-reject-case-1')),
        findsNothing,
      );

      var table = tester
          .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
            find.byKey(const Key('finance-approval-task-table')),
          );
      final columnKeys = table.columns.map((column) => column.key).toList();
      expect(
        columnKeys,
        containsAll(<String>[
          'orderType',
          'billNo',
          'supplierName',
          'amount',
          'expectedDate',
          'submittedByName',
          'submittedAt',
          'attempt',
        ]),
      );

      table.onSelectedIdsChanged?.call({'case-1', 'case-2'});
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(
        find.byKey(const Key('finance-approval-batch-approve')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('finance-approval-batch-reject')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('finance-approval-batch-approve')));
      await tester.pumpAndSettle();
      expect(find.text('批量通过(2 笔)'), findsOneWidget);
      expect(find.text('审核员：财务李四(FIN001)'), findsOneWidget);
      await tester.tap(find.text('确认批量通过'));
      await tester.pumpAndSettle();

      expect(repository.approvedBatches, hasLength(1));
      expect(repository.approvedBatches.single.map((item) => item.toJson()), [
        {'caseId': 'case-1', 'expectedVersion': 3},
        {'caseId': 'case-2', 'expectedVersion': 3},
      ]);

      table = tester
          .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
            find.byKey(const Key('finance-approval-task-table')),
          );
      table.onSelectedIdsChanged?.call({'case-1', 'case-2'});
      await tester.pump();
      await tester.tap(find.byKey(const Key('finance-approval-batch-reject')));
      await tester.pumpAndSettle();
      expect(find.text('批量驳回(2 笔)'), findsOneWidget);
      final reason = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '退回原因(必填)',
      );
      await tester.enterText(reason, '价格与交期需要重新确认');
      await tester.pump();
      await tester.tap(find.text('确认批量驳回'));
      await tester.pumpAndSettle();

      expect(find.text('批量驳回(2 笔)'), findsNothing);
      expect(repository.rejectedBatches, hasLength(1));
      expect(repository.rejectedBatches.single.reason, '价格与交期需要重新确认');
      expect(repository.rejectedBatches.single.items, hasLength(2));
    },
  );

  testWidgets('single click selects and same-row double click opens review', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo([
      _task(
        caseId: 'case-1',
        orderId: 'order-1',
        orderType: 'PURCHASE',
        billNo: 'PO-2026-001',
      ),
    ]);
    final router = await _pumpPage(tester, repository);

    await tester.tap(find.text('PO-2026-001'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('PO-2026-001'));
    await tester.pumpAndSettle();

    // 双击落点是财务专用审核详情页（按审批 case 定位），不再跳共享订单详情。
    expect(find.text('审核详情 case-1'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('PO-2026-001'), findsOneWidget);
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(
      find.byKey(const Key('finance-approval-batch-approve')),
      findsOneWidget,
    );
  });

  testWidgets('search clears selection and compact mode remains card-free', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo([
      _task(
        caseId: 'case-1',
        orderId: 'order-1',
        orderType: 'PURCHASE',
        billNo: 'PO-2026-001',
      ),
    ]);
    await _pumpPage(tester, repository, size: const Size(375, 812));

    await tester.tap(find.text('PO-2026-001'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('单击选择，双击或长按打开审核详情'), findsOneWidget);
    final approve = find.byKey(const Key('finance-approval-batch-approve'));
    final reject = find.byKey(const Key('finance-approval-batch-reject'));
    expect(approve.hitTestable(), findsOneWidget);
    expect(reject.hitTestable(), findsOneWidget);
    expect(tester.getRect(approve).bottom, lessThanOrEqualTo(812));
    expect(tester.getRect(reject).bottom, lessThanOrEqualTo(812));

    final search = find.descendant(
      of: find.byKey(const Key('finance-approval-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, '供应商A');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(repository.lastKeyword, '供应商A');
    final table = tester
        .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
          find.byKey(const Key('finance-approval-task-table')),
        );
    expect(table.selectedIds, isEmpty);
    expect(find.byType(Card), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server denied allowedActions keeps the table read-only', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo([
      _task(
        caseId: 'case-1',
        orderId: 'order-1',
        orderType: 'PURCHASE',
        billNo: 'PO-2026-001',
        allowedActions: const [],
      ),
    ]);
    await _pumpPage(tester, repository);

    final table = tester
        .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
          find.byKey(const Key('finance-approval-task-table')),
        );
    expect(table.selectable, isFalse);
    expect(
      find.byKey(const Key('finance-approval-batch-approve')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('finance-approval-batch-reject')),
      findsNothing,
    );
  });
}
