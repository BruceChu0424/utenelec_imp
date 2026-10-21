import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/widgets/material_borrow_dialog.dart';

void main() {
  for (final quantity in ['0.0001', '1.2345', '99999999999999.9999']) {
    testWidgets('same-analysis borrowing retains typed $quantity', (
      tester,
    ) async {
      const maximum = '99999999999999.9999';
      MaterialBorrowRequestDraft? returned;
      final from = ProductionMaterialAnalysisMaterial(
        materialLineId: 'from',
        analysisLineId: 'p1',
        goodsId: 'g',
        actionable: true,
        allocatedAvailableQty: double.parse(maximum),
        quantityFactsExact: const {'allocatedAvailableQty': maximum},
      );
      final to = ProductionMaterialAnalysisMaterial(
        materialLineId: 'to',
        analysisLineId: 'p2',
        goodsId: 'g',
        actionable: true,
        shortageQty: double.parse(maximum),
        quantityFactsExact: const {'shortageQty': maximum},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    returned = await showDialog<MaterialBorrowRequestDraft>(
                      context: context,
                      builder: (_) => MaterialBorrowDialog(
                        from: from,
                        candidates: [to],
                        productsById: const {},
                        pathLabelOf: (_) => 'source',
                        qtyText: (value) => value.toString(),
                      ),
                    ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('material-borrow-target-to')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('material-borrow-qty')))
            .controller!
            .text,
        maximum,
      );
      await tester.enterText(
        find.byKey(const Key('material-borrow-qty')),
        quantity,
      );
      await tester.enterText(
        find.byKey(const Key('material-borrow-reason')),
        '先保紧急需求',
      );
      await tester.tap(find.byKey(const Key('material-borrow-confirm')));
      await tester.pumpAndSettle();
      expect(returned?.qtyExact, quantity);
      expect(tester.takeException(), isNull);
    });
  }
}
