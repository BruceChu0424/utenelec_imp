import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/shared/pricing/line_pricing_amount_cell.dart';
import 'package:uten_imp/shared/pricing/line_pricing_controller.dart';

void main() {
  testWidgets(
    'total entry displays reference-price guidance without overflow',
    (tester) async {
      final qty = TextEditingController(text: '3');
      final price = TextEditingController();
      final pricing = LinePricingController(
        qty: qty,
        price: price,
        supportsTotalInput: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 190,
              child: LinePricingAmountCell(controller: pricing),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '10.00');
      await tester.pump();
      expect(find.text('算价'), findsOneWidget);
      expect(price.text, '3.3333333333');
      expect(find.byType(UtenFieldHintIcon), findsOneWidget);
      expect(
        tester.widget<UtenFieldHintIcon>(find.byType(UtenFieldHintIcon)).info,
        contains('不会用参考单价覆盖总金额'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      pricing.dispose();
      qty.dispose();
      price.dispose();
    },
  );

  testWidgets('menu selects target and keeps source-locked quantity disabled', (
    tester,
  ) async {
    final qty = TextEditingController(text: '4');
    final price = TextEditingController(text: '2');
    final pricing = LinePricingController(
      qty: qty,
      price: price,
      canCalculateQuantity: () => false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 220,
            child: LinePricingAmountCell(controller: pricing),
          ),
        ),
      ),
    );
    await tester.tap(find.text('算额'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动算数量'));
    await tester.pump();
    expect(pricing.mode, LinePricingMode.calculateAmount);
    expect(find.text('自动算数量'), findsOneWidget);
    await tester.tap(find.text('自动算单价'));
    await tester.pumpAndSettle();
    expect(pricing.mode, LinePricingMode.calculatePrice);
    await tester.enterText(find.byType(TextField), '20');
    await tester.pump();
    expect(qty.text, '4');
    expect(price.text, '5');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    pricing.dispose();
    qty.dispose();
    price.dispose();
  });
}
