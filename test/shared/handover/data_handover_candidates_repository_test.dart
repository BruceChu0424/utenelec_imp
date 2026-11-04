import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';
import 'package:uten_imp/shared/handover/data_handover_repository.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker_models.dart';

void main() {
  test(
    'handover pages derive legacy DTO page count, retain role and exclude before paging through a read body',
    () async {
      final requests = <RequestOptions>[];
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
                      'employeeId': 'source-other',
                      'code': 'E001',
                      'name': '交出人甲',
                      'status': 'resigned',
                      'accountStatus': 'disabled',
                      'employmentStatus': 'resigned',
                    },
                  ],
                  'page': 2,
                  'size': 100,
                  'total': 6001,
                },
              ),
            );
          },
        ),
      );
      final page = await DataHandoverRepository(ApiClient(dio)).pickerPage(
        const UtenEmployeePickerQuery(
          page: 2,
          keyword: ' E001 ',
          departmentId: 'department-1',
        ),
        role: DataHandoverCandidateRole.source,
        excludeEmployeeIds: {'target'},
      );
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.path, '/admin/data-handovers/candidates/query');
      final body = requests.single.data as Map<String, dynamic>;
      expect(body['role'], 'source');
      expect(body['page'], 2);
      expect(body['departmentId'], 'department-1');
      expect(body['excludeEmployeeIds'], ['target']);
      expect(page.totalPages, 61);
      expect(page.items.single.accountStatus, 'disabled');
      expect(page.items.single.employmentStatus, 'resigned');
    },
  );
  test(
    'uses scoped candidate endpoint with server search and pagination',
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
                  'items': [
                    {
                      'employeeId': 'employee-1',
                      'code': 'E001',
                      'name': '接手人甲',
                      'departmentId': 'department-1',
                      'departmentName': '销售部',
                      'status': 'active',
                    },
                  ],
                  'page': 2,
                  'size': 20,
                  'total': 21,
                },
              ),
            );
          },
        ),
      );

      final page = await DataHandoverRepository(ApiClient(dio)).candidates(
        role: DataHandoverCandidateRole.target,
        query: '  E001  ',
        page: 2,
      );

      expect(captured.path, '/admin/data-handovers/candidates');
      expect(captured.queryParameters, {
        'role': 'target',
        'query': 'E001',
        'page': 2,
        'size': 20,
      });
      expect(page.total, 21);
      expect(page.totalPages, 2);
      expect(page.items.single.employeeId, 'employee-1');
      expect(page.items.single.departmentName, '销售部');
    },
  );
}
