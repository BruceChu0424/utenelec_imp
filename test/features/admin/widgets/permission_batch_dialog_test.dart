import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/models/permission_template.dart';
import 'package:uten_imp/features/admin/providers/admin_providers.dart';
import 'package:uten_imp/features/admin/repositories/permission_template_repository.dart';
import 'package:uten_imp/features/admin/widgets/permission_batch_dialog.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';
import 'package:uten_imp/shared/auth/permission_grant_policy.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

import '../../../support/audit_screenshot_support.dart';

final _identity = StateProvider<String>((ref) => 'operator');
const _capture = bool.fromEnvironment('UTEN_CAPTURE_PERMISSION_BATCH');
final _captureKey = GlobalKey();
const _template = PermissionTemplate(
  id: 'template-warehouse',
  name: '仓库岗位模板',
  description: '仓库岗位授权',
  permissions: ['goods:view'],
  version: 7,
);

void main() {
  testWidgets(
    'template batch freezes all targets and submits reviewed fingerprint',
    (tester) async {
      final api = _BatchApi();
      final users = ['user-a', 'user-b'];
      final departments = ['department-a'];
      await _mount(tester, api, users: users, departments: departments);
      users.add('late-user');
      departments.clear();
      await _chooseTemplate(tester);
      expect(_applyButton(tester).onPressed, isNull);
      await _tap(tester, find.text('预览变更'));
      expect(
        api.calls.single.path,
        '/admin/permission-templates/apply/preview',
      );
      expect(api.calls.single.body, {
        'userIds': ['user-a', 'user-b'],
        'departmentIds': ['department-a'],
        'templateId': _template.id,
        'templateVersion': 7,
        'mode': 'MERGE',
      });
      expect(_applyButton(tester).onPressed, isNull);
      await _confirmSensitive(tester, api);
      expect(_applyButton(tester).onPressed, isNotNull);
      await _tap(
        tester,
        find.byKey(const ValueKey('confirm-apply-permission-template')),
      );
      expect(api.calls.last.path, '/admin/permission-templates/apply');
      expect(api.calls.last.body, {
        'request': api.calls.first.body,
        'expectedFingerprint': 'review-1',
        'sensitiveConfirmations': [
          'department-a-credit',
          'user-a-credit',
          'user-b-credit',
        ],
      });
      expect(find.byType(PermissionBatchDialog), findsNothing);
      expect(find.text('已应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('single employee uses the shared legacy template endpoint', (
    tester,
  ) async {
    final api = _BatchApi(sensitive: false);
    await _mount(tester, api, users: ['user-a']);
    await _chooseTemplate(tester);
    await _tap(tester, find.text('预览变更'));
    expect(
      api.calls.single.path,
      '/admin/users/user-a/permission-template/preview',
    );
    expect(api.calls.single.body, {
      'templateId': _template.id,
      'templateVersion': 7,
      'mode': 'MERGE',
    });
    await _tap(
      tester,
      find.byKey(const ValueKey('confirm-apply-permission-template')),
    );
    expect(api.calls.last.path, '/admin/users/user-a/permission-template');
    expect(api.calls.last.body['expectedFingerprint'], 'review-1');
    expect(find.text('已应用'), findsOneWidget);
  });

  testWidgets(
    'replace mode clears prior preview and every sensitive confirmation',
    (tester) async {
      final api = _BatchApi();
      await _mount(tester, api, users: ['user-a', 'user-b']);
      await _chooseTemplate(tester);
      await _tap(tester, find.text('预览变更'));
      await _confirmSensitive(tester, api);
      expect(_applyButton(tester).onPressed, isNotNull);
      await _tap(tester, find.text('替换直接设置'));
      expect(_applyButton(tester).onPressed, isNull);
      expect(
        find.byKey(const ValueKey('confirm-sensitive-user-a-credit')),
        findsNothing,
      );
      await _tap(tester, find.text('预览变更'));
      expect(api.calls.last.body['mode'], 'REPLACE');
      expect(_applyButton(tester).onPressed, isNull);
      await _confirmSensitive(tester, api);
      await _tap(
        tester,
        find.byKey(const ValueKey('confirm-apply-permission-template')),
      );
      expect(api.calls.last.body['expectedFingerprint'], 'review-2');
      expect((api.calls.last.body['request'] as Map)['mode'], 'REPLACE');
    },
  );

  testWidgets(
    'ordinary grant and revoke preserve the exact selected targets and codes',
    (tester) async {
      final api = _BatchApi(sensitive: false);
      await _mount(
        tester,
        api,
        templateMode: false,
        users: ['user-a', 'user-b'],
        departments: ['department-a'],
      );
      await _tap(tester, find.byKey(const ValueKey('permission-grant-all')));
      await _tap(tester, find.text('预览变更'));
      expect(api.calls.single.path, '/admin/permissions/batch/preview');
      expect(api.calls.single.body, {
        'userIds': ['user-a', 'user-b'],
        'departmentIds': ['department-a'],
        'grants': ['goods:edit', 'goods:view'],
        'revokes': <String>[],
      });
      await _tap(tester, find.text('取消所选权限'));
      expect(_applyButton(tester).onPressed, isNull);
      await _tap(tester, find.byKey(const ValueKey('permission-grant-all')));
      await _tap(tester, find.text('预览变更'));
      expect(api.calls.last.body['grants'], isEmpty);
      expect(api.calls.last.body['revokes'], [
        'account:balance_adjust',
        'goods:edit',
        'goods:view',
      ]);
      await _tap(
        tester,
        find.byKey(const ValueKey('confirm-apply-permission-template')),
      );
      expect(api.calls.last.path, '/admin/permissions/batch');
      expect(api.calls.last.body['expectedFingerprint'], 'review-2');
    },
  );

  for (final delayedPreview in [false, true]) {
    testWidgets(
      'identity changes block retained batch preview: delayed=$delayedPreview',
      (tester) async {
        final api = _BatchApi(sensitive: false);
        final container = await _mount(
          tester,
          api,
          users: ['user-a', 'user-b'],
        );
        await _chooseTemplate(tester);
        if (delayedPreview) api.previewGate = Completer<Map<String, dynamic>>();
        await tester.tap(find.text('预览变更'));
        if (delayedPreview) {
          await tester.pump();
          await tester.pump();
        } else {
          await tester.pumpAndSettle();
        }
        container.read(_identity.notifier).state = 'other-operator';
        if (delayedPreview) api.previewGate!.complete(api.response());
        await tester.pumpAndSettle();
        expect(_applyButton(tester).onPressed, isNull);
        expect(find.text('账号或连接已变化，请关闭后重新操作'), findsOneWidget);
        expect(
          api.calls.where((call) => !call.path.endsWith('/preview')),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('server conflict discards stale preview before any retry', (
    tester,
  ) async {
    final api = _BatchApi(
      sensitive: false,
    )..commitError = ApiException('CONFLICT', '模板版本已变化，请重新预览', httpStatus: 409);
    await _mount(tester, api, users: ['user-a', 'user-b']);
    await _chooseTemplate(tester);
    await _tap(tester, find.text('预览变更'));
    await _tap(
      tester,
      find.byKey(const ValueKey('confirm-apply-permission-template')),
    );
    expect(find.text('模板版本已变化，请重新预览'), findsOneWidget);
    expect(_applyButton(tester).onPressed, isNull);
    expect(
      api.calls.where((call) => !call.path.endsWith('/preview')),
      hasLength(1),
    );
    api.commitError = null;
    await _tap(tester, find.text('预览变更'));
    await _tap(
      tester,
      find.byKey(const ValueKey('confirm-apply-permission-template')),
    );
    expect(api.calls.last.body['expectedFingerprint'], 'review-2');
  });

  testWidgets('unknown commit outcome prevents repeat requests', (
    tester,
  ) async {
    final api = _BatchApi(sensitive: false)
      ..commitError = NetworkTimeoutException();
    await _mount(tester, api, users: ['user-a', 'user-b']);
    await _chooseTemplate(tester);
    await _tap(tester, find.text('预览变更'));
    await _tap(
      tester,
      find.byKey(const ValueKey('confirm-apply-permission-template')),
    );
    expect(find.textContaining('结果尚未确认'), findsOneWidget);
    expect(_applyButton(tester).onPressed, isNull);
    final previewButton = tester.widget<UtenButton>(
      find.ancestor(of: find.text('预览变更'), matching: find.byType(UtenButton)),
    );
    expect(previewButton.onPressed, isNull);
    await tester.pump(const Duration(seconds: 10));
    expect(api.calls, hasLength(2));
  });

  for (final width in [375.0, 1440.0]) {
    testWidgets('batch catalog starts collapsed and fits at $width', (
      tester,
    ) async {
      await _mount(
        tester,
        _BatchApi(),
        users: ['user-a', 'user-b'],
        templateMode: false,
        width: width,
      );
      expect(find.text('查看货品'), findsNothing);
      expect(
        find.byKey(const ValueKey('permission-module-基础资料')),
        findsOneWidget,
      );
      expect(find.text('全部展开'), findsOneWidget);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'permission-batch-collapsed-${width.toInt()}',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}

UtenButton _applyButton(WidgetTester tester) => tester.widget<UtenButton>(
  find.byKey(const ValueKey('confirm-apply-permission-template')),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _chooseTemplate(WidgetTester tester) async {
  await _tap(tester, find.byType(DropdownButtonFormField<PermissionTemplate>));
  await _tap(tester, find.text(_template.name).last);
}

Future<void> _confirmSensitive(WidgetTester tester, _BatchApi api) async {
  for (final key in api.confirmationKeys) {
    await _tap(tester, find.byKey(ValueKey('confirm-sensitive-$key')));
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _BatchApi api, {
  List<String> users = const [],
  List<String> departments = const [],
  bool templateMode = true,
  double width = 1440,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      isSuperAdminProvider.overrideWithValue(true),
      currentPermissionsProvider.overrideWithValue({Perm.authorizationManage}),
      permissionTemplateRepositoryProvider.overrideWithValue(
        PermissionTemplateRepository(api),
      ),
      permissionTemplatesProvider.overrideWith((ref) async => [_template]),
      permissionCatalogProvider.overrideWith(
        (ref) async => const [
          PermissionCatalogGroup(
            module: '基础资料',
            category: '货品资料',
            permissions: [
              AdminPermission(
                id: 'view',
                code: 'goods:view',
                name: '查看货品',
                category: '货品资料',
                actionType: PermissionActionType.view,
              ),
              AdminPermission(
                id: 'edit',
                code: 'goods:edit',
                name: '编辑货品',
                category: '货品资料',
                actionType: PermissionActionType.edit,
              ),
              AdminPermission(
                id: 'sensitive',
                code: 'account:balance_adjust',
                name: '调整账户余额',
                category: '货品资料',
                grantPolicy: PermissionGrantPolicy({
                  PermissionGrantPolicy.individualOnly,
                }),
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
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _capture
              ? auditScreenshotTheme(buildLightTheme())
              : buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final applied = await showPermissionBatchDialog(
                    context,
                    templateMode: templateMode,
                    userIds: users,
                    departmentIds: departments,
                  );
                  if (context.mounted && applied == true) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('已应用')));
                  }
                },
                child: const Text('打开批量设置'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开批量设置'));
  await tester.pumpAndSettle();
  return container;
}

class _BatchApi extends ApiClient {
  _BatchApi({this.sensitive = true})
    : super(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  final bool sensitive;
  final calls = <({String path, Map<String, dynamic> body})>[];
  final confirmationKeys = <String>[];
  int previews = 0;
  Object? commitError;
  Completer<Map<String, dynamic>>? previewGate;

  Map<String, dynamic> response() => {
    'fingerprint': 'review-$previews',
    'canApply': true,
    'issues': <String>[],
    'changes': [
      {
        'kind': 'USER',
        'sourceKey': 'user-a',
        'label': '员工甲',
        'added': ['goods:view'],
        'removed': <String>[],
      },
    ],
    'sensitiveAdditions': [
      if (sensitive)
        for (final key in confirmationKeys)
          {
            'key': key,
            'targetLabel': key,
            'label': '查看客户信用',
            'permissionCode': 'client:credit:view',
          },
    ],
  };

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final payload = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    calls.add((path: path, body: payload));
    if (path.endsWith('/preview')) {
      previews++;
      confirmationKeys
        ..clear()
        ..addAll([
          for (final id in payload['userIds'] as List? ?? ['user-a'])
            '$id-credit',
          for (final id in payload['departmentIds'] as List? ?? const [])
            '$id-credit',
        ]);
      if (previewGate != null) return previewGate!.future;
      return response();
    }
    if (commitError case final error?) throw error;
    return {};
  }
}
