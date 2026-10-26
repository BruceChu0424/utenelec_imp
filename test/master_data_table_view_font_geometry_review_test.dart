import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  testWidgets('a smaller rich-cell font retires the previous automatic width', (
    tester,
  ) async {
    final rows = [1];
    Widget app(double fontSize) => MaterialApp(
      themeAnimationDuration: Duration.zero,
      theme: ThemeData(
        textTheme: TextTheme(bodyMedium: TextStyle(fontSize: fontSize)),
      ),
      home: Scaffold(
        body: MasterDataTableView<int>(
          items: rows,
          showFullscreenToggle: false,
          showColumnChooser: false,
          columns: [
            MasterColumnDef<int>(
              key: 'name',
              label: 'Name',
              width: 72,
              minimumWidthOf: (_) => 72,
              value: (row) => '$row',
              measureWidthScope: 'font-geometry',
              measureWidthOf: (context, _, _) =>
                  Theme.of(context).textTheme.bodyMedium!.fontSize! * 10,
            ),
          ],
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
        ),
      ),
    );

    double width() => tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('Name'),
            matching: find.byType(Container),
          ),
        )
        .firstWhere(
          (container) =>
              container.constraints?.hasBoundedWidth == true &&
              container.constraints!.minWidth ==
                  container.constraints!.maxWidth,
        )
        .constraints!
        .maxWidth;

    await tester.pumpWidget(app(30));
    await tester.pumpAndSettle();
    final large = width();
    await tester.pumpWidget(app(10));
    await tester.pumpAndSettle();
    expect(width(), lessThan(large - 100));
    expect(tester.takeException(), isNull);
  });
}
