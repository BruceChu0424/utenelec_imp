import 'dart:convert';
import 'dart:typed_data';

const permissionConfigurationMaxBytes = 16 * 1024 * 1024;

enum PermissionConfigurationScope { employee, department, baseline }

/// Portable permission codes and source keys. UUIDs are resolved only by the
/// target server and explicitly reviewed before any authorization is written.
class PermissionConfiguration {
  PermissionConfiguration._(this.json, {this.exportScope});

  final Map<String, dynamic> json;
  final PermissionConfigurationScope? exportScope;

  bool get includesBaseline =>
      exportScope == null ||
      exportScope == PermissionConfigurationScope.baseline;
  bool get includesDataScopes =>
      exportScope == null ||
      exportScope == PermissionConfigurationScope.employee;

  /// A portable selection retains the existing server backup contract. Scope is
  /// carried outside [json], so it cannot become an unknown server DTO field.
  PermissionConfiguration select(
    PermissionConfigurationScope scope, {
    String? sourceId,
  }) {
    final selectedDepartments = scope == PermissionConfigurationScope.department
        ? departments.where((row) => row['key'] == sourceId).toList()
        : <Map<String, dynamic>>[];
    final selectedUsers = scope == PermissionConfigurationScope.employee
        ? users.where((row) => row['key'] == sourceId).toList()
        : <Map<String, dynamic>>[];
    if ((scope == PermissionConfigurationScope.department &&
            selectedDepartments.length != 1) ||
        (scope == PermissionConfigurationScope.employee &&
            selectedUsers.length != 1)) {
      throw const FormatException('当前部门或员工已变化，请刷新后重新导出');
    }
    final ownerKeys = <String>{
      for (final user in selectedUsers)
        for (final values
            in (user['dataScopes'] as Map<String, dynamic>).values)
          ...List<String>.from(values as List),
    };
    final selected = PermissionConfiguration.fromJson({
      ...json,
      'baseline': scope == PermissionConfigurationScope.baseline
          ? baseline
          : <String>[],
      'departments': selectedDepartments,
      'users': selectedUsers,
      'scopeOwners': owners
          .where((row) => ownerKeys.contains(row['key']))
          .toList(),
    });
    return PermissionConfiguration._(selected.json, exportScope: scope);
  }

  factory PermissionConfiguration.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'uten.permission-configuration' ||
        json['version'] != 1) {
      throw const FormatException('请选择本系统导出的权限设置文件（版本 1）');
    }
    for (final field in ['departments', 'users', 'scopeOwners', 'baseline']) {
      if (json[field] is! List) {
        throw FormatException('权限文件缺少有效的 $field 内容');
      }
    }
    void text(Map<String, dynamic> row, String field) {
      if (row[field] is! String ||
          (row[field] as String).trim().isEmpty ||
          (row[field] as String).length > 256) {
        throw FormatException('权限文件中的 $field 缺失或无效');
      }
    }

    void codes(Object? value) {
      if (value is! List ||
          value.length > 3000 ||
          value.any((item) => item is! String || item.length > 256)) {
        throw const FormatException('权限文件中的权限或人员列表格式不正确');
      }
    }

    codes(json['baseline']);
    for (final field in ['departments', 'users', 'scopeOwners']) {
      final sourceKeys = <String>{};
      if ((json[field] as List).length >
          (field == 'scopeOwners' ? 5000 : 1000)) {
        throw const FormatException('权限文件中的部门或人员数量超过上限');
      }
      for (final row in _objects(json[field])) {
        text(row, 'key');
        if (!sourceKeys.add(row['key'] as String)) {
          throw const FormatException('权限文件包含重复的来源标识');
        }
        if (field == 'users') {
          if (row['restorable'] != null && row['restorable'] is! bool) {
            throw const FormatException('权限文件中的账号恢复状态格式不正确');
          }
          for (final name in [
            'accountStatus',
            'employeeStatus',
            'restoreReason',
          ]) {
            if (row[name] != null &&
                (row[name] is! String || (row[name] as String).length > 512)) {
              throw const FormatException('权限文件中的账号状态说明格式不正确');
            }
          }
          for (final name in ['employeeCode', 'employeeName', 'loginAccount']) {
            text(row, name);
          }
          for (final name in [
            'grants',
            'revokes',
            'effective',
            'delegationPermissions',
          ]) {
            codes(row[name]);
          }
          if (row['dataScopes'] is! Map<String, dynamic>) {
            throw const FormatException('权限文件中的可查看数据范围格式不正确');
          }
          for (final value
              in (row['dataScopes'] as Map<String, dynamic>).values) {
            codes(value);
          }
        } else {
          text(row, 'code');
          text(row, 'name');
          if (field == 'departments') codes(row['permissions']);
        }
      }
    }
    return PermissionConfiguration._(json);
  }

  factory PermissionConfiguration.decode(Uint8List bytes) {
    if (bytes.length > permissionConfigurationMaxBytes) {
      throw const FormatException('权限文件不能超过 16 MB');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('权限文件格式不正确');
    }
    if (decoded['format'] == 'uten.permission-configuration-selection') {
      if (decoded['version'] != 1 ||
          decoded['configuration'] is! Map<String, dynamic>) {
        throw const FormatException('权限范围文件格式或版本不正确');
      }
      final scope = PermissionConfigurationScope.values
          .where((item) => item.name == decoded['scope'])
          .firstOrNull;
      if (scope == null) throw const FormatException('权限范围文件缺少有效范围');
      final configuration = PermissionConfiguration.fromJson(
        decoded['configuration'] as Map<String, dynamic>,
      );
      final valid = switch (scope) {
        PermissionConfigurationScope.employee =>
          configuration.users.length == 1 &&
              configuration.departments.isEmpty &&
              configuration.baseline.isEmpty,
        PermissionConfigurationScope.department =>
          configuration.departments.length == 1 &&
              configuration.users.isEmpty &&
              configuration.owners.isEmpty &&
              configuration.baseline.isEmpty,
        PermissionConfigurationScope.baseline =>
          configuration.departments.isEmpty &&
              configuration.users.isEmpty &&
              configuration.owners.isEmpty,
      };
      if (!valid) throw const FormatException('权限文件内容超出声明范围，不能导入');
      return PermissionConfiguration._(configuration.json, exportScope: scope);
    }
    return PermissionConfiguration.fromJson(decoded);
  }

  Uint8List encode() {
    final document = exportScope == null
        ? json
        : <String, dynamic>{
            'format': 'uten.permission-configuration-selection',
            'version': 1,
            'scope': exportScope!.name,
            'configuration': json,
          };
    final readable = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(document)),
    );
    if (readable.length <= permissionConfigurationMaxBytes) return readable;
    // Whitespace must not turn a valid server export into an unimportable file.
    final compact = Uint8List.fromList(utf8.encode(jsonEncode(document)));
    if (compact.length > permissionConfigurationMaxBytes) {
      throw const FormatException('权限备份超过 16 MB，暂时无法保存为可导入文件');
    }
    return compact;
  }

  List<Map<String, dynamic>> get departments => _objects(json['departments']);
  List<Map<String, dynamic>> get users => _objects(json['users']);
  List<Map<String, dynamic>> get owners => _objects(json['scopeOwners']);
  List<String> get baseline => _strings(json['baseline']);
}

class PermissionCopySnapshot {
  const PermissionCopySnapshot({
    required this.sourceUserId,
    required this.sourceLabel,
    required this.fingerprint,
    required this.permissions,
  });

  factory PermissionCopySnapshot.fromJson(Map<String, dynamic> json) =>
      PermissionCopySnapshot(
        sourceUserId: json['sourceUserId'] as String,
        sourceLabel: json['sourceLabel'] as String,
        fingerprint: json['fingerprint'] as String,
        permissions: _strings(json['permissions']),
      );

  final String sourceUserId;
  final String sourceLabel;
  final String fingerprint;
  final List<String> permissions;

  Map<String, dynamic> toRequest() => {
    'sourceUserId': sourceUserId,
    'sourceFingerprint': fingerprint,
  };
}

class PermissionTransferPreview {
  PermissionTransferPreview.fromJson(Map<String, dynamic> json)
    : fingerprint = json['fingerprint'] as String,
      canApply = json['canApply'] == true,
      issues = _strings(json['issues']),
      changes = _objects(json['changes']),
      sensitiveAdditions = _objects(json['sensitiveAdditions']),
      suggestions = _objects(json['suggestions']),
      pinnedBaselineAdditions = _strings(json['pinnedBaselineAdditions']),
      notes = _strings(json['notes']);

  final String fingerprint;
  final bool canApply;
  final List<String> issues;
  final List<Map<String, dynamic>> changes;
  final List<Map<String, dynamic>> sensitiveAdditions;
  final List<Map<String, dynamic>> suggestions;
  final List<String> pinnedBaselineAdditions;
  final List<String> notes;

  int get addedCount => changes.fold(
    0,
    (count, change) => count + _strings(change['added']).length,
  );
  int get removedCount => changes.fold(
    0,
    (count, change) => count + _strings(change['removed']).length,
  );

  bool confirmedBy(Set<String> confirmations) =>
      sensitiveAdditions.every((item) => confirmations.contains(item['key']));
}

List<Map<String, dynamic>> _objects(dynamic value) =>
    (value as List? ?? const [])
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('权限文件包含无效项目');
          }
          return item;
        })
        .toList(growable: false);

List<String> _strings(dynamic value) => (value as List? ?? const [])
    .map((item) => item as String)
    .toList(growable: false);
