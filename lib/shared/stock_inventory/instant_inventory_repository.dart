// Authorized read-only inventory projection; no balance mutation or local totals.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../models/paged_result.dart';
import 'instant_inventory_row.dart';

class InstantInventoryRepository {
  InstantInventoryRepository(this._api);

  final ApiClient _api;

  /// 即时库存分页（货品+颜色聚合余额；categoryId=分类含子树 / warehouseId=仓库 / keyword 模糊）。
  /// includeDefective=「含不良品仓」开关(仅仓库=全部/主仓聚合时生效；ADR-146 默认 false，
  /// 打开后每行另带 defectiveQty 与合计「其中不良品数量」)。
  /// 2026-09-16 起表头筛选：owningWarehouse=归属仓库 UUID；colorId/series/unitId=颜色/
  /// 物料系列/单位列筛选（值为颜色 UUID / 系列文本 / 单位 UUID，桶由列表响应 facets 下发）。
  /// attention 为服务器白名单行动规则；明细和 totals 包含规则筛选，facets 保持基础范围。
  /// warehouseRelatedOnly 仅保留所选仓范围内有余额或收货记录的货品+颜色，
  /// 用于仓库资料内的库存表，避免全公司零库存货品占位。
  /// 行动清单使用专用路由，旧服务端必须明确失败，不能把忽略规则的全量数据当风险。
  Future<PagedResult<InstantInventoryRow>> instantInventory({
    int page = 1,
    int size = 20,
    String? categoryId,
    String? warehouseId,
    bool includeDefective = false,
    bool includeLineSide = false,
    bool warehouseRelatedOnly = false,
    String? keyword,
    bool includeRelated = false,
    String? owningWarehouse,
    bool owningWarehouseNull = false,
    String? colorId,
    String? series,
    String? unitId,
    String? attention,
    String? sort,
    String? order,
  }) async {
    final json = await _api.get(
      attention == null
          ? ApiEndpoints.stockInstantInventory
          : '${ApiEndpoints.stockInstantInventory}/attention',
      query: {
        'page': page,
        'size': size,
        'categoryId': ?categoryId,
        'warehouseId': ?warehouseId,
        'includeDefective': includeDefective,
        // V595：线边仓(车间直送料架)默认不算进现实库存，显式打开才计入。
        if (includeLineSide) 'includeLineSide': true,
        if (warehouseRelatedOnly) 'warehouseRelatedOnly': true,
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        if (includeRelated && keyword?.trim().isNotEmpty == true)
          'includeRelated': true,
        // V587/V590 归属表头筛选：UUID 等值 / 未登记。
        'owningWarehouse': ?owningWarehouse,
        if (owningWarehouseNull) 'owningWarehouseNull': true,
        // 2026-09-16 颜色/物料系列/单位表头筛选。
        'colorId': ?colorId,
        'series': ?series,
        'unitId': ?unitId,
        'attention': ?attention,
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return PagedResult.fromJson(json, InstantInventoryRow.fromJson);
  }
}

final instantInventoryRepositoryProvider = Provider<InstantInventoryRepository>(
  (ref) => InstantInventoryRepository(ref.watch(apiClientProvider)),
);
