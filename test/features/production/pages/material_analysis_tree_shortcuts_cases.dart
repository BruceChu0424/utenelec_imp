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
  await tester.ensureVisible(toggle);
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
    'Ctrl tree: product peers open one level and nested peers keep their parent scope',
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
      final before = debugMaterialProjectionSteps;
      await _ctrlMaterialToggle(tester, 'MATERIAL|shortcut-0-0');
      expect(
        debugMaterialProjectionSteps,
        before,
        reason: 'repeating Ctrl on open peers is a no-op',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Ctrl tree: material summary opens aggregate peers without database reads',
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
      final initialCount = _presentationTable(tester).items.length;
      final requestCount = requests.length;
      await _ctrlMaterialToggle(tester, aggregates.first);
      expect(
        _presentationTable(tester).items.length,
        greaterThan(initialCount),
      );
      for (final aggregate in aggregates) {
        final toggle = tester.widget<IconButton>(
          find.byKey(ValueKey('material-table-toggle-$aggregate')),
        );
        expect(toggle.tooltip, contains('收起下级'));
      }
      expect(requests.length, requestCount);
      expect(tester.takeException(), isNull);
    },
  );
}
