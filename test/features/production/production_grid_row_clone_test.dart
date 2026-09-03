// ProductionGridRow.clone（明细复制/粘贴，2026-09-03）：
// 拷产品编号/货品/颜色/单位/排产量/备注；不拷 salesOrderItemId（订单↔计划行 1:1
// 溯源，审核回写 planned_qty——带旧 id 会双计）及订单带出的展示字段——粘贴行
// 等同手工自建行；qtyNotifier（表尾合计源）随 qty 回填自动同步。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/widgets/production_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test('clone 拷贝自建可录入内容，排产量合计源同步', () {
    final src = ProductionGridRow()
      ..goods = const GoodsOption(id: 'g1', name: '货品1')
      ..colorId = 'c1'
      ..unitId = 'u1';
    src.productNo.text = 'P01';
    src.qty.text = '120';
    src.remark.text = '备注';

    final c = src.clone();
    expect(c.goods?.id, 'g1');
    expect(c.colorId, 'c1');
    expect(c.unitId, 'u1');
    expect(c.productNo.text, 'P01');
    expect(c.qty.text, '120');
    expect(c.remark.text, '备注');
    expect(c.amountValue, 120); // qtyNotifier 随 qty 回填同步
  });

  test('clone 不拷订单溯源与订单带出字段（粘贴行等同手工自建行）', () {
    final src = ProductionGridRow()
      ..salesOrderItemId = 'soi-1'
      ..clientName = '客户A'
      ..sellerId = 'emp-1'
      ..sellerName = '销售员'
      ..unitRate = 1.5
      ..orderDate = '2026-09-01'
      ..outboundDate = '2026-09-30';
    src.oqty.text = '100';
    src.salesOrderNo.text = 'SO-1';
    src.qty.text = '10';

    final c = src.clone();
    expect(c.salesOrderItemId, isNull);
    expect(c.clientName, isNull);
    expect(c.sellerId, isNull);
    expect(c.sellerName, isNull);
    expect(c.unitRate, isNull);
    expect(c.orderDate, isNull);
    expect(c.outboundDate, isNull);
    expect(c.oqty.text, isEmpty);
    expect(c.salesOrderNo.text, isEmpty);
  });
}
