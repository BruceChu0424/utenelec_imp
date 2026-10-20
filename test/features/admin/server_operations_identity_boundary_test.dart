import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/sms_settings.dart';
import 'package:uten_imp/features/admin/pages/admin_sms_settings_page.dart';
import 'package:uten_imp/features/admin/providers/server_operations_access.dart';
import 'package:uten_imp/features/admin/repositories/sms_settings_repository.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final reorder in [false, true]) {
    testWidgets(
      'real C owner preserves SMS edits on equal-permission profile refresh reorder=$reorder',
      (tester) async {
        final fixture = await _pumpRealSession(tester);
        final container = fixture.container;
        final owner = container.read(serverOperationsOwnerProvider);
        final permissions = container.read(currentPermissionsProvider);
        final controller = _field(tester, 'sign').controller!;
        await tester.enterText(find.byKey(const ValueKey('sms-sign')), '保留编辑');
        await tester.enterText(
          find.byKey(const ValueKey('sms-key-id')),
          'public-fixture-key-id',
        );
        await tester.enterText(
          find.byKey(const ValueKey('sms-secret')),
          'public-fixture-secret',
        );

        (container.read(sessionProvider.notifier) as _ProfileSession).replace(
          _user(
            name: '同账号更新资料',
            permissions: reorder
                ? [Perm.serverUpdate, Perm.authorizationManage]
                : [Perm.authorizationManage, Perm.serverUpdate],
          ),
        );
        await tester.pumpAndSettle();

        final refreshedPermissions = container.read(currentPermissionsProvider);
        expect(identical(refreshedPermissions, permissions), isFalse);
        expect(refreshedPermissions, unorderedEquals(permissions));
        expect(
          _field(tester, 'sign').controller!.text,
          '保留编辑',
          reason:
              'same permission values must not discard the unsaved gateway form',
        );
        expect(container.read(serverOperationsOwnerProvider), owner);
        expect(
          identical(_field(tester, 'sign').controller, controller),
          isTrue,
        );
        expect(
          _field(tester, 'secret').controller!.text,
          'public-fixture-secret',
        );
        expect(fixture.reads, hasLength(1));
        expect(fixture.apiA.meReads, 1);
        expect(container.read(serverOperationsWritableProvider), isTrue);
        await tester.ensureVisible(
          find.byKey(const ValueKey('sms-settings-save')),
        );
        await tester.tap(find.byKey(const ValueKey('sms-settings-save')));
        await tester.pumpAndSettle();
        expect(fixture.commands, hasLength(1));
        expect(
          fixture.commands.single['expectedRevision'],
          'https://company-a/api/admin-a',
        );
        expect(fixture.commands.single['signName'], '保留编辑');
        expect(fixture.commands.single['accessKeyId'], 'public-fixture-key-id');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  for (final boundary in ['account', 'server', 'permission']) {
    testWidgets(
      'real C owner clears SMS secrets and rejects stale reads/actions after $boundary change',
      (tester) async {
        final fixture = await _pumpRealSession(tester);
        final container = fixture.container;
        final owner = container.read(serverOperationsOwnerProvider);
        await tester.enterText(
          find.byKey(const ValueKey('sms-key-id')),
          'old-fixture-key-id',
        );
        await tester.enterText(
          find.byKey(const ValueKey('sms-secret')),
          'old-fixture-secret',
        );
        final oldSave = tester
            .widget<UtenButton>(find.byKey(const ValueKey('sms-settings-save')))
            .onPressed!;
        final staleRead = Completer<SmsSettings>();
        fixture.nextRead = staleRead;
        await tester.tap(find.byTooltip('重新读取服务器配置'));
        await tester.pump();
        expect(fixture.reads, hasLength(2));

        switch (boundary) {
          case 'account':
            (container.read(sessionProvider.notifier) as _ProfileSession)
                .replace(_user(id: 'admin-b'));
          case 'server':
            container.read(_endpoint.notifier).state = 'https://company-b/api';
          case 'permission':
            (container.read(sessionProvider.notifier) as _ProfileSession)
                .replace(_user(permissions: [Perm.serverUpdate]));
        }
        await tester.pumpAndSettle();
        oldSave();
        await tester.pumpAndSettle();
        expect(
          fixture.commands,
          isEmpty,
          reason: 'a captured old action must not write for a new boundary',
        );
        expect(container.read(serverOperationsOwnerProvider), isNot(owner));
        if (boundary == 'permission') {
          expect(container.read(serverSourceVisibleProvider), isFalse);
          expect(find.text('仅超级管理员可管理短信网关'), findsOneWidget);
          expect(find.byKey(const ValueKey('sms-secret')), findsNothing);
          expect(find.byKey(const ValueKey('sms-settings-save')), findsNothing);
        } else {
          expect(_field(tester, 'key-id').controller!.text, isEmpty);
          expect(_field(tester, 'secret').controller!.text, isEmpty);
          expect(
            _field(tester, 'sign').controller!.text,
            isNot('stale private result'),
          );
        }
        staleRead.complete(_settings('stale', sign: 'stale private result'));
        await tester.pumpAndSettle();
        expect(find.text('stale private result'), findsNothing);
        expect(find.text('old-fixture-secret'), findsNothing);
        expect(fixture.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

TextFormField _field(WidgetTester tester, String suffix) =>
    tester.widget<TextFormField>(find.byKey(ValueKey('sms-$suffix')));

final _endpoint = StateProvider((ref) => 'https://company-a/api');

AppUser _user({
  String id = 'admin-a',
  String name = '当前超管',
  List<String> permissions = const [
    Perm.authorizationManage,
    Perm.serverUpdate,
  ],
}) => AppUser(
  id: id,
  code: id,
  name: name,
  superAdmin: true,
  permissions: List.of(permissions),
);

Future<_Fixture> _pumpRealSession(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  RecentMeSnapshot.clear();
  addTearDown(RecentMeSnapshot.clear);
  final fixture = _Fixture();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      sessionProvider.overrideWith(() => _ProfileSession(_user())),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_endpoint)),
      apiClientProvider.overrideWith(
        (ref) => ref.watch(_endpoint) == 'https://company-a/api'
            ? fixture.apiA
            : fixture.apiB,
      ),
      smsSettingsRepositoryProvider.overrideWith(
        (ref) => _SmsRepository(
          fixture,
          ref.watch(apiBaseUrlProvider),
          ref.watch(sessionProvider).user!.id,
        ),
      ),
    ],
  );
  fixture.container = container;
  addTearDown(container.dispose);
  // Keep the actual snapshot notifier, its permission listener and owner chain.
  // Only its wire /auth/me response and SMS repository boundary are fixtures.
  await container.read(sessionSnapshotProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: const AdminSmsSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(container.read(serverSourceVisibleProvider), isTrue);
  expect(container.read(serverOperationsWritableProvider), isTrue);
  return fixture;
}

class _ProfileSession extends SessionNotifier {
  _ProfileSession(this.initial);
  final AppUser initial;
  @override
  SessionState build() =>
      SessionState(status: AuthStatus.authenticated, user: initial);
  void replace(AppUser user) =>
      state = SessionState(status: AuthStatus.authenticated, user: user);
}

class _MeApi extends ApiClient {
  _MeApi() : super(Dio());
  int meReads = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    // 快照重取可能发生在 pumpAndSettle 守卫内（Riverpod 3 vsync 任务经假时钟
    // Timer 触发），此处再调守卫版 expect 会抛 "Guarded function conflict"，
    // 把快照打成错误态并留下 5s 重试 Timer；expectSync 保住同样的路径断言。
    expectSync(path, ApiEndpoints.authMe);
    meReads++;
    return {
      'session': {
        'delegableSurfaceKeys': <String>[],
        'documentScopes': <String, dynamic>{},
        'preferences': <String, dynamic>{},
      },
    };
  }
}

class _Fixture {
  final apiA = _MeApi(), apiB = _MeApi();
  late ProviderContainer container;
  final reads = <String>[];
  final commands = <Map<String, dynamic>>[];
  Completer<SmsSettings>? nextRead;
}

class _SmsRepository implements SmsSettingsRepository {
  _SmsRepository(this.fixture, this.endpoint, this.user);
  final _Fixture fixture;
  final String endpoint, user;
  String get revision => '$endpoint/$user';
  @override
  Future<SmsSettings> fetch() async {
    fixture.reads.add(revision);
    final pending = fixture.nextRead;
    fixture.nextRead = null;
    return pending == null ? _settings(revision) : pending.future;
  }

  @override
  Future<SmsSettings> save(Map<String, dynamic> command) async {
    fixture.commands.add(Map.of(command));
    return _settings(revision);
  }
}

SmsSettings _settings(String revision, {String sign = '当前公司签名'}) =>
    SmsSettings.fromJson({
      'revision': revision,
      'version': 1,
      'source': 'DATABASE',
      'provider': 'ALIYUN',
      'effectiveProvider': 'ALIYUN',
      'endpoint': 'dysmsapi.aliyuncs.com',
      'allowedEndpoints': ['dysmsapi.aliyuncs.com'],
      'signName': sign,
      'templateCode': 'SMS_FIXTURE',
      'accessKeyConfigured': true,
      'secretUnreadable': false,
      'capabilities': {
        'canManage': true,
        'canUseLog': false,
        'canExposeCode': false,
      },
      'status': 'READY',
      'applyMode': 'NEXT_ISSUANCE',
    });
