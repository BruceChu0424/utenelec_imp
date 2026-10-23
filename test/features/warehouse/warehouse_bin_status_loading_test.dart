import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_task_center.dart';

import 'workshop_material_test_support.dart';

class _Bins extends FakeWorkshopMaterialRepository {
  _Bins() {
    settingsResult = [
      for (var index = 0; index < 9; index++)
        WmSetting(
          workshopDepartmentId: 'workshop-$index',
          workshopName: '车间$index',
          status: WmBinStatus.periodic,
          periodicEnabled: true,
          binWarehouseId: 'bin-$index',
        ),
    ];
  }
  int active = 0;
  int peak = 0;
  final reads = <String>[];
  @override
  Future<List<WmPeriod>> periods(String binId) async {
    reads.add(binId);
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    active--;
    return [
      WmPeriod(
        id: 'period-$binId',
        periodNo: 1,
        startDate: '2026-10-01',
        status: WmPeriodStatus.open,
      ),
    ];
  }
}

void main() {
  testWidgets(
    'bin overview keeps a bounded shared read pool for every workshop',
    (tester) async {
      final repo = _Bins();
      await pumpWorkshopMaterialPage(
        tester,
        const Scaffold(
          body: WmBinStatusSegment(refreshTick: 0, header: SizedBox.shrink()),
        ),
        repo: repo,
      );
      expect(repo.peak, 4);
      expect(repo.reads, [
        for (var index = 0; index < 9; index++) 'bin-$index',
      ]);
      expect(find.text('车间0'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
