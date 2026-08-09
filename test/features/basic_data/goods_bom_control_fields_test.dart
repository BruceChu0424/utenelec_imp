import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';

void main() {
  test('legacy BOM responses keep the historical control defaults', () {
    final item = GoodsBomItem.fromJson({
      'id': 'row-1',
      'componentGoodsId': 'component-1',
    });

    expect(item.controlStage, BomControlStage.start);
    expect(item.consumptionBasis, BomConsumptionBasis.perUnit);
    expect(item.basisOutputQty, 1);
    expect(item.allowPartialPackage, isTrue);
    expect(item.hardGate, isTrue);
  });

  test('BOM responses parse packaging controls and friendly labels', () {
    final item = GoodsBomItem.fromJson({
      'id': 'row-2',
      'componentGoodsId': 'component-2',
      'controlStage': 'FINISH',
      'consumptionBasis': 'PER_PACKAGE',
      'basisOutputQty': 100,
      'allowPartialPackage': false,
      'hardGate': false,
    });

    expect(item.controlStage, BomControlStage.finish);
    expect(item.controlStage.label, '完工/包装前');
    expect(item.consumptionBasis, BomConsumptionBasis.perPackage);
    expect(item.consumptionBasis.label, '按包装');
    expect(item.basisOutputQty, 100);
    expect(item.allowPartialPackage, isFalse);
    expect(item.hardGate, isFalse);
  });

  test('shipping and reference stages are always warning-only in the model', () {
    final shipping = GoodsBomItem.fromJson({
      'id': 'row-ship',
      'componentGoodsId': 'component-ship',
      'controlStage': 'SHIP',
      'hardGate': true,
    });
    final reference = GoodsBomItem.fromJson({
      'id': 'row-reference',
      'componentGoodsId': 'component-reference',
      'controlStage': 'REFERENCE',
      'hardGate': true,
    });

    expect(BomControlStage.start.supportsHardGate, isTrue);
    expect(BomControlStage.assembly.supportsHardGate, isTrue);
    expect(BomControlStage.finish.supportsHardGate, isTrue);
    expect(BomControlStage.ship.supportsHardGate, isFalse);
    expect(BomControlStage.reference.supportsHardGate, isFalse);
    expect(shipping.hardGate, isFalse);
    expect(reference.hardGate, isFalse);
    expect(shipping.controlStage.label, '发货参考');
    expect(shipping.controlStage.description, contains('不预留包材、不阻止实际发货'));
    expect(shipping.controlStage.description, contains('FINISH'));
    expect(shipping.controlStage.description, contains('PER_PACKAGE'));
    expect(shipping.controlStage.description, contains('FIXED_BATCH'));
  });
}
