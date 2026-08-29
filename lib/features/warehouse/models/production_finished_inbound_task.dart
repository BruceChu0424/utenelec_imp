class ProductionFinishedInboundTask {
  const ProductionFinishedInboundTask({
    required this.documentId,
    required this.documentNo,
    required this.documentDate,
    required this.lineCount,
    required this.pendingQty,
    required this.createdAt,
    required this.residualTask,
    this.warehouseId,
    this.warehouseName,
    this.planId,
    this.planNo,
    this.reportNos,
    this.goodsSummary,
  });

  final String documentId;
  final String documentNo;
  final DateTime documentDate;
  final String? warehouseId;
  final String? warehouseName;
  final String? planId;
  final String? planNo;
  final String? reportNos;
  final String? goodsSummary;
  final int lineCount;
  final double pendingQty;
  final DateTime createdAt;
  final bool residualTask;

  factory ProductionFinishedInboundTask.fromJson(Map<String, dynamic> json) {
    DateTime parseDate(String key) =>
        DateTime.tryParse(json[key]?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);

    return ProductionFinishedInboundTask(
      documentId: json['documentId'] as String? ?? '',
      documentNo: json['documentNo'] as String? ?? '',
      documentDate: parseDate('documentDate'),
      warehouseId: json['warehouseId'] as String?,
      warehouseName: json['warehouseName'] as String?,
      planId: json['planId'] as String?,
      planNo: json['planNo'] as String?,
      reportNos: json['reportNos'] as String?,
      goodsSummary: json['goodsSummary'] as String?,
      lineCount: (json['lineCount'] as num?)?.toInt() ?? 0,
      pendingQty: (json['pendingQty'] as num?)?.toDouble() ?? 0,
      createdAt: parseDate('createdAt'),
      residualTask: json['residualTask'] as bool? ?? false,
    );
  }
}
