// 库存查询模型 (余额行 + 即时库存行), 对应后端 BalanceRow / InstantInventoryRow。
// 名称 (仓库/货品/颜色) 余额行由前端按 id 解析。日期: OffsetDateTime → ISO 字符串。
// 重量一律千克 (ADR-135): null = 没称/未知, 绝不当 0; weightEstimated = 含估算 (显示「≈」)。
// 出入库流水已并入单货品库存面板 (lib/shared/stock_ledger), 本文件不再有流水行。

class BalanceRow {
  const BalanceRow({
    required this.id,
    this.warehouseId,
    this.goodsId,
    this.colorId,
    this.qty,
    this.amountLocal,
    this.weight,
    this.weightEstimated = false,
    this.lastMovementDate,
  });

  final String id;
  final String? warehouseId;
  final String? goodsId;
  final String? colorId;
  final double? qty;
  final double? amountLocal;

  /// 库存重量 (千克); null = 未知。
  final double? weight;

  /// 库存重量含估算 (按库存均重/单重估算过)。
  final bool weightEstimated;
  final String? lastMovementDate;

  factory BalanceRow.fromJson(Map<String, dynamic> json) => BalanceRow(
    id: json['id'] as String,
    warehouseId: json['warehouseId'] as String?,
    goodsId: json['goodsId'] as String?,
    colorId: json['colorId'] as String?,
    qty: (json['qty'] as num?)?.toDouble(),
    amountLocal: (json['amountLocal'] as num?)?.toDouble(),
    weight: (json['weight'] as num?)?.toDouble(),
    weightEstimated: json['weightEstimated'] == true,
    lastMovementDate: json['lastMovementDate'] as String?,
  );
}

class StockBalanceAdjustmentResult {
  const StockBalanceAdjustmentResult({
    required this.documentId,
    required this.billNo,
    required this.beforeQty,
    required this.afterQty,
    required this.deltaQty,
    this.adjustedByEmployeeId,
    required this.adjustedByName,
    required this.adjustedAt,
    this.afterWeightKg,
  });

  final String documentId;
  final String billNo;
  final double beforeQty;
  final double afterQty;
  final double deltaQty;
  final String? adjustedByEmployeeId;
  final String adjustedByName;
  final String adjustedAt;

  /// 本次一并定下的库存重量 (千克); null = 本次没有改重量。
  final double? afterWeightKg;

  factory StockBalanceAdjustmentResult.fromJson(Map<String, dynamic> json) =>
      StockBalanceAdjustmentResult(
        documentId: json['documentId'] as String,
        billNo: json['billNo'] as String? ?? '',
        beforeQty: (json['beforeQty'] as num).toDouble(),
        afterQty: (json['afterQty'] as num).toDouble(),
        deltaQty: (json['deltaQty'] as num).toDouble(),
        adjustedByEmployeeId: json['adjustedByEmployeeId'] as String?,
        adjustedByName: json['adjustedByName'] as String? ?? '',
        adjustedAt: json['adjustedAt'] as String? ?? '',
        afterWeightKg: (json['afterWeightKg'] as num?)?.toDouble(),
      );
}

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
    this.moreQty,
    this.goodsCode,
    this.series,
    this.stockPlace,
    this.pendingQty,
    this.pendingStockInQty,
    this.owningWarehouseId,
    this.owningWarehouseName,
  });

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
  final double? moreQty; // 多排数量
  final String? goodsCode; // 物料编码（goods.code）
  final String? series; // 物料系列（goods.series）
  final String? stockPlace; // 库位号（goods.stock_place）
  final double? pendingQty; // 待检量（采购/委外收货未放行，>0=货在 IQC 待检）
  final double? pendingStockInQty; // IQC 已合格、仓库尚未确认入库，不计可用库存

  // ===== 所属仓库 (V587) =====
  // 货品平时归哪个仓管的主档归属，不是本行库存所在的落点仓，也不是页面的仓库筛选值。
  // 当前后端即时库存行还没下发这两个字段 (恒 null)，页面据此回落货品字典
  // (GoodsDictEntry.owningWarehouseName)；后端补发后前端无需再改。
  final String? owningWarehouseId;
  final String? owningWarehouseName;

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
        costAmount: (json['costAmount'] as num?)?.toDouble(),
        moreQty: (json['moreQty'] as num?)?.toDouble(),
        goodsCode: json['goodsCode'] as String?,
        series: json['series'] as String?,
        stockPlace: json['stockPlace'] as String?,
        pendingQty: (json['pendingQty'] as num?)?.toDouble(),
        pendingStockInQty: (json['pendingStockInQty'] as num?)?.toDouble(),
        owningWarehouseId: json['owningWarehouseId'] as String?,
        owningWarehouseName: json['owningWarehouseName'] as String?,
      );
}
