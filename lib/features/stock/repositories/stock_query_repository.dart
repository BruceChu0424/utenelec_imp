// 库存查询仓库：余额分页 + 流水分页。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/stock_query.dart';

class StockQueryRepository {
  StockQueryRepository(this.api);
  final ApiClient api;

  Future<PagedResult<BalanceRow>> balances({
    int page = 1,
    int size = 20,
    String? warehouseId,
    String? sort,
    String? order,
  }) async {
    final json = await api.get(ApiEndpoints.stockBalances, query: {
      'page': page,
      'size': size,
      if (warehouseId != null) 'warehouseId': warehouseId,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    });
    return PagedResult.fromJson(json, BalanceRow.fromJson);
  }

  Future<PagedResult<MovementRow>> movements({
    int page = 1,
    int size = 20,
    String? warehouseId,
    String? goodsId,
    int? movementType,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
  }) async {
    final json = await api.get(ApiEndpoints.stockMovements, query: {
      'page': page,
      'size': size,
      if (warehouseId != null) 'warehouseId': warehouseId,
      if (goodsId != null) 'goodsId': goodsId,
      if (movementType != null) 'movementType': movementType,
      if (dateFrom != null) 'dateFrom': dateFrom,
      if (dateTo != null) 'dateTo': dateTo,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    });
    return PagedResult.fromJson(json, MovementRow.fromJson);
  }
}

final stockQueryRepositoryProvider = Provider<StockQueryRepository>(
  (ref) => StockQueryRepository(ref.watch(apiClientProvider)),
);
