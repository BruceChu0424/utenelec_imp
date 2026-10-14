import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  testWidgets(
    'revealed compact controls stay beyond the frozen checkbox column',
    (tester) async {
      var calls = 0;
      var selected = <String>{};
      const targetKey = Key('compact-table-action');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 350,
              child: MasterDataTableView<String>(
                columns: [
                  MasterColumnDef<String>(
                    key: 'action',
                    label: 'A',
                    width: 64,
                    minimumWidthOf: (_) => 64,
                    value: (_) => 'Go',
                    cellBuilder: (_, _) => InkWell(
                      key: targetKey,
                      onTap: () => calls++,
                      child: const Text('Go'),
                    ),
                  ),
                  MasterColumnDef<String>(
                    key: 'name',
                    label: '名称',
                    width: 300,
                    value: (_) =>
                        'A sufficiently long name keeps the table horizontally scrollable',
                  ),
                ],
                items: const ['row'],
                facets: const {
                  'action': [
                    MasterFacetBucket(value: 'one', count: 1, label: 'Choice'),
                  ],
                },
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                selectable: true,
                idOf: (row) => row,
                selectedIds: selected,
                onSelectedIdsChanged: (next) => selected = next,
                showFullscreenToggle: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final target = find.byKey(targetKey);
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(
        calls,
        1,
        reason: 'the field must receive the click, not its frozen checkbox',
      );
      expect(selected, isEmpty);

      final header = find.text('A');
      await tester.ensureVisible(header);
      await tester.pumpAndSettle();
      expect(header.hitTestable(), findsOneWidget);
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('Choice (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
