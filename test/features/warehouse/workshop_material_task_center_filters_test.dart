import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_task_center.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_center_scaffold.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import 'workshop_material_test_support.dart';

class _ScopedPeriods extends FakeWorkshopMaterialRepository {
  final scopes = <Map<String, String>>[];
  @override
  Future<List<WmSetting>> taskStatus({
    Map<String, String> scope = const {},
  }) async {
    scopes.add(Map.of(scope));
    return const [
      WmSetting(
        workshopDepartmentId: 'w1',
        workshopName: '注塑车间',
        status: WmBinStatus.periodic,
        periodicEnabled: true,
        binWarehouseId: 'bin1',
        currentPeriod: WmPeriod(
          id: 'open',
          periodNo: 3,
          startDate: '2026-10-20',
          status: 'OPEN',
        ),
        pendingPeriod: WmPeriod(
          id: 'counting',
          periodNo: 2,
          startDate: '2026-10-01',
          status: 'COUNTING',
        ),
      ),
    ];
  }

  @override
  Future<List<WmPeriod>> periods(String binWarehouseId) =>
      throw StateError('不得逐仓重复请求期间');
}

void main() {
  testWidgets('周期列表将选仓传服务端并优先展示服务端待盘期间，不重复读取每仓期间', (tester) async {
    final repo = _ScopedPeriods();
    await pumpWorkshopMaterialPage(
      tester,
      const Scaffold(
        body: WarehouseListScope(
          scope: WarehouseTaskScope.warehouse('source-leaf'),
          child: WmBinStatusSegment(refreshTick: 0, header: SizedBox.shrink()),
        ),
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialCount,
      },
    );
    expect(repo.scopes.single, {'scopeWarehouseId': 'source-leaf'});
    expect(find.text('盘点中'), findsOneWidget);
    expect(find.text('开着'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('内料仓任务入口只保留审核与周期盘点，领退料在出入库办理', (tester) async {
    await pumpWorkshopMaterialPage(
      tester,
      const Scaffold(body: WorkshopMaterialTaskCenter()),
      repo: FakeWorkshopMaterialRepository(),
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
        Perm.workshopMaterialCount,
        Perm.stockCountWarehouseReview,
      },
    );
    final scaffold = tester.widget<WarehouseTaskCenterScaffold>(
      find.byType(WarehouseTaskCenterScaffold),
    );
    expect(scaffold.segments.map((segment) => segment.value), [
      'count',
      'periodCount',
      'history',
    ]);
    expect(find.text('待发料'), findsNothing);
    expect(find.text('待收退回'), findsNothing);
    expect(find.text('直接发料'), findsNothing);
    expect(find.text('盘点审核'), findsOneWidget);
    expect(find.text('审核记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有发料权限的人不再进入内料仓审核队列', (tester) async {
    await pumpWorkshopMaterialPage(
      tester,
      const Scaffold(body: WorkshopMaterialTaskCenter()),
      repo: FakeWorkshopMaterialRepository(),
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    expect(find.text('暂无已授权的内料仓审核任务'), findsOneWidget);
    expect(find.byType(WarehouseTaskCenterScaffold), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
