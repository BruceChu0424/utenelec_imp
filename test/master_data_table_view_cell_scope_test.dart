import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final selectable in [false, true]) {
    testWidgets(
      'custom cells receive actual ${selectable ? "checkbox" : "single-row"} selection',
      (tester) async {
        Set<String> selectedIds = {};
        final scopes = <String, MasterDataTableCellScope>{};
        final textColors = <String, Color?>{};
        final iconColors = <String, Color?>{};
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: Brightness.light),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => SizedBox(
                  width: 640,
                  height: 300,
                  child: MasterDataTableView<String>(
                    columns: [
                      MasterColumnDef<String>(
                        key: 'custom',
                        label: 'Custom',
                        width: 200,
                        value: (item) => item,
                        cellBuilder: (cellContext, item) {
                          scopes[item] = MasterDataTableCellScope.maybeOf(
                            cellContext,
                          )!;
                          textColors[item] = DefaultTextStyle.of(
                            cellContext,
                          ).style.color;
                          iconColors[item] = IconTheme.of(cellContext).color;
                          return Text(item);
                        },
                      ),
                    ],
                    items: const ['First', 'Second'],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: selectable,
                    idOf: (item) => item,
                    selectedIds: selectedIds,
                    onSelectedIdsChanged: (next) =>
                        setState(() => selectedIds = next),
                    onRowTap: (_) {},
                    showFullscreenToggle: false,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(scopes['First']!.selected, isFalse);
        await tester.tap(find.text('First'));
        await tester.pumpAndSettle();
        expect(scopes['First']!.selected, isTrue);
        expect(scopes['First']!.foregroundColor, Colors.white);
        expect(textColors['First'], Colors.white);
        expect(iconColors['First'], Colors.white);
        expect(scopes['Second']!.selected, isFalse);
        expect(selectedIds, selectable ? {'First'} : isEmpty);

        await tester.tap(find.text('Second'));
        await tester.pumpAndSettle();
        expect(scopes['Second']!.selected, isTrue);
        expect(scopes['First']!.selected, selectable);
        if (!selectable) expect(textColors['First'], isNot(Colors.white));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
