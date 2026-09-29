// StockGridRow.clone(明细复制/粘贴，2026-09-03；2026-09-28 ADR-135 加重量)：
// 拷货品、录入量(数量/实称重量；盘点=账面/实盘/账面重量/实盘重量)与只读主档展示列；
// 盘点模式保留(盘盈亏随控制器重算)；上游/执行段来源引用不拷。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test('非盘点：clone 拷货品/数量/实称重量(含按称重改数量标记)与主档展示列', () {
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
    src.weight.setKg(2.5, qtyFromWeight: true);

    final c = src.clone();
    addTearDown(src.dispose);
    addTearDown(c.dispose);
    expect(c.isCheck, isFalse);
    expect(c.goods?.id, 'g1');
    expect(c.qty.text, '10');
    expect(c.weight.kg, 2.5);
    expect(c.weight.qtyFromWeight, isTrue);
    expect(c.weight.text.text, '2.5');
    expect(c.colorId, 'c1');
    expect(c.unitId, 'u1');
    expect(c.unitRate, 1.5);
    expect(c.goodsCode, 'G001');
    expect(c.goodsSeries, 'A 系列');
    expect(c.goodsStockPlace, '1-01');
    expect(c.colorName, '黑');
    expect(c.unitName, '个');
    // 基本数量 = 数量 × 换算率。
    expect(c.qtyBase, 15);
  });

  test('盘点：clone 保留 isCheck，账面/实盘/账面重量/实盘重量拷贝且盘盈亏重算', () {
    final src = StockGridRow(isCheck: true)..bookWeightEstimated = true;
    src.bookQty.text = '10';
    src.checkQty.text = '8';
    src.bookWeightKg.value = 5;
    src.countWeight.setKg(4.2);

    final c = src.clone();
    addTearDown(src.dispose);
    addTearDown(c.dispose);
    expect(c.isCheck, isTrue);
    expect(c.bookQty.text, '10');
    expect(c.checkQty.text, '8');
    expect(c.amountValue, -2); // 实盘 - 账面
    expect(c.bookWeightKg.value, 5);
    expect(c.bookWeightEstimated, isTrue);
    expect(c.countWeight.kg, 4.2);
    expect(c.countWeight.qtyFromWeight, isFalse);
    // 盘点生效的是实盘数量与实盘重量。
    expect(identical(c.activeQty, c.checkQty), isTrue);
    expect(identical(c.activeWeight, c.countWeight), isTrue);
    expect(c.qtyBase, 8);
  });

  test('clone 不拷上游与执行段引用', () {
    final src = StockGridRow()
      ..upstreamItemId = 'up-1'
      ..executionSegmentId = 'seg-1'
      ..executionSegmentSalesAllocationId = 'alloc-1';
    src.qty.text = '1';

    final c = src.clone();
    addTearDown(src.dispose);
    addTearDown(c.dispose);
    expect(c.upstreamItemId, isNull);
    expect(c.executionSegmentId, isNull);
    expect(c.executionSegmentSalesAllocationId, isNull);
  });
}
