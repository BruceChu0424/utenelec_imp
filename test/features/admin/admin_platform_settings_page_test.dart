import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/platform_server_status.dart';
import 'package:uten_imp/features/admin/pages/admin_platform_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/platform_settings_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_cache.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _brand = PlatformBranding(
  version: 2,
  companyName: '测试公司',
  platformName: '协作管理平台',
  tagline: '工作更有序',
);
const _status = PlatformServerStatus(databaseConnected: true);
final _endpoint = StateProvider<String>(
  (ref) => 'https://company-a.invalid/api',
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'admin',
      code: 'A1',
      name: '管理员',
      superAdmin: true,
      permissions: [Perm.authorizationManage],
    ),
  );
  void revoke() => state = const SessionState();
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(generation: 1);
}

class _Repo implements PlatformSettingsRepository {
  PlatformBranding brand = _brand;
  Object? statusError;
  Object? saveError;
  Completer<PlatformServerStatus>? pendingStatus;
  Completer<PlatformBranding>? pendingFetch;
  int statusCalls = 0;
  int fetchCalls = 0;
  int saveCalls = 0;
  PlatformBranding? submitted;
  bool commitThenTimeout = false;
  @override
  Future<PlatformServerStatus> status() async {
    statusCalls++;
    if (statusError != null) throw statusError!;
    return pendingStatus?.future ?? _status;
  }

  @override
  Future<PlatformBranding> fetch() async {
    fetchCalls++;
    return pendingFetch?.future ?? brand;
  }

  @override
  Future<PlatformBranding> save(
    PlatformBranding branding, {
    Uint8List? logo,
    bool removeLogo = false,
  }) async {
    saveCalls++;
    submitted = branding;
    if (saveError != null) throw saveError!;
    brand = PlatformBranding.fromJson({
      ...branding.toUpdateJson(),
      'version': branding.version + 1,
      'hasLogo': logo != null || (!removeLogo && branding.hasLogo),
    });
    if (commitThenTimeout) throw NetworkTimeoutException();
    return brand;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repo repo, {
  _Repo? nextRepo,
  Size size = const Size(1440, 1000),
  bool dark = false,
  double scale = 1,
  bool routed = false,
  PlatformBranding? cachedBrand,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  if (cachedBrand != null) {
    const endpoint = 'https://company-a.invalid/api';
    await PlatformBrandingCache(prefs).saveBrand(
      endpoint,
      cachedBrand.forServer(endpoint),
      isCurrent: () => true,
    );
  }
  final router = routed
      ? GoRouter(
          initialLocation: RouteName.adminPlatformSettings,
          routes: [
            DraftAwareGoRoute(
              path: RouteName.adminPlatformSettings,
              builder: (_, _) => const AdminPlatformSettingsPage(),
            ),
            DraftAwareGoRoute(
              path: RouteName.dashboard,
              builder: (_, _) => const Scaffold(body: Text('已返回工作台')),
            ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
  Widget builder(BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_endpoint)),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'admin'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.authorizationManage,
        }),
        sessionProvider.overrideWith(_Session.new),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        platformSettingsRepositoryProvider.overrideWith(
          (ref) => ref.watch(apiBaseUrlProvider).contains('company-a')
              ? repo
              : nextRepo ?? repo,
        ),
        platformBrandingProvider.overrideWith((ref) async => repo.brand),
      ],
      child: RepaintBoundary(
        key: const Key('platform-capture'),
        child: router != null
            ? MaterialApp.router(
                locale: const Locale('zh'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                builder: builder,
                routerConfig: router,
              )
            : MaterialApp(
                locale: const Locale('zh'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const AdminPlatformSettingsPage(),
              ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['PLATFORM_SETTINGS_PREVIEW'];
  if (output == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('platform-capture')),
    );
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('checks current server before reading editable branding', (
    tester,
  ) async {
    final repo = _Repo()..pendingStatus = Completer();
    await _pump(tester, repo);
    expect(repo.fetchCalls, 0);
    expect(find.text('正在验证服务器和数据库…'), findsOneWidget);
    repo.pendingStatus!.complete(_status);
    await tester.pumpAndSettle();
    expect(repo.fetchCalls, 1);
    expect(find.byKey(const ValueKey('platform-companyName')), findsOneWidget);
    await _capture(tester, 'platform-light-wide');
  });

  testWidgets('administrator can leave while a server precheck is pending', (
    tester,
  ) async {
    final repo = _Repo()..pendingStatus = Completer();
    await _pump(tester, repo, routed: true);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('已返回工作台'), findsOneWidget);
    repo.pendingStatus!.complete(_status);
    await tester.pumpAndSettle();
    expect(repo.fetchCalls, 0);
  });

  testWidgets('imperative settings route inside a router mounts safely', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, repo, routed: true);
    await tester.pumpAndSettle();
    final parentContext = tester.element(
      find.byType(AdminPlatformSettingsPage),
    );
    final router = GoRouter.of(parentContext);
    final navigator = Navigator.of(parentContext);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const AdminPlatformSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(repo.fetchCalls, 2);
    expect(find.byType(AdminPlatformSettingsPage), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    router.go(RouteName.dashboard);
    await tester.pumpAndSettle();
    expect(find.text('已返回工作台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed precheck explains unsupported server and blocks editing',
    (tester) async {
      final repo = _Repo()
        ..statusError = ApiException('NOT_FOUND', 'not found', httpStatus: 404);
      await _pump(tester, repo);
      await tester.pumpAndSettle();
      expect(repo.fetchCalls, 0);
      expect(find.text('当前服务器版本尚未支持平台设置，请更新服务器后重试'), findsOneWidget);
      expect(find.byKey(const ValueKey('platform-pick-logo')), findsNothing);
      expect(find.text('重新检测'), findsOneWidget);
    },
  );

  testWidgets(
    'cached settings remain visible but cannot authorize editing after an upgrade',
    (tester) async {
      final repo = _Repo()..statusError = NetworkException();
      await _pump(
        tester,
        repo,
        cachedBrand: const PlatformBranding(
          version: 8,
          companyName: '保留配置的公司',
          platformName: '保留的平台',
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('platform-companyName'));
      expect(tester.widget<TextFormField>(field).controller!.text, '保留配置的公司');
      expect(tester.widget<TextFormField>(field).enabled, false);
      expect(
        tester
            .widget<UtenButton>(find.byKey(const ValueKey('platform-save')))
            .onPressed,
        isNull,
      );
      expect(repo.saveCalls, 0);
      expect(
        find.text('正在显示当前服务器上次确认的品牌，暂时只读。连接验证成功后才能修改和保存。'),
        findsOneWidget,
      );
      repo.statusError = null;
      repo.brand = const PlatformBranding(
        version: 9,
        companyName: '服务器当前公司',
        platformName: '当前平台',
      );
      await tester.tap(find.text('重新检测'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(field).controller!.text, '服务器当前公司');
      expect(tester.widget<TextFormField>(field).enabled, true);
    },
  );

  testWidgets('changing endpoint discards late company A response', (
    tester,
  ) async {
    final first = _Repo()..pendingFetch = Completer();
    final next = _Repo()
      ..brand = const PlatformBranding(
        version: 8,
        companyName: '乙公司',
        platformName: '乙公司平台',
      );
    final container = await _pump(tester, first, nextRepo: next);
    container.read(_endpoint.notifier).state = 'https://company-b.invalid/api';
    await tester.pumpAndSettle();
    first.pendingFetch!.complete(
      const PlatformBranding(version: 3, companyName: '迟到的甲公司'),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('platform-companyName')),
    );
    expect(field.controller!.text, '乙公司');
    expect(find.text('迟到的甲公司'), findsNothing);
  });

  testWidgets('revoking identity closes editor before a pending response', (
    tester,
  ) async {
    final repo = _Repo()..pendingStatus = Completer();
    final container = await _pump(tester, repo);
    (container.read(sessionProvider.notifier) as _Session).revoke();
    await tester.pump();
    repo.pendingStatus!.complete(_status);
    await tester.pumpAndSettle();
    expect(repo.fetchCalls, 0);
    expect(find.text('平台设置仅限已确认权限的超级管理员使用'), findsOneWidget);
  });

  testWidgets(
    'save rechecks connectivity and atomically submits current version',
    (tester) async {
      final repo = _Repo();
      await _pump(tester, repo);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('platform-companyName')),
        '新的公司',
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('platform-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repo.statusCalls, 2);
      expect(repo.saveCalls, 1);
      expect(repo.submitted!.companyName, '新的公司');
      expect(repo.submitted!.version, 2);
      expect(find.text('已保存 · 版本 3'), findsOneWidget);
    },
  );

  testWidgets('conflict retains edits and requires a fresh read', (
    tester,
  ) async {
    final repo = _Repo()
      ..saveError = ApiException('CONFLICT', 'stale', httpStatus: 409);
    await _pump(tester, repo);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('platform-companyName')),
      '未保存的公司',
    );
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('platform-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('platform-companyName')),
          )
          .controller!
          .text,
      '未保存的公司',
    );
    expect(tester.widget<UtenButton>(save).onPressed, isNull);
    expect(find.text('读取最新设置'), findsOneWidget);
  });

  testWidgets('partial color input keeps preview usable and cannot be saved', (
    tester,
  ) async {
    final repo = _Repo();
    await _pump(tester, repo);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('platform-primaryColor'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '#12');
    await tester.pump();
    expect(tester.takeException(), isNull);
    final save = find.byKey(const ValueKey('platform-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(repo.saveCalls, 0);
  });

  testWidgets('uncertain save detects new server version before another edit', (
    tester,
  ) async {
    final repo = _Repo()..commitThenTimeout = true;
    await _pump(tester, repo);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('platform-companyName')),
      '已提交的新公司',
    );
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('platform-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(repo.brand.version, 3);
    expect(find.text('保存结果尚未确认，请重新检测连接，再读取服务器最新设置核对。'), findsOneWidget);
    await tester.ensureVisible(find.text('重新检测'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新检测'));
    await tester.pumpAndSettle();
    expect(
      find.text('服务器已有新的设置版本，本次保存可能已生效。你的编辑已保留，请读取最新设置后核对。'),
      findsOneWidget,
    );
    expect(tester.widget<UtenButton>(save).onPressed, isNull);
    expect(find.text('撤销并读取最新'), findsOneWidget);
  });

  for (final deepBack in [false, true]) {
    testWidgets(
      'unsaved changes block ${deepBack ? 'deep-link back' : 'sidebar go'}',
      (tester) async {
        await _pump(tester, _Repo(), routed: true);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('platform-companyName')),
          '未保存',
        );
        await tester.pumpAndSettle();
        final router = GoRouter.of(
          tester.element(find.byType(AdminPlatformSettingsPage)),
        );
        if (deepBack) {
          await tester.tap(find.byTooltip('返回'));
        } else {
          router.go(RouteName.dashboard);
        }
        await tester.pumpAndSettle();
        expect(find.text('有尚未保存的修改'), findsOneWidget);
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        expect(find.byType(AdminPlatformSettingsPage), findsOneWidget);
        router.go(RouteName.dashboard);
        await tester.pumpAndSettle();
        await tester.tap(find.text('丢弃修改'));
        await tester.pumpAndSettle();
        expect(find.text('已返回工作台'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'configuration navigation groups global, business, and personal settings',
    (tester) async {
      await _pump(tester, _Repo());
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置导航'));
      await tester.pumpAndSettle();
      expect(find.text('平台管理'), findsOneWidget);
      expect(find.text('业务基础配置'), findsOneWidget);
      expect(find.text('运行维护'), findsOneWidget);
      expect(find.text('我的偏好'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'platform-configuration-groups');
    },
  );

  testWidgets('preview switches full theme including text contrast', (
    tester,
  ) async {
    await _pump(tester, _Repo());
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    final element = tester.element(find.text('登录与导航效果'));
    final theme = Theme.of(element);
    expect(theme.brightness, Brightness.dark);
    expect(
      theme.textTheme.titleMedium!.color!.computeLuminance(),
      greaterThan(0.5),
    );
    await _capture(tester, 'platform-light-dark-preview');
  });

  for (final (size, dark, scale, name) in [
    (const Size(375, 1000), false, 1.3, 'platform-mobile'),
    (const Size(375, 1000), false, 2.0, 'platform-mobile-largest'),
    (const Size(1440, 1000), true, 1.0, 'platform-dark-wide'),
    (const Size(900, 450), true, 1.3, 'platform-landscape'),
  ]) {
    testWidgets('responsive editor $name has no overflow', (tester) async {
      await _pump(tester, _Repo(), size: size, dark: dark, scale: scale);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, name);
      final preview = find.text('实时预览 · 未保存');
      await tester.scrollUntilVisible(
        preview,
        400,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, '$name-preview');
    });
  }
}
