// 仓库单据明细的重量字段契约 (ADR-135): StockDocItem 解析实称重量、按称重改数量、
// 盘点实盘重量/账面重量快照、领料已出库重量(含估算标记); 中断重放草稿逐字段保留。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_form_draft_codec.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_grid_column.dart';

void main() {
  test('stock document item parses optional weight facts (kg)', () {
    final item = StockDocItem.fromJson({
      'id': 'line-1',
      'qty': 8,
      'weight': 3.75,
      'qtyFromWeight': true,
    });
    final check = StockDocItem.fromJson({
      'id': 'line-2',
      'qty': 10,
      'countQty': 9,
      'countWeight': 4.5,
      'bookWeight': 5.0001,
    });
    final draw = StockDocItem.fromJson({
      'id': 'line-3',
      'qty': 20,
      'issuedQty': 12,
      'issuedWeightKg': 6.1234,
      'issuedWeightEstimated': true,
    });
    final legacyItem = StockDocItem.fromJson({'id': 'line-4', 'qty': 2});

    expect(item.qty, 8);
    expect(item.weight, 3.75);
    expect(item.qtyFromWeight, isTrue);
    expect(check.countWeight, 4.5);
    expect(check.bookWeight, 5.0001);
    expect(check.qtyFromWeight, isFalse);
    expect(draw.issuedWeightKg, 6.1234);
    expect(draw.issuedWeightEstimated, isTrue);
    // 没称/旧响应: 重量为 null (绝不当 0), 标记为 false。
    expect(legacyItem.weight, isNull);
    expect(legacyItem.countWeight, isNull);
    expect(legacyItem.bookWeight, isNull);
    expect(legacyItem.issuedWeightKg, isNull);
    expect(legacyItem.qtyFromWeight, isFalse);
    expect(legacyItem.issuedWeightEstimated, isFalse);
  });

  test('interrupted-request draft facts keep every weight field', () {
    final doc = StockDocDetail.fromJson({
      'id': 'doc-1',
      'docType': 'DRAW',
      'items': [
        {
          'id': 'line-1',
          'qty': 20,
          'weight': 7.5,
          'qtyFromWeight': true,
          'countWeight': 1.25,
          'bookWeight': 2.5,
          'issuedWeightKg': 3.75,
          'issuedWeightEstimated': true,
        },
      ],
    });
    final restored = StockDocDetail.fromJson(stockDocumentDraftFacts(doc));
    final item = restored.items.single;
    expect(item.weight, 7.5);
    expect(item.qtyFromWeight, isTrue);
    expect(item.countWeight, 1.25);
    expect(item.bookWeight, 2.5);
    expect(item.issuedWeightKg, 3.75);
    expect(item.issuedWeightEstimated, isTrue);
  });

  test('weight cell draft round-trips kg, from-weight flag and yellow qty', () {
    final weight = WeightEntryController();
    final qty = UtenAutofillTextController(autofilled: false);
    addTearDown(weight.dispose);
    addTearDown(qty.dispose);
    weight.setKg(12.3456);
    qty.setAutomaticText('5411');
    weight.markQtyDerived('5411', note: '按称重推算 5,373~5,449个');
    final draft = weightEntryDraft(weight, qty: qty);

    final restoredWeight = WeightEntryController();
    final restoredQty = UtenAutofillTextController(autofilled: false);
    addTearDown(restoredWeight.dispose);
    addTearDown(restoredQty.dispose);
    restoredQty.text = '5411';
    restoreWeightEntryDraft(restoredWeight, draft, qty: restoredQty);

    expect(restoredWeight.kg, 12.3456);
    expect(restoredWeight.qtyFromWeight, isTrue);
    expect(restoredWeight.qtyEstimateNote, '按称重推算 5,373~5,449个');
    expect(restoredQty.autofilled, isTrue);
    expect(restoredWeight.canonicalKeyPart, '12.3456|1');

    // 没称的格子: 恢复后仍是空, 不带标记。
    final empty = WeightEntryController();
    addTearDown(empty.dispose);
    restoreWeightEntryDraft(empty, weightEntryDraft(empty));
    expect(empty.kg, isNull);
    expect(empty.qtyFromWeight, isFalse);
    // 非 Map 的旧草稿值直接忽略。
    restoreWeightEntryDraft(empty, '2.5');
    expect(empty.kg, isNull);
  });
}
