part of 'material_analysis_one_table_test.dart';

MasterDataTableView<dynamic> _presentationTable(WidgetTester tester) =>
    tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const Key('material-analysis-material-table')),
    );

// The production row type is private to its page library. Read the callbacks
// without narrowing their argument to dynamic, then pass only that table's own
// row objects; a typed MasterDataTableView<dynamic>.idOf getter would cast the
// contravariant callback and fail before exercising the real presentation.
String? _presentationRowId(MasterDataTableView<dynamic> table, Object row) {
  // ignore: avoid_dynamic_calls
  final callback = (table as dynamic).idOf as Function?;
  return callback == null ? null : Function.apply(callback, [row]) as String?;
}

String? _presentationRowKey(MasterDataTableView<dynamic> table, Object row) {
  // ignore: avoid_dynamic_calls
  final callback = (table as dynamic).rowKeyOf as Function?;
  return callback == null ? null : Function.apply(callback, [row]) as String?;
}

bool? _presentationRowState(MasterDataTableView<dynamic> table, Object row) {
  // ignore: avoid_dynamic_calls
  final callback = (table as dynamic).selectionStateOf as Function?;
  return callback == null ? null : Function.apply(callback, [row]) as bool?;
}

Map<String, dynamic> _fiveHundredProductPresentation(
  Map<String, dynamic> data,
) {
  final product = Map<String, dynamic>.from(
    (data['products'] as List).first as Map,
  );
  final root = Map<String, dynamic>.from(_fixtureMaterial(data, 'm-root'));
  final child = Map<String, dynamic>.from(_fixtureMaterial(data, 'm-2'));
  data['products'] = [
    for (var i = 0; i < 500; i++)
      {
        ...product,
        'analysisLineId': 'perf-$i',
        'goodsId': 'perf-product-$i',
        'goodsName': '性能产品$i',
        'rootMaterialLineId': 'perf-root-$i',
      },
  ];
  data['flatMaterials'] = [
    for (var i = 0; i < 500; i++) ...[
      {
        ...root,
        'analysisLineId': 'perf-$i',
        'materialLineId': 'perf-root-$i',
        'actionGroupKey': 'perf-root-$i',
        'nodeKey': 'perf-root-node-$i',
        'goodsId': 'perf-product-$i',
        'goodsName': '性能产品$i',
      },
      for (var j = 0; j < 3; j++)
        {
          ...child,
          'analysisLineId': 'perf-$i',
          'materialLineId': 'perf-$i-$j',
          'actionGroupKey': 'perf-$i-$j',
          'nodeKey': 'perf-node-$i-$j',
          'parentNodeKey': 'perf-root-node-$i',
          'goodsId': 'perf-material-$i-$j',
          'goodsName': '性能物料$i-$j',
        },
    ],
  ];
  return data;
}

void materialAnalysisPresentationWorkCases() {
  testWidgets(
    'presentation work: visual switches preserve bucket summary work',
    (tester) async {
      await _pump(tester);
      List<(String, int, int)> summaries() => tester
          .widgetList<MaterialPreparationRouteCard>(
            find.byType(MaterialPreparationRouteCard),
          )
          .map(
            (card) => (card.routeId, card.inProgressCount, card.pendingCount),
          )
          .toList();
      final expected = summaries();
      final before = debugMaterialBucketSummaryEvaluations;
      for (var i = 0; i < 2; i++) {
        await _showMaterialSummary(tester);
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-product')),
        );
        await tester.pumpAndSettle();
        expect(summaries(), expected);
      }
      tester
          .widget<UtenButton>(
            find.byKey(const Key('material-analysis-bom-expansion-toggle')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(summaries(), expected);
      tester
          .widget<UtenButton>(
            find.byKey(const Key('material-analysis-bom-expansion-toggle')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(summaries(), expected);
      expect(
        debugMaterialBucketSummaryEvaluations - before,
        0,
        reason:
            'layout-only switches do not change any preparation bucket fact',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'presentation work: live permissions and quantity edits invalidate eligibility',
    (tester) async {
      final permissions = {..._permissions};
      await _pump(tester, permissions: permissions);
      final current = _presentationTable(tester);
      final Object row =
          current.items.singleWhere(
                (row) =>
                    _presentationRowKey(current, row as Object) ==
                    'MATERIAL|m-2',
              )
              as Object;
      expect(_presentationRowId(current, row), isNotNull);
      // Even an already captured callback must observe a permission change;
      // no widget rebuild or a new permission Set is needed to retire its memo.
      permissions.remove(Perm.productionMaterialAnalysisNotify);
      expect(_presentationRowId(current, row), isNull);
      expect(_presentationRowState(current, row), isFalse);
      permissions.add(Perm.productionMaterialAnalysisNotify);
      expect(_presentationRowId(current, row), isNotNull);
      final beforeEdit = debugMaterialTableEligibilityEvaluations;
      final bucketBeforeEdit = debugMaterialBucketSummaryEvaluations;
      await tester.enterText(_orderQty('m-2'), '900');
      expect(_presentationRowId(current, row), isNotNull);
      expect(debugMaterialTableEligibilityEvaluations, greaterThan(beforeEdit));
      await _settleRebuild(tester);
      expect(
        debugMaterialBucketSummaryEvaluations,
        greaterThan(bucketBeforeEdit),
      );
      expect(_nodeSelected(tester, 'm-2'), isTrue);
      expect(_qtyText(tester, _orderQty('m-2')), '900');
      expect(
        _submits(),
        isEmpty,
        reason: 'presentation queries never perform writes',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final fontFactor in [1.0, 1.6]) {
    testWidgets(
      'presentation work: 500 products bound identity shaping per frame scale=$fontFactor',
      (tester) async {
        var observing = true;
        var previous = debugMaterialIdentityTextMeasures;
        final before = previous;
        final measuresPerFrame = <int>[];
        tester.binding.addPostFrameCallback((_) {});
        tester.binding.addPersistentFrameCallback((_) {
          if (!observing) return;
          measuresPerFrame.add(debugMaterialIdentityTextMeasures - previous);
          previous = debugMaterialIdentityTextMeasures;
        });
        addTearDown(() => observing = false);
        await _pump(
          tester,
          size: const Size(1800, 945),
          fontFactor: fontFactor,
          mutate: _fiveHundredProductPresentation,
        );
        expect(_presentationTable(tester).items, hasLength(2000));
        expect(
          measuresPerFrame.reduce((a, b) => a > b ? a : b),
          lessThanOrEqualTo(256),
          reason:
              'rich tree identity must share the bounded table width budget',
        );
        expect(
          debugMaterialIdentityTextMeasures - before,
          2000,
          reason:
              'every distinct loaded identity is eventually measured, including the final product',
        );
        await _showMaterialSummary(tester);
        expect(_presentationTable(tester).items, hasLength(2000));
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-product')),
        );
        await tester.pumpAndSettle();
        expect(_presentationTable(tester).items, hasLength(2000));
        expect(
          measuresPerFrame.reduce((a, b) => a > b ? a : b),
          lessThanOrEqualTo(256),
          reason: 'switching both complete 2000-row projections also yields',
        );
        expect(
          find.byKey(const ValueKey('material-table-row-perf-499-2')),
          findsNothing,
          reason:
              'offscreen material cells remain lazy, while the full row set is retained',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'presentation work: layout reuses eligibility and selection facts',
    (tester) async {
      await _pump(tester);
      void inspect(MasterDataTableView<dynamic> current) {
        for (final row in current.items.cast<Object>()) {
          _presentationRowId(current, row);
          _presentationRowState(current, row);
        }
      }

      final current = _presentationTable(tester);
      inspect(current);
      final before = debugMaterialTableEligibilityEvaluations;
      for (var frame = 0; frame < 8; frame++) {
        inspect(current);
      }
      expect(
        debugMaterialTableEligibilityEvaluations - before,
        0,
        reason:
            'width batches/layout must not rescan unchanged business eligibility',
      );
      await _check(tester, _rowCheckbox('m-2'));
      await tester.pumpAndSettle();
      expect(_nodeSelected(tester, 'm-2'), isTrue);
      final selected = _presentationTable(tester);
      final Object row =
          selected.items.singleWhere(
                (row) =>
                    _presentationRowKey(selected, row as Object) ==
                    'MATERIAL|m-2',
              )
              as Object;
      expect(_presentationRowState(selected, row), isTrue);
      expect(_presentationRowId(selected, row), isNotNull);
      expect(
        find.byKey(const Key('material-analysis-submit-orders')),
        findsOneWidget,
      );
      await _showMaterialSummary(tester);
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-product')),
      );
      await tester.pumpAndSettle();
      expect(_nodeSelected(tester, 'm-2'), isTrue);
      inspect(_presentationTable(tester));
      final afterToggle = debugMaterialTableEligibilityEvaluations;
      inspect(_presentationTable(tester));
      expect(debugMaterialTableEligibilityEvaluations, afterToggle);
      expect(tester.takeException(), isNull);
    },
  );
}
