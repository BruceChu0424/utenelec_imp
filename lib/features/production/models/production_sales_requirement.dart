/// Sales instructions attached only to an authorized production source/task.
class ProductionSalesRequirement {
  const ProductionSalesRequirement({
    required this.salesOrderItemId,
    this.salesOrderNo,
    this.productName,
    this.orderRemark,
    this.itemRemark,
  });

  final String salesOrderItemId;
  final String? salesOrderNo;
  final String? productName;
  final String? orderRemark;
  final String? itemRemark;

  bool get hasContent =>
      orderRemark?.trim().isNotEmpty == true ||
      itemRemark?.trim().isNotEmpty == true;

  factory ProductionSalesRequirement.fromJson(Map<String, dynamic> json) =>
      ProductionSalesRequirement(
        salesOrderItemId: json['salesOrderItemId'] as String? ?? '',
        salesOrderNo: json['salesOrderNo'] as String?,
        productName: json['productName'] as String?,
        orderRemark: json['orderRemark'] as String?,
        itemRemark: json['itemRemark'] as String?,
      );

  static List<ProductionSalesRequirement> parseList(Object? raw) => raw is List
      ? raw
            .whereType<Map<Object?, Object?>>()
            .map(
              (row) => ProductionSalesRequirement.fromJson(
                Map<String, dynamic>.from(row),
              ),
            )
            .where((row) => row.hasContent)
            .toList(growable: false)
      : const [];
}
