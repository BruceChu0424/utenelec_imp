import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';

void main() {
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
