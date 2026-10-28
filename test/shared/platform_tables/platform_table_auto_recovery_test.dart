import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';
import 'package:uten_imp/shared/platform_tables/platform_row_draft.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';

const _path = '/platform-columns/goods/values:batch';
const _record = '63e5d6be-39f0-457b-bad5-817424f3c3b0';
const _nextRecord = 'b96732ae-506c-4534-a0d5-de45fbd58db1';
const _column = PlatformColumnDefinition(
  id: '62b189be-9bea-46ab-873e-1e89d2c6d939',
  scope: 'goods',
  name: '补充说明',
);

ResponseBody _json(Object value, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.read);
  final FutureOr<ResponseBody> Function(RequestOptions) read;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => await read(options);
  @override
  void close({bool force = false}) {}
}

class _Layout extends PlatformTableLayoutNotifier {
  _Layout() : super('automatic-read');
  @override
  PlatformTableLayout build() => const PlatformTableLayout(added: [_column]);
  @override
  void persist() {}
}

class _Fixture {
  final controller = PlatformTableController<String>();
  final rows = ValueNotifier([_record]);
  final draft = PlatformRowDraft()..setValue(_column, '未保存的精确原文');
  final requests = <RequestOptions>[];
  final delays = <Duration>[];
  late final Dio dio;
  late final PlatformTableRepository repository;
  var failures = 2;
  var batches = 0;
  var withDraft = true;
  Completer<void>? delayGate;
  Completer<void>? batchGate;

  _Fixture() {
    dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
    dio.httpClientAdapter = _Adapter((request) async {
      requests.add(request);
      switch (request.path) {
        case '/platform-columns/scopes':
          return _json([
            {'scope': 'goods', 'canWrite': true},
          ]);
        case '/platform-columns/goods/definitions':
          return _json([_column.toJson()]);
        case _path:
          batches++;
          if (batchGate case final gate?) await gate.future;
          if (failures-- > 0) {
            throw DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            );
          }
          final body = request.data as Map<String, dynamic>;
          return _json([
            for (final id in body['recordIds'] as List)
              {
                'recordId': id,
                'version': 2,
                'canWrite': true,
                'cells': [
                  {
                    'columnId': _column.id,
                    'definition': _column.toJson(),
                    'value': '服务端完整值',
                  },
                ],
              },
          ]);
        default:
          fail('Read recovery replayed ${request.method} ${request.path}');
      }
    });
    dio.interceptors.add(
      SafeRequestRetryInterceptor(
        dio,
        web: false,
        delay: (duration) async {
          delays.add(duration);
          if (delayGate case final gate?) await gate.future;
        },
      ),
    );
    repository = PlatformTableRepository(ApiClient(dio));
  }

  void dispose() {
    if (!controller.disposed) controller.dispose();
    rows.dispose();
    draft.dispose();
    dio.close(force: true);
  }
}

Future<void> _mount(WidgetTester tester, _Fixture fixture) async {
  addTearDown(fixture.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        platformTableRepositoryProvider.overrideWithValue(fixture.repository),
        platformTableLayoutProvider('automatic-read').overrideWith(_Layout.new),
      ],
      child: MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: fixture.rows,
          builder: (context, rows, _) {
            fixture.controller.configure(
              context,
              descriptor: PlatformTableDescriptor<String>(
                kind: 'editable',
                rows: rows,
                columnKeys: const ['base'],
                tableKey: 'automatic-read',
              ),
              explicitBinding: PlatformTableBinding<String>(
                tableKey: 'automatic-read',
                scope: 'goods',
                recordIdOf: (id) => id,
                draftOf: fixture.withDraft
                    ? (id) => id == _record ? fixture.draft : null
                    : null,
              ),
            );
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'real table automatically recovers batch reads with one retry budget and preserves draft input',
    (tester) async {
      final fixture = _Fixture();
      await _mount(tester, fixture);
      expect(fixture.batches, 3);
      expect(fixture.delays, [
        const Duration(milliseconds: 400),
        const Duration(milliseconds: 1200),
      ]);
      expect(fixture.controller.error, isNull);
      expect(fixture.controller.loading, isFalse);
      expect(fixture.draft.cells.single.value, '未保存的精确原文');
      expect(
        fixture.requests.where((r) => r.path.endsWith('/definitions')),
        hasLength(1),
        reason: 'No nested controller retry may multiply the metadata reads.',
      );
      expect(
        fixture.requests.where((r) => r.method != 'GET').map((r) => r.path),
        everyElement(_path),
      );
    },
  );

  testWidgets(
    'persistent failure stops at three attempts and explicit retry remains single flight',
    (tester) async {
      final fixture = _Fixture()..failures = 20;
      await _mount(tester, fixture);
      expect(fixture.batches, 3);
      expect(
        fixture.controller.readFailure,
        PlatformTableReadFailure.connection,
      );
      expect(fixture.controller.loading, isFalse);
      await tester.pump(const Duration(minutes: 1));
      expect(fixture.batches, 3, reason: 'No background table retry loop.');
      fixture.failures = 0;
      fixture.batchGate = Completer<void>();
      final first = fixture.controller.retryRead();
      final duplicate = fixture.controller.retryRead();
      await tester.pumpAndSettle();
      expect(fixture.batches, 4);
      expect(fixture.controller.loading, isTrue);
      fixture.batchGate!.complete();
      await tester.pumpAndSettle();
      await first;
      await duplicate;
      await tester.pumpAndSettle();
      expect(fixture.batches, 4);
      expect(fixture.controller.error, isNull);
      expect(fixture.draft.cells.single.value, '未保存的精确原文');
    },
  );

  testWidgets(
    'superseded batch retries cannot publish an old record into the current table',
    (tester) async {
      final fixture = _Fixture()
        ..failures = 1
        ..withDraft = false
        ..delayGate = Completer<void>();
      await _mount(tester, fixture);
      expect(fixture.batches, 1);
      expect(fixture.controller.loading, isTrue);
      fixture.rows.value = [_nextRecord];
      await tester.pump();
      await tester.pumpAndSettle();
      expect(fixture.controller.rowValues(_nextRecord)!.recordId, _nextRecord);
      fixture.delayGate!.complete();
      await tester.pumpAndSettle();
      expect(fixture.controller.rowValues(_record), isNull);
      expect(fixture.controller.rowValues(_nextRecord)!.recordId, _nextRecord);
      expect(fixture.controller.error, isNull);
      expect(fixture.draft.cells.single.value, '未保存的精确原文');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing during retry never notifies a retired table', (
    tester,
  ) async {
    final fixture = _Fixture()
      ..failures = 1
      ..delayGate = Completer<void>();
    await _mount(tester, fixture);
    var notifications = 0;
    fixture.controller.addListener(() => notifications++);
    fixture.controller.dispose();
    fixture.delayGate!.complete();
    await tester.pumpAndSettle();
    expect(notifications, 0);
    expect(fixture.batches, 2);
    expect(tester.takeException(), isNull);
  });

  for (final (status, code) in [
    (502, 'INTERNAL'),
    (503, 'INTERNAL'),
    (504, 'INTERNAL'),
    (503, 'SERVICE_UNAVAILABLE'),
  ]) {
    test('read-only batch automatically retries $status $code', () async {
      var attempts = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      addTearDown(() => dio.close(force: true));
      dio.httpClientAdapter = _Adapter((_) {
        attempts++;
        return attempts < 3 ? _json({'code': code}, status) : _json([]);
      });
      dio.interceptors.add(
        SafeRequestRetryInterceptor(dio, delay: (_) async {}),
      );
      await dio.post<dynamic>(
        _path,
        data: {
          'recordIds': [_record],
        },
      );
      expect(attempts, 3);
    });
  }

  for (final status in [401, 403, 404, 409, 422, 429, 500]) {
    test('read-only batch never blindly retries response $status', () async {
      var attempts = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      addTearDown(() => dio.close(force: true));
      dio.httpClientAdapter = _Adapter((_) {
        attempts++;
        return _json({'code': 'BUSINESS_REJECTION'}, status);
      });
      dio.interceptors.add(
        SafeRequestRetryInterceptor(dio, delay: (_) async {}),
      );
      await expectLater(dio.post<dynamic>(_path), throwsA(isA<DioException>()));
      expect(attempts, 1);
    });
  }

  for (final type in [
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionTimeout,
  ]) {
    test(
      'slow read-only batch preserves ADR-108 timeout guard: $type',
      () async {
        var attempts = 0;
        final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
        addTearDown(() => dio.close(force: true));
        dio.httpClientAdapter = _Adapter((request) {
          attempts++;
          throw DioException(requestOptions: request, type: type);
        });
        dio.interceptors.add(
          SafeRequestRetryInterceptor(dio, delay: (_) async {}, web: true),
        );
        await expectLater(
          dio.post<dynamic>(_path),
          throwsA(isA<DioException>()),
        );
        expect(attempts, 1);
      },
    );
  }

  for (final (method, path) in [
    ('POST', '/orders'),
    ('POST', '/platform-columns/goods/definitions'),
    ('POST', '/platform-columns/goods/definitions/$_record/use'),
    ('POST', '$_path/extra'),
    ('POST', '/platform-columns/goods/items/values:batch'),
    ('PUT', '/platform-columns/goods/values/$_record'),
    ('PUT', _path),
    ('DELETE', '/platform-columns/goods/definitions/$_record'),
  ]) {
    test('$method $path cannot enter read batch retry allowlist', () async {
      var attempts = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      addTearDown(() => dio.close(force: true));
      dio.httpClientAdapter = _Adapter((request) {
        attempts++;
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        );
      });
      dio.interceptors.add(
        SafeRequestRetryInterceptor(dio, delay: (_) async {}),
      );
      await expectLater(
        dio.request<dynamic>(path, options: Options(method: method)),
        throwsA(isA<DioException>()),
      );
      expect(attempts, 1);
    });
  }

  test('cancellation during backoff prevents another batch read', () async {
    var attempts = 0;
    final delay = Completer<void>();
    final waiting = Completer<void>();
    final cancellation = CancelToken();
    final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
    addTearDown(() => dio.close(force: true));
    dio.httpClientAdapter = _Adapter((request) {
      attempts++;
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      );
    });
    dio.interceptors.add(
      SafeRequestRetryInterceptor(
        dio,
        delay: (_) {
          waiting.complete();
          return delay.future;
        },
      ),
    );
    final request = expectLater(
      dio.post<dynamic>(_path, cancelToken: cancellation),
      throwsA(isA<DioException>()),
    );
    await waiting.future;
    cancellation.cancel('Table retired');
    delay.complete();
    await request;
    expect(attempts, 1);
  });

  test('explicit no-retry flag still applies to the read-only batch', () async {
    var attempts = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
    addTearDown(() => dio.close(force: true));
    dio.httpClientAdapter = _Adapter((request) {
      attempts++;
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      );
    });
    dio.interceptors.add(SafeRequestRetryInterceptor(dio, delay: (_) async {}));
    await expectLater(
      dio.post<dynamic>(
        _path,
        options: Options(extra: {safeRequestRetryDisabledKey: true}),
      ),
      throwsA(isA<DioException>()),
    );
    expect(attempts, 1);
  });

  for (final (hint, date, expectedDelays)
      in <(String, String?, List<Duration>)>[
        (
          '1',
          null,
          [const Duration(seconds: 1), const Duration(milliseconds: 1200)],
        ),
        (
          '10',
          null,
          [const Duration(seconds: 10), const Duration(seconds: 10)],
        ),
        ('11', null, []),
        ('999999999999999999999999999999999999', null, []),
        (
          'Wed, 28 Oct 2026 12:00:05 GMT',
          'Wed, 28 Oct 2026 12:00:00 GMT',
          [const Duration(seconds: 5), const Duration(seconds: 5)],
        ),
        ('Wed, 28 Oct 2026 12:10:00 GMT', 'Wed, 28 Oct 2026 12:00:00 GMT', []),
        (
          'Wed, 28 Oct 2026 11:00:00 GMT',
          'Wed, 28 Oct 2026 12:00:00 GMT',
          [
            const Duration(milliseconds: 400),
            const Duration(milliseconds: 1200),
          ],
        ),
        (
          'invalid',
          null,
          [
            const Duration(milliseconds: 400),
            const Duration(milliseconds: 1200),
          ],
        ),
        (
          '-1',
          null,
          [
            const Duration(milliseconds: 400),
            const Duration(milliseconds: 1200),
          ],
        ),
      ]) {
    test('batch read respects Retry-After $hint date=$date', () async {
      var attempts = 0;
      final delays = <Duration>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      addTearDown(() => dio.close(force: true));
      dio.httpClientAdapter = _Adapter((request) {
        attempts++;
        if (attempts == 3) return _json([]);
        return ResponseBody.fromString(
          jsonEncode({'code': 'SERVICE_UNAVAILABLE'}),
          503,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
            'retry-after': [hint],
            if (date != null) 'date': [date],
          },
        );
      });
      dio.interceptors.add(
        SafeRequestRetryInterceptor(
          dio,
          delay: (duration) async => delays.add(duration),
        ),
      );
      if (expectedDelays.isEmpty) {
        await expectLater(
          dio.post<dynamic>(_path),
          throwsA(isA<DioException>()),
        );
        expect(attempts, 1, reason: 'A long cooldown must not be shortened.');
      } else {
        await dio.post<dynamic>(_path);
        expect(attempts, 3);
      }
      expect(delays, expectedDelays);
    });
  }

  test(
    'HTTP-date Retry-After uses bounded current clock when Date is absent',
    () {
      final request = RequestOptions(path: _path, method: 'POST');
      final error = DioException.badResponse(
        statusCode: 503,
        requestOptions: request,
        response: Response<void>(
          requestOptions: request,
          statusCode: 503,
          headers: Headers.fromMap({
            'retry-after': ['Wed, 28 Oct 2026 12:00:03 GMT'],
          }),
        ),
      );
      expect(
        withClock(
          Clock.fixed(DateTime.utc(2026, 10, 28, 12)),
          () => safeRequestRetryAfter(error),
        ),
        const Duration(seconds: 3),
      );
    },
  );

  test('Retry-After does not turn a rate limit or write into a safe retry', () {
    for (final (method, path, status) in [
      ('POST', _path, 429),
      ('POST', '/orders', 503),
      ('PUT', '/platform-columns/goods/values/$_record', 503),
    ]) {
      final request = RequestOptions(path: path, method: method);
      final error = DioException.badResponse(
        statusCode: status,
        requestOptions: request,
        response: Response<Map<String, String>>(
          requestOptions: request,
          statusCode: status,
          data: {'code': 'SERVICE_UNAVAILABLE'},
          headers: Headers.fromMap({
            'retry-after': ['1'],
          }),
        ),
      );
      expect(shouldRetrySafeRequest(error), isFalse);
    }
  });
}
