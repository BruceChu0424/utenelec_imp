import 'dart:io';
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
        child: MaterialApp(
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
        ),
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
      final directory = Directory('build/software-downloads-20261026/previews');
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

  for (final entry in [
    (TargetPlatform.windows, SoftwareDownloadPlatform.windows),
    (TargetPlatform.android, SoftwareDownloadPlatform.android),
    (TargetPlatform.macOS, SoftwareDownloadPlatform.macos),
    (TargetPlatform.iOS, SoftwareDownloadPlatform.ios),
    (TargetPlatform.linux, null),
  ]) {
    test(
      'host OS ${entry.$1.name} resolves to the matching download platform',
      () {
        debugDefaultTargetPlatformOverride = entry.$1;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        expect(container.read(softwareDevicePlatformProvider), entry.$2);
      },
    );
  }

  for (final platform in SoftwareDownloadPlatform.values) {
    testWidgets('the current ${platform.label} device is shown first', (
      tester,
    ) async {
      final key = GlobalKey();
      await _pump(
        tester,
        SoftwareDownloadsTransport(),
        SoftwarePackageSaveFixture(),
        currentPlatform: platform,
        size: const Size(375, 950),
        scale: 2,
        boundaryKey: key,
      );
      final selected = find.byKey(
        ValueKey('software-platform-${platform.name}'),
      );
      for (final other in SoftwareDownloadPlatform.values.where(
        (item) => item != platform,
      )) {
        final otherTop = tester
            .getTopLeft(find.byKey(ValueKey('software-platform-${other.name}')))
            .dy;
        expect(tester.getTopLeft(selected).dy, lessThan(otherTop));
      }
      expect(find.text('当前设备'), findsOneWidget);
      expect(find.text('暂时无法下载'), findsNWidgets(3));
      expect(
        find.byKey(const ValueKey('software-downloads-windows')),
        findsOneWidget,
      );
      expect(find.text('优腾综合管理平台(UIMP)'), findsWidgets);
      expect(tester.takeException(), isNull);
      if (platform != SoftwareDownloadPlatform.windows) {
        await _screenshot(tester, key, 'downloads-current-${platform.name}');
      }
    });
  }

  for (final language in ['en', 'ko']) {
    testWidgets('$language uses the English platform name', (tester) async {
      final key = GlobalKey();
      await _pump(
        tester,
        SoftwareDownloadsTransport(),
        SoftwarePackageSaveFixture(),
        locale: Locale(language),
        size: const Size(375, 950),
        scale: 2,
        boundaryKey: key,
      );
      expect(
        find.text('Uten Integrated Management Platform (UIMP)'),
        findsWidgets,
      );
      expect(find.text('优腾综合管理平台(UIMP)'), findsNothing);
      expect(tester.takeException(), isNull);
      if (language == 'en') {
        await _screenshot(tester, key, 'downloads-english-name');
      }
    });
  }

  testWidgets(
    'multiple architectures remain usable with large text on a phone',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      transport.releases.add(
        transport.installer(
          id: SoftwareDownloadsTransport.arm64Id,
          architecture: 'arm64',
        ),
      );
      await _pump(
        tester,
        transport,
        SoftwarePackageSaveFixture(),
        size: const Size(375, 950),
        scale: 2,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('software-downloads-architecture')),
      );
      await tester.tap(
        find.byKey(const ValueKey('software-downloads-architecture')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ARM 64 位').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows download saves verified bytes and all other platforms remain unavailable',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      final saver = SoftwarePackageSaveFixture();
      await _pump(tester, transport, saver);
      expect(
        find.byKey(const ValueKey('software-downloads-windows')),
        findsOneWidget,
      );
      expect(find.text('暂时无法下载'), findsNWidgets(3));
      for (final platform in ['Android', 'macOS', 'iOS']) {
        expect(find.text(platform), findsOneWidget);
        expect(
          find.ancestor(
            of: find.text(platform),
            matching: find.byType(InkWell),
          ),
          findsNothing,
        );
      }
      expect(
        find.byKey(const ValueKey('software-downloads-publish')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('software-downloads-windows')),
      );
      await tester.pumpAndSettle();
      expect(saver.published.single, transport.bytes);
      expect(find.textContaining('已校验并保存：'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('architecture selection downloads its own full installer', (
    tester,
  ) async {
    final transport = SoftwareDownloadsTransport();
    transport.releases = [
      transport.installer(),
      transport.installer(
        id: SoftwareDownloadsTransport.arm64Id,
        architecture: 'arm64',
        version: '2.5.33',
      ),
    ];
    final saver = SoftwarePackageSaveFixture();
    await _pump(tester, transport, saver);
    await tester.tap(
      find.byKey(const ValueKey('software-downloads-architecture')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ARM 64 位').last);
    await tester.pumpAndSettle();
    expect(find.text('版本 2.5.33'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('software-downloads-windows')));
    await tester.pumpAndSettle();
    expect(
      transport.requests.last.path,
      '/client-updates/${SoftwareDownloadsTransport.arm64Id}/download',
    );
    expect(saver.filenames.single, endsWith('windows-arm64-setup.exe'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'publishing uses the independent permission and opens the installer dialog',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      await _pump(
        tester,
        transport,
        SoftwarePackageSaveFixture(),
        publisher: true,
      );
      await tester.tap(
        find.byKey(const ValueKey('software-downloads-publish')),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择完整客户端'), findsOneWidget);
      expect(transport.requests.last.path, '/admin/client-releases');
      expect(find.text('android'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an empty catalog shows preparation without a download button', (
    tester,
  ) async {
    final transport = SoftwareDownloadsTransport()..releases = [];
    final key = GlobalKey();
    await _pump(
      tester,
      transport,
      SoftwarePackageSaveFixture(),
      boundaryKey: key,
    );
    expect(find.text('Windows 版本正在准备'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('software-downloads-windows')),
      findsNothing,
    );
    expect(find.text('暂时无法读取版本'), findsNothing);
    expect(tester.takeException(), isNull);
    await _screenshot(tester, key, 'downloads-windows-preparing');
  });

  testWidgets(
    'a legacy Windows host never falls back to the regular installer',
    (tester) async {
      final key = GlobalKey();
      await _pump(
        tester,
        SoftwareDownloadsTransport(),
        SoftwarePackageSaveFixture(),
        runtimeFamily: ClientRuntimeFamily.wpfLegacy,
        boundaryKey: key,
      );
      expect(find.text('Windows 7 SP1 / 8.1 兼容版'), findsOneWidget);
      expect(find.text('兼容版暂未发布'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('software-downloads-windows')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _screenshot(tester, key, 'downloads-legacy-unpublished-20261028');
    },
  );

  testWidgets(
    'same-architecture families stay separate and missing x86 is not replaced by x64',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      transport.releases.add(
        transport.installer(
          id: SoftwareDownloadsTransport.arm64Id,
          mode: 'windows_wpf_setup',
          version: '1.0.0',
        )..['runtimeFamily'] = ClientRuntimeFamily.wpfLegacy,
      );
      await _pump(
        tester,
        transport,
        SoftwarePackageSaveFixture(),
        runtimeFamily: ClientRuntimeFamily.wpfLegacy,
      );
      expect(find.text('版本 1.0.0'), findsOneWidget);
      expect(find.text('版本 2.5.32'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('software-downloads-architecture')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('32 位').last);
      await tester.pumpAndSettle();
      expect(find.text('兼容版暂未发布'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('software-downloads-windows')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unbound real superadmin scope can read downloads and manage publication',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      final controller = await _pump(
        tester,
        transport,
        SoftwarePackageSaveFixture(),
        publisher: true,
        superAdmin: true,
        realControllerProvider: true,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SoftwareDownloadsPage)),
      );
      expect(container.read(sessionProvider).user!.employeeId, isNull);
      expect(container.read(sessionProvider).user!.superAdmin, isTrue);
      expect(controller.enabled, isTrue);
      expect(controller.loaded, isTrue);
      expect(
        find.byKey(const ValueKey('software-downloads-windows')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('software-downloads-publish')),
        findsOneWidget,
      );
      expect(transport.requests.single.path, '/client-updates/downloads');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed catalog read shows failure and an explicit retry', (
    tester,
  ) async {
    final transport = SoftwareDownloadsTransport()..listStatus = 503;
    await _pump(tester, transport, SoftwarePackageSaveFixture());
    expect(find.text('暂时无法读取版本'), findsOneWidget);
    expect(find.text('Windows 版本正在准备'), findsNothing);
    expect(
      find.byKey(const ValueKey('software-downloads-windows')),
      findsNothing,
    );
    transport.listStatus = 200;
    await tester.tap(find.text('刷新版本'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('software-downloads-windows')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('corrupted downloads report failure without a saved result', (
    tester,
  ) async {
    final transport = SoftwareDownloadsTransport()..packageStatus = 503;
    final saver = SoftwarePackageSaveFixture();
    await _pump(tester, transport, saver);
    await tester.tap(find.byKey(const ValueKey('software-downloads-windows')));
    await tester.pumpAndSettle();
    expect(find.text('下载未完成，请检查网络后重试。'), findsOneWidget);
    expect(find.textContaining('已校验并保存：'), findsNothing);
    expect(saver.published, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final width in [375.0, 844.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        final label =
            '${width.toInt()}-${brightness.name}-${(scale * 100).toInt()}';
        testWidgets('responsive download page $label has no overflow', (
          tester,
        ) async {
          final transport = SoftwareDownloadsTransport(byteCount: 1024 * 1024);
          final key = GlobalKey();
          await _pump(
            tester,
            transport,
            SoftwarePackageSaveFixture(),
            size: Size(width, width >= 1440 ? 1100 : 950),
            brightness: brightness,
            scale: scale,
            publisher: true,
            boundaryKey: key,
          );
          expect(
            find.byKey(const ValueKey('software-downloads-windows')),
            findsOneWidget,
          );
          expect(find.text('暂时无法下载'), findsNWidgets(3));
          expect(tester.takeException(), isNull);
          if (width == 1440 && scale == 1) {
            final monitor = find.byWidgetPredicate(
              (widget) =>
                  widget is Container && widget.constraints?.maxWidth == 320,
            );
            expect(monitor, findsOneWidget);
            final monitorSize = tester.getSize(monitor);
            expect(
              monitorSize.width,
              greaterThan(monitorSize.height),
              reason:
                  'The desktop illustration must retain a landscape monitor shape',
            );
          }
          await _screenshot(tester, key, 'downloads-$label');
          await tester.ensureVisible(find.text('iOS'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (width == 375 && scale == 2) {
            await _screenshot(tester, key, 'downloads-$label-platforms');
          }
        });
      }
    }
  }
}
