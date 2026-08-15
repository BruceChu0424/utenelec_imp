class ReferenceMethodOption {
  const ReferenceMethodOption({
    required this.id,
    required this.code,
    required this.name,
    this.legacyId,
    this.legacyCode,
    this.legacyNameConfirmed = true,
  });

  final String id;
  final int? legacyId;
  final String code;
  final String? legacyCode;
  final String name;
  final bool legacyNameConfirmed;

  factory ReferenceMethodOption.fromJson(Map<String, dynamic> json) =>
      ReferenceMethodOption(
        id: json['id'] as String,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        code: json['code'] as String? ?? '',
        legacyCode: json['legacyCode'] as String?,
        name: json['name'] as String? ?? '',
        legacyNameConfirmed: json['legacyNameConfirmed'] as bool? ?? false,
      );
}
