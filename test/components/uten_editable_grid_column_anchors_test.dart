import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Row extends EditableGridRow {
  _Row(this.name);
  final String name;
}

class _MemoryLayout extends PlatformTableLayoutNotifier {
  _MemoryLayout(this.seed) : super('anchors.items');
  final PlatformTableLayout seed;

  @override
  PlatformTableLayout build() => seed;
}

Finder _grip(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenColumnResizeHandle && widget.label == label,
);

List<String> _renderedOrder(WidgetTester tester, List<String> labels) =>
    List.of(labels)..sort(
      (a, b) => tester
          .getCenter(_grip(a))
          .dx
          .compareTo(tester.getCenter(_grip(b)).dx),
    );

Finder _headerCell(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox &&
            widget.width != null &&
            widget.child is DecoratedBox,
      ),
    )
    .first;

Future<void> _pumpAnchoredGrid(
  WidgetTester tester, {
  required UtenEditableGridController<_Row> controller,
  required bool destination,
  Map<String, String> anchors = const {'destination': 'qty'},
  List<String>? initialOrder,
  ProviderContainer? container,
}) async {
  Widget app = MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          UtenEditableGrid<_Row>(
            tableKey: 'anchors.items',
            controller: controller,
            showAddRow: false,
            showRowDelete: false,
            initialColumnOrder: initialOrder,
            defaultColumnOrderAnchors: anchors,
            columns: [
              EditableGridColumn<_Row>(
                key: 'goods',
                label: 'Goods',
                width: 160,
                filterValueOf: (row) => row.name,
                cellBuilder: (_, row) => Text('row-${row.name}'),
              ),
              EditableGridColumn<_Row>(
                key: 'qty',
                label: 'Quantity',
                width: 160,
                cellBuilder: (_, _) => const Text('4'),
              ),
              if (destination)
                EditableGridColumn<_Row>(
                  key: 'destination',
                  label: 'Destination',
                  width: 160,
                  cellBuilder: (_, _) => const Text('Warehouse'),
                ),
              EditableGridColumn<_Row>(
                key: 'remark',
                label: 'Remark',
                width: 160,
                cellBuilder: (_, _) => const Text('note'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  if (container != null) {
    app = UncontrolledProviderScope(container: container, child: app);
  }
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  void largeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  const labels = ['Goods', 'Quantity', 'Destination', 'Remark'];
  for (final anchored in [true, false]) {
    testWidgets(
      'new column ${anchored ? 'follows its anchor' : 'still appends without anchors'} without rebuilding the grid',
      (tester) async {
        largeViewport(tester);
        final rows = UtenEditableGridController<_Row>(
          initial: [_Row('keep'), _Row('other')],
        );
        addTearDown(rows.dispose);
        final anchors = anchored
            ? const {'destination': 'qty'}
            : const <String, String>{};
        Future<void> pump(bool destination) => _pumpAnchoredGrid(
          tester,
          controller: rows,
          destination: destination,
          anchors: anchors,
          initialOrder: const ['remark', 'qty', 'goods'],
        );
        await pump(false);
        final originalState = tester.state(find.byType(UtenEditableGrid<_Row>));
        // Keep a real view filter and a manually resized width through the
        // asynchronous arrival of the business column.
        await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('keep（1）'));
        await tester.pumpAndSettle();
        final before = tester.getSize(_headerCell('Quantity')).width;
        await tester.drag(_grip('Quantity'), const Offset(60, 0));
        await tester.pumpAndSettle();
        final resized = tester.getSize(_headerCell('Quantity')).width;
        expect(resized, greaterThan(before));

        await pump(true);
        expect(
          tester.state(find.byType(UtenEditableGrid<_Row>)),
          same(originalState),
        );
        expect(
          _renderedOrder(tester, labels),
          anchored
              ? ['Remark', 'Quantity', 'Destination', 'Goods']
              : ['Remark', 'Quantity', 'Goods', 'Destination'],
        );
        expect(tester.getSize(_headerCell('Quantity')).width, resized);
        expect(find.text('row-keep'), findsOneWidget);
        expect(find.text('row-other'), findsNothing);
        expect(rows.rows, hasLength(2));
        if (anchored) {
          await pump(false);
          expect(_renderedOrder(tester, ['Goods', 'Quantity', 'Remark']), [
            'Remark',
            'Quantity',
            'Goods',
          ]);
          expect(tester.getSize(_headerCell('Quantity')).width, resized);
          expect(find.text('row-keep'), findsOneWidget);
          expect(find.text('row-other'), findsNothing);
          await pump(true);
          expect(_renderedOrder(tester, labels), [
            'Remark',
            'Quantity',
            'Destination',
            'Goods',
          ]);
          expect(tester.getSize(_headerCell('Quantity')).width, resized);
          expect(find.text('row-other'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'initial saved order anchors only columns with no saved position',
    (tester) async {
      largeViewport(tester);
      final rows = UtenEditableGridController<_Row>(initial: [_Row('keep')]);
      addTearDown(rows.dispose);
      await _pumpAnchoredGrid(
        tester,
        controller: rows,
        destination: true,
        initialOrder: const ['remark', 'qty', 'goods'],
      );
      expect(_renderedOrder(tester, labels), [
        'Remark',
        'Quantity',
        'Destination',
        'Goods',
      ]);
      await _pumpAnchoredGrid(
        tester,
        controller: rows,
        destination: false,
        initialOrder: const ['destination', 'remark', 'qty', 'goods'],
      );
      await _pumpAnchoredGrid(
        tester,
        controller: rows,
        destination: true,
        initialOrder: const ['destination', 'remark', 'qty', 'goods'],
      );
      expect(_renderedOrder(tester, labels), [
        'Destination',
        'Remark',
        'Quantity',
        'Goods',
      ]);
      await _pumpAnchoredGrid(
        tester,
        controller: rows,
        destination: true,
        initialOrder: const ['destination', 'remark', 'qty', 'goods'],
      );
      expect(_renderedOrder(tester, labels), [
        'Destination',
        'Remark',
        'Quantity',
        'Goods',
      ]);
    },
  );

  for (final savedDestination in [false, true]) {
    testWidgets(
      'platform replay ${savedDestination ? 'preserves the saved destination position' : 'anchors an unseen destination'} and preserves width/filter',
      (tester) async {
        largeViewport(tester);
        final rows = UtenEditableGridController<_Row>(
          initial: [_Row('keep'), _Row('other')],
        );
        addTearDown(rows.dispose);
        final container = ProviderContainer(
          overrides: [
            authenticatedScopeProvider.overrideWithValue(null),
            apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
            platformTableLayoutProvider('anchors.items').overrideWith(
              () => _MemoryLayout(
                PlatformTableLayout(
                  order: [
                    if (savedDestination) 'destination',
                    'remark',
                    'qty',
                    'goods',
                  ],
                  widths: const {'qty': 240},
                  filters: const {'goods': 'keep'},
                  hasQueryPreferences: true,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        Future<void> pump(bool destination) => _pumpAnchoredGrid(
          tester,
          controller: rows,
          destination: destination,
          container: container,
        );
        await pump(false);
        await pump(true);
        // Repeat configure/replay after the insertion as normal host rebuilds do.
        await pump(true);
        expect(
          _renderedOrder(tester, labels),
          savedDestination
              ? ['Destination', 'Remark', 'Quantity', 'Goods']
              : ['Remark', 'Quantity', 'Destination', 'Goods'],
        );
        expect(tester.getSize(_headerCell('Quantity')).width, 240);
        expect(find.text('row-keep'), findsOneWidget);
        expect(find.text('row-other'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
