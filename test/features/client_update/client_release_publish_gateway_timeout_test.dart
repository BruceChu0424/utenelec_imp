import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/write_deadline_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/features/client_update/client_release_publish_queue.dart';

const _id = '11111111-1111-1111-1111-111111111111';

class _Adapter implements HttpClientAdapter {
  final sent = <RequestOptions>[];
  Future<Object?> Function(RequestOptions)? response;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add(options);
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody.fromString(
      jsonEncode(await response?.call(options) ?? <String, dynamic>{}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({Dio dio, _Adapter adapter, ApiClientReleasePublishGateway gateway})
  fixture({bool web = false}) {
    final registry = WebUpdateSafetyRegistry();
    addTearDown(registry.dispose);
    final dio = Dio(buildApiBaseOptions('https://fixture.test/api'));
    final adapter = _Adapter();
    dio.httpClientAdapter = adapter;
    dio.interceptors.addAll([
      WriteDeadlineInterceptor(enabled: web),
      SafeRequestRetryInterceptor(dio, delay: (_) async {}, web: web),
    ]);
    addTearDown(() => dio.close(force: true));
    final api = ApiClient(
      dio,
      reloadSafety: ApiMutationReloadSafety(registry: registry),
    );
    return (
      dio: dio,
      adapter: adapter,
      gateway: ApiClientReleasePublishGateway(api),
    );
  }

  for (final web in [false, true]) {
    test(
      'only publish receives five minutes; other budgets stay owned ($web)',
      () async {
        final f = fixture(web: web);
        await f.gateway.begin(() => true);
        await f.gateway.prepare({'requestId': _id});
        await f.gateway.publish(_id);
        await f.gateway.withdraw(_id);
        await f.gateway.upload(_id, Uint8List.fromList([1, 2, 3]), (_, _) {});
        final prepare = f.adapter.sent[0];
        final publish = f.adapter.sent[1];
        final withdraw = f.adapter.sent[2];
        final upload = f.adapter.sent[3];
        expect(publish.method, 'POST');
        expect(publish.path, '/admin/client-releases/$_id/publish');
        expect(publish.receiveTimeout, const Duration(minutes: 5));
        expect(publish.sendTimeout, apiSendTimeout);
        expect(
          publish.connectTimeout,
          web ? const Duration(minutes: 5) : apiConnectTimeout,
        );
        expect(prepare.receiveTimeout, apiReceiveTimeout);
        expect(withdraw.receiveTimeout, apiReceiveTimeout);
        expect(upload.receiveTimeout, const Duration(minutes: 5));
        expect(upload.sendTimeout, const Duration(minutes: 30));
        expect(f.dio.options.receiveTimeout, apiReceiveTimeout);
        expect(f.dio.options.sendTimeout, apiSendTimeout);
      },
    );
  }

  test(
    'late publish cannot escape a retired identity or dispatch a second POST',
    () async {
      final f = fixture();
      var current = true;
      FlutterSecureStorage.setMockInitialValues({});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        issuer: AuthBackendRealmPolicy().issuerFor('https://fixture.test/api'),
        accessToken: 'fixture-access',
        refreshToken: 'fixture-refresh',
      );
      f.dio.interceptors.insert(
        0,
        AuthInterceptor(
          replay: f.dio.fetch<dynamic>,
          storage: storage,
          baseUrl: 'https://fixture.test/api',
        ),
      );
      final started = Completer<void>();
      final result = Completer<Object?>();
      f.adapter.response = (_) {
        started.complete();
        return result.future;
      };
      await f.gateway.begin(() => current);
      final pending = f.gateway.publish(_id);
      await started.future;
      current = false;
      result.complete({'id': _id, 'state': 'PUBLISHED'});
      await expectLater(
        pending,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SESSION_CHANGED'),
        ),
      );
      await expectLater(f.gateway.publish(_id), throwsA(isA<ApiException>()));
      expect(f.adapter.sent, hasLength(1));
    },
  );

  test(
    'receive timeout keeps original publish unknown and never replays prepare/upload/publish',
    () async {
      final f = fixture();
      final records = <String, Map<String, dynamic>>{};
      f.adapter.response = (request) async {
        if (request.method == 'POST' &&
            request.path == '/admin/client-releases') {
          final body = Map<String, dynamic>.from(request.data as Map);
          final id = body['requestId'] as String;
          return records[id] = {
            ...body,
            'id': id,
            'state': 'DRAFT',
            'sha256': '',
            'sizeBytes': 0,
            'installMode': 'windows_archive',
            'deliveryContract': 'paired_v1',
          };
        }
        if (request.method == 'PUT') {
          final id = request.path.split('/')[3];
          records[id]!['sha256'] = records[id]!['expectedSha256'];
          records[id]!['sizeBytes'] = 3;
          return records[id];
        }
        if (request.path.endsWith('/publish')) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        }
        if (request.path == '/admin/client-releases') {
          return records.values.toList();
        }
        return records[request.path.split('/').last];
      };
      final snapshots = <Map<String, dynamic>>[];
      final queue = ClientReleasePublishQueue(
        gateway: f.gateway,
        isCurrent: () => true,
        checkpoint: (value) async => snapshots.add(value),
      );
      addTearDown(queue.dispose);
      queue.addFiles(
        [
          ClientReleasePickedFile.bytes(
            'uten.zip',
            Uint8List.fromList([1, 2, 3]),
          ),
        ],
        const ClientReleasePublishMetadata(
          version: '2.5.44',
          buildNumber: '2544',
        ),
      );
      await queue.run();
      final item = queue.items.single;
      final original = item.requestId;
      expect(item.stage, ClientReleaseQueueStage.unknown);
      expect(item.pendingOperation, ClientReleaseQueueOperation.publish);
      expect(item.releaseId, original);
      await queue.run();
      await queue.reconcilePending();
      expect(item.requestId, original);
      expect(snapshots, isNotEmpty);
      expect(
        f.adapter.sent.where(
          (r) => r.method == 'POST' && r.path == '/admin/client-releases',
        ),
        hasLength(1),
      );
      expect(f.adapter.sent.where((r) => r.method == 'PUT'), hasLength(1));
      expect(
        f.adapter.sent.where((r) => r.path.endsWith('/publish')),
        hasLength(1),
      );
    },
  );
}
