// Real browser transport contract without Flutter's platform test bootstrap.
// Every HTTP adapter is owned by this fixture. No company endpoints or storage.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;
import 'package:uten_imp/core/network/interceptors/page_read_priority_interceptor.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      throw StateError('Browser read did not dispatch');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> main() async {
  final adapter = FixtureAdapter();
  var identity = 1;
  final scheduler = PageReadPriorityInterceptor(
    isCurrent: (options) async => options.extra['identity'] == identity,
  );
  final dio = Dio()..httpClientAdapter = adapter;
  dio.interceptors.add(scheduler);
  Options owned() => Options(extra: {'identity': identity});
  try {
    final auxiliary = [
      for (var i = 0; i < 8; i++)
        dio.get<Map<String, dynamic>>('/master/$i/facets', options: owned()),
    ];
    await until(() => adapter.requests.length == 2);
    final rows = dio.get<Map<String, dynamic>>(
      '/warehouse/rows',
      queryParameters: {'scopeWarehouseId': 'a'},
      options: owned(),
    );
    final counts = dio.get<Map<String, dynamic>>(
      '/documents/status-counts',
      queryParameters: {'scopeWarehouseId': 'b'},
      options: owned(),
    );
    await until(() => adapter.requests.length == 4);
    check(
      adapter.requests.last.queryParameters['scopeWarehouseId'] == 'b',
      'Warehouse count scope changed',
    );
    adapter.release('/warehouse/rows');
    adapter.release('/documents/status-counts');
    await Future.wait([rows, counts]);
    check(
      adapter.pending.values.where((gate) => !gate.isCompleted).length == 2,
      'Foreground read waited for optional reads',
    );
    adapter.releaseAll = true;
    for (final request in adapter.requests.toList()) {
      adapter.release(request.path);
    }
    await Future.wait(auxiliary);
    check(scheduler.timings.length == 10, 'Read admission lost a completion');
    scheduler.close();
    dio.close();

    final identityAdapter = FixtureAdapter();
    final identityGate = PageReadPriorityInterceptor(
      maximumReads: 1,
      isCurrent: (options) async => options.extra['identity'] == identity,
    );
    final client = Dio()..httpClientAdapter = identityAdapter;
    client.interceptors.add(identityGate);
    try {
      final first = client.get<Map<String, dynamic>>(
        '/first',
        options: owned(),
      );
      final cancellation = CancelToken();
      var cancelled = false, retired = false;
      final second = client
          .get<Map<String, dynamic>>(
            '/cancelled',
            options: owned(),
            cancelToken: cancellation,
          )
          .then<void>(
            (_) => throw StateError('Cancelled read dispatched'),
            onError: (Object _) {
              cancelled = true;
            },
          );
      final third = client
          .get<Map<String, dynamic>>('/retired', options: owned())
          .then<void>(
            (_) => throw StateError('Retired identity dispatched'),
            onError: (Object _) {
              retired = true;
            },
          );
      await until(() => identityAdapter.requests.length == 1);
      cancellation.cancel();
      identity = 2;
      identityAdapter.release('/first');
      await first;
      await Future.wait([second, third]);
      check(
        cancelled && retired && identityAdapter.requests.length == 1,
        'Reader identity/cancellation fence failed',
      );
    } finally {
      identityGate.close();
      client.close(force: true);
    }
    web.document.body!.textContent = jsonEncode({
      'passed': true,
      'checks': [
        'auxiliary capacity',
        'exact warehouse query',
        'foreground priority',
        'queue cancellation',
        'identity retirement',
      ],
      'businessRequests': 0,
    });
  } catch (error) {
    web.document.body!.textContent = jsonEncode({
      'passed': false,
      'error': error.toString(),
    });
  } finally {
    scheduler.close();
    dio.close(force: true);
  }
}

class FixtureAdapter implements HttpClientAdapter {
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
