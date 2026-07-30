// 库存查询模型（余额行 + 流水行），对应后端 BalanceRow / MovementRow。
// 名称（仓库/货品/颜色）前端按 id 解析。日期：OffsetDateTime → ISO 字符串。

class BalanceRow {
  const BalanceRow({
    required this.id,
    this.warehouseId,
    this.goodsId,
    this.colorId,
    this.qty,
    this.amountLocal,
    this.lastMovementDate,
  });

  final String id;
  final String? warehouseId;
  final String? goodsId;
  final String? colorId;
  final double? qty;
  final double? amountLocal;
  final String? lastMovementDate;

  factory BalanceRow.fromJson(Map<String, dynamic> json) => BalanceRow(
        id: json['id'] as String,
        warehouseId: json['warehouseId'] as String?,
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        qty: (json['qty'] as num?)?.toDouble(),
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
        lastMovementDate: json['lastMovementDate'] as String?,
      );
}

class MovementRow {
  const MovementRow({
    required this.id,
    this.transactionDate,
    this.movementType,
    this.sourceDocType,
    this.goodsId,
    this.colorId,
    this.warehouseId,
    this.direction,
    this.qty,
    this.amountLocal,
    this.remark,
  });

  final String id;
  final String? transactionDate;
  final int? movementType;
  final String? sourceDocType;
  final String? goodsId;
  final String? colorId;
  final String? warehouseId;
  final int? direction;
  final double? qty;
  final double? amountLocal;
  final String? remark;

  factory MovementRow.fromJson(Map<String, dynamic> json) => MovementRow(
        id: json['id'] as String,
        transactionDate: json['transactionDate'] as String?,
        movementType: (json['movementType'] as num?)?.toInt(),
        sourceDocType: json['sourceDocType'] as String?,
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        direction: (json['direction'] as num?)?.toInt(),
        qty: (json['qty'] as num?)?.toDouble(),
        amountLocal: (json['amountLocal'] as num?)?.toDouble(),
        remark: json['remark'] as String?,
      );
}

/// movement_type 中文（1采购入 2采购退 3销售出 4销售退 5领料 6退料 7调拨入 8调拨出
/// 9盘盈 10盘亏 11其它入 12其它出 13产成品进仓 14产成品出仓）。
String movementTypeLabel(int? t) {
  const m = {
    1: '采购入库', 2: '采购退货', 3: '销售出库', 4: '销售退货',
    5: '生产领料', 6: '生产退料', 7: '调拨入', 8: '调拨出',
    9: '盘盈入', 10: '盘亏出', 11: '其它入', 12: '其它出',
    13: '产成品进仓', 14: '产成品出仓',
  };
  return t == null ? '—' : (m[t] ?? '类型$t');
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
    this.qty,
    this.costAmount,
    this.moreQty,
  });

  final String? goodsId;
  final String? colorId;
  final String? categoryName; // 所属类型
  final String? model;        // 型号
  final String? cNumber;      // 客户型号
  final String? name;         // 货品名称
  final String? spec;         // 规格
  final String? colorName;    // 颜色
  final String? unitName;     // 单位
  final String? remark;       // 备注（老库 B_Goods.Paper，如 外购）
  final double? weight;       // 库存重量
  final double? qty;          // 库存数量
  final double? costAmount;   // 成本金额
  final double? moreQty;      // 多排数量

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
        qty: (json['qty'] as num?)?.toDouble(),
        costAmount: (json['costAmount'] as num?)?.toDouble(),
        moreQty: (json['moreQty'] as num?)?.toDouble(),
      );
}
