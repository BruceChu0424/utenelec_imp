/// A server-authored quantity attribution to one original product, or public stock.
class SubcontractTaskSource {
  const SubcontractTaskSource({
    this.analysisItemId,
    required this.sourceType,
    required this.sourceNo,
    this.sourceLineNo,
    required this.productCode,
    required this.productName,
    required this.materialCode,
    required this.materialName,
    required this.quantity,
    required this.unitName,
  });

  final String? analysisItemId;
  final String sourceType;
  final String sourceNo;
  final int? sourceLineNo;
  final String productCode;
  final String productName;
  final String materialCode;
  final String materialName;
  final num quantity;
  final String unitName;

  bool get isPublicStock => sourceType == 'PUBLIC_STOCK';
  String get productLabel => '$productCode $productName'.trim();
  String get materialLabel => '$materialCode $materialName'.trim();

  factory SubcontractTaskSource.fromJson(Map<String, dynamic> json) =>
      SubcontractTaskSource(
        analysisItemId: json['analysisItemId'] as String?,
        sourceType: json['sourceType'] as String? ?? '',
        sourceNo: json['sourceNo'] as String? ?? '',
        sourceLineNo: (json['sourceLineNo'] as num?)?.toInt(),
        productCode: json['productCode'] as String? ?? '',
        productName: json['productName'] as String? ?? '',
        materialCode: json['materialCode'] as String? ?? '',
        materialName: json['materialName'] as String? ?? '',
        quantity: json['quantity'] as num? ?? 0,
        unitName: json['unitName'] as String? ?? '',
      );

  static List<SubcontractTaskSource> listFromJson(Object? value) =>
      value is List
      ? value
            .map(
              (item) => SubcontractTaskSource.fromJson(
                (item as Map).cast<String, dynamic>(),
              ),
            )
            .toList(growable: false)
      : const [];
}
