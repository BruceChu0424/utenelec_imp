part of 'production_daily_report_exact_segment_test.dart';

void registerDailyReportWeightEntryTests() {
  const source = <String, dynamic>{
    'unitRate': 2,
    'unitRateExact': '2',
    'goodsUnitWeightKgExact': '0.005',
    'plannedQty': 1500,
    'remainingPlanQty': 1500,
    'maxReportQty': 1500,
  };

  testWidgets(
    'daily report confirms measured weight using the goods base unit',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(sourceOverrides: source, onCreate: submissions.add),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      final quantity = _reportTextField(row.qty);
      final measuredWeight = _reportTextField(row.weight);
      final convert = find.byKey(
        ValueKey('daily-report-convert-weight-${row.localRowId}'),
      );
      expect(tester.widget<IconButton>(convert).tooltip, '按实称总重量换算完工申报量');
      await tester.enterText(quantity, '100');
      await tester.pumpAndSettle();
      expect(row.goodsUnitWeightKg.value, '0.005');
      expect(find.text('0.005 kg'), findsOneWidget);
      expect(
        tester.widget<TextField>(measuredWeight).decoration?.hintText,
        '参考 1',
      );
      expect(row.weight.text, isEmpty);

      await tester.enterText(measuredWeight, '12.5');
      await tester.pumpAndSettle();
      expect(row.qty.text, '100');
      await tester.tap(convert);
      await tester.pumpAndSettle();
      expect(find.text('确认称重换算'), findsOneWidget);
      expect(find.textContaining('0.01 kg'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(row.qty.text, '100');
      expect(row.weight.text, '12.5');
      expect(submissions, isEmpty);

      await tester.tap(convert);
      await tester.pumpAndSettle();
      await tester.tap(find.text('采用换算数量'));
      await tester.pumpAndSettle();
      expect(row.qty.text, '1250');
      expect(row.weight.text, '12.5');
      expect(submissions, isEmpty);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 1250);
      expect(item['weight'], 12.5);
      expect(item['unitWeightKgExact'], 0.005);
      expect(item['weightEntryMode'], 'WEIGHT');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily report quantity input does not save the reference weight',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(sourceOverrides: source, onCreate: submissions.add),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      await tester.enterText(_reportTextField(row.qty), '123');
      await tester.pumpAndSettle();
      final measuredWeight = tester.widget<TextField>(
        _reportTextField(row.weight),
      );
      expect(measuredWeight.decoration?.hintText, '参考 1.23');
      expect(row.weight.text, isEmpty);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 123);
      expect(item.containsKey('weight'), isFalse);
      expect(item['unitWeightKgExact'], 0.005);
      expect(item['weightEntryMode'], 'QUANTITY');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily report quantity input preserves independently measured weight',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(sourceOverrides: source, onCreate: submissions.add),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      await tester.enterText(_reportTextField(row.qty), '123');
      await tester.enterText(_reportTextField(row.weight), '1.3');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 123);
      expect(item['weight'], 1.3);
      expect(item['unitWeightKgExact'], 0.005);
      expect(item['weightEntryMode'], 'QUANTITY');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily report cannot convert without a registered goods unit weight',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(onCreate: submissions.add),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      await tester.enterText(_reportTextField(row.weight), '12.5');
      await tester.pumpAndSettle();
      final convert = tester.widget<IconButton>(
        find.byKey(ValueKey('daily-report-convert-weight-${row.localRowId}')),
      );
      expect(convert.tooltip, '请先在货品资料维护单重');
      expect(convert.onPressed, isNull);
      expect(row.goodsUnitWeightKg.value, isNull);
      expect(row.qty.text, '10');
      expect(submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _reportTextField(TextEditingController controller) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is TextField && identical(widget.controller, controller),
    );
