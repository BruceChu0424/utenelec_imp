part of 'production_material_analysis_page.dart';

final class _PendingMakeCandidate {
  const _PendingMakeCandidate({
    required this.material,
    required this.group,
    required this.route,
    required this.parentLabel,
    required this.shortageKindCount,
    required this.shortagePathCount,
    required this.unconfirmedPathCount,
  });

  final ProductionMaterialAnalysisMaterial material;
  final _MaterialGroup? group;

  /// 候选路线：make=自制备料；subcontract=有子层级委外件「先自制」
  /// （V458/ADR-064 两段式，与自制候选同区同门槛）。
  final MaterialSupplyRoute route;
  final String? parentLabel;
  final int shortageKindCount;
  final int shortagePathCount;
  final int unconfirmedPathCount;
}

final class _PendingRouteDecision {
  const _PendingRouteDecision({required this.groupKey, required this.decision});

  final String groupKey;
  final MaterialRouteDecision decision;

  String get identity =>
      '${decision.actionGroupKey ?? decision.materialLineId}|'
      '${decision.route.wireName}|${decision.reason ?? ''}';
}

final class _SupplyNotificationTarget {
  const _SupplyNotificationTarget({this.actionGroupKey, this.materialLineId})
    : assert(actionGroupKey != null || materialLineId != null);

  final String? actionGroupKey;
  final String? materialLineId;

  String get identity =>
      actionGroupKey == null ? 'LINE|$materialLineId' : 'GROUP|$actionGroupKey';
}

final class _MaterialAnalysisIndexes {
  const _MaterialAnalysisIndexes({
    required this.productsById,
    required this.materialsByProduct,
    required this.groups,
    required this.groupsByLine,
    required this.childrenByParentNodeKey,
  });

  final Map<String, ProductionMaterialAnalysisProduct> productsById;
  final Map<String?, List<ProductionMaterialAnalysisMaterial>>
  materialsByProduct;
  final List<_MaterialGroup> groups;
  final Map<String, _MaterialGroup> groupsByLine;

  /// (analysisLineId, parentNodeKey) → 直接子节点。nodeKey 只在单个分析项内
  /// 唯一（V234 唯一键同样是 analysis_item_id + node_key）；若只按 nodeKey
  /// 建桶，同款 BOM 的多订单行会落进同一大桶，候选查询仍退化成 O(产品²)。
  final Map<
    ({String? analysisLineId, String parentNodeKey}),
    List<ProductionMaterialAnalysisMaterial>
  >
  childrenByParentNodeKey;
}

/// Display-only ownership links. Business material objects keep their exact
/// analysis/item/action IDs when child preparation takes over a BOM branch.
final class _BomPresentation {
  const _BomPresentation({
    required this.nodesByProduct,
    required this.parentIdsByMaterial,
    required this.rootIdsByMaterial,
    required this.depthByMaterial,
  });

  final Map<String?, List<ProductionMaterialAnalysisMaterial>> nodesByProduct;
  final Map<String, String?> parentIdsByMaterial;
  final Map<String, String?> rootIdsByMaterial;
  final Map<String, int> depthByMaterial;
}

final class _BomFilterProjection {
  const _BomFilterProjection({
    required this.nodesByProduct,
    required this.directMatchCount,
    required this.visibleNodeCount,
    required this.presentation,
    this.visibleProductIds = const {},
    this.contextOnlyProductIds = const {},
    this.contextOnlyMaterialIds = const {},
    this.nodeMatchesFilters = const {},
    this.facets = const {},
  });

  final _BomPresentation presentation;
  final Map<String?, List<ProductionMaterialAnalysisMaterial>> nodesByProduct;
  final int directMatchCount;
  final int visibleNodeCount;

  /// 当前视图 + 关键词 + 表头筛选下要渲染的产品（含只作祖先上下文的产品）。
  final Set<String> visibleProductIds;

  /// 表头筛选未命中、仅因子孙命中而保留的产品行（只读上下文，无勾选/下拉）。
  final Set<String> contextOnlyProductIds;

  /// 表头筛选未命中、仅因子孙命中而保留的物料节点（只读上下文）。
  final Set<String> contextOnlyMaterialIds;

  /// 节点是否通过「关键词 + 表头筛选」（不含视图 chip），供 chip 计数复用。
  final Map<String, bool> nodeMatchesFilters;

  /// 进度/路线列头筛选桶：按当前视图（chip + 关键词）全量节点聚合，稳定键 +
  /// 中文标签；表头筛选本身不影响桶（否则选了一个值其余值就消失）。
  final Map<String, List<MasterFacetBucket>> facets;
}

/// 进度列头筛选的稳定桶键 → 中文标签（表头筛选按键比较，不按格内文案）。
/// 服务端/词表阶段键（如 BUY_ORDERED）不在此表，其标签取 [ProductionFlowStage.label]。
const Map<String, String> _materialStatusFacetLabels = {
  'routePending': '路线待确认',
  'pendingIssue': '未下达',
  'inTransit': '处理中',
  'covered': '已齐套',
  'blocked': '不可执行',
  'inactive': '本批无需求',
  'aggregateCovered': '已覆盖',
  'aggregatePartial': '部分覆盖',
  'aggregateUncovered': '未覆盖',
};

enum _ReadinessState { ready, waitingMake, waitingSupply, waiting }

enum _BomViewMode {
  all('全部 BOM'),
  shortage('只看缺料'),
  unconfirmed('待确认路线');

  const _BomViewMode(this.label);

  final String label;
}

class _ProductReadiness {
  const _ProductReadiness(
    this.state, {
    this.make = 0,
    this.buy = 0,
    this.subcontract = 0,
    this.review = 0,
  });

  final _ReadinessState state;
  final int make;
  final int buy;
  final int subcontract;
  final int review;
}

class _MaterialGroup {
  const _MaterialGroup({required this.key, required this.paths});

  final String key;
  final List<ProductionMaterialAnalysisMaterial> paths;

  ProductionMaterialAnalysisMaterial get representative => paths.first;
  bool get actionable => representative.actionable;
}

/// 按物料汇总视图的一行：同一物料跨产品、跨 BOM 路径的展示投影。
/// 仅用于汇总展示与选择入口；任务身份仍是 [paths] 里的逐路径节点，
/// 合计数字只是各路径服务端事实的加总，客户端不重新分配库存。
class _MaterialAggregate {
  const _MaterialAggregate({
    required this.key,
    required this.paths,
    this.rootProductIds,
  });

  final String key;
  final List<ProductionMaterialAnalysisMaterial> paths;
  final Set<String?>? rootProductIds;

  ProductionMaterialAnalysisMaterial get representative => paths.first;
  String? get goodsName => representative.goodsName;
  String? get goodsCode => representative.goodsCode;
  String? get spec => representative.spec;
  String? get colorName => representative.colorName;
  String? get unitName => representative.unitName;

  double get totalRequired =>
      paths.fold(0.0, (sum, item) => sum + item.requiredQty);
  double get totalShortage =>
      paths.fold(0.0, (sum, item) => sum + item.shortageQty);
  double get totalDemandSupplyGap =>
      paths.fold(0.0, (sum, item) => sum + item.demandSupplyGapQty);
  double get qualifiedCoveredQty =>
      (totalRequired - totalDemandSupplyGap).clamp(0.0, totalRequired);

  /// 现货是同一目标仓共享池快照，同料各路径应一致；取最大值防御脏数据。
  double get warehouseStock => paths.fold(
    0.0,
    (max, item) => item.availableQty > max ? item.availableQty : max,
  );

  int get productCount =>
      rootProductIds?.length ??
      paths.map((item) => item.analysisLineId).toSet().length;

  double get coverageRatio => totalRequired <= 0
      ? 0
      : (qualifiedCoveredQty / totalRequired).clamp(0.0, 1.0);

  /// 所有路径的确认路线（未确认时取建议路线）一致时返回该路线，
  /// 否则返回 null，界面显示「路线不一」并引导展开逐条查看。
  MaterialSupplyRoute? get uniformSuggestion {
    final routes = paths
        .map((item) => item.confirmedRoute ?? item.sourceSuggestion)
        .toSet();
    return routes.length == 1 ? routes.first : null;
  }
}

class _StatusView {
  const _StatusView(
    this.label,
    this.icon,
    this.color, {
    this.facetKey,
    this.facetLabel,
  });

  final String label;
  final IconData icon;
  final Color color;

  /// 进度列头筛选的稳定桶键（见 [_materialStatusFacetLabels]；流程阶段用
  /// [ProductionFlowStage.key]）。文案带数量/百分比时桶仍只按键聚合。
  final String? facetKey;

  /// 桶展示标签（流程阶段传 [ProductionFlowStage.label]，不带百分比）；
  /// 为空时按 [_materialStatusFacetLabels] 取，再退回 [label]。
  final String? facetLabel;
}

/// 数量确认对话框里的一行：一个提交单元（操作组或单行物料）。
/// maxQty = 本批生产需求缺口 − 已在途需求；公共安全库存补库是固定、显式、
