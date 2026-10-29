import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    expect(options.method, 'GET');
    if (options.path == '/client-updates/check') {
      expect(options.queryParameters, {
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
    expect(options.path, '/client-updates/$_releaseId/download');
    expect(options.extra[streamingDownloadRequestKey], isTrue);
    expect(options.followRedirects, isFalse);
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
          expect(call.method, 'installUpdate');
          installCalls.add(call);
          if (failInstall) throw PlatformException(code: 'INSTALL_FAILED');
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          expect(arguments['buildNumber'], 2528);
          expect(
            arguments['sha256'],
            sha256.convert(server.package).toString(),
          );
          final file = File(arguments['packagePath'] as String);
          expect(await file.readAsBytes(), server.package);
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
    expect(store.mayApplyAutomatically(store.update!), isFalse);
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

  testWidgets(
    'default-on staged login update waits for clean idle, counts down and installs at zero',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await pumpIdleLoginHost(tester, store: controller.stagedUpdates, navigator: navigator);
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
    'cancel during the countdown keeps the program until a fresh idle window',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await pumpIdleLoginHost(tester, store: controller.stagedUpdates, navigator: navigator);
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
      await pumpIdleLoginHost(tester, store: controller.stagedUpdates, navigator: navigator);
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
