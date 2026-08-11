import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';

void main() {
  testWidgets('expanded desktop table renders header and rows with items', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
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
                  openQty: 16,
                  statusCounts: {'WAITING_ORDER': 2},
                ),
                items: [
                  _task(id: 't1', goodsName: '桌面行一', actionDocItemId: 'ri-1'),
                  _task(id: 't2', goodsName: '桌面行二', actionDocItemId: 'ri-2'),
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

    expect(tester.takeException(), isNull);
    // 桌面表格路径（expanded 断点）
    expect(
      find.byKey(const Key('operations-workbench-desktop-table')),
      findsOneWidget,
    );
    // 表头
    expect(find.text('计划号'), findsOneWidget);
    expect(find.text('货品名称'), findsOneWidget);
    // 表体行
    expect(find.text('桌面行一'), findsOneWidget);
    expect(find.text('桌面行二'), findsOneWidget);
    // 表格区域必须有非零高度
    final tableSize = tester.getSize(
      find.byKey(const Key('operations-workbench-desktop-table')),
    );
    expect(tableSize.height, greaterThan(100));
  });
}

class _FakeGateway implements OperationsWorkbenchGateway {
  _FakeGateway(this.data);

  final OperationsWorkbenchData data;

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
  }) async =>
      data;
}

OperationsWorkbenchTask _task({
  required String id,
  required String goodsName,
  String? actionDocItemId,
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
    taskStatus: 'WAITING_ORDER',
    needDate: '2026-08-01',
    expectedDate: null,
    exceptionCode: null,
    updatedAt: '2026-07-31T10:00:00+08:00',
    actionDocument: actionDocItemId == null
        ? null
        : const OperationsActionDocument(
            id: 'request-1',
            docType: 'PURCHASE_REQUEST',
            number: 'PR-request-1',
            path: '/purchase/requests/request-1',
            canView: true,
            canEdit: false,
            status: '1',
          ),
    actionDocItemId: actionDocItemId,
    actionDocumentRestricted: false,
  );
}
