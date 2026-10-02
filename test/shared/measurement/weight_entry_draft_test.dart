import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_form_draft_codec.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_grid_column.dart';

void main() {
  test('建议草稿只保留事实空值，恢复后根据新库存重新预填', () {
    final original = WeightEntryController()..setSuggestedKg(20);
    final restored = WeightEntryController();
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    final draft = weightEntryDraft(original);
    expect(draft['kg'], isNull);
    expect(draft['userEdited'], isFalse);
    expect(draft.values, isNot(contains(20)));
    restoreWeightEntryDraft(restored, draft);
    restored.setSuggestedKg(18);
    expect(restored.text.text, '18');
    expect(restored.kg, isNull);
    expect(restored.canonicalKeyPart, '|0');
  });

  test('草稿人工清空、实称、错误输入均不能被建议覆盖', () {
    for (final text in ['', '19.5', 'bad weight']) {
      final original = WeightEntryController()..setSuggestedKg(20);
      final restored = WeightEntryController();
      addTearDown(original.dispose);
      addTearDown(restored.dispose);
      original.text.text = text;
      restoreWeightEntryDraft(restored, weightEntryDraft(original));
      restored.setSuggestedKg(30);
      expect(restored.text.text, text);
      expect(restored.isSuggested, isFalse);
      expect(restored.hasError, text == 'bad weight');
    }
  });

  test('旧空草稿允许新建议，旧实称仍按实称恢复', () {
    final blank = WeightEntryController();
    final measured = WeightEntryController();
    addTearDown(blank.dispose);
    addTearDown(measured.dispose);
    restoreWeightEntryDraft(blank, {'kg': null, 'qtyFromWeight': false});
    blank.setSuggestedKg(20);
    expect(blank.text.text, '20');
    restoreWeightEntryDraft(measured, {'kg': 17, 'qtyFromWeight': false});
    measured.setSuggestedKg(20);
    expect(measured.kg, 17);
  });
}
