import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';

void main() {
  test(
    'detail and every batch detail read carry the selected warehouse',
    () async {
      final api = _ScopeApi();
      final repository = WarehouseQualityResultRepository(
        api,
        scopeWarehouseId: 'warehouse-B',
      );
      await repository.detail('PURCHASE', 'single-receipt');
      await Future.wait([
        repository.detail('PURCHASE', 'batch-receipt-1'),
        repository.detail('SUBCONTRACT', 'batch-receipt-2'),
      ]);
      expect(api.queries, hasLength(3));
      expect(api.queries, everyElement({'scopeWarehouseId': 'warehouse-B'}));
      expect(api.paths.toSet(), hasLength(3));
    },
  );

  test(
    'default detail scope is resolved by the server without an all-scope override',
    () async {
      final api = _ScopeApi();
      await WarehouseQualityResultRepository(api).detail('PURCHASE', 'receipt');
      expect(api.queries.single, isEmpty);
    },
  );
}

class _ScopeApi extends ApiClient {
  _ScopeApi() : super(Dio());

  final paths = <String>[];
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    queries.add(Map<String, dynamic>.from(query ?? const {}));
    return {
      'receiptType': path.contains('SUBCONTRACT') ? 'SUBCONTRACT' : 'PURCHASE',
      'receiptId': path.split('/').last,
      'workStatus': 'WAITING_INSPECTION',
    };
  }
}
