import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_filter_field_theme.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';

final _outline = find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint &&
      widget.foregroundPainter?.runtimeType.toString() == '_InputBorderPainter',
);

const _items = [
  UtenDropdownItem(value: 'main', label: 'Main warehouse'),
  UtenDropdownItem(value: 'branch', label: 'Branch warehouse'),
];

Widget _field(String role, String state) => UtenDropdownField(
  key: ValueKey(role),
  label: 'Warehouse',
  value: state == 'empty' ? null : 'main',
  items: _items,
  info: state == 'info' ? 'The warehouse controls the available stock.' : null,
  errorMessage: state == 'error' ? 'Select an available warehouse.' : null,
  autofilled: state == 'autofill',
  onChanged: (_) {},
);

Future<void> _pump(
  WidgetTester tester, {
  required bool dark,
  required bool touch,
  required Widget child,
  double scale = 1,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = Size(touch ? 390 : 1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: (theme ?? (dark ? buildDarkTheme() : buildLightTheme())).copyWith(
        platform: touch ? TargetPlatform.android : TargetPlatform.windows,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: UtenControlTheme(child: SizedBox(width: 340, child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _rect(WidgetTester tester, String key) => tester.getRect(
  find.descendant(of: find.byKey(ValueKey(key)), matching: _outline),
);

Widget _roles(String state) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    const UtenSearchBar(key: ValueKey('search')),
    _field('form', state),
    UtenFilterFieldTheme(child: _field('filter', state)),
    UtenTableCellInputTheme(child: _field('table', state)),
  ],
);

void main() {
  for (final dark in [false, true]) {
    for (final touch in [false, true]) {
      testWidgets(
        'filter role also owns generic theme density dark=$dark touch=$touch',
        (tester) async {
          await _pump(
            tester,
            dark: dark,
            touch: touch,
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            child: Column(
              children: [
                const UtenSearchBar(key: ValueKey('search')),
                for (final state in [
                  'empty',
                  'selected',
                  'info',
                  'error',
                  'autofill',
                ])
                  UtenFilterFieldTheme(child: _field('generic-$state', state)),
              ],
            ),
          );
          for (final state in [
            'empty',
            'selected',
            'info',
            'error',
            'autofill',
          ]) {
            expect(
              Theme.of(
                tester.element(find.byKey(ValueKey('generic-$state'))),
              ).inputDecorationTheme.border,
              isA<OutlineInputBorder>().having(
                (border) => border.borderRadius,
                'filter border radius',
                UtenFilterRow.borderRadius,
              ),
            );
            expect(
              _rect(tester, 'generic-$state').height,
              closeTo(_rect(tester, 'search').height, .5),
              reason: state,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );

      for (final state in ['empty', 'selected', 'info', 'error', 'autofill']) {
        testWidgets(
          'input roles retain geometry dark=$dark touch=$touch $state',
          (tester) async {
            await _pump(tester, dark: dark, touch: touch, child: _roles(state));
            final filterHeight = _rect(tester, 'search').height;
            expect(filterHeight, closeTo(touch ? 48 : 36, .5));
            expect(_rect(tester, 'filter').height, closeTo(filterHeight, .5));
            expect(_rect(tester, 'form').height, closeTo(touch ? 48 : 44, .5));
            expect(_rect(tester, 'table').height, closeTo(touch ? 48 : 32, .5));
            if (['info', 'error', 'autofill'].contains(state)) {
              final hint = find.descendant(
                of: find.byKey(const ValueKey('filter')),
                matching: find.byType(UtenFieldHintIcon),
              );
              expect(hint, findsOneWidget);
              expect(
                _rect(tester, 'filter').contains(tester.getCenter(hint)),
                isTrue,
              );
              await tester.tap(hint);
              await tester.pumpAndSettle();
              final message = state == 'info'
                  ? 'The warehouse controls the available stock.'
                  : state == 'error'
                  ? 'Select an available warehouse.'
                  : '已按上次记录预填，请核对';
              expect(find.text(message), findsOneWidget);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }

      testWidgets(
        'large text grows instead of clipping dark=$dark touch=$touch',
        (tester) async {
          await _pump(
            tester,
            dark: dark,
            touch: touch,
            scale: 2,
            child: _roles('info'),
          );
          for (final role in ['filter', 'form', 'table']) {
            final rect = _rect(tester, role);
            final floor = touch
                ? 48
                : {'filter': 36, 'form': 44, 'table': 32}[role]!;
            expect(rect.height, greaterThan(floor));
            final hint = find.descendant(
              of: find.byKey(ValueKey(role)),
              matching: find.byType(UtenFieldHintIcon),
            );
            expect(rect.contains(tester.getCenter(hint)), isTrue);
          }
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'table role takes priority in either nesting order dark=$dark touch=$touch',
        (tester) async {
          await _pump(
            tester,
            dark: dark,
            touch: touch,
            child: Column(
              children: [
                UtenFilterFieldTheme(
                  child: UtenTableCellInputTheme(
                    child: _field('outer-filter', 'info'),
                  ),
                ),
                UtenTableCellInputTheme(
                  child: UtenFilterFieldTheme(
                    child: _field('outer-table', 'info'),
                  ),
                ),
              ],
            ),
          );
          for (final role in ['outer-filter', 'outer-table']) {
            expect(_rect(tester, role).height, closeTo(touch ? 48 : 32, .5));
            expect(
              Theme.of(
                tester.element(find.byKey(ValueKey(role))),
              ).inputDecorationTheme.border,
              isA<OutlineInputBorder>().having(
                (border) => border.borderRadius,
                'table border radius',
                UtenEditableGridCellSpec.borderRadius,
              ),
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('filter scope retains normal menu selection and field identity', (
    tester,
  ) async {
    var selected = 'main';
    final calls = <String?>[];
    await _pump(
      tester,
      dark: false,
      touch: false,
      child: StatefulBuilder(
        builder: (context, setState) => UtenFilterFieldTheme(
          child: UtenDropdownField(
            key: const ValueKey('filter'),
            value: selected,
            items: _items,
            info: 'Select the stock scope.',
            onChanged: (value) {
              calls.add(value);
              setState(() => selected = value!);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Branch warehouse'));
    await tester.pumpAndSettle();
    expect(calls, ['branch']);
    expect(selected, 'branch');
    expect(find.text('Branch warehouse'), findsOneWidget);
    expect(_rect(tester, 'filter').height, UtenFilterRow.minHeight);
    expect(tester.takeException(), isNull);
  });
}
