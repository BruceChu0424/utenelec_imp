class PermissionTemplate {
  const PermissionTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.permissions,
    required this.version,
  });
  factory PermissionTemplate.fromJson(Map<String, dynamic> json) =>
      PermissionTemplate(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        permissions: (json['permissions'] as List).cast<String>(),
        version: (json['version'] as num).toInt(),
      );
  final String id;
  final String name;
  final String description;
  final List<String> permissions;
  final int version;

  @override
  bool operator ==(Object other) =>
      other is PermissionTemplate && other.id == id && other.version == version;
  @override
  int get hashCode => Object.hash(id, version);
}
