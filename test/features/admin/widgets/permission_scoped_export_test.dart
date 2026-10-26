import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/permission_configuration.dart';
import 'package:uten_imp/features/admin/models/permission_template_archive.dart';
import 'package:uten_imp/features/admin/services/permission_archive_files.dart';

void main() {
  test(
    'department selection excludes employee, owner and baseline records',
    () {
      final export = _backup().select(
        PermissionConfigurationScope.department,
        sourceId: 'dept-a',
      );
      final restored = PermissionConfiguration.decode(export.encode());
      expect(restored.departments.single['name'], '采购部');
      expect(restored.users, isEmpty);
      expect(restored.owners, isEmpty);
      expect(restored.baseline, isEmpty);
      expect(restored.includesBaseline, isFalse);
      expect(restored.includesDataScopes, isFalse);
      expect(restored.json['format'], 'uten.permission-configuration');
      expect(restored.json.containsKey('scope'), isFalse);
    },
  );

  test(
    'employee export keeps only referenced owners and all raw rule fields',
    () {
      final restored = PermissionConfiguration.decode(
        _backup()
            .select(PermissionConfigurationScope.employee, sourceId: 'user-a')
            .encode(),
      );
      expect(restored.users.single['grants'], ['goods:edit']);
      expect(restored.users.single['storedOverrides'], [
        {'code': 'legacy:code', 'active': false, 'effect': 'REVOKE'},
      ]);
      expect(restored.owners.map((row) => row['key']), ['owner-a']);
      expect(restored.departments, isEmpty);
      expect(restored.baseline, isEmpty);
      expect(restored.includesBaseline, isFalse);
      expect(restored.includesDataScopes, isTrue);
    },
  );

  test('empty baseline remains an explicit baseline-only export', () {
    final source = _backup();
    source.json['baseline'] = <String>[];
    final restored = PermissionConfiguration.decode(
      source.select(PermissionConfigurationScope.baseline).encode(),
    );
    expect(restored.includesBaseline, isTrue);
    expect(restored.includesDataScopes, isFalse);
    expect(restored.users, isEmpty);
  });

  test(
    'missing selections and files exceeding their stated scope are rejected',
    () {
      expect(
        () => _backup().select(
          PermissionConfigurationScope.department,
          sourceId: 'missing',
        ),
        throwsFormatException,
      );
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'uten.permission-configuration-selection',
            'version': 1,
            'scope': 'department',
            'configuration': _backup().json,
          }),
        ),
      );
      expect(
        () => PermissionConfiguration.decode(bytes),
        throwsFormatException,
      );
    },
  );

  test(
    'template files round trip names, remarks and exact permission codes',
    () {
      final archive = PermissionTemplateArchive(
        name: '采购主管',
        description: '含导出权限',
        permissions: {'goods:view', 'purchase:export'},
      );
      final restored = PermissionTemplateArchive.decode(archive.encode());
      expect(restored.name, archive.name);
      expect(restored.description, archive.description);
      expect(restored.permissions, archive.permissions);
      expect(
        () => PermissionConfiguration.decode(archive.encode()),
        throwsFormatException,
      );
      expect(
        () => PermissionTemplateArchive.decode(_backup().encode()),
        throwsFormatException,
      );
      final bad =
          jsonDecode(utf8.decode(archive.encode())) as Map<String, dynamic>;
      bad['permissions'] = [''];
      expect(
        () => PermissionTemplateArchive.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(bad))),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'archive names carry clear scope and safe names while preserving extension',
    () {
      expect(permissionArchiveFilename('全部设置'), '权限-全部设置.json');
      expect(permissionArchiveFilename('模板', ' 采购/主管 '), '权限-模板-采购_主管.json');
      expect(permissionArchiveFilename('部门', '研发部'), '权限-部门-研发部.json');
      final long = permissionArchiveFilename('员工', '甲' * 220);
      expect(long.length, lessThanOrEqualTo(180));
      expect(long.endsWith('.json'), isTrue);
    },
  );
}

PermissionConfiguration _backup() => PermissionConfiguration.fromJson({
  'format': 'uten.permission-configuration',
  'version': 1,
  'baseline': ['notice:read'],
  'departments': [
    {
      'key': 'dept-a',
      'code': 'D1',
      'name': '采购部',
      'permissions': ['goods:view'],
    },
    {
      'key': 'dept-b',
      'code': 'D2',
      'name': '财务部',
      'permissions': ['finance:view'],
    },
  ],
  'users': [
    for (final id in ['a', 'b'])
      {
        'key': 'user-$id',
        'employeeCode': id,
        'employeeName': '员工$id',
        'loginAccount': id,
        'grants': ['goods:edit'],
        'revokes': <String>[],
        'effective': ['goods:view'],
        'delegationPermissions': <String>[],
        'dataScopes': {
          'client': ['owner-$id'],
        },
        'storedOverrides': [
          {'code': 'legacy:code', 'active': false, 'effect': 'REVOKE'},
        ],
      },
  ],
  'scopeOwners': [
    for (final id in ['a', 'b'])
      {'key': 'owner-$id', 'code': id, 'name': '归属$id'},
  ],
});
