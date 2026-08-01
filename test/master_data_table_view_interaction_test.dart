import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _rowText = 'ROW-WITHOUT-DETAIL';

Widget _table({ValueChanged<String>? onRowTap}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        child: MasterDataTableView<String>(
          columns: const [
            MasterColumnDef<String>(
              key: 'value',
              label: '值',
              width: 240,
              value: _identity,
            ),
          ],
          items: const [_rowText],
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: onRowTap,
          embedded: true,
        ),
      ),
    ),
  );
}

String _identity(String value) => value;

Finder _rowInkWell() =>
    find.ancestor(of: find.text(_rowText), matching: find.byType(InkWell));

void main() {
  testWidgets('row without callback has no tap widget or tap semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_table());
      await tester.pumpAndSettle();

      expect(find.text(_rowText), findsOneWidget);
      expect(_rowInkWell(), findsNothing);
      expect(
        tester
            .getSemantics(find.text(_rowText))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('row with callback remains tappable and exposes tap semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    try {
      await tester.pumpWidget(_table(onRowTap: (_) => taps++));
      await tester.pumpAndSettle();

      expect(_rowInkWell(), findsOneWidget);
      expect(
        tester
            .getSemantics(find.text(_rowText))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );

      await tester.tap(find.text(_rowText));
      await tester.pump();
      expect(taps, 1);
    } finally {
      semantics.dispose();
    }
  });
}
