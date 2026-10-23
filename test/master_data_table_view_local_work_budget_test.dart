import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  _Row(this.id, this.value);
  final int id;
  String value;
}

void main() {
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
