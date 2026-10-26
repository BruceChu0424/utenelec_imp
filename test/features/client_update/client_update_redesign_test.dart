import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/brand/uten_brand_mascot.dart';
import 'package:uten_imp/core/constants/assets.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_anim.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_update_bridge.dart';
import 'package:uten_imp/features/client_update/client_update_controller.dart';
import 'package:uten_imp/features/client_update/client_update_page.dart';
import 'package:uten_imp/features/client_update/client_update_tile.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

late SharedPreferences _preferences;
const _id = 'db7b8e64-12b8-4d56-b1ca-d095b857fd21';
const _notes = '优化表格编辑和任务提醒\n保留已保存的草稿与本机设置';

class _Api extends ApiClient {
  _Api()
    : super(Dio(BaseOptions(baseUrl: 'https://company-fixture.invalid/api')));
  final bytes = Uint8List.fromList([0x50, 0x4b, 3, 4, 10, 20, 30, 40]);
  int checks = 0, downloads = 0;
  final queries = <Map<String, dynamic>>[];
  bool available = false;
  Object? failure;
  Completer<Map<String, dynamic>>? delayed;
  StreamController<Uint8List>? chunks;

  Map<String, dynamic> get result => {
    'updateAvailable': available,
    'checkIntervalSeconds': 300,
    if (available)
      'release': {
        'id': _id,
        'platform': 'windows',
        'architecture': 'x64',
        'version': '2.5.32',
        'buildNumber': 2532,
        'releaseNotes': _notes,
        'installMode': 'windows_archive',
        'packageKind': 'update',
        'sha256': sha256.convert(bytes).toString(),
        'sizeBytes': bytes.length,
        'state': 'PUBLISHED',
      },
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/client-updates/check');
    checks++;
    queries.add(Map.of(query ?? {}));
    if (failure != null) throw failure!;
    return delayed?.future ?? result;
  }

  @override
  Future<Stream<Uint8List>> getPackageStream(
    String path, {
    required CancelToken cancelToken,
  }) async {
    expect(path, '/client-updates/$_id/download');
    downloads++;
    return chunks?.stream ?? Stream.value(bytes);
  }
}

class _Bridge extends ClientUpdateBridge {
  _Bridge({this.staging = ''});
  final String staging;
  int contexts = 0, installs = 0;
  @override
  Future<ClientInstallContext> context() async {
    contexts++;
    return ClientInstallContext(
      platform: 'windows',
      architecture: 'x64',
      currentVersion: '2.5.31',
      currentBuild: 2531,
      supportsInPlaceUpdate: true,
      stagingDirectory: staging,
    );
  }

  @override
  Future<String> install(String path, ClientRelease release) async {
    installs++;
    expect(release.id, _id);
    // No MethodChannel, process execution, installation or window closing.
    return 'installerOpened';
  }
}

class _Tier extends PerformanceNotifier {
  _Tier(this.initial);
  final PerformanceTier initial;
  @override
  PerformanceTier build() => initial;
}

class _Harness {
  _Harness(this.api, {this.bridgeOverride});
  final _Api api;
  final _Bridge? bridgeOverride;
  final navigator = GlobalKey<NavigatorState>();
  final boundary = GlobalKey();
  final scale = ValueNotifier<double>(1);
  late final bridge = bridgeOverride ?? _Bridge();
  late final controller = ClientUpdateController(api: api, bridge: bridge);

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1440, 1100),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool tile = false,
    bool reducedMotion = false,
    bool tickers = true,
    PerformanceTier tier = PerformanceTier.standard,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(scale.dispose);
    addTearDown(() {
      if (!controller.isDisposed) controller.dispose();
    });
    scale.value = textScale;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(_preferences),
          performanceProvider.overrideWith(() => _Tier(tier)),
          clientUpdateControllerProvider.overrideWithValue(controller),
          apiClientProvider.overrideWithValue(api),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          debugShowCheckedModeBanner: false,
          scrollBehavior: const UtenScrollBehavior(),
          theme: auditScreenshotTheme(
            brightness == Brightness.light
                ? buildLightTheme()
                : buildDarkTheme(),
          ),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ValueListenableBuilder<double>(
            valueListenable: scale,
            builder: (context, value, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(value),
                disableAnimations: reducedMotion,
              ),
              child: TickerMode(
                enabled: tickers,
                child: RepaintBoundary(key: boundary, child: child!),
              ),
            ),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => tile
                  ? const ClientUpdateTile()
                  : TextButton(
                      key: const ValueKey('redesign-open'),
                      onPressed: () =>
                          openClientUpdatePage(context, controller),
                      child: const Text('打开软件更新'),
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, {bool tile = false}) async {
    await tester.tap(
      tile
          ? find.byType(ClientUpdateTile)
          : find.byKey(const ValueKey('redesign-open')),
    );
    await tester.pump();
    await tester.pump(UtenAnim.normal);
    await tester.pump();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CLIENT_UPDATE_REDESIGN_SCREENSHOTS'))
      return;
    final mascot = find.byType(UtenBrandMascot);
    final image = tester.widget<Image>(
      find.descendant(of: mascot, matching: find.byType(Image)),
    );
    expect((image.image as AssetImage).assetName, UtenAssets.logoIp);
    Object? decodeError;
    await tester.runAsync(
      () => precacheImage(
        const AssetImage(UtenAssets.logoIp),
        tester.element(mascot),
        onError: (error, stack) => decodeError = error,
      ),
    );
    expect(
      decodeError,
      isNull,
      reason: 'the real bundled anime IP must decode before capture',
    );
    await tester.pump();
    await tester.pump(UtenAnim.fast);
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(
          'build/client-update-redesign-20261026/previews',
        );
        await directory.create(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }
}

Future<void> _wait(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 30 && !condition(); attempt++) {
    await tester.pump(UtenAnim.fast);
  }
  expect(condition(), isTrue);
}

Finder get _back => find.byType(UtenBackButton);
Finder get _check => find.byKey(const ValueKey('client-update-check'));
Finder get _update => find.byKey(const ValueKey('client-update-now'));
RotationTransition _mark(WidgetTester tester) =>
    tester.widget<RotationTransition>(
      find.descendant(
        of: find.byKey(const ValueKey('client-update-visual')),
        matching: find.byType(RotationTransition),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
    if (const bool.fromEnvironment('CLIENT_UPDATE_REDESIGN_SCREENSHOTS')) {
      final font = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      await (FontLoader('NotoSansSC')..addFont(Future.value(font))).load();
      await (FontLoader('Roboto')..addFont(Future.value(font))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  testWidgets(
    'every page entry checks once while rebuilds and animation frames do not',
    (tester) async {
      final api = _Api()..delayed = Completer<Map<String, dynamic>>();
      final harness = _Harness(api);
      await harness.mount(tester);
      await harness.open(tester);
      expect(api.checks, 1);
      expect(harness.controller.stage, ClientUpdateStage.checking);
      expect(find.text('正在检查更新'), findsWidgets);
      harness.controller.notifyListeners();
      harness.scale.value = 1.2;
      await tester.pump(UtenAnim.normal);
      await tester.pump(UtenAnim.normal);
      expect(api.checks, 1);
      api.delayed!.complete(api.result);
      await tester.pumpAndSettle();
      expect(find.text('当前已是最新版本'), findsWidgets);
      expect(find.text('更新内容'), findsNothing);
      expect(find.text('此版本暂无更新说明。'), findsNothing);
      await tester.tap(_back);
      await tester.pumpAndSettle();
      api.delayed = null;
      await harness.open(tester);
      await tester.pumpAndSettle();
      expect(api.checks, 2);
      expect(api.queries.last, {
        'platform': 'windows',
        'architecture': 'x64',
        'currentBuildNumber': 2531,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening from the real settings tile does not also perform a second check',
    (tester) async {
      final api = _Api();
      final harness = _Harness(api);
      await harness.mount(tester, tile: true);
      await harness.open(tester, tile: true);
      await tester.pumpAndSettle();
      expect(api.checks, 1);
      expect(find.byType(ClientUpdatePage), findsOneWidget);
      await tester.tap(_back);
      await tester.pumpAndSettle();
      await harness.open(tester, tile: true);
      await tester.pumpAndSettle();
      expect(api.checks, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual checking transitions from current to a newer version and notes',
    (tester) async {
      final api = _Api();
      final harness = _Harness(api);
      await harness.mount(tester);
      await harness.open(tester);
      await tester.pumpAndSettle();
      expect(find.text('更新内容'), findsNothing);
      api.available = true;
      api.delayed = Completer<Map<String, dynamic>>();
      await tester.ensureVisible(_check);
      await tester.tap(_check);
      await tester.pump();
      expect(harness.controller.stage, ClientUpdateStage.checking);
      expect(find.text('正在检查更新'), findsWidgets);
      api.delayed!.complete(api.result);
      await tester.pumpAndSettle();
      expect(api.checks, 2);
      expect(find.textContaining('2.5.32'), findsWidgets);
      expect(find.text(_notes), findsOneWidget);
      expect(_update, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed automatic page-entry check is never presented as up to date',
    (tester) async {
      final api = _Api()
        ..failure = ApiException('FIXTURE_UNAVAILABLE', '本机测试检查失败');
      final harness = _Harness(api);
      await harness.mount(tester);
      await harness.open(tester);
      await tester.pumpAndSettle();
      expect(api.checks, 1);
      expect(harness.controller.error, isNotNull);
      expect(harness.controller.stage, ClientUpdateStage.failed);
      expect(find.text('当前已是最新版本'), findsNothing);
      expect(find.text('正在检查更新'), findsNothing);
      expect(_check, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a later failed check supersedes the old successful-current message',
    (tester) async {
      final api = _Api();
      final harness = _Harness(api);
      await harness.mount(tester);
      await harness.open(tester);
      await tester.pumpAndSettle();
      expect(harness.controller.hasSuccessfulCheck, isTrue);
      await tester.tap(_back);
      await tester.pumpAndSettle();
      api.failure = ApiException('FIXTURE_UNAVAILABLE', '本机测试检查失败');
      await harness.open(tester);
      await tester.pumpAndSettle();
      expect(api.checks, 2);
      expect(harness.controller.error, isNotNull);
      expect(find.text('当前已是最新版本'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the check visual moves only while checking and stops when current',
    (tester) async {
      final api = _Api()..delayed = Completer<Map<String, dynamic>>();
      final harness = _Harness(api);
      await harness.mount(tester);
      await harness.open(tester);
      final start = _mark(tester).turns.value;
      await tester.pump(UtenAnim.fast);
      expect(_mark(tester).turns.value, isNot(start));
      expect(api.checks, 1);
      await harness.capture(tester, 'checking-1440-light');
      api.delayed!.complete(api.result);
      await tester.pumpAndSettle();
      expect(_mark(tester).turns.value, 0);
      await tester.pump(UtenAnim.slow);
      expect(_mark(tester).turns.value, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(api.checks, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final quiet in ['lite', 'accessibility', 'tickers']) {
    testWidgets('$quiet keeps the pending check visual static', (tester) async {
      final api = _Api()..delayed = Completer<Map<String, dynamic>>();
      final harness = _Harness(api);
      await harness.mount(
        tester,
        tier: quiet == 'lite' ? PerformanceTier.lite : PerformanceTier.standard,
        reducedMotion: quiet == 'accessibility',
        tickers: quiet != 'tickers',
      );
      await harness.open(tester);
      expect(harness.controller.stage, ClientUpdateStage.checking);
      expect(_mark(tester).turns.value, 0);
      await tester.pump(UtenAnim.slow);
      expect(_mark(tester).turns.value, 0);
      expect(api.checks, 1);
      api.delayed!.complete(api.result);
      await tester.pump();
      await tester.pump(UtenAnim.normal);
      expect(harness.controller.stage, ClientUpdateStage.idle);
      expect(_mark(tester).turns.value, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      '1920 ${brightness.name} current status stays centered within 760 without empty notes',
      (tester) async {
        final harness = _Harness(_Api());
        await harness.mount(
          tester,
          size: const Size(1920, 1080),
          brightness: brightness,
        );
        await harness.open(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('client-update-notes')), findsNothing);
        expect(find.byType(UtenBrandMascot), findsOneWidget);
        final image = tester.widget<Image>(
          find.descendant(
            of: find.byType(UtenBrandMascot),
            matching: find.byType(Image),
          ),
        );
        expect((image.image as AssetImage).assetName, UtenAssets.logoIp);
        final bounded = find.ancestor(
          of: find.byKey(const ValueKey('client-update-status')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is ConstrainedBox && widget.constraints.maxWidth == 760,
          ),
        );
        expect(bounded, findsOneWidget);
        final rect = tester.getRect(bounded);
        expect(rect.width, lessThanOrEqualTo(760));
        expect((rect.center.dx - 960).abs(), lessThanOrEqualTo(16));
        await harness.capture(tester, 'current-1920-${brightness.name}');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [
    const Size(375, 1000),
    const Size(844, 390),
    const Size(1920, 1080),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'update status is bounded and its back action inset/reachable at 2x $size ${brightness.name}',
        (tester) async {
          final api = _Api()..available = true;
          final harness = _Harness(api);
          await harness.mount(
            tester,
            size: size,
            brightness: brightness,
            textScale: 2,
          );
          await harness.open(tester);
          await tester.pumpAndSettle();
          expect(api.checks, 1);
          final back = find.descendant(
            of: _back,
            matching: find.byType(IconButton),
          );
          final rect = tester.getRect(back);
          expect(rect.left, greaterThanOrEqualTo(12));
          expect(rect.width, greaterThanOrEqualTo(24));
          expect(rect.height, greaterThanOrEqualTo(24));
          expect(back.hitTestable(), findsOneWidget);
          await harness.capture(
            tester,
            'available-${size.width.toInt()}-${brightness.name}-2x-initial',
          );
          await tester.ensureVisible(_update);
          await tester.pumpAndSettle();
          expect(_update.hitTestable(), findsOneWidget);
          await tester.ensureVisible(find.text(_notes));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await harness.capture(
            tester,
            'available-${size.width.toInt()}-${brightness.name}-2x',
          );
          await tester.tap(back);
          await tester.pumpAndSettle();
          expect(find.byType(ClientUpdatePage), findsNothing);
        },
      );
    }
  }

  testWidgets(
    'synthetic download blocks back and duplicate update without executing an installer',
    (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('uten-update-redesign-'),
      );
      final bridge = _Bridge(staging: directory!.path);
      final api = _Api()..available = true;
      api.chunks = StreamController<Uint8List>();
      final harness = _Harness(api, bridgeOverride: bridge);
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      await harness.mount(tester);
      await harness.open(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_update);
      await tester.tap(_update);
      await _wait(tester, () => api.downloads == 1);
      expect(harness.controller.transferBusy, isTrue);
      await tester.tap(_back);
      await tester.pump();
      expect(find.byType(ClientUpdatePage), findsOneWidget);
      await harness.navigator.currentState!.maybePop();
      await tester.pump();
      expect(find.byType(ClientUpdatePage), findsOneWidget);
      await harness.controller.update();
      expect(api.downloads, 1);
      expect(bridge.installs, 0);
      expect(tester.widget<UtenButton>(_update).onPressed, isNull);
      api.chunks!.add(api.bytes);
      unawaited(api.chunks!.close());
      for (
        var frame = 0;
        frame < 60 && harness.controller.transferBusy;
        frame++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(UtenAnim.fast);
      }
      expect(harness.controller.stage, ClientUpdateStage.installerOpened);
      expect(api.downloads, 1);
      expect(bridge.installs, 1);
      expect(tester.widget<UtenButton>(_update).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
