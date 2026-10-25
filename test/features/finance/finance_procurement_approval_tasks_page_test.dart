import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_tasks_page.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import '../../helpers/finance_claim_fixture.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/audit_screenshot_support.dart';

class _FakeWorkflowRepo implements FinanceProcurementWorkflowRepository {
  @override
  Future<List<MasterFacetBucket>> approvalBillNoFacets({
    FinanceProcurementOrderType? orderType,
    String? keyword,
    String status = 'PENDING',
  }) async => const []; // 2026-09-25 单号列统一：页面 facets 静默降级。
  _FakeWorkflowRepo(this.items);

  final List<FinanceProcurementApprovalTask> items;
  final List<List<FinanceProcurementDecisionItem>> approvedBatches = [];
  final List<({List<FinanceProcurementDecisionItem> items, String reason})>
  rejectedBatches = [];
  String? lastKeyword;
  FinanceProcurementOrderType? lastOrderType;
  Object? reviewError;
  int taskReads = 0;

  @override
  Future<FinanceProcurementApprovalPage> approvalTasks({
    int page = 1,
    int size = 20,
    FinanceProcurementOrderType? orderType,
    String? keyword,
    String? sort,
    String? order,
    String? billNo,
    String status = 'PENDING',
  }) async {
    taskReads++;
    lastKeyword = keyword;
    lastOrderType = orderType;
    final filtered = items
        .where(
          (item) =>
              (status == 'ALL' ||
                  item.status == status ||
                  (status == 'CLOSURE_PENDING' &&
                      item.status == 'PENDING' &&
                      item.isClosureRequest)) &&
              (orderType == null || item.orderType == orderType),
        )
        .toList();
    return FinanceProcurementApprovalPage(
      items: filtered,
      page: page,
      size: size,
      total: filtered.length,
      totalPages: 1,
    );
  }

  @override
  Future<Map<String, int>> approvalTypeCounts({
    String status = 'PENDING',
  }) async => {
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
    if (reviewError case final error?) throw error;
    final task = items.firstWhere((task) => task.caseId == caseId);
    return FinanceProcurementApprovalReview.fromJson({
      'caseId': caseId,
      'orderId': task.orderId,
      'orderType': task.orderType.name.toUpperCase(),
      'billNo': task.billNo,
      'status': task.status,
      'attempt': 1,
      'version': task.version,
      'allowedActions': task.allowedActions.toList(),
    });
  }

  @override
  Future<void> approveOrdersBatch(
    List<FinanceProcurementDecisionItem> items, {
    String? remark,
    double? exchangeRate,
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
    user: AppUser(id: 'finance-reviewer', code: 'FIN001', name: '财务李四'),
  );
}

FinanceProcurementApprovalTask _task({
  required String caseId,
  required String orderId,
  required String orderType,
  required String billNo,
  List<String> allowedActions = const ['APPROVE', 'REJECT'],
  int changeCount = 0,
  String status = 'PENDING',
}) => FinanceProcurementApprovalTask.fromJson({
  'caseId': caseId,
  'orderId': orderId,
  'orderType': orderType,
  'billNo': billNo,
  'supplierName': orderType == 'PURCHASE' ? '供应商A' : '委外商B',
  'warehouseName': '一号仓',
  'amount': orderType == 'PURCHASE' ? '1200.50' : '800.00',
  'totalOriginal': orderType == 'PURCHASE' ? '169.0845' : '800',
  'currencyName': orderType == 'PURCHASE' ? '美元' : '人民币',
  'submittedByName': '张三',
  'submittedAt': '2026-08-18T02:00:00+08:00',
  'expectedDate': '2026-09-01',
  'attempt': 1,
  'status': status,
  'version': 3,
  'allowedActions': allowedActions,
  'changeCount': changeCount,
});

Future<GoRouter> _pumpPage(
  WidgetTester tester,
  _FakeWorkflowRepo repository, {
  Size size = const Size(1400, 1000),
  FinanceClaimFixture? claims,
  ThemeData? theme,
  GlobalKey? capture,
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
        builder: (context, state) => Scaffold(
          body: Column(
            children: [
              Text('审核详情 ${state.pathParameters['caseId']}'),
              TextButton(
                onPressed: () => context.pop(false),
                child: const Text('返回审批任务'),
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: '/purchase/orders/:id',
        builder: (context, state) => Scaffold(
          body: Column(
            children: [
              Text('采购详情 ${state.pathParameters['id']}'),
              TextButton(
                onPressed: () => context.pop(false),
                child: const Text('返回审批任务'),
              ),
            ],
          ),
        ),
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
        taskClaimRepositoryProvider.overrideWithValue(
          claims ?? FinanceClaimFixture(),
        ),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            facts: {BadgeFact.procurementApproval: repository.items.length},
          ),
        ),
        financeProcurementWorkflowRepositoryProvider.overrideWithValue(
          repository,
        ),
      ],
      child: MaterialApp.router(
        theme: theme,
        builder: (_, child) => capture == null
            ? child!
            : RepaintBoundary(key: capture, child: child!),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  for (final sourceOrder in [false, true]) {
    testWidgets('${sourceOrder ? '原订货单' : '审核详情'}无本地决定返回仍重核结束审批队列', (
      tester,
    ) async {
      final repository = _FakeWorkflowRepo([
        _task(
          caseId: 'before',
          orderId: 'order-1',
          orderType: 'PURCHASE',
          billNo: 'PO-BEFORE',
        ),
      ]);
      await _pumpPage(tester, repository);
      final table = tester
          .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
            find.byKey(const Key('finance-approval-task-table')),
          );
      final beforeReads = repository.taskReads;
      if (sourceOrder) {
        final menu = table.rowMenuBuilder!(table.items.single)
            .whereType<UtenMenuItem>()
            .last;
        menu.onTap();
      } else {
        table.onRowTap!(table.items.single);
      }
      await tester.pumpAndSettle();
      repository.items
        ..clear()
        ..add(
          FinanceProcurementApprovalTask.fromJson({
            'caseId': 'after',
            'orderId': 'order-1',
            'orderType': 'PURCHASE',
            'billNo': 'PO-AFTER',
            'requestType': 'CLOSE',
            'status': 'PENDING',
            'version': 1,
            'allowedActions': ['APPROVE'],
          }),
        );
      await tester.tap(find.text('返回审批任务'));
      await tester.pumpAndSettle();
      expect(repository.taskReads, beforeReads + 1);
      expect(find.text('PO-BEFORE'), findsNothing);
      expect(find.text('PO-AFTER'), findsOneWidget);
      expect(find.text('采购 · 结束待审批'), findsOneWidget);
    });
  }

  testWidgets('结束待审批使用同一状态筛选并区分正常订货审批', (tester) async {
    final closure = FinanceProcurementApprovalTask.fromJson({
      'caseId': 'closure-1',
      'orderId': 'order-1',
      'orderType': 'PURCHASE',
      'billNo': 'PO-CLOSE-1',
      'status': 'PENDING',
      'requestType': 'CLOSE_AND_REORDER',
      'version': 1,
      'allowedActions': ['APPROVE', 'REJECT'],
    });
    final repository = _FakeWorkflowRepo([closure]);
    await _pumpPage(tester, repository);
    await tester.tap(find.text('结束待审批'));
    await tester.pumpAndSettle();
    expect(find.text('PO-CLOSE-1'), findsOneWidget);
    expect(find.text('采购 · 结束待审批'), findsOneWidget);
    expect(
      find.byKey(const Key('finance-approval-status-segments')),
      findsOneWidget,
    );
  });

  for (final scenario in const [
    (width: 1440.0, dark: false),
    (width: 1440.0, dark: true),
    (width: 375.0, dark: false),
    (width: 375.0, dark: true),
  ]) {
    testWidgets(
      'combined approval status layout ${scenario.width} dark=${scenario.dark}',
      (tester) async {
        const captureUi = bool.fromEnvironment('UTEN_CAPTURE_UI');
        final capture = captureUi ? GlobalKey() : null;
        if (captureUi) await loadAuditScreenshotFonts(tester);
        final theme = scenario.dark ? buildDarkTheme() : buildLightTheme();
        final repository = _FakeWorkflowRepo([
          _task(
            caseId: 'purchase',
            orderId: 'p1',
            orderType: 'PURCHASE',
            billNo: 'CD202610120001',
          ),
          _task(
            caseId: 'subcontract',
            orderId: 's1',
            orderType: 'SUBCONTRACT',
            billNo: 'WT202610120002',
          ),
          _task(
            caseId: 'changed',
            orderId: 'p2',
            orderType: 'PURCHASE',
            billNo: 'CD202610120003',
            changeCount: 2,
          ),
        ]);
        await _pumpPage(
          tester,
          repository,
          size: Size(scenario.width, 1000),
          theme: captureUi ? auditScreenshotTheme(theme) : theme,
          capture: capture,
        );
        final tableFinder = find.byKey(
          const Key('finance-approval-task-table'),
        );
        final table = tester
            .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
              tableFinder,
            );
        final status = table.columns.first;
        expect(table.items, hasLength(3));
        expect(
          find.byKey(const Key('finance-approval-type-segments')),
          findsNothing,
        );
        final element = tester.element(tableFinder);
        for (final task in table.items) {
          final luminance = status.cellColor!(element, task)!
              .computeLuminance();
          expect(1.05 / (luminance + .05), greaterThanOrEqualTo(4.5));
        }
        expect(tester.takeException(), isNull);
        if (scenario.width < 600) {
          final approve = find.byKey(
            const Key('finance-approval-batch-approve'),
          );
          await tester.ensureVisible(approve);
          await tester.pumpAndSettle();
          expect(tester.getRect(approve).bottom, lessThanOrEqualTo(1000));
        }
        if (capture != null) {
          await saveAuditScreenshot(
            tester,
            capture,
            'approval-status-${scenario.width.toInt()}-${scenario.dark ? 'dark' : 'light'}',
          );
        }
      },
    );
  }

  testWidgets('已批准审批记录可从财务打开且不带整批审批动作', (tester) async {
    final repository = _FakeWorkflowRepo([
      _task(
        caseId: 'pending',
        orderId: 'order-a',
        orderType: 'PURCHASE',
        billNo: 'PO-PENDING',
      ),
      _task(
        caseId: 'approved',
        orderId: 'order-b',
        orderType: 'PURCHASE',
        billNo: 'PO-APPROVED',
        status: 'APPROVED',
        allowedActions: const [],
      ),
    ]);
    await _pumpPage(tester, repository);
    expect(find.text('已批准'), findsNothing);
    await tester.tap(find.text('历史单据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已批准'));
    await tester.pumpAndSettle();
    final table = tester
        .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
          find.byKey(const Key('finance-approval-task-table')),
        );
    expect(table.items.single.caseId, 'approved');
    expect(table.selectable, isFalse);
    expect(
      find.byKey(const Key('finance-approval-batch-approve')),
      findsNothing,
    );
    table.onRowTap!(table.items.single);
    await tester.pumpAndSettle();
    expect(find.text('审核详情 approved'), findsOneWidget);
    expect(repository.approvedBatches, isEmpty);
  });
  testWidgets('采购委外混合批量任一认领失败则全部不提交并释放已取得租约', (tester) async {
    final repository = _FakeWorkflowRepo([
      _task(
        caseId: 'case-1',
        orderId: 'order-1',
        orderType: 'PURCHASE',
        billNo: 'PO001',
      ),
      _task(
        caseId: 'case-2',
        orderId: 'order-2',
        orderType: 'SUBCONTRACT',
        billNo: 'SC001',
      ),
    ]);
    final claims = FinanceClaimFixture()..failClaimKey = 'case-2';
    await _pumpPage(tester, repository, claims: claims);
    final table = tester
        .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
          find.byKey(const Key('finance-approval-task-table')),
        );
    table.onSelectedIdsChanged?.call({'case-1', 'case-2'});
    await tester.pump();
    await tester.tap(find.byKey(const Key('finance-approval-batch-approve')));
    await tester.pumpAndSettle();
    expect(repository.approvedBatches, isEmpty);
    expect(repository.rejectedBatches, isEmpty);
    expect(claims.released, ['lease-PROCUREMENT_FINANCE_APPROVE-case-1-1']);
  });

  testWidgets('批量认领后的快照拒绝保留真实原因并释放占用', (tester) async {
    final repository = _FakeWorkflowRepo([
      _task(
        caseId: 'case-1',
        orderId: 'order-1',
        orderType: 'PURCHASE',
        billNo: 'PO001',
      ),
    ])..reviewError = ApiException('FORBIDDEN', '此订货单不在你的数据范围内');
    final claims = FinanceClaimFixture();
    await _pumpPage(tester, repository, claims: claims);
    final table = tester
        .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
          find.byKey(const Key('finance-approval-task-table')),
        );
    table.onSelectedIdsChanged?.call({'case-1'});
    await tester.pump();
    await tester.tap(find.byKey(const Key('finance-approval-batch-approve')));
    await tester.pumpAndSettle();
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceProcurementApprovalTasksPage)),
    ).read(appNotificationProvider);
    expect(notifications.last.message, '此订货单不在你的数据范围内');
    expect(repository.approvedBatches, isEmpty);
    expect(repository.rejectedBatches, isEmpty);
    expect(claims.released, ['lease-PROCUREMENT_FINANCE_APPROVE-case-1-1']);
  });

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
          'status',
          'billNo',
          'supplierName',
          'totalOriginal',
          'amount',
          'expectedDate',
          'submittedByName',
          'submittedAt',
          'attempt',
        ]),
      );
      // ADR-128 → 2026-10-10 后缀口径：订货金额数值后自动带币种单位，折合人民
      // 币另列带「元」；明细行数/超收损耗%/汇率对齐详情页，仓库/货品只进详情页。
      expect(find.text('169.0845 美元'), findsOneWidget);
      // 委外行 totalOriginal(800)与折合人民币(800.00)同文案，两处命中。
      expect(find.text('800.00 元'), findsWidgets);
      expect(find.text('折合人民币'), findsOneWidget);
      // 2026-10-10 用户口径：仓库/货品两列从中心表格退役，只进审核详情页。
      expect(find.text('仓库'), findsNothing);
      expect(find.text('一号仓'), findsNothing);
      expect(find.text('货品'), findsNothing);
      expect(find.text('汇率'), findsOneWidget);

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
        {
          'caseId': 'case-1',
          'expectedVersion': 3,
          'expectedClaimId': 'lease-PROCUREMENT_FINANCE_APPROVE-case-1-1',
        },
        {
          'caseId': 'case-2',
          'expectedVersion': 3,
          'expectedClaimId': 'lease-PROCUREMENT_FINANCE_APPROVE-case-2-2',
        },
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
    expect(
      find.text('已选 1 项'),
      findsNothing,
      reason: '返回时重核服务器队列并清掉旧选择，不能沿用可能已被他人审批的任务。',
    );
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

    // 2026-10-06 状态列全站前置：窄屏下首列是状态格，点它选行（单号格可能已
    // 横向挤出 375 视口）。
    await tester.tap(find.text('采购待审批'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('已选 1 项'), findsOneWidget);
    // 2026-10-02 用户口径：「共 N 笔」/操作说明提示文字退役。
    expect(find.textContaining('单击选择'), findsNothing);
    final approve = find.byKey(const Key('finance-approval-batch-approve'));
    final reject = find.byKey(const Key('finance-approval-batch-reject'));
    // 2026-09-24 折叠联动改版（对齐物料分析页）后，窄屏走整页滚动回退：
    // 批量条在折叠下方，先滚到可见再断言可达。
    await tester.ensureVisible(approve);
    await tester.pump(const Duration(milliseconds: 100));
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

  // 批准后改量（2026-09-05）：改过数量的任务在状态列显示浅黄底徽标，
  // 未改过的任务仍显示默认「待财务复核」。
  testWidgets('qty-changed task shows re-review badge in status column', (
    tester,
  ) async {
    final repository = _FakeWorkflowRepo([
      _task(
        caseId: 'case-1',
        orderId: 'order-1',
        orderType: 'PURCHASE',
        billNo: 'PO-2026-001',
        changeCount: 2,
      ),
      _task(
        caseId: 'case-2',
        orderId: 'order-2',
        orderType: 'SUBCONTRACT',
        billNo: 'SO-2026-002',
      ),
    ]);
    await _pumpPage(tester, repository);

    final table = tester
        .widget<MasterDataTableView<FinanceProcurementApprovalTask>>(
          find.byKey(const Key('finance-approval-task-table')),
        );
    expect(table.columns.map((column) => column.key), contains('status'));
    expect(find.text('采购 · 改后待复核 · 改量 2 处'), findsOneWidget);
    expect(find.text('委外待审批'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 来源筛选移到状态表头；嵌入态宿主主类栏与整批选择边界保持稳定。
  testWidgets('status header filters both order types and keeps the host bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

    final router = GoRouter(
      initialLocation: '/host',
      routes: [
        GoRoute(
          path: '/host',
          builder: (_, _) => Scaffold(
            body: FinanceProcurementApprovalTasksPage(
              embedded: true,
              externalHeader: Container(
                key: const Key('host-category-bar'),
                color: Colors.teal,
                height: 40,
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/finance/procurement-approvals/:caseId',
          builder: (_, state) =>
              Scaffold(body: Text('审核详情 ${state.pathParameters['caseId']}')),
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
          taskClaimRepositoryProvider.overrideWithValue(FinanceClaimFixture()),
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: {BadgeFact.procurementApproval: repository.items.length},
            ),
          ),
          financeProcurementWorkflowRepositoryProvider.overrideWithValue(
            repository,
          ),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-category-bar')), findsOneWidget);

    MasterDataTableView<FinanceProcurementApprovalTask> table() =>
        tester.widget(find.byKey(const Key('finance-approval-task-table')));
    expect(
      find.byKey(const Key('finance-approval-type-segments')),
      findsNothing,
    );
    expect(table().items, hasLength(2));
    final status = table().columns.singleWhere(
      (column) => column.key == 'status',
    );
    expect(status.value(table().items.first), '采购待审批');
    expect(status.value(table().items.last), '委外待审批');
    final tableContext = tester.element(
      find.byKey(const Key('finance-approval-task-table')),
    );
    expect(
      status.cellColor!(tableContext, table().items.first),
      isNot(status.cellColor!(tableContext, table().items.last)),
    );
    table().onSelectedIdsChanged!({'case-1', 'case-2'});
    await tester.pumpAndSettle();
    table().onFilterChanged('status', 'PURCHASE');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('host-category-bar')), findsOneWidget);
    expect(repository.lastOrderType, FinanceProcurementOrderType.purchase);
    expect(table().items.single.caseId, 'case-1');
    expect(table().selectedIds, isEmpty);
    table().onFilterChanged('status', 'SUBCONTRACT');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-category-bar')), findsOneWidget);
    expect(repository.lastOrderType, FinanceProcurementOrderType.subcontract);
    expect(table().items.single.caseId, 'case-2');
    table().onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(repository.lastOrderType, isNull);
    expect(table().items, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
