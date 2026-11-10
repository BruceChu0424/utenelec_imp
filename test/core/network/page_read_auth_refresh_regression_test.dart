import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/page_read_priority_interceptor.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final parallelReads in [1, 8]) {
    test(
      '30 permission epoch changes preserve $parallelReads concurrent reads',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        const baseUrl = 'https://erp.example.cn/api';
        final storage = SecureStorage(const FlutterSecureStorage());
        await storage.saveTokens(
          accessToken: 'access-0',
          refreshToken: 'refresh-0',
          issuer: AuthBackendRealmPolicy().issuerFor(baseUrl),
        );
        var epoch = 0;
        var refreshes = 0;
        var writes = 0;
        final dispatched = <String>[];
        Future<ResponseBody> respond(RequestOptions options) async {
          dispatched.add(options.path);
          if (options.path == '/auth/refresh') {
            refreshes++;
            return _json(200, {
              'accessToken': 'access-$epoch',
              'refreshToken': 'refresh-$epoch',
            });
          }
          if (options.headers['Authorization'] != 'Bearer access-$epoch') {
            return _json(401, {'code': 'UNAUTHORIZED'});
          }
          if (options.method == 'PUT') {
            writes++;
            epoch++;
          }
          return _json(200, {'epoch': epoch});
        }

        Dio createTransport() =>
            Dio(BaseOptions(baseUrl: baseUrl))
              ..httpClientAdapter = _Adapter(respond);
        final dio = createTransport();
        final auth = AuthInterceptor(
          replay: dio.fetch<dynamic>,
          storage: storage,
          baseUrl: baseUrl,
          dioFactory: createTransport,
        );
        final scheduler = PageReadPriorityInterceptor(
          isCurrent: auth.requestBelongsToCurrentIdentity,
        );
        dio.interceptors.add(auth);
        scheduler.installOn(dio);
        addTearDown(() {
          scheduler.close();
          dio.close(force: true);
        });

        for (var account = 0; account < 30; account++) {
          await dio.put<dynamic>('/admin/users/account-$account/permissions');
          final replies =
              await Future.wait([
                for (var read = 0; read < parallelReads; read++)
                  dio.get<Map<String, dynamic>>(
                    '/admin/users/account-$account/permissions',
                    queryParameters: {'read': read},
                  ),
              ]).timeout(
                const Duration(seconds: 2),
                onTimeout: () {
                  throw StateError(
                    'Account ${account + 1} read never dispatched; '
                    'refreshes=$refreshes writes=$writes last=${dispatched.last}',
                  );
                },
              );
          expect(
            replies.map((reply) => reply.data!['epoch']),
            everyElement(account + 1),
          );
        }
        final status = await dio
            .get<Map<String, dynamic>>('/admin/server-status')
            .timeout(const Duration(seconds: 2));
        expect(status.data!['epoch'], 30);
        expect(refreshes, 30, reason: 'Concurrent 401s share one refresh');
        expect(writes, 30, reason: 'Read recovery must never replay a write');
        expect(dispatched.last, '/admin/server-status');
        expect(
          scheduler.timings,
          hasLength((30 * parallelReads * 2 + 1).clamp(0, 256)),
          reason: 'Both refused and recovered attempts release their permit',
        );
      },
    );
  }
}

ResponseBody _json(int status, Map<String, Object> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}
