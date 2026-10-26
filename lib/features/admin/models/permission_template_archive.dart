import 'dart:convert';
import 'dart:typed_data';

import 'permission_configuration.dart';
import 'permission_template.dart';

/// Template files are portable snapshots, never employee authorization writes.
class PermissionTemplateArchive {
  PermissionTemplateArchive({
    required this.name,
    required this.description,
    required Set<String> permissions,
  }) : permissions = Set.unmodifiable(permissions);

  factory PermissionTemplateArchive.fromTemplate(PermissionTemplate template) =>
      PermissionTemplateArchive(
        name: template.name,
        description: template.description,
        permissions: template.permissions.toSet(),
      );

  final String name;
  final String description;
  final Set<String> permissions;

  factory PermissionTemplateArchive.decode(Uint8List bytes) {
    if (bytes.length > permissionConfigurationMaxBytes) {
      throw const FormatException('权限文件不能超过 16 MB');
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic> ||
        json['format'] != 'uten.permission-template' ||
        json['version'] != 1) {
      throw const FormatException('请选择本系统导出的权限模板文件（版本 1）');
    }
    final name = json['name'];
    final description = json['description'];
    final permissions = json['permissions'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 80 ||
        description is! String ||
        description.length > 1000 ||
        permissions is! List ||
        permissions.length > 3000 ||
        permissions.any(
          (code) => code is! String || code.trim().isEmpty || code.length > 256,
        )) {
      throw const FormatException('模板名称、备注或权限列表格式不正确');
    }
    return PermissionTemplateArchive(
      name: name.trim(),
      description: description,
      permissions: permissions.cast<String>().toSet(),
    );
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'uten.permission-template',
        'version': 1,
        'name': name,
        'description': description,
        'permissions': permissions.toList()..sort(),
      }),
    ),
  );
}
