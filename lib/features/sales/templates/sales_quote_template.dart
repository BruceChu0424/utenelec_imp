class SalesQuoteTemplate {
  const SalesQuoteTemplate({
    required this.id,
    required this.name,
    this.version = 1,
    this.useCount = 0,
    this.sourceName,
    this.lastUsedAt,
  });

  factory SalesQuoteTemplate.fromJson(Map<String, dynamic> json) =>
      SalesQuoteTemplate(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        version: (json['version'] as num?)?.toInt() ?? 1,
        useCount: (json['useCount'] as num?)?.toInt() ?? 0,
        sourceName: json['sourceName']?.toString(),
        lastUsedAt: DateTime.tryParse(json['lastUsedAt']?.toString() ?? ''),
      );

  final String id;
  final String name;
  final int version;
  final int useCount;
  final String? sourceName;
  final DateTime? lastUsedAt;
}
