const Set<String> warehouseIqcReturnForbiddenKeys = {
  'failedAmountOriginal',
  'failedAmountLocal',
  'currencyCode',
  'creditReference',
  'creditDate',
  'creditConfirmedAt',
  'closedNoCreditReason',
  'closedNoCreditAt',
  'financeExceptionCode',
  'financeExceptionMessage',
  'replacementAllocations',
  'allocatedAmountOriginal',
  'allocatedAmountLocal',
  'price',
  'amount',
};

enum WarehouseIqcReceiptType {
  purchase('PURCHASE', '采购收货'),
  subcontract('SUBCONTRACT', '委外进仓');

  const WarehouseIqcReceiptType(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static WarehouseIqcReceiptType? tryParse(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    for (final type in values) {
      if (type.apiValue == normalized) return type;
    }
    return null;
  }
}

abstract final class WarehouseIqcPhysicalStatus {
  static const pendingReturn = 'PENDING_RETURN';
  static const returnRecorded = 'RETURN_RECORDED';
  static const voided = 'VOIDED';

  static String label(String? value) => switch (value?.trim().toUpperCase()) {
    pendingReturn => '待登记实物退回',
    returnRecorded => '实物退回已登记',
    voided => '来源已撤销',
    _ => value?.trim().isNotEmpty == true ? value!.trim() : '状态未知',
  };
}

abstract final class WarehouseIqcReturnAction {
  static const recordReturn = 'RECORD_RETURN';
}

class WarehouseIqcReturnTask {
  const WarehouseIqcReturnTask({
    required this.id,
    required this.version,
    required this.allowedActions,
    this.receiptType,
    this.receiptId,
    this.receiptItemId,
    this.inspectionItemId,
    this.receiptBillNo,
    this.orderBillNo,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.warehouseName,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.failedBaseQuantity,
    this.failedQuantity,
    this.inspectionStatus,
    this.physicalReturnStatus,
    this.returnReference,
    this.returnDate,
    this.returnNote,
    this.returnRecordedByName,
    this.returnRecordedAt,
  });

  final String id;
  final WarehouseIqcReceiptType? receiptType;
  final String? receiptId;
  final String? receiptItemId;
  final String? inspectionItemId;
  final String? receiptBillNo;
  final String? orderBillNo;
  final String? supplierId;
  final String? supplierName;
  final String? warehouseId;
  final String? warehouseName;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final String? failedBaseQuantity;
  final String? failedQuantity;
  final String? inspectionStatus;
  final String? physicalReturnStatus;
  final int version;
  final String? returnReference;
  final String? returnDate;
  final String? returnNote;
  final String? returnRecordedByName;
  final String? returnRecordedAt;
  final Set<String> allowedActions;

  String get statusLabel =>
      WarehouseIqcPhysicalStatus.label(physicalReturnStatus);

  String get goodsLabel {
    return [
      goodsCode,
      goodsName,
    ].where((value) => value?.trim().isNotEmpty == true).join(' · ');
  }

  bool get canRecordReturn =>
      allowedActions.contains(WarehouseIqcReturnAction.recordReturn) &&
      physicalReturnStatus == WarehouseIqcPhysicalStatus.pendingReturn &&
      version > 0;

  factory WarehouseIqcReturnTask.fromJson(Map<String, dynamic> json) {
    return WarehouseIqcReturnTask(
      id: _requiredId(json['id']),
      receiptType: WarehouseIqcReceiptType.tryParse(json['receiptType']),
      receiptId: _text(json['receiptId']),
      receiptItemId: _text(json['receiptItemId']),
      inspectionItemId: _text(json['inspectionItemId']),
      receiptBillNo: _text(json['receiptBillNo']),
      orderBillNo: _text(json['orderBillNo']),
      supplierId: _text(json['supplierId']),
      supplierName: _text(json['supplierName']),
      warehouseId: _text(json['warehouseId']),
      warehouseName: _text(json['warehouseName']),
      goodsId: _text(json['goodsId']),
      goodsCode: _text(json['goodsCode']),
      goodsName: _text(json['goodsName']),
      colorName: _text(json['colorName']),
      unitName: _text(json['unitName']),
      failedBaseQuantity: _decimalText(
        json['failedBaseQuantity'] ?? json['failedBaseQty'],
      ),
      failedQuantity: _decimalText(json['failedQuantity'] ?? json['failedQty']),
      inspectionStatus: _text(json['inspectionStatus']),
      physicalReturnStatus: _text(
        json['physicalReturnStatus'] ?? json['physicalStatus'],
      ),
      version: _integer(json['version']) ?? 0,
      returnReference: _text(json['returnReference']),
      returnDate: _text(json['returnDate']),
      returnNote: _text(json['returnNote']),
      returnRecordedByName: _text(json['returnRecordedByName']),
      returnRecordedAt: _text(json['returnRecordedAt'] ?? json['returnedAt']),
      allowedActions: _stringSet(json['allowedActions']),
    );
  }
}

class WarehouseIqcRecordReturnCommand {
  const WarehouseIqcRecordReturnCommand({
    required this.expectedVersion,
    required this.commandId,
    required this.returnReference,
    required this.returnDate,
    required this.returnNote,
  });

  final int expectedVersion;
  final String commandId;
  final String returnReference;
  final String returnDate;
  final String returnNote;

  Map<String, dynamic> toJson() => {
    'expectedVersion': expectedVersion,
    'commandId': commandId,
    'returnReference': returnReference.trim(),
    'returnDate': returnDate,
    'returnNote': returnNote.trim(),
  };
}

String _requiredId(Object? value) {
  final id = _text(value);
  if (id == null) throw const FormatException('IQC 实物退回任务缺少 id');
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
