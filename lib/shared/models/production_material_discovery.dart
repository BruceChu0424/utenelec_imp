/// A warehouse request retains the exact work order and each physical source.
class ProductionMaterialDiscoveryDetail {
  ProductionMaterialDiscoveryDetail.fromJson(Map<String, dynamic> value)
    : requestId = value['requestId'] as String,
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
      drawDocIds = List<String>.from(value['drawDocIds'] as List? ?? []);

  final String requestId,
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
  final List<String> drawDocIds;
  bool get canConfigure => status == 'PENDING';
}
