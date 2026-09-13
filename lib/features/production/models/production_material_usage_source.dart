class ProductionMaterialUsageSource {
  const ProductionMaterialUsageSource({
    required this.executionSegmentId,
    required this.executionSegmentCode,
    required this.shared,
    required this.canOpen,
    required this.canSettle,
  });
  final String executionSegmentId;
  final String executionSegmentCode;
  final bool shared;
  final bool canOpen;
  final bool canSettle;

  factory ProductionMaterialUsageSource.fromJson(Map<String, dynamic> json) =>
      ProductionMaterialUsageSource(
        executionSegmentId: json['executionSegmentId'] as String,
        executionSegmentCode:
            json['executionSegmentCode'] as String? ?? '原领料任务',
        shared: json['shared'] == true,
        canOpen: json['canOpen'] == true,
        canSettle: json['canSettle'] == true,
      );
}
