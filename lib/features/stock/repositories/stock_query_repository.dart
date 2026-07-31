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
    String? goodsId,
    String? sort,
    String? order,
  }) async {
    final json = await api.get(
      ApiEndpoints.stockBalances,
      query: {
        'page': page,
        'size': size,
        'warehouseId': ?warehouseId,
        'goodsId': ?goodsId,
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return PagedResult.fromJson(json, BalanceRow.fromJson);
  }

  Future<StockBalanceAdjustmentResult> adjustBalance({
    required BalanceRow balance,
    required String targetQty,
    required String reason,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.stockBalanceAdjust,
      body: {
        'idempotencyKey': idempotencyKey,
        'warehouseId': balance.warehouseId,
        'goodsId': balance.goodsId,
        'colorId': ?balance.colorId,
        'expectedQty': balance.qty ?? 0,
        'targetQty': targetQty,
        'reason': reason.trim(),
      },
    );
    return StockBalanceAdjustmentResult.fromJson(json);
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
    final json = await api.get(
      ApiEndpoints.stockMovements,
      query: {
        'page': page,
        'size': size,
        'warehouseId': ?warehouseId,
        'goodsId': ?goodsId,
        'movementType': ?movementType,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return PagedResult.fromJson(json, MovementRow.fromJson);
  }

  /// 即时库存分页（货品+颜色聚合余额；categoryId=分类含子树 / warehouseId=仓库 / keyword 模糊）。
  /// includeDefective=「含不良品仓」开关（仅仓库=全部时生效，默认 true=老系统口径）。
  Future<PagedResult<InstantInventoryRow>> instantInventory({
    int page = 1,
    int size = 20,
    String? categoryId,
    String? warehouseId,
    bool includeDefective = true,
    String? keyword,
    String? sort,
    String? order,
  }) async {
    final json = await api.get(
      ApiEndpoints.stockInstantInventory,
      query: {
        'page': page,
        'size': size,
        'categoryId': ?categoryId,
        'warehouseId': ?warehouseId,
        'includeDefective': includeDefective,
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return PagedResult.fromJson(json, InstantInventoryRow.fromJson);
  }
}

final stockQueryRepositoryProvider = Provider<StockQueryRepository>(
  (ref) => StockQueryRepository(ref.watch(apiClientProvider)),
);
