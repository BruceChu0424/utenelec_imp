import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/responsive_json_decoder.dart';
import 'package:uten_imp/core/network/responsive_json_transformer.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

void main() {
  late Uint8List bytes;
  setUpAll(() {
    bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'items': List.generate(
            50000,
            (i) => {
              'id': 'row-$i',
              'name': '极限加载😀$i',
              'quantity': '0001.0000000000000001',
              'amount': '99999999999999.1234567890',
              'empty': null,
            },
          ),
        }),
      ),
    );
  });
  test(
    '50k rows survive 24 overlapping reads and repeated retirement without stale publication',
    () async {
      final decoder = ResponsiveJsonDecoder();
      addTearDown(decoder.dispose);
      var generation = 0, pulses = 0, cancelled = 0;
      final watch = Stopwatch()..start();
      var lastPulse = 0, maxGap = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
        pulses++;
        final now = watch.elapsedMilliseconds;
        final gap = now - lastPulse;
        if (gap > maxGap) maxGap = gap;
        lastPulse = now;
      });
      addTearDown(timer.cancel);
      final calls = <Future<Object?>>[];
      for (var i = 0; i < 24; i++) {
        final own = ++generation;
        calls.add(
          decoder
              .decodeBytes(bytes, isCurrent: () => own == generation)
              .catchError((Object error) {
                if (error is UiWorkCancelled) {
                  cancelled++;
                  return null;
                }
                throw error;
              }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final results = await Future.wait(calls);
      expect(cancelled, greaterThan(0));
      expect(pulses, greaterThan(0));
      expect(
        maxGap,
        lessThan(500),
        reason: 'Large-load overlap must not monopolize the UI event loop',
      );
      // Operational fixture measurements, not production business data.
      // ignore: avoid_print
      print(
        'STRESS_METRICS ${jsonEncode({'rows': 50000, 'overlaps': 24, 'bytes': bytes.length, 'cancelled': cancelled, 'maxEventLoopGapMs': maxGap, 'elapsedMs': watch.elapsedMilliseconds})}',
      );
      final last = results.last as Map;
      final items = last['items'] as List;
      expect(items.length, 50000);
      expect((items.last as Map)['id'], 'row-49999');
      expect((items.first as Map)['quantity'], '0001.0000000000000001');
      expect((items.last as Map)['amount'], '99999999999999.1234567890');
      expect((items.first as Map)['empty'], isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'mid-stream interruption cannot publish partial data and next full request recovers',
    () async {
      final decoder = ResponsiveJsonDecoder();
      addTearDown(decoder.dispose);
      final transformer = ResponsiveJsonTransformer(decoder);
      final cancel = CancelToken();
      Stream<Uint8List> chunks() async* {
        for (var p = 0; p < bytes.length; p += 32768) {
          await Future<void>.delayed(Duration.zero);
          if (p >= 32768 * 8) {
            cancel.cancel('retired');
          }
          yield Uint8List.sublistView(
            bytes,
            p,
            (p + 32768).clamp(0, bytes.length),
          );
        }
      }

      await expectLater(
        transformer.transformResponse(
          RequestOptions(path: '/fixture', cancelToken: cancel),
          ResponseBody(
            chunks(),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          ),
        ),
        throwsA(isA<DioException>()),
      );
      final complete = await transformer.transformResponse(
        RequestOptions(path: '/fixture'),
        ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      expect((complete as Map)['items'], hasLength(50000));
    },
  );
  test('owner disposal during a 50k-row decode retires the result', () async {
    final decoder = ResponsiveJsonDecoder();
    final pending = decoder.decodeBytes(bytes);
    decoder.dispose();
    await expectLater(pending, throwsA(isA<StateError>()));
  });
}
