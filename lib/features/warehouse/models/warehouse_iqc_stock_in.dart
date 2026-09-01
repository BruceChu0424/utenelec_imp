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

abstract final class WarehouseIqcStockInAction {
  static const confirm = 'CONFIRM';
}

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

class WarehouseIqcStockInTaskSummary {
  const WarehouseIqcStockInTaskSummary({
    required this.receiptType,
    required this.receiptId,
    required this.goodsLineCount,
    required this.pendingSliceCount,
    required this.status,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.warehouseName,
    this.firstReleasedAt,
    this.lastReleasedAt,
  });

  final WarehouseIqcStockInReceiptType receiptType;
  final String receiptId;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? supplierName;
  final String? warehouseId;
  final String? warehouseName;
  final int goodsLineCount;
  final int pendingSliceCount;
  final String status;
  final String? firstReleasedAt;
  final String? lastReleasedAt;

  String get receiptTypeValue => receiptType.apiValue;

  String get statusLabel => switch (status.trim().toUpperCase()) {
    'PENDING_STOCK_IN' => '品质已放行 · 待仓库入库',
    _ => status.trim().isEmpty ? '待仓库入库' : status.trim(),
  };

  factory WarehouseIqcStockInTaskSummary.fromJson(Map<String, dynamic> json) =>
      WarehouseIqcStockInTaskSummary(
        receiptType: _requiredReceiptType(json['receiptType']),
        receiptId: _requiredText(json['receiptId'], 'IQC 待入库任务缺少 receiptId'),
        billNo: _text(json['billNo']),
        billDate: _text(json['billDate']),
        supplierId: _text(json['supplierId']),
        supplierName: _text(json['supplierName']),
        warehouseId: _text(json['warehouseId']),
        warehouseName: _text(json['warehouseName']),
        goodsLineCount: _integer(json['goodsLineCount']),
        pendingSliceCount: _integer(json['pendingSliceCount']),
        firstReleasedAt: _text(json['firstReleasedAt']),
        lastReleasedAt: _text(json['lastReleasedAt']),
        status: _text(json['status']) ?? 'PENDING_STOCK_IN',
      );
}

class WarehouseIqcStockInTaskDetail {
  const WarehouseIqcStockInTaskDetail({
    required this.receiptType,
    required this.receiptId,
    required this.qualityStatus,
    required this.pendingSliceCount,
    required this.completed,
    required this.allowedActions,
    required this.items,
    required this.history,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.warehouseName,
  });

  final WarehouseIqcStockInReceiptType receiptType;
  final String receiptId;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? supplierName;
  final String? warehouseId;
  final String? warehouseName;
  final String qualityStatus;
  final int pendingSliceCount;
  final bool completed;
  final Set<String> allowedActions;
  final List<WarehouseIqcStockInReleasedSlice> items;
  final List<WarehouseIqcStockInHistoryItem> history;

  bool get canConfirm =>
      !completed &&
      items.isNotEmpty &&
      allowedActions.contains(WarehouseIqcStockInAction.confirm);

  String get qualityStatusLabel => switch (qualityStatus.trim().toUpperCase()) {
    'IN_PROGRESS' => '品质检验进行中',
    'PENDING' => '部分待检',
    'PARTIAL' => '部分处置',
    'RESOLVED' => '品质已结案',
    'REVERSED' => '品质已撤销',
    _ => qualityStatus.trim().isEmpty ? '品质状态未知' : qualityStatus.trim(),
  };

  factory WarehouseIqcStockInTaskDetail.fromJson(Map<String, dynamic> json) {
    final itemRows = json['items'] as List? ?? const [];
    final historyRows = json['history'] as List? ?? const [];
    return WarehouseIqcStockInTaskDetail(
      receiptType: _requiredReceiptType(json['receiptType']),
      receiptId: _requiredText(json['receiptId'], 'IQC 待入库详情缺少 receiptId'),
      billNo: _text(json['billNo']),
      billDate: _text(json['billDate']),
      supplierId: _text(json['supplierId']),
      supplierName: _text(json['supplierName']),
      warehouseId: _text(json['warehouseId']),
      warehouseName: _text(json['warehouseName']),
      qualityStatus: _text(json['qualityStatus']) ?? '',
      pendingSliceCount: _integer(json['pendingSliceCount']),
      completed: json['completed'] == true,
      allowedActions: _stringSet(json['allowedActions']),
      items: [
        for (final row in itemRows.whereType<Map<Object?, Object?>>())
          WarehouseIqcStockInReleasedSlice.fromJson(
            Map<String, dynamic>.from(row),
          ),
      ],
      history: [
        for (final row in historyRows.whereType<Map<Object?, Object?>>())
          WarehouseIqcStockInHistoryItem.fromJson(
            Map<String, dynamic>.from(row),
          ),
      ],
    );
  }
}

class WarehouseIqcStockInReleasedSlice {
  const WarehouseIqcStockInReleasedSlice({
    required this.passEventId,
    required this.inspectionItemId,
    required this.goodsId,
    required this.receivedBaseQty,
    required this.qualityPassedBaseQty,
    required this.warehouseStockedBaseQty,
    required this.releasedBaseQty,
    required this.stockedForReleaseBaseQty,
    required this.remainingBaseQty,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitId,
    this.unitName,
    this.sourceOrderNo,
    this.releasedWeight,
    this.weightUnitId,
    this.weightUnitName,
    this.placeHint,
    this.releaseNote,
    this.releasedBy,
    this.releasedAt,
  });

  final String passEventId;
  final String inspectionItemId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? sourceOrderNo;
  final double receivedBaseQty;
  final double qualityPassedBaseQty;
  final double warehouseStockedBaseQty;
  final double releasedBaseQty;
  final double stockedForReleaseBaseQty;
  final double remainingBaseQty;
  final double? releasedWeight;
  final String? weightUnitId;
  final String? weightUnitName;
  final String? placeHint;
  final String? releaseNote;
  final String? releasedBy;
  final String? releasedAt;

  String get goodsLabel => [
    goodsCode,
    goodsName,
    if (colorName?.isNotEmpty == true) colorName,
  ].where((value) => value?.trim().isNotEmpty == true).join(' · ');

  factory WarehouseIqcStockInReleasedSlice.fromJson(
    Map<String, dynamic> json,
  ) => WarehouseIqcStockInReleasedSlice(
    passEventId: _requiredText(json['passEventId'], 'IQC 待入库切片缺少 passEventId'),
    inspectionItemId: _requiredText(
      json['inspectionItemId'],
      'IQC 待入库切片缺少 inspectionItemId',
    ),
    goodsId: _requiredText(json['goodsId'], 'IQC 待入库切片缺少 goodsId'),
    goodsCode: _text(json['goodsCode']),
    goodsName: _text(json['goodsName']),
    colorName: _text(json['colorName']),
    unitId: _text(json['unitId']),
    unitName: _text(json['unitName']),
    sourceOrderNo: _text(json['sourceOrderNo']),
    receivedBaseQty: _decimal(json['receivedBaseQty']),
    qualityPassedBaseQty: _decimal(json['qualityPassedBaseQty']),
    warehouseStockedBaseQty: _decimal(json['warehouseStockedBaseQty']),
    releasedBaseQty: _decimal(json['releasedBaseQty']),
    stockedForReleaseBaseQty: _decimal(json['stockedForReleaseBaseQty']),
    remainingBaseQty: _decimal(json['remainingBaseQty']),
    releasedWeight: _nullableDecimal(json['releasedWeight']),
    weightUnitId: _text(json['weightUnitId']),
    weightUnitName: _text(json['weightUnitName']),
    placeHint: _text(json['placeHint']),
    releaseNote: _text(json['releaseNote']),
    releasedBy: _text(json['releasedBy']),
    releasedAt: _text(json['releasedAt']),
  );
}

class WarehouseIqcStockInHistoryItem {
  const WarehouseIqcStockInHistoryItem({
    required this.stockInItemId,
    required this.batchId,
    required this.passEventId,
    required this.goodsId,
    required this.baseQty,
    required this.place,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.weight,
    this.weightUnitName,
    this.confirmedBy,
    this.confirmedAt,
  });

  final String stockInItemId;
  final String batchId;
  final String passEventId;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double baseQty;
  final double? weight;
  final String? weightUnitName;
  final String place;
  final String? confirmedBy;
  final String? confirmedAt;

  String get goodsLabel => [
    goodsCode,
    goodsName,
    if (colorName?.isNotEmpty == true) colorName,
  ].where((value) => value?.trim().isNotEmpty == true).join(' · ');

  factory WarehouseIqcStockInHistoryItem.fromJson(Map<String, dynamic> json) =>
      WarehouseIqcStockInHistoryItem(
        stockInItemId: _requiredText(
          json['stockInItemId'],
          'IQC 入库历史缺少 stockInItemId',
        ),
        batchId: _requiredText(json['batchId'], 'IQC 入库历史缺少 batchId'),
        passEventId: _requiredText(
          json['passEventId'],
          'IQC 入库历史缺少 passEventId',
        ),
        goodsId: _requiredText(json['goodsId'], 'IQC 入库历史缺少 goodsId'),
        goodsCode: _text(json['goodsCode']),
        goodsName: _text(json['goodsName']),
        colorName: _text(json['colorName']),
        unitName: _text(json['unitName']),
        baseQty: _decimal(json['baseQty']),
        weight: _nullableDecimal(json['weight']),
        weightUnitName: _text(json['weightUnitName']),
        place: _text(json['place']) ?? '—',
        confirmedBy: _text(json['confirmedBy']),
        confirmedAt: _text(json['confirmedAt']),
      );
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

WarehouseIqcStockInReceiptType _requiredReceiptType(Object? value) {
  final result = WarehouseIqcStockInReceiptType.tryParse(value);
  if (result == null) throw const FormatException('IQC 待入库任务来源类型无效');
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

double _decimal(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

double? _nullableDecimal(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

Set<String> _stringSet(Object? value) {
  if (value is! List) return const {};
  return {for (final item in value) ?_text(item)};
}
