// 单货品库存面板仓储: 出入库流水 (含重量调整) + 单货品 KPI 条。
//
// 余额分页/授权调整仍走库存查询仓储 (lib/features/stock), 单重学习走
// lib/shared/measurement 的 WeightRepository; 本仓储只管这两个只读端点。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import 'stock_ledger_models.dart';

class GoodsStockLedgerRepository {
  GoodsStockLedgerRepository(this.api);

  final ApiClient api;

  /// GET /stock/goods/{goodsId}/ledger (stock:view)。
  Future<StockLedgerPage> ledger(String goodsId, StockLedgerQuery query) async {
    final json = await api.get(
      ApiEndpoints.stockGoodsLedger(goodsId),
      query: query.toQueryParameters(),
    );
    return StockLedgerPage.fromJson(json);
  }

  /// GET /stock/insights/goods/{goodsId} (stock:view)。
  Future<GoodsStockInsight> goodsInsight(String goodsId) async {
    final json = await api.get(ApiEndpoints.stockInsightsGoods(goodsId));
    return GoodsStockInsight.fromJson(json);
  }
}

final goodsStockLedgerRepositoryProvider = Provider<GoodsStockLedgerRepository>(
  (ref) => GoodsStockLedgerRepository(ref.watch(apiClientProvider)),
);
