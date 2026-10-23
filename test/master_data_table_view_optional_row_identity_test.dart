import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final identity in ['absent', 'empty', 'valid']) {
    testWidgets(
      'multiple selectable rows have unique reveal keys with $identity identity',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final rows = ValueNotifier(const ['row-a', 'row-b']);
        addTearDown(rows.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SelectionArea(
                child: ValueListenableBuilder(
                  valueListenable: rows,
                  builder: (_, value, _) => MasterDataTableView<String>(
                    columns: [
                      MasterColumnDef(
                        key: 'name',
                        label: '名称',
                        width: 220,
                        value: (row) => row,
                      ),
                    ],
                    items: value,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    rowKeyOf: identity == 'absent'
                        ? null
                        : (row) => identity == 'empty' ? '' : row,
                    revealItemId: identity == 'empty'
                        ? ''
                        : identity == 'valid'
                        ? 'row-b'
                        : null,
                    revealRequest: identity == 'absent' ? 0 : 1,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('row-a'), findsOneWidget);
        expect(find.text('row-b'), findsOneWidget);
        rows.value = const ['row-a', 'row-b', 'row-c'];
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('row-c'), findsOneWidget);
      },
    );
  }
}
