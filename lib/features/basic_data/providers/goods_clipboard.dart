// GoodsClipboard - 货品资料「复制/粘贴」的 App 内剪贴板（内存态，不落盘）。
//
// 两个独立槽位：
// - 货品槽：「复制货品」（单个）/「批量复制」（多个）把整份快照存进来——货品字段 +
//   其全部组件行（全量复制，2026-09-25 口径）；「粘贴货品」/「批量粘贴」在当前分类下
//   以快照字段新建货品（编号留空由后端自动生成），随后把组件行原样粘到新货品上。
// - 组件信息槽：「复制组件信息」把某货品的 BOM 行快照进来；「粘贴组件信息」
//   把快照逐行建到目标货品上（目标已有组件时由用户选「替换」或「同级追加」）。
//
// 剪贴板是内存态：页面切换/翻页不丢，App 重启即清空（与系统剪贴板语义不同，
// 避免敏感主档数据写进系统剪贴板被其他应用读到）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/goods_bom_item.dart';
import '../models/goods_node.dart';

/// 一份货品快照：货品整份详情 + 其组件行（全量复制）。
///
/// 复制货品 = 连同组件一起复制：粘贴时先按 [detail] 新建货品，再把 [bomItems]
/// 逐行粘到新货品上（组件行引用的是既有货品，孙层结构随引用自动还原）。
/// [bomItems] 为空表示源货品没有组装信息。
class GoodsCopyClip {
  const GoodsCopyClip({required this.detail, this.bomItems = const []});

  final GoodsDetail detail;

  /// 源货品的直接组件行快照（粘贴时原样写入新货品）。
  final List<GoodsBomItem> bomItems;
}

/// 剪贴板状态：两个槽位互不影响（复制货品不会清掉已复制的组件信息）。
class GoodsClipboardState {
  const GoodsClipboardState({
    this.goodsList = const [],
    this.bomItems,
    this.bomSourceLabel,
  });

  /// 「复制货品 / 批量复制」快照列表（货品 + 组件成对）；空表 = 无。
  final List<GoodsCopyClip> goodsList;

  /// 货品槽是否有内容（单个或批量复制后皆 true）。
  bool get hasGoods => goodsList.isNotEmpty;

  /// 「复制组件信息」快照（BOM 行列表）。
  final List<GoodsBomItem>? bomItems;

  /// 组件信息来源货品的展示名（粘贴确认弹窗里提示"从 X 复制"用）。
  final String? bomSourceLabel;

  GoodsClipboardState copyWith({
    List<GoodsCopyClip>? goodsList,
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
  void copyGoodsList(List<GoodsCopyClip> clips) {
    state = state.copyWith(goodsList: List<GoodsCopyClip>.unmodifiable(clips));
  }

  /// 写入单个货品快照（= 列表仅一项）。
  void copyGoods(GoodsCopyClip clip) => copyGoodsList([clip]);

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
