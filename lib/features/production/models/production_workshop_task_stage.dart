import '../../../core/l10n/gen/app_localizations.dart';
import 'production_execution_workbench.dart';
import 'production_flow_stage.dart';

/// Workshop presentation of server facts, with optional local draft occupancy.
/// Dart and Java export adapters use workshop-task-stage-v1.json contract cases.
ProductionFlowStage workshopTaskFlowStage(
  ProductionExecutionWorkbenchSegment task, {
  required AppLocalizations l10n,
  Object? draftReportedQty = 0,
}) =>
    _binMaterialStageOf(task, l10n) ??
    _orderFlowStageOf(task, l10n, draftReportedQty);

/// 车间内料仓用料状态的阶段(ADR-131 §5.4)：先于领料发现判定——待认料归
/// 「等待物料」、状态「待认料」；产品的料要从内料仓领而本车间没开启的，
/// 红底「不能开工」。只对未开工段生效。
ProductionFlowStage? _binMaterialStageOf(
  ProductionExecutionWorkbenchSegment task,
  AppLocalizations l10n,
) {
  const started = {'IN_PROGRESS', 'COMPLETED', 'CANCELLED', 'REVERSED'};
  if (started.contains(task.segmentStatus)) return null;
  if (task.needsMaterialChoice) {
    return ProductionFlowStage(
      route: ProductionFlowRoute.make,
      key: 'MAKE_BIN_NEED_CHOICE',
      label: l10n.wmNeedChoice,
      tone: ProductionFlowTone.decide,
      stepIndex: 0,
      stepCount: 5,
    );
  }
  if (task.needsMaterialBin) {
    return const ProductionFlowStage(
      route: ProductionFlowRoute.make,
      key: 'MAKE_BIN_NEED_BIN',
      label: '车间内料仓未开启 · 不能开工',
      tone: ProductionFlowTone.decide,
      stepIndex: 0,
      stepCount: 5,
    );
  }
  return null;
}

/// 按工单领料链路的阶段(原口径)：领料发现在前，其余按全站流程词表。
ProductionFlowStage _orderFlowStageOf(
  ProductionExecutionWorkbenchSegment task,
  AppLocalizations l10n,
  Object? draftReportedQty,
) => task.materialDiscoveryRequired
    ? ProductionFlowStage(
        route: ProductionFlowRoute.make,
        key: 'MAKE_MATERIAL_DISCOVERY',
        label: task.materialDiscoveryStatus == 'PENDING'
            ? l10n.materialDiscoveryPending
            : l10n.materialDiscoveryNeeded,
        tone: task.materialDiscoveryStatus == 'PENDING'
            ? ProductionFlowTone.waiting
            : ProductionFlowTone.decide,
        stepIndex: 0,
        stepCount: 5,
      )
    : ProductionFlowStage.forSegment(
        segmentStatus: task.segmentStatus,
        zeroMaterial: task.zeroMaterial,
        materialIssued: task.issued,
        partialMaterialReportLimited: task.partialMaterialReportLimited,
        drawRequested: task.drawRequested,
        splitReplaced: task.splitReplaced,
        continuousSupply: task.continuousSupply,
        startRoute: task.startRoute,
        routeConfirmationRequired: task.startRoute == null,
        canStartNow: task.canStart,
        canRequestDraw: task.canRequestDraw,
        // 2026-09-20 用户口径「物料没有齐不能显示齐，车间内流转的要流转了才算」：
        // 未开工段的文案只按服务端逐种物料事实生成(ADR-095)。
        materials: _materialFactsOf(task),
        reportedQty: (task.reportedQty - task.actualSurplusReportedQty).clamp(
          0.0,
          double.infinity,
        ),
        plannedQty: task.plannedQty,
        // 草稿承接的数量占住待报额度：阶段词表按扣减后的事实判定
        //（全部被承接=「报工草稿待审核」，部分承接仍显示可报）。
        remainingReportQty: task.remainingReportQtyText,
        draftReportedQty: draftReportedQty,
        fqcPendingQty: task.fqcPendingQty,
        fqcFailedQty: task.fqcFailedQty,
        finishedInboundPendingQty: task.finishedInboundPendingQty,
        inboundQty: task.plannedInboundQty,
        hasUnregisteredMaterial: task.hasUnregisteredMaterial,
        hasPendingReturn: task.hasPendingReturn,
        hasAvailableMaterial: task.hasAvailableMaterial,
      );

ProductionMaterialFacts _materialFactsOf(
  ProductionExecutionWorkbenchSegment task,
) => ProductionMaterialFacts(
  kindCount: task.materialKindCount,
  issuedKindCount: task.materialIssuedKindCount,
  shortKindCount: task.materialShortKindCount,
  shortMakeKindCount: task.materialShortMakeKindCount,
  drawableKindCount: task.materialDrawableKindCount,
  awaitingWarehouseKindCount: task.materialAwaitingWarehouseKindCount,
  lineSidePendingKindCount: task.materialLineSidePendingKindCount,
  supportedOutputQty: task.materialSupportedOutputQty,
  planningGapKindCount: task.materialPlanningGapKindCount,
  planningUrged: task.planningUrgeCount > 0,
);
