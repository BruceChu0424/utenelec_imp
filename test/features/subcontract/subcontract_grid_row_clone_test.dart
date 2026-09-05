// SubcontractGridRow.clone（明细复制/粘贴，2026-09-03）：
// 语义同 PurchaseGridRow.clone——拷用户录入（含损耗单四列）与主档透传 + 行委外商；
// 不拷上游 id / planItemId / 来源谱系 / 到货门控 / sourceLocked。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test('clone 拷贝全部录入列（含损耗单四列）与行委外商', () {
    final src = SubcontractGridRow(sourceLocked: true)
      ..goods = const GoodsOption(id: 'g1', name: '货品1')
      ..colorId = 'c1'
      ..unitId = 'u1'
      ..unitRate = 1.5
      ..supplierId = 'sub-1'
      ..planItemId = 'plan-1';
    src.qty.text = '4';
    src.price.text = '3';
    src.weight.text = '2.5';
    src.girth.text = '6';
    src.boxQty.text = '2';
    src.endingQty.text = '10';
    src.standardQty.text = '9';
    src.wasteRate.text = '0.1';
    src.cause.text = '毛边';

    final c = src.clone();
    expect(c.goods?.id, 'g1');
    expect(c.qty.text, '4');
    expect(c.price.text, '3');
    expect(c.weight.text, '2.5');
    expect(c.girth.text, '6');
    expect(c.boxQty.text, '2');
    expect(c.endingQty.text, '10');
    expect(c.standardQty.text, '9');
    expect(c.wasteRate.text, '0.1');
    expect(c.cause.text, '毛边');
    expect(c.colorId, 'c1');
    expect(c.unitId, 'u1');
    expect(c.unitRate, 1.5);
    expect(c.supplierId, 'sub-1');
    expect(c.amountValue, 12); // 4 × 3 随构造器重算
  });

  test('clone 拷贝行级商业条款与备注（2026-09 行级条款改造）', () {
    final src = SubcontractGridRow()
      ..goods = const GoodsOption(id: 'g1', name: '货品1')
      ..supplierId = 'sub-1'
      ..settlementMethodId = 'settle-1'
      ..currencyId = 'cny';
    src.exchangeRate.text = '7.2';
    src.taxRate.text = '13';
    src.remark.text = '行备注';

    final c = src.clone();
    expect(c.supplierId, 'sub-1');
    expect(c.settlementMethodId, 'settle-1');
    expect(c.currencyId, 'cny');
    expect(c.exchangeRate.text, '7.2');
    expect(c.taxRate.text, '13');
    expect(c.remark.text, '行备注');
    // 拷贝的是独立控制器/通知器，改克隆不影响原行。
    c.exchangeRate.text = '1';
    c.currencyId = 'usd';
    expect(src.exchangeRate.text, '7.2');
    expect(src.currencyId, 'cny');
  });

  test('clone 不拷上游引用、计划行、谱系与门控', () {
    final src = SubcontractGridRow(sourceLocked: true)
      ..upstreamItemId = 'up-1'
      ..planItemId = 'plan-1'
      ..maxQty = 10
      ..sourceDocNo = 'SC-1';
    src.qty.text = '1';

    final c = src.clone();
    expect(c.upstreamItemId, isNull);
    expect(c.planItemId, isNull);
    expect(c.maxQty, isNull);
    expect(c.sourceDocNo, isNull);
    expect(c.sourceLocked, isFalse);
  });

  test('列序契约：数量之后紧跟单位，实际重量列已下线（2026-09-04）', () {
    final columns = subcontractGridColumns(
      (_) async {},
      SubcontractDocConfig.inquiry, // 任一配置都不再渲染 weight 列
    );
    final keys = columns.map((column) => column.key).toList();
    expect(keys, isNot(contains('weight')));
    expect(keys.indexOf('unit'), keys.indexOf('qty') + 1);
  });
}
