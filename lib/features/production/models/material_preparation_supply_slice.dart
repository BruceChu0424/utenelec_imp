import 'production_exact_quantity.dart';

/// A server-proven public supply identity. The key is opaque and reveals no
/// document identifiers; eligibility is specific to the receiving source row.
class MaterialPreparationSupplySlice {
  const MaterialPreparationSupplySlice({
    required this.key,
    required this.availableQty,
    this.availableQtyExact,
    required this.adoptable,
  });
  final String key;
  final double availableQty;
  final String? availableQtyExact;
  String? get availableQtyText =>
      productionExactQuantityText(availableQtyExact ?? availableQty);
  final bool adoptable;

  factory MaterialPreparationSupplySlice.fromJson(Map<String, dynamic> json) =>
      MaterialPreparationSupplySlice(
        key: json['key']?.toString() ?? '',
        availableQty: double.tryParse('${json['availableQty']}') ?? 0,
        availableQtyExact: json['availableQtyExact'] is String
            ? json['availableQtyExact'] as String
            : json['availableQty'] is String
            ? json['availableQty'] as String
            : null,
        adoptable: json['adoptable'] == true,
      );
}
