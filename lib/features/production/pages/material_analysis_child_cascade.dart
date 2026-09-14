part of 'production_material_analysis_page.dart';

/// 父件 + 下层一起下单（ADR-081，2026-09-14 修订为**弹窗前置**）：在分桶页
/// 点「创建生产计划 / 下达委外」时，若被下达件的 BOM 还有没下单的下层，**先**
/// 弹这张与物料分析准备页同款的层级表——树顶是被下达件本身，下面是子层 /
/// 孙层，数量按本批数量自动算好（可改），点「一键下单」才按序提交：
/// 先父件（车间走 issue-plans 原子建锚点 + 出计划 / 委外走 notify），
/// 再按最新快照重建下层行并继承已填数量，最后按各自路线分流——
/// 采购行走下达采购、无子层委外行走下达委外、自制与有子层委外行回到
/// 下达车间。基础需求已下过单的下层行按申请进度分流：申请未分解的把追加量
/// **并入原申请**（明细数量改大，V477 口径），已分解的问过用户后按**追加**
/// 另立申请（notify 超量通道）。
///
///不是一个事务：各段各有自己的校验、幂等键与 CAS（ADR-080「明确不做」里
/// 拒绝把它们压进一个事务的理由依然成立）。这里做的是**有序编排 + 逐段如实
/// 回报**：任一段失败即停下、不静默继续，已成功的段保留（幂等键可重放），
/// 弹窗按最新快照重算后留在原地供重试。

/// 一次下达车间里的一行，作为下层展开的起点。
///
/// 只存 ID 和本批数量：下达成功后分析快照会整体换一份，提交前抓到的
/// product / material 对象立刻过期，必须按新快照重新解析。
class _ChildCascadeSeed {
  const _ChildCascadeSeed({
    required this.label,
    required this.batchQty,
    this.analysisLineId,
    this.materialLineId,
    this.unitName,
  });

  /// 被下达件的显示名（弹窗标题与逐行「来自」列用）。
  final String label;

  /// 本批数量（含超出需求的公共备货产出部分）——下层展开的驱动量。
  final double batchQty;

  /// 产品行（顶层产品或已建锚点子件）。
  final String? analysisLineId;

  /// 候选物料行（自制候选 / 有子层委外候选）。
  final String? materialLineId;

  final String? unitName;
}

/// 下层行按有效路线分流到的下达通道。
enum _CascadeKind {
  /// 采购 → 下达采购（notify BUY）。
  buy,

  /// 无子层委外 → 下达委外（notify SUBCONTRACT，直接形成委外申请）。
  subcontractLeaf,

  /// 自制 / 有子层委外 → 下达车间（issue-plans：建锚点 + 出计划，同一事务）。
  workshop,
}

extension _CascadeKindX on _CascadeKind {
  String get label => switch (this) {
    _CascadeKind.buy => '采购',
    _CascadeKind.subcontractLeaf => '委外',
    _CascadeKind.workshop => '车间',
  };

  /// 未下达时的第一步（全站统一流程词表，见 生产物料分析页 §3.7）。
  String get pendingStage => switch (this) {
    _CascadeKind.buy => '等待下发采购',
    _CascadeKind.subcontractLeaf => '等待下发委外',
    _CascadeKind.workshop => '等待下达车间',
  };
}

/// 展开阶段的中间结果：一条 BOM 路径 + 它在本批下的毛需求。
typedef _CascadeNode = ({
  ProductionMaterialAnalysisMaterial material,
  int depth,
  String seedLabel,

  /// 驱动本节点的上层行（null = 直接由种子驱动）。
  String? parentMaterialLineId,

  /// 驱动方的单位耗用（种子 = 种子除数），用于「改上层数量 → 下层重算」。
  double parentPerProduct,

  /// 本批毛需求 = 驱动量 × 本节点单位耗用 ÷ 驱动方单位耗用。
  double grossNeed,

  /// 刚下达的那个件本身：树顶只读行（用户口径「最上面就是点击下达车间的」），
  /// 不参与提交单元合并、不可勾选。
  bool isSeed,
});

/// 下层办齐弹窗里的一行（与下达车间桶同一张 UtenEditableGrid）。
class _ChildCascadeRow extends EditableGridRow {
  _ChildCascadeRow({
    required this.material,
    required this.groupKey,
    required this.submitKey,
    required this.depth,
    required this.seedLabel,
    required this.route,
    required this.kind,
    required this.parentMaterialLineId,
    required this.parentPerProduct,
    required this.grossNeed,
    required this.snapshotNeed,
    required this.residual,
    required this.overspill,
    required this.suggested,
    required this.ownsInput,
    required this.mergedPathCount,
    required this.blockedReason,
    required this.overCapped,
    this.isSeed = false,
  }) {
    if (ownsInput && suggested > 0) qty.text = _bucketQtyText(suggested);
  }

  /// 树顶那行 = 刚下达的件本身，只读上下文（下层数量都由它的本批数量驱动）。
  final bool isSeed;

  final ProductionMaterialAnalysisMaterial material;

  /// 本行在当前快照里的 `_MaterialGroup.key`（路线确认 / 下达按它定位）。
  final String groupKey;

  /// 提交单元身份 = actionGroupKey ?? materialLineId。同一提交单元在树里
  /// 出现多次时只有第一处可填数量，其余行只作层级上下文。
  final String submitKey;

  /// 相对被下达件的层级（1 = 直接子件）。
  final int depth;
  final String seedLabel;
  final MaterialSupplyRoute route;
  final _CascadeKind kind;

  final String? parentMaterialLineId;
  final double parentPerProduct;

  /// 本批毛需求（按本批数量算出来的「要用多少」）。
  double grossNeed;

  /// 服务端快照里这些路径的本批需求合计。
  final double snapshotNeed;

  /// 服务端口径的可下达余量（本批缺口 − 已在途）。
  final double residual;

  /// 超产造成的额外量 = max(0, 毛需求 − 快照需求)。
  double overspill;

  /// 建议下单量 = 可下达余量 + 额外量（无超量权限的采购/委外行按余量封顶）。
  double suggested;

  /// 额外量因缺少超量下达权限被砍掉。
  bool overCapped;

  final bool ownsInput;
  final int mergedPathCount;

  /// 非空 = 本行不能在这里下达（原因如实显示，不勾选）。
  final String? blockedReason;

  final TextEditingController qty = TextEditingController();
  final ValueNotifier<String?> departmentId = ValueNotifier<String?>(null);
  String? departmentName;
  bool workshopAutofilled = false;
  final ValueNotifier<String?> workerId = ValueNotifier<String?>(null);
  String? workerName;
  bool workerAutofilled = false;

  /// 用户手工改过本行数量：上层数量再变时不覆盖它。
  bool qtyTouched = false;

  /// 基础需求已下过单的行：下游采购/委外申请联动（null = 未下过单或未加载，
  /// 走普通下达；加载失败不阻断，按无联动展示）。
  MaterialAnalysisSupplyLink? supplyLink;

  /// 基础需求已覆盖（还可下达=0）而本批超产又多出来的量：需要走「并入申请」
  /// 或「追加」通道，而不是普通下单。
  bool get supplementMode =>
      residual <= 0.0001 &&
      overspill > 0.0001 &&
      supplyLink != null &&
      (kind == _CascadeKind.buy || kind == _CascadeKind.subcontractLeaf);

  /// 并入已有申请：申请未分解出订货单，追加量直接把明细数量改大。
  bool get adjustIntoRequest => supplementMode && supplyLink!.adjustable;

  /// 已分解出订货单 / 委外申请：问过用户后按追加另立申请（需超量权限）。
  bool get appendToOrdered => supplementMode && !supplyLink!.adjustable;

  String get id => material.materialLineId;
  String? get goodsId => material.goodsId;
  double get perProductQty => material.perProductQty;

  /// 可勾选可下达：有输入框、无阻断原因，且（有建议量 或 可并入已有申请——
  /// 并入走采购侧 sanctioned 入口，权限由该端点自裁，不吃分析侧超量闸）。
  bool get selectable =>
      !isSeed &&
      ownsInput &&
      blockedReason == null &&
      (suggested > 0.0001 || adjustIntoRequest);

  bool get needsWorkshop => !isSeed && kind == _CascadeKind.workshop;

  double get enteredQty => double.tryParse(qty.text.trim()) ?? 0;

  @override
  void dispose() {
    qty.dispose();
    departmentId.dispose();
    workerId.dispose();
    super.dispose();
  }
}

/// 一键下单的逐段结果（成功段与失败点都如实回报，不合并成一句「已完成」）。
typedef _CascadeStepResult = ({String label, int count, bool ok, String? note});

abstract class _MaterialAnalysisChildCascadeState
    extends _MaterialAnalysisMaterialTableState {
  /// 展开上限：一棵深 BOM 可以炸出几千行，弹窗不是主表，超过就明说被截断。
  static const int _cascadeRowLimit = 300;

  // ===== 一、按本批数量展开下层 =====

  /// 把本次下达车间的各行按 BOM 自顶向下展开成层级行。
  ///
  /// 数量口径（与服务端三条下达路径的上限口径对齐）：
  /// - 毛需求 = 本批数量 × 本节点单位耗用 ÷ 驱动件单位耗用
  ///   （`perProductQty` 是「每 1 个来源单位产品」的累计耗用，见
  ///   MaterialAnalysisBomSnapshotReader 的 BOM 递归 CTE）。
  /// - 建议下单 = 可下达余量（服务端口径：本批缺口 − 已在途）
  ///   + max(0, 毛需求 − 快照需求)。
  ///
  /// 第二项就是**超量下达多出来的那部分**：ADR-070 §2.7 / V577 下，超产
  /// 不会自动抬高下层需求（锚点行不展开自己的 BOM、父件计划产出按物理
  /// 缺口封顶），所以快照里根本没有这段需求，只能在这里按 BOM 算出来补。
  /// 没有超量时第二项为 0，建议值与各桶的默认下达量完全一致。
  List<_ChildCascadeRow> _buildChildCascadeRows(List<_ChildCascadeSeed> seeds) {
    final analysis = _analysis;
    if (analysis == null || seeds.isEmpty) return const [];
    final presentation = _bomPresentation(analysis);
    final indexes = _analysisIndexes(analysis);
    final childrenByParent =
        <String?, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in analysis.materials) {
      if (material.isRootSupply) continue;
      childrenByParent
          .putIfAbsent(
            presentation.parentIdsByMaterial[material.materialLineId],
            () => [],
          )
          .add(material);
    }
    for (final children in childrenByParent.values) {
      children.sort(
        (left, right) => (left.nodeKey ?? '').compareTo(right.nodeKey ?? ''),
      );
    }
    // 本批一起下达的行互为「已安排」：下达 P 又下达它的自制子件 C 时，C 以下
    // 的料由 C 自己的数量驱动，不能再被 P 的数量重复展开一遍。
    final anchors = <String, ({String? parentId, double divisor})>{};
    final seedByAnchor = <String, _ChildCascadeSeed>{};
    for (final seed in seeds) {
      final resolved = _resolveCascadeAnchor(seed, analysis, indexes);
      if (resolved == null) continue;
      anchors[resolved.key] = (
        parentId: resolved.parentId,
        divisor: resolved.divisor,
      );
      seedByAnchor[resolved.key] = seed;
    }
    final seedAnchorMaterialIds = {
      for (final entry in anchors.entries)
        if (entry.value.parentId != null) entry.value.parentId!,
    };
    final nodes = <_CascadeNode>[];
    final visited = <String>{};
    var truncated = false;

    void walk({
      required String? parentId,
      required String? parentMaterialLineId,
      required double parentPerProduct,
      required double driverQty,
      required int depth,
      required String seedLabel,
      required String? scopeAnalysisLineId,
    }) {
      if (depth > 10 || truncated) return;
      final children = childrenByParent[parentId] ?? const [];
      for (final child in children) {
        if (nodes.length >= _cascadeRowLimit) {
          truncated = true;
          return;
        }
        // 旧载荷没有 ROOT_SUPPLY 行时按 parent=null 聚齐了所有产品的直接层，
        // 必须再按分析行过滤，否则会把别的产品的料算进来。
        if (parentId == null &&
            scopeAnalysisLineId != null &&
            child.analysisLineId != scopeAnalysisLineId) {
          continue;
        }
        // SHIP / REFERENCE 不写正式生产需求（ADR-029 §4.1），不在办齐范围。
        if (_isNonProductionStage(child.controlStage)) continue;
        // 本批已经单独下达的行：它的子树由它自己那条种子驱动。
        if (seedAnchorMaterialIds.contains(child.materialLineId)) continue;
        if (!visited.add(child.materialLineId)) continue;
        final rate = parentPerProduct <= 0 || child.perProductQty <= 0
            ? null
            : child.perProductQty / parentPerProduct;
        // 缺单位耗用的历史行不硬凑比例：退回快照需求，界面标明未按本批放大。
        final grossNeed = rate == null ? child.requiredQty : driverQty * rate;
        nodes.add((
          material: child,
          depth: depth,
          seedLabel: seedLabel,
          parentMaterialLineId: parentMaterialLineId,
          parentPerProduct: parentPerProduct,
          grossNeed: grossNeed,
          isSeed: false,
        ));
        final group = indexes.groupsByLine[child.materialLineId];
        final route = group == null ? null : _draftRoute(group);
        final descend =
            route == MaterialSupplyRoute.make ||
            (route == MaterialSupplyRoute.subcontract &&
                _hasProductionBomChildren(child, analysis));
        if (!descend) continue;
        walk(
          parentId: child.materialLineId,
          parentMaterialLineId: child.materialLineId,
          parentPerProduct: child.perProductQty,
          driverQty: grossNeed,
          depth: depth + 1,
          seedLabel: seedLabel,
          scopeAnalysisLineId: scopeAnalysisLineId,
        );
      }
    }

    final byLine = {
      for (final material in analysis.materials)
        material.materialLineId: material,
    };
    for (final entry in anchors.entries) {
      final seed = seedByAnchor[entry.key]!;
      final before = nodes.length;
      // 树顶先占一行：刚下达的那个件本身（用户口径「最上面就是点击下达车间的，
      // 下面是子层级、孙层级」）。它只读，本批数量就是下层的驱动量。
      final anchorMaterial = byLine[entry.value.parentId];
      if (anchorMaterial != null) {
        nodes.add((
          material: anchorMaterial,
          depth: 0,
          seedLabel: seed.label,
          parentMaterialLineId: null,
          parentPerProduct: entry.value.divisor,
          grossNeed: seed.batchQty,
          isSeed: true,
        ));
      }
      walk(
        parentId: entry.value.parentId,
        parentMaterialLineId: entry.value.parentId,
        parentPerProduct: entry.value.divisor,
        driverQty: seed.batchQty,
        depth: 1,
        seedLabel: seed.label,
        scopeAnalysisLineId: entry.value.parentId == null
            ? seed.analysisLineId
            : null,
      );
      // 这条种子一个下层都没展开出来：树顶那行独自留着只是噪音。
      if (anchorMaterial != null && nodes.length == before + 1) {
        nodes.removeLast();
      }
    }
    if (nodes.every((node) => node.isSeed)) return const [];
    if (nodes.isEmpty) return const [];
    return _materializeCascadeRows(nodes, analysis, indexes);
  }

  /// 种子 → 展开起点。返回子树父节点（null = 顶层产品且无根供给行）与
  /// 单位耗用除数（顶层产品 = 1，因为 `perProductQty` 本就是「每来源单位」）。
  ({String key, String? parentId, double divisor})? _resolveCascadeAnchor(
    _ChildCascadeSeed seed,
    ProductionMaterialAnalysisView analysis,
    _MaterialAnalysisIndexes indexes,
  ) {
    final materialLineId = seed.materialLineId;
    if (materialLineId != null) {
      final anchor = analysis.materials
          .where((material) => material.materialLineId == materialLineId)
          .firstOrNull;
      if (anchor == null) return null;
      return (
        key: 'MATERIAL|$materialLineId',
        parentId: anchor.materialLineId,
        divisor: anchor.perProductQty,
      );
    }
    final analysisLineId = seed.analysisLineId;
    final product = analysisLineId == null
        ? null
        : indexes.productsById[analysisLineId];
    if (product == null) return null;
    if (_isEmbeddedMakeChildProduct(product)) {
      // 锚点子件不展开自己的 BOM（ADR-071 §四）：它的料仍留在原树的来源
      // 节点下，展开起点必须回到那个节点。
      final origin = analysis.materials
          .where(
            (material) =>
                material.planAnchorAnalysisLineId == product.analysisLineId,
          )
          .firstOrNull;
      if (origin == null) return null;
      return (
        key: 'PRODUCT|$analysisLineId',
        parentId: origin.materialLineId,
        divisor: origin.perProductQty,
      );
    }
    final root = _rootSupplyMaterialOf(product);
    return (
      key: 'PRODUCT|$analysisLineId',
      parentId: root?.materialLineId,
      divisor: 1,
    );
  }

  /// 展开结果 → 可提交行：同一提交单元（actionGroupKey）合并到第一处，
  /// 其余保留为层级上下文；数量按服务端口径算建议值并标注阻断原因。
  List<_ChildCascadeRow> _materializeCascadeRows(
    List<_CascadeNode> nodes,
    ProductionMaterialAnalysisView analysis,
    _MaterialAnalysisIndexes indexes,
  ) {
    final pathsBySubmitKey =
        <String, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in analysis.materials) {
      final key = material.actionGroupKey ?? material.materialLineId;
      pathsBySubmitKey.putIfAbsent(key, () => []).add(material);
    }
    final ownerIndex = <String, int>{};
    final gross = <String, double>{};
    final snapshot = <String, double>{};
    final mergedCount = <String, int>{};
    for (var index = 0; index < nodes.length; index++) {
      // 树顶只读行不参与提交单元合并：它是刚下达的件本身，不在这里下单。
      if (nodes[index].isSeed) continue;
      final key =
          nodes[index].material.actionGroupKey ??
          nodes[index].material.materialLineId;
      ownerIndex.putIfAbsent(key, () => index);
      gross[key] = (gross[key] ?? 0) + nodes[index].grossNeed;
      snapshot[key] = (snapshot[key] ?? 0) + nodes[index].material.requiredQty;
      mergedCount[key] = (mergedCount[key] ?? 0) + 1;
    }
    final rows = <_ChildCascadeRow>[];
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final material = node.material;
      final submitKey = material.actionGroupKey ?? material.materialLineId;
      final group = indexes.groupsByLine[material.materialLineId];
      final ownsInput = ownerIndex[submitKey] == index;
      final route = group == null
          ? MaterialSupplyRoute.subcontract
          : _draftRoute(group);
      final kind = _cascadeKindOf(material, route, analysis);
      final submitGroup = group == null
          ? null
          : _MaterialGroup(
              key: group.key,
              paths: pathsBySubmitKey[submitKey] ?? group.paths,
            );
      final residual = submitGroup == null
          ? 0.0
          : _residualSubmitQty(submitGroup, route);
      final grossNeed = ownsInput ? (gross[submitKey] ?? 0) : node.grossNeed;
      final snapshotNeed = ownsInput
          ? (snapshot[submitKey] ?? 0)
          : material.requiredQty;
      final overspill = grossNeed - snapshotNeed > 0.0001
          ? grossNeed - snapshotNeed
          : 0.0;
      final allowOver =
          kind == _CascadeKind.workshop ||
          (_canOverSupply &&
              (kind == _CascadeKind.buy ||
                  kind == _CascadeKind.subcontractLeaf));
      final overCapped = overspill > 0.0001 && !allowOver;
      final suggested = residual + (allowOver ? overspill : 0);
      rows.add(
        _ChildCascadeRow(
          material: material,
          groupKey: group?.key ?? 'NONE|${material.materialLineId}',
          submitKey: submitKey,
          depth: node.depth,
          seedLabel: node.seedLabel,
          route: route,
          kind: kind,
          parentMaterialLineId: node.parentMaterialLineId,
          parentPerProduct: node.parentPerProduct,
          grossNeed: grossNeed,
          snapshotNeed: snapshotNeed,
          residual: residual,
          overspill: overspill,
          suggested: suggested,
          ownsInput: ownsInput,
          mergedPathCount: ownsInput ? (mergedCount[submitKey] ?? 1) : 1,
          overCapped: overCapped,
          isSeed: node.isSeed,
          blockedReason: ownsInput
              ? _cascadeBlockedReason(material, group, route, kind)
              : null,
        ),
      );
    }
    return rows;
  }

  _CascadeKind _cascadeKindOf(
    ProductionMaterialAnalysisMaterial material,
    MaterialSupplyRoute route,
    ProductionMaterialAnalysisView analysis,
  ) => switch (route) {
    MaterialSupplyRoute.buy => _CascadeKind.buy,
    MaterialSupplyRoute.make => _CascadeKind.workshop,
    MaterialSupplyRoute.subcontract =>
      _hasProductionBomChildren(material, analysis)
          ? _CascadeKind.workshop
          : _CascadeKind.subcontractLeaf,
  };

  /// 本行为什么不能在这里下达。fail-closed：说不清就不放行，让人回主表处理。
  String? _cascadeBlockedReason(
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup? group,
    MaterialSupplyRoute route,
    _CascadeKind kind,
  ) {
    if (group == null) return '本行来源无法解析，请回主表核对';
    final planningBlock = _planningBlockForGroup(group);
    if (planningBlock != null) return planningBlock;
    if (!_hasResolvedMaterialSource(material)) return '本行来源无法解析，请回主表核对';
    if (material.confirmedRoute == null) {
      if (!_canRoute) return '没有确认物料路线权限';
      if (!_canEditMaterialRoute(group)) return '本行已有下游行动，路线不可改，请回主表核对';
      // 主档来源为空时 _draftRoute 只能兜底委外——那是缺省值不是决定
      // （生产物料分析页 §3.4），不允许在这里替人确认。
      if (material.sourceSuggestion == null &&
          _rememberedRouteForGoods(
                material.goodsId,
                material.colorId,
                material.unitId,
              ) ==
              null) {
        return '主档来源为空，请先在主表确认路线';
      }
    }
    if (kind == _CascadeKind.workshop && !_canGenerate) {
      return '没有生成生产计划权限';
    }
    if (kind != _CascadeKind.workshop && !_canNotify) {
      return '没有下达采购/委外权限';
    }
    if (kind != _CascadeKind.workshop &&
        _routeBlockedBySafetyGap(group, route)) {
      return '存在公共安全补库缺口，仅采购路线可下达';
    }
    return null;
  }

  // ===== 二、入口：先弹窗（弹窗前置），一键下单里再提交父件 =====

  /// 预构建下层办齐行：无可勾选行返回 null（调用方走原路直接提交，不打扰）。
  /// 「有没有被下单」由服务端口径的可下达余量决定，不靠界面猜。
  @override
  List<_ChildCascadeRow>? _pendingChildCascadeRows(
    List<_ChildCascadeSeed> seeds,
  ) {
    if (!mounted || seeds.isEmpty) return null;
    if (!_canNotify && !_canGenerate) return null;
    final rows = _buildChildCascadeRows(seeds);
    if (rows.where((row) => row.selectable).isEmpty) {
      for (final row in rows) {
        row.dispose();
      }
      return null;
    }
    return rows;
  }

  /// 进入「父件 + 下层一起下单」整页（2026-09-14 修订：**不再弹窗**——用户口径
  /// 「不要弹窗了直接去新的页面，弹窗看的东西太少」；提交前置——先让用户在
  /// 页面里看清下层并核对数量，点「一键下单」才按序提交父件与下层，不再先把
  /// 父件落库再补问）。[parentAction] = 父件提交段（null = 重试模式，父件已
  /// 提交过）。返回 true = 全部段成功。
  @override
  Future<bool> _showChildCascadeDialog({
    required List<_ChildCascadeSeed> seeds,
    required List<_ChildCascadeRow> initialRows,
    Future<bool> Function()? parentAction,
  }) async {
    if (!mounted) return false;
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ChildCascadePage(
          host: this,
          seeds: seeds,
          initialRows: initialRows,
          parentAction: parentAction,
        ),
      ),
    );
    return done == true;
  }

  // ===== 三、一键下单：父件 → 路线确认 → 并入申请 → 采购 → 委外 → 车间 =====

  /// 按路线分流依次下达。**不是一个事务**：逐段调用既有的下达链路，
  /// 每段自带幂等键、CAS 与 409 恢复；任一段失败即停下并如实回报，
  /// 已成功的段保留在服务端（重试按幂等键回放，不会重复建单）。
  ///
  /// [parentAction] = 父件提交段（弹窗前置模式）：先提交用户在分桶页填好的
  /// 父件本身，成功后经 [rebuildAfterParent] 按最新快照重建下层行并继承已填
  /// 数量——父件提交会让分析快照整体换一份（锚点/缺口/在途重算），提交前
  /// 抓到的行对象立刻过期；被父件顺带办妥的行（如委外前置自制任务接手的
  /// 子件）会自然变成「已下达」，从后续段里退出并如实回报。
  Future<List<_CascadeStepResult>> _executeChildCascade(
    List<_ChildCascadeRow> rows, {
    Future<bool> Function()? parentAction,
    List<_ChildCascadeRow> Function()? rebuildAfterParent,
    int parentCount = 1,
  }) async {
    final results = <_CascadeStepResult>[];
    if (rows.isEmpty) return results;
    // 0) 父件段：先把本次下达的父件提交了，下层才有「按本批数量」的权威驱动量。
    if (parentAction != null) {
      final ok = await parentAction();
      if (!mounted) return results;
      results.add((
        label: '父件下达',
        count: ok ? parentCount : 0,
        ok: ok,
        note: ok ? null : '父件未提交成功，下层未动，可直接重试',
      ));
      if (!ok) return results;
      if (rebuildAfterParent != null) {
        final beforeKeys = {for (final row in rows) row.submitKey};
        rows = rebuildAfterParent();
        final afterKeys = {for (final row in rows) row.submitKey};
        final covered = beforeKeys.difference(afterKeys).length;
        if (covered > 0) {
          results.add((
            label: '已随父件下达办妥',
            count: covered,
            ok: true,
            note: null,
          ));
        }
        if (rows.isEmpty) return results;
      }
    }
    // 1) 先确认路线：三条下达链路都以「已确认路线」为硬门槛（ADR-029 §6.1）。
    final needRoute = [
      for (final row in rows)
        if (_analysisGroupOf(row.groupKey)?.representative.confirmedRoute !=
            row.route)
          row,
    ];
    if (needRoute.isNotEmpty) {
      if (!_canRoute) {
        results.add((
          label: '确认物料路线',
          count: needRoute.length,
          ok: false,
          note: '没有确认物料路线权限',
        ));
        return results;
      }
      setState(() {
        for (final row in needRoute) {
          _routeDraft[row.groupKey] = row.route;
          _dirtyRouteGroups.add(row.groupKey);
        }
        _invalidateBucketRowsCache();
      });
      await _saveRoutes(
        onlyGroupKeys: {for (final row in needRoute) row.groupKey},
      );
      if (!mounted) return results;
      final stillPending = [
        for (final row in needRoute)
          if (_analysisGroupOf(row.groupKey)?.representative.confirmedRoute !=
              row.route)
            row,
      ];
      results.add((
        label: '确认物料路线',
        count: needRoute.length - stillPending.length,
        ok: stillPending.isEmpty,
        note: stillPending.isEmpty
            ? null
            : '${stillPending.length} 条未确认，已停止后续下达',
      ));
      if (stillPending.isNotEmpty) return results;
    }
    // 2) 并入已有申请：基础需求已生成采购申请且尚未分解出订货单的行，直接把
    //    追加量写进同一张申请（V477 sanctioned 入口，权限与守卫由该端点自裁）。
    final adjustBatch = rows
        .where((row) => row.adjustIntoRequest)
        .toList(growable: false);
    if (adjustBatch.isNotEmpty) {
      var okCount = 0;
      String? failNote;
      for (final row in adjustBatch) {
        final link = row.supplyLink!;
        final name = row.material.goodsName ?? row.material.goodsCode ?? row.id;
        try {
          await ref
              .read(purchaseRepositoryProvider(PurchaseDocType.request))
              .adjustRequestItemQty(
                requestId: link.documentId,
                itemId: link.documentItemId!,
                qty: link.itemQty + row.enteredQty,
              );
          okCount++;
        } catch (error) {
          failNote =
              '「$name」'
              '${productionErrorMessage(error, fallback: '申请数量修改失败')}';
          break;
        }
      }
      results.add((
        label: '并入已有采购申请',
        count: okCount,
        ok: failNote == null,
        note: failNote,
      ));
      if (failNote != null) return results;
    }
    // 3) 采购 4) 无子层委外：行内数量交给既有的裁决/分批/幂等链路。
    //    「已分解出订货单」的追加行也走这里（notify 超量通道另立追加申请）。
    for (final kind in [_CascadeKind.buy, _CascadeKind.subcontractLeaf]) {
      final batch = rows
          .where((row) => row.kind == kind && !row.adjustIntoRequest)
          .toList(growable: false);
      if (batch.isEmpty) continue;
      final route = kind == _CascadeKind.buy
          ? MaterialSupplyRoute.buy
          : MaterialSupplyRoute.subcontract;
      final view = await _notifyRoute(
        route,
        onlyGroupKeys: {for (final row in batch) row.groupKey},
        qtyByActionGroupKey: {
          for (final row in batch)
            if (row.material.actionGroupKey != null)
              row.material.actionGroupKey!: row.qty.text.trim(),
        },
        silent: true,
      );
      if (!mounted) return results;
      results.add((
        label: kind == _CascadeKind.buy ? '下达采购' : '下达委外',
        count: view == null ? 0 : batch.length,
        ok: view != null,
        note: view == null ? '本段未提交，后续下达已停止' : null,
      ));
      if (view == null) return results;
    }
    // 5) 车间：自制 + 有子层委外一次原子调用（服务端建锚点 + 出计划同事务）。
    final workshop = rows
        .where((row) => row.kind == _CascadeKind.workshop)
        .toList(growable: false);
    if (workshop.isNotEmpty) {
      final ok = await _issueWorkshopPlans(
        candidateInputs: [
          for (final row in workshop)
            _BucketCandidatePlanInput(
              materialLineId: row.material.materialLineId,
              qty: row.enteredQty,
              departmentId: row.departmentId.value,
              workshopName: row.departmentName,
              workerId: row.workerId.value,
            ),
        ],
        silent: true,
      );
      if (!mounted) return results;
      results.add((
        label: '下达车间',
        count: ok ? workshop.length : 0,
        ok: ok,
        note: ok ? null : '生产计划未生成，整批已回滚',
      ));
    }
    return results;
  }

  _MaterialGroup? _analysisGroupOf(String groupKey) {
    final analysis = _analysis;
    if (analysis == null) return null;
    for (final group in _materialGroups(analysis)) {
      if (group.key == groupKey) return group;
    }
    return null;
  }
}

/// 父件 + 下层一起下单**整页**（2026-09-14 用户口径「不要弹窗了直接去新的页面，
/// 弹窗看的东西太少」）：与物料分析准备页同款的树表格（展开 / 收缩 + 层级连线，
/// UtenTreeTableCell）+ 一个「一键下单」。[parentAction] 非空 = 前置模式（父件
/// 还没提交，一键下单先提交父件再办下层）；null = 重试模式（父件已提交过）。
class _ChildCascadePage extends StatefulWidget {
  const _ChildCascadePage({
    required this.host,
    required this.seeds,
    required this.initialRows,
    this.parentAction,
  });

  final _MaterialAnalysisChildCascadeState host;
  final List<_ChildCascadeSeed> seeds;
  final List<_ChildCascadeRow> initialRows;
  final Future<bool> Function()? parentAction;

  @override
  State<_ChildCascadePage> createState() => _ChildCascadePageState();
}

/// 一行的树结构投影（由扁平 DFS 行序推导）：有没有下层 / 直接子数 /
/// 各层祖先是否还有后续兄弟（连线断 / 连）/ 是不是本层最后一个。
class _CascadeTreeInfo {
  const _CascadeTreeInfo({
    required this.hasChildren,
    required this.childCount,
    required this.ancestorContinuations,
    required this.isLastChild,
  });

  final bool hasChildren;
  final int childCount;
  final List<bool> ancestorContinuations;
  final bool isLastChild;
}

class _ChildCascadePageState extends State<_ChildCascadePage> {
  final UtenEditableGridController<_ChildCascadeRow> _grid =
      UtenEditableGridController<_ChildCascadeRow>();

  /// 全量行（含被折叠隐藏的）：行对象与输入控制器归本页所有，折叠只换
  /// 可见子集（swapRows 不 dispose），展开原样放回，已填内容不丢。
  List<_ChildCascadeRow> _allRows = const [];
  Map<_ChildCascadeRow, _CascadeTreeInfo> _treeInfo = const {};
  final Set<String> _collapsedBranches = {};
  bool _running = false;
  List<_CascadeStepResult> _lastRun = const [];

  /// 前置模式下父件是否已提交成功：失败重试时不再重发父件段——
  /// 首次提交后分析快照已换版本，重发会生成新幂等键，等于真实重复下单。
  bool _parentSubmitted = false;

  Map<
    String,
    ({
      String departmentId,
      String? departmentName,
      String? workerId,
      String? workerName,
    })
  >
  _workshopDefaults = const {};
  Map<String, ({String? id, String? name})> _workshopManagers = const {};

  _MaterialAnalysisChildCascadeState get _host => widget.host;

  @override
  void initState() {
    super.initState();
    _installRows(widget.initialRows);
    unawaited(_loadWorkshopDefaults());
    unawaited(_loadSupplyLinks());
  }

  @override
  void dispose() {
    // _grid.dispose 会销毁它手里的可见行；被折叠隐藏的行不在其中，这里补上
    // （同一行对象不能重复 dispose）。
    final visible = _grid.rows.toSet();
    for (final row in _allRows) {
      if (!visible.contains(row)) row.dispose();
    }
    _grid.dispose();
    super.dispose();
  }

  /// 只为「基础需求已覆盖、本批超产又有新量」的行拉一次下游申请联动：
  /// 申请未分解 → 并入申请调量；已分解 → 追加另立。加载失败不阻断（按无
  /// 联动的普通超量口径展示，用户仍可回对应桶处理）。
  Future<void> _loadSupplyLinks() async {
    final analysis = _host._analysis;
    final lineIds = <String>{
      for (final row in _allRows)
        if (row.ownsInput &&
            !row.isSeed &&
            (row.kind == _CascadeKind.buy ||
                row.kind == _CascadeKind.subcontractLeaf) &&
            row.residual <= 0.0001 &&
            row.overspill > 0.0001)
          row.id,
    };
    if (analysis == null || lineIds.isEmpty) return;
    final links = await _host.ref
        .read(productionPlanRepositoryProvider)
        .materialAnalysisSupplyLinks(analysis.analysisId, lineIds)
        .catchError((_) => const <MaterialAnalysisSupplyLink>[]);
    if (!mounted) return;
    final byLine = {for (final link in links) link.materialLineId: link};
    setState(() {
      for (final row in _allRows) {
        final link = byLine[row.id];
        if (link == null) continue;
        row.supplyLink = link;
        // 无超量权限时建议量为 0，但并入申请走采购侧端点，照填追加量。
        if (row.adjustIntoRequest &&
            !row.qtyTouched &&
            (double.tryParse(row.qty.text.trim()) ?? 0) <= 0) {
          row.qty.text = _bucketQtyText(row.overspill);
        }
      }
    });
  }

  /// [selectedKeys] 非空 = 只勾选这些提交单元（父件提交后重建：继承用户原来
  /// 勾的行，新出现的行不自动勾）；空 = 全部可选行勾上（页面首次打开）。
  /// 重建才走 dispose（旧行作废）；折叠 / 展开只换可见子集（swapRows）。
  void _installRows(List<_ChildCascadeRow> rows, {Set<String>? selectedKeys}) {
    for (final row in _allRows) {
      row.dispose();
    }
    _allRows = List.unmodifiable(rows);
    _computeTreeInfo();
    _grid.swapRows(_visibleRows());
    for (final row in _allRows) {
      if (!row.ownsInput) continue;
      row.qty.addListener(() => _onQtyChanged(row));
      if (row.selectable &&
          (selectedKeys == null || selectedKeys.contains(row.submitKey))) {
        _grid.setSelected([row], true);
      }
    }
  }

  /// 由扁平 DFS 行序推导每行的树结构投影（子树范围 / 连线 / 末位标记）。
  void _computeTreeInfo() {
    final rows = _allRows;
    final n = rows.length;
    final childCountOf = List<int>.filled(n, 0);
    final hasNextSibling = List<bool>.filled(n, false);
    for (var i = 0; i < n; i++) {
      var j = i + 1;
      var children = 0;
      while (j < n && rows[j].depth > rows[i].depth) {
        if (rows[j].depth == rows[i].depth + 1) children++;
        j++;
      }
      childCountOf[i] = children;
      hasNextSibling[i] = j < n && rows[j].depth == rows[i].depth;
    }
    final info = <_ChildCascadeRow, _CascadeTreeInfo>{};
    for (var i = 0; i < n; i++) {
      final depth = rows[i].depth;
      List<bool> continuations;
      if (depth == 0) {
        continuations = const [];
      } else {
        var p = i - 1;
        while (p >= 0 && rows[p].depth >= depth) {
          p--;
        }
        if (p < 0 || rows[p].depth != depth - 1) {
          continuations = List<bool>.filled(depth, false);
        } else {
          continuations = [
            ...?info[rows[p]]?.ancestorContinuations,
            hasNextSibling[p],
          ];
        }
      }
      info[rows[i]] = _CascadeTreeInfo(
        hasChildren: childCountOf[i] > 0,
        childCount: childCountOf[i],
        ancestorContinuations: continuations,
        isLastChild: !hasNextSibling[i],
      );
    }
    _treeInfo = info;
  }

  /// 折叠状态下的可见子集：被折叠行后面的更深行整段隐藏（多级嵌套折叠天然
  /// 成立——外层先截断，内层自然不可见）。
  List<_ChildCascadeRow> _visibleRows() {
    if (_collapsedBranches.isEmpty) return _allRows;
    final visible = <_ChildCascadeRow>[];
    var hideDepth = -1;
    for (final row in _allRows) {
      if (hideDepth >= 0) {
        if (row.depth > hideDepth) continue;
        hideDepth = -1;
      }
      visible.add(row);
      if (_collapsedBranches.contains(row.id)) hideDepth = row.depth;
    }
    return visible;
  }

  /// 展开 / 收起一个分支：只换可见子集，行对象与已填内容不动；折叠时把
  /// 隐藏行的勾选一并撤掉——「看到的勾选 = 提交的内容」。
  void _toggleBranch(_ChildCascadeRow row) {
    final index = _allRows.indexOf(row);
    if (index < 0) return;
    final hidden = <_ChildCascadeRow>[];
    for (var i = index + 1; i < _allRows.length; i++) {
      if (_allRows[i].depth <= row.depth) break;
      hidden.add(_allRows[i]);
    }
    setState(() {
      if (!_collapsedBranches.add(row.id)) {
        _collapsedBranches.remove(row.id);
      } else if (hidden.isNotEmpty) {
        _grid.setSelected(hidden, false);
      }
      _grid.swapRows(_visibleRows());
    });
  }

  /// 父件提交成功后按最新快照重建行，并继承用户已填的数量 / 车间 / 负责人 /
  /// 勾选与申请联动。重建会 dispose 旧行，旧控制器的值必须先抓下来。
  /// 返回重建后仍可下达且原本勾选的行（被父件顺带办妥的行自然退出）。
  List<_ChildCascadeRow> _rebuildAfterParent(Set<String> selectedKeys) {
    final carried =
        <
          String,
          ({
            String? qtyText,
            String? departmentId,
            String? departmentName,
            String? workerId,
            String? workerName,
            MaterialAnalysisSupplyLink? supplyLink,
          })
        >{};
    for (final row in _allRows) {
      carried[row.submitKey] = (
        qtyText: row.qtyTouched ? row.qty.text : null,
        departmentId: row.departmentId.value,
        departmentName: row.departmentName,
        workerId: row.workerId.value,
        workerName: row.workerName,
        supplyLink: row.supplyLink,
      );
    }
    final fresh = _host._buildChildCascadeRows(widget.seeds);
    for (final row in fresh) {
      final old = carried[row.submitKey];
      if (old == null) continue;
      row.supplyLink = old.supplyLink;
      final carriedQty = double.tryParse(old.qtyText?.trim() ?? '');
      if (carriedQty != null && carriedQty > 0) {
        row.qty.text = old.qtyText!.trim();
        row.qtyTouched = true;
      }
      if (old.departmentId != null) {
        row.departmentId.value = old.departmentId;
        row.departmentName = old.departmentName;
        row.workerId.value = old.workerId;
        row.workerName = old.workerName;
      }
    }
    _installRows(fresh, selectedKeys: selectedKeys);
    unawaited(_loadWorkshopDefaults());
    return [
      for (final row in fresh)
        if (selectedKeys.contains(row.submitKey) && row.selectable) row,
    ];
  }

  /// 改了上层数量 → 下层跟着重算（用户没手工改过的行才覆盖）。
  void _onQtyChanged(_ChildCascadeRow row) {
    if (!row.needsWorkshop || !row.qtyTouched) return;
    _refillDescendants(row, row.enteredQty);
  }

  void _refillDescendants(_ChildCascadeRow driver, double driverQty) {
    if (driver.perProductQty <= 0) return;
    final children = _allRows.where(
      (row) => row.parentMaterialLineId == driver.id && row.ownsInput,
    );
    for (final child in children) {
      if (child.perProductQty > 0) {
        final gross = driverQty * child.perProductQty / driver.perProductQty;
        child.grossNeed = gross;
        child.overspill = gross - child.snapshotNeed > 0.0001
            ? gross - child.snapshotNeed
            : 0;
        // 与建表时同一口径：车间去向按 V577 可超量、采购/无子层委外要
        // over_supply 权限（见 _materializeCascadeRows）。
        final allowOver =
            child.kind == _CascadeKind.workshop || _host._canOverSupply;
        child.overCapped = child.overspill > 0.0001 && !allowOver;
        child.suggested = child.residual + (allowOver ? child.overspill : 0);
        if (!child.qtyTouched) {
          child.qty.text = child.suggested > 0
              ? _bucketQtyText(child.suggested)
              : '';
        }
      }
      if (child.needsWorkshop) {
        _refillDescendants(child, child.enteredQty);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadWorkshopDefaults() async {
    final goodsIds = <String>{
      for (final row in _allRows)
        if (row.needsWorkshop && (row.goodsId?.isNotEmpty ?? false))
          row.goodsId!,
    };
    if (goodsIds.isEmpty) return;
    final results = await Future.wait([
      _host.ref
          .read(productionPlanRepositoryProvider)
          .defaultWorkshops(goodsIds)
          .catchError(
            (_) =>
                const <
                  String,
                  ({
                    String departmentId,
                    String? departmentName,
                    String? workerId,
                    String? workerName,
                  })
                >{},
          ),
      _workshopTreeOrNull(),
    ]);
    if (!mounted) return;
    _workshopDefaults =
        results[0]
            as Map<
              String,
              ({
                String departmentId,
                String? departmentName,
                String? workerId,
                String? workerName,
              })
            >;
    final tree = results[1] as List<DepartmentNode>;
    _workshopManagers = {
      for (final node in tree)
        if (node.managerId?.isNotEmpty == true)
          node.id: (id: node.managerId, name: node.managerName),
    };
    for (final row in _allRows) {
      if (!row.needsWorkshop || row.departmentId.value != null) continue;
      final learned = _workshopDefaults[row.goodsId];
      if (learned == null) continue;
      row.departmentId.value = learned.departmentId;
      row.departmentName = learned.departmentName;
      row.workshopAutofilled = true;
      final manager = _workshopManagers[learned.departmentId];
      row.workerId.value = learned.workerId ?? manager?.id;
      row.workerName = learned.workerName ?? manager?.name;
      row.workerAutofilled = row.workerId.value != null;
    }
    setState(() {});
  }

  Future<List<DepartmentNode>> _workshopTreeOrNull() async {
    try {
      final tree = await _host.ref.read(departmentRepositoryProvider).tree();
      return findDepartmentByCode(tree, kDeptCodeProduction)?.children ??
          const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _pickWorkshop(_ChildCascadeRow row) async {
    final tree = await _workshopTreeOrNull();
    if (!mounted) return;
    final workshopIds = {for (final node in tree) node.id};
    final picked = await showUtenDepartmentPickerPanel(
      context,
      tree: tree,
      selectablePredicate: (node) => workshopIds.contains(node.id),
      initialSelection: row.departmentId.value == null
          ? const []
          : [
              DeptSelection(
                id: row.departmentId.value!,
                name: row.departmentName ?? '',
                fullPath: '',
                level: '',
              ),
            ],
    );
    final selection = picked == null || picked.isEmpty ? null : picked.first;
    if (selection == null || !mounted) return;
    setState(() {
      if (row.departmentId.value != selection.id) {
        final learned = _workshopDefaults[row.goodsId];
        final remembered =
            learned != null &&
                learned.departmentId == selection.id &&
                learned.workerId != null
            ? (id: learned.workerId, name: learned.workerName)
            : null;
        final manager = remembered ?? _workshopManagers[selection.id];
        row.workerId.value = manager?.id;
        row.workerName = manager?.name;
        row.workerAutofilled = manager != null;
      }
      row.departmentId.value = selection.id;
      row.departmentName = selection.name;
      row.workshopAutofilled = false;
    });
  }

  Future<void> _pickWorker(_ChildCascadeRow row) async {
    final picked = await showUtenEmployeePickerPanel(
      context,
      title: '选择生产负责人',
      selectedId: row.workerId.value,
      departmentName: row.departmentName,
      loader: (keyword) async {
        final result = await _host.ref
            .read(employeeRepositoryProvider)
            .list(
              size: 30,
              search: keyword,
              departmentId: (keyword?.trim().isEmpty ?? true)
                  ? row.departmentId.value
                  : null,
              includeSubtree: true,
            );
        return [
          for (final employee in result.items)
            UtenEmployeePickerItem(
              id: employee.id,
              name: employee.fullName,
              employeeCode: employee.code,
              departmentName: employee.departmentName,
            ),
        ];
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      row.workerId.value = picked.id;
      row.workerName = picked.name;
      row.workerAutofilled = false;
    });
  }

  // ===== 提交 =====

  String? _validate(List<_ChildCascadeRow> rows) {
    final badQty = <String>[];
    final overQty = <String>[];
    final noWorkshop = <String>[];
    final noWorker = <String>[];
    for (final row in rows) {
      final name = _rowName(row);
      final qty = double.tryParse(row.qty.text.trim());
      if (qty == null || !qty.isFinite || qty <= 0) {
        badQty.add('「$name」');
        continue;
      }
      // 并入已有申请：追加量 > 0 即可，权限与守卫由采购侧 V477 端点自裁。
      if (row.adjustIntoRequest) continue;
      // 采购/无子层委外超过「本批缺口 − 已在途」要走公共超量通道；没有
      // 超量下达权限时服务端会拒，这里先点名，不静默改小。
      if (row.kind != _CascadeKind.workshop &&
          !_host._canOverSupply &&
          qty > row.residual + 0.0001) {
        overQty.add(
          row.appendToOrdered
              ? '「$name」已下过单，追加 ${_host._qty(qty)} 需要超量下达权限'
              : '「$name」本次 ${_host._qty(qty)} / 可下达 ${_host._qty(row.residual)}',
        );
        continue;
      }
      if (!row.needsWorkshop) continue;
      if (row.departmentId.value?.isNotEmpty != true) {
        noWorkshop.add('「$name」');
        continue;
      }
      if (row.workerId.value?.isNotEmpty != true) noWorker.add('「$name」');
    }
    final problems = <String>[
      if (badQty.isNotEmpty) _issueLine(badQty, '下单数量必须大于 0'),
      if (overQty.isNotEmpty) _issueLine(overQty, '超过可下达量，需要超量下达权限，请改小或找有权限的人'),
      if (noWorkshop.isNotEmpty) _issueLine(noWorkshop, '尚未选择生产车间'),
      if (noWorker.isNotEmpty) _issueLine(noWorker, '尚未选择负责人'),
    ];
    return problems.isEmpty ? null : problems.join('\n');
  }

  String _issueLine(List<String> labels, String issue) {
    const maxShown = 8;
    final shown = labels.take(maxShown).join('、');
    final rest = labels.length - maxShown;
    return '以下 ${labels.length} 行$issue：$shown${rest > 0 ? ' 等 $rest 行' : ''}';
  }

  String _rowName(_ChildCascadeRow row) =>
      row.material.goodsName ?? row.material.goodsCode ?? row.id;

  Future<void> _submit() async {
    if (_running) return;
    final selected = _grid.selectedRows
        .where((row) => row.selectable)
        .toList(growable: false);
    if (selected.isEmpty) {
      context.appInfo('请先勾选要下单的下层物料');
      return;
    }
    final error = _validate(selected);
    if (error != null) {
      context.appError(error);
      return;
    }
    final byKind = <_CascadeKind, int>{};
    for (final row in selected) {
      byKind[row.kind] = (byKind[row.kind] ?? 0) + 1;
    }
    final needRoute = selected
        .where((row) => row.material.confirmedRoute != row.route)
        .length;
    // 已下过单的两类要当面说清去向（用户口径「问是不是追加」）：
    // 并入申请 = 把原申请明细数量改大；追加 = 另立一张申请加量。
    final adjusting = selected
        .where((row) => row.adjustIntoRequest)
        .toList(growable: false);
    final appending = selected
        .where((row) => row.appendToOrdered)
        .toList(growable: false);
    final ok = await UtenDialog.show(
      context,
      title: '确认一键下单下层物料',
      content: Text(
        [
          if (widget.parentAction != null)
            '第一步先提交本次下达的父件（${widget.seeds.length} 行），成功后自动接着办下层。',
          '将按各自路线依次下达 ${selected.length} 行：',
          for (final entry in byKind.entries)
            '· ${entry.key.label}：${entry.value} 行',
          if (adjusting.isNotEmpty)
            '其中 ${adjusting.length} 行基础需求已生成采购申请且尚未分解，'
                '追加量将并入原申请（明细数量直接改大）：\n'
                '${adjusting.map((row) => '· ${_rowName(row)} ${_host._qty(row.supplyLink!.itemQty)} → ${_host._qty(row.supplyLink!.itemQty + row.enteredQty)}').join('\n')}',
          if (appending.isNotEmpty)
            '其中 ${appending.length} 行已下过单，本次按「追加」另立申请：\n'
                '${appending.map((row) => '· ${_rowName(row)} 追加 ${_host._qty(row.enteredQty)}').join('\n')}',
          if (needRoute > 0) '其中 $needRoute 行会先按表内显示的路线确认路线。',
          '',
          '各下达路径各自提交（不是同一个事务）：任一段失败会立即停下并'
              '如实告诉你停在哪一步，已成功的段保留在服务端，重试不会重复建单。',
        ].join('\n'),
      ),
      confirmLabel: '一键下单',
    );
    if (ok != true || !mounted) return;
    setState(() {
      _running = true;
      _lastRun = const [];
    });
    List<_CascadeStepResult> results = const [];
    final selectedKeys = {for (final row in selected) row.submitKey};
    // 父件段只在弹窗前置模式且**尚未提交成功**时执行：失败重试不重发父件
    // （首次提交后快照已换版本，重发=新幂等键=真实重复下单）。
    Future<bool> parentSegment() async {
      final ok = await widget.parentAction!();
      if (ok) _parentSubmitted = true;
      return ok;
    }

    final parentPending = widget.parentAction != null && !_parentSubmitted;
    try {
      results = await _host._executeChildCascade(
        selected,
        parentAction: parentPending ? parentSegment : null,
        rebuildAfterParent: parentPending
            ? () => _rebuildAfterParent(selectedKeys)
            : null,
        parentCount: widget.seeds.length,
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
    if (!mounted) return;
    final allOk = results.isNotEmpty && results.every((step) => step.ok);
    if (allOk) {
      Navigator.of(context).pop(true);
      context.appSuccess(
        '已一起下单：${results.map((step) => '${step.label} ${step.count} 行').join('、')}',
      );
      return;
    }
    // 失败留在弹窗里：按最新快照重算（已成功的行会变成「已下达」），可直接重试。
    setState(() {
      _lastRun = results;
      _installRows(_host._buildChildCascadeRows(widget.seeds));
    });
  }

  // ===== 页面 =====

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const Key('material-analysis-child-cascade-dialog'),
      appBar: UtenAppBar(
        title: widget.parentAction == null ? '下层还没下单，继续办齐' : '下层还没下单，跟父件一起办',
        // 与分桶详情同款：宿主页的命令式子弹层，无独立路由 scope，权限入口
        // 由宿主页承载（非 go_router 页路由不得解析 scope，fail-closed 契约）。
        showPagePermissionAction: false,
        leading: UtenBackButton(
          onPressed: _running ? null : () => Navigator.of(context).pop(false),
        ),
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s8,
              UtenSpacing.s16,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _hintCard(theme),
                if (_lastRun.isNotEmpty) _resultCard(theme),
                const SizedBox(height: UtenSpacing.s8),
                Expanded(
                  child: Padding(
                    // 给右下角悬浮动作组让位（全站统一口径）。
                    padding: const EdgeInsets.only(
                      bottom: UtenFloatingActionGroup.scrollClearance,
                    ),
                    child: _table(theme),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: UtenSpacing.s16,
            bottom: UtenSpacing.s16,
            child: AnimatedBuilder(
              animation: _grid,
              builder: (context, _) {
                final count = _grid.selectedRows
                    .where((row) => row.selectable)
                    .length;
                return UtenFloatingActionGroup(
                  children: [
                    UtenSelectionSummaryPill(
                      count: count,
                      clearKey: const Key(
                        'material-analysis-child-cascade-selected-count',
                      ),
                      onClear: count == 0 || _running
                          ? null
                          : _grid.clearSelection,
                    ),
                    UtenButton(
                      type: UtenButtonType.ghost,
                      onPressed: _running
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('稍后再办'),
                    ),
                    UtenButton(
                      key: const Key('material-analysis-child-cascade-submit'),
                      onPressed: _running || count == 0 ? null : _submit,
                      child: Text(_running ? '正在下达…' : '一键下单($count)'),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _hintCard(ThemeData theme) {
    final seedText = widget.seeds
        .map(
          (seed) =>
              '${seed.label} ${_host._qty(seed.batchQty)}'
              '${seed.unitName?.trim().isNotEmpty == true ? ' ${seed.unitName!.trim()}' : ''}',
        )
        .join('、');
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              widget.parentAction == null
                  ? '刚下达：$seedText。下面按 BOM 自顶向下列出它的子层 / 孙层，'
                        '下单数量已按本批数量算好，可以改；改了上层数量，没手工改过的下层会跟着重算。'
                        '一键下单会按各行路线分流：采购 → 下达采购，无子层委外 → 下达委外，'
                        '自制与有子层委外 → 回到下达车间出计划。'
                  : '本次将下达：$seedText。下面按 BOM 自顶向下列出它的子层 / 孙层，'
                        '下单数量已按本批数量算好，可以改；改了上层数量，没手工改过的下层会跟着重算。'
                        '点「一键下单」会先提交上面的父件，再按各行路线分流：采购 → 下达采购，'
                        '无子层委外 → 下达委外，自制与有子层委外 → 下达车间出计划。'
                        '已下过单的行按申请进度处理：申请未分解的直接并入原申请改大量，'
                        '已分解的按「追加」另立申请。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: UtenSpacing.s8),
    child: Container(
      key: const Key('material-analysis-child-cascade-result'),
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.error),
      ),
      child: Text(
        '上次执行：${_lastRun.map((step) => '${step.label} '
            '${step.ok ? '成功 ${step.count} 行' : '失败（${step.note ?? '未提交'}）'}').join('；')}。'
        '表内数量已按最新快照重算，可直接重试未完成的部分。',
        style: theme.textTheme.bodySmall,
      ),
    ),
  );

  Widget _table(ThemeData theme) => UtenEditableGrid<_ChildCascadeRow>(
    controller: _grid,
    selectable: true,
    canSelectRow: (row) => row.selectable,
    showAddRow: false,
    showRowDelete: false,
    showSelectAllToggle: false,
    showColumnSettings: true,
    emptyMessage: '下层没有需要下单的物料',
    columns: [
      // 身份列与主表、三个分桶详情完全一致（2026-09-14 全站统一口径）：
      // UtenTreeTableCell——缩进 + 层级连线 + 展开/收缩箭头 + 未展开子数徽章，
      // 与物料分析准备页同一组件同一读法，树顶是被下达件本身。
      EditableGridColumn<_ChildCascadeRow>(
        key: 'goods',
        label: '物料名称',
        width: 260,
        filterValueOf: (row) =>
            row.material.goodsName ?? row.material.goodsCode,
        cellBuilder: (context, row) {
          final info = _treeInfo[row];
          final spec = row.material.spec?.trim();
          return UtenTreeTableCell(
            key: ValueKey('cascade-tree-${row.id}'),
            toggleKey: ValueKey('cascade-toggle-${row.id}'),
            depth: row.depth,
            sequence: '',
            sequenceInline: true,
            showLeafMarker: false,
            title: row.material.goodsName ?? row.material.goodsCode ?? '未命名物料',
            subtitle: spec == null || spec.isEmpty ? null : spec,
            hasChildren: info?.hasChildren ?? false,
            childCount: info?.childCount,
            expanded: !_collapsedBranches.contains(row.id),
            onToggle: (info?.hasChildren ?? false)
                ? () => _toggleBranch(row)
                : null,
            ancestorContinuations: info?.ancestorContinuations ?? const [],
            isLastChild: info?.isLastChild ?? true,
          );
        },
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        filterValueOf: (row) => row.material.goodsCode,
        cellBuilder: (context, row) => Text(row.material.goodsCode ?? '—'),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'colorName',
        label: '颜色',
        width: 96,
        filterValueOf: (row) => row.material.colorName,
        cellBuilder: (context, row) => Text(row.material.colorName ?? '—'),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'unitName',
        label: '单位',
        width: 76,
        filterValueOf: (row) => row.material.unitName,
        cellBuilder: (context, row) => Text(row.material.unitName ?? '—'),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'route',
        label: '供料路线',
        width: 108,
        filterValueOf: (row) => row.route.label,
        cellBuilder: (context, row) => Text(
          row.material.confirmedRoute == null
              ? '${row.route.label}（待确认）'
              : row.route.label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: row.material.confirmedRoute == null
                ? theme.colorScheme.tertiary
                : theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'channel',
        label: '下达去向',
        width: 110,
        filterValueOf: (row) => switch (row.kind) {
          _CascadeKind.buy => '下达采购',
          _CascadeKind.subcontractLeaf => '下达委外',
          _CascadeKind.workshop => '下达车间',
        },
        cellBuilder: (context, row) => Text(
          row.isSeed
              ? '—'
              : switch (row.kind) {
                  _CascadeKind.buy => '下达采购',
                  _CascadeKind.subcontractLeaf => '下达委外',
                  _CascadeKind.workshop => '下达车间',
                },
          style: theme.textTheme.bodySmall,
        ),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'grossNeed',
        label: '本批要用',
        width: 108,
        numeric: true,
        headerInfo: '按本批数量 × BOM 单位耗用算出来的毛需求，不扣现货与在途。',
        cellBuilder: (context, row) => Align(
          alignment: Alignment.centerRight,
          child: Text(_qtyWithUnit(row, row.grossNeed)),
        ),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'residual',
        label: '还可下达',
        width: 108,
        numeric: true,
        headerInfo: '服务端口径：本批缺口 − 已在途。为 0 表示这行已经下过单了。',
        cellBuilder: (context, row) => Align(
          alignment: Alignment.centerRight,
          child: row.isSeed
              ? const Text('—')
              : Text(
                  _host._qty(row.residual),
                  style: TextStyle(
                    color: row.residual > 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: row.residual > 0 ? FontWeight.w700 : null,
                  ),
                ),
        ),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'qty',
        label: '下单数量',
        width: 128,
        numeric: true,
        required: true,
        headerInfo: '默认 = 还可下达 + 超产多出来的部分；可以改小分批。',
        textOf: (row) => row.qty.text,
        listenableOf: (row) => row.qty,
        cellBuilder: (context, row) {
          if (!row.ownsInput) {
            return Align(
              alignment: Alignment.centerRight,
              child: Text(
                row.isSeed ? '—' : '与上面同一物料合并',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          if (row.blockedReason != null ||
              (row.suggested <= 0.0001 && !row.adjustIntoRequest)) {
            return const Align(
              alignment: Alignment.centerRight,
              child: Text('—'),
            );
          }
          return RequiredCellFrame(
            listenable: row.qty,
            isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
            child: TextField(
              key: ValueKey('material-analysis-child-cascade-qty-${row.id}'),
              controller: row.qty,
              textAlign: TextAlign.right,
              onChanged: (_) => row.qtyTouched = true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const UtenInputDecoration(
                InputDecoration(isDense: true, hintText: '可改小'),
              ),
            ),
          );
        },
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'workshop',
        label: '生产车间',
        width: 150,
        cellBuilder: (context, row) => row.needsWorkshop
            ? ValueListenableBuilder<String?>(
                valueListenable: row.departmentId,
                builder: (context, departmentId, _) => InkWell(
                  key: ValueKey(
                    'material-analysis-child-cascade-workshop-${row.id}',
                  ),
                  onTap: row.selectable ? () => _pickWorkshop(row) : null,
                  child: InputDecorator(
                    decoration: applyAutofillHint(
                      const InputDecoration(isDense: true),
                      Theme.of(context),
                      autofilled:
                          row.workshopAutofilled && departmentId != null,
                    ),
                    child: Text(
                      departmentId == null
                          ? '点击选择'
                          : (row.departmentName ?? departmentId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              )
            : const Text('—'),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'worker',
        label: '负责人',
        width: 150,
        cellBuilder: (context, row) => row.needsWorkshop
            ? ValueListenableBuilder<String?>(
                valueListenable: row.workerId,
                builder: (context, workerId, _) => InkWell(
                  key: ValueKey(
                    'material-analysis-child-cascade-worker-${row.id}',
                  ),
                  onTap: row.selectable ? () => _pickWorker(row) : null,
                  child: InputDecorator(
                    decoration: applyAutofillHint(
                      const InputDecoration(isDense: true),
                      Theme.of(context),
                      autofilled: row.workerAutofilled && workerId != null,
                    ),
                    child: Text(
                      workerId == null ? '点击选择' : (row.workerName ?? workerId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              )
            : const Text('—'),
      ),
      EditableGridColumn<_ChildCascadeRow>(
        key: 'status',
        label: '状态',
        width: 220,
        filterValueOf: _statusLabel,
        cellBuilder: (context, row) => Text(
          _statusLabel(row),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: row.blockedReason != null
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: row.blockedReason != null ? FontWeight.w700 : null,
          ),
        ),
      ),
    ],
  );

  String _qtyWithUnit(_ChildCascadeRow row, double value) {
    // 树顶那行的数量是**来源单位**的本批数量（需求 10 箱就是 10），而它挂的
    // 根供给行记的是基本单位（200 件）——两者不能拼在一起，否则会出现
    //「刚下达 10 件」这种错标。带单位的完整说明在顶部提示卡里。
    if (row.isSeed) return _host._qty(value);
    final unit = row.material.unitName?.trim();
    return unit == null || unit.isEmpty
        ? _host._qty(value)
        : '${_host._qty(value)} $unit';
  }

  String _statusLabel(_ChildCascadeRow row) {
    if (row.isSeed) {
      return widget.parentAction == null
          ? '刚下达 ${_qtyWithUnit(row, row.grossNeed)}，下层按这个数量算'
          : '本次将下达 ${_qtyWithUnit(row, row.grossNeed)}，下层按这个数量算';
    }
    if (!row.ownsInput) return '同一物料的另一条路径（只作层级上下文）';
    final blocked = row.blockedReason;
    if (blocked != null) return blocked;
    if (row.residual <= 0.0001) {
      if (row.overspill > 0.0001) {
        final link = row.supplyLink;
        if (row.adjustIntoRequest) {
          return '已下采购申请 ${link!.documentNo}（未分解）· 并入 '
              '${_host._qty(link.itemQty)} → ${_host._qty(link.itemQty + row.overspill)}';
        }
        if (row.appendToOrdered) {
          return '已下单 ${link!.documentNo} · 追加 ${_host._qty(row.overspill)}'
              '${_host._canOverSupply ? '' : '（需超量下达权限）'}';
        }
        return row.overCapped
            ? '已下达；多做的 ${_host._qty(row.overspill)} 需超量下达权限'
            : '已覆盖；多做的 ${_host._qty(row.overspill)} 可在此下单';
      }
      return '已下达 / 无需再下单';
    }
    final parts = <String>[row.kind.pendingStage];
    if (row.overspill > 0.0001) {
      parts.add(
        row.overCapped
            ? '超产多需 ${_host._qty(row.overspill)}，无超量下达权限未计入'
            : '含超产多需 ${_host._qty(row.overspill)}',
      );
    }
    if (row.mergedPathCount > 1) parts.add('合并 ${row.mergedPathCount} 条路径');
    return parts.join(' · ');
  }
}
