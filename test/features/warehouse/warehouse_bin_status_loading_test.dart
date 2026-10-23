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
          currentPeriod: WmPeriod(
            id: 'period-bin-$index',
            periodNo: 1,
            startDate: '2026-10-01',
            status: WmPeriodStatus.open,
          ),
        ),
    ];
  }
  int statusReads = 0;
  final reads = <String>[];
  @override
  Future<List<WmSetting>> taskStatus({
    Map<String, String> scope = const {},
  }) async {
    statusReads++;
    return settingsResult;
  }

  @override
  Future<List<WmPeriod>> periods(String binId) async {
    reads.add(binId);
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
    'bin overview uses one authoritative task status read without per-bin fanout',
    (tester) async {
      final repo = _Bins();
      await pumpWorkshopMaterialPage(
        tester,
        const Scaffold(
          body: WmBinStatusSegment(refreshTick: 0, header: SizedBox.shrink()),
        ),
        repo: repo,
      );
      expect(repo.statusReads, 1);
      expect(repo.reads, isEmpty);
      expect(find.text('车间0'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
