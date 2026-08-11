import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';

void main() {
  test('listUsers forwards status to server-side pagination', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: const {
                'items': <dynamic>[],
                'page': 2,
                'size': 30,
                'total': 0,
                'totalPages': 0,
              },
            ),
          );
        },
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));
    await repository.listUsers(
      page: 2,
      size: 30,
      search: 'zhang',
      status: 'locked',
    );

    expect(captured.method, 'GET');
    expect(captured.uri.path, '/api/admin/users');
    expect(captured.uri.queryParameters, const {
      'page': '2',
      'size': '30',
      'search': 'zhang',
      'status': 'locked',
    });
  });

  test('resetPassword parses one-time temporaryPassword response', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: {'temporaryPassword': 'Temp-Only-2026!'},
            ),
          );
        },
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));
    final password = await repository.resetPassword('user-1');

    expect(password, 'Temp-Only-2026!');
    expect(captured.method, 'POST');
    expect(captured.path, '/admin/users/user-1/reset-password');
  });

  test('resetPassword rejects an empty or missing secret', () async {
    for (final response in <Map<String, dynamic>>[
      const {},
      const {'temporaryPassword': ''},
    ]) {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: response,
            ),
          ),
        ),
      );

      final repository = DioAdminRepository(ApiClient(dio));
      await expectLater(
        repository.resetPassword('user-1'),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('getUserDataScopes parses a raw UUID string array', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: const ['owner-1', 'owner-2'],
            ),
          );
        },
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));
    final scopes = await repository.getUserDataScopes('user-1', 'goods');

    expect(scopes, const ['owner-1', 'owner-2']);
    expect(captured.method, 'GET');
    expect(captured.path, '/admin/users/user-1/data-scopes?scope=goods');
    expect(captured.uri.queryParameters, const {'scope': 'goods'});
  });

  test('getUserDataScopes accepts an empty array', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: const <String>[],
          ),
        ),
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));

    expect(await repository.getUserDataScopes('user-1', 'client'), isEmpty);
  });

  test('getUserDataScopes rejects a non-string array response', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: const [1],
          ),
        ),
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));

    await expectLater(
      repository.getUserDataScopes('user-1', 'sales'),
      throwsA(isA<FormatException>()),
    );
  });
}
