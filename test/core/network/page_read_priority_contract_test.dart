import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/page_read_priority_interceptor.dart';

void main() {
  test('a scheduler rejects duplicate installation', () {
    final scheduler = PageReadPriorityInterceptor();
    final dio = Dio();
    scheduler.installOn(dio);
    expect(() => scheduler.installOn(dio), throwsStateError);
    scheduler.close();
    dio.close(force: true);
  });

  test(
    'consumed responses and identity refusals release transport capacity',
    () async {
      final adapter = _GatedAdapter()..releaseAll = true;
      final scheduler = PageReadPriorityInterceptor(maximumReads: 1);
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            if (response.requestOptions.path.endsWith('/retired')) {
              // AuthInterceptor rejects a late response without forwarding errors.
              handler.reject(
                DioException(
                  requestOptions: response.requestOptions,
                  response: Response(
                    requestOptions: response.requestOptions,
                    statusCode: 409,
                    data: {'code': 'SESSION_CHANGED'},
                  ),
                ),
              );
            } else {
              handler.resolve(response);
            }
          },
        ),
      );
      scheduler.installOn(dio);
      addTearDown(() {
        scheduler.close();
        dio.close(force: true);
      });
      for (var i = 0; i < 12; i++) {
        await expectLater(
          dio
              .get<dynamic>('/rows/$i/retired')
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<DioException>()),
        );
        await dio
            .get<dynamic>('/rows/$i/current')
            .timeout(const Duration(seconds: 2));
      }
      expect(adapter.requests, hasLength(24));
      expect(scheduler.timings, hasLength(24));
    },
  );

  test('local preflight refusal never owns a read permit', () async {
    final adapter = _GatedAdapter()..releaseAll = true;
    final scheduler = PageReadPriorityInterceptor(maximumReads: 1);
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/refused')) {
            handler.reject(DioException(requestOptions: options));
          } else {
            handler.next(options);
          }
        },
      ),
    );
    scheduler.installOn(dio);
    addTearDown(() {
      scheduler.close();
      dio.close(force: true);
    });
    for (var i = 0; i < 12; i++) {
      await expectLater(
        dio.get<dynamic>('/rows/$i/refused'),
        throwsA(isA<DioException>()),
      );
    }
    await dio.get<dynamic>('/rows/current').timeout(const Duration(seconds: 2));
    expect(adapter.requests.single.path, '/rows/current');
    expect(scheduler.timings, hasLength(1));
  });

  test('replacement options retain the original admission lease', () async {
    final adapter = _GatedAdapter()..releaseAll = true;
    final scheduler = PageReadPriorityInterceptor(maximumReads: 1);
    final dio = Dio()..httpClientAdapter = adapter;
    scheduler.installOn(dio);
    // Some replay/transport wrappers replace RequestOptions. Retain the lease
    // through that copy without relying on RequestOptions object identity.
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.next(options.copyWith(extra: {...options.extra}));
        },
      ),
    );
    addTearDown(() {
      scheduler.close();
      dio.close(force: true);
    });
    for (var i = 0; i < 12; i++) {
      await dio.get<dynamic>('/rows/$i').timeout(const Duration(seconds: 2));
    }
    expect(adapter.requests, hasLength(12));
    expect(scheduler.timings, hasLength(12));
  });

  test('session wait cannot occupy the only foreground read slot', () async {
    final adapter = _GatedAdapter();
    final scheduler = PageReadPriorityInterceptor(maximumReads: 1);
    final dio = Dio()..httpClientAdapter = adapter;
    scheduler.installOn(dio);
    addTearDown(() {
      scheduler.close();
      dio.close(force: true);
    });
    final watch = dio.get<dynamic>('/auth/session/watch');
    await _until(() => adapter.requests.length == 1);
    final rows = dio.get<dynamic>('/warehouse/tasks');
    await _until(() => adapter.requests.length == 2);
    adapter.release('/warehouse/tasks');
    await rows;
    adapter.release('/auth/session/watch');
    await watch;
    expect(scheduler.timings, hasLength(1));
  });

  test('active cancellation returns exactly its own permit', () async {
    final adapter = _GatedAdapter();
    final scheduler = PageReadPriorityInterceptor(maximumReads: 1);
    final dio = Dio()..httpClientAdapter = adapter;
    scheduler.installOn(dio);
    addTearDown(() {
      scheduler.close();
      dio.close(force: true);
    });
    final cancelled = CancelToken();
    final old = dio.get<dynamic>('/old', cancelToken: cancelled);
    final oldResult = expectLater(old, throwsA(isA<DioException>()));
    await _until(() => adapter.requests.length == 1);
    final current = dio.get<dynamic>('/current');
    final waiting = dio.get<dynamic>('/waiting');
    cancelled.cancel();
    await oldResult;
    await _until(() => adapter.requests.length == 2);
    expect(adapter.requests.last.path, '/current');
    adapter.release('/old');
    await pumpEventQueue();
    expect(
      adapter.requests,
      hasLength(2),
      reason:
          'Late completion of a cancelled read cannot release its successor',
    );
    adapter.release('/current');
    await current;
    await _until(() => adapter.requests.length == 3);
    adapter.release('/waiting');
    await waiting;
    expect(scheduler.timings, hasLength(3));
  });

  test(
    'slow optional reads leave capacity for rows and counts, preserving queries',
    () async {
      final adapter = _GatedAdapter();
      final scheduler = PageReadPriorityInterceptor();
      final dio = Dio()..httpClientAdapter = adapter;
      scheduler.installOn(dio);
      addTearDown(() {
        scheduler.close();
        dio.close(force: true);
      });
      final optional = [
        for (var i = 0; i < 8; i++)
          dio.get<Map<String, dynamic>>('/master/$i/facets'),
      ];
      await _until(() => adapter.requests.length == 2);
      expect(adapter.requests.length, 2);
      final rows = dio.get<Map<String, dynamic>>(
        '/warehouse/tasks',
        queryParameters: {'scopeWarehouseId': 'a', 'status': 'OPEN'},
      );
      final counts = dio.get<Map<String, dynamic>>(
        '/documents/status-counts',
        queryParameters: {'scopeWarehouseId': 'b', 'kind': 'stockDocument'},
      );
      await _until(() => adapter.requests.length == 4);
      expect(
        adapter.requests.map((request) => request.path),
        containsAll(['/warehouse/tasks', '/documents/status-counts']),
      );
      expect(adapter.requests.last.queryParameters['scopeWarehouseId'], 'b');
      adapter.release('/warehouse/tasks');
      adapter.release('/documents/status-counts');
      await Future.wait([rows, counts]);
      adapter.releaseAll = true;
      for (final request in adapter.requests.toList()) {
        adapter.release(request.path);
      }
      await Future.wait(optional);
      expect(scheduler.timings, hasLength(10));
    },
  );

  test(
    'queued cancellation and changed identity cannot dispatch or leak a permit',
    () async {
      final adapter = _GatedAdapter();
      var identity = 1;
      var identityChecks = 0;
      final scheduler = PageReadPriorityInterceptor(
        maximumReads: 1,
        isCurrent: (options) async {
          identityChecks++;
          return options.extra['identity'] == identity;
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      scheduler.installOn(dio);
      addTearDown(() {
        scheduler.close();
        dio.close(force: true);
      });
      final first = dio.get<Map<String, dynamic>>(
        '/rows/one',
        options: Options(extra: {'identity': 1}),
      );
      final cancelled = CancelToken();
      final second = dio.get<Map<String, dynamic>>(
        '/rows/two',
        cancelToken: cancelled,
        options: Options(extra: {'identity': 1}),
      );
      final third = dio.get<Map<String, dynamic>>(
        '/rows/three',
        options: Options(extra: {'identity': 1}),
      );
      final secondCheck = expectLater(second, throwsA(isA<DioException>()));
      final thirdCheck = expectLater(third, throwsA(isA<DioException>()));
      await _until(() => adapter.requests.length == 1);
      expect(
        identityChecks,
        0,
        reason: 'Immediate reads add no credential-store round trip',
      );
      cancelled.cancel();
      identity = 2;
      adapter.release('/rows/one');
      await first;
      await Future.wait([secondCheck, thirdCheck]);
      expect(
        identityChecks,
        1,
        reason: 'A queued live read rechecks its original identity',
      );
      expect(adapter.requests.map((request) => request.path), ['/rows/one']);
      adapter.releaseAll = true;
      await dio.get<Map<String, dynamic>>(
        '/rows/new',
        options: Options(extra: {'identity': 2}),
      );
      expect(adapter.requests.last.path, '/rows/new');
    },
  );
}

class _GatedAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final pending = <String, Completer<void>>{};
  bool releaseAll = false;
  void release(String path) {
    final gate = pending[path];
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!releaseAll) await (pending[options.path] = Completer<void>()).future;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _until(bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw StateError('Read did not dispatch');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
