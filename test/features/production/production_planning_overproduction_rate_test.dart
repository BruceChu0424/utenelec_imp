import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/models/production_plan.dart';
import 'package:uten_imp/features/production/widgets/production_overproduction_rate_field.dart';

void main() {
  test(
    'analysis carries server defaults and omitted issue allowance stays omitted',
    () {
      final view = ProductionMaterialAnalysisView.fromJson({
        'analysisId': 'analysis',
        'overproductionDefaults': {
          'parent': 0,
          'leaf': 0.1,
          'remembered': 0.275,
        },
      });
      expect(view.overproductionDefaults, {
        'parent': 0,
        'leaf': 0.1,
        'remembered': 0.275,
      });
      expect(
        const MaterialAnalysisIssueLine(qty: 1).toJson(),
        isNot(contains('allowedOverproductionRate')),
      );
      expect(
        const MaterialAnalysisIssueLine(
          qty: 1,
          allowedOverproductionRate: 0,
        ).toJson()['allowedOverproductionRate'],
        0,
      );
    },
  );
  test(
    'percentage precision matches API ratio without floating point tails',
    () {
      for (final entry in <String, double>{
        '0': 0,
        '10': 0.1,
        '29.1234': 0.291234,
        '250': 2.5,
        '0.0001': 0.000001,
        '99999.9999': 999.999999,
      }.entries) {
        expect(parseProductionOverproductionPercent(entry.key), entry.value);
        expect(productionOverproductionPercentText(entry.value), entry.key);
      }
      expect(parseProductionOverproductionPercent('.5'), 0.005);
      expect(parseProductionOverproductionPercent('10.'), 0.1);
      for (final invalid in [
        '',
        '-1',
        'NaN',
        'Infinity',
        '1e2',
        '10.12345',
        '100000',
      ]) {
        expect(parseProductionOverproductionPercent(invalid), isNull);
      }
    },
  );

  testWidgets(
    'invalid input stays visible with the shared inline error treatment',
    (tester) async {
      final controller = TextEditingController(text: '10');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 152,
              height: 48,
              child: ProductionOverproductionRateField(controller: controller),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '-2');
      await tester.pump();
      expect(controller.text, '-2');
      final decoration =
          tester.widget<TextField>(find.byType(TextField)).decoration!
              as UtenInputDecoration;
      expect(
        (decoration.base.error! as UtenFieldMessage).message,
        '请输入非负百分比，最多 4 位小数',
      );
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), '0');
      await tester.pump();
      expect(
        (tester.widget<TextField>(find.byType(TextField)).decoration!
                as UtenInputDecoration)
            .base
            .error,
        isNull,
      );
    },
  );

  test(
    'new-plan seeds use exact demand identities and never authorize old tasks',
    () {
      const source = MaterialAnalysisSourceInput(
        salesOrderItemId: 'sale-item-a',
        requestedQty: 100,
        initialAllowedOverproductionRate: 0.25,
      );
      const manual = MaterialAnalysisSourceInput(
        sourceType: 'STOCK',
        sourceRef: 'stock-2026-1',
        goodsId: 'same-product',
        colorId: 'white',
        unitId: 'piece',
        requestedQty: 20,
        initialAllowedOverproductionRate: 0,
      );
      const seed = ProductionMaterialAnalysisSeed(sources: [source, manual]);
      expect(
        seed.initialAllowedOverproductionRateFor(
          const ProductionMaterialAnalysisProduct(
            analysisLineId: 'analysis-a',
            salesOrderItemId: 'sale-item-a',
            goodsId: 'same-product',
          ),
        ),
        0.25,
      );
      expect(
        seed.initialAllowedOverproductionRateFor(
          const ProductionMaterialAnalysisProduct(
            analysisLineId: 'analysis-b',
            salesOrderItemId: 'sale-item-b',
            goodsId: 'same-product',
          ),
        ),
        isNull,
      );
      expect(
        seed.initialAllowedOverproductionRateFor(
          const ProductionMaterialAnalysisProduct(
            analysisLineId: 'analysis-c',
            sourceType: 'STOCK',
            sourceRef: 'stock-2026-1',
            goodsId: 'same-product',
            colorId: 'white',
            unitId: 'piece',
          ),
        ),
        0,
      );
      expect(source.toJson(), isNot(contains('allowedOverproductionRate')));
      expect(
        source.toJson(),
        isNot(contains('initialAllowedOverproductionRate')),
      );
      expect(
        ProductionPlanItem.fromJson({
          'id': 'p1',
          'allowedOverproductionRate': 0,
        }).allowedOverproductionRate,
        0,
      );
      expect(
        ProductionPlanItem.fromJson({'id': 'p2'}).allowedOverproductionRate,
        0.1,
      );
    },
  );
}
