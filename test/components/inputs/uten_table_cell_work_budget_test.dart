import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_auto_width.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

void main() {
  testWidgets(
    'row host mounts one theme for 120 input cells and preserves focus on zoom',
    (tester) async {
      final controller = TextEditingController(text: 'draft');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      Widget app(double scale) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: UtenTableCellInputTheme(
                key: const Key('row-host'),
                child: Column(
                  children: [
                    for (var i = 0; i < 120; i++)
                      UtenTableCellInputTheme(
                        child: i == 0
                            ? TextField(
                                key: const Key('edit'),
                                controller: controller,
                                focusNode: focus,
                              )
                            : Text('cell-$i'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(1));
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('row-host'));
      expect(
        find.descendant(of: row, matching: find.byType(Theme)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('edit')));
      await tester.enterText(
        find.byKey(const Key('edit')),
        'uncommitted value',
      );
      await tester.pump();
      final inputState = tester.state(find.byType(EditableText));
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 6,
      );
      await tester.pumpWidget(app(2));
      await tester.pump();
      expect(
        find.descendant(of: row, matching: find.byType(Theme)),
        findsOneWidget,
      );
      expect(tester.state(find.byType(EditableText)), same(inputState));
      expect(focus.hasFocus, isTrue);
      expect(controller.text, 'uncommitted value');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 6),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit local theme and local zoom are reinjected with their own geometry',
    (tester) async {
      final observed = <String, ThemeData>{};
      Widget probe(String key) => UtenTableCellInputTheme(
        child: Builder(
          builder: (context) {
            observed[key] = Theme.of(context);
            return Text(key);
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: UtenTableCellInputTheme(
              key: const Key('row-host'),
              child: Column(
                children: [
                  probe('ordinary'),
                  Theme(
                    data: ThemeData(
                      platform: TargetPlatform.android,
                      colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
                      textTheme: const TextTheme(
                        bodyMedium: TextStyle(fontSize: 20),
                      ),
                    ),
                    child: probe('local-theme'),
                  ),
                  MediaQuery(
                    data: const MediaQueryData(
                      textScaler: TextScaler.linear(2),
                    ),
                    child: probe('local-zoom'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // One row theme, explicit local Theme + its cell theme, one zoom cell theme.
      expect(
        find.descendant(
          of: find.byKey(const Key('row-host')),
          matching: find.byType(Theme),
        ),
        findsNWidgets(4),
      );
      expect(
        observed['local-theme']!.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: Colors.red).primary,
      );
      expect(observed['local-theme']!.textTheme.bodyMedium!.fontSize, 20);
      expect(
        observed['local-theme']!.inputDecorationTheme.constraints!.minHeight,
        48,
      );
      expect(
        observed['ordinary']!.inputDecorationTheme.constraints!.minHeight,
        32,
      );
      expect(
        observed['local-zoom']!.inputDecorationTheme.contentPadding,
        isNot(observed['ordinary']!.inputDecorationTheme.contentPadding),
      );
      expect(tester.takeException(), isNull);
    },
  );

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
