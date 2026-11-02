import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/page_read_priority_interceptor.dart';

void main() {
  test(
    'real loopback HTTP measures contested cold rows and counts before/after',
    () async {
      final samples = <Map<String, Object>>[];
      // These are actual socket/JSON timings in a controlled slow-facet fixture,
      // not company-server latency or a production SQL performance claim.
      for (var repeat = 0; repeat < 4; repeat++) {
        for (final optimized in [false, true]) {
          samples.add(await _measure(optimized, repeat));
        }
      }
      final baseline =
          samples
              .where((s) => s['optimized'] == false)
              .map((s) => s['rowsMs'] as double)
              .toList()
            ..sort();
      final optimized =
          samples
              .where((s) => s['optimized'] == true)
              .map((s) => s['rowsMs'] as double)
              .toList()
            ..sort();
      expect(optimized[2], lessThan(baseline[2] * .6));
      final output = File('build/category-loading-http-timings.json');
      output.parent.createSync(recursive: true);
      output.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'fixture':
              'loopback HTTP, 6 connections, 8 auxiliary reads at 150ms, 50 table rows, exact warehouse queries',
          'samples': samples,
        }),
      );
      // ignore: avoid_print
      print(
        'HTTP rows median before=${((baseline[1] + baseline[2]) / 2).toStringAsFixed(1)}ms after=${((optimized[1] + optimized[2]) / 2).toStringAsFixed(1)}ms',
      );
    },
  );
}

Future<Map<String, Object>> _measure(bool optimized, int repeat) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    if (request.uri.path.endsWith('/facets')) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(
        request.uri.path.endsWith('/counts')
            ? {'OPEN': 37}
            : {
                'items': [
                  for (var i = 0; i < 50; i++)
                    {'id': '$i', 'billNo': 'TEST-$i', 'quantity': '123.456789'},
                ],
                'page': 1,
                'size': 50,
                'total': 37,
              },
      ),
    );
    await request.response.close();
  });
  final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()..maxConnectionsPerHost = 6,
  );
  final scheduler = PageReadPriorityInterceptor();
  if (optimized) dio.interceptors.add(scheduler);
  try {
    final watch = Stopwatch()..start();
    final optional = [
      for (var i = 0; i < 8; i++) dio.get<Map<String, dynamic>>('/$i/facets'),
    ];
    // Reproduce an auxiliary batch already ahead of the business reads.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final countFuture = dio
        .get<Map<String, dynamic>>(
          '/counts',
          queryParameters: {'scopeWarehouseId': 'warehouse-A'},
        )
        .then((r) {
          expect(r.data!['OPEN'], 37);
          return watch.elapsedMicroseconds / 1000;
        });
    final rows = await dio.get<Map<String, dynamic>>(
      '/rows',
      queryParameters: {'scopeWarehouseId': 'warehouse-A'},
    );
    final rowsMs = watch.elapsedMicroseconds / 1000;
    expect(rows.data!['items'], hasLength(50));
    final countsMs = await countFuture;
    await Future.wait(optional);
    return {
      'repeat': repeat,
      'optimized': optimized,
      'rowsMs': rowsMs,
      'countsMs': countsMs,
      'allReadsMs': watch.elapsedMicroseconds / 1000,
    };
  } finally {
    scheduler.close();
    dio.close(force: true);
    await subscription.cancel();
    await server.close(force: true);
  }
}
