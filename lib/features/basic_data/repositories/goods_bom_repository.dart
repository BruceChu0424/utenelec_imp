// 货品组装信息（BOM）仓库：组件清单 CRUD（组装树子级对组件 id 再调 list 懒加载）。
//
// 仿 DioGoodsRepository，端点走 ApiEndpoints.goodsBom 系列；
// 导出复用 UtenExportButton（endpoint=goodsBomExport），不走本仓库。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/goods_bom_item.dart';

abstract interface class GoodsBomRepository {
  /// 某货品的组件清单（含组件展示信息 + hasChildren）。
  Future<List<GoodsBomItem>> list(String goodsId);

  /// 添加组件（同成品下 componentGoodsId UUID 唯一；body 对应 BomItemSaveRequest）。
  Future<GoodsBomItem> create(String goodsId, Map<String, dynamic> body);

  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  );

  Future<void> delete(String goodsId, String itemId);

  /// 审计标记（goods:bom:audit，V256）：把组装行标记为「已核对无误」或取消。
  Future<GoodsBomItem> setAudited(String goodsId, String itemId, bool audited);
}

class DioGoodsBomRepository implements GoodsBomRepository {
  DioGoodsBomRepository(this.api);
  final ApiClient api;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    final list = await api.getList(ApiEndpoints.goodsBom(goodsId));
    return list.map(GoodsBomItem.fromJson).toList();
  }

  @override
  Future<GoodsBomItem> create(String goodsId, Map<String, dynamic> body) async {
    final json = await api.post(ApiEndpoints.goodsBom(goodsId), body: body);
    return GoodsBomItem.fromJson(json);
  }

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async {
    final json = await api.put(
      ApiEndpoints.goodsBomItem(goodsId, itemId),
      body: body,
    );
    return GoodsBomItem.fromJson(json);
  }

  @override
  Future<void> delete(String goodsId, String itemId) async {
    await api.delete(ApiEndpoints.goodsBomItem(goodsId, itemId));
  }

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async {
    final json = await api.put(
      ApiEndpoints.goodsBomItemAudit(goodsId, itemId),
      body: {'audited': audited},
    );
    return GoodsBomItem.fromJson(json);
  }
}

final goodsBomRepositoryProvider = Provider<GoodsBomRepository>(
  (ref) => DioGoodsBomRepository(ref.watch(apiClientProvider)),
);
