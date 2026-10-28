import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_repository.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';

void main() {
  test(
    'employee relationship headers retain the original qualification statuses and subtree scope',
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
                data: {
                  'items': <Object?>[],
                  'page': 1,
                  'size': 100,
                  'total': 0,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );
      final EmployeeRepository repository = DioEmployeeRepository(
        ApiClient(dio),
      );
      await repository.listWithColumnQuery(
        page: 2,
        size: 100,
        statuses: {'active', 'onLeave'},
        departmentId: 'selected',
        includeSubtree: true,
        columnQuery: {
          'search.name': '员工%_',
          'employmentStatus': 'onLeave',
          'accountStatus': 'locked',
        },
        sort: 'employeeCode',
        order: 'desc',
      );
      expect(captured.queryParameters['statuses'], ['active', 'onLeave']);
      expect(
        captured.queryParameters,
        containsPair('departmentId', 'selected'),
      );
      expect(captured.queryParameters, containsPair('includeSubtree', true));
      expect(captured.queryParameters, containsPair('page', 2));
      expect(captured.queryParameters, containsPair('search.name', '员工%_'));
      expect(
        captured.queryParameters,
        containsPair('employmentStatus', 'onLeave'),
      );
      expect(captured.queryParameters, containsPair('accountStatus', 'locked'));
      expect(captured.queryParameters, containsPair('sort', 'employeeCode'));
    },
  );
  test(
    'staff request preserves surface and managed department with independent header conditions',
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
                data: {
                  'items': <Object?>[],
                  'page': 1,
                  'size': 40,
                  'total': 0,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );
      await PagePermissionDelegationRepository(ApiClient(dio)).staffPage(
        surfaceKey: 'sales.order',
        departmentId: 'managed-department',
        search: '姓名',
        columnQuery: {
          'search.position': '业务%_员',
          'accountStatus': 'notProvisioned',
          'employmentStatus': 'probation',
        },
        sort: 'employeeCode',
        ascending: false,
      );
      expect(
        captured.queryParameters,
        containsPair('surfaceKey', 'sales.order'),
      );
      expect(
        captured.queryParameters,
        containsPair('departmentId', 'managed-department'),
      );
      expect(captured.queryParameters, containsPair('search', '姓名'));
      expect(
        captured.queryParameters,
        containsPair('search.position', '业务%_员'),
      );
      expect(
        captured.queryParameters,
        containsPair('accountStatus', 'notProvisioned'),
      );
      expect(
        captured.queryParameters,
        containsPair('employmentStatus', 'probation'),
      );
      expect(captured.queryParameters, containsPair('sort', 'employeeCode'));
      expect(captured.queryParameters, containsPair('order', 'desc'));
    },
  );
}
