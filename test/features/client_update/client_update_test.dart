import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/client_update/client_package_download.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_update_bridge.dart';
import 'package:uten_imp/features/client_update/client_update_controller.dart';
import 'package:uten_imp/features/client_update/client_update_dialog.dart';
import 'package:uten_imp/features/client_update/client_update_host.dart';
import 'package:uten_imp/features/client_update/client_update_page.dart';
import 'package:uten_imp/features/client_update/client_update_navigation.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

late SharedPreferences preferences;

const installed = ClientInstallContext(
  platform: 'windows',
  architecture: 'x64',
  currentVersion: '2.5.27',
  currentBuild: 2527,
  supportsInPlaceUpdate: true,
);
const release = ClientRelease(
  id: '69fdcabe-0ae7-47cd-8d49-8136b21a4321',
  platform: 'windows',
  architecture: 'x64',
  version: '2.5.28',
  buildNumber: 2528,
  releaseNotes: '表格编辑更顺手\n优化任务提醒与页面加载\n修复已知问题，提升使用稳定性',
  installMode: 'windows_archive',
);
Map<String, dynamic> releaseJson({
  int build = 2528,
  String platform = 'windows',
  String architecture = 'x64',
}) => {
  'id': release.id,
  'platform': platform,
  'architecture': architecture,
  'version': release.version,
  'buildNumber': build,
  'releaseNotes': release.releaseNotes,
  'installMode': 'windows_archive',
};

class FakeApi extends ApiClient {
  FakeApi() : super(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  Map<String, dynamic> result = {
    'updateAvailable': true,
    'release': releaseJson(),
  };
  Completer<Map<String, dynamic>>? delayed;
  int checks = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    checks++;
    return delayed == null ? result : delayed!.future;
  }
}

class FakeBridge extends ClientUpdateBridge {
  @override
  Future<ClientInstallContext> context() async => installed;
}

class ReadyController extends ClientUpdateController {
  ReadyController() : super(api: FakeApi(), bridge: FakeBridge()) {
    this.installed = installed;
    this.release = release;
    stage = ClientUpdateStage.available;
  }
  int checks = 0;
  int updates = 0;
  @override
  Future<void> check({bool automatic = false}) async {
    checks++;
  }

  @override
  Future<void> update() async {
    updates++;
    stage = ClientUpdateStage.downloading;
    progress = .42;
    notifyListeners();
  }
}

Widget app(
  Widget home, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  ClientUpdateNavigation? navigation,
}) => ProviderScope(
  overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    navigatorObservers: [?navigation],
    theme: brightness == Brightness.light
        ? buildLightTheme()
        : buildDarkTheme(),
    locale: const Locale('zh'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: home,
  ),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });
  test('only newer matching platform and architecture are offered', () {
    expect(release.matches(installed), isTrue);
    for (final candidate in [
      releaseJson(build: 2527),
      releaseJson(build: 2526),
      releaseJson(platform: 'android'),
      releaseJson(architecture: 'arm64'),
    ]) {
      expect(ClientRelease.fromJson(candidate).matches(installed), isFalse);
    }
    expect(
      ClientRelease.fromJson(
        releaseJson(architecture: 'universal'),
      ).matches(installed),
      isTrue,
    );
  });

  test('store URLs cannot carry credentials or leave official domains', () {
    for (final url in [
      'https://apps.apple.com.evil.test/app/1',
      'http://apps.apple.com/app/1',
      'https://user@apps.apple.com/app/1',
      'https://apps.apple.com:9443/app/1',
      'file:///app/1',
    ]) {
      final candidate = ClientRelease.fromJson({
        ...releaseJson(platform: 'ios'),
        'storeUrl': url,
      });
      expect(candidate.trustedStoreUri, isNull);
    }
    expect(
      ClientRelease.fromJson({
        ...releaseJson(platform: 'ios'),
        'storeUrl': 'https://apps.apple.com/cn/app/id123',
      }).trustedStoreUri,
      isNotNull,
    );
  });

  test('late checks cannot revive a disposed login controller', () async {
    final api = FakeApi()..delayed = Completer();
    final controller = ClientUpdateController(api: api, bridge: FakeBridge());
    final check = controller.check();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    api.delayed!.complete(api.result);
    await check;
    expect(controller.release, isNull);
  });

  test('a malicious server candidate is not made installable', () async {
    final api = FakeApi()
      ..result = {
        'updateAvailable': true,
        'release': releaseJson(architecture: 'arm64'),
      };
    final controller = ClientUpdateController(api: api, bridge: FakeBridge());
    await controller.check();
    expect(controller.release, isNull);
    controller.dispose();
  });

  test('server polling interval is bounded and respected', () async {
    final api = FakeApi()
      ..result = {'updateAvailable': false, 'checkIntervalSeconds': 720};
    final controller = ClientUpdateController(api: api, bridge: FakeBridge());
    await controller.check();
    expect(controller.checkIntervalSeconds, 720);
    api.result['checkIntervalSeconds'] = 1;
    await controller.check();
    expect(controller.checkIntervalSeconds, 60);
    controller.dispose();
  });

  test(
    'package download keeps credentials inside relative API paths',
    () async {
      final api = ApiClient(Dio());
      for (final path in [
        'https://evil.test/update.zip',
        '//evil.test/file',
        '/client-updates/../download',
        '/client-updates/${release.id}/download?redirect=1',
      ]) {
        await expectLater(
          api.getPackageStream(path, cancelToken: CancelToken()),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'streamed packages are hashed before activation; damaged files are removed',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'uten-client-update-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final bytes = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 256),
      );
      final context = ClientInstallContext(
        platform: 'windows',
        architecture: 'x64',
        currentVersion: '2.5.27',
        currentBuild: 2527,
        stagingDirectory: directory.path,
        supportsInPlaceUpdate: true,
      );
      final metadata = {
        ...releaseJson(),
        'sizeBytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      };
      final path = await saveClientPackage(
        Stream.value(bytes),
        context,
        ClientRelease.fromJson(metadata),
        (_) {},
        () => true,
      );
      expect(await File(path).readAsBytes(), bytes);
      await removeClientPackage(path);
      await expectLater(
        saveClientPackage(
          Stream.value(Uint8List(1024)),
          context,
          ClientRelease.fromJson(metadata),
          (_) {},
          () => true,
        ),
        throwsFormatException,
      );
      expect(directory.listSync(), isEmpty);
      final attempts = await Future.wait([
        for (var index = 0; index < 2; index++)
          saveClientPackage(
            Stream.value(bytes),
            context,
            ClientRelease.fromJson(metadata),
            (_) {},
            () => true,
          ),
      ]);
      expect(attempts[0], isNot(attempts[1]));
      for (final attempt in attempts) {
        await removeClientPackage(attempt);
      }
      expect(directory.listSync(), isEmpty);
      await expectLater(
        saveClientPackage(
          Stream.value(bytes.sublist(1)),
          context,
          ClientRelease.fromJson(metadata),
          (_) {},
          () => true,
        ),
        throwsFormatException,
      );
      expect(directory.listSync(), isEmpty);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'centered offer and progress fit narrow large text in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(375, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = ReadyController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          app(
            ClientUpdatePage(controller: controller),
            brightness: brightness,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(release.releaseNotes), findsOneWidget);
        final update = find.text('立即更新');
        await tester.ensureVisible(update);
        await tester.tap(update);
        await tester.pump();
        expect(controller.updates, 1);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(update, warnIfMissed: false);
        expect(controller.updates, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('each fresh login shows the same pending release again', (
    tester,
  ) async {
    final controller = ReadyController();
    addTearDown(controller.dispose);
    Future<void> login(String key) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clientUpdateControllerProvider.overrideWithValue(controller),
          ],
          child: app(
            Builder(
              builder: (context) => Scaffold(
                body: ClientUpdateHost(
                  key: ValueKey(key),
                  enabled: true,
                  dialogContext: () => context,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    }

    await login('login-one');
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text(release.releaseNotes), findsNothing);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.byType(ClientUpdatePage), findsOneWidget);
    expect(find.text(release.releaseNotes), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    await login('login-two');
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    await login('login-three');
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'login update still appears when login returns to a business detail page',
    (tester) async {
      final controller = ReadyController();
      final navigation = ClientUpdateNavigation();
      addTearDown(controller.dispose);
      late BuildContext homeContext;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clientUpdateControllerProvider.overrideWithValue(controller),
            clientUpdateNavigationProvider.overrideWithValue(navigation),
          ],
          child: app(
            Builder(
              builder: (context) {
                homeContext = context;
                return Scaffold(
                  body: ClientUpdateHost(
                    enabled: true,
                    dialogContext: () => context,
                  ),
                );
              },
            ),
            navigation: navigation,
          ),
        ),
      );
      unawaited(
        Navigator.of(homeContext).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: '/sales/orders/example'),
            builder: (_) => const Scaffold(body: Text('business detail')),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text(release.releaseNotes), findsNothing);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(find.text('business detail'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('desktop offer preview', (tester) async {
    tester.view.physicalSize = const Size(1120, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ReadyController();
    addTearDown(controller.dispose);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: app(
          Scaffold(
            body: Center(child: ClientUpdateDialog(controller: controller)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CLIENT_UPDATE_SCREENSHOT')) {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('build/client-update-evidence');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/desktop-update.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  testWidgets('desktop details page preview', (tester) async {
    tester.view.physicalSize = const Size(1120, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ReadyController();
    addTearDown(controller.dispose);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: app(ClientUpdatePage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CLIENT_UPDATE_SCREENSHOT')) {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('build/client-update-evidence');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/desktop-update-page.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
