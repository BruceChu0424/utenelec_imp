import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';

const Key _fieldKey = ValueKey('overlay-lifecycle-field');
const _items = [
  UtenDropdownItem(value: 'first', label: 'First warehouse'),
  UtenDropdownItem(value: 'second', label: 'Second warehouse'),
];
const _optionKey = ValueKey<(String, Key?, String?)>((
  'uten-dropdown-option',
  _fieldKey,
  'first',
));

void _ignore(String? _) {}

void main() {
  testWidgets('menu follows parent layout when the field is constant', (
    tester,
  ) async {
    late StateSetter update;
    var gap = 60.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return Column(
                children: [
                  SizedBox(height: gap),
                  const SizedBox(
                    width: 220,
                    child: UtenDropdownField(
                      key: _fieldKey,
                      value: null,
                      items: _items,
                      allowClear: false,
                      searchable: false,
                      onChanged: _ignore,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_fieldKey));
    await tester.pumpAndSettle();
    final before = tester.getRect(find.byKey(_optionKey));
    update(() => gap = 100);
    await tester.pumpAndSettle();
    final field = tester.getRect(find.byKey(_fieldKey));
    final menu = tester.getRect(find.byKey(_optionKey));
    expect(menu.top, moreOrLessEquals(before.top + 40));
    expect(menu.top, moreOrLessEquals(field.bottom + 2));
    expect(menu.left, moreOrLessEquals(field.left));
    expect(menu.width, moreOrLessEquals(field.width));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'menu retains field theme, locale, direction and provider scope',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final fieldContainer = ProviderContainer();
      final fieldTheme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => UncontrolledProviderScope(
                  container: fieldContainer,
                  child: Theme(
                    data: fieldTheme,
                    child: Localizations.override(
                      context: context,
                      locale: const Locale('en', 'GB'),
                      child: Directionality(
                        textDirection: TextDirection.rtl,
                        child: MediaQuery(
                          data: MediaQuery.of(
                            context,
                          ).copyWith(textScaler: const TextScaler.linear(1.25)),
                          child: const Center(
                            child: SizedBox(
                              width: 220,
                              child: UtenDropdownField(
                                key: _fieldKey,
                                value: null,
                                items: _items,
                                allowClear: false,
                                searchable: false,
                                onChanged: _ignore,
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
        await tester.tap(find.byKey(_fieldKey));
        await tester.pumpAndSettle();
        final option = tester.element(find.byKey(_optionKey));
        expect(Theme.of(option).colorScheme, fieldTheme.colorScheme);
        expect(Localizations.localeOf(option), const Locale('en', 'GB'));
        expect(Directionality.of(option), TextDirection.rtl);
        expect(MediaQuery.textScalerOf(option).scale(16), 20);
        expect(ProviderScope.containerOf(option), same(fieldContainer));
        expect(
          tester.getSemantics(find.byKey(_optionKey)).label,
          contains('First warehouse'),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        fieldContainer.dispose();
      }
    },
  );

  testWidgets(
    'open menu refreshes items and closes on disable or field removal',
    (tester) async {
      late StateSetter update;
      var enabled = true;
      var visible = true;
      var items = _items;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return visible
                      ? SizedBox(
                          width: 220,
                          child: UtenDropdownField(
                            key: _fieldKey,
                            value: null,
                            items: items,
                            enabled: enabled,
                            allowClear: false,
                            searchable: true,
                            onChanged: _ignore,
                          ),
                        )
                      : const Text('Field removed');
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(_fieldKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'warehouse');
      update(
        () => items = const [
          UtenDropdownItem(value: 'third', label: 'Third warehouse'),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Third warehouse'), findsOneWidget);
      expect(find.text('First warehouse'), findsNothing);
      update(() => enabled = false);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Third warehouse'), findsNothing);
      update(() => enabled = true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_fieldKey));
      await tester.pumpAndSettle();
      expect(find.text('Third warehouse'), findsOneWidget);
      update(() => visible = false);
      await tester.pumpAndSettle();
      expect(find.text('Field removed'), findsOneWidget);
      expect(find.text('Third warehouse'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
