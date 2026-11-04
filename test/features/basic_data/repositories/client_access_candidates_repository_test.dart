import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker_models.dart';
import 'package:uten_imp/features/basic_data/widgets/client_access_employee_loader.dart';

void main() {
  test(
    '1000 owner exclusions stay in a read body and first page does not drain 6001 staff',
    () async {
      final requests = <RequestOptions>[];
      final excluded = {
        for (var i = 0; i < 1000; i++)
          '00000000-0000-4000-8000-${i.toRadixString(16).padLeft(12, '0')}',
      };
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
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
                      'employeeId': 'allowed',
                      'name': '负责人甲',
                      'code': 'E001',
                      'status': 'active',
                      'activeAccount': true,
                    },
                  ],
                  'page': 1,
                  'size': 100,
                  'total': 6001,
                  'totalPages': 61,
                },
              ),
            );
          },
        ),
      );
      final page = await loadClientAccessEmployeePage(
        DioClientRepository(ApiClient(dio)),
        const UtenEmployeePickerQuery(
          keyword: ' E001 ',
          departmentId: 'department-1',
        ),
        excludeEmployeeIds: excluded,
      );
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.path, '/master/clients/access-candidates/query');
      expect(requests.single.uri.query, isEmpty);
      final body = requests.single.data as Map<String, dynamic>;
      expect(body['excludeEmployeeIds'], hasLength(1000));
      expect(body['departmentId'], 'department-1');
      expect(
        body['includeSubtree'],
        false,
        reason: 'An unmatched department remains an exact filter.',
      );
      expect(body['search'], 'E001');
      expect(page.totalPages, 61);
      expect(page.items.single.id, 'allowed');
    },
  );
  test('client access candidates use minimal client-assign endpoint', () async {
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
                'items': [
                  {
                    'employeeId': 'employee-1',
                    'name': '负责人甲',
                    'code': 'E001',
                    'departmentName': '销售部',
                    'status': 'active',
                    'activeAccount': true,
                  },
                ],
                'page': 1,
                'size': 20,
                'total': 1,
                'totalPages': 1,
              },
            ),
          );
        },
      ),
    );

    final page = await DioClientRepository(
      ApiClient(dio),
    ).accessCandidates(search: '  甲  ');

    expect(captured.path, '/master/clients/access-candidates');
    expect(captured.queryParameters, {'page': 1, 'size': 20, 'search': '甲'});
    expect(page.items.single.employeeId, 'employee-1');
    expect(page.items.single.activeAccount, isTrue);
  });
}
