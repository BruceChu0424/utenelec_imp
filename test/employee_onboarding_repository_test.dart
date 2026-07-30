import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';

void main() {
  test('onboarding parses profile and one-time temporary password', () async {
    late RequestOptions captured;
    final repository = DioEmployeeRepository(
      _api((request) {
        captured = request;
        return {
          'employee': {'id': 'employee-1', 'code': 'E1001', 'fullName': '张三'},
          'temporaryPassword': 'A7!temporary-Only2',
        };
      }),
    );

    final result = await repository.create(
      EmployeeOnboardingInput(
        profile: const {
          'code': 'E1001',
          'fullName': '张三',
          'idType': '身份证',
          'idNumber': '11010519491231002X',
          'phone': '13800138000',
        },
        employment: const {
          'departmentId': 'department-1',
          'hireDate': '2026-07-30',
          'employmentType': 'regular',
          'status': 'probation',
        },
      ),
    );

    expect(result.employee.code, 'E1001');
    expect(result.temporaryPassword, 'A7!temporary-Only2');
    expect(captured.method, 'POST');
    expect(captured.path, '/org/employees');
  });

  test(
    'onboarding rejects a response that omits the one-time secret',
    () async {
      final repository = DioEmployeeRepository(
        _api(
          (_) => {
            'employee': {'id': 'employee-1', 'code': 'E1001', 'fullName': '张三'},
          },
        ),
      );

      await expectLater(
        repository.create(
          EmployeeOnboardingInput(profile: const {}, employment: const {}),
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );
}

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
