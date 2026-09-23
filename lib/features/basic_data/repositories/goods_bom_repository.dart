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

  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  );

  /// 批量删除组装行(可横跨 goodsId 组装树的多层，一次提交，上限 500 条)。
  ///
  /// 服务端是**整批原子**的：只要有一条 id 不存在、已被别人删掉、或它的父件不在
  /// 这个 goodsId 的组装树里，整批就失败且一条都不删(抛 ApiException，通常是 404)。
  /// 所以本方法要么正常返回、要么抛异常，不存在「删了一部分」的返回值。
  ///
  /// 返回值是服务端去重后实际删掉的条数：调用方提交重复 id 时它会小于提交条数，
  /// 报「成功几条」要按它来。
  Future<int> deleteMany(String goodsId, List<String> itemIds);

  /// 审计标记（goods:bom:audit，V256）：把组装行标记为「已核对无误」或取消。
  Future<GoodsBomItem> setAudited(String goodsId, String itemId, bool audited);

  /// 粘贴组件信息(ADR-111)：把 [items] 一次替换/追加到 1~50 个目标货品，整批原子。
  ///
  /// 任何一处不合格(重复、成环、组件停用、目标已被他人改过……)服务端一条都不写，
  /// 抛 ApiException(409)，fieldErrors 逐条写明第几行、为什么。
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  });
}

/// 粘贴方式：替换目标现有组件 / 在现有组件后追加。
enum BomPasteMode { replace, append }

/// 粘贴目标。[expectedItemIds] 是页面读到的目标现有组件行 id(乐观锁)；
/// 为 null 表示不比对(批量粘贴不逐个预读目标)。
class BomPasteTarget {
  const BomPasteTarget(this.goodsId, {this.expectedItemIds});

  final String goodsId;
  final List<String>? expectedItemIds;

  Map<String, dynamic> toJson() => {
    'goodsId': goodsId,
    'expectedItemIds': ?expectedItemIds,
  };
}

/// 粘贴结果：目标数、新增行数、替换掉的行数。
class BomPasteResult {
  const BomPasteResult({
    required this.targets,
    required this.added,
    required this.removed,
  });

  final int targets;
  final int added;
  final int removed;

  factory BomPasteResult.fromJson(Map<String, dynamic> json) => BomPasteResult(
    targets: (json['targets'] as num?)?.toInt() ?? 0,
    added: (json['added'] as num?)?.toInt() ?? 0,
    removed: (json['removed'] as num?)?.toInt() ?? 0,
  );
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
  Future<int> deleteMany(String goodsId, List<String> itemIds) async {
    final json = await api.post(
      ApiEndpoints.goodsBomBatchDelete(goodsId),
      body: {'itemIds': itemIds},
    );
    // 后端 int 字段在 JSON 里可能是 int 也可能是 num，直接 as int 会炸。
    final deleted = json['deleted'];
    return deleted is num ? deleted.toInt() : 0;
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

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async {
    final json = await api.post(
      _pastePath,
      body: {
        'mode': mode == BomPasteMode.replace ? 'REPLACE' : 'APPEND',
        'targets': [for (final t in targets) t.toJson()],
        'items': items,
      },
    );
    return BomPasteResult.fromJson(json);
  }

  static const _pastePath = '${ApiEndpoints.goods}/bom/paste';
}

final goodsBomRepositoryProvider = Provider<GoodsBomRepository>(
  (ref) => DioGoodsBomRepository(ref.watch(apiClientProvider)),
);
