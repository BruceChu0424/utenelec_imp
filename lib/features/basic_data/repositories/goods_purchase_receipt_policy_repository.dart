import '../../../shared/formatters/exact_decimal.dart';
// 货品主档「采购允许超收%」记忆 (ADR-144)：
// PUT /master/goods/{id}/purchase-receipt-policy {allowedOverReceiptPct, version}。
//
// 只改这一个记忆值，不走整张货品保存 (整张保存是全量覆盖语义，不带这一键)。
// 比例不是价格或成本，服务端只要 goods:edit 与货品写范围；页面按货品详情的
// 可编辑能力显示入口，不在这里做本地权限判断。
// 与 GoodsRepository 分开：那个宽接口有很多测试替身，不为一个字段扩它。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// 输入解析：空 = 清除记忆 (null)；填了须是 0 到 100 的数，最多24位有效小数。
/// 返回 `valid=false` 表示输入不合法 (不发请求)。
({String? value, bool valid}) parseGoodsPurchaseOverReceiptPct(String? raw) =>
    parseExactPercentage(raw);

abstract interface class GoodsPurchaseReceiptPolicyRepository {
  /// 保存采购允许超收记忆 [pct]（null 清除），乐观锁 [version] 必填。
  Future<void> update(
    String goodsId, {
    required String? pct,
    required int version,
  });
}

class DioGoodsPurchaseReceiptPolicyRepository
    implements GoodsPurchaseReceiptPolicyRepository {
  DioGoodsPurchaseReceiptPolicyRepository(this.api);

  final ApiClient api;

  @override
  Future<void> update(
    String goodsId, {
    required String? pct,
    required int version,
  }) async {
    final id = goodsId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(goodsId, 'goodsId', 'must not be blank');
    }
    if (!parseExactPercentage(pct).valid) {
      throw ArgumentError.value(
        pct,
        'pct',
        'must be an exact native percentage between 0 and 100',
      );
    }
    await api.put(
      '/master/goods/$id/purchase-receipt-policy',
      body: {'allowedOverReceiptPct': pct, 'version': version},
    );
  }
}

final goodsPurchaseReceiptPolicyRepositoryProvider =
    Provider<GoodsPurchaseReceiptPolicyRepository>(
      (ref) =>
          DioGoodsPurchaseReceiptPolicyRepository(ref.watch(apiClientProvider)),
    );
