import 'measurement_hold.dart';

/// 即时库存行（对标老系统「即时库存」窗口），对应后端 InstantInventoryRow。
/// 粒度=货品+颜色；名称（分类/颜色/单位）后端已解析，免前端字典二次查询。
class InstantInventoryRow {
  const InstantInventoryRow({
    this.goodsId,
    this.colorId,
    this.categoryName,
    this.model,
    this.cNumber,
    this.name,
    this.spec,
    this.colorName,
    this.unitName,
    this.remark,
    this.weight,
    this.weightEstimated = false,
    this.weightUnknown = false,
    this.unitWeightKg,
    this.weightTier,
    this.qty,
    this.costAmount,
    this.costMasked = false,
    this.moreQty,
    this.goodsCode,
    this.series,
    this.stockPlace,
    this.pendingQty,
    this.pendingStockInQty,
    this.owningWarehouseId,
    this.owningWarehouseName,
    this.defectiveQty,
    this.searchRank,
    this.searchMatchKind,
    this.measurementPending = false,
    this.measurementHoldReason,
    bool availableKnown = true,
  }) : availableKnown = availableKnown && !measurementPending;

  final String? goodsId;
  final String? colorId;
  final String? categoryName; // 所属类型
  final String? model; // 型号
  final String? cNumber; // 客户型号
  final String? name; // 货品名称
  final String? spec; // 规格
  final String? colorName; // 颜色
  final String? unitName; // 单位
  final String? remark; // 备注（老库 B_Goods.Paper，如 外购）
  /// 库存重量 (千克, 多仓合计); null = 有维度重量未知 (显示「未称」, 不当 0)。
  final double? weight;

  /// 库存重量含估算 (显示「≈」)。
  final bool weightEstimated;

  /// 本行重量未知 (有库存但没称过)。
  final bool weightUnknown;

  /// 当前学到的单重 (千克/基本单位); 本页不显示, 供流水/分析口径对齐。
  final double? unitWeightKg;

  /// 单重可靠度 GREEN / YELLOW / RED。
  final String? weightTier;
  final double? qty; // 库存数量
  /// 当前筛选仓范围内 stock_balances.amount_local 的库存台账金额聚合。
  ///
  /// 不是 goods.c_total × qty 的标准成本估算。
  final double? costAmount;
  final bool costMasked;
  final double? moreQty; // 多排数量
  final String? goodsCode; // 物料编码（goods.code）
  final String? series; // 物料系列（goods.series）
  final String? stockPlace; // 库位号（goods.stock_place）
  final double? pendingQty; // 待检量（采购/委外收货未放行，>0=货在 IQC 待检）
  final double? pendingStockInQty; // IQC 已合格、仓库尚未确认入库，不计可用库存

  // ===== 所属仓库 (V587) =====
  // 货品平时归哪个仓管的主档归属，不是本行库存所在的落点仓，也不是页面的仓库筛选值。
  // stock:view 的即时库存/详情投影直接连接当前主档，不依赖 goods:view 字典。
  final String? owningWarehouseId;
  final String? owningWarehouseName;

  /// 本行数量里在不良品仓的部分(ADR-146; 只有打开「含不良品仓」或直接查不良品仓时非 0)。
  final double? defectiveQty;
  final int? searchRank;
  final String? searchMatchKind;
  final bool measurementPending;
  final String? measurementHoldReason;
  final bool availableKnown;
  String get measurementNotice => measurementHoldNotice(measurementHoldReason);
  bool get isRelatedSearchMatch => searchMatchKind == 'RELATED';

  factory InstantInventoryRow.fromJson(Map<String, dynamic> json) =>
      InstantInventoryRow(
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        categoryName: json['categoryName'] as String?,
        model: json['model'] as String?,
        cNumber: json['cNumber'] as String?,
        name: json['name'] as String?,
        spec: json['spec'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        remark: json['remark'] as String?,
        weight: (json['weight'] as num?)?.toDouble(),
        weightEstimated: json['weightEstimated'] == true,
        weightUnknown: json['weightUnknown'] == true,
        unitWeightKg: (json['unitWeightKg'] as num?)?.toDouble(),
        weightTier: json['weightTier'] as String?,
        qty: (json['qty'] as num?)?.toDouble(),
        costAmount: json['costMasked'] == true
            ? null
            : (json['costAmount'] as num?)?.toDouble(),
        costMasked: json['costMasked'] == true,
        moreQty: (json['moreQty'] as num?)?.toDouble(),
        goodsCode: json['goodsCode'] as String?,
        series: json['series'] as String?,
        stockPlace: json['stockPlace'] as String?,
        pendingQty: (json['pendingQty'] as num?)?.toDouble(),
        pendingStockInQty: (json['pendingStockInQty'] as num?)?.toDouble(),
        owningWarehouseId: json['owningWarehouseId'] as String?,
        owningWarehouseName: json['owningWarehouseName'] as String?,
        defectiveQty: (json['defectiveQty'] as num?)?.toDouble(),
        searchRank: (json['searchRank'] as num?)?.toInt(),
        searchMatchKind: json['searchMatchKind'] as String?,
        measurementPending: json['measurementPending'] == true,
        measurementHoldReason: json['measurementHoldReason'] as String?,
        availableKnown: json['availableKnown'] != false,
      );
}
