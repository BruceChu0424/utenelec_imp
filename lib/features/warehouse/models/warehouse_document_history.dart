import '../config/warehouse_document_history_config.dart';

/// Commercial keys that are outside the warehouse-history API contract.
///
/// The parser below never reads or retains these values. Keeping this list next
/// to the allow-listed model makes regression tests explicit when upstream DTOs
/// evolve.
const Set<String> warehouseHistoryForbiddenCommercialKeys = {
  'price',
  'unitPrice',
  'taxRate',
  'currencyId',
  'currencyCode',
  'exchangeRate',
  'settlementMethodId',
  'settlementStyleLegacy',
  'amount',
  'amountOriginal',
  'amountLocal',
  'totalOriginal',
  'totalLocal',
  'deductAmount',
  'claimAmount',
  'apPosted',
};

/// Quantity-only list row for a warehouse-owned document-history page.
class WarehouseDocumentHistorySummary {
  const WarehouseDocumentHistorySummary({
    required this.id,
    required this.type,
    required this.closed,
    required this.itemCount,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.supplierName,
    this.warehouseId,
    this.warehouseName,
    this.status,
    this.sourceDocNo,
    this.inspectionStatus,
    this.makerId,
    this.makerName,
    this.approverId,
    this.approverName,
  });

  final String id;
  final WarehouseDocumentHistoryType type;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? supplierName;
  final String? warehouseId;
  final String? warehouseName;
  final String? status;
  final bool closed;
  final String? sourceDocNo;
  final int itemCount;
  final String? inspectionStatus;
  final String? makerId;
  final String? makerName;
  final String? approverId;
  final String? approverName;

  String get displayBillNo => _nonBlank(billNo) ?? '—';

  String get statusLabel => warehouseHistoryStatusLabel(status, closed: closed);

  String get inspectionStatusLabel =>
      warehouseInspectionStatusLabel(inspectionStatus);

  factory WarehouseDocumentHistorySummary.fromJson(
    WarehouseDocumentHistoryType expectedType,
    Map<String, dynamic> json,
  ) {
    return WarehouseDocumentHistorySummary(
      id: _requiredId(json['id']),
      type: expectedType,
      billNo: _text(json['billNo']),
      billDate: _text(json['billDate']),
      supplierId: _text(json['supplierId']),
      supplierName: _text(json['supplierName']),
      warehouseId: _text(json['warehouseId']),
      warehouseName: _text(json['warehouseName']),
      status: _text(json['status']),
      closed: _boolean(json['closed']),
      sourceDocNo: _text(json['sourceDocumentNo'] ?? json['sourceDocNo']),
      itemCount: _integer(json['lineCount'] ?? json['itemCount']) ?? 0,
      inspectionStatus: _text(json['iqcStatus'] ?? json['inspectionStatus']),
      makerId: _text(json['makerId']),
      makerName: _text(json['makerName']),
      approverId: _text(json['approverId']),
      approverName: _text(json['approverName']),
    );
  }
}

/// Quantity-only detail returned by `/warehouse/document-history/{segment}/{id}`.
class WarehouseDocumentHistoryDetail {
  const WarehouseDocumentHistoryDetail({
    required this.header,
    required this.items,
    this.makerId,
    this.makerName,
    this.approverId,
    this.approverName,
    this.senderId,
    this.senderName,
    this.receiverId,
    this.receiverName,
    this.workerId,
    this.workerName,
    this.remark,
    this.createdAt,
  });

  final WarehouseDocumentHistorySummary header;
  final String? makerId;
  final String? makerName;
  final String? approverId;
  final String? approverName;
  final String? senderId;
  final String? senderName;
  final String? receiverId;
  final String? receiverName;
  final String? workerId;
  final String? workerName;
  final String? remark;
  final String? createdAt;
  final List<WarehouseDocumentPhysicalItem> items;

  factory WarehouseDocumentHistoryDetail.fromJson(
    WarehouseDocumentHistoryType expectedType,
    Map<String, dynamic> json,
  ) {
    final rawItems = _objectList(json['items'] ?? json['lines']);
    final items = rawItems
        .map(WarehouseDocumentPhysicalItem.fromJson)
        .toList(growable: false);
    final parsedHeader = WarehouseDocumentHistorySummary.fromJson(
      expectedType,
      json,
    );
    final header = WarehouseDocumentHistorySummary(
      id: parsedHeader.id,
      type: parsedHeader.type,
      billNo: parsedHeader.billNo,
      billDate: parsedHeader.billDate,
      supplierId: parsedHeader.supplierId,
      supplierName: parsedHeader.supplierName,
      warehouseId: parsedHeader.warehouseId,
      warehouseName: parsedHeader.warehouseName,
      status: parsedHeader.status,
      closed: parsedHeader.closed,
      sourceDocNo: parsedHeader.sourceDocNo,
      itemCount:
          _integer(json['lineCount'] ?? json['itemCount']) ?? items.length,
      inspectionStatus: parsedHeader.inspectionStatus,
      makerId: parsedHeader.makerId,
      makerName: parsedHeader.makerName,
      approverId: parsedHeader.approverId,
      approverName: parsedHeader.approverName,
    );
    return WarehouseDocumentHistoryDetail(
      header: header,
      makerId: parsedHeader.makerId,
      makerName: parsedHeader.makerName,
      approverId: parsedHeader.approverId,
      approverName: parsedHeader.approverName,
      senderId: _text(json['senderId']),
      senderName: _text(json['senderName']),
      receiverId: _text(json['receiverId']),
      receiverName: _text(json['receiverName']),
      workerId: _text(json['workerId']),
      workerName: _text(json['workerName']),
      remark: _text(json['remark']),
      createdAt: _text(json['createdAt']),
      items: items,
    );
  }
}

/// Allow-listed physical line. Decimal values stay as text to preserve server
/// precision on Flutter Web and to avoid accidental local commercial maths.
class WarehouseDocumentPhysicalItem {
  const WarehouseDocumentPhysicalItem({
    required this.id,
    this.lineNo,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.stockPlace,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.unitRate,
    this.qty,
    this.weight,
    this.returnedQty,
    this.giftQty,
    this.wastedQty,
    this.endingQty,
    this.standardQty,
    this.wasteRate,
    this.cause,
    this.parentGoodsId,
    this.parentGoodsCode,
    this.sourceDocNo,
    this.remark,
    this.inspectionStatus,
    this.receivedBaseQty,
    this.passedBaseQty,
    this.stockedBaseQty,
    this.pendingStockInBaseQty,
    this.failedBaseQty,
    this.atSupplierQty,
    this.consumedQty,
    this.supplierEndingQty,
    this.boxQty,
    this.parentGoodsName,
  });

  final String id;
  final int? lineNo;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? stockPlace;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? unitRate;
  final String? qty;
  final String? weight;
  final String? returnedQty;
  final String? giftQty;
  final String? wastedQty;
  final String? endingQty;
  final String? standardQty;
  final String? wasteRate;
  final String? cause;
  final String? parentGoodsId;
  final String? parentGoodsCode;
  final String? sourceDocNo;
  final String? remark;
  final String? inspectionStatus;
  final String? receivedBaseQty;
  final String? passedBaseQty;
  final String? stockedBaseQty;
  final String? pendingStockInBaseQty;
  final String? failedBaseQty;
  final String? atSupplierQty;
  final String? consumedQty;
  final String? supplierEndingQty;
  final String? boxQty;
  final String? parentGoodsName;

  String get displayGoods {
    final code = _nonBlank(goodsCode);
    final name = _nonBlank(goodsName);
    if (code == null) return name ?? '—';
    if (name == null) return code;
    return '$code · $name';
  }

  String get inspectionStatusLabel =>
      warehouseInspectionStatusLabel(inspectionStatus);

  factory WarehouseDocumentPhysicalItem.fromJson(Map<String, dynamic> json) {
    return WarehouseDocumentPhysicalItem(
      id: _requiredId(json['id']),
      lineNo: _integer(json['lineNumber'] ?? json['lineNo']),
      goodsId: _text(json['goodsId']),
      goodsCode: _text(json['goodsCode']),
      goodsName: _text(json['goodsName']),
      stockPlace: _text(json['stockPlace']),
      colorId: _text(json['colorId']),
      colorName: _text(json['colorName']),
      unitId: _text(json['unitId']),
      unitName: _text(json['unitName']),
      unitRate: _decimalText(json['unitRate']),
      qty: _decimalText(json['quantity'] ?? json['qty']),
      weight: _decimalText(json['weight']),
      returnedQty: _decimalText(
        json['returnedQuantity'] ?? json['returnedQty'],
      ),
      giftQty: _decimalText(json['giftQuantity'] ?? json['giftQty']),
      wastedQty: _decimalText(json['wastedQuantity'] ?? json['wastedQty']),
      endingQty: _decimalText(json['endingQuantity'] ?? json['endingQty']),
      standardQty: _decimalText(
        json['standardQuantity'] ?? json['standardQty'],
      ),
      wasteRate: _decimalText(json['wasteRate']),
      cause: _text(json['reason'] ?? json['cause']),
      parentGoodsId: _text(json['parentGoodsId']),
      parentGoodsCode: _text(json['parentGoodsCode']),
      sourceDocNo: _text(json['referenceDocumentNo'] ?? json['sourceDocNo']),
      remark: _text(json['remark']),
      inspectionStatus: _text(json['iqcStatus'] ?? json['inspectionStatus']),
      receivedBaseQty: _decimalText(json['receivedBaseQty']),
      passedBaseQty: _decimalText(
        json['iqcPassedBaseQuantity'] ?? json['passedBaseQty'],
      ),
      stockedBaseQty: _decimalText(
        json['iqcStockedBaseQuantity'] ?? json['stockedBaseQty'],
      ),
      pendingStockInBaseQty: _decimalText(
        json['iqcPendingStockInBaseQuantity'] ?? json['pendingStockInBaseQty'],
      ),
      failedBaseQty: _decimalText(
        json['iqcFailedBaseQuantity'] ?? json['failedBaseQty'],
      ),
      atSupplierQty: _decimalText(json['atSupplierQuantity']),
      consumedQty: _decimalText(json['consumedQuantity']),
      supplierEndingQty: _decimalText(json['supplierEndingQuantity']),
      boxQty: _decimalText(json['boxQuantity']),
      parentGoodsName: _text(json['parentGoodsName']),
    );
  }
}

String _requiredId(Object? value) {
  final id = _text(value);
  if (id == null) throw const FormatException('仓库历史记录缺少 id');
  return id;
}

String? _nonBlank(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

String? _decimalText(Object? value) => _text(value);

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

bool _boolean(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return switch (value?.toString().trim().toLowerCase()) {
    'true' || '1' || 'yes' => true,
    _ => false,
  };
}

List<Map<String, dynamic>> _objectList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map<Object?, Object?>>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}
