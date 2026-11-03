import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/streaming_download_contract.dart';
import 'package:uten_imp/features/client_update/client_update_bridge.dart';
import 'package:uten_imp/features/client_update/client_update_controller.dart';
import 'package:uten_imp/features/client_update/client_update_host.dart';
import 'package:uten_imp/features/client_update/client_auto_update_preferences.dart';
import 'package:uten_imp/features/client_update/client_staged_update.dart';
import 'package:uten_imp/core/network/user_activity.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/core/web_update/app_update_safety_host.dart';
import 'package:uten_imp/core/web_update/update_safety_navigation.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/client_update/client_update_page.dart';
import 'package:uten_imp/features/client_update/client_update_tile.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';

class _ManualUpdates extends ClientAutoUpdatePreference {
  @override
  bool build() => false;
}

const _releaseId = '69fdcabe-0ae7-47cd-8d49-8136b21a4321';

/// Runs real API parsing, controller, streamed disk download and MethodChannel
/// handoff. Only the network transport and OS installation are test fixtures.
class _CompanyServer implements HttpClientAdapter {
  final package = Uint8List.fromList(List.generate(8192, (i) => i % 251));
  final requests = <RequestOptions>[];
  Uint8List? downloadBytes;
  int downloadStatus = 200;
  int checkStatus = 200;
  bool available = true;
  Completer<void>? downloadGate;
  Map<String, Object> releaseOverrides = {};
  int get downloads =>
      requests.where((r) => r.path.endsWith('/download')).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    expectSync(options.method, 'GET');
    if (options.path == '/client-updates/check') {
      expectSync(options.queryParameters, {
        'platform': 'windows',
        'architecture': 'x64',
        'currentBuildNumber': 2527,
      });
      return ResponseBody.fromString(
        jsonEncode({
          'updateAvailable': available,
          'checkIntervalSeconds': 300,
          'release': {
            'id': _releaseId,
            'platform': 'windows',
            'architecture': 'x64',
            'version': '2.5.28',
            'buildNumber': 2528,
            'releaseNotes': '发布到公司服务器的 Windows 更新',
            'installMode': 'windows_archive',
            'sha256': sha256.convert(package).toString(),
            'sizeBytes': package.length,
            'state': 'PUBLISHED',
            ...releaseOverrides,
          },
        }),
        checkStatus,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    expectSync(options.path, '/client-updates/$_releaseId/download');
    expectSync(options.extra[streamingDownloadRequestKey], isTrue);
    expectSync(options.followRedirects, isFalse);
    await downloadGate?.future;
    final bytes = downloadBytes ?? package;
    return ResponseBody(
      Stream.fromIterable([
        Uint8List.sublistView(bytes, 0, bytes.length ~/ 2),
        Uint8List.sublistView(bytes, bytes.length ~/ 2),
      ]),
      downloadStatus,
      headers: {
        Headers.contentTypeHeader: ['application/octet-stream'],
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory staging;
  late _CompanyServer server;
  late ClientUpdateController controller;
  late List<MethodCall> installCalls;
  late Dio dio;
  bool failInstall = false;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('uten-delivery-flow-');
    server = _CompanyServer();
    installCalls = [];
    failInstall = false;
    dio = Dio(BaseOptions(baseUrl: 'https://company-fixture.test/api'))
      ..httpClientAdapter = server;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ClientUpdateBridge.channel, (call) async {
          if (call.method == 'getInstallContext') {
            return {
              'platform': 'windows',
              'architecture': 'x64',
              'currentVersion': '2.5.27',
              'currentBuild': 2527,
              'stagingDirectory': staging.path,
              'supportsInPlaceUpdate': true,
            };
          }
          expectSync(call.method, 'installUpdate');
          installCalls.add(call);
          if (failInstall) throw PlatformException(code: 'INSTALL_FAILED');
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          expectSync(arguments['buildNumber'], 2528);
          expectSync(
            arguments['sha256'],
            sha256.convert(server.package).toString(),
          );
          final file = File(arguments['packagePath'] as String);
          expectSync(await file.readAsBytes(), server.package);
          return {'status': 'installerOpened'};
        });
    controller = ClientUpdateController(
      api: ApiClient(dio),
      bridge: ClientUpdateBridge(),
    );
  });

  tearDown(() async {
    if (!controller.isDisposed) controller.dispose();
    dio.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ClientUpdateBridge.channel, null);
    // Windows Defender can briefly hold a freshly verified package; retry
    // instead of failing the delivery flow on a transient sharing violation.
    for (var attempt = 0; ; attempt++) {
      try {
        await staging.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 10) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test(
    'old Windows discovers the release and explicit update hands off verified bytes once',
    () async {
      await controller.check(automatic: true);
      expect(controller.release?.id, _releaseId);
      expect(controller.stage, ClientUpdateStage.available);
      expect(server.downloads, 0);
      expect(installCalls, isEmpty);
      await Future.wait([
        controller.update(),
        controller.update(),
        controller.update(),
      ]);
      expect(server.downloads, 1);
      expect(installCalls, hasLength(1));
      expect(controller.stage, ClientUpdateStage.installerOpened);
      expect(controller.error, isNull);
      expect(controller.progress, 1);
    },
  );

  test(
    'verified staging survives logout and local apply makes no new HTTP requests',
    () async {
      await controller.check();
      await controller.prepareUpdate();
      final store = controller.stagedUpdates;
      expect(store.update, isNotNull);
      expect(installCalls, isEmpty);
      final requests = server.requests.length;
      controller.dispose();
      expect(
        await store.apply(
          bridge: ClientUpdateBridge(),
          isSafe: () => true,
          automatic: true,
        ),
        isTrue,
      );
      expect(server.requests.length, requests);
      expect(installCalls, hasLength(1));
    },
  );

  test(
    'work becoming dirty after package verification cancels install and retains staging',
    () async {
      await controller.check();
      await controller.prepareUpdate();
      var safe = true;
      final store = controller.stagedUpdates;
      expect(
        await store.apply(
          bridge: ClientUpdateBridge(),
          isSafe: () => safe,
          verifySession: () async => safe = false,
        ),
        isFalse,
      );
      expect(installCalls, isEmpty);
      expect(store.update, isNotNull);
      expect(store.applying, isFalse);
      safe = true;
      expect(
        await store.apply(bridge: ClientUpdateBridge(), isSafe: () => safe),
        isTrue,
      );
      expect(installCalls, hasLength(1));
    },
  );

  for (final change in ['withdrawn', 'digest', 'build']) {
    test(
      'authoritative $change check invalidates the package before a later logout',
      () async {
        await controller.check();
        await controller.prepareUpdate();
        final store = controller.stagedUpdates;
        if (change == 'withdrawn') {
          server.available = false;
        } else if (change == 'digest') {
          server.releaseOverrides = {'sha256': '0' * 64};
        } else {
          server.releaseOverrides = {'buildNumber': 2529};
        }
        await controller.check();
        expect(store.update, isNull);
        controller.dispose();
        expect(
          await store.apply(
            bridge: ClientUpdateBridge(),
            isSafe: () => true,
            automatic: true,
          ),
          isFalse,
        );
        expect(installCalls, isEmpty);
      },
    );
  }

  test(
    'a transient offline check preserves a previously verified package',
    () async {
      await controller.check();
      await controller.prepareUpdate();
      final store = controller.stagedUpdates;
      final original = store.update;
      server.checkStatus = 503;
      await controller.check(automatic: true);
      expect(identical(store.update, original), isTrue);
      expect(installCalls, isEmpty);
    },
  );

  test('tampered staged bytes cannot reach the OS installer', () async {
    await controller.check();
    await controller.prepareUpdate();
    final store = controller.stagedUpdates;
    await File(
      store.update!.path,
    ).writeAsBytes(Uint8List(server.package.length));
    await expectLater(
      store.apply(
        bridge: ClientUpdateBridge(),
        isSafe: () => true,
        automatic: true,
      ),
      throwsFormatException,
    );
    expect(installCalls, isEmpty);
    expect(store.update, isNull);
    await controller.update();
    expect(server.downloads, 2);
    expect(installCalls, hasLength(1));
    expect(controller.error, isNull);
    expect(controller.stage, ClientUpdateStage.installerOpened);
  });

  test('an automatic installer failure is latched for that release', () async {
    await controller.check();
    await controller.prepareUpdate();
    final store = controller.stagedUpdates;
    failInstall = true;
    await expectLater(
      store.apply(
        bridge: ClientUpdateBridge(),
        isSafe: () => true,
        automatic: true,
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(installCalls, hasLength(1));
    expect(store.mayApplyAutomatically(store.update!), isFalse);
    expect(
      await store.apply(
        bridge: ClientUpdateBridge(),
        isSafe: () => true,
        automatic: true,
      ),
      isFalse,
    );
    expect(installCalls, hasLength(1));
  });

  Future<void> pumpIdleLoginHost(
    WidgetTester tester, {
    required ClientStagedUpdateStore store,
    required GlobalKey<NavigatorState> navigator,
  }) async {
    await tester.runAsync(() async {
      await controller.check();
      await controller.prepareUpdate();
    });
    final staged = store.update;
    expect(staged, isNotNull);
    controller.dispose();
    UserActivity.reset();
    UserActivity.clock = () => tester.binding.clock.now();
    addTearDown(UserActivity.reset);
    webUpdateSafety.setReady(true);
    var dirty = true;
    final owner = Object();
    webUpdateSafety.register(owner, () => WebUpdateSafetyState(dirty: dirty));
    addTearDown(() => webUpdateSafety.unregister(owner));
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clientStagedUpdateStoreProvider.overrideWithValue(store),
          clientUpdateBridgeProvider.overrideWithValue(ClientUpdateBridge()),
          clientUpdateControllerProvider.overrideWith(
            (ref) => throw StateError(
              'Login must not acquire an authenticated controller',
            ),
          ),
          platformBrandingSnapshotProvider.overrideWithValue(
            PlatformBranding.defaults,
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ClientUpdateHost(
              enabled: true,
              authenticated: false,
              dialogContext: () => navigator.currentContext,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 90));
    expect(find.byType(AlertDialog), findsNothing);
    expect(installCalls, isEmpty);
    dirty = false;
    webUpdateSafety.changed();
    UserActivity.record();
    await tester.pump(const Duration(seconds: 50));
    expect(find.byType(AlertDialog), findsNothing);
    expect(installCalls, isEmpty);
  }

  // Staged-package verification, the installer handoff and every file handle
  // release perform real I/O that fake async cannot drive alone. Alternate
  // real event-loop spins with clock flushes so the whole chain settles; a
  // fixed count also drains work scheduled after the handoff.
  Future<void> flushInstallChain(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpSettings(
    WidgetTester tester, {
    bool host = false,
    bool openUpdate = true,
  }) async {
    // Use the production safety gate and both real navigation layers, rather
    // than the controller's permissive unit-test default.
    controller.dispose();
    controller = ClientUpdateController(
      api: ApiClient(dio),
      bridge: ClientUpdateBridge(),
      canInstall: () => webUpdateSafety.safeToReload,
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    webUpdateSafety.setReady(true);
    final rootSafety = UpdateSafetyNavigation();
    final shellSafety = UpdateSafetyNavigation();
    final navigator = GlobalKey<NavigatorState>();
    final router = GoRouter(
      navigatorKey: navigator,
      initialLocation: RouteName.settings,
      observers: [rootSafety],
      routes: [
        ShellRoute(
          observers: [shellSafety],
          builder: (_, _, child) => child,
          routes: [
            GoRoute(
              path: RouteName.settings,
              builder: (_, _) => const Scaffold(body: ClientUpdateTile()),
            ),
          ],
        ),
      ],
    );
    addTearDown(() {
      router.dispose();
      rootSafety.dispose();
      shellSafety.dispose();
      webUpdateSafety.setReady(false);
    });
    tester.view.physicalSize = const Size(1000, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clientUpdateControllerProvider.overrideWithValue(controller),
          clientStagedUpdateStoreProvider.overrideWithValue(
            controller.stagedUpdates,
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
          platformBrandingSnapshotProvider.overrideWithValue(
            PlatformBranding.defaults,
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) => Column(
            children: [
              AppUpdateSafetyHost(router: router),
              if (host)
                ClientUpdateHost(
                  enabled: true,
                  dialogContext: () => navigator.currentContext,
                ),
              Expanded(child: child!),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (openUpdate) {
      await tester.tap(find.byType(ClientUpdateTile));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'settings update installs with the production route safety gate',
    (tester) async {
      await pumpSettings(tester);
      await tester.tap(find.byKey(const ValueKey('client-update-now')));
      await flushInstallChain(tester);
      expect(installCalls, hasLength(1));
      expect(controller.waitingForSafeInstall, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a downloaded update survives re-entry and rapid install requests hand off once',
    (tester) async {
      await pumpSettings(tester);
      await tester.runAsync(controller.prepareUpdate);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('client-update-package-ready')),
        findsOneWidget,
      );
      await tester.tap(find.byType(UtenBackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ClientUpdateTile));
      await tester.pumpAndSettle();
      expect(controller.hasStagedUpdate, isTrue);
      final requests = List.generate(50, (_) => controller.installPrepared());
      await flushInstallChain(tester);
      await Future.wait(requests);
      expect(server.downloads, 1);
      expect(installCalls, hasLength(1));
      expect(controller.error, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'installer failure stays actionable and retry clears the error without redownloading',
    (tester) async {
      await pumpSettings(tester);
      failInstall = true;
      await tester.tap(find.byKey(const ValueKey('client-update-now')));
      await flushInstallChain(tester);
      expect(controller.stage, ClientUpdateStage.failed);
      expect(find.text('更新未完成'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(controller.hasStagedUpdate, isTrue);
      failInstall = false;
      await tester.tap(find.byKey(const ValueKey('client-update-now')));
      await flushInstallChain(tester);
      expect(server.downloads, 1);
      expect(installCalls, hasLength(2));
      expect(controller.error, isNull);
      expect(controller.stage, ClientUpdateStage.installerOpened);
      expect(find.text('更新未完成'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('settings update returns through the root above a nested shell', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.byType(UtenBackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ClientUpdatePage), findsNothing);
    expect(find.byType(ClientUpdateTile), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final blocker in ['dirty', 'busy', 'blocked']) {
    testWidgets(
      '$blocker work gives feedback and a saved retry installs once',
      (tester) async {
        var blocked = true;
        final owner = Object();
        webUpdateSafety.register(
          owner,
          () => WebUpdateSafetyState(
            dirty: blocked && blocker == 'dirty',
            busy: blocked && blocker == 'busy',
            blocked: blocked && blocker == 'blocked',
          ),
        );
        addTearDown(() => webUpdateSafety.unregister(owner));
        await pumpSettings(tester);
        await tester.tap(find.byKey(const ValueKey('client-update-now')));
        await flushInstallChain(tester);
        expect(installCalls, isEmpty);
        expect(controller.waitingForSafeInstall, isTrue);
        final message = tester
            .widget<Text>(
              find.byKey(const ValueKey('client-update-install-wait')),
            )
            .data!;
        expect(
          message,
          contains(switch (blocker) {
            'dirty' => '保存正在编辑的内容',
            'busy' => '等待当前操作完成',
            _ => '处理未完成的操作',
          }),
        );
        blocked = false;
        webUpdateSafety.changed();
        await tester.pumpAndSettle();
        expect(find.text('更新已下载，可以点击“立即更新”继续安装。'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('client-update-now')));
        await flushInstallChain(tester);
        expect(server.downloads, 1);
        expect(installCalls, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('background preparation leaves the settings return usable', (
    tester,
  ) async {
    await pumpSettings(tester);
    final download = controller.prepareUpdate();
    expect(controller.stage, ClientUpdateStage.downloading);
    expect(controller.blocksNavigation, isFalse);
    await tester.pump();
    expect(
      tester.widget<UtenBackButton>(find.byType(UtenBackButton)).enabled,
      isTrue,
    );
    await tester.tap(find.byType(UtenBackButton));
    await flushInstallChain(tester);
    await download;
    await tester.pumpAndSettle();
    expect(find.byType(ClientUpdatePage), findsNothing);
    expect(find.byType(ClientUpdateTile), findsOneWidget);
    expect(
      controller.hasStagedUpdate,
      isTrue,
      reason: '${controller.stage}: ${controller.error}',
    );
    expect(installCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('default-on automatic download still announces the new release', (
    tester,
  ) async {
    server.downloadGate = Completer<void>();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          clientUpdateControllerProvider.overrideWithValue(controller),
          platformBrandingSnapshotProvider.overrideWithValue(
            PlatformBranding.defaults,
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ClientUpdateHost(
              enabled: true,
              dialogContext: () => navigator.currentContext,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await flushInstallChain(tester);
    expect(find.text('有新的版本（2.5.28）'), findsOneWidget);
    expect(controller.stage, ClientUpdateStage.downloading);
    expect(installCalls, isEmpty);
    server.downloadGate!.complete();
    await flushInstallChain(tester);
    expect(controller.hasStagedUpdate, isTrue);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 5));
    await flushInstallChain(tester);
    expect(find.text('有新的版本（2.5.28）'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an untouched startup offer becomes the idle countdown and installs',
    (tester) async {
      UserActivity.reset();
      UserActivity.clock = () => tester.binding.clock.now();
      addTearDown(UserActivity.reset);
      await pumpSettings(tester, host: true, openUpdate: false);
      await tester.pump(const Duration(seconds: 2));
      await flushInstallChain(tester);
      expect(find.text('查看详情'), findsOneWidget);
      expect(controller.hasStagedUpdate, isTrue);
      expect(installCalls, isEmpty);
      await tester.pump(const Duration(minutes: 5));
      // The first tick dismisses this exact offer. A later tick opens countdown.
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('查看详情'), findsNothing);
      expect(find.textContaining(RegExp('立即更新（\\d+）')), findsOneWidget);
      expect(installCalls, isEmpty);
      await tester.pump(const Duration(seconds: 12));
      await flushInstallChain(tester);
      expect(installCalls, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'default-on staged login update waits for clean idle, counts down and installs at zero',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await pumpIdleLoginHost(
        tester,
        store: controller.stagedUpdates,
        navigator: navigator,
      );
      final requests = server.requests.length;
      // 60s clean idle at the login screen shows the visible countdown.
      await tester.pump(const Duration(seconds: 15));
      expect(find.text('有新的版本（2.5.28）'), findsOneWidget);
      expect(find.textContaining(RegExp('立即更新（\\d+）')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(installCalls, isEmpty);
      // The countdown reaches zero and the verified package installs itself.
      await tester.pump(const Duration(seconds: 12));
      await flushInstallChain(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(installCalls, hasLength(1));
      expect(server.requests.length, requests);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'viewing update details does not suppress clean idle installation',
    (tester) async {
      UserActivity.reset();
      UserActivity.clock = () => tester.binding.clock.now();
      addTearDown(UserActivity.reset);
      await pumpSettings(tester, host: true, openUpdate: false);
      await tester.pump(const Duration(seconds: 2));
      await flushInstallChain(tester);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.byType(ClientUpdatePage), findsOneWidget);
      expect(controller.hasStagedUpdate, isTrue);
      await tester.pump(const Duration(minutes: 5));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining(RegExp('立即更新（\\d+）')), findsOneWidget);
      await tester.pump(const Duration(seconds: 12));
      await flushInstallChain(tester);
      expect(installCalls, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cancel during the countdown keeps the program until a fresh idle window',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await pumpIdleLoginHost(
        tester,
        store: controller.stagedUpdates,
        navigator: navigator,
      );
      await tester.pump(const Duration(seconds: 15));
      expect(find.textContaining(RegExp('立即更新（\\d+）')), findsOneWidget);
      await tester.tap(find.text('稍后'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(installCalls, isEmpty);
      // The click itself counts as input: no new offer before a fresh idle
      // window, and cancelling never installs by itself.
      UserActivity.record();
      await tester.pump(const Duration(seconds: 59));
      expect(find.byType(AlertDialog), findsNothing);
      expect(installCalls, isEmpty);
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining(RegExp('立即更新（\\d+）')), findsOneWidget);
      expect(installCalls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the primary button installs immediately without waiting for the countdown',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await pumpIdleLoginHost(
        tester,
        store: controller.stagedUpdates,
        navigator: navigator,
      );
      await tester.pump(const Duration(seconds: 15));
      final primary = find.textContaining(RegExp('立即更新（\\d+）'));
      expect(primary, findsOneWidget);
      await tester.tap(primary);
      await tester.pump(const Duration(seconds: 2));
      await flushInstallChain(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(installCalls, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final failure in ['checksum', 'truncated', 'withdrawn']) {
    test(
      '$failure download cannot reach installation and a later valid retry works',
      () async {
        await controller.check();
        if (failure == 'checksum') {
          server.downloadBytes = Uint8List(server.package.length);
        } else if (failure == 'truncated') {
          server.downloadBytes = Uint8List.sublistView(server.package, 0, 100);
        } else {
          server.downloadStatus = 403;
        }
        await controller.update();
        expect(controller.stage, ClientUpdateStage.failed);
        expect(controller.error, isNotNull);
        expect(installCalls, isEmpty);
        expect(staging.listSync(), isEmpty);
        server.downloadBytes = null;
        server.downloadStatus = 200;
        await controller.update();
        expect(controller.stage, ClientUpdateStage.installerOpened);
        expect(installCalls, hasLength(1));
      },
    );
  }

  testWidgets(
    'running old Windows receives the update offer and details before downloading',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clientUpdateControllerProvider.overrideWithValue(controller),
            clientAutoUpdateEnabledProvider.overrideWith(_ManualUpdates.new),
            platformBrandingSnapshotProvider.overrideWithValue(
              PlatformBranding.defaults,
            ),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ClientUpdateHost(
                enabled: true,
                dialogContext: () => navigator.currentContext,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('有新的版本（2.5.28）'), findsOneWidget);
      expect(server.downloads, 0);
      expect(installCalls, isEmpty);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('发布到公司服务器的 Windows 更新'), findsOneWidget);
      expect(find.text('立即更新'), findsOneWidget);
      expect(server.downloads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
