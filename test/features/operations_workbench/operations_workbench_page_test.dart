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
      expect(find.text('批量生成采购单'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pump();
      var batchButton = tester.widget<UtenButton>(
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
      expect(batchButton.onPressed, isNull);
      expect(find.text('请选择同一采购申请的明细'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).at(2));
      await tester.tap(find.byType(Checkbox).at(3));
      await tester.pump();
      expect(find.text('先生成/挂接采购申请'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).at(3));
      await tester.tap(find.byType(Checkbox).at(4));
      await tester.pump();
      expect(find.text('采购申请尚未审核，请先审核'), findsOneWidget);
    },
  );

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
    expect(
      gateway.data.exceptionOptions.map((option) => option.value),
      containsAll(<String>['OVERDUE_ANY', 'OVERDUE_SHORTAGE']),
    );
    expect(find.text('全部逾期'), findsOneWidget);
  });

  testWidgets(
    'restricted document metadata and purchase create action stay hidden',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
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

      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(
        find.byKey(const Key('operations-workbench-open-selected')),
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
          surfaceSize: const Size(375, 667),
        ),
        (
          department: OperationsWorkbenchDepartment.purchase,
          metricLabel: '待采购处理',
          status: 'UNPEGGED',
          surfaceSize: const Size(800, 1200),
        ),
        (
          department: OperationsWorkbenchDepartment.subcontract,
          metricLabel: '待委外处理',
          status: 'UNPEGGED',
          surfaceSize: const Size(1200, 800),
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

        expect(gateway.statuses, [null]);
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

      expect(gateway.statuses, [null, 'LEGACY_STATE']);
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
    if (status != null && dataAfterStatusFilter != null) {
      return dataAfterStatusFilter!;
    }
    return data;
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
