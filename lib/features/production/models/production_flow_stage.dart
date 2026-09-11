import 'package:flutter/material.dart';

/// 生产全链路「流程阶段」词表 —— 全站唯一口径。
///
/// 自制 / 采购 / 委外三条链的里程碑名称、顺序与展示语义都只在这里定义：
/// 物料分析主表、分桶详情页、我的车间任务、生产调度与进度、计划详情
/// 一律引用本词表，不允许各页面自造状态文案。
///
/// 阶段事实的来源：
/// - 物料行（采购/委外/自制子件）：服务端 [MaterialAnalysisFlowStageService]
///   批量推导的 `flowStage` 键（BUY_* / SC_* / MAKE_*）；
/// - 执行段 / 车间任务 / 顶层产品：执行段状态 + 零料标志 + 报工数量，
///   由 [ProductionFlowStage.forSegment] / [forProduct] 就地推导。
/// 两边共用同一份键与文案，弹窗内的逐步时间线（supply-progress）仍是深钻事实。
enum ProductionFlowRoute { make, buy, subcontract }

enum ProductionFlowTone { pending, active, done }

class ProductionFlowStage {
  const ProductionFlowStage({
    required this.route,
    required this.key,
    required this.label,
    required this.tone,
    required this.stepIndex,
    required this.stepCount,
    this.detail,
    this.progress,
  });

  final ProductionFlowRoute route;
  final String key;
  final String label;
  final String? detail;
  final ProductionFlowTone tone;

  /// 在本链中的位置（0 起）与链长，用于步骤点展示。
  final int stepIndex;
  final int stepCount;

  /// 进行中的完成比（0-1）；仅 [ProductionFlowTone.active] 的生产阶段使用。
  final double? progress;

  int? get progressPercent {
    final ratio = progress;
    if (ratio == null || !ratio.isFinite) return null;
    final clamped = ratio.clamp(0.0, 1.0).toDouble();
    if (clamped >= 1) return 100;
    return (clamped * 100).round().clamp(0, 99);
  }

  IconData get icon => switch (tone) {
    ProductionFlowTone.done => Icons.task_alt_rounded,
    ProductionFlowTone.active => Icons.play_circle_outline_rounded,
    ProductionFlowTone.pending => Icons.schedule_rounded,
  };

  static const _makeStepCount = 6;
  static const _buyStepCount = 7;
  static const _subcontractStepCount = 8;

  /// 解析服务端阶段键（物料行 flowStage 字段）。
  ///
  /// [route] 为该行的确认路线；委外行的前置自制阶段（MAKE_* 键）会显示
  /// 「前置自制」前缀，让委外与自制的同构关系一眼可见。
  factory ProductionFlowStage.fromServerKey(
    String? serverKey, {
    required ProductionFlowRoute route,
    double? progress,
  }) {
    final key = serverKey?.trim().toUpperCase() ?? '';
    final isSubcontractPrefix =
        route == ProductionFlowRoute.subcontract && key.startsWith('MAKE_');
    final stage = _fromKey(key.isEmpty ? null : key, progress: progress);
    if (stage == null) return _unknown(route);
    if (isSubcontractPrefix && stage.route == ProductionFlowRoute.make) {
      return ProductionFlowStage(
        route: ProductionFlowRoute.subcontract,
        key: stage.key,
        label: '前置自制 · ${stage.label}',
        tone: stage.tone,
        stepIndex: stage.stepIndex,
        stepCount: _subcontractStepCount,
        detail: stage.detail,
        progress: stage.progress,
      );
    }
    return stage;
  }

  static ProductionFlowStage? _fromKey(String? key, {double? progress}) {
    if (key == null) return null;
    return switch (key) {
      'MAKE_PENDING_ISSUE' => _make(0, '等待下达车间', ProductionFlowTone.pending),
      'MAKE_PLAN_SUBMITTED' => _make(1, '计划待审核', ProductionFlowTone.pending),
      'MAKE_WAITING_MATERIAL' => _make(
        2,
        '车间已收到 · 等待物料',
        ProductionFlowTone.active,
      ),
      // 2026-09-06 车间任务页改版：齐套（READY/DISPATCHED）语义 = 物料齐套、
      // 车间可开工（开工动作在此分类/计划详情触发，与报工自动开工同口径）。
      'MAKE_WAITING_DRAW' => _make(3, '物料齐套 · 可开工', ProductionFlowTone.active),
      'MAKE_ZERO_READY' => _make(3, '无需领料 · 可开工', ProductionFlowTone.active),
      'MAKE_IN_PROGRESS' => _make(
        4,
        '生产中 · 可报工',
        ProductionFlowTone.active,
        progress: progress,
      ),
      'MAKE_COMPLETED' => _make(5, '已完工', ProductionFlowTone.done),
      'BUY_PENDING_ISSUE' => _buy(0, '等待下发采购', ProductionFlowTone.pending),
      'BUY_REQUESTED' => _buy(1, '等待采购下单', ProductionFlowTone.active),
      'BUY_PENDING_FINANCE' => _buy(
        2,
        '已下单 · 待财务审批',
        ProductionFlowTone.active,
      ),
      'BUY_WAIT_RECEIPT' => _buy(
        3,
        '财务已审批 · 等待仓库收货',
        ProductionFlowTone.active,
      ),
      'BUY_WAIT_IQC' => _buy(4, '仓库已收货 · 等待品质验货', ProductionFlowTone.active),
      'BUY_WAIT_STOCK_IN' => _buy(5, '品质已通过 · 等待入库', ProductionFlowTone.active),
      'BUY_STOCKED' => _buy(6, '已入库', ProductionFlowTone.done),
      'SC_PENDING_ISSUE' => _sc(0, '等待下发委外', ProductionFlowTone.pending),
      'SC_REQUESTED' => _sc(1, '等待委外下单', ProductionFlowTone.active),
      'SC_PENDING_FINANCE' => _sc(2, '已下单 · 待财务审批', ProductionFlowTone.active),
      'SC_WAIT_OUTBOUND' => _sc(
        3,
        '财务已审批 · 等待目标件出仓',
        ProductionFlowTone.active,
      ),
      'SC_WAIT_RETURN' => _sc(4, '已出仓 · 等待回厂', ProductionFlowTone.active),
      'SC_WAIT_IQC' => _sc(5, '已回厂 · 等待品质验货', ProductionFlowTone.active),
      'SC_WAIT_STOCK_IN' => _sc(6, '品质已通过 · 等待入库', ProductionFlowTone.active),
      'SC_STOCKED' => _sc(7, '已入库', ProductionFlowTone.done),
      _ => null,
    };
  }

  /// 执行段事实 → 自制链阶段（车间任务、计划详情、分桶已下达共用）。
  factory ProductionFlowStage.forSegment({
    required String segmentStatus,
    required bool zeroMaterial,
    bool materialIssued = true,
    double? reportedQty,
    double? plannedQty,
  }) {
    final status = segmentStatus.trim().toUpperCase();
    return switch (status) {
      'WAITING' => _make(2, '车间已收到 · 等待物料', ProductionFlowTone.active),
      'READY' =>
        zeroMaterial
            ? _make(3, '无需领料 · 可开工', ProductionFlowTone.active)
            : _make(
                3,
                materialIssued ? '物料齐套 · 可开工' : '物料齐套 · 待仓库发料',
                ProductionFlowTone.active,
              ),
      'DISPATCHED' =>
        zeroMaterial
            ? _make(3, '无需领料 · 可开工', ProductionFlowTone.active)
            : _make(
                3,
                materialIssued ? '物料齐套 · 可开工' : '物料齐套 · 待仓库发料',
                ProductionFlowTone.active,
              ),
      'IN_PROGRESS' => _make(
        4,
        '生产中 · 可报工',
        ProductionFlowTone.active,
        progress: _ratio(reportedQty, plannedQty),
      ),
      'COMPLETED' => _make(5, '已完工', ProductionFlowTone.done),
      // 终态非完工段只在车间任务「历史任务」时间门控视图出现（ADR-066 §1.3），
      // 不能再落到「等待下达车间」误导。
      'CANCELLED' => _make(0, '已取消', ProductionFlowTone.pending),
      'REVERSED' => _make(0, '已红冲', ProductionFlowTone.pending),
      _ => _make(0, '等待下达车间', ProductionFlowTone.pending),
    };
  }

  /// 顶层产品执行状态 → 自制链阶段（分析产品行、分桶已下达共用）。
  ///
  /// [fallbackRatio]：旧服务端没有报工量时退回入库完成比展示，不伪装 0%。
  factory ProductionFlowStage.forProduct({
    String? planExecutionStatus,
    bool zeroMaterial = false,
    double? reportedQty,
    double? plannedQty,
    double? fallbackRatio,
  }) {
    final status = planExecutionStatus?.trim().toUpperCase();
    if (status == null || status.isEmpty) {
      return _make(0, '等待下达车间', ProductionFlowTone.pending);
    }
    return switch (status) {
      'SUBMITTED' => _make(1, '计划待审核', ProductionFlowTone.pending),
      'APPROVED' ||
      'WAITING' => _make(2, '车间已收到 · 等待物料', ProductionFlowTone.active),
      'READY' =>
        zeroMaterial
            ? _make(3, '无需领料 · 可开工', ProductionFlowTone.active)
            : _make(3, '物料齐套 · 可开工', ProductionFlowTone.active),
      'DISPATCHED' =>
        zeroMaterial
            ? _make(3, '无需领料 · 可开工', ProductionFlowTone.active)
            : _make(3, '物料齐套 · 可开工', ProductionFlowTone.active),
      'IN_PROGRESS' => _make(
        4,
        '生产中 · 可报工',
        ProductionFlowTone.active,
        progress: _ratio(reportedQty, plannedQty) ?? _clamped(fallbackRatio),
      ),
      'COMPLETED' => _make(5, '已完工', ProductionFlowTone.done),
      _ => _make(1, '计划执行中', ProductionFlowTone.active),
    };
  }

  /// 带百分比的展示标签（生产中 N%）。
  String get displayLabel {
    if (progressPercent case final percent?) {
      return '$label $percent%';
    }
    return label;
  }

  static ProductionFlowStage _make(
    int index,
    String label,
    ProductionFlowTone tone, {
    double? progress,
  }) => ProductionFlowStage(
    route: ProductionFlowRoute.make,
    key: 'MAKE_$index',
    label: label,
    tone: tone,
    stepIndex: index,
    stepCount: _makeStepCount,
    progress: progress,
  );

  static ProductionFlowStage _buy(
    int index,
    String label,
    ProductionFlowTone tone,
  ) => ProductionFlowStage(
    route: ProductionFlowRoute.buy,
    key: 'BUY_$index',
    label: label,
    tone: tone,
    stepIndex: index,
    stepCount: _buyStepCount,
  );

  static ProductionFlowStage _sc(
    int index,
    String label,
    ProductionFlowTone tone,
  ) => ProductionFlowStage(
    route: ProductionFlowRoute.subcontract,
    key: 'SC_$index',
    label: label,
    tone: tone,
    stepIndex: index,
    stepCount: _subcontractStepCount,
  );

  static ProductionFlowStage _unknown(ProductionFlowRoute route) =>
      ProductionFlowStage(
        route: route,
        key: 'UNKNOWN',
        label: '状态待确认',
        tone: ProductionFlowTone.pending,
        stepIndex: 0,
        stepCount: 1,
      );

  static double? _ratio(double? reported, double? planned) {
    if (reported == null || planned == null || planned <= 0) return null;
    return (reported.clamp(0.0, planned)) / planned;
  }

  static double? _clamped(double? ratio) {
    if (ratio == null || !ratio.isFinite) return null;
    return ratio.clamp(0.0, 1.0).toDouble();
  }
}
