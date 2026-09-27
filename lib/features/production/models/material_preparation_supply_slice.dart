/// A server-proven public supply identity. The key is opaque and reveals no
/// document identifiers; eligibility is specific to the receiving source row.
class MaterialPreparationSupplySlice {
  const MaterialPreparationSupplySlice({
    required this.key,
    required this.availableQty,
    required this.adoptable,
  });
  final String key;
  final double availableQty;
  final bool adoptable;

  factory MaterialPreparationSupplySlice.fromJson(Map<String, dynamic> json) =>
      MaterialPreparationSupplySlice(
        key: json['key']?.toString() ?? '',
        availableQty: double.tryParse('${json['availableQty']}') ?? 0,
        adoptable: json['adoptable'] == true,
      );
}
