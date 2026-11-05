import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  testWidgets(
    'local tree projection preserves full facets, row identity and hidden selections',
    (tester) async {
      const rows = ['P', 'P/C', 'P/C/G'];
      var folded = true;
      var selected = <String>{'P/C/G'};
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, change) {
                update = change;
                return MasterDataTableView<String>(
                  key: const Key('tree-table'),
                  items: rows,
                  unfilteredRows: (all) => folded ? all.take(1).toList() : all,
                  filterContextRows: (all, matched) => all
                      .where(
                        (row) => matched.any(
                          (match) => match == row || match.startsWith('$row/'),
                        ),
                      )
                      .toList(),
                  columns: [
                    MasterColumnDef(
                      key: 'id',
                      label: '编号',
                      width: 300,
                      value: (row) => row,
                      filterFromRows: true,
                    ),
                  ],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  selectable: true,
                  idOf: (row) => row,
                  rowWidgetKeyOf: (row) => ValueKey('tree-$row'),
                  selectedIds: selected,
                  onSelectedIdsChanged: (next) => change(() => selected = next),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('P/C/G'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('master-column-filter-id')));
      await tester.pumpAndSettle();
      expect(find.text('P/C/G (1)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        'P/C/G',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      for (final row in rows) {
        expect(find.text(row), findsWidgets);
      }
      Checkbox selectedBox() => tester.widget<Checkbox>(
        find
            .descendant(
              of: find.byKey(const ValueKey('tree-P/C/G')),
              matching: find.byType(Checkbox),
            )
            .first,
      );
      expect(selectedBox().value, isTrue);
      await tester.tap(find.byKey(const ValueKey('master-column-filter-id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      expect(find.text('P/C/G'), findsNothing);
      expect(selected, {'P/C/G'});
      update(() => folded = false);
      await tester.pumpAndSettle();
      expect(selectedBox().value, isTrue);
      expect(
        tester
            .widget<MasterDataTableView<String>>(
              find.byKey(const Key('tree-table')),
            )
            .items,
        same(rows),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
