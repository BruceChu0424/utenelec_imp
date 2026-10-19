import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/models/permission_configuration.dart';
import 'package:uten_imp/features/admin/providers/admin_providers.dart';
import 'package:uten_imp/features/admin/repositories/permission_configuration_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_transfer_actions.dart';
import 'package:uten_imp/features/admin/widgets/permission_configuration_import_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import '../../../support/audit_screenshot_support.dart';

final _identity = StateProvider<String>((ref) => 'admin');
final _captureKey = GlobalKey();
const _capture = bool.fromEnvironment('UTEN_CAPTURE_PERMISSION_TRANSFER');

void main() {
  test('source keys are namespaced and malformed scopes fail before UI', () {
    Map<String, dynamic> document() =>
        jsonDecode(jsonEncode(_backup().json)) as Map<String, dynamic>;
    final sharedKey = document();
    ((sharedKey['users'] as List).first as Map<String, dynamic>)['key'] =
        'department-old';
    expect(() => PermissionConfiguration.fromJson(sharedKey), returnsNormally);
    final duplicate = document();
    (duplicate['departments'] as List).add(
      (duplicate['departments'] as List).first,
    );
    expect(
      () => PermissionConfiguration.fromJson(duplicate),
      throwsFormatException,
    );
    final malformed = document();
    ((malformed['users'] as List).first as Map<String, dynamic>)['dataScopes'] =
        {'client': 'not-a-list'};
    expect(
      () => PermissionConfiguration.fromJson(malformed),
      throwsFormatException,
    );
  });
  test(
    'portable backup round trips codes and rejects unrelated or oversized files',
    () {
      final backup = _backup();
      expect(PermissionConfiguration.decode(backup.encode()).json, backup.json);
      expect(
        () => PermissionConfiguration.decode(
          Uint8List.fromList(utf8.encode('{"version":1}')),
        ),
        throwsFormatException,
      );
      expect(
        () => PermissionConfiguration.decode(
          Uint8List(permissionConfigurationMaxBytes + 1),
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'copy clipboard is discarded when the operator identity changes',
    (tester) async {
      final repository = _Repository();
      final container = await _mount(tester, repository, const SizedBox());
      container.read(permissionCopyClipboardProvider.notifier).state = _source;
      expect(container.read(permissionCopyClipboardProvider), isNotNull);
      container.read(_identity.notifier).state = 'different-admin';
      await tester.pump();
      expect(container.read(permissionCopyClipboardProvider), isNull);
    },
  );

  testWidgets(
    'late copy response cannot replace clipboard after choosing another employee',
    (tester) async {
      final repository = _Repository()
        ..pendingCopy = Completer<PermissionCopySnapshot>();
      final selected = ValueNotifier(_user('source'));
      addTearDown(selected.dispose);
      final container = await _mount(
        tester,
        repository,
        ValueListenableBuilder<AdminUserSummary>(
          valueListenable: selected,
          builder: (_, user, _) => AdminPermissionCopyActions(
            user: user,
            enabled: true,
            onApplied: () {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('copy-user-permissions')));
      await tester.pump();
      selected.value = _user('target');
      await tester.pump();
      repository.pendingCopy!.complete(_source);
      await tester.pumpAndSettle();
      expect(container.read(permissionCopyClipboardProvider), isNull);
      expect(repository.copyRequests, ['source']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'paste requires each sensitive grant and sends the reviewed fingerprint',
    (tester) async {
      final repository = _Repository();
      var applied = 0;
      final container = await _mount(
        tester,
        repository,
        AdminPermissionCopyActions(
          user: _user('target'),
          enabled: true,
          onApplied: () => applied++,
        ),
      );
      container.read(permissionCopyClipboardProvider.notifier).state = _source;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('paste-user-permissions')));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('confirm-paste-permissions'));
      expect(tester.widget<UtenButton>(confirm).onPressed, isNull);
      expect(find.textContaining('可查看数据范围仍按目标员工原设置'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-sensitive-target:finance')),
      );
      await tester.tap(
        find.byKey(const ValueKey('confirm-sensitive-target:finance')),
      );
      await tester.pump();
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(repository.copyWrites, 1);
      expect(repository.confirmations, {'target:finance'});
      expect(repository.fingerprint, 'reviewed-fingerprint');
      expect(applied, 1);
    },
  );

  testWidgets('uncertain paste never automatically repeats the write', (
    tester,
  ) async {
    final repository = _Repository()..copyError = NetworkTimeoutException();
    final container = await _mount(
      tester,
      repository,
      AdminPermissionCopyActions(
        user: _user('target'),
        enabled: true,
        onApplied: () {},
      ),
    );
    container.read(permissionCopyClipboardProvider.notifier).state = _source;
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('paste-user-permissions')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('confirm-sensitive-target:finance')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('confirm-paste-permissions')));
    await tester.pumpAndSettle();
    expect(repository.copyWrites, 1);
    expect(find.textContaining('暂勿重复粘贴'), findsOneWidget);
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const ValueKey('confirm-paste-permissions')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('重新预览'), findsNothing);
  });

  testWidgets('back navigation after uncertain write refreshes permissions', (
    tester,
  ) async {
    final repository = _Repository()..copyError = NetworkTimeoutException();
    final container = await _mount(
      tester,
      repository,
      Consumer(
        builder: (_, ref, _) {
          ref.watch(adminEffectivePermissionsProvider('target'));
          return AdminPermissionCopyActions(
            user: _user('target'),
            enabled: true,
            onApplied: () {},
          );
        },
      ),
    );
    container.read(permissionCopyClipboardProvider.notifier).state = _source;
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('paste-user-permissions')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('confirm-sensitive-target:finance')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('confirm-paste-permissions')));
    await tester.pumpAndSettle();
    final before = repository.effectiveReads;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(repository.effectiveReads, before + 1);
    expect(repository.copyWrites, 1);
    expect(container.read(permissionConfigurationRevisionProvider), 1);
  });

  testWidgets('unavailable identity does not offer an unusable retry', (
    tester,
  ) async {
    final repository = _Repository()
      ..previewError = AuthenticatedRequestScope.unavailable();
    final container = await _mount(
      tester,
      repository,
      AdminPermissionCopyActions(
        user: _user('target'),
        enabled: true,
        onApplied: () {},
      ),
    );
    container.read(permissionCopyClipboardProvider.notifier).state = _source;
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('paste-user-permissions')));
    await tester.pumpAndSettle();
    expect(find.textContaining('请关闭窗口后重新打开'), findsOneWidget);
    expect(find.text('重新预览'), findsNothing);
    expect(repository.copyWrites, 0);
  });

  testWidgets(
    'archived disabled-account settings remain in backup but cannot be selected',
    (tester) async {
      final repository = _Repository();
      final json =
          jsonDecode(jsonEncode(_backup().json)) as Map<String, dynamic>;
      final user = (json['users'] as List).first as Map<String, dynamic>;
      user.addAll({
        'accountStatus': 'disabled',
        'employeeStatus': 'active',
        'restorable': false,
        'restoreReason': '账号已停用，设置仅作备份留存',
      });
      final backup = PermissionConfiguration.fromJson(json);
      late ProviderContainer container;
      container = await _mount(
        tester,
        repository,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => PermissionConfigurationImportDialog(
                configuration: backup,
                boundary: container.read(sensitiveReadBoundaryProvider),
              ),
            ),
            child: const Text('开始导入'),
          ),
        ),
      );
      await tester.tap(find.text('开始导入'));
      await tester.pumpAndSettle();
      expect(repository.importPreviews.single['users'], isEmpty);
      await tester.tap(find.textContaining('个人操作权限 · 已匹配'));
      await tester.pumpAndSettle();
      expect(find.text('账号已停用，设置仅作备份留存'), findsOneWidget);
      final item = find.widgetWithText(
        CheckboxListTile,
        '员工甲（UT001） · employee · 来源账号已停用',
      );
      expect(tester.widget<CheckboxListTile>(item).value, isFalse);
      expect(tester.widget<CheckboxListTile>(item).onChanged, isNull);
      expect(backup.json['users'], json['users']);
    },
  );

  for (final width in [375.0, 1000.0]) {
    testWidgets(
      'import reviews explicit mappings before any writes at $width',
      (tester) async {
        final repository = _Repository();
        await _mount(
          tester,
          repository,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => Consumer(
                  builder: (_, ref, _) => PermissionConfigurationImportDialog(
                    configuration: _backup(),
                    boundary: ref.read(sensitiveReadBoundaryProvider),
                  ),
                ),
              ),
              child: const Text('开始导入'),
            ),
          ),
          width: width,
        );
        await tester.tap(find.text('开始导入'));
        await tester.pumpAndSettle();
        expect(repository.importWrites, 0);
        expect(repository.importPreviews.single['departments'], [
          {'sourceKey': 'department-old', 'targetId': null},
        ]);
        expect(
          tester
              .widget<UtenButton>(
                find.byKey(const ValueKey('confirm-permission-import')),
              )
              .onPressed,
          isNull,
        );
        final check = find.byKey(
          const ValueKey('confirm-permission-import-mapping'),
        );
        await tester.ensureVisible(check);
        await tester.tap(check);
        await tester.pump();
        final preview = find.byKey(const ValueKey('preview-permission-import'));
        await tester.ensureVisible(preview);
        await tester.tap(preview);
        await tester.pumpAndSettle();
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'permission-import-preview-${width.toInt()}',
          );
        }
        expect(repository.importPreviews.last['departments'], [
          {'sourceKey': 'department-old', 'targetId': 'department-new'},
        ]);
        expect(repository.importPreviews.last['users'], [
          {'sourceKey': 'user-old', 'targetId': 'user-new'},
        ]);
        expect(repository.importWrites, 0);
        await tester.ensureVisible(
          find.byKey(const ValueKey('confirm-sensitive-target:finance')),
        );
        await tester.tap(
          find.byKey(const ValueKey('confirm-sensitive-target:finance')),
        );
        await tester.pump();
        final confirm = find.byKey(const ValueKey('confirm-permission-import'));
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(repository.importWrites, 1);
        expect(repository.fingerprint, 'reviewed-fingerprint');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'editing the import scope invalidates preview and sensitive confirmations',
    (tester) async {
      final repository = _Repository();
      late ProviderContainer container;
      container = await _mount(
        tester,
        repository,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => PermissionConfigurationImportDialog(
                configuration: _backup(),
                boundary: container.read(sensitiveReadBoundaryProvider),
              ),
            ),
            child: const Text('开始导入'),
          ),
        ),
      );
      await tester.tap(find.text('开始导入'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm-permission-import-mapping')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('preview-permission-import')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-sensitive-target:finance')),
      );
      await tester.tap(
        find.byKey(const ValueKey('confirm-sensitive-target:finance')),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('导入全员基础包'));
      await tester.tap(find.text('导入全员基础包'));
      await tester.pump();
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('confirm-permission-import')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('confirm-sensitive-target:finance')),
        findsNothing,
      );
      expect(repository.importWrites, 0);
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Repository repository,
  Widget child, {
  double width = 1000,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final api = ApiClient(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      isSuperAdminProvider.overrideWithValue(true),
      currentPermissionsProvider.overrideWithValue({Perm.authorizationManage}),
      permissionConfigurationRepositoryProvider.overrideWithValue(repository),
      permissionCatalogProvider.overrideWith((ref) async => []),
      adminEffectivePermissionsProvider.overrideWith((ref, userId) async {
        repository.effectiveReads++;
        return const EffectivePermissions(
          departmentPermissions: [],
          baselinePermissions: [],
          grants: [],
          revokes: [],
          effective: [],
        );
      }),
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
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _capture ? auditScreenshotTheme(buildLightTheme()) : null,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

const _source = PermissionCopySnapshot(
  sourceUserId: 'source',
  sourceLabel: '来源员工（UT001）',
  fingerprint: 'source-fingerprint',
  permissions: ['finance:view:all'],
);
AdminUserSummary _user(String id) => AdminUserSummary(
  id: id,
  loginAccount: id,
  status: 'active',
  mustChangePassword: false,
  remoteAccess: false,
  currentEmployee: true,
  employeeStatus: 'active',
  employeeName: '目标员工',
);

PermissionConfiguration _backup() => PermissionConfiguration.fromJson({
  'format': 'uten.permission-configuration',
  'version': 1,
  'exportedAt': '2026-10-17T00:00:00Z',
  'baseline': ['notice:read'],
  'departments': [
    {
      'key': 'department-old',
      'code': 'DEPT_A',
      'name': '业务部门',
      'permissions': ['goods:view'],
    },
  ],
  'users': [
    {
      'key': 'user-old',
      'employeeCode': 'UT001',
      'employeeName': '员工甲',
      'loginAccount': 'employee',
      'grants': <String>[],
      'revokes': <String>[],
      'effective': ['goods:view'],
      'delegationPermissions': <String>[],
      'dataScopes': <String, dynamic>{},
    },
  ],
  'scopeOwners': <dynamic>[],
});

PermissionTransferPreview _preview({bool suggestions = false}) =>
    PermissionTransferPreview.fromJson({
      'fingerprint': 'reviewed-fingerprint',
      'canApply': !suggestions,
      'issues': <String>[],
      'changes': [
        {
          'kind': 'user',
          'sourceKey': 'user-old',
          'targetId': 'target',
          'label': '目标员工',
          'added': ['finance:view:all'],
          'removed': ['goods:edit'],
        },
      ],
      'sensitiveAdditions': [
        {
          'key': 'target:finance',
          'label': '查看全公司财务数据',
          'permissionCode': 'finance:view:all',
          'targetLabel': '目标员工',
        },
      ],
      'suggestions': [
        {
          'kind': 'department',
          'sourceKey': 'department-old',
          'targetId': 'department-new',
          'label': '业务部门（DEPT_A）',
        },
        {
          'kind': 'user',
          'sourceKey': 'user-old',
          'targetId': 'user-new',
          'label': '员工甲（UT001）',
        },
      ],
      'pinnedBaselineAdditions': <String>[],
      'notes': <String>[],
    });

class _Repository implements PermissionConfigurationRepository {
  Completer<PermissionCopySnapshot>? pendingCopy;
  Object? copyError;
  Object? previewError;
  int effectiveReads = 0;
  final copyRequests = <String>[];
  final importPreviews = <Map<String, dynamic>>[];
  int copyWrites = 0;
  int importWrites = 0;
  Set<String> confirmations = {};
  String? fingerprint;
  @override
  Future<PermissionConfiguration> export() async => _backup();
  @override
  Future<PermissionCopySnapshot> copy(String userId) async {
    copyRequests.add(userId);
    return pendingCopy == null ? _source : await pendingCopy!.future;
  }

  @override
  Future<PermissionTransferPreview> previewCopy(
    String targetId,
    PermissionCopySnapshot source,
  ) async {
    if (previewError != null) throw previewError!;
    return _preview();
  }

  @override
  Future<void> applyCopy(
    String targetId,
    PermissionCopySnapshot source,
    PermissionTransferPreview preview,
    Set<String> confirmed,
  ) async {
    copyWrites++;
    confirmations = Set.of(confirmed);
    fingerprint = preview.fingerprint;
    if (copyError != null) throw copyError!;
  }

  @override
  Future<PermissionTransferPreview> previewImport(
    Map<String, dynamic> request,
  ) async {
    importPreviews.add(request);
    return _preview(suggestions: importPreviews.length == 1);
  }

  @override
  Future<void> importConfiguration(
    Map<String, dynamic> request,
    PermissionTransferPreview preview,
    Set<String> confirmed,
  ) async {
    importWrites++;
    confirmations = Set.of(confirmed);
    fingerprint = preview.fingerprint;
  }
}
