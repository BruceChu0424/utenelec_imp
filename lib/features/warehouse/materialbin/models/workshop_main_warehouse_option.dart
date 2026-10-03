/// Setup-only placement metadata. No balances, valuation, keepers or warehouse administration fields.
class WmMainWarehouseOption {
  const WmMainWarehouseOption({
    required this.id,
    required this.name,
    this.code,
  });

  final String id;
  final String name;
  final String? code;

  factory WmMainWarehouseOption.fromJson(Map<String, dynamic> json) =>
      WmMainWarehouseOption(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['code'] as String? ?? '',
        code: json['code'] as String?,
      );
}
