// 订货审批审核详情页（财务专用视图）测试：
//  - 卡片结构（状态条/供应商快照/订单信息/明细/审批历史）与底部三操作；
//  - 通过：选填备注随单笔 batch-approve 提交，成功后 pop(true) 回列表；
//  - 驳回：原因必填，空原因内联报错；
//  - 非 PENDING / 无动作 case 不渲染底栏（服务端 allowedActions 为准）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_review_page.dart';
import 'package:uten_imp/features/finance/providers/finance_procurement_approval_count_provider.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _FakeWorkflowRepo implements FinanceProcurementWorkflowRepository {
  _FakeWorkflowRepo(this.reviewResult);

  FinanceProcurementApprovalReview reviewResult;
  String? requestedCaseId;
  final List<({List<FinanceProcurementDecisionItem> items, String? remark})>
  approved = [];
  final List<({List<FinanceProcurementDecisionItem> items, String reason})>
  rejected = [];

  @override
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
    FinanceProcurementOrderType? orderType,
    String? keyword,
  }) async => const FinanceProcurementApprovalPage(
    items: [],
    page: 1,
    size: 20,
    total: 0,
    totalPages: 1,
  );

  @override
  Future<int> pendingApprovalCount() async => 1;

  @override
  Future<Map<String, int>> approvalTypeCounts() async => {'PURCHASE': 1};

  @override
  Future<FinanceProcurementApprovalReview> review(String caseId) async {
    requestedCaseId = caseId;
    return reviewResult;
  }

  @override
  Future<void> approveOrdersBatch(
    List<FinanceProcurementDecisionItem> items, {
    String? remark,
  }) async {
    approved.add((items: List.of(items), remark: remark));
  }

  @override
  Future<void> rejectOrdersBatch(
    List<FinanceProcurementDecisionItem> items,
    String reason,
  ) async {
    rejected.add((items: List.of(items), reason: reason));
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

FinanceProcurementApprovalReview _pendingReview({
  String status = 'PENDING',
  Set<String> allowedActions = const {'APPROVE', 'REJECT'},
}) => FinanceProcurementApprovalReview.fromJson({
  'caseId': 'case-1',
  'orderId': 'order-1',
  'orderType': 'PURCHASE',
  'billNo': 'PO-2026-001',
  'status': status,
  'attempt': 2,
  'version': 3,
  'allowedActions': allowedActions.toList(),
  'submittedByName': '张三',
  'submittedAt': '2026-09-02T02:00:00+08:00',
  'billDate': '2026-09-01',
  'supplierName': '供应商A',
  'supplierCode': 'S-001',
  'warehouseName': '一号仓',
  'currencyName': '美元',
  'exchangeRate': '7.1',
  'settlementMethodName': '月结30天',
  'taxRate': '13',
  'purchaserName': '采购员甲',
  'makerName': '制单员乙',
  'deliverDate': '2026-09-15',
  'remark': '加急',
  'totalOriginal': '10000',
  'totalLocal': '71000',
  'supplierApBalance': '12500.50',
  'sourceApplicationCount': 2,
  'items': [
    {
      'lineNo': 1,
      'goodsCode': 'G001',
      'goodsName': '铜线',
      'colorName': '裸色',
      'unitName': '公斤',
      'unitRate': '1',
      'qty': '100',
      'price': '100',
      'amountOriginal': '10000',
      'amountLocal': '71000',
      'deliverDate': '2026-09-15',
      'sourceDocNo': 'PR-2026-010',
    },
  ],
  'history': [
    {
      'attempt': 1,
      'eventType': 'SUBMITTED',
      'actorName': '张三',
      'occurredAt': '2026-09-01T01:00:00+08:00',
    },
    {
      'attempt': 1,
      'eventType': 'REJECTED',
      'actorName': '财务王五',
      'occurredAt': '2026-09-01T05:00:00+08:00',
      'reason': '单价待复核',
    },
    {
      'attempt': 2,
      'eventType': 'SUBMITTED',
      'actorName': '张三',
      'occurredAt': '2026-09-02T02:00:00+08:00',
    },
  ],
});

Future<GoRouter> _pumpReviewPage(
  WidgetTester tester,
  _FakeWorkflowRepo repository, {
  bool withApprovePerms = true,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: '/finance/procurement-approvals/case-1',
    routes: [
      GoRoute(
        path: '/finance/procurement-approvals/:caseId',
        builder: (_, state) => FinanceProcurementApprovalReviewPage(
          caseId: state.pathParameters['caseId']!,
        ),
      ),
      GoRoute(
        path: '/finance/procurement-approvals',
        builder: (_, _) => const Scaffold(body: Text('任务中心列表')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeOrderApprovalView,
          if (withApprovePerms) ...{
            Perm.financeOrderApprovalApprove,
            Perm.financeOrderApprovalReject,
          },
        }),
        sessionProvider.overrideWith(_FinanceReviewerSessionNotifier.new),
        financeProcurementApprovalCountProvider.overrideWith((ref) async => 1),
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
  testWidgets('renders finance-scoped cards with bottom decision bar', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(_pendingReview());
    await _pumpReviewPage(tester, repository);

    expect(repository.requestedCaseId, 'case-1');
    expect(find.text('PO-2026-001'), findsOneWidget);
    expect(find.text('采购订货 · 第 2 轮'), findsOneWidget);
    expect(find.text('待财务审核 · 通过后订货生效并生成仓库预计到货任务'), findsOneWidget);
    expect(find.text('供应商财务快照 · 供应商A(S-001)'), findsOneWidget);
    expect(find.text('12500.50'), findsOneWidget, reason: '应付余额格式化展示');
    expect(find.text('美元'), findsWidgets);
    expect(find.text('G001 · 铜线(裸色 · 公斤)'), findsOneWidget);
    expect(find.text('PR-2026-010'), findsOneWidget);
    expect(find.text('原因：单价待复核'), findsOneWidget);
    expect(find.byKey(const Key('finance-order-review-back')), findsOneWidget);
    expect(
      find.byKey(const Key('finance-order-review-reject')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('finance-order-review-approve')),
      findsOneWidget,
    );
  });

  testWidgets('approve submits single decision with optional remark', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(_pendingReview());
    final router = await _pumpReviewPage(tester, repository);

    await tester.tap(find.byKey(const Key('finance-order-review-approve')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('finance-order-review-approve-remark')),
      '已核对供应商账期',
    );
    await tester.tap(
      find.byKey(const Key('finance-order-review-approve-submit')),
    );
    await tester.pumpAndSettle();

    expect(repository.approved, hasLength(1));
    expect(repository.approved.single.remark, '已核对供应商账期');
    expect(repository.approved.single.items.single.toJson(), {
      'caseId': 'case-1',
      'expectedVersion': 3,
    });
    // 决策完成 → pop(true) 回任务中心。
    expect(find.text('任务中心列表'), findsOneWidget);
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/finance/procurement-approvals',
    );
  });

  testWidgets('reject requires a reason before submit', (tester) async {
    final repository = _FakeWorkflowRepo(_pendingReview());
    await _pumpReviewPage(tester, repository);

    await tester.tap(find.byKey(const Key('finance-order-review-reject')));
    await tester.pumpAndSettle();
    // 空原因：内联校验拦截，不提交。
    await tester.tap(
      find.byKey(const Key('finance-order-review-reject-submit')),
    );
    await tester.pump();
    expect(find.text('请填写驳回原因'), findsOneWidget);
    expect(repository.rejected, isEmpty);

    await tester.enterText(
      find.byKey(const Key('finance-order-review-reject-reason')),
      '税率与结算方式需要重新确认',
    );
    await tester.tap(
      find.byKey(const Key('finance-order-review-reject-submit')),
    );
    await tester.pumpAndSettle();

    expect(repository.rejected, hasLength(1));
    expect(repository.rejected.single.reason, '税率与结算方式需要重新确认');
    expect(find.text('任务中心列表'), findsOneWidget);
  });

  testWidgets('decided case renders read-only without decision bar', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(
      _pendingReview(status: 'APPROVED', allowedActions: const {}),
    );
    await _pumpReviewPage(tester, repository);

    expect(find.text('已通过 · 订货已生效'), findsOneWidget);
    expect(find.byKey(const Key('finance-order-review-approve')), findsNothing);
    expect(find.byKey(const Key('finance-order-review-reject')), findsNothing);
    expect(find.byKey(const Key('finance-order-review-back')), findsNothing);
  });

  testWidgets('pending case without server actions stays read-only', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo(
      _pendingReview(allowedActions: const {}),
    );
    await _pumpReviewPage(tester, repository);

    expect(find.byKey(const Key('finance-order-review-approve')), findsNothing);
    expect(find.byKey(const Key('finance-order-review-reject')), findsNothing);
  });
}
