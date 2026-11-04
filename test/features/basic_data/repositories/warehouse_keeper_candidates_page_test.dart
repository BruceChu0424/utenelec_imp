import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_keeper_repository.dart';

void main() {
  test(
    'keeper candidate page remains bounded and preserves account/membership/duplicate warning facts',
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
                      'employeeId': 'keeper',
                      'name': '仓管甲',
                      'code': 'E001',
                      'hasAccount': false,
                      'warehouseMember': false,
                      'duplicateName': true,
                      'accountStatus': 'notProvisioned',
                      'employmentStatus': 'probation',
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
      final page = await WarehouseKeeperRepository(ApiClient(dio))
          .candidatesPage(
            ' E001 ',
            page: 2,
            departmentId: 'warehouse-dept',
            includeSubtree: true,
          );
      expect(requests, hasLength(1));
      expect(
        requests.single.path,
        '${ApiEndpoints.warehouseKeeperCandidates}/page',
      );
      expect(requests.single.queryParameters, {
        'page': 2,
        'size': 100,
        'keyword': 'E001',
        'departmentId': 'warehouse-dept',
        'includeSubtree': true,
      });
      expect(page.totalPages, 61);
      expect(page.items.single.hasAccount, false);
      expect(page.items.single.warehouseMember, false);
      expect(page.items.single.duplicateName, true);
      expect(page.items.single.accountStatus, 'notProvisioned');
      expect(page.items.single.employmentStatus, 'probation');
    },
  );
}
