// FinanceGridRow.clone（明细复制/粘贴，2026-09-03，allocate/transfer 模式）：
// 拷用户录入与下拉/日期选择；金额文本回填即触发 _syncFromAmountField，
// amountNotifier（保存真相源）自动同步；settle 台账绑定不拷。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';

void main() {
  test('allocate：clone 拷风格/部门/数量/单价/金额/备注，金额真相源同步', () {
    final src = FinanceGridRow(mode: ItemMode.allocate)
      ..styleId = 'style-1'
      ..inAccountId = 'acc-1'
      ..occurDate = '2026-09-03';
    src.department.text = 'dept-1';
    src.qty.text = '2';
    src.price.text = '50';
    src.amount.text = '100';
    src.exchangeRate.text = '1';
    src.writeOff.text = '0';
    src.remark.text = '备注';

    final c = src.clone();
    expect(c.mode, ItemMode.allocate);
    expect(c.styleId, 'style-1');
    expect(c.inAccountId, 'acc-1');
    expect(c.occurDate, '2026-09-03');
    expect(c.department.text, 'dept-1');
    expect(c.qty.text, '2');
    expect(c.price.text, '50');
    expect(c.amount.text, '100');
    expect(c.exchangeRate.text, '1');
    expect(c.remark.text, '备注');
    expect(c.amountNotifier.value, 100); // amount.text 回填即同步
  });

  test('settle：clone 不拷台账绑定（核销明细由「引用应收应付」生成，不应被克隆）', () {
    final src = FinanceGridRow(mode: ItemMode.settle)
      ..appliedLedgerId = 'led-1'
      ..appliedBillNo = 'AR-1'
      ..currencyId = 'CNY';
    src.amount.text = '88';

    final c = src.clone();
    expect(c.mode, ItemMode.settle);
    expect(c.appliedLedgerId, isNull);
    expect(c.appliedBillNo, isNull);
    expect(c.currencyId, isNull);
    expect(c.amount.text, '88');
  });
}
