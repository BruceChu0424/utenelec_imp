import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/native_facet_routes.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';

void main() {
  late WebUpdateSafetyRegistry registry;
  late ApiMutationReloadSafety safety;
  late _Adapter adapter;
  late ApiClient api;

  setUp(() {
    registry = WebUpdateSafetyRegistry()..setReady(true);
    safety = ApiMutationReloadSafety(registry: registry);
    adapter = _Adapter();
    api = ApiClient(
      Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = adapter,
      reloadSafety: safety,
    );
  });

  tearDown(() => registry.dispose());

  test(
    'overlapping reads and commands remain busy until both finish',
    () async {
      final read = api.get('/items');
      final write = api.put('/items/one', body: {'name': 'new'});
      expect(safety.pendingReadCount, 1);
      expect(safety.pendingCount, 1);
      expect(registry.snapshot.busy, isTrue);
      await adapter.ready(2);
      adapter.respond(0, '{}');
      await read;
      expect(registry.snapshot.busy, isTrue);
      adapter.respond(1, '{}');
      await write;
      expect(safety.pendingCount, 0);
      expect(safety.pendingReadCount, 0);
      expect(registry.snapshot.isSafe, isTrue);
    },
  );

  final commands = <String, Future<Object?> Function(ApiClient)>{
    'post': (api) => api.post('/save'),
    'postLongRunning': (api) => api.postLongRunning(
      '/save',
      receiveTimeout: const Duration(minutes: 1),
    ),
    'postList': (api) => api.postList('/save'),
    'putList': (api) => api.putList('/save'),
    'put': (api) => api.put('/save'),
    'putWithQuery': (api) => api.putWithQuery('/save', query: {'version': 2}),
    'putBytes': (api) async =>
        api.putBytes('/save', Uint8List(1), 'application/octet-stream'),
    'postBytes': (api) => api.postBytes('/save', Uint8List(1)),
    'postMultipartFile': (api) =>
        api.postMultipartFile('/save', Uint8List(1), 'one.txt', 'text/plain'),
    'uploadClientPackage': (api) async =>
        api.uploadClientPackage('/save', Uint8List(1), onProgress: (_, _) {}),
    'patch': (api) => api.patch('/save'),
    'delete': (api) async => api.delete('/save'),
  };
  for (final command in commands.entries) {
    test(
      '${command.key} blocks before dispatch and releases after receipt',
      () async {
        final request = command.value(api);
        expect(safety.pendingCount, 1);
        expect(registry.snapshot.busy, isTrue);
        await adapter.ready(1);
        adapter.respond(0, command.key.endsWith('List') ? '[]' : '{}');
        await request;
        expect(safety.pendingCount, 0);
        expect(registry.snapshot.isSafe, isTrue);
      },
    );
  }

  for (final status in [408, 499, 500, 502, 503, 504]) {
    test(
      'HTTP $status keeps an uncertainty fence after the write ends',
      () async {
        final request = api.post('/save');
        final rejected = expectLater(request, throwsA(isA<ApiException>()));
        await adapter.ready(1);
        adapter.respond(
          0,
          '{"code":"FAILED","message":"failed"}',
          status: status,
        );
        await rejected;
        expect(safety.pendingCount, 0);
        expect(registry.snapshot.busy, isFalse);
        expect(registry.snapshot.blocked, isTrue);
        final unrelated = api.put('/other');
        await adapter.ready(2);
        adapter.respond(1, '{}');
        await unrelated;
        expect(
          registry.snapshot.blocked,
          isTrue,
          reason: 'another success cannot resolve the earlier command',
        );
      },
    );
  }

  for (final kind in [
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.connectionError,
    DioExceptionType.cancel,
  ]) {
    test(
      '$kind does not turn an unconfirmed command into a safe idle page',
      () async {
        final request = api.delete('/save');
        final rejected = expectLater(request, throwsA(isA<ApiException>()));
        await adapter.ready(1);
        adapter.fail(0, kind);
        await rejected;
        expect(safety.pendingCount, 0);
        expect(registry.snapshot.blocked, isTrue);
      },
    );
  }

  test(
    'a definite business rejection leaves no unconfirmed mutation',
    () async {
      final request = api.put('/save');
      final rejected = expectLater(request, throwsA(isA<ApiException>()));
      await adapter.ready(1);
      adapter.respond(0, '{"code":"CONFLICT","message":"stale"}', status: 409);
      await rejected;
      expect(registry.snapshot.isSafe, isTrue);
    },
  );

  test('a locally rejected successful response retains uncertainty', () async {
    final request = api.post('/save');
    final rejected = expectLater(request, throwsA(isA<ApiException>()));
    await adapter.ready(1);
    adapter.respond(
      0,
      '{"readScopeVersion":"old"}',
      headers: {
        'X-Uten-Read-Scope-Version': ['new'],
      },
    );
    await rejected;
    expect(registry.snapshot.blocked, isTrue);
  });

  test(
    'known read-only POST failures release busy without a commit fence',
    () async {
      final request = api.post(nativeFacetPaths.first, body: {'filter': 'one'});
      final rejected = expectLater(request, throwsA(isA<ApiException>()));
      expect(safety.pendingReadCount, 1);
      expect(safety.pendingCount, 0);
      await adapter.ready(1);
      adapter.fail(0, DioExceptionType.receiveTimeout);
      await rejected;
      expect(registry.snapshot.isSafe, isTrue);
    },
  );

  test('package headers do not release a still-active download body', () async {
    final chunks = StreamController<Uint8List>();
    final cancel = CancelToken();
    final future = api.getPackageStream(
      '/client-updates/11111111-1111-4111-8111-111111111111/download',
      cancelToken: cancel,
    );
    expect(safety.pendingReadCount, 1);
    await adapter.ready(1);
    adapter.responses[0].complete(ResponseBody(chunks.stream, 200));
    final stream = await future;
    expect(registry.snapshot.busy, isTrue);
    final consumed = stream.toList();
    chunks.add(Uint8List.fromList([1, 2]));
    expect(registry.snapshot.busy, isTrue);
    await chunks.close();
    expect((await consumed).expand((chunk) => chunk), [1, 2]);
    expect(safety.pendingReadCount, 0);
    expect(registry.snapshot.isSafe, isTrue);
  });

  test(
    'cancelling a package stream retires its read lease exactly once',
    () async {
      final chunks = StreamController<Uint8List>();
      final future = api.getPackageStream(
        '/client-updates/11111111-1111-4111-8111-111111111111/download',
        cancelToken: CancelToken(),
      );
      await adapter.ready(1);
      adapter.responses[0].complete(ResponseBody(chunks.stream, 200));
      final stream = await future;
      final subscription = stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(safety.pendingReadCount, 1);
      await subscription.cancel();
      await chunks.close();
      expect(safety.pendingReadCount, 0);
      expect(registry.snapshot.isSafe, isTrue);
    },
  );
  test(
    'export download remains busy until the streamed artifact completes',
    () async {
      final chunks = StreamController<Uint8List>();
      final collected = api
          .downloadExportStream(
            '/report-export-jobs/11111111-1111-4111-8111-111111111111/download',
          )
          .toList();
      await adapter.ready(1);
      adapter.responses[0].complete(ResponseBody(chunks.stream, 200));
      await Future<void>.delayed(Duration.zero);
      expect(safety.pendingCount, 0);
      expect(safety.pendingReadCount, 1);
      chunks.add(Uint8List.fromList([3]));
      await chunks.close();
      expect((await collected).expand((chunk) => chunk), [3]);
      expect(registry.snapshot.isSafe, isTrue);
    },
  );

  test(
    'cancellation before a package body is listened also releases its lease',
    () async {
      final cancel = CancelToken();
      final future = api.getPackageStream(
        '/client-updates/11111111-1111-4111-8111-111111111111/download',
        cancelToken: cancel,
      );
      await adapter.ready(1);
      adapter.responses[0].complete(
        ResponseBody(const Stream<Uint8List>.empty(), 200),
      );
      await future;
      expect(safety.pendingReadCount, 1);
      cancel.cancel('Session retired before consuming the body');
      await Future<void>.delayed(Duration.zero);
      expect(safety.pendingReadCount, 0);
      expect(registry.snapshot.isSafe, isTrue);
    },
  );
}

class _Adapter implements HttpClientAdapter {
  final sent = <RequestOptions>[];
  final responses = <Completer<ResponseBody>>[];

  Future<void> ready(int count) async {
    for (var attempt = 0; attempt < 100 && sent.length < count; attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(sent.length, count);
  }

  void respond(
    int index,
    String data, {
    int status = 200,
    Map<String, List<String>> headers = const {},
  }) => responses[index].complete(
    ResponseBody.fromString(
      data,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        ...headers,
      },
    ),
  );

  void fail(int index, DioExceptionType type) => responses[index].completeError(
    DioException(requestOptions: sent[index], type: type),
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    sent.add(options);
    final response = Completer<ResponseBody>();
    responses.add(response);
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}
