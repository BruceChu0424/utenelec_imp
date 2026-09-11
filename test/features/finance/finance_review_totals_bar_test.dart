// 财务审核详情页明细合计条（UtenTotalsSummaryBar）契约：
//  - 订货审批审核详情 / 销售订单财务审核详情都在明细表下渲染合计条；
//  - 「合计数量」按 unitId 分组，不同单位的数量绝不相加（显示「100 公斤 · 3 箱」）；
//  - 「合计金额(币种)」取服务端权威总额并标红（error 色）；
//  - 销售订单阶段不落本币事实，故销售审核详情不出「折合本币」项。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_review_page.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_review_page.dart';
import 'package:uten_imp/features/finance/providers/finance_procurement_approval_count_provider.dart';
import 'package:uten_imp/features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';
import 'package:uten_imp/features/finance/repositories/sales_order_finance_confirmation_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';

import '../../helpers/finance_claim_fixture.dart';

void main() {
  testWidgets('订货审批审核详情：合计数量按单位分组，合计金额标红，折合本币可见', (tester) async {
    await _pumpProcurementReview(tester);

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    expect(find.text('合计数量: '), findsOneWidget);
    // 100 公斤 + 3 箱 绝不合并成 103（分组顺序按 unitId 稳定排序）。
    expect(find.text('3 箱 · 100 公斤'), findsOneWidget);
    expect(find.text('103'), findsNothing);

    expect(find.text('合计金额(美元): '), findsOneWidget);
    expect(_valueColor(tester, '10000.00'), _errorColor(tester));
    expect(find.text('折合本币: '), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(UtenTotalsSummaryBar),
        matching: find.text('71000.00'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('销售订单财务审核详情：合计数量按单位分组，合计金额标红，无折合本币项', (tester) async {
    await _pumpSalesReview(tester);

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    expect(find.text('合计数量: '), findsOneWidget);
    expect(find.text('3 箱 · 12 个'), findsOneWidget);
    expect(find.text('15'), findsNothing);

    expect(find.text('合计金额(美元): '), findsOneWidget);
    expect(_valueColor(tester, '2400.00'), _errorColor(tester));
    // 销售阶段本币事实为空，合计条整体隐藏该项。
    expect(find.text('折合本币: '), findsNothing);
  });

  testWidgets('单位缺失的明细行落入「单位未维护」桶而不是并入其它单位', (tester) async {
    await _pumpProcurementReview(tester, missingUnitOnSecondLine: true);

    expect(find.text('100 公斤 · 3 单位未维护'), findsOneWidget);
  });
}

Color? _errorColor(WidgetTester tester) => Theme.of(
  tester.element(find.byType(UtenTotalsSummaryBar)),
).colorScheme.error;

/// 只取合计条内部的数值 Text（页面头部快照卡可能有同值文本）。
Color? _valueColor(WidgetTester tester, String value) => tester
    .widget<Text>(
      find.descendant(
        of: find.byType(UtenTotalsSummaryBar),
        matching: find.text(value),
      ),
    )
    .style
    ?.color;

// ---------------------------------------------------------------- 订货审批
Map<String, dynamic> _procurementReviewJson({
  required bool missingUnitOnSecondLine,
}) => {
  'caseId': 'case-1',
  'orderId': 'order-1',
  'orderType': 'PURCHASE',
  'billNo': 'PO-2026-001',
  'status': 'PENDING',
  'attempt': 1,
  'version': 1,
  'allowedActions': const <String>['APPROVE', 'REJECT'],
  'submittedByName': '张三',
  'submittedAt': '2026-09-02T02:00:00+08:00',
  'billDate': '2026-09-01',
  'supplierName': '供应商A',
  'supplierCode': 'S-001',
  'currencyName': '美元',
  'exchangeRate': '7.1',
  'taxRate': '13',
  'totalOriginal': '10000',
  'totalLocal': '71000',
  'supplierApBalance': '12500.50',
  'sourceApplicationCount': 1,
  'items': [
    {
      'lineNo': 1,
      'goodsCode': 'G001',
      'goodsName': '铜线',
      'unitId': 'unit-kg',
      'unitName': '公斤',
      'qty': '100',
      'price': '100',
      'amountOriginal': '10000',
      'amountLocal': '71000',
    },
    {
      'lineNo': 2,
      'goodsCode': 'G002',
      'goodsName': '包装箱',
      if (!missingUnitOnSecondLine) 'unitId': 'unit-box',
      if (!missingUnitOnSecondLine) 'unitName': '箱',
      'qty': '3',
      'price': '0',
      'amountOriginal': '0',
      'amountLocal': '0',
    },
  ],
  'history': const <Map<String, dynamic>>[],
};

Future<void> _pumpProcurementReview(
  WidgetTester tester, {
  bool missingUnitOnSecondLine = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final review = FinanceProcurementApprovalReview.fromJson(
    _procurementReviewJson(missingUnitOnSecondLine: missingUnitOnSecondLine),
  );
  final router = GoRouter(
    initialLocation: '/finance/procurement-approvals/case-1',
    routes: [
      GoRoute(
        path: '/finance/procurement-approvals/:caseId',
        builder: (_, state) => FinanceProcurementApprovalReviewPage(
          caseId: state.pathParameters['caseId']!,
        ),
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
        }),
        sessionProvider.overrideWith(_ReviewerSessionNotifier.new),
        taskClaimRepositoryProvider.overrideWithValue(FinanceClaimFixture()),
        financeProcurementApprovalCountProvider.overrideWith((ref) async => 1),
        financeProcurementWorkflowRepositoryProvider.overrideWithValue(
          _FakeWorkflowRepo(review),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ReviewerSessionNotifier extends SessionNotifier {
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

class _FakeWorkflowRepo implements FinanceProcurementWorkflowRepository {
  _FakeWorkflowRepo(this.reviewResult);

  final FinanceProcurementApprovalReview reviewResult;

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
  Future<FinanceProcurementApprovalReview> review(String caseId) async =>
      reviewResult;

  @override
  Future<void> approveOrdersBatch(
    List<FinanceProcurementDecisionItem> items, {
    String? remark,
  }) async {}

  @override
  Future<void> rejectOrdersBatch(
    List<FinanceProcurementDecisionItem> items,
    String reason,
  ) async {}
}

// ------------------------------------------------------- 销售订单财务审核详情
Future<void> _pumpSalesReview(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final review = SalesOrderFinanceReview.fromJson(const {
    'orderId': 'order-1',
    'billNo': 'SO-2026-001',
    'billDate': '2026-09-01',
    'clientName': '客户甲',
    'clientCode': 'C-001',
    'currencyName': '美元',
    'totalOriginal': '2400',
    'financeReviewRevision': 1,
    'items': [
      {
        'itemId': 'item-1',
        'lineNo': 1,
        'goodsCode': 'G001',
        'goodsName': '成品A',
        'unitId': 'unit-pcs',
        'unitName': '个',
        'qty': '12',
        'price': '200',
        'discount': '1',
        'amountOriginal': '2400',
      },
      {
        'itemId': 'item-2',
        'lineNo': 2,
        'goodsCode': 'G002',
        'goodsName': '包装箱',
        'unitId': 'unit-box',
        'unitName': '箱',
        'qty': '3',
        'price': '0',
        'discount': '1',
        'amountOriginal': '0',
      },
    ],
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.salesOrderFinanceView,
        }),
        sessionProvider.overrideWith(_ReviewerSessionNotifier.new),
        salesOrderFinanceConfirmationCountProvider.overrideWith(
          (ref) async => 0,
        ),
        salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
          _FakeSalesReviewRepo(review),
        ),
        taskClaimRepositoryProvider.overrideWithValue(FinanceClaimFixture()),
      ],
      child: MaterialApp(home: FinanceSalesOrderReviewPage(id: review.orderId)),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeSalesReviewRepo implements SalesOrderFinanceConfirmationRepository {
  _FakeSalesReviewRepo(this.reviewValue);

  final SalesOrderFinanceReview reviewValue;

  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
  }) async => const SalesOrderFinancePendingPage(
    items: [],
    page: 1,
    size: 20,
    total: 0,
    totalPages: 1,
  );

  @override
  Future<int> pendingCount({bool? changesOnly}) async => 0;

  @override
  Future<SalesOrderFinanceReview> review(String orderId) async => reviewValue;

  @override
  Future<void> confirm(
    String orderId, {
    String? remark,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {}

  @override
  Future<void> confirmBatch(
    Iterable<String> orderIds, {
    String? remark,
    Map<String, int>? expectedRevisions,
    Map<String, String>? expectedClaimIds,
  }) async {}

  @override
  Future<void> reject(
    String orderId, {
    required String reason,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {}
}
