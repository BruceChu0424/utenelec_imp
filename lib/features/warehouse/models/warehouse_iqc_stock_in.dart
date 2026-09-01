/// 仓库侧永不回显的商业字段（价格/金额/币种/结算）；列表与详情解析都不得触碰。
/// 2026-09-01 详情读路径合并进「品质部检查结果」后，本文件只剩入库确认命令
/// 与来源类型；只读展示模型见 warehouse_quality_result.dart。
const Set<String> warehouseIqcStockInForbiddenKeys = {
  'price',
  'unitPrice',
  'amount',
  'totalAmount',
  'currencyId',
  'currencyCode',
  'exchangeRate',
  'settlementMethodId',
  'payableAmount',
  'apLedgerId',
};

enum WarehouseIqcStockInReceiptType {
  purchase('PURCHASE', '采购收货'),
  subcontract('SUBCONTRACT', '委外进仓');

  const WarehouseIqcStockInReceiptType(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static WarehouseIqcStockInReceiptType? tryParse(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    for (final type in values) {
      if (type.apiValue == normalized) return type;
    }
    return null;
  }
}

class WarehouseIqcStockInConfirmItem {
  const WarehouseIqcStockInConfirmItem({
    required this.passEventId,
    required this.baseQty,
    required this.expectedRemainingBaseQty,
    required this.place,
  });

  final String passEventId;
  final double baseQty;
  final double expectedRemainingBaseQty;
  final String place;

  Map<String, dynamic> toJson() => {
    'passEventId': passEventId,
    'baseQty': baseQty,
    'expectedRemainingBaseQty': expectedRemainingBaseQty,
    'place': place.trim(),
  };
}

class WarehouseIqcStockInConfirmCommand {
  const WarehouseIqcStockInConfirmCommand({
    required this.idempotencyKey,
    required this.items,
  });

  final String idempotencyKey;
  final List<WarehouseIqcStockInConfirmItem> items;

  Map<String, dynamic> toJson() => {
    'idempotencyKey': idempotencyKey,
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };
}

class WarehouseIqcStockInConfirmResult {
  const WarehouseIqcStockInConfirmResult({
    required this.batchId,
    required this.replayed,
    required this.confirmedCount,
    this.confirmedAt,
  });

  final String batchId;
  final bool replayed;
  final int confirmedCount;
  final String? confirmedAt;

  factory WarehouseIqcStockInConfirmResult.fromJson(
    Map<String, dynamic> json,
  ) => WarehouseIqcStockInConfirmResult(
    batchId: _requiredText(json['batchId'], 'IQC 入库确认结果缺少 batchId'),
    replayed: json['replayed'] == true,
    confirmedCount: _integer(json['confirmedCount']),
    confirmedAt: _text(json['confirmedAt']),
  );
}

String _requiredText(Object? value, String message) {
  final result = _text(value);
  if (result == null) throw FormatException(message);
  return result;
}

String? _text(Object? value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

int _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
