import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/models/system_updater_status.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';
import 'package:uten_imp/features/admin/widgets/platform_settings_entry_card.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _entryKey = ValueKey('system-settings-platform-entry');

GoRouter _router(Widget home) => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(
      path: '/home',
      builder: (_, _) => Scaffold(body: home),
    ),
    GoRoute(
      path: RouteName.adminPlatformSettings,
      builder: (_, _) => const Scaffold(body: Text('platform-settings-page')),
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  GoRouter router, {
  SystemSettingRepository? repository,
  Set<String> permissions = const {Perm.authorizationManage},
  bool superAdmin = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(superAdmin),
        if (repository != null)
          systemSettingRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('platform entry opens its page and retains return navigation', (
    tester,
  ) async {
    final router = _router(const PlatformSettingsEntryCard());
    addTearDown(router.dispose);
    await _pump(tester, router);
    expect(find.text('平台设置'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('公司名称、Logo')), findsOneWidget);
    await tester.tap(find.byKey(_entryKey));
    await tester.pumpAndSettle();
    expect(find.text('platform-settings-page'), findsOneWidget);
    expect(router.canPop(), isTrue);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(_entryKey), findsOneWidget);
  });

  for (final (admin, permissions) in [
    (false, const {Perm.authorizationManage}),
    (true, const <String>{}),
  ]) {
    testWidgets(
      'platform entry hidden for admin=$admin permissions=$permissions',
      (tester) async {
        final router = _router(const PlatformSettingsEntryCard());
        addTearDown(router.dispose);
        await _pump(
          tester,
          router,
          superAdmin: admin,
          permissions: permissions,
        );
        expect(find.byKey(_entryKey), findsNothing);
      },
    );
  }

  for (final failure in [false, true]) {
    testWidgets(
      'platform entry survives loading and ${failure ? 'failure' : 'empty settings'}',
      (tester) async {
        tester.view.physicalSize = const Size(400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = _Repository();
        final router = _router(const AdminSystemSettingsPage());
        addTearDown(router.dispose);
        await _pump(tester, router, repository: repository);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byKey(_entryKey), findsOneWidget);
        if (failure) {
          repository.response.completeError(
            ApiException('INTERNAL_ERROR', '设置读取失败', httpStatus: 500),
          );
        } else {
          repository.response.complete(const []);
        }
        await tester.pumpAndSettle();
        expect(find.byKey(_entryKey), findsOneWidget);
        expect(find.text(failure ? '设置读取失败' : '暂无设置项'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(_entryKey));
        await tester.pumpAndSettle();
        expect(find.text('platform-settings-page'), findsOneWidget);
      },
    );
  }
}

class _Repository implements SystemSettingRepository {
  final response = Completer<List<SystemSettingEntry>>();

  @override
  Future<List<SystemSettingEntry>> list() => response.future;

  @override
  Future<SystemUpdaterStatus> updaterStatus() => throw UnimplementedError();

  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) => throw UnimplementedError();
}
