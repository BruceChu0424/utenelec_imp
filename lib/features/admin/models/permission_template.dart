class PermissionTemplate {
  const PermissionTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.permissions,
    required this.version,
    this.appliedCount = 0,
    this.appliedUserCount = 0,
    this.appliedDepartmentCount = 0,
  });
  factory PermissionTemplate.fromJson(Map<String, dynamic> json) =>
      PermissionTemplate(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        permissions: (json['permissions'] as List).cast<String>(),
        version: (json['version'] as num).toInt(),
        appliedCount: (json['appliedCount'] as num?)?.toInt() ?? 0,
        appliedUserCount:
            (json['appliedUserCount'] as num?)?.toInt() ??
            (json['appliedCount'] as num?)?.toInt() ??
            0,
        appliedDepartmentCount:
            (json['appliedDepartmentCount'] as num?)?.toInt() ?? 0,
      );
  final String id;
  final String name;
  final String description;
  final List<String> permissions;
  final int version;

  /// 最近应用该模板的账号数；模板保存后会差量同步到这些账号（个人收回优先）。
  final int appliedCount;
  final int appliedUserCount;
  final int appliedDepartmentCount;

  @override
  bool operator ==(Object other) =>
      other is PermissionTemplate && other.id == id && other.version == version;
  @override
  int get hashCode => Object.hash(id, version);
}

class PermissionTemplateBinding {
  const PermissionTemplateBinding({
    required this.kind,
    required this.targetId,
    required this.templateId,
    required this.templateName,
    required this.templateVersion,
    this.legacySnapshot = false,
  });
  factory PermissionTemplateBinding.fromJson(Map<String, dynamic> json) =>
      PermissionTemplateBinding(
        kind: json['kind'] as String,
        targetId: json['targetId'] as String,
        templateId: json['templateId'] as String,
        templateName: json['templateName'] as String,
        templateVersion: (json['templateVersion'] as num).toInt(),
        legacySnapshot: json['legacySnapshot'] == true,
      );
  Map<String, dynamic> toExpectedJson() => {
    'kind': kind,
    'targetId': targetId,
    'templateId': templateId,
    'templateVersion': templateVersion,
    'legacySnapshot': legacySnapshot,
  };
  final String kind;
  final String targetId;
  final String templateId;
  final String templateName;
  final int templateVersion;
  final bool legacySnapshot;
}
