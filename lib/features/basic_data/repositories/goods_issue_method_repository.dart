// 货品「发料方式 / 分摊方式 / 每袋净重 / 回收料」切换仓库 (ADR-131)。
//
// 独立成仓库而不是往 GoodsRepository 里加方法：切换是一条带预览的原子命令
// (先核对没清账的工单与受影响的 BOM，再在同一事务里改货品、转换 BOM 行形状)，
// 与货品普通保存不是一回事；也避免既有测试里的 GoodsRepository 伪实现全部失配。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/idempotency_key.dart';
import '../models/goods_issue_method.dart';

abstract interface class GoodsIssueMethodRepository {
  /// 切到 [target] (ORDER / PERIODIC) 会影响什么、能不能切。
  /// [costBasis] 为整批领料的分摊方式 (OWN / SHARED / EXPENSE)，按工单领料不传。
  Future<GoodsIssueMethodPreview> preview(
    String goodsId, {
    required String target,
    String? costBasis,
  });

  /// 原子批量切换 (任何一条不合格整批不写，抛 ApiException)。
  Future<void> apply(List<GoodsIssueMethodChange> items);
}

class DioGoodsIssueMethodRepository implements GoodsIssueMethodRepository {
  DioGoodsIssueMethodRepository(this.api);
  final ApiClient api;

  @override
  Future<GoodsIssueMethodPreview> preview(
    String goodsId, {
    required String target,
    String? costBasis,
  }) async {
    final json = await api.get(
      ApiEndpoints.goodsIssueMethodPreview(goodsId),
      query: {
        'target': target,
        if (target == 'PERIODIC' && costBasis != null) 'costBasis': costBasis,
      },
    );
    return GoodsIssueMethodPreview.fromJson(
      json,
      goodsId: goodsId,
      target: target,
    );
  }

  @override
  Future<void> apply(List<GoodsIssueMethodChange> items) async {
    // 同一批内容 (含各自的 expectedVersion) 重试得到同一个键：响应丢了再点一次
    // 服务端按幂等账本返回原结果，不会切两次。
    final key = businessIdempotencyKey(
      'goods-issue-method',
      [for (final item in items) item.canonical()].join(';'),
    );
    await api.put(
      ApiEndpoints.goodsIssueMethodBatch,
      body: {
        'items': [for (final item in items) item.toJson()],
        'idempotencyKey': key,
      },
    );
  }
}

final goodsIssueMethodRepositoryProvider = Provider<GoodsIssueMethodRepository>(
  (ref) => DioGoodsIssueMethodRepository(ref.watch(apiClientProvider)),
);
