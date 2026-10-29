import 'dart:io';
import 'dart:async';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/client_update/software_downloads_controller.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/software_downloads_page.dart';
import 'package:uten_imp/features/client_update/software_downloads_presentation.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/api_client.dart';

import '../../support/software_downloads_fixture.dart';

late SharedPreferences _preferences;

class _Session extends SessionNotifier {
  _Session(this.permissions, {this.superAdmin = false});
  final List<String> permissions;
  final bool superAdmin;
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'downloads-employee',
      code: 'DL',
      name: '下载员工',
      permissions: permissions,
      superAdmin: superAdmin,
    ),
  );
}

Future<SoftwareDownloadsController> _pump(
  WidgetTester tester,
  SoftwareDownloadsTransport transport,
  SoftwarePackageSaveFixture saver, {
  Size size = const Size(1440, 1100),
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool publisher = false,
  bool superAdmin = false,
  bool realControllerProvider = false,
  GlobalKey? boundaryKey,
  SoftwareDownloadPlatform? currentPlatform = SoftwareDownloadPlatform.windows,
  Locale locale = const Locale('zh'),
  String runtimeFamily = ClientRuntimeFamily.flutter,
  SoftwareHostInfo? host,
  SoftwareHostReader? hostReader,
  bool routed = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = realControllerProvider
      ? null
      : SoftwareDownloadsController(api: transport.api, save: saver.save);
  if (controller != null) addTearDown(controller.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ProviderScope(
        overrides: [
          softwareDevicePlatformProvider.overrideWithValue(currentPlatform),
          softwareHostReaderProvider.overrideWithValue(
            hostReader ??
                () async =>
                    host ??
                    SoftwareHostInfo(
                      platform: currentPlatform,
                      osLabel:
                          currentPlatform == SoftwareDownloadPlatform.windows
                          ? (runtimeFamily == ClientRuntimeFamily.wpfLegacy
                                ? 'Windows 7 SP1'
                                : 'Windows 11')
                          : currentPlatform?.label ?? '未知系统',
                      osVersion:
                          currentPlatform == SoftwareDownloadPlatform.windows
                          ? (runtimeFamily == ClientRuntimeFamily.wpfLegacy
                                ? 'windows7_sp1'
                                : 'windows11')
                          : currentPlatform?.name,
                      architecture: 'x64',
                      windowsRuntimeFamily: runtimeFamily,
                      osCertainty: SoftwareDetectionCertainty.nativeConfirmed,
                      architectureCertainty:
                          SoftwareDetectionCertainty.nativeConfirmed,
                    ),
          ),
          softwareWindowsRuntimeFamilyProvider.overrideWithValue(runtimeFamily),
          apiClientProvider.overrideWithValue(transport.api),
          if (controller != null)
            softwareDownloadsControllerProvider.overrideWithValue(controller),
          sharedPreferencesProvider.overrideWithValue(_preferences),
          sessionProvider.overrideWith(
            () => _Session(
              publisher ? [Perm.clientReleasePublish] : [],
              superAdmin: superAdmin,
            ),
          ),
        ],
        child: (routed
            ? MaterialApp.router(
                theme: buildLightTheme(),
                routerConfig: GoRouter(
                  initialLocation: RouteName.softwareDownloads,
                  routes: [
                    GoRoute(
                      path: RouteName.softwareDownloads,
                      builder: (_, _) => const SoftwareDownloadsPage(),
                    ),
                    GoRoute(
                      path: RouteName.clientReleasePublish,
                      builder: (_, state) => Scaffold(
                        body: Text('独立发布页面 ${state.uri.queryParameters}'),
                      ),
                    ),
                  ],
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
              )
            : MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: brightness == Brightness.light
                    ? buildLightTheme()
                    : buildDarkTheme(),
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const SoftwareDownloadsPage(),
              )),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller ??
      ProviderScope.containerOf(
        tester.element(find.byType(SoftwareDownloadsPage)),
      ).read(softwareDownloadsControllerProvider);
}

Future<void> _screenshot(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (!const bool.fromEnvironment('SOFTWARE_DOWNLOADS_SCREENSHOTS')) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/software-downloads-20261028/previews');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  test('the publication page has an exact direct-link permission', () {
    expect(requiredAnyPermFor(RouteName.clientReleasePublish), [
      Perm.clientReleasePublish,
    ]);
    expect(
      requiredAnyPermFor('${RouteName.clientReleasePublish}?platform=android'),
      [Perm.clientReleasePublish],
    );
    expect(
      locationAllowedFor({}, false, RouteName.clientReleasePublish),
      false,
    );
    expect(
      locationAllowedFor(
        {Perm.clientReleasePublish},
        false,
        '${RouteName.clientReleasePublish}?platform=android',
      ),
      true,
    );
  });

  for (final entry in [
    (TargetPlatform.windows, SoftwareDownloadPlatform.windows),
    (TargetPlatform.android, SoftwareDownloadPlatform.android),
    (TargetPlatform.macOS, SoftwareDownloadPlatform.macos),
    (TargetPlatform.iOS, SoftwareDownloadPlatform.ios),
    (TargetPlatform.linux, SoftwareDownloadPlatform.linux),
  ]) {
    test('host ${entry.$1.name} selects its own platform', () {
      debugDefaultTargetPlatformOverride = entry.$1;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(softwareDevicePlatformProvider), entry.$2);
    });
  }

  testWidgets('detected target and filename name the OS and architecture', (
    tester,
  ) async {
    final transport = SoftwareDownloadsTransport();
    final saver = SoftwarePackageSaveFixture();
    await _pump(tester, transport, saver);
    expect(find.text('当前设备：Windows 11 · X64'), findsOneWidget);
    expect(find.text('Windows 11 · X64 常规版'), findsOneWidget);
    expect(find.textContaining('windows11-x64-setup.exe'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('software-downloads-windows')));
    await tester.pumpAndSettle();
    expect(saver.published.single, transport.bytes);
    expect(saver.filenames.single, endsWith('windows11-x64-setup.exe'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown architecture requires an explicit choice', (
    tester,
  ) async {
    await _pump(
      tester,
      SoftwareDownloadsTransport(),
      SoftwarePackageSaveFixture(),
      host: const SoftwareHostInfo(
        platform: SoftwareDownloadPlatform.windows,
        osLabel: 'Windows 10 / 11',
        osVersion: 'windows10_or_11',
        windowsRuntimeFamily: ClientRuntimeFamily.flutter,
      ),
    );
    expect(
      find.byKey(const ValueKey('software-downloads-windows')),
      findsNothing,
    );
    expect(find.text('选择架构后查看对应安装包'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('software-downloads-architecture')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('X64').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('software-downloads-windows')),
      findsOneWidget,
    );
    expect(find.text('Windows 10 / 11 · X64 常规版'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late detection cannot overwrite a manual destination', (
    tester,
  ) async {
    final detection = Completer<SoftwareHostInfo>();
    await _pump(
      tester,
      SoftwareDownloadsTransport(),
      SoftwarePackageSaveFixture(),
      hostReader: () => detection.future,
    );
    await tester.tap(find.byKey(const ValueKey('software-select-android')));
    await tester.pumpAndSettle();
    detection.complete(
      const SoftwareHostInfo(
        platform: SoftwareDownloadPlatform.windows,
        osLabel: 'Windows 7 SP1',
        osVersion: 'windows7_sp1',
        architecture: 'x86',
        windowsRuntimeFamily: ClientRuntimeFamily.wpfLegacy,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find
          .byKey(const ValueKey('software-download-target-label'))
          .evaluate()
          .single
          .widget,
      isA<Text>().having(
        (w) => w.data,
        'manual selection',
        contains('Android'),
      ),
    );
    expect(
      find.byKey(const ValueKey('software-downloads-windows')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'legacy never falls back to regular and a missing x86 stays missing',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      await _pump(
        tester,
        transport,
        SoftwarePackageSaveFixture(),
        runtimeFamily: ClientRuntimeFamily.wpfLegacy,
      );
      expect(find.text('Windows 7 SP1 · X64 兼容版'), findsOneWidget);
      expect(find.text('此版本暂未发布'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('software-downloads-windows')),
        findsNothing,
      );
      transport.releases.add(
        transport.installer(
          id: SoftwareDownloadsTransport.arm64Id,
          mode: 'windows_wpf_setup',
        )..['runtimeFamily'] = ClientRuntimeFamily.wpfLegacy,
      );
      await tester.tap(find.text('刷新版本'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('software-downloads-windows')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('software-downloads-architecture')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('X86').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('software-downloads-windows')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('publication uses a full route and carries target context', (
    tester,
  ) async {
    await _pump(
      tester,
      SoftwareDownloadsTransport(),
      SoftwarePackageSaveFixture(),
      publisher: true,
      routed: true,
    );
    await tester.tap(find.byKey(const ValueKey('software-downloads-publish')));
    await tester.pumpAndSettle();
    expect(find.textContaining('独立发布页面'), findsOneWidget);
    expect(find.textContaining('architecture: x64'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog retry recovers without changing destination', (
    tester,
  ) async {
    final transport = SoftwareDownloadsTransport()..listStatus = 503;
    await _pump(tester, transport, SoftwarePackageSaveFixture());
    expect(find.text('暂时无法读取版本'), findsOneWidget);
    transport.listStatus = 200;
    await tester.tap(find.text('刷新版本'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('software-downloads-windows')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [375.0, 844.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        final label =
            '${width.toInt()}-${brightness.name}-${(scale * 100).toInt()}';
        testWidgets('responsive downloads $label', (tester) async {
          final key = GlobalKey();
          await _pump(
            tester,
            SoftwareDownloadsTransport(),
            SoftwarePackageSaveFixture(),
            size: Size(width, 1100),
            brightness: brightness,
            scale: scale,
            boundaryKey: key,
            publisher: true,
          );
          expect(
            find.byKey(const ValueKey('software-downloads-windows')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await _screenshot(tester, key, 'downloads-$label');
          await tester.ensureVisible(find.text('安装与后续更新'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
