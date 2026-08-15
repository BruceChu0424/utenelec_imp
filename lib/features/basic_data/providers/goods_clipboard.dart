// GoodsClipboard - 货品资料「复制/粘贴」的 App 内剪贴板（内存态，不落盘）。
//
// 两个独立槽位：
// - 货品槽：「复制货品」（单个）/「批量复制」（多个）把 GoodsDetail 快照列表存进来；
//   「粘贴货品」/「批量粘贴」在当前分类下以快照字段新建货品（编号留空由后端自动生成）。
// - 组件信息槽：「复制组件信息」把某货品的 BOM 行快照进来；「粘贴组件信息」
//   把快照逐行建到目标货品上（目标已有组件时由用户选「替换」或「同级追加」）。
//
// 剪贴板是内存态：页面切换/翻页不丢，App 重启即清空（与系统剪贴板语义不同，
// 避免敏感主档数据写进系统剪贴板被其他应用读到）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/goods_bom_item.dart';
import '../models/goods_node.dart';

/// 剪贴板状态：两个槽位互不影响（复制货品不会清掉已复制的组件信息）。
class GoodsClipboardState {
  const GoodsClipboardState({
    this.goodsList = const [],
    this.bomItems,
    this.bomSourceLabel,
  });

  /// 「复制货品 / 批量复制」快照列表（整份详情，含成本字段）；空表 = 无。
  final List<GoodsDetail> goodsList;

  /// 货品槽是否有内容（单个或批量复制后皆 true）。
  bool get hasGoods => goodsList.isNotEmpty;

  /// 「复制组件信息」快照（BOM 行列表）。
  final List<GoodsBomItem>? bomItems;

  /// 组件信息来源货品的展示名（粘贴确认弹窗里提示"从 X 复制"用）。
  final String? bomSourceLabel;

  GoodsClipboardState copyWith({
    List<GoodsDetail>? goodsList,
    List<GoodsBomItem>? bomItems,
    String? bomSourceLabel,
  }) {
    return GoodsClipboardState(
      goodsList: goodsList ?? this.goodsList,
      bomItems: bomItems ?? this.bomItems,
      bomSourceLabel: bomSourceLabel ?? this.bomSourceLabel,
    );
  }
}

class GoodsClipboardNotifier extends Notifier<GoodsClipboardState> {
  @override
  GoodsClipboardState build() => const GoodsClipboardState();

  /// 写入货品快照列表（批量复制用；单个复制走 [copyGoods] 传单元素列表）。
  void copyGoodsList(List<GoodsDetail> details) {
    state = state.copyWith(goodsList: List<GoodsDetail>.unmodifiable(details));
  }

  /// 写入单个货品快照（= 列表仅一项）。
  void copyGoods(GoodsDetail detail) => copyGoodsList([detail]);

  /// 写入组件信息快照（[sourceLabel] 为来源货品展示名，用于粘贴确认文案）。
  void copyBom(List<GoodsBomItem> items, String sourceLabel) {
    state = state.copyWith(
      bomItems: List<GoodsBomItem>.unmodifiable(items),
      bomSourceLabel: sourceLabel,
    );
  }
}

/// 货品资料剪贴板（内存态）。页面监听它决定「粘贴货品/批量粘贴/粘贴组件信息」可用性。
final goodsClipboardProvider =
    NotifierProvider<GoodsClipboardNotifier, GoodsClipboardState>(
      GoodsClipboardNotifier.new,
    );
