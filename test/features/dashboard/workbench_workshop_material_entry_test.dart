import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/dashboard/widgets/workbench_module_area.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../helpers/badge_summary_fixture.dart';

class _StubSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

AppUser _user(Set<String> permissions) => AppUser(
  id: 'workshop-entry-user',
  code: 'W001',
  name: '车间入口测试',
  permissions: permissions.toList(),
);

Future<GoRouter> _pump(WidgetTester tester, Set<String> permissions) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: RouteName.dashboard,
    routes: [
      GoRoute(
        path: RouteName.dashboard,
        builder: (_, _) => const Scaffold(
          body: SingleChildScrollView(child: WorkbenchModuleArea()),
        ),
      ),
      GoRoute(
        path: RouteName.workshopMaterialBin,
        redirect: (_, state) => employeePermissionRedirect(
          _user(permissions),
          state.uri.toString(),
        ),
        builder: (_, _) => const Scaffold(body: Text('内料仓总览落点')),
      ),
      GoRoute(
        path: RouteName.accessDenied,
        builder: (_, _) => const Scaffold(body: Text('无权进入')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(() => _StubSession()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_TestSession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'test-user'),
        ),
        sessionSnapshotProvider.overrideWith(_TestSnapshot.new),
        apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

class _TestSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'test-user', code: 'E001', name: '测试员工'),
  );
}

class _TestSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

void main() {
  for (final permission in [
    Perm.workshopMaterialView,
    Perm.workshopMaterialSetup,
  ]) {
    test('内料仓总览和指定车间入口允许单独的 $permission', () {
      for (final location in [
        RouteName.workshopMaterialBin,
        RoutePath.workshopMaterialBin(workshopId: 'workshop-1'),
      ]) {
        expect(requiredAnyPermFor(location), [
          Perm.workshopMaterialView,
          Perm.workshopMaterialSetup,
        ]);
        expect(requiredAllPermsFor(location), isEmpty);
        expect(
          employeePermissionRedirect(_user({permission}), location),
          isNull,
        );
        expect(locationAllowedFor({permission}, false, location), isTrue);
      }
      expect(
        employeePermissionRedirect(
          _user({permission}),
          RouteName.workshopMaterialReports,
        ),
        permission == Perm.workshopMaterialView
            ? isNull
            : RouteName.accessDenied,
      );
      expect(
        employeePermissionRedirect(
          _user({permission}),
          RouteName.workshopMaterialSetup,
        ),
        permission == Perm.workshopMaterialSetup
            ? isNull
            : RouteName.accessDenied,
      );
    });

    testWidgets('仅 $permission 可见通用卡并到达不指定车间的总览', (tester) async {
      final router = await _pump(tester, {permission});
      expect(find.text('车间内料仓'), findsOneWidget);
      expect(find.text('查看各车间库存与启用情况'), findsOneWidget);
      await tester.ensureVisible(find.text('车间内料仓'));
      await tester.tap(find.text('车间内料仓'));
      await tester.pumpAndSettle();
      expect(find.text('内料仓总览落点'), findsOneWidget);
      expect(router.state.uri.path, RouteName.workshopMaterialBin);
      expect(router.state.uri.queryParameters, {
        'returnTo': RouteName.dashboard,
      });
      expect(tester.takeException(), isNull);
    });
  }

  test('没有查看或设置权限时，总览和指定车间深链都拒绝', () {
    for (final permissions in <Set<String>>[
      {},
      {Perm.workshopMaterialRequest},
    ]) {
      for (final location in [
        RouteName.workshopMaterialBin,
        RoutePath.workshopMaterialBin(workshopId: 'workshop-1'),
      ]) {
        expect(
          employeePermissionRedirect(_user(permissions), location),
          RouteName.accessDenied,
        );
        expect(locationAllowedFor(permissions, false, location), isFalse);
      }
    }
  });

  testWidgets('没有查看或设置权限不显示内料仓卡且直达被拒绝', (tester) async {
    final router = await _pump(tester, {});
    expect(find.text('车间内料仓'), findsNothing);
    expect(find.text('查看各车间库存与启用情况'), findsNothing);
    router.go(RouteName.workshopMaterialBin);
    await tester.pumpAndSettle();
    expect(find.text('无权进入'), findsOneWidget);
    expect(find.text('内料仓总览落点'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
