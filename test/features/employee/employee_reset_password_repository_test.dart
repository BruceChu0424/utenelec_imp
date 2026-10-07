import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

void main() {
  test('员工密码重置 POST 员工账号端点，无需人事提交自选密码', () async {
    late RequestOptions captured;
    final repository = DioEmployeeRepository(
      _api((request) {
        captured = request;
        return {'temporaryPassword': 'A7!temporary-Only2'};
      }),
    );

    expect(await repository.resetPassword('emp-7'), 'A7!temporary-Only2');
    expect(captured.method, 'POST');
    expect(captured.path, '/org/employees/emp-7/account/reset-password');
    expect(captured.data, isNull);
  });

  final invalidResponses = <String, Map<String, dynamic>>{
    '缺少密码': {},
    'null 密码': {'temporaryPassword': null},
    '空密码': {'temporaryPassword': ''},
    '空白密码': {'temporaryPassword': '  \n\t '},
    '数字密码': {'temporaryPassword': 123456},
    '对象密码': {
      'temporaryPassword': {'value': 'secret'},
    },
  };
  for (final entry in invalidResponses.entries) {
    test('${entry.key}时响应失败，不伪装成已生成可交付密码', () async {
      final repository = DioEmployeeRepository(_api((_) => entry.value));

      await expectLater(
        repository.resetPassword('emp-7'),
        throwsA(isA<FormatException>()),
      );
    });
  }
}
