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
      expect(
        find.descendant(
          of: find.byKey(const Key('operations-workbench-selection-bar')),
          matching: find.byKey(
            const Key('operations-workbench-purchase-batch'),
          ),
        ),
        findsNothing,
      );

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
      expect(find.text('先生成/挂接采购申请'), findsOneWidget);
      batchButton = tester.widget<UtenButton>(
        find.byKey(const Key('operations-workbench-purchase-batch')),
      );
      expect(batchButton.onPressed, isNull);

      await tester.tap(find.byType(Checkbox).at(3));
      await tester.tap(find.byType(Checkbox).at(4));
      await tester.pump();
      expect(find.text('计划申请尚未下达，请刷新后重试'), findsOneWidget);
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

  testWidgets('overdue metric reloads with a backend-wide exception filter', (
    tester,
  ) async {
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
    expect(gateway.exceptions, [null]);

    await tester.tap(find.text('逾期 / 异常'));
    await tester.pumpAndSettle();

    expect(gateway.exceptions.last, 'OVERDUE_ANY');
    // 异常卡与状态卡互斥：默认「待完成」状态须被清除，只留逾期一个筛选。
    expect(gateway.statuses.last, isNull);
    expect(
      gateway.data.exceptionOptions.map((option) => option.value),
      containsAll(<String>['OVERDUE_ANY', 'OVERDUE_SHORTAGE']),
    );
    expect(find.text('全部逾期'), findsOneWidget);
  });

  testWidgets(
    'restricted document metadata and purchase create action stay hidden',
    (tester) async {
      // 375 宽保持 compact 卡片布局；1800 高保证懒构建 ListView 里的任务卡
      // 在折叠线之上被物化（指标卡+筛选条占去首屏）。
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
          String metricLabel,
          String status,
          Size surfaceSize,
        })
      >[
        (
          department: OperationsWorkbenchDepartment.warehouse,
          metricLabel: '待备料 / 待领取',
          status: 'READY_TO_PICK',
          // 375 宽保持 compact；1800 高保证筛选下拉在懒构建 ListView 内被物化。
          surfaceSize: const Size(375, 1800),
        ),
        (
          department: OperationsWorkbenchDepartment.purchase,
          metricLabel: '申请待分解',
          status: 'WAITING_ORDER',
          surfaceSize: const Size(800, 1200),
        ),
      ];

  for (final scenario in zeroStatusScenarios) {
    testWidgets(
      '${scenario.department.apiValue} zero-count metric remains a valid filter',
      (tester) async {
        await tester.binding.setSurfaceSize(scenario.surfaceSize);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final gateway = _FakeGateway(
          _emptyData(department: scenario.department),
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

        // 采购/仓库默认待完成（委外默认全部的口径归 SubcontractDecompositionPage）。
        expect(gateway.statuses, [kOperationsWorkbenchOpenStatus]);
        await tester.tap(find.text(scenario.metricLabel));
        await tester.pumpAndSettle();

        expect(gateway.statuses.last, scenario.status);
        expect(tester.takeException(), isNull);
        final statusField = tester.widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>).first,
        );
        expect(statusField.initialValue, scenario.status);
      },
    );
  }

  testWidgets('zero overdue metric remains a valid exception filter', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _FakeGateway(
      _emptyData(department: OperationsWorkbenchDepartment.purchase),
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

    await tester.tap(find.text('逾期 / 异常'));
    await tester.pumpAndSettle();

    expect(gateway.exceptions.last, 'OVERDUE_ANY');
    expect(tester.takeException(), isNull);
    final exceptionField = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).at(1),
    );
    expect(exceptionField.initialValue, 'OVERDUE_ANY');
  });

  testWidgets(
    'metric cards are mutually exclusive across status and exception',
    (tester) async {
      // 双显示回归：点「已完成」再点「逾期 / 异常」，状态筛选须被清除，
      // 任一时刻只保留一张生效的筛选卡（而不是两张卡同时高亮）。
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        _emptyData(department: OperationsWorkbenchDepartment.purchase),
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
      expect(gateway.statuses, [kOperationsWorkbenchOpenStatus]);

      await tester.tap(find.text('已完成'));
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, 'COMPLETED');
      expect(gateway.exceptions.last, isNull);

      await tester.tap(find.text('逾期 / 异常'));
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, isNull);
      expect(gateway.exceptions.last, 'OVERDUE_ANY');
      expect(tester.takeException(), isNull);

      // 再点已选的异常卡取消 → 回到「全部」（状态/异常都为空）。
      await tester.tap(find.text('逾期 / 异常'));
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, isNull);
      expect(gateway.exceptions.last, isNull);
    },
  );

  testWidgets(
    'selected backend status remains valid when refreshed options omit it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _FakeGateway(
        _emptyData(
          department: OperationsWorkbenchDepartment.purchase,
          statusCounts: const {'LEGACY_STATE': 1},
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

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('LEGACY_STATE').last);
      await tester.pumpAndSettle();

      expect(gateway.statuses, [
        kOperationsWorkbenchOpenStatus,
        'LEGACY_STATE',
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('LEGACY_STATE'), findsOneWidget);
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
  }) async {
    exceptions.add(exception);
    statuses.add(status);
    // 首屏默认「待完成」哨兵（OPEN_ANY）仍应返回带完整选项的数据；
    // 只有用户显式选择的具体状态才触发「刷新后选项缺失」场景。
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
  final Completer<OperationsWorkbenchData> _refresh = Completer();
  var _calls = 0;

  void completeRefresh() => _refresh.complete(data);

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
  }) {
    _calls++;
    return _calls == 1 ? Future.value(data) : _refresh.future;
  }
}

OperationsWorkbenchData _emptyData({
  required OperationsWorkbenchDepartment department,
  Map<String, int> statusCounts = const {},
}) {
  return OperationsWorkbenchData(
    department: department,
    summary: OperationsWorkbenchSummary(
      totalTasks: 0,
      overdueTasks: 0,
      openTasks: 0,
      openQty: 0,
      statusCounts: statusCounts,
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
    exceptionCode: actionDocItemId == null ? 'UNLINKED' : null,
    updatedAt: '2026-07-31T10:00:00+08:00',
    actionDocument: actionDocItemId == null
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
