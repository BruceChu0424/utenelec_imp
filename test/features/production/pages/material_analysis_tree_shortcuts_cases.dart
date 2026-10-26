part of 'material_analysis_one_table_test.dart';

Map<String, dynamic> _materialShortcutForest(Map<String, dynamic> data) {
  final product = Map<String, dynamic>.from(
    (data['products'] as List).first as Map,
  );
  data['products'] = [
    for (var i = 0; i < 3; i++)
      {
        ...product,
        'analysisLineId': 'shortcut-product-$i',
        'goodsId': 'shortcut-goods-$i',
        'goodsName': '快捷展开产品$i',
        'rootMaterialLineId': 'shortcut-root-$i',
      },
  ];
  data['flatMaterials'] = [
    for (var i = 0; i < 3; i++) ...[
      {
        ..._material(
          line: 'shortcut-root-$i',
          name: '快捷展开产品$i',
          confirmed: 'MAKE',
          netShortageQty: 600,
          nodeRole: 'ROOT_SUPPLY',
          level: 0,
        ),
        'analysisLineId': 'shortcut-product-$i',
      },
      for (var branch = 0; branch < 2; branch++) ...[
        {
          ..._material(
            line: 'shortcut-$i-$branch',
            name: '组件$i-$branch',
            confirmed: 'BUY',
            netShortageQty: 600,
            parentLine: 'shortcut-root-$i',
          ),
          'analysisLineId': 'shortcut-product-$i',
        },
        {
          ..._material(
            line: 'shortcut-$i-$branch-leaf',
            name: '底层$i-$branch',
            confirmed: 'BUY',
            netShortageQty: 600,
            level: 2,
            parentLine: 'shortcut-$i-$branch',
          ),
          'analysisLineId': 'shortcut-product-$i',
        },
      ],
    ],
  ];
  return data;
}

Future<void> _ctrlMaterialToggle(WidgetTester tester, String key) async {
  final toggle = find.byKey(ValueKey('material-table-toggle-$key'));
  await Scrollable.ensureVisible(tester.element(toggle), alignment: 0.5);
  // A pinned leading region can cover the position chosen by the default
  // ensureVisible alignment after visiting a deeply indented child.
  await Scrollable.of(
    tester.element(toggle),
    axis: Axis.horizontal,
  ).position.ensureVisible(tester.renderObject(toggle), alignment: 1);
  await tester.pumpAndSettle();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  try {
    await tester.tap(toggle);
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pumpAndSettle();
}

void materialTreeShortcutCases() {
  testWidgets(
    'read-only material trees mount text instead of disabled editors',
    (tester) async {
      await _pump(
        tester,
        permissions: const {Perm.productionMaterialAnalysisView},
        platform: TargetPlatform.windows,
        size: const Size(1800, 1400),
        mutate: _materialShortcutForest,
      );
      final table = find.byKey(const Key('material-analysis-material-table'));
      expect(_presentationTable(tester).expensiveRowMounts, isFalse);
      expect(
        find.descendant(of: table, matching: find.byType(EditableText)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'material tree toggles retain settled column width on every frame',
    (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.windows,
        size: const Size(1800, 1400),
        mutate: _materialShortcutForest,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-product')),
      );
      await tester.pumpAndSettle();
      final root = find.byKey(
        const ValueKey('material-table-tree-PRODUCT|shortcut-product-0'),
      );
      final settledWidth = tester.getSize(root).width;
      final requestCount = requests.length;
      for (var cycle = 0; cycle < 4; cycle++) {
        await tester.tap(
          find.byKey(const Key('material-analysis-bom-expansion-toggle')),
        );
        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.getSize(root).width,
            greaterThanOrEqualTo(settledWidth - 0.5),
            reason:
                'toggle $cycle frame $frame must not collapse measured width',
          );
        }
        await tester.pumpAndSettle();
      }
      expect(requests.length, requestCount);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Ctrl tree: product and nested peers toggle within their parent and preserve descendants',
    (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.windows,
        size: const Size(1800, 1400),
        mutate: _materialShortcutForest,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-product')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('material-analysis-bom-expansion-toggle')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-table-tree-MATERIAL|shortcut-0-0')),
        findsNothing,
      );
      final requestCount = requests.length;
      await _ctrlMaterialToggle(tester, 'PRODUCT|shortcut-product-0');
      for (var root = 0; root < 3; root++) {
        expect(
          find.byKey(ValueKey('material-table-tree-MATERIAL|shortcut-$root-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            ValueKey('material-table-tree-MATERIAL|shortcut-$root-0-leaf'),
          ),
          findsNothing,
        );
      }
      await tester.tap(
        find.byKey(
          const ValueKey('material-table-toggle-PRODUCT|shortcut-product-2'),
        ),
      );
      await tester.pumpAndSettle();
      await _ctrlMaterialToggle(tester, 'PRODUCT|shortcut-product-0');
      expect(
        find.byKey(const ValueKey('material-table-tree-MATERIAL|shortcut-2-0')),
        findsOneWidget,
        reason:
            'an open arrow in a mixed sibling group opens the remaining peers',
      );
      await _ctrlMaterialToggle(tester, 'MATERIAL|shortcut-0-0');
      for (var branch = 0; branch < 2; branch++) {
        expect(
          find.byKey(
            ValueKey('material-table-tree-MATERIAL|shortcut-0-$branch-leaf'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            ValueKey('material-table-tree-MATERIAL|shortcut-1-$branch-leaf'),
          ),
          findsNothing,
        );
      }
      expect(
        requests.length,
        requestCount,
        reason: 'tree expansion is presentation work and makes no API calls',
      );
      await _ctrlMaterialToggle(tester, 'MATERIAL|shortcut-0-1');
      for (var branch = 0; branch < 2; branch++) {
        expect(
          find.byKey(
            ValueKey('material-table-tree-MATERIAL|shortcut-0-$branch-leaf'),
          ),
          findsNothing,
          reason: 'Ctrl on any fully open peer closes only this sibling group',
        );
      }
      await _ctrlMaterialToggle(tester, 'MATERIAL|shortcut-0-0');
      final quantityController = tester
          .widget<TextField>(_orderQty('shortcut-0-0'))
          .controller;
      await _ctrlMaterialToggle(tester, 'PRODUCT|shortcut-product-1');
      for (var root = 0; root < 3; root++) {
        expect(
          find.byKey(ValueKey('material-table-tree-MATERIAL|shortcut-$root-0')),
          findsNothing,
        );
      }
      await _ctrlMaterialToggle(tester, 'PRODUCT|shortcut-product-2');
      for (var branch = 0; branch < 2; branch++) {
        expect(
          find.byKey(
            ValueKey('material-table-tree-MATERIAL|shortcut-0-$branch-leaf'),
          ),
          findsOneWidget,
          reason: 'closing the roots retains their descendant expansion state',
        );
        expect(
          find.byKey(
            ValueKey('material-table-tree-MATERIAL|shortcut-1-$branch-leaf'),
          ),
          findsNothing,
        );
      }
      expect(
        tester.widget<TextField>(_orderQty('shortcut-0-0')).controller,
        same(quantityController),
      );
      expect(requests.length, requestCount);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Ctrl tree: material summary toggles aggregate peers without database reads',
    (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.windows,
        size: const Size(1800, 1400),
        mutate: _materialShortcutForest,
      );
      await _showMaterialSummary(tester);
      final aggregates = _presentationTable(tester).items
          .cast<Object>()
          .map((row) => _presentationRowKey(_presentationTable(tester), row))
          .whereType<String>()
          .where((key) => key.startsWith('AGGREGATE|'))
          .toList();
      expect(aggregates.length, greaterThan(1));
      final otherAggregate = aggregates[1];
      final initialCount = _presentationTable(tester).items.length;
      final requestCount = requests.length;
      await _ctrlMaterialToggle(tester, aggregates.first);
      expect(
        _presentationTable(tester).items.length,
        greaterThan(initialCount),
      );
      final expandedCount = _presentationTable(tester).items.length;
      expect(
        expandedCount,
        initialCount + aggregates.length,
        reason:
            'each fixture aggregate exposes its one source, including virtualized offscreen peers',
      );
      await _ctrlMaterialToggle(tester, otherAggregate);
      expect(_presentationTable(tester).items, hasLength(initialCount));
      await _ctrlMaterialToggle(tester, aggregates.first);
      expect(_presentationTable(tester).items, hasLength(expandedCount));
      await tester.tap(
        find.byKey(ValueKey('material-table-toggle-${aggregates.first}')),
      );
      await tester.pumpAndSettle();
      expect(_presentationTable(tester).items.length, lessThan(expandedCount));
      await _ctrlMaterialToggle(tester, otherAggregate);
      expect(_presentationTable(tester).items, hasLength(expandedCount));
      expect(requests.length, requestCount);
      expect(tester.takeException(), isNull);
    },
  );
}
