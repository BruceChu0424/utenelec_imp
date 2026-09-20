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

/// 阶段色调。2026-09-11 由 3 档扩到 6 档——原先「等待物料 / 去领料 / 可开工 /
/// 生产中」共用一个 active（清一色蓝），用户在车间任务里分不出哪一步该干什么。
/// 2026-09-20 用户口径「不同状态不同颜色，差别大点」：再拆出 [decide]，并把同一
/// 分类里会同时出现的档位拉到互不相邻的色相（红 / 琥珀 / 蓝 / 绿 / 灰）。
///
/// 按**该谁动手、动什么手**分色，同一条链里相邻步骤必然不同色：
/// - [pending]       还没轮到本环节(等下达、待审核、已交仓库待发料)—— 中性灰
/// - [decide]        车间必须先做决定(待选生产路线)，其它动作全部锁着 —— 红
/// - [waiting]       在等别人/等物料到位 —— 琥珀(看得见但不催人)
/// - [toDrawPartial] 备好了一部分，可先领这部分(还缺料)—— 紫
/// - [toDraw]        料全备齐了，可由车间提交领料 —— 蓝
/// - [readyPartial]  部分物料已投，**可开工**(持续生产)—— 品牌青
/// - [ready]         料全在手上，**可开工** —— 绿
/// - [active]        生产中 · 可报工 —— 品牌青(主色系；与 readyPartial 不同分类)
/// - [done]          已完工 —— 绿(只在历史任务/分析列表出现，与可开工不同分类)
enum ProductionFlowTone {
  pending,
  decide,
  waiting,
  toDrawPartial,
  toDraw,
  readyPartial,
  ready,
  active,
  done,
}

/// 车间任务的逐种物料事实(ADR-095/V628，ADR-096/V629)：每种正式物料需求只落一个桶。
/// [kindCount] 为 0 表示零料任务或调用方没有事实（退回旧布尔口径）。
class ProductionMaterialFacts {
  const ProductionMaterialFacts({
    required this.kindCount,
    this.issuedKindCount = 0,
    this.shortKindCount = 0,
    this.shortMakeKindCount = 0,
    this.drawableKindCount = 0,
    this.awaitingWarehouseKindCount = 0,
    this.lineSidePendingKindCount = 0,
    this.supportedOutputQty = 0,
  });

  final int kindCount;
  final int issuedKindCount;
  final int shortKindCount;

  /// 缺料中由自制子件工单供给的种数：子件做完可能直送本车间也可能入库后领料，
  /// 交接方式在子件报工时才决定，这里只说明来源(ADR-096)。
  final int shortMakeKindCount;
  final int drawableKindCount;
  final int awaitingWarehouseKindCount;
  final int lineSidePendingKindCount;

  /// 已实领物料共同支持的可产量。
  final double supportedOutputQty;

  /// 已备齐（预留足量或已领）的种数。
  int get coveredKindCount => (kindCount - shortKindCount).clamp(0, kindCount);

  /// 每种物料都已实领到车间（含直送已投入）。
  bool get allIssued => kindCount > 0 && issuedKindCount >= kindCount;
}

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

  /// 图标也按档分（不只靠颜色区分——色盲/黑白打印同样要读得出来）。
  IconData get icon => switch (tone) {
    ProductionFlowTone.done => Icons.task_alt_rounded,
    ProductionFlowTone.active => Icons.play_circle_outline_rounded,
    ProductionFlowTone.ready => Icons.play_arrow_rounded,
    ProductionFlowTone.readyPartial => Icons.play_arrow_rounded,
    // 去领料 = 要跑一趟仓库，用「搬运/取货」语义的图标。
    ProductionFlowTone.toDraw => Icons.move_to_inbox_rounded,
    ProductionFlowTone.toDrawPartial => Icons.move_to_inbox_rounded,
    ProductionFlowTone.waiting => Icons.hourglass_bottom_rounded,
    // 待选路线 = 车间要先做决定，用「岔路」图标。
    ProductionFlowTone.decide => Icons.alt_route_rounded,
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
        ProductionFlowTone.waiting,
      ),
      // 2026-09-06 车间任务页改版：齐套（READY/DISPATCHED）语义 = 物料齐套、
      // 车间可开工（开工动作在此分类/计划详情触发，与报工自动开工同口径）。
      'MAKE_WAITING_DRAW' => _make(3, '物料齐套 · 可开工', ProductionFlowTone.ready),
      'MAKE_ZERO_READY' => _make(3, '无需领料 · 可开工', ProductionFlowTone.ready),
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
  ///
  /// [startRoute]（V599 开工路线）确认后，WAITING 的等待方式按路线区分——
  /// 与物料分析「未下达段按路线显示第一步」同款：齐套等到齐、分批等部分到货、
  /// 持续等部分物料；未确认/null 保持通用「车间已收到 · 等待物料」。
  ///
  /// 传入 [materials]（ADR-095 逐种物料事实）时，未开工段的文案只按事实生成：
  /// 已领 / 缺(等到货或等自制子件完成)/ 可领 / 待仓库发料 / 可开工——
  /// 2026-09-20 用户口径「物料没有齐不能显示齐，车间内流转的要流转了才算」。
  /// 没有事实（旧调用方）退回布尔口径。
  factory ProductionFlowStage.forSegment({
    required String segmentStatus,
    required bool zeroMaterial,
    bool materialIssued = true,
    bool drawRequested = false,
    bool splitReplaced = false,
    bool continuousSupply = false,
    String? startRoute,
    bool routeConfirmationRequired = false,
    bool? canStartNow,
    bool canRequestDraw = false,
    ProductionMaterialFacts? materials,
    double? reportedQty,
    double? plannedQty,
    double? remainingReportQty,
    double fqcPendingQty = 0,
    double fqcFailedQty = 0,
    double finishedInboundPendingQty = 0,
    double inboundQty = 0,
    bool hasUnregisteredMaterial = false,
    bool hasPendingReturn = false,
    bool hasAvailableMaterial = true,
  }) {
    if (splitReplaced) {
      return _make(2, '已拆分为生产批次', ProductionFlowTone.pending);
    }
    final status = segmentStatus.trim().toUpperCase();
    final route = startRoute?.trim().toUpperCase();
    // 持续生产口径只看已确认路线；continuous_supply 自 V628 起只表示「按增量备料」
    //（改回齐套的工单仍为真），不能再用它判断持续生产。
    final continuousRoute = route == null
        ? continuousSupply
        : route == 'CONTINUOUS';
    if (routeConfirmationRequired &&
        const ['WAITING', 'READY', 'DISPATCHED'].contains(status)) {
      return _make(2, '待选生产路线', ProductionFlowTone.decide);
    }
    final facts = materials;
    if (facts != null &&
        facts.kindCount > 0 &&
        !zeroMaterial &&
        const ['READY', 'DISPATCHED'].contains(status)) {
      return _preparingStage(
        facts: facts,
        continuousRoute: continuousRoute,
        canStartNow: canStartNow == true,
        canRequestDraw: canRequestDraw,
        drawRequested: drawRequested,
      );
    }
    if (facts != null &&
        facts.kindCount > 0 &&
        !zeroMaterial &&
        status == 'WAITING' &&
        route == 'FULL_KIT' &&
        facts.coveredKindCount > 0) {
      return _make(
        2,
        '等待物料到齐 · 已备 ${facts.coveredKindCount}/${facts.kindCount} 种',
        ProductionFlowTone.waiting,
      );
    }
    if (continuousRoute &&
        const ['READY', 'DISPATCHED'].contains(status) &&
        canStartNow != null) {
      // 旧布尔口径（无逐种事实的调用方）：持续生产 READY 只代表有增量物料可领。
      return _make(
        3,
        canStartNow
            ? '部分物料已投 · 可开工'
            : canRequestDraw
            ? '部分物料可领 · 去领料'
            : drawRequested
            ? '已提交领料 · 待仓库发料'
            : '等待物料支持开工',
        canStartNow
            ? ProductionFlowTone.readyPartial
            : canRequestDraw
            ? ProductionFlowTone.toDrawPartial
            : drawRequested
            ? ProductionFlowTone.pending
            : ProductionFlowTone.waiting,
      );
    }
    if (status == 'IN_PROGRESS' &&
        remainingReportQty != null &&
        remainingReportQty <= 0.000001) {
      final label = fqcPendingQty > 0
          ? '已报完 · 待品质检查'
          : finishedInboundPendingQty > 0
          ? '品质通过 · 待点收入库'
          : plannedQty != null && inboundQty >= plannedQty && plannedQty > 0
          ? hasPendingReturn && !hasAvailableMaterial
                ? '已入库 · 待仓库收退料'
                : hasUnregisteredMaterial
                ? '已入库 · 待登记实际用料'
                : '已入库 · 待结清核对'
          : fqcFailedQty > 0
          ? '品质异常 · 待处理'
          : '已报完 · 待仓库登记送检';
      return _make(4, label, ProductionFlowTone.waiting);
    }
    return switch (status) {
      'WAITING' => _make(2, switch (route) {
        'FULL_KIT' => '等待物料到齐 · 齐套生产',
        'BATCH' => '等待到货 · 分批生产',
        'CONTINUOUS' => '等待部分物料 · 持续生产',
        _ => '车间已收到 · 等待物料',
      }, ProductionFlowTone.waiting),
      'READY' =>
        zeroMaterial
            ? _make(3, '无需领料 · 可开工', ProductionFlowTone.ready)
            : _make(
                3,
                materialIssued
                    ? '物料齐套 · 可开工'
                    : drawRequested
                    ? '已提交领料 · 待仓库发料'
                    : '物料齐套 · 去领料',
                materialIssued
                    ? ProductionFlowTone.ready
                    : drawRequested
                    ? ProductionFlowTone.pending
                    : ProductionFlowTone.toDraw,
              ),
      'DISPATCHED' =>
        zeroMaterial
            ? _make(3, '无需领料 · 可开工', ProductionFlowTone.ready)
            : _make(
                3,
                materialIssued
                    ? '物料齐套 · 可开工'
                    : drawRequested
                    ? '已提交领料 · 待仓库发料'
                    : '物料齐套 · 去领料',
                materialIssued
                    ? ProductionFlowTone.ready
                    : drawRequested
                    ? ProductionFlowTone.pending
                    : ProductionFlowTone.toDraw,
              ),
      'IN_PROGRESS' => _make(
        4,
        // V595 持续生产：仓库料与同车间直送料到一批投一批，工单一直开着直到最后一次报工。
        continuousRoute ? '持续生产中 · 按实际投料报工' : '生产中 · 可报工',
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
      'WAITING' => _make(2, '车间已收到 · 等待物料', ProductionFlowTone.waiting),
      'READY' =>
        zeroMaterial
            ? _make(3, '无需领料 · 可开工', ProductionFlowTone.ready)
            : _make(3, '物料齐套 · 可开工', ProductionFlowTone.ready),
      'DISPATCHED' =>
        zeroMaterial
            ? _make(3, '无需领料 · 可开工', ProductionFlowTone.ready)
            : _make(3, '物料齐套 · 可开工', ProductionFlowTone.ready),
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

  /// 未开工段(READY/DISPATCHED)按逐种物料事实生成文案(ADR-095/096)。优先级：
  /// 可开工 → 可领料 → 已交仓库待发 → 缺料(等到货 / 等自制子件完成)→ 备料中。
  /// 「齐」只在每种物料都实领到车间时才说；持续生产只要共同支持正产量就可开工。
  /// 部分与全部各用一档色(2026-09-20 用户口径「部分物料可领和物料已备齐颜色要分开」)。
  static ProductionFlowStage _preparingStage({
    required ProductionMaterialFacts facts,
    required bool continuousRoute,
    required bool canStartNow,
    required bool canRequestDraw,
    required bool drawRequested,
  }) {
    if (canStartNow) {
      return facts.allIssued
          ? _make(3, '物料已领齐 · 可开工', ProductionFlowTone.ready)
          : _make(3, '部分物料已投 · 可开工', ProductionFlowTone.readyPartial);
    }
    if (canRequestDraw) {
      return facts.shortKindCount > 0
          ? _make(3, '部分物料可领 · 去领料', ProductionFlowTone.toDrawPartial)
          : _make(3, '物料已备齐 · 去领料', ProductionFlowTone.toDraw);
    }
    if (facts.awaitingWarehouseKindCount > 0 ||
        (drawRequested && facts.shortKindCount == 0)) {
      return _make(3, '已提交领料 · 待仓库发料', ProductionFlowTone.pending);
    }
    if (facts.shortKindCount > 0) {
      final short = facts.shortKindCount;
      // 自制子件做完可能直送本车间也可能入库后领料，不许诺交接方式，只说来源。
      return _make(
        3,
        continuousRoute
            ? (facts.shortMakeKindCount > 0
                  ? '等自制子件完成 · 缺 $short 种'
                  : '等待到货 · 缺 $short 种')
            : '等待物料到齐 · 已备 ${facts.coveredKindCount}/${facts.kindCount} 种',
        ProductionFlowTone.waiting,
      );
    }
    if (facts.lineSidePendingKindCount > 0) {
      return _make(3, '直送料待投入 · 等待开工条件', ProductionFlowTone.waiting);
    }
    return _make(3, '备料中 · 等待领料指令', ProductionFlowTone.waiting);
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
