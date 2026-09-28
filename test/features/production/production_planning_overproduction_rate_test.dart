import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/models/production_plan.dart';
import 'package:uten_imp/features/production/repositories/production_overproduction_rate_repository.dart';
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

  test('rate labels use the same percent formatting as the input', () {
    expect(productionRateText(null), '—');
    expect(productionRateText(double.nan), '—');
    for (final rate in const [0.0, 0.1, 0.125, 2.5, 0.291234]) {
      expect(
        productionRateText(rate),
        '${productionOverproductionPercentText(rate)}%',
      );
    }
  });

  test(
    'system prefilled rates: untouched submits null, anything else is explicit',
    () {
      final rates = SystemPrefilledRates();
      final a = TextEditingController(), b = TextEditingController();
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      rates.fill(a, 0.1, goodsId: 'g');
      expect(a.text, '10');
      expect(rates.isExplicit(a), isFalse);
      expect(rates.submitted(a), isNull);
      a.text = '12';
      expect(rates.submitted(a), 0.12);
      a.text = '10';
      expect(rates.submitted(a), isNull);

      // 复制行沿用预填记录；换货品后忘掉，之后与旧默认相同的输入也按人填的算。
      b.text = a.text;
      rates.copy(a, b);
      expect(rates.submitted(b), isNull);
      rates.forget(b);
      expect(rates.submitted(b), 0.1);

      // 新默认只刷没人改过、也没被跳过的格子。
      final typed = TextEditingController(), issued = TextEditingController();
      addTearDown(typed.dispose);
      addTearDown(issued.dispose);
      rates
        ..fill(typed, 0.1, goodsId: 'g')
        ..fill(issued, 0.1, goodsId: 'g');
      typed.text = '11';
      rates.reseed([a, typed, issued], {'g': 0.05}, skip: (c) => c == issued);
      expect([a.text, typed.text, issued.text], ['5', '11', '10']);
      expect(rates.submitted(a), isNull);
      // 改过的格子只换预填记录：改回旧默认 10 是人定的(服务端会填 5)，改成新默认 5
      // 才按默认送空值。
      typed.text = '10';
      expect(rates.submitted(typed), 0.1);
      typed.text = '5';
      expect(rates.submitted(typed), isNull);
      typed.text = '11';

      // 撤销：快照时是预填的回到当前预填值，人填过的照原文放回。
      a.text = '20';
      rates.restore(a, '10', explicit: false);
      expect(a.text, '5');
      expect(rates.isExplicit(a), isFalse);
      rates.restore(a, '10', explicit: true);
      expect(rates.submitted(a), 0.1);
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
      // 比例由服务端权威下发；缺失就是缺失，客户端不再自拟 10%。
      expect(
        ProductionPlanItem.fromJson({'id': 'p2'}).allowedOverproductionRate,
        isNull,
      );
      expect(
        ProductionPlanItem.fromJson({
          'id': 'p3',
          'allowedOverproductionRate': 0.1,
          'allowedOverproductionRateSource': 'DEFAULT',
        }).allowedOverproductionRateSource,
        'DEFAULT',
      );
    },
  );
}
