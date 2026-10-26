import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/admin/models/permission_configuration.dart';
import 'package:uten_imp/features/admin/models/permission_template.dart';
import 'package:uten_imp/features/admin/models/permission_template_archive.dart';
import 'package:uten_imp/features/admin/services/permission_workspace_archive.dart';
import 'package:uten_imp/features/admin/repositories/permission_configuration_repository.dart';
import 'package:uten_imp/features/admin/repositories/permission_template_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_transfer_actions.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

void main() {
  test(
    'complete ZIP preserves the server JSON and every portable template',
    () async {
      final configuration = _configuration();
      final templates = [
        _template('one', '采购主管', ['goods:view', 'goods:edit']),
        _template('two', '财务岗位', ['finance:view']),
      ];
      final archive = ZipDecoder().decodeBytes(
        await buildPermissionWorkspaceArchive(
          configuration: configuration,
          templates: templates,
          stillCurrent: () => true,
        ),
      );
      expect(permissionWorkspaceArchiveFilename, '权限-全部设置.zip');
      expect(archive.files, hasLength(templates.length + 2));
      final restored = PermissionConfiguration.decode(
        _bytes(archive.findFile('权限-全部设置.json')!),
      );
      expect(restored.json, configuration.json);
      expect(restored.exportScope, isNull);
      for (final template in templates) {
        final file = archive.findFile('模板/权限-模板-${template.name}.json');
        expect(file, isNotNull);
        final saved = PermissionTemplateArchive.decode(_bytes(file!));
        expect(saved.name, template.name);
        expect(saved.description, template.description);
        expect(saved.permissions, template.permissions.toSet());
      }
      final instructions = utf8.decode(_bytes(archive.findFile('导入说明.txt')!));
      expect(instructions, contains('请先解压 ZIP'));
      expect(instructions, contains('导入权限设置'));
      expect(instructions, contains('导入模板'));
    },
  );

  test(
    'sanitized and case-insensitive duplicate names never replace templates',
    () async {
      final templates = [
        for (final (index, name) in [
          '研发/主管',
          '研发:主管',
          '研发_主管-2',
          '研发_主管',
          'Manager',
          'manager',
        ].indexed)
          _template('$index', name, ['fixture:$index']),
      ];
      final archive = ZipDecoder().decodeBytes(
        await buildPermissionWorkspaceArchive(
          configuration: _configuration(),
          templates: templates,
          stillCurrent: () => true,
        ),
      );
      final files = archive.files
          .where((file) => file.name.startsWith('模板/'))
          .toList();
      expect(files, hasLength(templates.length));
      expect(
        files.map((file) => file.name.toLowerCase()).toSet(),
        hasLength(templates.length),
      );
      expect(
        files.every((file) => !file.name.substring('模板/'.length).contains('/')),
        isTrue,
      );
      final restored = files
          .map((file) => PermissionTemplateArchive.decode(_bytes(file)))
          .toList();
      expect(
        restored.map((item) => item.name).toSet(),
        templates.map((item) => item.name).toSet(),
      );
      expect(
        restored.expand((item) => item.permissions).toSet(),
        templates.expand((item) => item.permissions).toSet(),
      );
    },
  );

  test(
    'an empty template library still exports the complete configuration',
    () async {
      final archive = ZipDecoder().decodeBytes(
        await buildPermissionWorkspaceArchive(
          configuration: _configuration(),
          templates: const [],
          stillCurrent: () => true,
        ),
      );
      expect(archive.findFile('权限-全部设置.json'), isNotNull);
      expect(
        archive.files.where((file) => file.name.startsWith('模板/')),
        isEmpty,
      );
    },
  );

  test(
    'a partial configuration cannot masquerade as a complete export',
    () async {
      await expectLater(
        buildPermissionWorkspaceArchive(
          configuration: _configuration().select(
            PermissionConfigurationScope.baseline,
          ),
          templates: const [],
          stillCurrent: () => true,
        ),
        throwsFormatException,
      );
    },
  );

  test('an expired owner cannot publish a complete archive', () async {
    await expectLater(
      buildPermissionWorkspaceArchive(
        configuration: _configuration(),
        templates: [
          _template('one', '采购岗位', ['goods:view']),
        ],
        stillCurrent: () => false,
      ),
      throwsA(isA<UiWorkCancelled>()),
    );
  });

  test(
    'a ZIP that exceeds its memory budget fails without a partial result',
    () async {
      await expectLater(
        buildPermissionWorkspaceArchive(
          configuration: _configuration(),
          templates: [
            _template('one', '采购岗位', ['goods:view']),
          ],
          stillCurrent: () => true,
          maximumBytes: 512,
        ),
        throwsFormatException,
      );
    },
  );

  for (final failTemplates in [false, true]) {
    testWidgets(
      'complete-export button requires both reads (${failTemplates ? 'templates' : 'configuration'} failure)',
      (tester) async {
        final configuration = _ConfigurationRepository(fail: !failTemplates);
        final templates = _TemplateRepository(fail: failTemplates);
        final api = ApiClient(
          Dio(BaseOptions(baseUrl: 'https://example.test/api')),
        );
        final container = ProviderContainer(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            isSuperAdminProvider.overrideWithValue(true),
            currentPermissionsProvider.overrideWithValue({
              Perm.authorizationManage,
            }),
            permissionConfigurationRepositoryProvider.overrideWithValue(
              configuration,
            ),
            permissionTemplateRepositoryProvider.overrideWithValue(templates),
            sensitiveReadBoundaryProvider.overrideWith(
              (ref) => SensitiveReadBoundary(
                identity: const AuthenticatedScope(userId: 'admin'),
                api: api,
                permissions: {Perm.authorizationManage},
                superAdmin: true,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: AdminPermissionArchiveActions()),
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('export-permission-configuration')),
        );
        await tester.pumpAndSettle();
        expect(configuration.exports, 1);
        expect(templates.reads, 1);
        expect(
          container.read(appNotificationProvider).single.message,
          contains(failTemplates ? '模板列表读取失败' : '权限设置读取失败'),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Uint8List _bytes(ArchiveFile file) => Uint8List.fromList(file.content);

PermissionTemplate _template(String id, String name, List<String> codes) =>
    PermissionTemplate(
      id: id,
      name: name,
      description: '岗位备注：$name',
      permissions: codes,
      version: 3,
    );

PermissionConfiguration _configuration() => PermissionConfiguration.fromJson({
  'format': 'uten.permission-configuration',
  'version': 1,
  'exportedAt': '2026-10-26T12:00:00Z',
  'baseline': ['notice:read'],
  'departments': [
    {
      'key': 'dept-a',
      'code': 'D1',
      'name': '采购部',
      'permissions': ['goods:view'],
    },
  ],
  'users': [
    {
      'key': 'user-a',
      'employeeCode': 'E1',
      'employeeName': '员工甲',
      'loginAccount': 'employee-a',
      'grants': ['goods:edit'],
      'revokes': ['goods:delete'],
      'effective': ['goods:view', 'goods:edit'],
      'delegationPermissions': <String>[],
      'dataScopes': {
        'client': ['owner-a'],
      },
      'storedOverrides': [
        {'code': 'legacy:code', 'active': false, 'effect': 'REVOKE'},
      ],
    },
  ],
  'scopeOwners': [
    {'key': 'owner-a', 'code': 'E2', 'name': '数据归属甲'},
  ],
});

class _ConfigurationRepository extends Fake
    implements PermissionConfigurationRepository {
  _ConfigurationRepository({required this.fail});
  final bool fail;
  int exports = 0;
  @override
  Future<PermissionConfiguration> export() async {
    exports++;
    if (fail) throw const FormatException('权限设置读取失败');
    return _configuration();
  }
}

class _TemplateRepository extends PermissionTemplateRepository {
  _TemplateRepository({required this.fail}) : super(ApiClient(Dio()));
  final bool fail;
  int reads = 0;
  @override
  Future<List<PermissionTemplate>> list() async {
    reads++;
    if (fail) throw const FormatException('模板列表读取失败');
    return [
      _template('one', '采购岗位', ['goods:view']),
    ];
  }
}
