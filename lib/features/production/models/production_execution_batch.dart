import 'production_draw_request.dart';

class ProductionExecutionBatchPreview {
  const ProductionExecutionBatchPreview({
    required this.segmentId,
    required this.expectedVersion,
    required this.originalQty,
    required this.maxReadyQty,
    required this.quantity,
    required this.remainingQty,
    required this.fingerprint,
    required this.summaries,
    this.planId,
    this.planNo,
    this.segmentCode,
    this.productCode,
    this.productName,
    this.productUnitName,
  });

  final String segmentId;
  final int expectedVersion;
  final String? planId;
  final String? planNo;
  final String? segmentCode;
  final String? productCode;
  final String? productName;
  final String? productUnitName;
  final double originalQty;
  final double maxReadyQty;
  final double quantity;
  final double remainingQty;
  final String fingerprint;
  final List<ProductionDrawRequestSummary> summaries;

  factory ProductionExecutionBatchPreview.fromJson(Map<String, dynamic> json) =>
      ProductionExecutionBatchPreview(
        segmentId: json['segmentId'] as String,
        expectedVersion: (json['expectedVersion'] as num).toInt(),
        originalQty: (json['originalQty'] as num).toDouble(),
        maxReadyQty: (json['maxReadyQty'] as num).toDouble(),
        quantity: (json['quantity'] as num).toDouble(),
        remainingQty: (json['remainingQty'] as num).toDouble(),
        fingerprint: json['fingerprint'] as String,
        summaries: [
          for (final row in json['summaries'] as List? ?? const [])
            ProductionDrawRequestSummary.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
        ],
        planId: json['planId'] as String?,
        planNo: json['planNo'] as String?,
        segmentCode: json['segmentCode'] as String?,
        productCode: json['productCode'] as String?,
        productName: json['productName'] as String?,
        productUnitName: json['productUnitName'] as String?,
      );
}

class ProductionExecutionBatchResult {
  const ProductionExecutionBatchResult({
    required this.batchSegmentId,
    required this.documentIds,
    required this.replayed,
    this.remainingSegmentId,
  });
  final String batchSegmentId;
  final String? remainingSegmentId;
  final List<String> documentIds;
  final bool replayed;

  factory ProductionExecutionBatchResult.fromJson(Map<String, dynamic> json) =>
      ProductionExecutionBatchResult(
        batchSegmentId: json['batchSegmentId'] as String,
        remainingSegmentId: json['remainingSegmentId'] as String?,
        documentIds: (json['documentIds'] as List? ?? const []).cast<String>(),
        replayed: json['replayed'] == true,
      );
}
