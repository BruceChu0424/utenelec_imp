import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';

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
  for (final target in ['admin', 'employee']) {
    test(
      '$target rejects a different manual receipt without treating it as the chosen password',
      () async {
        final api = _api(
          (_) => {'temporaryPassword': 'DIFFERENT-SYNTHETIC-RECEIPT'},
        );
        final result = target == 'admin'
            ? DioAdminRepository(
                api,
              ).resetPassword('target', temporaryPassword: ' 合成A!口令 ')
            : DioEmployeeRepository(
                api,
              ).resetPassword('target', temporaryPassword: ' 合成A!口令 ');
        await expectLater(result, throwsA(isA<FormatException>()));
      },
    );
  }

  test(
    'admin random request stays body-free and manual request preserves raw text',
    () async {
      final requests = <RequestOptions>[];
      final repository = DioAdminRepository(
        _api((request) {
          requests.add(request);
          final body = request.data as Map<String, dynamic>?;
          return {
            'temporaryPassword':
                body?['temporaryPassword'] ?? 'SYNTHETIC-RANDOM-20!',
          };
        }),
      );
      expect(await repository.resetPassword('target'), 'SYNTHETIC-RANDOM-20!');
      expect(requests.last.data, isNull);
      const custom = ' 合成A!口令 ';
      expect(
        await repository.resetPassword('target', temporaryPassword: custom),
        custom,
      );
      expect(requests.last.path, '/admin/users/target/reset-password');
      expect(requests.last.data, {'temporaryPassword': custom});
    },
  );

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

  test(
    'manual temporary password is sent verbatim to the same employee endpoint',
    () async {
      late RequestOptions captured;
      const custom = ' 自定A!口令 ';
      final repository = DioEmployeeRepository(
        _api((request) {
          captured = request;
          return {'temporaryPassword': custom};
        }),
      );
      expect(
        await repository.resetPassword('emp-7', temporaryPassword: custom),
        custom,
      );
      expect(captured.path, '/org/employees/emp-7/account/reset-password');
      expect(captured.data, {'temporaryPassword': custom});
    },
  );

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
    test('admin ${entry.key} is not a usable credential receipt', () async {
      final repository = DioAdminRepository(_api((_) => entry.value));
      await expectLater(
        repository.resetPassword('target'),
        throwsA(isA<FormatException>()),
      );
    });
    test('${entry.key}时响应失败，不伪装成已生成可交付密码', () async {
      final repository = DioEmployeeRepository(_api((_) => entry.value));

      await expectLater(
        repository.resetPassword('emp-7'),
        throwsA(isA<FormatException>()),
      );
    });
  }
}
