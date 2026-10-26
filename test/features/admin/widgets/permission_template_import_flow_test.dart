import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/models/permission_template.dart';
import 'package:uten_imp/features/admin/models/permission_template_archive.dart';
import 'package:uten_imp/features/admin/providers/admin_providers.dart';
import 'package:uten_imp/features/admin/repositories/permission_template_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_templates.dart';
import 'package:uten_imp/features/admin/widgets/permission_catalog_browser.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

final _identity = StateProvider((ref) => 'admin');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FilePicker.platform = _Picker(() async => null);
  });
  tearDown(() => FilePicker.platform = _Picker(() async => null));

  testWidgets(
    'template import pre-fills metadata and opens the complete imported permission selection',
    (tester) async {
      final repository = _Repository();
      final picker = _Picker(() async => _file());
      FilePicker.platform = picker;
      await _mount(tester, repository);
      await tester.tap(
        find.byKey(const ValueKey('import-permission-template')),
      );
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(find.byType(UtenAlertDialog), findsOneWidget);
      expect(
        tester
            .widget<TextField>(_field('permission-template-name'))
            .controller!
            .text,
        '仓库主管',
      );
      expect(
        tester
            .widget<TextField>(_field('permission-template-description'))
            .controller!
            .text,
        '查看和导出货品',
      );
      expect(
        find.descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.byType(PermissionCatalogBrowser),
        ),
        findsNothing,
      );
      expect(repository.writes, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('create-permission-template')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(repository.writes.single.name, '仓库主管');
      expect(repository.writes.single.description, '查看和导出货品');
      expect(repository.writes.single.permissions.toSet(), {
        'goods:view',
        'goods:export',
      });
      expect(find.byType(PermissionCatalogBrowser), findsOneWidget);
      expect(
        find.byKey(const ValueKey('save-permission-template')),
        findsOneWidget,
      );
      await _expandCatalog(tester);
      for (final code in ['goods:view', 'goods:export']) {
        expect(
          tester
              .widget<Switch>(find.byKey(ValueKey('template-code-$code')))
              .value,
          isTrue,
        );
      }
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('template-code-goods:edit')),
            )
            .value,
        isFalse,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(repository.writes.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity change while choosing the template file prevents metadata and creation',
    (tester) async {
      final repository = _Repository();
      final selection = Completer<FilePickerResult?>();
      final picker = _Picker(() => selection.future);
      FilePicker.platform = picker;
      final container = await _mount(tester, repository);
      await tester.tap(
        find.byKey(const ValueKey('import-permission-template')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(picker.calls, 1);
      container.read(_identity.notifier).state = 'different-admin';
      await tester.pump();
      selection.complete(_file());
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(_field('permission-template-name'), findsNothing);
      expect(repository.writes, isEmpty);
      expect(repository.rows, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

FilePickerResult _file() {
  final bytes = PermissionTemplateArchive(
    name: '仓库主管',
    description: '查看和导出货品',
    permissions: {'goods:view', 'goods:export'},
  ).encode();
  return FilePickerResult([
    PlatformFile(
      name: '权限-模板-仓库主管.json',
      size: bytes.length,
      readStream: Stream.fromIterable([
        bytes.sublist(0, 30),
        bytes.sublist(30),
      ]),
    ),
  ]);
}

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

Future<void> _expandCatalog(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('permission-toggle-all-groups'));
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Repository repository,
) async {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = ApiClient(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      isSuperAdminProvider.overrideWithValue(true),
      currentPermissionsProvider.overrideWithValue({Perm.authorizationManage}),
      permissionTemplateRepositoryProvider.overrideWithValue(repository),
      permissionCatalogProvider.overrideWith(
        (ref) async => [
          PermissionCatalogGroup(
            module: '基础资料',
            category: '货品资料',
            permissions: [
              for (final (code, name) in [
                ('goods:view', '查看货品'),
                ('goods:export', '导出货品'),
                ('goods:edit', '编辑货品'),
              ])
                AdminPermission(
                  id: code,
                  code: code,
                  name: name,
                  category: '货品资料',
                ),
            ],
          ),
        ],
      ),
      sensitiveReadBoundaryProvider.overrideWith(
        (ref) => SensitiveReadBoundary(
          identity: AuthenticatedScope(userId: ref.watch(_identity)),
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
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: AdminPermissionTemplatesView(navigation: SizedBox()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

class _Repository extends PermissionTemplateRepository {
  _Repository() : super(ApiClient(Dio()));
  final rows = <PermissionTemplate>[];
  final writes = <PermissionTemplate>[];
  @override
  Future<List<PermissionTemplate>> list() async => List.of(rows);
  @override
  Future<PermissionTemplate> save({
    PermissionTemplate? template,
    required String name,
    required String description,
    required Set<String> permissions,
  }) async {
    final saved = PermissionTemplate(
      id: template?.id ?? 'imported-template',
      name: name,
      description: description,
      permissions: permissions.toList()..sort(),
      version: (template?.version ?? 0) + 1,
    );
    writes.add(saved);
    rows.removeWhere((row) => row.id == saved.id);
    rows.add(saved);
    return saved;
  }
}

class _Picker extends FilePicker {
  _Picker(this.select);
  final Future<FilePickerResult?> Function() select;
  int calls = 0;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) {
    calls++;
    expect(type, FileType.custom);
    expect(allowedExtensions, ['json']);
    expect(withReadStream, isTrue);
    expect(allowMultiple, isFalse);
    return select();
  }
}
