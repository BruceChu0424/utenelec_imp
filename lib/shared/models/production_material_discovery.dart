class ProductionMaterialDiscoveryDrawDocument {
  const ProductionMaterialDiscoveryDrawDocument({
    required this.id,
    required this.billNo,
    this.warehouseId,
    this.warehouseName = '',
  });

  factory ProductionMaterialDiscoveryDrawDocument.fromJson(
    Map<String, dynamic> value,
  ) => ProductionMaterialDiscoveryDrawDocument(
    id: value['id'] as String,
    billNo: value['billNo'] as String? ?? '',
    warehouseId: value['warehouseId'] as String?,
    warehouseName: value['warehouseName'] as String? ?? '',
  );

  final String id;
  final String billNo;
  final String? warehouseId;
  final String warehouseName;
}

/// A warehouse request retains the exact work order and each physical source.
class ProductionMaterialDiscoveryDetail {
  ProductionMaterialDiscoveryDetail.fromJson(Map<String, dynamic> value)
    : requestId = value['requestId'] as String,
      requestNo = value['requestNo'] as String? ?? '',
      segmentId = value['segmentId'] as String,
      segmentCode = value['segmentCode'] as String? ?? '',
      planNo = value['planNo'] as String? ?? '',
      productCode = value['productCode'] as String? ?? '',
      productName = value['productName'] as String? ?? '',
      plannedQty = (value['plannedQty'] as num?)?.toDouble() ?? 0,
      productUnitName = value['productUnitName'] as String? ?? '',
      workshopName = value['workshopName'] as String? ?? '',
      status = value['status'] as String,
      version = (value['version'] as num).toInt(),
      items = [
        for (final row in value['items'] as List? ?? [])
          Map<String, dynamic>.from(row as Map),
      ],
      suggestedItems = [
        for (final row in value['suggestedItems'] as List? ?? [])
          Map<String, dynamic>.from(row as Map),
      ],
      drawDocIds = List<String>.from(value['drawDocIds'] as List? ?? []),
      drawDocuments = [
        for (final row in value['drawDocuments'] as List? ?? [])
          ProductionMaterialDiscoveryDrawDocument.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
      ];

  final String requestId,
      requestNo,
      segmentId,
      segmentCode,
      planNo,
      productCode,
      productName,
      productUnitName,
      workshopName,
      status;
  final double plannedQty;
  final int version;
  final List<Map<String, dynamic>> items;

  /// Workshop suggestions are request facts, not configured or issued stock.
  final List<Map<String, dynamic>> suggestedItems;
  final List<String> drawDocIds;
  final List<ProductionMaterialDiscoveryDrawDocument> drawDocuments;
  bool get canConfigure => status == 'PENDING';
}
