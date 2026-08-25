import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';
import 'package:uten_imp/shared/handover/data_handover_repository.dart';

void main() {
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
      expect(page.items.single.employeeId, 'employee-1');
      expect(page.items.single.departmentName, '销售部');
    },
  );
}
