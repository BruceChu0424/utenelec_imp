import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_form_draft_codec.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_grid_column.dart';

void main() {
  test('产成品进仓的单重按本行包装单位计算，复制后两行数量各自独立', () {
    final row = StockGridRow()
      ..unitRateText = '12'
      ..unitName = '箱';
    addTearDown(row.dispose);
    row.qty.text = '10';
    row.weight.setUnitWeightInput(
      '24g',
      unit: WeightUnit.g,
      quantityText: row.qty.text,
    );
    expect(row.weight.kgText, '0.24');
    final copy = row.clone();
    addTearDown(copy.dispose);
    copy.qty.text = '11';
    expect(copy.weight.kgText, '0.264');
    expect(row.weight.kgText, '0.24');
    expect(row.qtyBase, 120);
  });

  test('个重保留原十进制，数量及赠品变化重算总重，改总重退休个重驱动', () {
    final weight = WeightEntryController();
    addTearDown(weight.dispose);
    weight.setUnitWeightInput(
      '2.1234567890123456789g',
      unit: WeightUnit.g,
      quantityText: '1000',
    );
    expect(weight.kgText, '2.1234567890123456789');
    weight.updateUnitWeightQuantity('1001');
    expect(weight.kgText, '2.1255802458013580245789');
    weight.text.text = '3kg';
    expect(weight.unitWeightInput, isNull);
    weight.updateUnitWeightQuantity('2000');
    expect(weight.kgText, '3');
  });

  test('个重错误或缺数量阻止提交，原输入与草稿恢复保留', () {
    for (final input in ['bad', '-2g', '0']) {
      final weight = WeightEntryController();
      final restored = WeightEntryController();
      addTearDown(weight.dispose);
      addTearDown(restored.dispose);
      weight.setUnitWeightInput(input, unit: WeightUnit.g, quantityText: '5');
      expect(weight.hasError, isTrue);
      restoreWeightEntryDraft(
        restored,
        weightEntryDraft(weight),
        unitWeightQuantityText: '5',
      );
      expect(restored.unitWeightInput, input);
      expect(restored.hasError, isTrue);
      expect(restored.kgText, isNull);
    }
    final missingQty = WeightEntryController();
    addTearDown(missingQty.dispose);
    missingQty.setUnitWeightInput('2g', unit: WeightUnit.g, quantityText: '');
    expect(missingQty.hasError, isTrue);
    missingQty.updateUnitWeightQuantity('5');
    expect(missingQty.hasError, isFalse);
    expect(missingQty.kgText, '0.01');
  });

  test('个重驱动草稿恢复后继续随数量更新，切换总重单位不漂移', () {
    final original = WeightEntryController();
    final restored = WeightEntryController();
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    original.setUnitWeightInput('2lb', unit: WeightUnit.g, quantityText: '10');
    restoreWeightEntryDraft(
      restored,
      weightEntryDraft(original),
      unitWeightQuantityText: '10',
    );
    expect(restored.kgText, '9.0718474');
    restored.switchUnit(WeightUnit.g);
    restored.updateUnitWeightQuantity('11');
    expect(restored.kgText, '9.97903214');
    expect(restored.unitWeightInput, '2lb');
  });
}
