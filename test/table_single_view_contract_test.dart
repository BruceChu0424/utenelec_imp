import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';
import 'package:uten_imp/components/layout/uten_pagination.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _ElementMountProbe extends StatefulWidget {
  const _ElementMountProbe(this.text, this.onMount);
  final String text;
  final VoidCallback onMount;

  @override
  State<_ElementMountProbe> createState() => _ElementMountProbeState();
}

class _ElementMountProbeState extends State<_ElementMountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => Text(widget.text);
}

void main() {
  testWidgets(
    '36000 loaded rows scroll locally without pages, placeholder admission or header remounts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rows = MasterDataTableRowsController<int>();
      final built = <int>{};
      var networkPageRequests = 0;
      final data = List.generate(36000, (index) => index);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<int>(
              rowsController: rows,
              rowKeyOf: (row) => '$row',
              items: data,
              // Stale compatibility metadata cannot reactivate scroll paging.
              totalPages: 1800,
              onPageChange: (_) => networkPageRequests++,
              columns: [
                MasterColumnDef<int>(
                  key: 'name',
                  label: '名称',
                  width: 220,
                  value: (row) => '货品 $row',
                  cellBuilder: (_, row) {
                    built.add(row);
                    return Text('货品 $row');
                  },
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              showColumnChooser: false,
              showFullscreenToggle: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(rows.items, hasLength(36000));
      expect(built.length, lessThan(150));
      expect(find.byType(UtenPagination), findsNothing);
      expect(find.byType(UtenRowMountPlaceholder), findsNothing);
      final header = tester.element(find.text('名称').first);
      final position = tester.state<ScrollableState>(_vertical()).position;
      for (final fraction in [.75, .15, .95, .0, .5, .0]) {
        position.jumpTo(position.maxScrollExtent * fraction);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(UtenRowMountPlaceholder), findsNothing);
        expect(
          identical(tester.element(find.text('名称').first), header),
          isTrue,
        );
        expect(networkPageRequests, 0);
      }
      await tester.pumpAndSettle();
      expect(built.length, lessThan(1500));
      expect(find.text('货品 0'), findsOneWidget);
      expect(rows.items, hasLength(36000));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a complete report with duplicate display values still virtualizes without business IDs',
    (tester) async {
      var mounts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<String>(
              items: List.filled(20000, '相同显示值'),
              columns: [
                MasterColumnDef<String>(
                  key: 'value',
                  label: '结果',
                  width: 180,
                  value: (row) => row,
                  cellBuilder: (_, row) {
                    return _ElementMountProbe(row, () => mounts++);
                  },
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              showColumnChooser: false,
              showFullscreenToggle: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(mounts, lessThan(200));
      expect(
        find.byWidgetPredicate((widget) => widget is UtenAncestorRowWindow),
        findsOneWidget,
      );
      expect(find.byType(UtenDeferredRowMount), findsNothing);
      final position = tester.state<ScrollableState>(_vertical()).position;
      position.jumpTo(position.maxScrollExtent * .8);
      await tester.pumpAndSettle();
      expect(mounts, lessThan(500));
      expect(find.byType(UtenRowMountPlaceholder), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('anonymous complete report replaces and reorders its snapshot', (
    tester,
  ) async {
    final rows = ValueNotifier(List.generate(5000, (index) => 'item-$index'));
    addTearDown(rows.dispose);
    var mounts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<List<String>>(
            valueListenable: rows,
            builder: (_, items, _) => MasterDataTableView<String>(
              items: items,
              rowKeyOf: (_) => null,
              columns: [
                MasterColumnDef<String>(
                  key: 'value',
                  label: '结果',
                  width: 180,
                  value: (row) => row,
                  cellBuilder: (_, row) =>
                      _ElementMountProbe(row, () => mounts++),
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              showColumnChooser: false,
              showFullscreenToggle: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('item-0'), findsOneWidget);
    rows.value = rows.value.reversed.toList();
    await tester.pumpAndSettle();
    expect(find.text('item-4999'), findsOneWidget);
    expect(find.text('item-0'), findsNothing);
    rows.value = ['replacement', ...rows.value.skip(1)];
    await tester.pumpAndSettle();
    expect(find.text('replacement'), findsOneWidget);
    expect(find.text('item-4999'), findsNothing);
    final position = tester.state<ScrollableState>(_vertical()).position;
    position.jumpTo(position.maxScrollExtent * .9);
    await tester.pumpAndSettle();
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('replacement'), findsOneWidget);
    expect(mounts, lessThan(500));
    expect(find.byType(UtenRowMountPlaceholder), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Finder _vertical() => find
    .byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    )
    .first;
