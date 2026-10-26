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

const _releaseId = '69fdcabe-0ae7-47cd-8d49-8136b21a4321';

/// Runs real API parsing, controller, streamed disk download and MethodChannel
/// handoff. Only the network transport and OS installation are test fixtures.
class _CompanyServer implements HttpClientAdapter {
  final package = Uint8List.fromList(List.generate(8192, (i) => i % 251));
  final requests = <RequestOptions>[];
  Uint8List? downloadBytes;
  int downloadStatus = 200;
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
          'updateAvailable': true,
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
          },
        }),
        200,
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

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('uten-delivery-flow-');
    server = _CompanyServer();
    installCalls = [];
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
    controller.dispose();
    dio.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ClientUpdateBridge.channel, null);
    await staging.delete(recursive: true);
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
      expect(find.text('发现新版本'), findsOneWidget);
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
