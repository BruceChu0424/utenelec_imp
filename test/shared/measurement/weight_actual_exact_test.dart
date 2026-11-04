import 'package:uten_imp/shared/measurement/weight_mass_units.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_form_draft_codec.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_totals.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_grid_column.dart';

void main() {
  test(
    'warehouse exact formula keeps full rate and quantity products with no binary reconstruction',
    () {
      const params = WeightParams(
        goodsId: 'mass',
        basis: WeightBasis.exact,
        massFactorKg: 0.001,
        massFactorKgExact: '0.001',
      );
      expect(
        warehouseExactLineKg(
          lineQty: '12345678901234567890.000000000000000000000001',
          lineMassUnit: WeightUnit.g,
        ),
        '12345678901234567.890000000000000000000000001',
      );
      expect(
        warehouseExactLineKg(
          lineQty: '0.000000000000000000000001',
          unitRate: '0.000000000000000000000001',
          params: params,
        ),
        '0.000000000000000000000000000000000000000000000000001',
      );
      expect(
        warehouseExactLineKg(lineQty: '1', unitRate: '0', params: params),
        isNull,
      );
    },
  );

  test(
    '40 integer and 24 fractional kg remain exact through draft and totals',
    () {
      const raw =
          '1234567890123456789012345678901234567890.123456789012345678901234';
      final first = WeightEntryController()..text.text = raw,
          second = WeightEntryController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      expect(first.kgText, raw);
      expect(first.hasError, isFalse);
      restoreWeightEntryDraft(second, weightEntryDraft(first));
      expect(second.kgText, raw);
      expect(second.enteredText, raw);
      expect(
        WeightTotalsSummary.of([raw, '0.000000000000000000000001']).totalKgText,
        '1234567890123456789012345678901234567890.123456789012345678901235',
      );
    },
  );
  test(
    'unit display choice never rewrites original kg; finite unit conversion ignores choice',
    () {
      final c = WeightEntryController(kgExact: '1');
      addTearDown(c.dispose);
      c.switchUnit(WeightUnit.lb);
      expect(c.needsDisplayPrecision, isTrue);
      expect(c.text.text, '1 kg');
      c.setDisplayPrecision(const BusinessPrecisionChoice(4, 'DOWN'));
      expect(c.text.text, '2.2046');
      expect(c.kgText, '1');
      final d = weightEntryDraft(c),
          restored = WeightEntryController(unit: WeightUnit.lb);
      addTearDown(restored.dispose);
      restoreWeightEntryDraft(restored, d);
      expect(restored.text.text, '2.2046');
      expect(restored.kgText, '1');
      restored.switchUnit(WeightUnit.g);
      expect(restored.text.text, '1000');
      expect(restored.kgText, '1');
    },
  );
  test(
    'tiny recorded weight never disappears; full lb product survives until server field choice',
    () {
      final c = WeightEntryController();
      addTearDown(c.dispose);
      c.text.text = '0.000000000000000000000001 kg';
      expect(c.kgText, '0.000000000000000000000001');
      c.text.text = '0.000000000000000000000001 lb';
      expect(c.kgText, '0.00000000000000000000000045359237');
      expect(c.hasError, isFalse);
      expect(
        WeightUnit.t.editText('0.000000000000000000000001'),
        '0.000000000000000000000000001',
      );
    },
  );
  test(
    'profile update keeps unrelated exact values and sample frozen body roundtrips',
    () {
      final profile = GoodsWeightProfile.fromJson({
        'version': 1,
        'defaultTareKgExact': '0.000000000000000000000001',
        'manualUnitWeightKgExact':
            '12345678901234567890.000000000000000000000001',
      });
      final body = WeightProfileUpdate.from(
        profile,
      ).copyWith(learningEnabled: false).toJson();
      expect(body['defaultTareKg'], '0.000000000000000000000001');
      expect(
        body['manualUnitWeightKg'],
        '12345678901234567890.000000000000000000000001',
      );
      const sample = WeightSampleRequest(
        qty: 1,
        qtyExact: '1.000000000000000000000001',
        weight: 1,
        weightExact: '1.000000000000000000000001',
        weightUnitCode: 'KG',
        idempotencyKey: 'weight-source',
      );
      expect(
        WeightSampleRequest.fromJson(
          Map<String, dynamic>.from(sample.toJson()),
        ).toJson(),
        sample.toJson(),
      );
    },
  );
}
