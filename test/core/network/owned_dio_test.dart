import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/visitor_auth_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/network/owned_dio.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  test(
    'owned client closes gracefully only after the operation settles',
    () async {
      final adapter = _Adapter((_) => throw UnimplementedError());
      final client = Dio()..httpClientAdapter = adapter;
      final pending = Completer<int>();
      final operation = withOwnedDio(() => client, (_) => pending.future);
      expect(adapter.closes, isEmpty);
      pending.complete(7);
      expect(await operation, 7);
      expect(adapter.closes, [false]);
    },
  );

  test('owned client closes when the operation throws synchronously', () async {
    final adapter = _Adapter((_) => throw UnimplementedError());
    final client = Dio()..httpClientAdapter = adapter;
    final error = StateError('operation failed');
    await expectLater(
      withOwnedDio<int>(() => client, (_) => throw error),
      throwsA(same(error)),
    );
    expect(adapter.closes, [false]);
  });

  test('owned client closes after an asynchronous failure', () async {
    final adapter = _Adapter((_) => throw UnimplementedError());
    final client = Dio()..httpClientAdapter = adapter;
    final error = StateError('operation failed');
    await expectLater(
      withOwnedDio(() => client, (_) => Future<int>.error(error)),
      throwsA(same(error)),
    );
    expect(adapter.closes, [false]);
  });

  for (final visitor in [false, true]) {
    for (final outcome in ['success', 'refresh-failed', 'replay-failed']) {
      test(
        '${visitor ? 'visitor' : 'staff'} $outcome releases every temporary client',
        () async {
          FlutterSecureStorage.setMockInitialValues({});
          final storage = SecureStorage(const FlutterSecureStorage());
          if (visitor) {
            await storage.saveVisitorTokens(
              accessToken: 'old',
              refreshToken: 'refresh',
            );
          } else {
            await storage.saveTokens(
              accessToken: 'old',
              refreshToken: 'refresh',
            );
          }
          final adapters = <_Adapter>[];
          Dio create() {
            final client = Dio(
              buildApiBaseOptions('https://erp.example.cn/api'),
            );
            final adapter = _Adapter((options) {
              if (options.path.endsWith('/auth/refresh')) {
                return _json(outcome == 'refresh-failed' ? 503 : 200, {
                  'accessToken': 'new',
                  'refreshToken': 'new-refresh',
                });
              }
              if (options.headers['Authorization'] == 'Bearer new') {
                return _json(outcome == 'replay-failed' ? 409 : 200, {
                  'ok': true,
                });
              }
              return _json(401, {'code': 'UNAUTHORIZED'});
            });
            adapters.add(adapter);
            client.httpClientAdapter = adapter;
            return client;
          }

          final client = create();
          addTearDown(client.close);
          client.interceptors.add(
            visitor
                ? VisitorAuthInterceptor(
                    storage: storage,
                    baseUrl: client.options.baseUrl,
                    dioFactory: create,
                  )
                : AuthInterceptor(
                    storage: storage,
                    baseUrl: client.options.baseUrl,
                    dioFactory: create,
                  ),
          );
          if (outcome == 'success') {
            expect((await client.get<dynamic>('/protected')).data, {
              'ok': true,
            });
          } else {
            await expectLater(
              client.get<dynamic>('/protected'),
              throwsA(isA<DioException>()),
            );
          }
          expect(adapters, hasLength(outcome == 'refresh-failed' ? 2 : 3));
          expect(adapters.first.closes, isEmpty);
          for (final adapter in adapters.skip(1)) {
            expect(adapter.closes, [false]);
          }
          expect(
            await (visitor
                ? storage.getVisitorAccessToken()
                : storage.getAccessToken()),
            outcome == 'refresh-failed' ? 'old' : 'new',
          );
        },
      );
    }
  }
}

ResponseBody _json(int status, Object data) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  final closes = <bool>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  @override
  void close({bool force = false}) => closes.add(force);
}
