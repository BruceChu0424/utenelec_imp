import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';

const _choices = [
  UtenDropdownItem(value: 'a', label: 'Alpha warehouse'),
  UtenDropdownItem(value: 'b', label: 'Beta warehouse'),
];

Finder _option(Key field, String value) => find.byKey(
  ValueKey<(String, Key?, String?)>(('uten-dropdown-option', field, value)),
);

void main() {
  testWidgets(
    'two cells in one list row expose operable semantics and retain separate values',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        const first = ValueKey('first warehouse');
        const second = ValueKey('second warehouse');
        final values = <String?>[null, null];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => ListView(
                  children: [
                    Row(
                      children: [
                        for (var i = 0; i < 2; i++)
                          SizedBox(
                            width: 240,
                            child: UtenDropdownField(
                              key: i == 0 ? first : second,
                              value: values[i],
                              label: i == 0
                                  ? 'Source warehouse'
                                  : 'Target warehouse',
                              items: _choices,
                              allowClear: false,
                              searchable: false,
                              onChanged: (value) =>
                                  setState(() => values[i] = value),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        for (final field in [first, second, first, second]) {
          await tester.tap(find.byKey(field));
          await tester.pumpAndSettle();
          final node = tester.getSemantics(_option(field, 'b'));
          expect(node.label, contains('Beta warehouse'));
          expect(
            node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            isTrue,
          );
          await tester.tap(_option(field, field == first ? 'a' : 'b'));
          await tester.pumpAndSettle();
          expect(_option(field, 'a'), findsNothing);
        }
        expect(values, ['a', 'b']);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'bare nested scrollables follow both axes and close after anchor leaves viewport',
    (tester) async {
      final vertical = ScrollController();
      final horizontal = ScrollController();
      addTearDown(vertical.dispose);
      addTearDown(horizontal.dispose);
      const field = ValueKey('bare scroll warehouse');
      final values = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 300,
                child: SingleChildScrollView(
                  controller: vertical,
                  child: SizedBox(
                    height: 1000,
                    child: SingleChildScrollView(
                      controller: horizontal,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: 1000,
                        height: 1000,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 120, top: 80),
                            child: SizedBox(
                              width: 220,
                              child: UtenDropdownField(
                                key: field,
                                value: null,
                                items: _choices,
                                allowClear: false,
                                searchable: false,
                                onChanged: values.add,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Scaffold), findsNothing);
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      final before = tester.getRect(_option(field, 'a'));
      horizontal.jumpTo(40);
      vertical.jumpTo(30);
      await tester.pumpAndSettle();
      final after = tester.getRect(_option(field, 'a'));
      expect(after.left, moreOrLessEquals(before.left - 40));
      expect(after.top, moreOrLessEquals(before.top - 30));
      expect(after.width, moreOrLessEquals(before.width));
      vertical.jumpTo(500);
      await tester.pumpAndSettle();
      expect(_option(field, 'a'), findsNothing);
      expect(_option(field, 'b'), findsNothing);
      expect(values, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disable remove and global-key reparent close active searchable owner without stale callbacks',
    (tester) async {
      final field = GlobalKey();
      final values = <String?>[];
      late StateSetter change;
      var enabled = true;
      var visible = true;
      var moved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                final input = UtenDropdownField(
                  key: field,
                  value: null,
                  items: _choices,
                  allowClear: false,
                  searchable: true,
                  enabled: enabled,
                  onChanged: values.add,
                );
                return Row(
                  children: [
                    SizedBox(
                      key: const ValueKey('left owner'),
                      width: 240,
                      child: visible && !moved ? input : const SizedBox(),
                    ),
                    SizedBox(
                      key: const ValueKey('right owner'),
                      width: 240,
                      child: visible && moved ? input : const SizedBox(),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      Future<void> openSearch() async {
        await tester.tap(find.byKey(field));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Beta');
        await tester.pumpAndSettle();
        expect(_option(field, 'b'), findsOneWidget);
      }

      await openSearch();
      change(() => enabled = false);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(_option(field, 'b'), findsNothing);
      change(() => enabled = true);
      await tester.pumpAndSettle();
      await openSearch();
      change(() => moved = true);
      await tester.pumpAndSettle();
      expect(find.byKey(field), findsOneWidget);
      expect(_option(field, 'b'), findsNothing);
      await openSearch();
      change(() => visible = false);
      await tester.pumpAndSettle();
      expect(find.byKey(field), findsNothing);
      expect(_option(field, 'b'), findsNothing);
      expect(values, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pushing another route closes old owner menu and returning can choose again',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      const field = ValueKey('route warehouse');
      final values = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: UtenDropdownField(
                key: field,
                value: null,
                items: _choices,
                allowClear: false,
                searchable: false,
                onChanged: values.add,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      expect(_option(field, 'a'), findsOneWidget);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('New current route')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('New current route'), findsOneWidget);
      expect(_option(field, 'a'), findsNothing);
      expect(values, isEmpty);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      await tester.tap(_option(field, 'b'));
      await tester.pumpAndSettle();
      expect(values, ['b']);
      expect(_option(field, 'b'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
