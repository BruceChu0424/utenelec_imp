import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/impersonation_repository.dart';

void main() {
  test(
    'target page preserves displayed locked/no-account facts and does not fetch all pages',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {
                  'items': [
                    {
                      'employeeId': 'locked',
                      'name': '锁定员工',
                      'employeeCode': 'E001',
                      'accountStatus': 'locked',
                      'employmentStatus': 'active',
                    },
                    {
                      'employeeId': 'no-account',
                      'name': '未开户员工',
                      'employeeCode': 'E002',
                      'accountStatus': 'notProvisioned',
                      'employmentStatus': 'active',
                    },
                  ],
                  'page': 2,
                  'size': 100,
                  'total': 6001,
                  'totalPages': 61,
                },
              ),
            );
          },
        ),
      );
      final page = await ImpersonationRepository(ApiClient(dio)).targetsPage(
        ' E001 ',
        page: 2,
        departmentId: 'department-1',
        includeSubtree: true,
      );
      expect(requests, hasLength(1));
      expect(requests.single.path, '/admin/impersonation/targets/page');
      expect(requests.single.queryParameters, {
        'search': 'E001',
        'page': 2,
        'size': 100,
        'departmentId': 'department-1',
        'includeSubtree': true,
      });
      expect(page.totalPages, 61);
      expect(page.items.map((item) => item.accountStatus), [
        'locked',
        'notProvisioned',
      ]);
    },
  );
}
