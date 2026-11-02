import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/page_read_priority_interceptor.dart';

void main() {
  test(
    'slow optional reads leave capacity for rows and counts, preserving queries',
    () async {
      final adapter = _GatedAdapter();
      final scheduler = PageReadPriorityInterceptor();
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(scheduler);
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
      dio.interceptors.add(scheduler);
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
