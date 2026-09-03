// StockGridRow.clone（明细复制/粘贴，2026-09-03）：
// 拷货品、录入量与只读主档展示列；盘点模式保留（盘盈亏随控制器重算）；
// 上游/执行段/退料来源引用与 maxQty 门控不拷。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test('非盘点：clone 拷货品/数量/重量与主档展示列', () {
    final src = StockGridRow()
      ..goods = const GoodsOption(id: 'g1', name: '货品1')
      ..colorId = 'c1'
      ..unitId = 'u1'
      ..unitRate = 1.5
      ..goodsCode = 'G001'
      ..goodsSeries = 'A 系列'
      ..goodsStockPlace = '1-01'
      ..colorName = '黑'
      ..unitName = '个';
    src.qty.text = '10';
    src.weight.text = '2.5';

    final c = src.clone();
    expect(c.isCheck, isFalse);
    expect(c.goods?.id, 'g1');
    expect(c.qty.text, '10');
    expect(c.weight.text, '2.5');
    expect(c.colorId, 'c1');
    expect(c.unitId, 'u1');
    expect(c.unitRate, 1.5);
    expect(c.goodsCode, 'G001');
    expect(c.goodsSeries, 'A 系列');
    expect(c.goodsStockPlace, '1-01');
    expect(c.colorName, '黑');
    expect(c.unitName, '个');
  });

  test('盘点：clone 保留 isCheck，账面/实盘拷贝且盘盈亏重算', () {
    final src = StockGridRow(isCheck: true);
    src.bookQty.text = '10';
    src.checkQty.text = '8';

    final c = src.clone();
    expect(c.isCheck, isTrue);
    expect(c.bookQty.text, '10');
    expect(c.checkQty.text, '8');
    expect(c.amountValue, -2); // 实盘 - 账面
  });

  test('clone 不拷上游/执行段/退料引用与门控', () {
    final src = StockGridRow(sourceLocked: true)
      ..upstreamItemId = 'up-1'
      ..executionSegmentId = 'seg-1'
      ..executionSegmentSalesAllocationId = 'alloc-1'
      ..sourceDrawId = 'draw-1'
      ..sourceDrawNo = 'WD-1'
      ..maxQty = 9;
    src.qty.text = '1';

    final c = src.clone();
    expect(c.upstreamItemId, isNull);
    expect(c.executionSegmentId, isNull);
    expect(c.executionSegmentSalesAllocationId, isNull);
    expect(c.sourceDrawId, isNull);
    expect(c.sourceDrawNo, isNull);
    expect(c.maxQty, isNull);
    expect(c.sourceLocked, isFalse);
  });
}
