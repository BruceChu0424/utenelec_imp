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

  /// 货架目视化清单行：货品主档已维护库位号的货品（未软删；默认不含禁用），
  /// 库位号按「库行-层-位」三段解析（不符合格式的行 parsed=false，归「未分层」），
  /// 附即时库存参考量与单位。
  /// - [rack]：库行（如 A31），只对已分层行生效；null=全部；
  /// - [keyword]：名称/编号/系列/库位号模糊；
  /// - [warehouseId]：选仓 = 本仓树偏好库位优先 + 该仓及子仓库存汇总；null = 主档库位 + 全部核算仓汇总；
  /// - [includeDisabled]：是否包含 status='禁用' 的货品。
  Future<List<ShelfLabelRow>> shelfLabels({
    String? rack,
    String? keyword,
    String? warehouseId,
    bool includeDisabled = false,
  }) async {
    final list = await api.getList(
      ApiEndpoints.stockShelfLabels,
      query: {
        'rack': ?rack,
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        'warehouseId': ?warehouseId,
        'includeDisabled': includeDisabled,
      },
    );
    return list.map(ShelfLabelRow.fromJson).toList();
  }

  /// 已分层库行（去重排序；残值不含）：库行下拉数据源。
  Future<List<String>> shelfLabelRacks({
    String? warehouseId,
    bool includeDisabled = false,
  }) {
    return api.getStringList(
      ApiEndpoints.stockShelfLabelRacks,
      query: {'warehouseId': ?warehouseId, 'includeDisabled': includeDisabled},
    );
  }

  /// 货架图布局：每个已分层库行的最大层/位与行数；末尾 rack 为空串的一条是「未分层」桶
  /// （仅残值数 > 0 时出现）。
  Future<List<ShelfLayoutRack>> shelfLabelLayout({
    String? warehouseId,
    bool includeDisabled = false,
  }) async {
    final list = await api.getList(
      ApiEndpoints.stockShelfLabelLayout,
      query: {'warehouseId': ?warehouseId, 'includeDisabled': includeDisabled},
    );
    return list.map(ShelfLayoutRack.fromJson).toList();
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
    this.unitName,
    this.qty = 0,
    this.disabled = false,
    this.level,
    this.slot,
    this.parsed = false,
  });

  final String goodsId;

  /// 库行（如 A31）；未分层行为空串。
  final String rack;

  /// 库位号（选仓时本仓偏好优先，否则主档原值）。
  final String? place;
  final String? goodsCode;
  final String? series;
  final String? goodsName;
  final String? colorName;

  /// 单位名称（无则空串/null）。
  final String? unitName;

  /// 即时库存参考量（未选仓=全部核算仓汇总；选仓=该仓及子仓汇总）。
  final double qty;

  /// 货品已禁用（仅 includeDisabled=true 时会出现）。
  final bool disabled;

  /// 层 / 位（未分层为 null）。
  final int? level;
  final int? slot;

  /// 库位号是否符合「库行-层-位」三段格式。
  final bool parsed;

  factory ShelfLabelRow.fromJson(Map<String, dynamic> json) => ShelfLabelRow(
    goodsId: json['goodsId'] as String? ?? '',
    rack: json['rack'] as String? ?? '',
    place: json['place'] as String?,
    goodsCode: json['goodsCode'] as String?,
    series: json['series'] as String?,
    goodsName: json['goodsName'] as String?,
    colorName: json['colorName'] as String?,
    unitName: json['unitName'] as String?,
    qty: (json['qty'] as num?)?.toDouble() ?? 0,
    disabled: json['disabled'] as bool? ?? false,
    level: (json['level'] as num?)?.toInt(),
    slot: (json['slot'] as num?)?.toInt(),
    parsed: json['parsed'] as bool? ?? false,
  );
}

/// 货架图布局项（/stock/shelf-labels/layout）：[rack] 为空串 = 未分层桶。
class ShelfLayoutRack {
  const ShelfLayoutRack({
    required this.rack,
    this.maxLevel,
    this.maxSlot,
    this.count = 0,
  });

  final String rack;
  final int? maxLevel;
  final int? maxSlot;
  final int count;

  bool get isUnparsedBucket => rack.isEmpty;

  factory ShelfLayoutRack.fromJson(Map<String, dynamic> json) =>
      ShelfLayoutRack(
        rack: json['rack'] as String? ?? '',
        maxLevel: (json['maxLevel'] as num?)?.toInt(),
        maxSlot: (json['maxSlot'] as num?)?.toInt(),
        count: (json['count'] as num?)?.toInt() ?? 0,
      );
}

final stockQueryRepositoryProvider = Provider<StockQueryRepository>(
  (ref) => StockQueryRepository(ref.watch(apiClientProvider)),
);
