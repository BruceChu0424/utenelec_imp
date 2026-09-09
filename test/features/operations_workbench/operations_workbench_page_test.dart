import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';

void main() {
  testWidgets(
    'purchase batch action requires every selected request item link',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
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
      await tester.tap(find.text('申请待分解'));
      await tester.pumpAndSettle();

      expect(find.text('采购任务工作台'), findsOneWidget);
      expect(find.text('已挂接轴套一'), findsOneWidget);
      expect(find.text('生成采购订货单'), findsOneWidget);
      expect(
        find.byKey(const Key('operations-workbench-floating-primary-action')),
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

      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pump();
      batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNotNull);

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

      await tester.tap(find.byType(Checkbox).at(2));
      await tester.tap(find.byType(Checkbox).at(3));
      await tester.pump();
      // 选中不可执行任务：按钮置灰，原因在 Tooltip/点击提示里（不再占选中条）。
      batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNull);

      await tester.tap(find.byType(Checkbox).at(3));
      await tester.tap(find.byType(Checkbox).at(4));
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
        ProviderScope(
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
      await tester.tap(find.text('申请待分解'));
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
        ProviderScope(
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
                    statusCounts: {'FINANCE_APPROVED': 1},
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

      await tester.tap(find.text('财务已通过'));
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
      ProviderScope(
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认未选阶段 → 无任务卡。点「申请待分解」段触发的加载同样被网关挂起，
    // 手动放行后内容才出现（刷新语义与新范式下的首次列表加载一致）。
    await tester.tap(find.text('申请待分解'));
    await tester.pump();
    gateway.completeRefresh();
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    var button = tester.widget<UtenButton>(
      find.byKey(const Key('operations-workbench-purchase-batch')),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byTooltip('刷新'));
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
    'exception segment reloads with a backend-wide exception filter after a stage is chosen',
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
        ProviderScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 默认不选阶段：initState 只发一次概览请求，不带异常筛选。
      expect(gateway.exceptions, [null]);

      // 先选「申请待分解」阶段段，任务列表才加载。
      await tester.tap(find.text('申请待分解'));
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'WAITING_ORDER');
      expect(gateway.exceptions.last, isNull);

      // 阶段内点异常小类「逾期缺料」：带异常参数重新加载，阶段筛选保留；
      // 「全部逾期」（OVERDUE_ANY 聚合段）2026-09-03 起不再显示。
      await tester.tap(find.text('逾期缺料'));
      await tester.pumpAndSettle();

      expect(gateway.exceptions.last, 'OVERDUE_SHORTAGE');
      expect(gateway.statuses.last, 'WAITING_ORDER');
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
        ProviderScope(
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
      await tester.tap(find.text('申请待分解'));
      await tester.pumpAndSettle();

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
        ProviderScope(
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

      // 默认未选阶段：仓库仍走表格布局（useTaskTable），但内容区是引导占位，
      // 不发列表请求——点「待备料 / 待领取」段后表格才加载。
      expect(find.text('在上方选择阶段后开始办理'), findsOneWidget);
      expect(
        find.byKey(const Key('operations-workbench-mobile-list')),
        findsNothing,
      );

      await tester.tap(find.text('待备料 / 待领取'));
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

      await tester.tap(find.text('PP-001'));
      await tester.pump();

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
          ProviderScope(
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
        await tester.tap(find.text(scenario.stageLabel));
        await tester.pumpAndSettle();

        expect(gateway.statuses.last, scenario.status);
        expect(tester.takeException(), isNull);
        // 阶段段保持单选选中（零计数不使分段失效），引导占位消失。
        final stageRow = tester.widget<SegmentedButton<dynamic>>(
          find.byKey(
            Key('operations-workbench-stages-${scenario.department.apiValue}'),
          ),
        );
        expect(stageRow.selected.length, 1);
        expect(find.text('在上方选择阶段后开始办理'), findsNothing);
      },
    );
  }

  testWidgets('zero-count overdue exception segment remains a valid filter', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _FakeGateway(
      // 具体异常段（OVERDUE_ANY 聚合段已不显示）零计数：仍可点选过滤。
      _emptyData(
        department: OperationsWorkbenchDepartment.purchase,
        exceptionCounts: const {'OVERDUE_SHORTAGE': 0},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 异常小类行在选中阶段后才出现：先点「申请待分解」，再点「逾期缺料」。
    await tester.tap(find.text('申请待分解'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('逾期缺料'));
    await tester.pumpAndSettle();

    expect(gateway.exceptions.last, 'OVERDUE_SHORTAGE');
    expect(gateway.statuses.last, 'WAITING_ORDER');
    expect(tester.takeException(), isNull);
    // 零计数异常段仍保持选中（分段单选不因计数为 0/无徽章失效）。
    final exceptionRow = tester.widget<SegmentedButton<dynamic>>(
      find.byKey(const Key('operations-workbench-exceptions-purchase')),
    );
    expect(exceptionRow.selected.length, 1);
  });

  testWidgets('stage segments stay single-select and gate the exception row', (
    tester,
  ) async {
    // 旧「指标卡互斥」语义的新范式等价物：阶段行单选；异常小类行仅在选中
    // 阶段后出现并与阶段组合过滤；切换阶段时异常小类被重置（不残留）。
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _FakeGateway(
      _emptyData(
        department: OperationsWorkbenchDepartment.purchase,
        exceptionCounts: const {'OVERDUE_SHORTAGE': 1},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 默认不选阶段：只有一次概览请求，异常小类行不出现，内容区为引导占位。
    expect(gateway.statuses, [null]);
    expect(find.text('在上方选择阶段后开始办理'), findsOneWidget);
    expect(find.text('逾期缺料'), findsNothing);

    // 点「申请待分解」阶段段：单选生效，异常小类行解锁出现。
    await tester.tap(find.text('申请待分解'));
    await tester.pumpAndSettle();
    expect(gateway.statuses.last, 'WAITING_ORDER');
    expect(gateway.exceptions.last, isNull);
    expect(find.text('逾期缺料'), findsOneWidget);

    // 阶段内点异常段「逾期缺料」：异常与阶段组合（状态筛选保留）。
    await tester.tap(find.text('逾期缺料'));
    await tester.pumpAndSettle();
    expect(gateway.statuses.last, 'WAITING_ORDER');
    expect(gateway.exceptions.last, 'OVERDUE_SHORTAGE');
    expect(tester.takeException(), isNull);

    // 切换到另一阶段段：阶段单选切换，且异常小类重置（不沿用上一个异常）。
    await tester.tap(find.text('等待财务审核'));
    await tester.pumpAndSettle();
    expect(gateway.statuses.last, 'ORDER_PENDING_APPROVAL');
    expect(gateway.exceptions.last, isNull);
    final exceptionRow = tester.widget<SegmentedButton<dynamic>>(
      find.byKey(const Key('operations-workbench-exceptions-purchase')),
    );
    expect(exceptionRow.selected, isEmpty);
  });

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
        ProviderScope(
          child: MaterialApp(
            home: OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 点「申请待分解」：此后该网关返回的概览不再带任何 statusCounts。
      await tester.tap(find.text('申请待分解'));
      await tester.pumpAndSettle();
      expect(gateway.statuses, [null, 'WAITING_ORDER']);

      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();

      // 刷新后阶段选择保持：仍以选中阶段发起请求，分段仍是单选选中态。
      expect(gateway.statuses, [null, 'WAITING_ORDER', 'WAITING_ORDER']);
      expect(tester.takeException(), isNull);
      final stageRow = tester.widget<SegmentedButton<dynamic>>(
        find.byKey(const Key('operations-workbench-stages-purchase')),
      );
      expect(stageRow.selected.length, 1);
      expect(find.text('申请待分解'), findsOneWidget);
      expect(find.text('在上方选择阶段后开始办理'), findsNothing);

      // 阶段段在「选项缺失」的刷新后仍可继续切换。
      await tester.tap(find.text('等待财务审核'));
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'ORDER_PENDING_APPROVAL');
    },
  );
}

class _FakeGateway implements OperationsWorkbenchGateway {
  _FakeGateway(this.data, {this.dataAfterStatusFilter});

  final OperationsWorkbenchData data;
  final OperationsWorkbenchData? dataAfterStatusFilter;
  final List<String?> exceptions = [];
  final List<String?> statuses = [];

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
    exceptionCode: (actionDocItemId == null && actionItemIds.isEmpty)
        ? 'UNLINKED'
        : null,
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

OperationsWorkbenchTask _warehouseTask() {
  return const OperationsWorkbenchTask(
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
    exceptionCode: null,
    updatedAt: '2026-08-22T10:00:00+08:00',
    actionDocument: OperationsActionDocument(
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
