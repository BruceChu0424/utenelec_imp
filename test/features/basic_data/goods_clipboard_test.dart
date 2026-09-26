// 货品剪贴板（2026-09-25 全量复制口径）：复制货品 = 货品字段 + 全部组件行成对快照；
// 货品槽与组件槽互不影响。纯内存态单测（Riverpod Notifier 直调）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/goods_clipboard.dart';

GoodsDetail _detail(String id, String name) => GoodsDetail(
  id: id,
  name: name,
  status: '使用',
);

const _bom = [
  GoodsBomItem(id: 'row-1', componentGoodsId: 'goods-x', qty: 2),
  GoodsBomItem(id: 'row-2', componentGoodsId: 'goods-y', qty: 1),
];

void main() {
  test('复制货品携带组件行（全量复制）', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(goodsClipboardProvider).hasGoods, isFalse);

    container
        .read(goodsClipboardProvider.notifier)
        .copyGoods(GoodsCopyClip(detail: _detail('g1', '面板'), bomItems: _bom));

    final state = container.read(goodsClipboardProvider);
    expect(state.hasGoods, isTrue);
    expect(state.goodsList, hasLength(1));
    expect(state.goodsList.single.detail.name, '面板');
    expect(state.goodsList.single.bomItems, hasLength(2));
    expect(state.goodsList.single.bomItems.first.id, 'row-1');
  });

  test('批量复制整批替换；无组件的货品组件槽为空', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(goodsClipboardProvider.notifier).copyGoodsList([
      GoodsCopyClip(detail: _detail('g1', '面板'), bomItems: _bom),
      GoodsCopyClip(detail: _detail('g2', '支架')),
    ]);
    expect(container.read(goodsClipboardProvider).goodsList, hasLength(2));
    expect(
      container.read(goodsClipboardProvider).goodsList.last.bomItems,
      isEmpty,
    );

    container.read(goodsClipboardProvider.notifier).copyGoods(
      GoodsCopyClip(detail: _detail('g3', '螺丝')),
    );
    expect(container.read(goodsClipboardProvider).goodsList, hasLength(1));
  });

  test('货品槽与组件槽互不影响', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(goodsClipboardProvider.notifier).copyBom(_bom, '面板');
    container
        .read(goodsClipboardProvider.notifier)
        .copyGoods(GoodsCopyClip(detail: _detail('g1', '面板'), bomItems: _bom));

    final state = container.read(goodsClipboardProvider);
    expect(state.bomItems, hasLength(2));
    expect(state.bomSourceLabel, '面板');
    expect(state.goodsList.single.detail.id, 'g1');
  });
}
