import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/search/numeric_column_query.dart';

void main() {
  for (final editing in [false, true]) {
    testWidgets(
      'numeric search error stays inside its field: editing=$editing',
      (tester) async {
        final submitted = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: editing
                  ? Center(
                      child: SizedBox(
                        width: 240,
                        child: GridHeaderFilterCell(
                          label: '数量',
                          buckets: const [],
                          nullCount: 0,
                          selected: null,
                          numericSearch: true,
                          onChanged: (_) {},
                          onSearch: submitted.add,
                        ),
                      ),
                    )
                  : MasterDataTableView<String>(
                      columns: [
                        MasterColumnDef(
                          key: 'quantity',
                          label: '数量',
                          type: 'number',
                          width: 240,
                          value: (row) => row,
                        ),
                      ],
                      items: const ['10'],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, value) => submitted.add(value),
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('数量').first);
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('uten-column-keyword-input'));
        final initialHeight = tester.getSize(input).height;
        await tester.enterText(input, '>>10');
        await tester.tap(find.byKey(const Key('uten-column-keyword-search')));
        await tester.pumpAndSettle();
        expect(submitted, isEmpty);
        expect(tester.getSize(input).height, initialHeight);
        final errorHint = find.byWidgetPredicate(
          (widget) =>
              widget is UtenFieldHintIcon &&
              widget.errorMessage == NumericColumnQuery.error,
        );
        expect(errorHint.hitTestable(), findsOneWidget);
        await tester.tap(errorHint);
        await tester.pumpAndSettle();
        expect(find.text(NumericColumnQuery.error), findsOneWidget);
        expect(tester.widget<TextField>(input).controller!.text, '>>10');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
