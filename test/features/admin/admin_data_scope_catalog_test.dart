import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';

void main() {
  test(
    'data scope catalog parses finance, view-all and disabled metadata',
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
                data: const [
                  {
                    'scope': 'finance',
                    'label': '财务单据可见制单人',
                    'description': '加看所选制单人的财务单据',
                    'viewAllPermission': 'finance:view:all',
                    'enabled': true,
                    'disabledReason': null,
                    'group': '财务',
                  },
                  {
                    'scope': 'goods',
                    'label': '外贸货品可见业务员',
                    'description': '旧开关关闭',
                    'viewAllPermission': 'goods:view:all',
                    'enabled': false,
                    'disabledReason': '当前全员可见全部货品',
                    'group': '客户与销售',
                  },
                ],
              ),
            );
          },
        ),
      );

      final catalog = await DioAdminRepository(
        ApiClient(dio),
      ).dataScopeCatalog();

      expect(captured.method, 'GET');
      expect(captured.path, '/admin/data-scope-catalog');
      expect(catalog, hasLength(2));
      expect(catalog.first.scope, 'finance');
      expect(catalog.first.displayLabel, '财务单据可见负责人');
      expect(catalog.last.enabled, isFalse);
      expect(catalog.last.displayLabel, '货品资料可见负责人');
      expect(catalog.last.disabledReason, '当前全员可见全部货品');
    },
  );
}
