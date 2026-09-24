// ADR-117：车间任务「等计划下单」档的优先级——车间自己能先办的(可开工 / 可领料 /
// 已交仓库待发)照旧排前面；路线没选先选路线；已开工 / 零料 / 计划都下过单的不出现。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/features/production/models/production_flow_stage.dart';
import 'package:uten_imp/features/production/widgets/production_flow_stage_cell.dart';

void main() {
  ProductionFlowStage stage({
    String status = 'WAITING',
    int gap = 2,
    bool urged = false,
    bool canStart = false,
    bool canRequestDraw = false,
    int awaitingWarehouse = 0,
    bool zeroMaterial = false,
    bool routeRequired = false,
    String? route = 'FULL_KIT',
  }) => ProductionFlowStage.forSegment(
    segmentStatus: status,
    zeroMaterial: zeroMaterial,
    startRoute: route,
    routeConfirmationRequired: routeRequired,
    canStartNow: canStart,
    canRequestDraw: canRequestDraw,
    materials: ProductionMaterialFacts(
      kindCount: 4,
      issuedKindCount: 1,
      shortKindCount: 3,
      awaitingWarehouseKindCount: awaitingWarehouse,
      planningGapKindCount: gap,
      planningUrged: urged,
    ),
  );

  test('缺的料计划没下单：品红「等计划下单 · 缺 N 种」，催过改说「已催计划」', () {
    final waiting = stage();
    expect(waiting.label, '等计划下单 · 缺 2 种');
    expect(waiting.tone, ProductionFlowTone.waitPlanning);
    expect(productionFlowBadgeType(waiting), UtenStatusBadgeType.fuchsia);
    expect(waiting.icon, Icons.campaign_rounded);

    final urged = stage(urged: true);
    expect(urged.label, '已催计划 · 等下单 2 种');
    expect(urged.tone, ProductionFlowTone.waitPlanning);

    for (final status in ['READY', 'DISPATCHED']) {
      expect(stage(status: status).tone, ProductionFlowTone.waitPlanning);
    }
  });

  test('车间自己能先办的排在「等计划下单」前面', () {
    expect(stage(canStart: true).tone, isNot(ProductionFlowTone.waitPlanning));
    expect(
      stage(canRequestDraw: true).tone,
      isNot(ProductionFlowTone.waitPlanning),
    );
    expect(
      stage(awaitingWarehouse: 1).tone,
      isNot(ProductionFlowTone.waitPlanning),
    );
    // 路线没选：先选路线(红)，其它一律锁着。
    final decide = stage(routeRequired: true, route: null);
    expect(decide.label, '待选生产路线');
    expect(decide.tone, ProductionFlowTone.decide);
  });

  test('已开工 / 已结束 / 零料 / 计划都下过单：不出现「等计划下单」', () {
    for (final status in ['IN_PROGRESS', 'COMPLETED', 'CANCELLED']) {
      expect(
        stage(status: status).label,
        isNot(contains('计划')),
        reason: status,
      );
    }
    expect(stage(zeroMaterial: true).label, isNot(contains('计划')));
    final ordered = stage(gap: 0);
    expect(ordered.tone, isNot(ProductionFlowTone.waitPlanning));
    expect(ordered.label, isNot(contains('计划')));
  });

  test('深色主题下品红档有独立的前景色', () {
    final light = productionFlowToneColor(
      ThemeData(brightness: Brightness.light),
      ProductionFlowTone.waitPlanning,
    );
    final dark = productionFlowToneColor(
      ThemeData(brightness: Brightness.dark),
      ProductionFlowTone.waitPlanning,
    );
    expect(light, isNot(dark));
  });
}
