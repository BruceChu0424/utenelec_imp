const Set<String> warehouseSalesOutboundForbiddenKeys = {
  'financeAudit',
  'currencyId',
  'currencyCode',
  'exchangeRate',
  'taxRate',
  'settlementMethodId',
  'price',
  'unitPrice',
  'amount',
  'amountOriginal',
  'amountLocal',
  'totalOriginal',
  'totalLocal',
  'arPosted',
};

abstract final class WarehouseSalesOutboundStatus {
  static const pendingPick = 'PENDING_PICK';
  static const picking = 'PICKING';
  static const picked = 'PICKED';
  static const exception = 'EXCEPTION';
  static const shipped = 'SHIPPED';

  static String label(String? value) => switch (value?.trim().toUpperCase()) {
    pendingPick => '待拣货',
    picking => '拣货中',
    picked => '已拣货，待交接',
    exception => '仓库异常',
    shipped => '已交接出库',
    _ => value?.trim().isNotEmpty == true ? value!.trim() : '状态未知',
  };

  static String nextStep(String? value) =>
      switch (value?.trim().toUpperCase()) {
        pendingPick => '核对实物与库位后开始拣货',
        picking => '完成逐项拣货，或如实登记异常',
        picked => '核对交接后完成正式出库',
        exception => '处理异常并填写说明后恢复待拣货',
        shipped => '已完成仓库交接',
        _ => '请刷新后按服务端允许动作处理',
      };
}

enum WarehouseSalesOutboundAction {
  startPicking(WarehouseSalesOutboundStatus.picking, '开始拣货'),
  finishPicking(WarehouseSalesOutboundStatus.picked, '拣货完成'),
  reportException(WarehouseSalesOutboundStatus.exception, '登记异常'),
  restorePending(WarehouseSalesOutboundStatus.pendingPick, '恢复待拣货'),
  handOver(WarehouseSalesOutboundStatus.shipped, '交接出库');

  const WarehouseSalesOutboundAction(this.targetStatus, this.label);

  final String targetStatus;
  final String label;

  bool get requiresReason => this == reportException || this == restorePending;
}

class WarehouseSalesOutboundSummary {
  const WarehouseSalesOutboundSummary({
    required this.id,
    required this.allowedWarehouseTargets,
    this.billNo,
    this.billDate,
    this.clientId,
    this.clientName,
    this.warehouseId,
    this.warehouseName,
    this.warehouseWorkStatus,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? clientId;
  final String? clientName;
  final String? warehouseId;
  final String? warehouseName;
  final String? warehouseWorkStatus;
  final Set<String> allowedWarehouseTargets;

  String get statusLabel =>
      WarehouseSalesOutboundStatus.label(warehouseWorkStatus);

  bool allows(WarehouseSalesOutboundAction action) =>
      allowedWarehouseTargets.contains(action.targetStatus);

  factory WarehouseSalesOutboundSummary.fromJson(Map<String, dynamic> json) {
    return WarehouseSalesOutboundSummary(
      id: _requiredId(json['id']),
      billNo: _text(json['billNo']),
      billDate: _text(json['billDate']),
      clientId: _text(json['clientId']),
      clientName: _text(json['clientName']),
      warehouseId: _text(json['warehouseId']),
      warehouseName: _text(json['warehouseName']),
      warehouseWorkStatus: _text(json['warehouseWorkStatus']),
      allowedWarehouseTargets: _stringSet(json['allowedWarehouseTargets']),
    );
  }
}

class WarehouseSalesOutboundDetail {
  const WarehouseSalesOutboundDetail({
    required this.header,
    required this.lines,
    this.shipAddress,
    this.contactPhone,
    this.logisticsNo,
    this.parcelCount,
    this.warehouseWorkUpdatedAt,
    this.pickingStartedAt,
    this.pickedAt,
    this.handedOverAt,
    this.warehouseExceptionReason,
  });

  final WarehouseSalesOutboundSummary header;
  final String? shipAddress;
  final String? contactPhone;
  final String? logisticsNo;
  final int? parcelCount;
  final String? warehouseWorkUpdatedAt;
  final String? pickingStartedAt;
  final String? pickedAt;
  final String? handedOverAt;
  final String? warehouseExceptionReason;
  final List<WarehouseSalesOutboundLine> lines;

  factory WarehouseSalesOutboundDetail.fromJson(Map<String, dynamic> json) {
    return WarehouseSalesOutboundDetail(
      header: WarehouseSalesOutboundSummary.fromJson(json),
      shipAddress: _text(json['shipAddress']),
      contactPhone: _text(json['contactPhone']),
      logisticsNo: _text(json['logisticsNo']),
      parcelCount: _integer(json['parcelCount']),
      warehouseWorkUpdatedAt: _text(json['warehouseWorkUpdatedAt']),
      pickingStartedAt: _text(json['pickingStartedAt']),
      pickedAt: _text(json['pickedAt']),
      handedOverAt: _text(json['handedOverAt']),
      warehouseExceptionReason: _text(json['warehouseExceptionReason']),
      lines: _objectList(json['lines'])
          .map(WarehouseSalesOutboundLine.fromJson)
          .toList(growable: false),
    );
  }
}

class WarehouseSalesOutboundLine {
  const WarehouseSalesOutboundLine({
    required this.id,
    this.lineNumber,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.currentStockPlaceHint,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.quantity,
    this.weight,
    this.parcelQuantity,
    this.cartonCount,
    this.clientProductCode,
    this.clientModel,
    this.sourceDocumentNo,
  });

  final String id;
  final int? lineNumber;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? currentStockPlaceHint;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? quantity;
  final String? weight;
  final String? parcelQuantity;
  final int? cartonCount;
  final String? clientProductCode;
  final String? clientModel;
  final String? sourceDocumentNo;

  factory WarehouseSalesOutboundLine.fromJson(Map<String, dynamic> json) {
    return WarehouseSalesOutboundLine(
      id: _requiredId(json['id']),
      lineNumber: _integer(json['lineNumber']),
      goodsId: _text(json['goodsId']),
      goodsCode: _text(json['goodsCode']),
      goodsName: _text(json['goodsName']),
      currentStockPlaceHint: _text(json['currentStockPlaceHint']),
      colorId: _text(json['colorId']),
      colorName: _text(json['colorName']),
      unitId: _text(json['unitId']),
      unitName: _text(json['unitName']),
      quantity: _decimalText(json['quantity']),
      weight: _decimalText(json['weight']),
      parcelQuantity: _decimalText(json['parcelQuantity']),
      cartonCount: _integer(json['cartonCount']),
      clientProductCode: _text(json['clientProductCode']),
      clientModel: _text(json['clientModel']),
      sourceDocumentNo: _text(json['sourceDocumentNo']),
    );
  }
}

String _requiredId(Object? value) {
  final id = _text(value);
  if (id == null) throw const FormatException('销售出库任务缺少 id');
  return id;
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

String? _decimalText(Object? value) => _text(value);

int? _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

Set<String> _stringSet(Object? value) {
  if (value is! List) return const {};
  return {for (final item in value) ?_text(item)};
}

List<Map<String, dynamic>> _objectList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map<Object?, Object?>>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}
