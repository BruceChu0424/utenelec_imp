import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../../../../shared/models/paged_result.dart';
import '../models/stock_count_request.dart';

class StockCountRequestRepository {
  StockCountRequestRepository(this.api);
  final ApiClient api;
  static const base = '/stock/count-requests';

  Future<StockCountScope> scope({String? warehouseId}) async =>
      StockCountScope.fromJson(
        await api.get('$base/scope', query: {'warehouseId': ?warehouseId}),
      );
  Future<PagedResult<CountStockRow>> candidates({
    required String warehouseId,
    String? keyword,
    List<String> goodsIds = const [],
    int page = 1,
    int size = 50,
  }) async => PagedResult.fromJson(
    await api.get(
      '$base/candidates',
      query: {
        'warehouseId': warehouseId,
        'keyword': ?keyword,
        if (goodsIds.isNotEmpty) 'goodsIds': goodsIds.join(','),
        'page': page,
        'size': size,
      },
    ),
    CountStockRow.fromJson,
  );
  Future<StockCountRequest> submit({
    required String warehouseId,
    required String reason,
    required String idempotencyKey,
    required List<Map<String, dynamic>> lines,
  }) async => StockCountRequest.fromJson(
    await api.post(
      base,
      body: {
        'warehouseId': warehouseId,
        'reason': reason,
        'idempotencyKey': idempotencyKey,
        'lines': lines,
      },
    ),
  );
  Future<PagedResult<StockCountRequest>> list({
    String? reviewRoute,
    String? status,
    int page = 1,
    int size = 50,
  }) async => PagedResult.fromJson(
    await api.get(
      base,
      query: {
        'reviewRoute': ?reviewRoute,
        'status': ?status,
        'page': page,
        'size': size,
      },
    ),
    StockCountRequest.fromJson,
  );
  Future<StockCountRequest> detail(String id) async =>
      StockCountRequest.fromJson(await api.get('$base/$id'));
  Future<StockCountCounts> counts() async =>
      StockCountCounts.fromJson(await api.get('$base/counts'));
  Future<StockCountRequest> approve(
    String id, {
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) => _review(id, 'approve', expectedVersion, idempotencyKey, reason);
  Future<StockCountRequest> reject(
    String id, {
    required int expectedVersion,
    required String idempotencyKey,
    required String reason,
  }) => _review(id, 'reject', expectedVersion, idempotencyKey, reason);
  Future<StockCountRequest> cancel(
    String id, {
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) => _review(id, 'cancel', expectedVersion, idempotencyKey, reason);
  Future<StockCountRequest> _review(
    String id,
    String action,
    int version,
    String key,
    String? reason,
  ) async => StockCountRequest.fromJson(
    await api.post(
      '$base/$id/$action',
      body: {
        'expectedVersion': version,
        'idempotencyKey': key,
        'reason': ?reason,
      },
    ),
  );
}

final stockCountRequestRepositoryProvider =
    Provider<StockCountRequestRepository>(
      (ref) => StockCountRequestRepository(ref.watch(apiClientProvider)),
    );
