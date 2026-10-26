import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

double _headerWidth(WidgetTester tester) => tester
    .widgetList<Container>(
      find.ancestor(of: find.text('名称'), matching: find.byType(Container)),
    )
    .firstWhere(
      (widget) =>
          widget.constraints?.hasBoundedWidth == true &&
          widget.constraints!.minWidth == widget.constraints!.maxWidth,
    )
    .constraints!
    .maxWidth;

void main() {
  testWidgets('lightweight sliver rows share a bounded four-row batch', (
    tester,
  ) async {
    var builds = 0;
    final controllers = List.generate(
      12,
      (_) => UtenDeferredRowMountController(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final controller in controllers)
                UtenDeferredRowMount(
                  controller: controller,
                  expensive: false,
                  estimatedExtent: 30,
                  builder: (_) {
                    builds++;
                    return const SizedBox(height: 30);
                  },
                ),
            ],
          ),
        ),
      ),
    );
    expect(builds, 0);
    for (var frame = 0; frame < 3; frame++) {
      final before = builds;
      await tester.pump();
      expect(builds - before, 4);
    }
    await tester.pumpAndSettle();
    expect(
      controllers.every((controller) => controller.hasMountedContent),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'stable rich scope ignores fresh closures and publishes width once',
    (tester) async {
      var calls = 0;
      Widget app(int count) => MaterialApp(
        home: Scaffold(
          body: MasterDataTableView<int>(
            virtualized: true,
            showColumnChooser: false,
            showFullscreenToggle: false,
            rowKeyOf: (row) => '$row',
            items: List.generate(count, (row) => row),
            columns: [
              MasterColumnDef<int>(
                key: 'name',
                label: '名称',
                width: 72,
                value: (row) => '$row',
                measureWidthScope: 'stable-geometry',
                measureWidthOf: (_, row, _) {
                  calls++;
                  final clock = Stopwatch()..start();
                  while (clock.elapsedMicroseconds < 2200) {}
                  return 100.0 + row * 10;
                },
              ),
            ],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
          ),
        ),
      );
      await tester.pumpWidget(app(1));
      await tester.pumpAndSettle();
      final original = _headerWidth(tester);
      final before = calls;
      await tester.pumpWidget(app(1));
      await tester.pumpAndSettle();
      expect(calls, before, reason: 'a build closure is not new geometry');
      await tester.pumpWidget(app(25));
      final widths = <double>{_headerWidth(tester)};
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump();
        final width = _headerWidth(tester);
        expect(width, greaterThanOrEqualTo(original));
        widths.add(width);
      }
      expect(calls, before + 24);
      expect(widths, hasLength(2), reason: 'one complete width publication');
      expect(_headerWidth(tester), greaterThan(original));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lightweight master viewport warms rows without mounting the dataset',
    (tester) async {
      final builds = <int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<int>(
              virtualized: true,
              expensiveRowMounts: false,
              showColumnChooser: false,
              showFullscreenToggle: false,
              rowKeyOf: (row) => '$row',
              items: List.generate(1000, (row) => row),
              columns: [
                MasterColumnDef<int>(
                  key: 'name',
                  label: '名称',
                  width: 200,
                  value: (row) => '$row',
                  cellBuilder: (_, row) {
                    builds.add(row);
                    return SizedBox(height: 36, child: Text('row-$row'));
                  },
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      var mountFrames = 0;
      while (find.byType(UtenRowMountPlaceholder).evaluate().isNotEmpty &&
          mountFrames < 16) {
        await tester.pump();
        mountFrames++;
      }
      // Background width sampling deliberately continues over more frames.
      // Measure visible row readiness separately from that budgeted scan.
      expect(mountFrames, lessThan(16));
      await tester.pumpAndSettle();
      debugPrint(
        'lightweight-master mountFrames=$mountFrames mounted=${builds.length}',
      );
      expect(builds.length, inInclusiveRange(10, 40));
      expect(find.byType(UtenRowMountPlaceholder), findsNothing);
      final body = tester
          .stateList<ScrollableState>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            ),
          )
          .singleWhere((state) => state.position.axis == Axis.vertical);
      builds.clear();
      body.position.jumpTo(20000);
      await tester.pumpAndSettle();
      expect(
        builds.length,
        lessThan(80),
        reason: 'jump directly to a bounded window',
      );
      expect(find.byType(UtenRowMountPlaceholder), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
