import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/business_columns/business_columns_row.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

Future<void> _showCell(
  WidgetTester tester,
  SalesGridRow row,
  BusinessColumn column,
) async {
  final gridColumn = businessEditableColumns<SalesGridRow>([
    column,
  ], rowOf: (row) => row).single;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 130,
            height: 48,
            child: Builder(
              builder: (context) => gridColumn.cellBuilder(context, row),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'numeric column preserves invalid input and clears its own error after correction',
    (tester) async {
      const fee = BusinessColumn(
        id: 'packing',
        name: '包装费',
        type: 'AMOUNT',
        operation: 'ADD',
        value: '5',
      );
      final row = SalesGridRow()..addExtraColumn(fee);
      addTearDown(row.dispose);
      await _showCell(tester, row, fee);
      expect(tester.widget<TextField>(find.byType(TextField)).maxLength, 120);
      expect(find.byType(UtenFieldHintIcon), findsNothing);

      await tester.enterText(find.byType(TextField), '1e3');
      await tester.pumpAndSettle();
      expect(row.extraColumnController(fee).text, '1e3');
      expect(row.extraColumnsValid('100'), isFalse);
      expect(
        tester
            .widget<UtenFieldHintIcon>(find.byType(UtenFieldHintIcon))
            .errorMessage,
        contains('附加列'),
      );
      expect(tester.takeException(), isNull);

      await tester.enterText(find.byType(TextField), '12.5');
      await tester.pumpAndSettle();
      expect(row.extraColumnsValid('100'), isTrue);
      expect(financeExactTrimmed(row.applyExtraColumnAmount('100')), '112.5');
      expect(find.byType(UtenFieldHintIcon), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(row.extraColumnsValid('100'), isTrue);
      expect(financeExactTrimmed(row.applyExtraColumnAmount('100')), '100');
      expect(find.byType(UtenFieldHintIcon), findsNothing);
    },
  );

  testWidgets(
    'division by zero is flagged in its cell without replacing the operand',
    (tester) async {
      const divisor = BusinessColumn(
        id: 'divide',
        name: '分摊系数',
        type: 'NUMBER',
        operation: 'DIVIDE',
      );
      final row = SalesGridRow()..addExtraColumn(divisor);
      addTearDown(row.dispose);
      await _showCell(tester, row, divisor);

      await tester.enterText(find.byType(TextField), '-0.000');
      await tester.pumpAndSettle();
      expect(row.extraColumnController(divisor).text, '-0.000');
      expect(row.extraColumnsValid('100'), isFalse);
      expect(find.byType(UtenFieldHintIcon), findsOneWidget);

      await tester.enterText(find.byType(TextField), '4');
      await tester.pumpAndSettle();
      expect(row.extraColumnsValid('100'), isTrue);
      expect(financeExactTrimmed(row.applyExtraColumnAmount('100')), '25');
      expect(find.byType(UtenFieldHintIcon), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'text columns preserve leading zeros and overlong pasted text for correction',
    (tester) async {
      const reference = BusinessColumn(id: 'reference', name: '客户货号');
      final row = SalesGridRow()..addExtraColumn(reference);
      addTearDown(row.dispose);
      await _showCell(tester, row, reference);
      expect(tester.widget<TextField>(find.byType(TextField)).maxLength, 2000);

      await tester.enterText(find.byType(TextField), '000123');
      await tester.pumpAndSettle();
      expect(row.extraColumnsPayload().single['value'], '000123');
      expect(row.extraColumnsValid('100'), isTrue);
      expect(find.byType(UtenFieldHintIcon), findsNothing);

      final overlong = List.filled(2001, 'A').join();
      await tester.enterText(find.byType(TextField), overlong);
      await tester.pumpAndSettle();
      expect(row.extraColumnController(reference).text, overlong);
      expect(row.extraColumnsValid('100'), isFalse);
      expect(
        tester
            .widget<UtenFieldHintIcon>(find.byType(UtenFieldHintIcon))
            .errorMessage,
        contains('2000'),
      );

      await tester.enterText(find.byType(TextField), '000123');
      await tester.pumpAndSettle();
      expect(row.extraColumnsValid('100'), isTrue);
      expect(find.byType(UtenFieldHintIcon), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
