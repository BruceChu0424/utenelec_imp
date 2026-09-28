// 入库登记库位建议(采购/委外到货与产成品登记共用，2026-09-27)。
//
// 一条链、一个端点：所选仓 × 货品 × 颜色的记忆库位(warehouse_goods_place_preferences，
// 入库/登记成功后由服务端自动学习)→ 货品资料通用库位 → 无。两类登记页选定/改仓时
// 都按仓合并请求，只覆盖没手填过的行。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

/// 建议来源(格内黄标说明用)。
enum InboundPlaceSource {
  warehousePreference('WAREHOUSE_PREFERENCE'),
  goodsMaster('GOODS_MASTER'),
  none('NONE');

  const InboundPlaceSource(this.code);

  final String code;

  static InboundPlaceSource fromCode(String? code) => values.firstWhere(
    (source) => source.code == code,
    orElse: () => InboundPlaceSource.none,
  );

  /// 黄框 ⓘ 里的来源说明。
  String get reviewHint => switch (this) {
    warehousePreference => '该仓上次入库记住的库位，请核对本次实物存放位置',
    goodsMaster => '货品资料的通用库位，请核对本次实物存放位置',
    none => '请核对本次实物存放位置',
  };
}

class WarehousePlaceSuggestion {
  const WarehousePlaceSuggestion({
    required this.goodsId,
    required this.source,
    this.colorId,
    this.place,
  });

  final String goodsId;
  final String? colorId;
  final String? place;
  final InboundPlaceSource source;

  factory WarehousePlaceSuggestion.fromJson(Map<String, dynamic> json) =>
      WarehousePlaceSuggestion(
        goodsId: json['goodsId'] as String? ?? '',
        colorId: json['colorId'] as String?,
        place: (json['place'] as String?)?.trim(),
        source: InboundPlaceSource.fromCode(json['source'] as String?),
      );
}

/// 货品 × 颜色键(建议按此回填到行)。
String inboundGoodsColorKey(String goodsId, String? colorId) =>
    '$goodsId|${colorId ?? ''}';

class WarehousePlaceSuggestionRepository {
  const WarehousePlaceSuggestionRepository(this.api);

  final ApiClient api;

  /// 一个仓一次请求：返回按「货品 × 颜色」键索引的建议。
  Future<Map<String, WarehousePlaceSuggestion>> suggest({
    required String warehouseId,
    required Iterable<({String goodsId, String? colorId})> goods,
  }) async {
    final keys = <String, ({String goodsId, String? colorId})>{
      for (final item in goods)
        inboundGoodsColorKey(item.goodsId, item.colorId): item,
    };
    if (keys.isEmpty) return const {};
    final json = await api.post(
      ApiEndpoints.warehousePlaceSuggestions,
      body: {
        'warehouseId': warehouseId,
        'items': [
          for (final item in keys.values)
            {'goodsId': item.goodsId, 'colorId': item.colorId},
        ],
      },
    );
    final items =
        (json['items'] as List?)?.whereType<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    return {
      for (final item in items.map(WarehousePlaceSuggestion.fromJson))
        inboundGoodsColorKey(item.goodsId, item.colorId): item,
    };
  }
}

final warehousePlaceSuggestionRepositoryProvider =
    Provider<WarehousePlaceSuggestionRepository>(
      (ref) => WarehousePlaceSuggestionRepository(ref.watch(apiClientProvider)),
    );
