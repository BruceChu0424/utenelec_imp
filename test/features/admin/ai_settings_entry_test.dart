import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/admin/models/system_setting_entry.dart';
import 'package:uten_imp/features/admin/models/system_updater_status.dart';
import 'package:uten_imp/features/admin/pages/admin_system_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';
import 'package:uten_imp/features/admin/widgets/ai_settings_entry_card.dart';
import 'package:uten_imp/features/dashboard/providers/workbench_layout_provider.dart';
import 'package:uten_imp/features/dashboard/widgets/workbench_module_area.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _zh = lookupAppLocalizations(const Locale('zh'));

class _Layout extends WorkbenchLayoutNotifier {
  @override
  WorkbenchLayoutState build() =>
      const WorkbenchLayoutState(order: ['system'], collapsed: {});
}

GoRouter _router(Widget home) => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(
      path: '/home',
      builder: (_, _) => Scaffold(body: home),
    ),
    GoRoute(
      path: RouteName.adminAiSettings,
      builder: (_, _) => const Scaffold(body: Text('ai-settings-page')),
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  GoRouter router, {
  Set<String> permissions = const {Perm.authorizationManage},
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        workbenchLayoutProvider.overrideWith(_Layout.new),
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
}

void main() {
  testWidgets(
    'workbench system group links to AI services for administrators',
    (tester) async {
      final router = _router(
        const SingleChildScrollView(child: WorkbenchModuleArea()),
      );
      addTearDown(router.dispose);
      await _pump(tester, router);

      expect(find.text('AI 服务'), findsOneWidget);
      await tester.tap(find.text('AI 服务'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        RouteName.adminAiSettings,
      );
      expect(find.text('ai-settings-page'), findsOneWidget);
    },
  );

  testWidgets('the workbench item stays hidden without system administration', (
    tester,
  ) async {
    final router = _router(
      const SingleChildScrollView(child: WorkbenchModuleArea()),
    );
    addTearDown(router.dispose);
    await _pump(tester, router, permissions: {Perm.serverStatusView});
    expect(find.text('AI 服务'), findsNothing);
  });

  testWidgets('system settings entry card opens the AI services page', (
    tester,
  ) async {
    final router = _router(const AiSettingsEntryCard());
    addTearDown(router.dispose);
    await _pump(tester, router);

    expect(find.text(_zh.aiSettingsTitle), findsOneWidget);
    expect(find.text(_zh.aiSettingsEntrySubtitle), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(_zh.aiSettingsEntrySubtitle)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('system-settings-ai-entry')));
    await tester.pumpAndSettle();
    expect(find.text('ai-settings-page'), findsOneWidget);
    // push 进来的页面返回回到系统设置。
    expect(router.canPop(), isTrue);
  });

  // AI 服务入口不依赖系统设置项: 设置项读不到或为空时也要能进 AI 服务页。
  for (final (name, repository) in [
    (
      'the settings failed to load',
      _SettingsRepository(
        error: ApiException('INTERNAL_ERROR', '加载失败', httpStatus: 500),
      ),
    ),
    ('there are no settings', _SettingsRepository()),
  ]) {
    testWidgets('system settings keeps the AI entry when $name', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            systemSettingRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AdminSystemSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('system-settings-ai-entry')),
        findsOneWidget,
      );
      expect(
        find.text(repository.error == null ? '暂无设置项' : '加载失败'),
        findsOneWidget,
      );
    });
  }
}

class _SettingsRepository implements SystemSettingRepository {
  _SettingsRepository({this.error});

  final ApiException? error;

  @override
  Future<List<SystemSettingEntry>> list() async {
    if (error != null) throw error!;
    return const [];
  }

  @override
  Future<SystemUpdaterStatus> updaterStatus() => throw UnimplementedError();

  @override
  Future<List<SystemSettingEntry>> updateBatch(
    List<({String key, String value, String expectedValue})> changes,
  ) => throw UnimplementedError();
}
