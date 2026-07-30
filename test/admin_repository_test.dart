import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';

void main() {
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
}
