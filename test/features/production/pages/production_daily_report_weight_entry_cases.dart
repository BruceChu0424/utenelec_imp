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
    'daily report measurement immediately fills exact quantity from weight and master unit',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(sourceOverrides: source, onCreate: submissions.add),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      final measuredWeight = _reportTextField(row.weight);
      final convert = find.byKey(
        ValueKey('daily-report-convert-weight-${row.localRowId}'),
      );
      expect(row.goodsUnitWeightKg.value, '0.005');
      await tester.enterText(measuredWeight, '12.5');
      await tester.pumpAndSettle();
      expect(row.qty.text, '1250');
      expect(row.weight.text, '12.5');
      expect(convert, findsNothing);
      expect(find.byType(BusinessPrecisionDialog), findsNothing);
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
    'daily report measurement from quantity and master unit does not submit reference weight',
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
      expect(row.weight.text, '1.23');
      expect(row.measuredWeightKg, isNull);
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
    'daily report measurement from quantity and manual unit is reference only',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(sourceOverrides: source, onCreate: submissions.add),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      final unit = _reportUnitWeight(row);
      expect(tester.widget<TextField>(unit).decoration?.hintText, '主档 0.005');
      await tester.enterText(_reportTextField(row.qty), '100');
      await tester.enterText(unit, '0.007');
      await tester.pumpAndSettle();
      expect(row.weight.text, '1.4');
      expect(row.measuredWeightKg, isNull);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 100);
      expect(item.containsKey('weight'), isFalse);
      expect(item['unitWeightKgExact'], 0.007);
      expect(item['unitWeightSource'], 'MANUAL');
      expect(item['weightEntryMode'], 'QUANTITY');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily report measurement reopens a manual-unit draft with reference-only total',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      final api = _api(sourceOverrides: source, onCreate: submissions.add);
      const surfaceSize = Size(2000, 1000);
      await _pumpNewReport(tester, api, surfaceSize: surfaceSize);
      final row = _productRows(tester).single;
      await tester.enterText(_reportTextField(row.qty), '100');
      await tester.enterText(_reportUnitWeight(row), '0.007');
      await tester.pumpAndSettle();
      expect(row.weight.text, '1.4');

      final originalEditor = _identityState(tester);
      final draft = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(originalEditor.captureFormDraft())) as Map,
      );
      final draftRow = (draft['rows'] as List).single as Map;
      expect(draftRow['unitWeightInput'], '0.007');
      expect(draftRow['weightInputOrder'], ['quantity', 'unitWeight']);
      expect(draftRow['calculatedMeasurement'], 'totalWeight');

      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpNewReport(tester, api, surfaceSize: surfaceSize);
      final reopenedEditor = _identityState(tester);
      expect(reopenedEditor, isNot(same(originalEditor)));
      await reopenedEditor.restoreFormDraft(draft);
      await tester.pumpAndSettle();
      final restored = _productRows(tester).single;
      expect(restored.localRowId, row.localRowId);
      expect(restored.qty.text, '100');
      expect(restored.unitWeightInput.text, '0.007');
      expect(restored.weight.text, '1.4');
      expect(restored.measuredWeightKg, isNull);
      expect(restored.weightInputOrder, [
        DailyReportMeasurement.quantity,
        DailyReportMeasurement.unitWeight,
      ]);

      await tester.enterText(_reportTextField(restored.qty), '150');
      await tester.pumpAndSettle();
      expect(restored.weight.text, '2.1');
      expect(restored.measuredWeightKg, isNull);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 150);
      expect(item.containsKey('weight'), isFalse);
      expect(item['unitWeightKgExact'], 0.007);
      expect(item['unitWeightSource'], 'MANUAL');
      expect(item['weightEntryMode'], 'QUANTITY');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily report measurement uses latest two explicit fields and submits derived unit',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(sourceOverrides: source, onCreate: submissions.add),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      final qty = _reportTextField(row.qty);
      final total = _reportTextField(row.weight);
      final unit = _reportUnitWeight(row);

      await tester.enterText(qty, '100');
      await tester.enterText(total, '1.3');
      await tester.pumpAndSettle();
      expect(row.qty.text, '100');
      expect(row.unitWeightInput.text, '0.0065');
      expect(row.measuredWeightKg, '1.3');

      await tester.enterText(unit, '0.01');
      await tester.pumpAndSettle();
      expect(row.qty.text, '65');
      expect(row.measuredWeightKg, '1.3');

      await tester.enterText(qty, '100');
      await tester.pumpAndSettle();
      expect(row.weight.text, '2');
      expect(row.measuredWeightKg, isNull);

      await tester.enterText(total, '1.3');
      await tester.pumpAndSettle();
      expect(row.unitWeightInput.text, '0.0065');
      expect(row.goodsUnitWeightKg.value, '0.005');
      expect(find.byType(BusinessPrecisionDialog), findsNothing);
      expect(submissions, isEmpty);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 100);
      expect(item['weight'], 1.3);
      expect(item['unitWeightKgExact'], 0.0065);
      expect(item['unitWeightSource'], 'DERIVED');
      expect(item['weightEntryMode'], 'UNIT');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily report measurement without a master unit can use an explicit local unit',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: {...source, 'goodsUnitWeightKgExact': null},
          onCreate: submissions.add,
        ),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      await tester.enterText(_reportTextField(row.weight), '12.5');
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('daily-report-convert-weight-${row.localRowId}')),
        findsNothing,
      );
      expect(row.goodsUnitWeightKg.value, isNull);
      expect(row.qty.text, isEmpty);
      expect(submissions, isEmpty);
      await tester.enterText(_reportUnitWeight(row), '0.005');
      await tester.pumpAndSettle();
      expect(row.qty.text, '1250');
      expect(row.measuredWeightKg, '12.5');
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 1250);
      expect(item['weight'], 12.5);
      expect(item['unitWeightKgExact'], 0.005);
      expect(item['unitWeightSource'], 'MANUAL');
      expect(item['weightEntryMode'], 'WEIGHT');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily report measurement repeating conversion retains input and prompts on save',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: {...source, 'goodsUnitWeightKgExact': '0.003'},
          onCreate: submissions.add,
        ),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      final convert = find.byKey(
        ValueKey('daily-report-convert-weight-${row.localRowId}'),
      );
      final save = find.byKey(const ValueKey('uten-edit-save'));
      final dialog = find.byType(BusinessPrecisionDialog);
      await tester.enterText(_reportTextField(row.weight), '1');
      await tester.pumpAndSettle();
      expect(row.qty.text, isEmpty);
      await tester.tap(convert);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(find.text('称重换算申报量'), findsOneWidget);
      await tester.tap(find.text('取消，保留原输入'));
      await tester.pumpAndSettle();
      expect(row.weight.text, '1');
      expect(row.qty.text, isEmpty);
      expect(submissions, isEmpty);

      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      await _adoptMeasurementPrecision(tester, '2');
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 166.66);
      expect(item['weight'], 1);
      expect(item['unitWeightKgExact'], 0.003);
      expect(item['weightEntryMode'], 'WEIGHT');
      expect(item['weightQuantityScale'], 2);
      expect(item['weightQuantityRounding'], 'DOWN');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily report measurement repeating unit conversion submits its own precision',
    (tester) async {
      final submissions = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(sourceOverrides: source, onCreate: submissions.add),
        surfaceSize: const Size(2000, 1000),
      );
      final row = _productRows(tester).single;
      await tester.enterText(_reportTextField(row.qty), '3');
      await tester.enterText(_reportTextField(row.weight), '1');
      await tester.pumpAndSettle();
      expect(row.unitWeightInput.text, isEmpty);
      expect(row.qty.text, '3');
      expect(row.weight.text, '1');
      await tester.tap(find.byTooltip('选择单重的换算精度'));
      await tester.pumpAndSettle();
      expect(find.text('称重换算单重'), findsOneWidget);
      await _adoptMeasurementPrecision(tester, '4');
      expect(row.unitWeightInput.text, '0.1666');
      expect(submissions, isEmpty);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(find.byType(BusinessPrecisionDialog), findsNothing);
      final item = (submissions.single['items'] as List).single as Map;
      expect(item['qty'], 3);
      expect(item['weight'], 1);
      expect(item['unitWeightKgExact'], 0.1666);
      expect(item['unitWeightSource'], 'DERIVED');
      expect(item['weightEntryMode'], 'UNIT');
      expect(item['weightUnitScale'], 4);
      expect(item['weightUnitRounding'], 'DOWN');
      expect(item.containsKey('weightQuantityScale'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _adoptMeasurementPrecision(
  WidgetTester tester,
  String scale,
) async {
  final dialog = find.byType(BusinessPrecisionDialog);
  await tester.enterText(
    find.descendant(of: dialog, matching: find.byType(TextField)),
    scale,
  );
  await tester.tap(find.text('处理方式'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('直接截取，不进位').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认本次精度'));
  await tester.pumpAndSettle();
}

Finder _reportUnitWeight(DailyGridRow row) =>
    find.byKey(ValueKey('daily-report-unit-weight-${row.localRowId}'));

Finder _reportTextField(TextEditingController controller) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is TextField && identical(widget.controller, controller),
    );
