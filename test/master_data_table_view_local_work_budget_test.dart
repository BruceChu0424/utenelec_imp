import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

class _Row {
  _Row(this.id, this.value);
  final int id;
  String value;
}

void main() {
  testWidgets('custom cells share one mounted input Theme per data row', (
    tester,
  ) async {
    final themes = <(int, int), Theme>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MasterDataTableView<int>(
            items: const [0, 1, 2, 3, 4, 5],
            virtualized: true,
            showColumnChooser: false,
            columns: [
              for (var column = 0; column < 12; column++)
                MasterColumnDef<int>(
                  key: 'c$column',
                  label: '列$column',
                  width: 80,
                  value: (row) => '$row:$column',
                  cellBuilder: (context, row) {
                    themes[(row, column)] = context
                        .findAncestorWidgetOfExactType<Theme>()!;
                    return Text('$row:$column');
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
    await tester.pumpAndSettle();
    expect(themes, hasLength(72));
    expect(Set<Theme>.identity()..addAll(themes.values), hasLength(6));
    for (var row = 0; row < 6; row++) {
      for (var column = 1; column < 12; column++) {
        expect(themes[(row, column)], same(themes[(row, 0)]));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selection scope is synchronous, one header collection and live outside the scope',
    (tester) async {
      const count = 300;
      var allowed = true;
      bool? scopedPermission;
      var active = false;
      var scopeCalls = 0;
      var scopedIds = 0;
      var projectedBuilds = 0;
      Set<String>? selection;
      R scoped<R>(R Function() read) {
        expect(active, isFalse);
        active = true;
        scopedPermission = allowed;
        scopeCalls++;
        try {
          return read();
        } finally {
          scopedPermission = null;
          active = false;
        }
      }

      debugUiWorkSliceObserver = (label, _) {
        if (label == 'master.projected-table') projectedBuilds++;
      };
      addTearDown(() => debugUiWorkSliceObserver = null);
      final table = MasterDataTableView<int>(
        items: [for (var i = 0; i < count; i++) i],
        virtualized: true,
        selectable: true,
        columns: [
          MasterColumnDef<int>(
            key: 'name',
            label: '名称',
            width: 120,
            value: (row) => '$row',
          ),
        ],
        rowKeyOf: (row) => '$row',
        selectionReadScope: scoped,
        idOf: (row) {
          if (active) scopedIds++;
          return (scopedPermission ?? allowed) ? '$row' : null;
        },
        onSelectedIdsChanged: (next) {
          expect(
            active,
            isFalse,
            reason:
                'business callbacks must be outside the presentation read scope',
          );
          selection = next;
        },
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        showFullscreenToggle: false,
      );
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: table)));
      await tester.pumpAndSettle();
      expect(active, isFalse);
      expect(
        scopeCalls,
        projectedBuilds,
        reason: 'one header ID collection per table build',
      );
      expect(scopedIds, scopeCalls * count);
      // The previously captured callback must see an in-place authorization
      // change without rebuilding the widget or replacing its closure.
      allowed = false;
      expect(table.idOf!(0), isNull);
      await tester.tap(find.byKey(const Key('master-data-table-select-all')));
      await tester.pumpAndSettle();
      expect(selection, isNull);
      expect(active, isFalse);
      allowed = true;
      expect(table.idOf!(0), '0');
      await tester.tap(find.byKey(const Key('master-data-table-select-all')));
      await tester.pumpAndSettle();
      expect(selection, {for (var i = 0; i < count; i++) '$i'});
      expect(active, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty selection and absent rows controller do not evaluate row eligibility',
    (tester) async {
      var identities = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<int>(
              items: [for (var i = 0; i < 1000; i++) i],
              virtualized: true,
              columns: [
                MasterColumnDef<int>(
                  key: 'name',
                  label: '名称',
                  width: 120,
                  value: (row) => '$row',
                ),
              ],
              rowKeyOf: (row) => '$row',
              idOf: (row) {
                identities++;
                return '$row';
              },
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(identities, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local sorting reads values linearly and reuses the view for selection chrome',
    (tester) async {
      var reads = 0;
      final rows = [for (var i = 0; i < 600; i++) _Row(i, '${600 - i}')];
      final column = MasterColumnDef<_Row>(
        key: 'amount',
        label: '金额',
        width: 160,
        type: 'number',
        sortable: true,
        filterFromRows: true,
        value: (row) {
          reads++;
          return row.value;
        },
        measureValueOf: (row) => row.value,
        cellBuilder: (_, row) => Text('值${row.value}'),
      );
      Widget app() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 500,
            child: MasterDataTableView<_Row>(
              items: rows,
              columns: [column],
              virtualized: true,
              idOf: (row) => '${row.id}',
              selectable: true,
              onSelectedIdsChanged: (_) {},
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              showFullscreenToggle: false,
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('金额').first);
      await tester.pumpAndSettle();
      reads = 0;
      await tester.tap(find.text('从小到大'));
      await tester.pumpAndSettle();
      expect(find.text('值1'), findsOneWidget);
      expect(
        reads,
        lessThan(rows.length * 3),
        reason:
            'sorting and the selection header must not repeat comparator value reads',
      );
      final stableReads = reads;
      debugPrint('master-local-sort rows=600 valueReads=$stableReads');
      await tester.pump(const Duration(milliseconds: 16));
      expect(reads, stableReads);
      // Mutable host rows are supported: rebuilding the same list must retire
      // both the sorted projection and the local facet values.
      rows.last.value = '-1';
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('值-1'), findsOneWidget);
      await tester.tap(find.text('金额').first);
      await tester.pumpAndSettle();
      expect(find.text('-1 (1)'), findsOneWidget);
      expect(find.text('1 (1)'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
