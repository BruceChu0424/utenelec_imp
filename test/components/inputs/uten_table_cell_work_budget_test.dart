import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_auto_width.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

void main() {
  testWidgets(
    'identical cells share derived theme while zoom gets its own geometry',
    (tester) async {
      final theme = ThemeData();
      var creates = 0;
      debugUiWorkSliceObserver = (label, _) {
        if (label == 'table-cell-theme-create') creates++;
      };
      addTearDown(() => debugUiWorkSliceObserver = null);
      final observed = Set<ThemeData>.identity();
      Widget app(double scale) => MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (var i = 0; i < 120; i++)
                  UtenTableCellInputTheme(
                    child: Builder(
                      builder: (context) {
                        observed.add(Theme.of(context));
                        return Text('row-$i');
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(1));
      await tester.pumpAndSettle();
      expect(creates, 1);
      expect(observed, hasLength(1));
      final ordinary = observed.single.inputDecorationTheme.contentPadding;
      observed.clear();
      await tester.pumpWidget(app(2));
      await tester.pumpAndSettle();
      expect(creates, 2);
      expect(observed, hasLength(1));
      expect(
        observed.single.inputDecorationTheme.contentPadding,
        isNot(ordinary),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large custom-cell discovery is bounded per frame and drains without lost cells',
    (tester) async {
      var scans = 0;
      debugUiWorkSliceObserver = (label, _) {
        if (label == 'table-cell-auto-width-scan') scans++;
      };
      addTearDown(() => debugUiWorkSliceObserver = null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < 500; i++)
                    UtenTableCellAutoWidth(
                      onWidthNeeded: (_) {},
                      child: Text('cell-$i'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(scans, greaterThan(0));
      expect(scans, lessThanOrEqualTo(64));
      await tester.pumpAndSettle();
      expect(scans, 500);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
