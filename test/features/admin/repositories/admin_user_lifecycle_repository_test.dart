import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';

void main() {
  test(
    'userByEmployeeId parses employment status and current capability',
    () async {
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
                  'id': 'user-1',
                  'employeeId': 'employee-1',
                  'loginAccount': '13800000000',
                  'status': 'disabled',
                  'roles': <String>[],
                  'remoteAccess': false,
                  'employeeStatus': 'resigned',
                  'currentEmployee': false,
                },
              ),
            );
          },
        ),
      );

      final user = await DioAdminRepository(
        ApiClient(dio),
      ).userByEmployeeId('employee-1');

      expect(captured.method, 'GET');
      expect(captured.path, '/admin/users/by-employee/employee-1');
      expect(user.employeeStatus, 'resigned');
      expect(user.currentEmployee, isFalse);
      expect(user.passwordResetAllowed, isTrue);
    },
  );
}
