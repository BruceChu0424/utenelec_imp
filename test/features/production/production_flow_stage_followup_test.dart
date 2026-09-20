import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/features/production/models/production_flow_stage.dart';
import 'package:uten_imp/features/production/widgets/production_flow_stage_cell.dart';

void main() {
  test('unconfirmed route and partial material do not claim complete kit', () {
    final unconfirmed = ProductionFlowStage.forSegment(
      segmentStatus: 'READY',
      zeroMaterial: true,
      routeConfirmationRequired: true,
    );
    expect(unconfirmed.label, '待选生产路线');
    expect(unconfirmed.tone, ProductionFlowTone.decide);
    // 旧布尔口径（无逐种事实）：持续生产 READY 只代表有增量物料可领。
    final partial = ProductionFlowStage.forSegment(
      segmentStatus: 'READY',
      zeroMaterial: false,
      continuousSupply: true,
      canStartNow: false,
      canRequestDraw: true,
    );
    expect(partial.label, '部分物料可领 · 去领料');
    expect(partial.tone, ProductionFlowTone.toDraw);
    final available = ProductionFlowStage.forSegment(
      segmentStatus: 'READY',
      zeroMaterial: false,
      continuousSupply: true,
      materialIssued: false,
      canStartNow: true,
    );
    expect(available.label, '部分物料已投 · 可开工');
  });

  // ADR-095（2026-09-20 用户口径「物料没有齐不能显示齐，车间内流转的要流转了才算」）：
  // 未开工段的文案只按逐种物料事实生成，「齐」只在每种物料都实领到车间时才说。
  test('material facts drive preparing labels without claiming a full kit', () {
    ProductionFlowStage stage({
      required ProductionMaterialFacts facts,
      String route = 'CONTINUOUS',
      bool canStart = false,
      bool canRequestDraw = false,
      bool drawRequested = false,
      String status = 'READY',
    }) => ProductionFlowStage.forSegment(
      segmentStatus: status,
      zeroMaterial: false,
      startRoute: route,
      continuousSupply: true,
      materials: facts,
      canStartNow: canStart,
      canRequestDraw: canRequestDraw,
      drawRequested: drawRequested,
    );
    // 2/3 已领、1 种等同车间子件直送：不是「待仓库发料」，也不是「已到」。
    final directShort = stage(
      facts: const ProductionMaterialFacts(
        kindCount: 3,
        issuedKindCount: 2,
        shortKindCount: 1,
        shortDirectKindCount: 1,
      ),
      drawRequested: true,
    );
    expect(directShort.label, '等同车间直送 · 缺 1 种');
    expect(directShort.tone, ProductionFlowTone.waiting);
    // 缺的是采购/委外未到货。
    expect(
      stage(
        facts: const ProductionMaterialFacts(
          kindCount: 3,
          issuedKindCount: 2,
          shortKindCount: 1,
        ),
      ).label,
      '等待到货 · 缺 1 种',
    );
    // 全部实领：持续生产也说「已领齐」，不再说「部分产量」。
    final allIssued = stage(
      facts: const ProductionMaterialFacts(kindCount: 1, issuedKindCount: 1),
      canStart: true,
    );
    expect(allIssued.label, '物料已领齐 · 可开工');
    expect(allIssued.tone, ProductionFlowTone.ready);
    expect(
      stage(
        facts: const ProductionMaterialFacts(kindCount: 2, issuedKindCount: 1),
        canStart: true,
      ).label,
      '部分物料已投 · 可开工',
    );
    // 可领：还缺料时只说「部分物料可领」。
    expect(
      stage(
        facts: const ProductionMaterialFacts(
          kindCount: 2,
          drawableKindCount: 1,
          shortKindCount: 1,
        ),
        canRequestDraw: true,
      ).label,
      '部分物料可领 · 去领料',
    );
    expect(
      stage(
        facts: const ProductionMaterialFacts(
          kindCount: 2,
          drawableKindCount: 2,
        ),
        canRequestDraw: true,
      ).label,
      '物料已备齐 · 去领料',
    );
    // 已交仓库待发。
    expect(
      stage(
        facts: const ProductionMaterialFacts(
          kindCount: 2,
          awaitingWarehouseKindCount: 2,
        ),
      ).label,
      '已提交领料 · 待仓库发料',
    );
    // 曾按持续生产备过部分料再改齐套的工单：仍是 READY，但按齐套口径说「等待到齐」。
    expect(
      stage(
        facts: const ProductionMaterialFacts(
          kindCount: 3,
          issuedKindCount: 2,
          shortKindCount: 1,
          shortDirectKindCount: 1,
        ),
        route: 'FULL_KIT',
      ).label,
      '等待物料到齐 · 已备 2/3 种',
    );
    // 齐套 WAITING 已备了一部分（只可能来自增量备料）也报数量。
    expect(
      stage(
        facts: const ProductionMaterialFacts(kindCount: 3, shortKindCount: 1),
        route: 'FULL_KIT',
        status: 'WAITING',
      ).label,
      '等待物料到齐 · 已备 2/3 种',
    );
  });

  test('preparing tones use pairwise distinct badge colours', () {
    final tones = [
      ProductionFlowTone.decide,
      ProductionFlowTone.waiting,
      ProductionFlowTone.toDraw,
      ProductionFlowTone.ready,
      ProductionFlowTone.pending,
    ];
    final types = tones
        .map(
          (tone) => productionFlowBadgeType(
            ProductionFlowStage(
              route: ProductionFlowRoute.make,
              key: 'x',
              label: 'x',
              tone: tone,
              stepIndex: 0,
              stepCount: 1,
            ),
          ),
        )
        .toSet();
    expect(types.length, tones.length, reason: '等待物料里同时出现的档位必须各有一色');
  });
  test(
    'continuous task does not label planned remainder as material capacity',
    () {
      final stage = ProductionFlowStage.forSegment(
        segmentStatus: 'IN_PROGRESS',
        zeroMaterial: false,
        continuousSupply: true,
        plannedQty: 1000,
        reportedQty: 100,
        remainingReportQty: 900,
      );
      expect(stage.label, '持续生产中 · 按实际投料报工');
      expect(stage.progressPercent, 10);
    },
  );
  test(
    'material fully awaiting return receipt does not ask for consumption again',
    () {
      final stage = ProductionFlowStage.forSegment(
        segmentStatus: 'IN_PROGRESS',
        zeroMaterial: false,
        plannedQty: 100,
        inboundQty: 100,
        remainingReportQty: 0,
        hasUnregisteredMaterial: true,
        hasPendingReturn: true,
        hasAvailableMaterial: false,
      );
      expect(stage.label, '已入库 · 待仓库收退料');
    },
  );
  test(
    'kit request, warehouse issue and start stay distinct in both themes',
    () {
      final waiting = ProductionFlowStage.forSegment(
        segmentStatus: 'WAITING',
        zeroMaterial: false,
        materialIssued: false,
      );
      final ready = ProductionFlowStage.forSegment(
        segmentStatus: 'READY',
        zeroMaterial: false,
        materialIssued: false,
      );
      final requested = ProductionFlowStage.forSegment(
        segmentStatus: 'READY',
        zeroMaterial: false,
        materialIssued: false,
        drawRequested: true,
      );
      final issued = ProductionFlowStage.forSegment(
        segmentStatus: 'READY',
        zeroMaterial: false,
        // materialIssued 默认 true，不显式传。
      );
      expect(ready.label, '物料齐套 · 去领料');
      expect(requested.label, '已提交领料 · 待仓库发料');
      expect(issued.label, '物料齐套 · 可开工');
      expect(
        productionFlowBadgeType(ready),
        isNot(productionFlowBadgeType(waiting)),
      );
      for (final theme in [ThemeData.light(), ThemeData.dark()]) {
        expect(
          productionFlowToneColor(theme, ready.tone),
          isNot(productionFlowToneColor(theme, waiting.tone)),
        );
      }
    },
  );
  test('reported quantity does not imply another issue or another report', () {
    final stage = ProductionFlowStage.forSegment(
      segmentStatus: 'IN_PROGRESS',
      zeroMaterial: false,
      reportedQty: 10000,
      plannedQty: 10000,
      remainingReportQty: 0,
      inboundQty: 10000,
      hasUnregisteredMaterial: true,
    );
    expect(stage.label, '已入库 · 待登记实际用料');
    expect(stage.progressPercent, isNull);
    expect(stage.tone, ProductionFlowTone.waiting);
  });

  test('quality and inbound follow-ups remain distinct after reporting', () {
    for (final (quality, inbound, label) in [
      (10.0, 0.0, '已报完 · 待品质检查'),
      (0.0, 10.0, '品质通过 · 待点收入库'),
      (0.0, 0.0, '已报完 · 待仓库登记送检'),
    ]) {
      final stage = ProductionFlowStage.forSegment(
        segmentStatus: 'IN_PROGRESS',
        zeroMaterial: false,
        remainingReportQty: 0,
        reportedQty: 10,
        plannedQty: 10,
        fqcPendingQty: quality,
        finishedInboundPendingQty: inbound,
      );
      expect(stage.label, label);
    }
  });

  test(
    'authorized recovery quantity stays reportable after original reporting',
    () {
      final stage = ProductionFlowStage.forSegment(
        segmentStatus: 'IN_PROGRESS',
        zeroMaterial: false,
        remainingReportQty: 2,
        reportedQty: 10,
        plannedQty: 10,
        fqcFailedQty: 2,
      );
      expect(stage.label, '生产中 · 可报工');
    },
  );
}
