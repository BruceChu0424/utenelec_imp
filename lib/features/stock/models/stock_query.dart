import '../../../shared/models/historical_receipt_facts.dart';
import '../../../shared/stock_inventory/measurement_hold.dart';

export '../../../shared/stock_inventory/instant_inventory_row.dart';

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
    this.qtyText,
    this.amountLocal,
    this.costMasked = false,
    this.weight,
    this.weightEstimated = false,
    this.lastMovementDate,
    this.measurementPending = false,
    this.measurementHoldReason,
    bool availableKnown = true,
  }) : availableKnown = availableKnown && !measurementPending;

  final String id;
  final String? warehouseId;
  final String? goodsId;
  final String? colorId;
  final double? qty;
  final String? qtyText;
  final double? amountLocal;
  final bool costMasked;

  /// 库存重量 (千克); null = 未知。
  final double? weight;

  /// 库存重量含估算 (按库存均重/单重估算过)。
  final bool weightEstimated;
  final String? lastMovementDate;
  final bool measurementPending;
  final String? measurementHoldReason;
  final bool availableKnown;
  String get measurementNotice => measurementHoldNotice(measurementHoldReason);

  factory BalanceRow.fromJson(Map<String, dynamic> json) => BalanceRow(
    id: json['id'] as String,
    warehouseId: json['warehouseId'] as String?,
    goodsId: json['goodsId'] as String?,
    colorId: json['colorId'] as String?,
    qty: (json['qty'] as num?)?.toDouble(),
    qtyText: receiptRecordedDecimal(json, 'qty'),
    amountLocal: json['costMasked'] == true
        ? null
        : (json['amountLocal'] as num?)?.toDouble(),
    costMasked: json['costMasked'] == true,
    weight: (json['weight'] as num?)?.toDouble(),
    weightEstimated: json['weightEstimated'] == true,
    lastMovementDate: json['lastMovementDate'] as String?,
    measurementPending: json['measurementPending'] == true,
    measurementHoldReason: json['measurementHoldReason'] as String?,
    availableKnown: json['availableKnown'] != false,
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
