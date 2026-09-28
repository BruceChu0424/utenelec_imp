import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/ai_status_provider.dart';

void main() {
  group('DioAiJobRepository', () {
    test(
      'submit posts raw bytes with kind, params and encoded file headers',
      () async {
        final api = _FakeApi()
          ..postBytesResponse = {'jobId': 'job-1', 'status': 'PENDING'};
        final repository = DioAiJobRepository(api);

        final snapshot = await repository.submit(
          const AiJobRequest(
            kind: 'SALES_DOCUMENT_INTAKE',
            params: {'docType': 'order', 'clientId': 'c-1'},
            bytes: [1, 2, 3],
            fileName: 'SUNAS 报价(2026).xlsx',
            contentType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          ),
        );

        expect(api.postBytesPath, ApiEndpoints.aiJobs);
        expect(api.postBytesBody, [1, 2, 3]);
        expect(api.postBytesQuery, {
          'kind': 'SALES_DOCUMENT_INTAKE',
          'docType': 'order',
          'clientId': 'c-1',
        });
        // 文件名走百分号编码(请求头只能是 ASCII), 服务端按 UTF-8 解码。
        expect(
          api.postBytesHeaders![DioAiJobRepository.fileNameHeader],
          Uri.encodeComponent('SUNAS 报价(2026).xlsx'),
        );
        expect(
          api.postBytesHeaders![DioAiJobRepository.fileNameHeader],
          isNot(contains('报')),
        );
        expect(
          api.postBytesHeaders![DioAiJobRepository.fileTypeHeader],
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
        expect(api.postBytesSendTimeout, DioAiJobRepository.uploadTimeout);
        expect(
          api.postBytesReceiveTimeout,
          DioAiJobRepository.submitReceiveTimeout,
        );
        expect(snapshot.id, 'job-1');
        expect(snapshot.kind, 'SALES_DOCUMENT_INTAKE');
        expect(snapshot.status, AiJobStatus.pending);
      },
    );

    test('the kind query key is reserved for the job kind', () async {
      final repository = DioAiJobRepository(_FakeApi());
      await expectLater(
        repository.submit(
          const AiJobRequest(
            kind: 'X',
            params: {'kind': 'Y'},
            bytes: [1],
            fileName: 'a.csv',
            contentType: 'text/csv',
          ),
        ),
        throwsArgumentError,
      );
    });

    test(
      'a submit response without job id is not treated as accepted',
      () async {
        final api = _FakeApi()..postBytesResponse = {};
        await expectLater(
          DioAiJobRepository(api).submit(
            const AiJobRequest(
              kind: 'X',
              params: {},
              bytes: [1],
              fileName: 'a.csv',
              contentType: 'text/csv',
            ),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'get parses the job snapshot and cancel posts to the cancel path',
      () async {
        final api = _FakeApi()
          ..getResponse = {
            'id': 'job-2',
            'kind': 'SALES_DOCUMENT_INTAKE',
            'status': 'SUCCEEDED',
            'stage': 'DONE',
            'progress': 100,
            'result': {'schemaVersion': 2},
            'createdAt': '2026-09-27T01:02:03Z',
          };
        final repository = DioAiJobRepository(api);

        final snapshot = await repository.get('job-2');
        await repository.cancel('job-2');

        expect(api.getPath, ApiEndpoints.aiJob('job-2'));
        expect(snapshot.status, AiJobStatus.succeeded);
        expect(snapshot.isTerminal, isTrue);
        expect(snapshot.progress, 100);
        expect(snapshot.result, {'schemaVersion': 2});
        expect(snapshot.createdAt, DateTime.utc(2026, 9, 27, 1, 2, 3));
        expect(api.postPaths, [ApiEndpoints.aiJobCancel('job-2')]);
      },
    );

    test(
      'job ids with path characters are rejected before any request',
      () async {
        final api = _FakeApi();
        final repository = DioAiJobRepository(api);
        await expectLater(repository.get('../admin'), throwsArgumentError);
        await expectLater(repository.cancel('a/b'), throwsArgumentError);
        expect(api.getPath, isNull);
        expect(api.postPaths, isEmpty);
      },
    );
  });

  test(
    'ApiClient.postBytes forwards query, headers and both timeouts to Dio',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'))
        ..httpClientAdapter = _Adapter((options) {
          captured = options;
          return ResponseBody.fromString(
            jsonEncode({'jobId': 'j', 'status': 'PENDING'}),
            202,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        });
      final json = await ApiClient(dio).postBytes(
        '/ai/jobs',
        Uint8List.fromList([9, 8]),
        query: {'kind': 'K'},
        headers: {'X-Uten-File-Name': 'a.xlsx'},
        sendTimeout: const Duration(minutes: 3),
        receiveTimeout: const Duration(seconds: 60),
      );
      expect(json['jobId'], 'j');
      expect(captured.method, 'POST');
      expect(captured.uri.path, '/api/ai/jobs');
      expect(captured.queryParameters, {'kind': 'K'});
      expect(captured.headers['X-Uten-File-Name'], 'a.xlsx');
      expect(captured.contentType, 'application/octet-stream');
      expect(captured.sendTimeout, const Duration(minutes: 3));
      expect(captured.receiveTimeout, const Duration(seconds: 60));
    },
  );

  group('write revision', () {
    RequestOptions options(String method, String path) =>
        RequestOptions(method: method, baseUrl: 'http://h/api', path: path);

    test('AI job traffic and provider probes do not count as data writes', () {
      for (final path in [
        '/ai/jobs',
        '/ai/jobs/5b0b3d1e-0000-4000-8000-000000000000/cancel',
        '/admin/ai/providers/test',
        '/admin/ai/providers/models',
        '/admin/ai/providers/5b0b3d1e-0000-4000-8000-000000000000/test',
        '/admin/ai/providers/5b0b3d1e-0000-4000-8000-000000000000/models',
      ]) {
        expect(isBusinessWrite(options('POST', path)), isFalse, reason: path);
      }
    });

    test('saving AI provider configuration still counts as a write', () {
      expect(isBusinessWrite(options('POST', '/admin/ai/providers')), isTrue);
      expect(isBusinessWrite(options('PUT', '/admin/ai/providers/p1')), isTrue);
      expect(
        isBusinessWrite(options('DELETE', '/admin/ai/providers/p1')),
        isTrue,
      );
      expect(
        isBusinessWrite(options('POST', '/admin/ai/providers/p1/default')),
        isTrue,
      );
    });
  });

  group('aiStatusProvider', () {
    test('parses the status of the current account', () async {
      final api = _FakeApi()
        ..getResponse = {
          'available': true,
          'aiAllowedForMe': true,
          'supportsVision': false,
        };
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final status = await container.read(aiStatusProvider.future);
      expect(api.getPath, ApiEndpoints.aiStatus);
      expect(status.usable, isTrue);
      expect(status.supportsVision, isFalse);
    });

    test('any failure reads as AI unavailable instead of an error', () async {
      final api = _FakeApi()..getError = Exception('offline');
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final status = await container.read(aiStatusProvider.future);
      expect(status.available, isFalse);
      expect(status.usable, isFalse);
    });

    test('AI is only usable when available and allowed for me', () {
      expect(
        AiStatus.fromJson({'available': true, 'aiAllowedForMe': false}).usable,
        isFalse,
      );
      expect(
        AiStatus.fromJson({'available': false, 'aiAllowedForMe': true}).usable,
        isFalse,
      );
    });
  });
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  Map<String, dynamic> postBytesResponse = const {};
  String? postBytesPath;
  Uint8List? postBytesBody;
  Map<String, dynamic>? postBytesQuery;
  Map<String, String>? postBytesHeaders;
  Duration? postBytesSendTimeout;
  Duration? postBytesReceiveTimeout;

  Map<String, dynamic> getResponse = const {};
  Object? getError;
  String? getPath;
  final List<String> postPaths = [];

  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List bytes, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    Duration? sendTimeout,
    Duration? receiveTimeout,
  }) async {
    postBytesPath = path;
    postBytesBody = bytes;
    postBytesQuery = query;
    postBytesHeaders = headers;
    postBytesSendTimeout = sendTimeout;
    postBytesReceiveTimeout = receiveTimeout;
    return postBytesResponse;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    getPath = path;
    if (getError != null) throw getError!;
    return getResponse;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    postPaths.add(path);
    return const {};
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.responder);

  final ResponseBody Function(RequestOptions options) responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => responder(options);

  @override
  void close({bool force = false}) {}
}
