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

  /// 货架目视化清单：货品主档已维护库位号的货品（库行/库位号/编码/系列/名称/颜色）。
  /// rack=库行（如 A31）；keyword=名称/编号/系列/库位号模糊。与库存数量无关。
  Future<List<ShelfLabelRow>> shelfLabels({
    String? rack,
    String? keyword,
  }) async {
    final list = await api.getList(
      ApiEndpoints.stockShelfLabels,
      query: {
        'rack': ?rack,
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
      },
    );
    return list.map(ShelfLabelRow.fromJson).toList();
  }

  /// 全部库行（货架编号，筛选下拉数据源）。
  Future<List<String>> shelfLabelRacks() {
    return api.getStringList(ApiEndpoints.stockShelfLabelRacks);
  }
}

/// 货架目视化清单行（/stock/shelf-labels）。
class ShelfLabelRow {
  const ShelfLabelRow({
    required this.goodsId,
    required this.rack,
    this.place,
    this.goodsCode,
    this.series,
    this.goodsName,
    this.colorName,
  });

  final String goodsId;
  final String rack;
  final String? place;
  final String? goodsCode;
  final String? series;
  final String? goodsName;
  final String? colorName;

  factory ShelfLabelRow.fromJson(Map<String, dynamic> json) => ShelfLabelRow(
    goodsId: json['goodsId'] as String? ?? '',
    rack: json['rack'] as String? ?? '',
    place: json['place'] as String?,
    goodsCode: json['goodsCode'] as String?,
    series: json['series'] as String?,
    goodsName: json['goodsName'] as String?,
    colorName: json['colorName'] as String?,
  );
}

final stockQueryRepositoryProvider = Provider<StockQueryRepository>(
  (ref) => StockQueryRepository(ref.watch(apiClientProvider)),
);
