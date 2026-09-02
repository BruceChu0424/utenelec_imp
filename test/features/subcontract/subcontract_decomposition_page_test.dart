import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'compact decomposition selects issued application lines and enables one primary action',
    (tester) async {
      final gateway = _Gateway(_data(capability: true));
      tester.view.physicalSize = const Size(375, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('subcontract-decomposition-compact-list')),
        findsOneWidget,
      );
      expect(gateway.statuses, [null]);
      final stage = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('subcontract-decomposition-status')),
      );
      expect(stage.initialValue, '');
      // V458 清理后页面不再有流程说教横幅，保留 KPI 指标条。
      expect(find.textContaining('这里分解物料分析下达'), findsNothing);
      expect(find.text('待分解'), findsOneWidget);
      var button = tester.widget<UtenButton>(
        find.byKey(const Key('subcontract-decomposition-create-order')),
      );
      expect(button.onPressed, isNull);

      await tester.tap(find.byType(Checkbox).at(0));
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();

      button = tester.widget<UtenButton>(
        find.byKey(const Key('subcontract-decomposition-create-order')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.text('生成委外订货单(2)'), findsOneWidget);
      expect(find.textContaining('可进入委外订货单填写委外商'), findsOneWidget);
    },
  );

  for (final scenario in const [
    (
      name: 'missing local decompose permission',
      permissions: <String>{},
      capability: true,
    ),
    (
      name: 'server capability denies create',
      permissions: <String>{
        Perm.subcontractApplicationView,
        Perm.subcontractOrderView,
        Perm.subcontractOrderCreate,
        Perm.subcontractOrderDecompose,
      },
      capability: false,
    ),
  ]) {
    testWidgets('${scenario.name} hides selection and keeps action disabled', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(scenario.permissions),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: scenario.capability)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsNothing);
      final action = find.byKey(
        const Key('subcontract-decomposition-create-order'),
      );
      if (scenario.permissions.isEmpty) {
        expect(action, findsNothing);
      } else {
        expect(action, findsOneWidget);
        expect(tester.widget<UtenButton>(action).onPressed, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }
}

class _Gateway implements OperationsWorkbenchGateway {
  _Gateway(this.data);
  final OperationsWorkbenchData data;
  final List<String?> statuses = <String?>[];

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
  }) async {
    statuses.add(status);
    return data;
  }
}

OperationsWorkbenchData _data({required bool capability}) =>
    OperationsWorkbenchData(
      department: OperationsWorkbenchDepartment.subcontract,
      summary: const OperationsWorkbenchSummary(
        totalTasks: 2,
        overdueTasks: 0,
        openTasks: 2,
        openQty: 12,
        statusCounts: {'WAITING_ORDER': 2},
      ),
      items: [
        _task('task-1', 'application-1', 'application-item-1'),
        _task('task-2', 'application-2', 'application-item-2'),
      ],
      page: 1,
      size: 20,
      total: 2,
      totalPages: 1,
      capabilities: OperationsWorkbenchCapabilities(
        canCreateSubcontractOrder: capability,
      ),
    );

OperationsWorkbenchTask _task(
  String taskId,
  String applicationId,
  String applicationItemId,
) => OperationsWorkbenchTask(
  taskId: taskId,
  packageId: 'package-1',
  planId: 'plan-1',
  planNo: 'PP-001',
  warehouseName: '委外目标仓',
  goodsCode: 'FG-$taskId',
  goodsName: '委外目标件',
  spec: '标准',
  colorName: '本色',
  unitName: '件',
  supplyRoute: 'SUBCONTRACT',
  requiredQty: 10,
  allocatedQty: 0,
  fulfilledQty: 0,
  supplyPeggedQty: 0,
  openQty: 6,
  taskStatus: 'WAITING_ORDER',
  needDate: '2026-09-10',
  expectedDate: null,
  exceptionCode: null,
  updatedAt: '2026-08-30T10:00:00Z',
  actionDocument: OperationsActionDocument(
    id: applicationId,
    docType: 'SUBCONTRACT_APPLICATION',
    number: 'EA-$applicationId',
    path: '/subcontract/applications/$applicationId',
    canView: true,
    canEdit: false,
    status: '1',
  ),
  actionDocItemId: applicationItemId,
  actionDocumentRestricted: false,
);
