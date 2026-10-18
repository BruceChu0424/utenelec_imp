import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/remote_mfa_interceptor.dart';
import 'package:uten_imp/core/network/remote_mfa_coordinator.dart';
import 'package:uten_imp/core/network/interceptors/automatic_request_interceptor.dart';

class _Adapter implements HttpClientAdapter {
  int sent = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent++;
    return ResponseBody.fromString(
      jsonEncode({'code': 'MFA_REQUIRED', 'message': 'Verify first'}),
      403,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _DelayedAdapter extends _Adapter {
  final entered = Completer<void>();
  final finish = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    entered.complete();
    await finish.future;
    return super.fetch(options, requestStream, cancelFuture);
  }
}

void main() {
  test('background polling never opens a verification dialog', () async {
    var prompts = 0;
    final coordinator = RemoteMfaCoordinator()
      ..register(() async {
        prompts++;
        return 'Verified';
      });
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(RemoteMfaInterceptor(coordinator: coordinator));
    await expectLater(
      dio.get<dynamic>(
        '/notices/count',
        options: Options(headers: {AutomaticRequestInterceptor.header: '1'}),
      ),
      throwsA(isA<DioException>()),
    );
    expect(prompts, 0);
    expect(adapter.sent, 1);
  });
  test(
    'dismissal suppresses repeated prompts briefly without replaying requests',
    () async {
      var now = DateTime.utc(2026, 10, 17);
      var prompts = 0;
      final coordinator = RemoteMfaCoordinator(clock: () => now)
        ..register(() async {
          prompts++;
          return null;
        });
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(RemoteMfaInterceptor(coordinator: coordinator));
      for (var i = 0; i < 2; i++) {
        await expectLater(
          dio.get<dynamic>('/protected'),
          throwsA(isA<DioException>()),
        );
      }
      expect(prompts, 1);
      now = now.add(const Duration(seconds: 31));
      await expectLater(
        dio.get<dynamic>('/protected'),
        throwsA(isA<DioException>()),
      );
      expect(prompts, 2);
      expect(adapter.sent, 3);
    },
  );
  test(
    'a late error from a previous identity cannot prompt under the new account',
    () async {
      var identity = 'one';
      var prompts = 0;
      final coordinator = RemoteMfaCoordinator()
        ..register(() async {
          prompts++;
          return 'Verified';
        }, context: () => identity);
      final adapter = _DelayedAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(RemoteMfaInterceptor(coordinator: coordinator));
      final request = dio.post<dynamic>('/stock/write');
      final result = expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (error) => (error.response!.data as Map)['code'],
            'code',
            'MFA_REQUIRED',
          ),
        ),
      );
      await adapter.entered.future;
      identity = 'two';
      adapter.finish.complete();
      await result;
      expect(prompts, 0);
      expect(adapter.sent, 1);
    },
  );
  test(
    'verification leaves a write rejected and never sends it a second time',
    () async {
      final coordinator = RemoteMfaCoordinator()
        ..register(() async => 'Verified; check the result before continuing.');
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(RemoteMfaInterceptor(coordinator: coordinator));
      await expectLater(
        dio.post<dynamic>('/stock/outbound', data: {'quantity': 3}),
        throwsA(
          isA<DioException>().having(
            (e) => (e.response?.data as Map)['code'],
            'code',
            'MFA_RETRY_REQUIRED',
          ),
        ),
      );
      expect(adapter.sent, 1);
    },
  );
  test(
    'login and refresh never invoke authenticated verification prompt',
    () async {
      var prompts = 0;
      final coordinator = RemoteMfaCoordinator()
        ..register(() async {
          prompts++;
          return 'Verified';
        });
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(RemoteMfaInterceptor(coordinator: coordinator));
      for (final path in ['/auth/login', '/auth/refresh', '/auth/mfa/verify']) {
        await expectLater(
          dio.post<dynamic>(path),
          throwsA(isA<DioException>()),
        );
      }
      expect(prompts, 0);
      expect(adapter.sent, 3);
    },
  );
  test(
    'concurrent failures share one verification without sharing/replaying commands',
    () async {
      final pending = Completer<String?>();
      var prompts = 0;
      final coordinator = RemoteMfaCoordinator()
        ..register(() {
          prompts++;
          return pending.future;
        });
      final first = coordinator.obtain();
      final second = coordinator.obtain();
      expect(prompts, 1);
      pending.complete(null);
      expect(await first, isNull);
      expect(await second, isNull);
    },
  );
}
