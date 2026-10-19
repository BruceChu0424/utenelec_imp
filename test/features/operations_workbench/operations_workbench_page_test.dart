import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/data_display/uten_status_cell_color.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';

/// 选中工具条分段：分段铺得开时直接点；小屏放不下时工具条收成「分类」下拉
/// 按钮（2026-09-14 起不再左右拖），先点开下拉再点目标菜单项。
Future<void> _selectSegment(WidgetTester tester, String label) =>
    selectFilterSegment(tester, label);

Future<void> _tapRefresh(WidgetTester tester) async {
  var refresh = find.byTooltip('刷新').hitTestable();
  if (!tester.any(refresh)) {
    await tester.tap(find.byKey(const Key('uten-app-bar-more-actions')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    refresh = find.byTooltip('刷新').hitTestable();
  }
  expect(refresh, findsOneWidget, reason: '刷新必须在工具条或更多面板内可操作');
  await tester.tap(refresh);
  await tester.pump();
}

MasterDataTableView<OperationsWorkbenchTask> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<OperationsWorkbenchTask>));

// Existing presentation scenarios describe an authorized task worker. Supply a
// separate task-response fixture; regressions below deliberately make it differ
// from the browsable status distribution.
Widget _taskScope({required Widget child, Map<String, int>? taskFacts}) {
  final page = (child as MaterialApp).home! as OperationsWorkbenchPage;
  final data = switch (page.repository) {
    _FakeGateway(:final data) => data,
    _RefreshBlockingGateway(:final data) => data,
    _ => null,
  };
  final status = data?.summary.statusCounts ?? const <String, int>{};
  final source = page.department == OperationsWorkbenchDepartment.subcontract
      ? 'subcontractTask'
      : 'purchaseTask';
  return ProviderScope(
    overrides: [
      // 页面会并行预热主档「主仓 - 子仓」字典（masterNameServiceProvider →
      // apiClientProvider）。Riverpod 3 下这条链会真实挂载默认 Dio：widget 测试的
      // 假时钟里真实网络请求永不完成，_load 的 await warehouseNames 一直挂起，
      // 首屏停在加载转圈、pumpAndSettle 超时。本文件断言的仓库列本就是「字典
      // 未加载回退行内叶仓名」路径，注入一个立即失败的离线 api 即可（页面契约：
      // 预热失败就地吞掉，不阻断任务加载）。
      apiClientProvider.overrideWithValue(_OfflineApi()),
      fixedBadgeSummaryOverride(
        badgeSummaryFixture(
          facts:
              taskFacts ??
              {
                '$source.waitingOrder': status['WAITING_ORDER'] ?? 0,
                '$source.rework': status['FINANCE_REJECTED'] ?? 0,
                '$source.shortDelivery': 0,
                '$source.inProgress': status['IN_PROGRESS'] ?? 0,
                BadgeFact.productionDrawReady: status['READY_TO_PICK'] ?? 0,
                BadgeFact.productionDrawPartial: status['PARTIAL'] ?? 0,
                BadgeFact.productionDrawMaterialsToDefine:
                    status['MATERIALS_TO_DEFINE'] ?? 0,
              },
        ),
      ),
    ],
    child: child,
  );
}

/// 离线 api：任何主档字典请求立即失败（见 _taskScope 注释）。
class _OfflineApi extends ApiClient {
  _OfflineApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    throw StateError('offline: $path');
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    throw StateError('offline: $path');
  }
}

void main() {
  testWidgets('read-only status counts never become personal task badges', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _FakeGateway(
      _emptyData(
        department: OperationsWorkbenchDepartment.purchase,
        statusCounts: const {
          'WAITING_ORDER': 9,
          'FINANCE_REJECTED': 4,
          'IN_PROGRESS': 7,
        },
      ),
    );
    await tester.pumpWidget(
      _taskScope(
        taskFacts: const {
          BadgeFact.purchaseTaskWaitingOrder: 0,
          BadgeFact.purchaseTaskRework: 0,
          BadgeFact.purchaseTaskInProgress: 0,
        },
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toolbar = find.byKey(
      const Key('operations-workbench-stages-purchase'),
    );
    expect(
      find.descendant(
        of: toolbar,
        matching: find.byType(UtenNotificationBadge),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: toolbar, matching: find.byType(UtenInProgressBadge)),
      findsNothing,
    );
    expect(gateway.statuses, [null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'task badge counts stay separate from larger browsable status totals',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        _emptyData(
          department: OperationsWorkbenchDepartment.purchase,
          statusCounts: const {
            'WAITING_ORDER': 99,
            'FINANCE_REJECTED': 44,
            'IN_PROGRESS': 77,
          },
        ),
      );
      await tester.pumpWidget(
        _taskScope(
          taskFacts: const {
            BadgeFact.purchaseTaskWaitingOrder: 2,
            BadgeFact.purchaseTaskRework: 1,
            BadgeFact.purchaseTaskInProgress: 3,
          },
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toolbar = tester.widget<UtenFilterToolbar<dynamic>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenFilterToolbar<dynamic> &&
              widget.segmentsKey ==
                  const Key('operations-workbench-stages-purchase'),
        ),
      );
      expect(toolbar.segments.first.count, 2);
      expect(toolbar.segments[1].count, 1);
      expect(toolbar.segments[1].inProgressCount, 3);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'selected exception remains clearable when its latest count disappears',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        _emptyData(
          department: OperationsWorkbenchDepartment.purchase,
          statusCounts: const {'IN_PROGRESS': 1},
          exceptionCounts: const {'OVERDUE': 1},
        ),
        dataAfterExceptionFilter: _emptyData(
          department: OperationsWorkbenchDepartment.purchase,
          statusCounts: const {'IN_PROGRESS': 1},
        ),
      );
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _table(tester).onFilterChanged('exception', 'OVERDUE');
      await tester.pumpAndSettle();
      expect(gateway.exceptions.last, 'OVERDUE');
      expect(_table(tester).filters['exception'], 'OVERDUE');
      expect(_table(tester).facets['exception']!.single.value, 'OVERDUE');
      expect(_table(tester).facets['exception']!.single.count, 0);
      _table(tester).onFilterChanged('exception', null);
      await tester.pumpAndSettle();
      expect(gateway.exceptions.last, isNull);
      expect(gateway.statuses.last, 'IN_PROGRESS');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'finance return stays a status and never narrows in-progress automatically',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        _emptyData(
          department: OperationsWorkbenchDepartment.purchase,
          statusCounts: const {'FINANCE_REJECTED': 2, 'IN_PROGRESS': 5},
          exceptionCounts: const {'FINANCE_REJECTED': 2},
        ),
      );
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'IN_PROGRESS');
      expect(gateway.exceptions, everyElement(isNull));
      expect(
        gateway.data.exceptionOptions.map((option) => option.value),
        isNot(contains('FINANCE_REJECTED')),
      );
      expect(
        _table(tester).facets['exception']!.map((bucket) => bucket.value),
        isNot(contains('FINANCE_REJECTED')),
      );
      expect(find.text('财务已退回'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'purchase batch action requires every selected request item link',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: _FakeGateway(
                OperationsWorkbenchData(
                  department: OperationsWorkbenchDepartment.purchase,
                  summary: const OperationsWorkbenchSummary(
                    totalTasks: 5,
                    overdueTasks: 1,
                    openTasks: 5,
                    openQty: 40,
                    statusCounts: {
                      'UNPEGGED': 2,
                      'WAITING_SUPPLY': 1,
                      'COVERED': 1,
                    },
                    exceptionCounts: {
                      'OVERDUE_SHORTAGE': 1,
                      'SUPPLY_PEG_REQUIRED': 2,
                    },
                  ),
                  items: [
                    _task(
                      id: 'task-linked-1',
                      goodsName: '已挂接轴套一',
                      actionDocItemId: 'request-item-1',
                    ),
                    _task(
                      id: 'task-linked-2',
                      goodsName: '已挂接轴套二',
                      actionDocItemId: 'request-item-2',
                    ),
                    _task(
                      id: 'task-other-request',
                      goodsName: '另一申请轴套',
                      actionDocId: 'request-2',
                      actionDocItemId: 'request-item-3',
                    ),
                    _task(id: 'task-unlinked', goodsName: '未挂接轴套'),
                    _task(
                      id: 'task-unapproved',
                      goodsName: '待审申请轴套',
                      actionDocItemId: 'request-item-4',
                      actionDocStatus: '0',
                    ),
                  ],
                  page: 1,
                  size: 20,
                  total: 5,
                  totalPages: 1,
                  capabilities: const OperationsWorkbenchCapabilities(
                    canCreatePurchaseOrder: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 新范式：默认不选阶段（只拉一次概览徽章），点「申请待分解」段后才
      // 加载任务列表，勾选/批量门禁都建立在阶段选中之后。
      await _selectSegment(tester, '申请待分解');
      await tester.pumpAndSettle();

      expect(find.text('采购任务工作台'), findsOneWidget);
      expect(find.text('已挂接轴套一'), findsOneWidget);
      expect(find.text('生成采购订货单'), findsOneWidget);
      // 2026-09-29「大小屏共用一张表」：批量动作统一走表格标准右下悬浮组，
      // 组 key 退役；断言主操作按钮本体。
      expect(
        find.byKey(const Key('operations-workbench-purchase-batch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operations-workbench-open-selected')),
        findsNothing,
      );

      var batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNull);
      // 2026-09-06 顶部选中条退役：已选计数走右下角悬浮组标准胶囊
      // （与物料分桶页/我的车间任务同款），业务按钮与胶囊同框。
      expect(
        find.byKey(const Key('operations-workbench-selection-bar')),
        findsNothing,
      );
      expect(find.text('已选 0 项'), findsOneWidget);

      // 2026-10-09 卡片形态退役：窄屏同一张表格，Checkbox.at(0) 是表头三态
      // 全选格，行勾选框从 at(1) 起。
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNotNull);

      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pump();
      batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNotNull);

      await tester.tap(find.byType(Checkbox).at(3));
      await tester.pump();
      batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNotNull);

      await tester.tap(find.byType(Checkbox).at(3));
      await tester.tap(find.byType(Checkbox).at(4));
      await tester.pump();
      // 选中不可执行任务：按钮置灰，原因在 Tooltip/点击提示里（不再占选中条）。
      batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNull);

      await tester.tap(find.byType(Checkbox).at(4));
      await tester.tap(find.byType(Checkbox).at(5));
      await tester.pump();
      batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNull);
    },
  );

  testWidgets(
    'document-grouped purchase row shows goods summary and stays selectable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: _FakeGateway(
                OperationsWorkbenchData(
                  department: OperationsWorkbenchDepartment.purchase,
                  summary: const OperationsWorkbenchSummary(
                    totalTasks: 2,
                    overdueTasks: 0,
                    openTasks: 2,
                    openQty: 0,
                    statusCounts: {'WAITING_ORDER': 2},
                  ),
                  items: [
                    // ADR-065 修订：5 个物料合并成的一张采购申请 = 一行；
                    // actionItemIds 携带整单明细，勾选即整单带入生成订货单。
                    _task(
                      id: 'request-merged',
                      goodsName: '',
                      actionDocId: 'request-merged',
                      goodsCount: 5,
                      openLineCount: 5,
                      actionItemIds: const [
                        'merged-item-1',
                        'merged-item-2',
                        'merged-item-3',
                        'merged-item-4',
                        'merged-item-5',
                      ],
                    ),
                    _task(
                      id: 'task-single',
                      goodsName: '单货品申请轴套',
                      actionDocItemId: 'request-item-single',
                    ),
                  ],
                  page: 1,
                  size: 20,
                  total: 2,
                  totalPages: 1,
                  capabilities: const OperationsWorkbenchCapabilities(
                    canCreatePurchaseOrder: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 新阶段段交互（UtenFilterToolbar）：默认不选段只拉概览徽章，
      // 点「申请待分解」段后才加载任务列表。
      await _selectSegment(tester, '申请待分解');
      await tester.pumpAndSettle();

      // 归组行：货品列显示“N 种物料 · N 行”摘要、单据号列显示申请号，
      // 不再按 5 条明细重复出 5 行。
      expect(find.text('5 种物料 · 5 行'), findsOneWidget);
      expect(find.text('PR-request-merged'), findsOneWidget);
      expect(find.text('5 行'), findsOneWidget);
      expect(find.text('单货品申请轴套'), findsOneWidget);

      // 勾选归组行：actionItemIds 整单可用，生成订货单按钮可用。
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pump();
      final batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNotNull);
      expect(find.text('先生成/挂接采购申请'), findsNothing);
    },
  );

  testWidgets(
    'order-stage segment offers no checkboxes or batch generate action',
    (tester) async {
      // 已进入订货/收货阶段的行（生产上唯一可见形态：已生成的订货单）不能
      // 再「生成采购订货单」（补货走原订单，V466 收口）——这些段不渲染
      // 勾选与悬浮按钮，避免用户勾选后对着永远点不动的按钮报障。
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const orderStageTask = OperationsWorkbenchTask(
        taskId: 'order-doc-1',
        packageId: null,
        planId: null,
        planNo: 'PP-001',
        warehouseName: '原材料仓',
        goodsCode: '',
        goodsName: '',
        spec: '',
        colorName: '',
        unitName: '',
        supplyRoute: 'PURCHASE',
        requiredQty: 0,
        allocatedQty: 0,
        fulfilledQty: 0,
        supplyPeggedQty: 0,
        openQty: 0,
        taskStatus: 'FINANCE_APPROVED',
        needDate: '2026-08-01',
        expectedDate: null,
        exceptionCode: null,
        updatedAt: '2026-07-31T10:00:00+08:00',
        actionDocument: OperationsActionDocument(
          id: 'order-1',
          docType: 'PURCHASE_ORDER',
          number: 'PO-order-1',
          path: '/purchase/orders/order-1',
          canView: true,
          canEdit: false,
          status: '1',
        ),
        actionDocItemId: null,
        actionDocumentRestricted: false,
        goodsCount: 8,
        openLineCount: 8,
      );
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: _FakeGateway(
                const OperationsWorkbenchData(
                  department: OperationsWorkbenchDepartment.purchase,
                  summary: OperationsWorkbenchSummary(
                    totalTasks: 1,
                    overdueTasks: 0,
                    openTasks: 1,
                    openQty: 0,
                    // ADR-100: 财务已通过并入「进行中」段, 段计数取 IN_PROGRESS。
                    statusCounts: {'IN_PROGRESS': 1, 'FINANCE_APPROVED': 1},
                  ),
                  items: [orderStageTask],
                  page: 1,
                  size: 20,
                  total: 1,
                  totalPages: 1,
                  capabilities: OperationsWorkbenchCapabilities(
                    canCreatePurchaseOrder: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _selectSegment(tester, '进行中');
      await tester.pumpAndSettle();

      expect(find.text('8 种物料 · 8 行'), findsOneWidget);
      expect(
        find.byKey(const Key('operations-workbench-floating-primary-action')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operations-workbench-purchase-batch')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operations-workbench-selection-bar')),
        findsNothing,
      );
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('所选任务已进入采购订单或收货阶段'), findsNothing);
    },
  );

  testWidgets('refresh disables an enabled floating create action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = OperationsWorkbenchData(
      department: OperationsWorkbenchDepartment.purchase,
      summary: const OperationsWorkbenchSummary(
        totalTasks: 1,
        overdueTasks: 0,
        openTasks: 1,
        openQty: 8,
        statusCounts: {'WAITING_ORDER': 1},
      ),
      items: [
        _task(
          id: 'refresh-task',
          goodsName: '刷新中的采购任务',
          actionDocItemId: 'request-item-refresh',
        ),
      ],
      page: 1,
      size: 20,
      total: 1,
      totalPages: 1,
      capabilities: const OperationsWorkbenchCapabilities(
        canCreatePurchaseOrder: true,
      ),
    );
    final gateway = _RefreshBlockingGateway(data);
    await tester.pumpWidget(
      _taskScope(
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: gateway,
          ),
        ),
      ),
    );
    // The overview badge selects the actionable stage automatically. Its
    // accepted overview rows must remain hidden while the stage GET is held.
    await tester.pump();
    await tester.pump();
    expect(gateway._pending, isNotNull);
    expect(find.byType(Checkbox), findsNothing);
    gateway.completeRefresh();
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    var button = tester.widget<UtenButton>(
      find.byKey(const Key('operations-workbench-purchase-batch')),
    );
    expect(button.onPressed, isNotNull);

    await _tapRefresh(tester);
    await tester.pump();
    button = tester.widget<UtenButton>(
      find.byKey(const Key('operations-workbench-purchase-batch')),
    );
    expect(button.onPressed, isNull);

    gateway.completeRefresh();
    await tester.pumpAndSettle();
    button = tester.widget<UtenButton>(
      find.byKey(const Key('operations-workbench-purchase-batch')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets(
    'exception header queries the dedicated backend filter and clears within the main stage',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        OperationsWorkbenchData(
          department: OperationsWorkbenchDepartment.purchase,
          summary: const OperationsWorkbenchSummary(
            totalTasks: 1,
            overdueTasks: 1,
            openTasks: 1,
            openQty: 8,
            statusCounts: {'UNPEGGED': 1},
            exceptionCounts: {'OVERDUE_SHORTAGE': 1},
          ),
          items: [
            _task(
              id: 'overdue-task',
              goodsName: '逾期物料',
              actionDocItemId: 'request-item-overdue',
              exceptionCode: 'OVERDUE_SHORTAGE',
            ),
          ],
          page: 1,
          size: 20,
          total: 1,
          totalPages: 1,
          capabilities: const OperationsWorkbenchCapabilities(
            canCreatePurchaseOrder: true,
          ),
        ),
      );
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 概览计数里红/黄段（申请待分解/进行中）的计数都是 null——按 0 对待，
      // 没有红黄徽章就不自动选（2026-10-04 口径），进页面仍只有一次概览请求。
      expect(gateway.statuses, [null]);

      // 主阶段加载完整任务；异常由表头选择，不再自动切到异常子分类。
      await _selectSegment(tester, '申请待分解');
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'WAITING_ORDER');
      expect(gateway.exceptions.last, isNull);
      expect(
        find.byKey(const Key('operations-workbench-exceptions-purchase')),
        findsNothing,
      );
      final table = _table(tester);
      expect(table.facets['exception']!.single.value, 'OVERDUE_SHORTAGE');
      table.onSelectedIdsChanged!({'overdue-task'});
      await tester.pump();
      expect(_table(tester).selectedIds, {'overdue-task'});
      _table(tester).onFilterChanged('exception', 'OVERDUE_SHORTAGE');
      await tester.pumpAndSettle();
      expect(gateway.exceptions.last, 'OVERDUE_SHORTAGE');
      expect(gateway.statuses.last, 'WAITING_ORDER');
      expect(gateway.pages.last, 1);
      expect(
        gateway.columnFilters.last.containsKey('exception'),
        isFalse,
        reason: '异常必须走专用exception，不能变成f.exception',
      );
      expect(_table(tester).selectedIds, isEmpty);
      final row = _table(tester).items.single;
      final statusColumn = _table(tester).columns.first;
      expect(statusColumn.value(row), contains('逾期缺料'));
      expect(
        statusColumn.cellColor!(tester.element(find.byType(Scaffold)), row),
        utenStatusBadgeCellColor(UtenStatusBadgeType.orange),
      );

      // 重选同一表头值不会重复加载。
      final exceptionsBeforeRetap = gateway.exceptions.length;
      _table(tester).onFilterChanged('exception', 'OVERDUE_SHORTAGE');
      await tester.pumpAndSettle();
      expect(gateway.exceptions.length, exceptionsBeforeRetap);

      _table(tester).onFilterChanged('exception', null);
      await tester.pumpAndSettle();
      expect(gateway.exceptions.last, isNull);
      expect(gateway.statuses.last, 'WAITING_ORDER');
      expect(_table(tester).filters['exception'], isNull);
      _table(tester).onFilterChanged('exception', 'OVERDUE_SHORTAGE');
      await tester.pumpAndSettle();

      // 切主阶段清除旧异常，重新完整加载；OVERDUE_ANY 聚合项继续隐藏。
      await _selectSegment(tester, '进行中');
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'IN_PROGRESS');
      expect(gateway.exceptions.last, isNull);
      expect(
        gateway.data.exceptionOptions.map((option) => option.value),
        contains('OVERDUE_SHORTAGE'),
      );
      expect(
        gateway.data.exceptionOptions.map((option) => option.value),
        isNot(contains('OVERDUE_ANY')),
      );
      expect(find.text('全部逾期'), findsNothing);
    },
  );

  testWidgets(
    'restricted document metadata and purchase create action stay hidden',
    (tester) async {
      // 375 宽保持 compact 卡片布局；1800 高保证懒构建 ListView 里的任务卡
      // 在折叠线之上被物化（筛选工具条占去首屏）。
      await tester.binding.setSurfaceSize(const Size(375, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final restrictedTask = _task(
        id: 'task-restricted',
        goodsName: '受限采购任务',
        actionDocumentRestricted: true,
      );
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: _FakeGateway(
                OperationsWorkbenchData(
                  department: OperationsWorkbenchDepartment.purchase,
                  summary: const OperationsWorkbenchSummary(
                    totalTasks: 1,
                    overdueTasks: 0,
                    openTasks: 1,
                    openQty: 8,
                    statusCounts: {'WAITING_SUPPLY': 1},
                  ),
                  items: [restrictedTask],
                  page: 1,
                  size: 20,
                  total: 1,
                  totalPages: 1,
                  capabilities: const OperationsWorkbenchCapabilities(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 默认不选阶段：先点「申请待分解」段加载任务卡，再断言脱敏与权限隐藏。
      await _selectSegment(tester, '申请待分解');
      await tester.pumpAndSettle();

      // 2026-10-10：原「执行入口」列退役，受限提示并入「单据号」列——
      // 此时本列不显示单号（单号属单据元数据不能泄漏），只显示占位；
      // 断言不泄漏真实单据号即可。
      expect(find.text('无权查看关联单据'), findsOneWidget);
      expect(
        find.byKey(const Key('operations-workbench-purchase-batch')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operations-workbench-open-selected')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operations-task-action-task-restricted')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operations-workbench-selection-bar')),
        findsNothing,
      );
      expect(find.byType(Checkbox), findsNothing);
    },
  );

  testWidgets(
    'warehouse uses a task table on compact widths without meaningless multi-select',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.warehouse,
              repository: _FakeGateway(
                OperationsWorkbenchData(
                  department: OperationsWorkbenchDepartment.warehouse,
                  summary: const OperationsWorkbenchSummary(
                    totalTasks: 1,
                    overdueTasks: 0,
                    openTasks: 1,
                    openQty: 4,
                    statusCounts: {'READY_TO_PICK': 1},
                  ),
                  items: [_warehouseTask()],
                  page: 1,
                  size: 20,
                  total: 1,
                  totalPages: 1,
                  capabilities: const OperationsWorkbenchCapabilities(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 2026-10-04 起进页面默认选中红1的「待备料 / 待领取」段：表格直接加载，
      // 不再有引导占位；紧凑宽度仍走表格布局而非移动卡片列表。
      expect(find.text('在上方选择阶段后开始办理'), findsNothing);
      expect(
        find.byKey(const Key('operations-workbench-mobile-list')),
        findsNothing,
      );

      // 再点已选中的段不重复发请求（单选点已选段不回调）。
      await _selectSegment(tester, '待备料 / 待领取');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operations-workbench-selection-bar')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operations-workbench-floating-primary-action')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operations-workbench-mobile-list')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operations-workbench-desktop-table')),
        findsOneWidget,
      );
      expect(find.text('已选 0 项'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);

      // 2026-09-29「大小屏共用一张表」：卡片点按=打开详情（本测试无路由宿主，
      // 不再模拟点按）；「无意义多选」语义由上方 无复选框/无已选胶囊 断言覆盖。
      expect(find.text('已选 1 项'), findsNothing);
      expect(
        find.byKey(const Key('operations-workbench-purchase-batch')),
        findsNothing,
      );
    },
  );

  final zeroStatusScenarios =
      <
        ({
          OperationsWorkbenchDepartment department,
          String stageLabel,
          String status,
          Size surfaceSize,
        })
      >[
        (
          department: OperationsWorkbenchDepartment.warehouse,
          stageLabel: '待备料 / 待领取',
          status: 'READY_TO_PICK',
          // 375 宽保持 compact；1800 高保证阶段分段行 + 表格在首屏被物化。
          surfaceSize: const Size(375, 1800),
        ),
        (
          department: OperationsWorkbenchDepartment.purchase,
          stageLabel: '申请待分解',
          status: 'WAITING_ORDER',
          surfaceSize: const Size(800, 1200),
        ),
      ];

  for (final scenario in zeroStatusScenarios) {
    testWidgets(
      '${scenario.department.apiValue} zero-count stage segment remains a valid filter',
      (tester) async {
        await tester.binding.setSurfaceSize(scenario.surfaceSize);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final gateway = _FakeGateway(
          // 徽章计数为 0 的阶段（概览返回 0）：分段仍可点击并按该阶段加载。
          _emptyData(
            department: scenario.department,
            statusCounts: {scenario.status: 0},
          ),
        );
        await tester.pumpWidget(
          _taskScope(
            child: MaterialApp(
              home: OperationsWorkbenchPage(
                department: scenario.department,
                repository: gateway,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 默认不选阶段：仅一次概览请求（status=null）。
        expect(gateway.statuses, [null]);
        await _selectSegment(tester, scenario.stageLabel);
        await tester.pumpAndSettle();

        expect(gateway.statuses.last, scenario.status);
        expect(tester.takeException(), isNull);
        // 阶段段保持单选选中（零计数不使分段失效），引导占位消失。小屏下
        // 分段条收成「分类」下拉（2026-09-14 起），选中态改从两种形态断言：
        // 铺开的 SegmentedButton 或收起后按钮上的选中标签。
        final stageRow = find.byKey(
          Key('operations-workbench-stages-${scenario.department.apiValue}'),
        );
        if (tester.any(stageRow)) {
          expect(
            tester.widget<UtenSegmentRow<dynamic>>(stageRow).selected.length,
            1,
          );
        } else {
          expect(find.text(scenario.stageLabel), findsOneWidget);
        }
        expect(find.text('在上方选择阶段后开始办理'), findsNothing);
      },
    );
  }

  testWidgets(
    'zero-count exception header option remains a backend-wide filter',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 667));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        // OVERDUE_ANY 聚合项隐藏；具体异常零计数仍可从表头查询。
        _emptyData(
          department: OperationsWorkbenchDepartment.purchase,
          exceptionCounts: const {'OVERDUE_SHORTAGE': 0},
        ),
      );
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 当前页没有行也可以从部门全量桶选择异常，零计数不禁用。
      await _selectSegment(tester, '申请待分解');
      await tester.pumpAndSettle();
      expect(_table(tester).facets['exception']!.single.count, 0);
      _table(tester).onFilterChanged('exception', 'OVERDUE_SHORTAGE');
      await tester.pumpAndSettle();

      expect(gateway.exceptions.last, 'OVERDUE_SHORTAGE');
      expect(gateway.statuses.last, 'WAITING_ORDER');
      expect(tester.takeException(), isNull);
      expect(_table(tester).filters['exception'], 'OVERDUE_SHORTAGE');
    },
  );

  testWidgets('main-stage selection resets the exception header filter', (
    tester,
  ) async {
    // 主阶段单选；异常表头在当前主阶段内收敛，切阶段清除旧异常。
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _FakeGateway(
      _emptyData(
        department: OperationsWorkbenchDepartment.purchase,
        exceptionCounts: const {'OVERDUE_SHORTAGE': 1},
      ),
    );
    await tester.pumpWidget(
      _taskScope(
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 无主阶段红黄计数不自动选：只拉概览，内容区为引导占位。
    expect(gateway.statuses, [null]);
    expect(find.text('在上方选择阶段后开始办理'), findsOneWidget);
    expect(find.text('逾期缺料'), findsNothing);

    // 主阶段完整加载，异常仅在用户主动使用表头时收敛。
    await _selectSegment(tester, '申请待分解');
    await tester.pumpAndSettle();
    expect(gateway.statuses.last, 'WAITING_ORDER');
    expect(gateway.exceptions.last, isNull);
    expect(
      _table(tester).facets['exception']!.single.value,
      'OVERDUE_SHORTAGE',
    );
    _table(tester).onFilterChanged('exception', 'OVERDUE_SHORTAGE');
    await tester.pumpAndSettle();

    // 重选同一异常表头值不重复请求。
    _table(tester).onFilterChanged('exception', 'OVERDUE_SHORTAGE');
    await tester.pumpAndSettle();
    expect(gateway.statuses.last, 'WAITING_ORDER');
    expect(gateway.exceptions.last, 'OVERDUE_SHORTAGE');
    expect(tester.takeException(), isNull);

    // 切换主阶段后清除旧异常。
    // ADR-100 起采购只有两段, 第二段是合并后的「进行中」(status=IN_PROGRESS)。
    await _selectSegment(tester, '进行中');
    await tester.pumpAndSettle();
    expect(gateway.statuses.last, 'IN_PROGRESS');
    expect(gateway.exceptions.last, isNull);
    expect(_table(tester).filters['exception'], isNull);
  });

  testWidgets(
    'warehouse exception header keeps picking stages and historical dates',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        OperationsWorkbenchData(
          department: OperationsWorkbenchDepartment.warehouse,
          summary: const OperationsWorkbenchSummary(
            totalTasks: 1,
            overdueTasks: 0,
            openTasks: 1,
            openQty: 4,
            statusCounts: {'READY_TO_PICK': 0},
            exceptionCounts: {'SHORTAGE': 1},
          ),
          items: [_warehouseTask(exceptionCode: 'SHORTAGE')],
          page: 1,
          size: 20,
          total: 1,
          totalPages: 1,
          capabilities: const OperationsWorkbenchCapabilities(),
        ),
      );
      await tester.pumpWidget(
        _taskScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.warehouse,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _selectSegment(tester, '待备料 / 待领取');
      await tester.pumpAndSettle();
      expect(_table(tester).selectable, isFalse);
      _table(tester).onFilterChanged('exception', 'SHORTAGE');
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'READY_TO_PICK');
      expect(gateway.exceptions.last, 'SHORTAGE');
      expect(gateway.columnFilters.last.containsKey('exception'), isFalse);
      final row = _table(tester).items.single;
      final statusColumn = _table(tester).columns.first;
      expect(statusColumn.value(row), contains('缺料'));
      expect(
        statusColumn.cellColor!(tester.element(find.byType(Scaffold)), row),
        utenStatusBadgeCellColor(UtenStatusBadgeType.warning),
      );
      expect(find.byType(Checkbox), findsNothing);

      _table(tester).onFilterChanged('exception', null);
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'READY_TO_PICK');
      expect(gateway.exceptions.last, isNull);
      _table(tester).onFilterChanged('exception', 'SHORTAGE');
      await tester.pumpAndSettle();
      await _selectSegment(tester, '部分领取');
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'PARTIAL');
      expect(gateway.exceptions.last, isNull);
      expect(_table(tester).filters['exception'], isNull);

      await _selectSegment(tester, '历史记录');
      await tester.pumpAndSettle();
      tester
          .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
          .onChanged(
            UtenHistoryTimeValue.range(
              DateTimeRange(
                start: DateTime(2026, 8),
                end: DateTime(2026, 8, 31),
              ),
            ),
          );
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, isNull);
      expect(gateway.exceptions.last, isNull);
      expect(gateway.datesFrom.last, '2026-08-01');
      expect(gateway.datesTo.last, '2026-08-31');
      expect(_table(tester).facets.containsKey('exception'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected stage segment stays selected when refreshed summary omits its count',
    (tester) async {
      // 阶段段来自页面固定 _stages 列表（不再依赖后端 statusOptions）：刷新返回
      // 的概览即使缺失该阶段计数（徽章消失），选择也保持且仍带 status 请求。
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        _emptyData(
          department: OperationsWorkbenchDepartment.purchase,
          statusCounts: const {'WAITING_ORDER': 1},
        ),
        dataAfterStatusFilter: _emptyData(
          department: OperationsWorkbenchDepartment.purchase,
        ),
      );
      await tester.pumpWidget(
        _taskScope(
          // This scenario starts as browsing and explicitly selects a stage.
          // A ready positive task fact correctly auto-selects before overview.
          taskFacts: const {
            BadgeFact.purchaseTaskWaitingOrder: 0,
            BadgeFact.purchaseTaskRework: 0,
            BadgeFact.purchaseTaskInProgress: 0,
          },
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.statuses, [null]);

      // 点「申请待分解」：此后该网关返回的概览不再带任何 statusCounts。
      await _selectSegment(tester, '申请待分解');
      await tester.pumpAndSettle();
      expect(gateway.statuses, [null, 'WAITING_ORDER']);

      await _tapRefresh(tester);
      await tester.pumpAndSettle();

      // 刷新后阶段选择保持：仍以选中阶段发起请求，分段仍是单选选中态。
      expect(gateway.statuses, [null, 'WAITING_ORDER', 'WAITING_ORDER']);
      expect(tester.takeException(), isNull);
      final stageRow = tester.widget<UtenSegmentRow<dynamic>>(
        find.byKey(const Key('operations-workbench-stages-purchase')),
      );
      expect(stageRow.selected.length, 1);
      expect(find.text('申请待分解'), findsOneWidget);
      expect(find.text('在上方选择阶段后开始办理'), findsNothing);

      // 阶段段在「选项缺失」的刷新后仍可继续切换。
      await _selectSegment(tester, '进行中');
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'IN_PROGRESS');
    },
  );
}

class _FakeGateway implements OperationsWorkbenchGateway {
  _FakeGateway(
    this.data, {
    this.dataAfterStatusFilter,
    this.dataAfterExceptionFilter,
  });

  final OperationsWorkbenchData data;
  final OperationsWorkbenchData? dataAfterStatusFilter;
  final OperationsWorkbenchData? dataAfterExceptionFilter;
  final List<String?> exceptions = [];
  final List<String?> statuses = [];
  final List<int> pages = [];
  final List<Map<String, String?>> columnFilters = [];
  final List<String?> datesFrom = [];
  final List<String?> datesTo = [];

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) async {
    exceptions.add(exception);
    statuses.add(status);
    pages.add(page);
    this.columnFilters.add(Map.of(columnFilters));
    datesFrom.add(dateFrom);
    datesTo.add(dateTo);
    if (exception != null && dataAfterExceptionFilter != null) {
      return dataAfterExceptionFilter!;
    }
    // 概览请求（status=null）返回带完整计数的数据；选中具体阶段后的加载
    // 才触发「刷新后选项缺失」场景（返回无 statusCounts 的数据）。
    final specificStatus =
        status != null && status != kOperationsWorkbenchOpenStatus;
    if (specificStatus && dataAfterStatusFilter != null) {
      return dataAfterStatusFilter!;
    }
    return data;
  }
}

class _RefreshBlockingGateway implements OperationsWorkbenchGateway {
  _RefreshBlockingGateway(this.data);

  final OperationsWorkbenchData data;
  Completer<OperationsWorkbenchData>? _pending;
  var _calls = 0;

  /// 放行当前被挂起的加载（点阶段段的首次列表加载、刷新均算）。
  void completeRefresh() => _pending?.complete(data);

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) {
    _calls++;
    // 首次（initState 概览）立即返回；此后每次加载都挂起，等测试手动放行。
    if (_calls == 1) return Future.value(data);
    final pending = Completer<OperationsWorkbenchData>();
    _pending = pending;
    return pending.future;
  }
}

OperationsWorkbenchData _emptyData({
  required OperationsWorkbenchDepartment department,
  Map<String, int> statusCounts = const {},
  Map<String, int> exceptionCounts = const {},
}) {
  return OperationsWorkbenchData(
    department: department,
    summary: OperationsWorkbenchSummary(
      totalTasks: 0,
      overdueTasks: 0,
      openTasks: 0,
      openQty: 0,
      statusCounts: statusCounts,
      exceptionCounts: exceptionCounts,
    ),
    items: const [],
    page: 1,
    size: 20,
    total: 0,
    totalPages: 0,
    capabilities: const OperationsWorkbenchCapabilities(),
  );
}

OperationsWorkbenchTask _task({
  required String id,
  required String goodsName,
  String actionDocId = 'request-1',
  String? actionDocItemId,
  String actionDocStatus = '1',
  bool actionDocumentRestricted = false,
  String? exceptionCode,
  int goodsCount = 0,
  int openLineCount = 0,
  List<String> actionItemIds = const [],
}) {
  return OperationsWorkbenchTask(
    taskId: id,
    packageId: 'package-1',
    planId: 'plan-1',
    planNo: 'PP-001',
    warehouseName: '原材料仓',
    goodsCode: 'MAT-$id',
    goodsName: goodsName,
    spec: 'φ20',
    colorName: '本色',
    unitName: '件',
    supplyRoute: 'PURCHASE',
    requiredQty: 10,
    allocatedQty: 4,
    fulfilledQty: 2,
    supplyPeggedQty: 4,
    openQty: 8,
    taskStatus: 'OPEN',
    needDate: '2026-08-01',
    expectedDate: null,
    // 归组行没有单条明细链接，异常由明细行集合表达；单行任务保持
    // “无明细链接即 UNLINKED” 的旧口径。
    exceptionCode:
        exceptionCode ??
        ((actionDocItemId == null && actionItemIds.isEmpty)
            ? 'UNLINKED'
            : null),
    updatedAt: '2026-07-31T10:00:00+08:00',
    actionDocument: (actionDocItemId == null && actionItemIds.isEmpty)
        ? null
        : OperationsActionDocument(
            id: actionDocId,
            docType: 'PURCHASE_REQUEST',
            number: 'PR-$actionDocId',
            path: '/purchase/requests/$actionDocId',
            canView: true,
            canEdit: false,
            status: actionDocStatus,
          ),
    actionDocItemId: actionDocItemId,
    actionDocumentRestricted: actionDocumentRestricted,
    goodsCount: goodsCount,
    openLineCount: openLineCount,
    actionItemIds: actionItemIds,
  );
}

OperationsWorkbenchTask _warehouseTask({String? exceptionCode}) {
  return OperationsWorkbenchTask(
    taskId: 'warehouse-task',
    packageId: 'package-1',
    planId: 'plan-1',
    planNo: 'PP-001',
    warehouseName: '原材料仓',
    goodsCode: 'MAT-WH-1',
    goodsName: '待发料轴套',
    spec: 'φ20',
    colorName: '本色',
    unitName: '件',
    supplyRoute: 'MAKE',
    requiredQty: 10,
    allocatedQty: 6,
    fulfilledQty: 2,
    supplyPeggedQty: 0,
    openQty: 4,
    taskStatus: 'READY_TO_PICK',
    needDate: '2026-08-01',
    expectedDate: null,
    exceptionCode: exceptionCode,
    updatedAt: '2026-08-22T10:00:00+08:00',
    actionDocument: const OperationsActionDocument(
      id: 'draw-1',
      docType: 'DRAW',
      number: 'LL-001',
      path: '/warehouse/DRAW/draw-1',
      canView: true,
      canEdit: false,
      status: '1',
    ),
    actionDocItemId: 'draw-item-1',
    actionDocumentRestricted: false,
  );
}
