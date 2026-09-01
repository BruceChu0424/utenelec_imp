import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

/// V452：供应商字典携带默认结算方式 id，供采购/委外订货开单预填。
void main() {
  test('supplier default settlement is parsed and resolvable by id', () async {
    final service = MasterNameService(
      _StubApi([
        {
          'id': 's-monthly',
          'code': 'WJ0001',
          'name': '洪武',
          'status': '使用',
          'defaultSettlementMethodId': 'm-monthly-60',
        },
        {
          'id': 's-none',
          'code': 'WJ0002',
          'name': '无默认',
          'status': '使用',
        },
        {
          'id': 's-empty',
          'code': 'WJ0003',
          'name': '空字符串默认',
          'status': '使用',
          'defaultSettlementMethodId': '',
        },
      ]),
    );

    await service.ensureLoaded();

    expect(service.supplierDefaultSettlement('s-monthly'), 'm-monthly-60');
    expect(service.supplierDefaultSettlement('s-none'), isNull);
    expect(service.supplierDefaultSettlement('s-empty'), isNull);
    expect(service.supplierDefaultSettlement(null), isNull);
    expect(service.supplierDefaultSettlement('missing'), isNull);
  });
}

class _StubApi extends ApiClient {
  _StubApi(this.suppliers) : super(Dio());

  final List<Map<String, dynamic>> suppliers;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    return path == ApiEndpoints.suppliersDict ? suppliers : const [];
  }
}
