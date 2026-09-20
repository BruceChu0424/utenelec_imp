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
    expect(unconfirmed.label, '待确认生产路线');
    final partial = ProductionFlowStage.forSegment(
      segmentStatus: 'READY',
      zeroMaterial: false,
      continuousSupply: true,
      canStartNow: false,
      canRequestDraw: true,
    );
    expect(partial.label, '物料已到 · 去领料');
    final available = ProductionFlowStage.forSegment(
      segmentStatus: 'READY',
      zeroMaterial: false,
      continuousSupply: true,
      materialIssued: false,
      canStartNow: true,
    );
    expect(available.label, '已支持部分产量 · 可开工');
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
