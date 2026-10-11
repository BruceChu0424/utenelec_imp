// PurchaseGridRow.clone（明细复制/粘贴，2026-09-03）：
// 拷用户录入 + 货品主档透传 + 行供应商 + 行级商业条款 + 备注；不拷上游明细 id /
// 来源谱系 / 到货门控 / sourceLocked——粘贴行是自由新明细，不得双引用上游行。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test('clone 拷贝录入与主档透传，金额随构造器自动重算', () {
    final src = PurchaseGridRow(sourceLocked: true)
      ..goods = const GoodsOption(id: 'g1', code: 'C1', name: '货品1')
      ..colorId = 'c1'
      ..unitId = 'u1'
      ..unitRate = 2
      ..supplierId = 's1';
    src.qty.text = '5';
    src.weight.text = '3.5';
    src.price.text = '2.5';

    final c = src.clone();
    expect(c.goods?.id, 'g1');
    expect(c.qty.text, '5');
    expect(c.weight.text, '3.5');
    expect(c.price.text, '2.5');
    expect(c.colorId, 'c1');
    expect(c.unitId, 'u1');
    expect(c.unitRate, 2);
    expect(c.supplierId, 's1');
    expect(c.amountValue, 12.5);
    expect(c, isNot(same(src)));
  });

  test('clone 拷贝行级商业条款与备注（2026-09 行级条款改造）', () {
    final src = PurchaseGridRow()
      ..goods = const GoodsOption(id: 'g1', code: 'C1', name: '货品1')
      ..supplierId = 's1'
      ..settlementMethodId = 'settle-1'
      ..currencyId = 'cny';
    src.exchangeRate.text = '7.2';
    src.taxRate.text = '13';
    src.remark.text = '行备注';

    final c = src.clone();
    expect(c.supplierId, 's1');
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

  test('clone 不拷上游引用、来源谱系与数量门控', () {
    final src = PurchaseGridRow(sourceLocked: true)
      ..upstreamItemId = 'up-1'
      ..maxQty = 10
      ..sourceDocNo = 'PO-1'
      ..sourceRequestNo = 'REQ-1'
      ..sourceRequestId = 'req-id';
    src.qty.text = '3';

    final c = src.clone();
    expect(c.upstreamItemId, isNull);
    expect(c.maxQty, isNull);
    expect(c.sourceDocNo, isNull);
    expect(c.sourceRequestNo, isNull);
    expect(c.sourceRequestId, isNull);
    expect(c.sourceLocked, isFalse);
  });

  testWidgets('列序契约：单位列已撤（2026-10-10 T9 内联数量 suffix），数量后紧跟单价', (tester) async {
    late final List<String> keys;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            keys = purchaseGridColumns(
              (_) async {},
              context: context,
            ).map((column) => column.key).toList();
            return const SizedBox();
          },
        ),
      ),
    );
    expect(keys, isNot(contains('weight')));
    expect(keys, isNot(contains('unit')));
    expect(keys.indexOf('price'), keys.indexOf('qty') + 1);
  });

  testWidgets('订货列序契约：允许超收% 紧跟数量，商业条款撤汇率（2026-10-10）', (tester) async {
    late final List<String> keys;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            keys = purchaseGridColumns(
              (_) async {},
              context: context,
              showCommercial: true,
              showAllowedOverReceipt: true,
              showRemark: true,
            ).map((column) => column.key).toList();
            return const SizedBox();
          },
        ),
      ),
    );
    expect(keys, isNot(contains('unit')));
    expect(keys.indexOf('allowedOverReceiptPct'), keys.indexOf('qty') + 1);
    expect(keys.indexOf('price'), keys.indexOf('allowedOverReceiptPct') + 1);
    // 商业条款撤汇率（采购不填汇率，财务审批时填，前端提交恒 1）。
    expect(keys, isNot(contains('exchangeRate')));
    expect(keys.sublist(keys.indexOf('amount') + 1, keys.indexOf('remark')), [
      'currency',
      'taxRate',
      'settlement',
    ]);
  });
}
