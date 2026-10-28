import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
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
  PlatformServerStatus reportedStatus = _status;
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
    return pendingStatus?.future ?? reportedStatus;
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
  String initialEndpoint = 'https://company-a.invalid/api',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  if (cachedBrand != null) {
    await PlatformBrandingCache(prefs).saveBrand(
      initialEndpoint,
      cachedBrand.forServer(initialEndpoint),
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
            DraftAwareGoRoute(
              path: RouteName.adminServerStatus,
              builder: (_, _) => const Scaffold(body: Text('服务器维护页面')),
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
        _endpoint.overrideWith((ref) => initialEndpoint),
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
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                builder: builder,
                routerConfig: router,
              )
            : MaterialApp(
                debugShowCheckedModeBanner: false,
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

Future<void> _revealForTap(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 20,
  );
  await tester.pumpAndSettle();
  // A lazy section may change its scroll extent after the first reveal.
  // Position the settled target inside the viewport before sending a tap.
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> _openServerSection(WidgetTester tester) async {
  final sections = find.byType(UtenSegmentRow<int>);
  await _revealForTap(tester, sections);
  final inlineTab = find.descendant(
    of: sections,
    matching: find.text('服务器与文件'),
  );
  if (inlineTab.evaluate().isNotEmpty) {
    expect(inlineTab.hitTestable(), findsOneWidget);
    await tester.tap(inlineTab.hitTestable());
  } else {
    final compactMenu = find.descendant(
      of: sections,
      matching: find.byType(OutlinedButton),
    );
    expect(compactMenu.hitTestable(), findsOneWidget);
    await tester.tap(compactMenu.hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('选择分类'), findsOneWidget);
    final dialogTab = find.text('服务器与文件');
    await Scrollable.ensureVisible(tester.element(dialogTab), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(dialogTab.hitTestable(), findsOneWidget);
    await tester.tap(dialogTab.hitTestable());
  }
  await tester.pumpAndSettle();
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

  testWidgets(
    'failed server recheck clears previously confirmed storage availability',
    (tester) async {
      final repo = _Repo()
        ..reportedStatus = const PlatformServerStatus(
          databaseConnected: true,
          attachmentStorageBackend: 'local',
          attachmentUploadsEnabled: true,
        );
      await _pump(tester, repo);
      await tester.pumpAndSettle();
      await _openServerSection(tester);
      final storage = find.byKey(const ValueKey('platform-storage-card'));
      expect(
        find.descendant(of: storage, matching: find.text('公司数据库')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: storage, matching: find.text('服务器本地目录')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: storage, matching: find.text('已配置开放')),
        findsOneWidget,
      );
      await _capture(tester, 'platform-server-overview');

      repo.statusError = NetworkException();
      await tester.ensureVisible(find.text('重新检测'));
      await tester.tap(find.text('重新检测'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(storage);
      expect(find.text('尚未确认连接'), findsOneWidget);
      expect(
        find.descendant(of: storage, matching: find.text('等待验证')),
        findsNWidgets(3),
      );
      expect(find.text('已配置开放'), findsNothing);
      expect(find.text('服务器本地目录'), findsNothing);
      expect(find.text('公司数据库'), findsNothing);

      repo.statusError = null;
      repo.reportedStatus = const PlatformServerStatus(
        databaseConnected: true,
        attachmentStorageBackend: 'oss',
      );
      await tester.ensureVisible(find.text('重新检测'));
      await tester.tap(find.text('重新检测'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: storage, matching: find.text('对象存储 (OSS)')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: storage, matching: find.text('未开放')),
        findsOneWidget,
      );
      expect(find.text('等待验证'), findsNothing);
      expect(repo.saveCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'server maintenance navigation confirms unsaved branding before leaving',
    (tester) async {
      final repo = _Repo();
      await _pump(tester, repo, routed: true);
      await tester.pumpAndSettle();
      final company = find.byKey(const ValueKey('platform-companyName'));
      await tester.enterText(company, '尚未保存的公司名称');
      await _openServerSection(tester);
      final maintenance = find.text('服务器状态与备份');
      await tester.ensureVisible(maintenance);
      await tester.tap(maintenance);
      await tester.pumpAndSettle();
      expect(find.text('有尚未保存的修改'), findsOneWidget);
      expect(find.text('服务器维护页面'), findsNothing);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('公司与品牌'));
      await tester.tap(find.text('公司与品牌'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(company).controller!.text,
        '尚未保存的公司名称',
      );

      await _openServerSection(tester);
      await tester.ensureVisible(maintenance);
      await tester.tap(maintenance);
      await tester.pumpAndSettle();
      await tester.tap(find.text('丢弃修改'));
      await tester.pumpAndSettle();
      expect(find.text('服务器维护页面'), findsOneWidget);
      expect(repo.saveCalls, 0);

      GoRouter.of(tester.element(find.text('服务器维护页面'))).pop();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('公司与品牌'));
      await tester.tap(find.text('公司与品牌'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(company).controller!.text,
        _brand.companyName,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, dark, scale, twoColumns, name) in [
    (const Size(1440, 1000), false, 1.0, true, 'platform-server-light-wide'),
    (const Size(1440, 1000), true, 1.0, true, 'platform-server-dark-wide'),
    (const Size(760, 1000), false, 1.0, false, 'platform-server-tablet'),
    (const Size(375, 1000), false, 1.0, false, 'platform-server-mobile'),
    (
      const Size(375, 1000),
      false,
      2.0,
      false,
      'platform-server-mobile-largest',
    ),
    (const Size(900, 450), true, 1.3, false, 'platform-server-landscape'),
  ]) {
    testWidgets('server layout $name aligns cards and remains usable', (
      tester,
    ) async {
      final repo = _Repo()
        ..reportedStatus = const PlatformServerStatus(
          databaseConnected: true,
          attachmentStorageBackend: 'local',
          attachmentUploadsEnabled: true,
        );
      await _pump(
        tester,
        repo,
        size: size,
        dark: dark,
        scale: scale,
        initialEndpoint:
            'https://company-a.invalid/company-platform/production/'
            'long-deployment-identifier-for-current-company-server/api',
      );
      await tester.pumpAndSettle();
      final connection = tester.getRect(
        find.byKey(const ValueKey('platform-connection-summary')),
      );
      expect(connection.width, greaterThan(size.width * 0.85));
      await _openServerSection(tester);
      expect(tester.takeException(), isNull);
      await _capture(tester, name);

      final storageFinder = find.byKey(const ValueKey('platform-storage-card'));
      await tester.scrollUntilVisible(
        storageFinder,
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 20,
      );
      final storage = tester.getRect(storageFinder);
      final maintenance = tester.getRect(
        find.byKey(const ValueKey('platform-maintenance-card')),
      );
      final upgrade = tester.getRect(
        find.byKey(const ValueKey('platform-upgrade-card')),
      );
      expect(storage.left, closeTo(connection.left, 0.1));
      expect(upgrade.left, closeTo(connection.left, 0.1));
      expect(upgrade.width, closeTo(connection.width, 0.1));
      if (twoColumns) {
        expect(maintenance.top, closeTo(storage.top, 0.1));
        expect(maintenance.right, closeTo(connection.right, 0.1));
        expect(storage.width / maintenance.width, closeTo(1.5, 0.02));
        expect(storage.right, lessThan(maintenance.left));
      } else {
        expect(storage.width, closeTo(connection.width, 0.1));
        expect(maintenance.width, closeTo(connection.width, 0.1));
        expect(maintenance.left, closeTo(connection.left, 0.1));
        expect(maintenance.top, greaterThanOrEqualTo(storage.bottom));
      }
      expect(upgrade.top, greaterThanOrEqualTo(maintenance.bottom));

      final details = find.descendant(
        of: find.byKey(const ValueKey('platform-upgrade-card')),
        matching: find.byType(UtenFieldHintIcon),
      );
      final expandedExplanation = find.textContaining('公司配置随数据库备份与还原，不随安装包替换。');
      expect(expandedExplanation, findsNothing);
      await _revealForTap(tester, details);
      await tester.tap(details.hitTestable());
      await tester.pumpAndSettle();
      expect(expandedExplanation, findsOneWidget);
      expect(details.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, '$name-details');

      final scrollable = find.byType(Scrollable).first;
      for (var step = 0; step < 30; step++) {
        final position = tester.state<ScrollableState>(scrollable).position;
        if (position.pixels >= position.maxScrollExtent) break;
        await tester.drag(scrollable, const Offset(0, -350));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels, closeTo(position.maxScrollExtent, 1));
      await _capture(tester, '$name-bottom');
    });
  }

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
