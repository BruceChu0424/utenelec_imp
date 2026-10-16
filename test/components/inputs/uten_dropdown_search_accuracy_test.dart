import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

const _field = ValueKey('search-accuracy');
Finder _option(String value) => find.byKey(
  ValueKey<(String, Key?, String?)>(('uten-dropdown-option', _field, value)),
);

Future<void> _open(WidgetTester tester, List<UtenDropdownItem> items) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: UtenDropdownField(
              key: _field,
              label: '选择货品',
              value: null,
              allowClear: false,
              searchable: true,
              items: items,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_field));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'generic dropdown searches every word and ranks exact before approximate labels',
    (tester) async {
      await _open(tester, const [
        UtenDropdownItem(value: 'contains', label: '不锈钢螺丝'),
        UtenDropdownItem(value: 'prefix', label: '螺丝 M3'),
        UtenDropdownItem(value: 'exact', label: '螺丝'),
        UtenDropdownItem(value: 'split', label: 'M3 不锈钢螺丝'),
        UtenDropdownItem(value: 'hidden', label: '螺丝', visible: false),
      ]);
      await tester.enterText(find.byType(TextField), '螺丝');
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_option('exact')).dy,
        lessThan(tester.getTopLeft(_option('prefix')).dy),
      );
      expect(
        tester.getTopLeft(_option('prefix')).dy,
        lessThan(tester.getTopLeft(_option('contains')).dy),
      );
      expect(_option('hidden'), findsNothing);
      await tester.enterText(find.byType(TextField), '螺丝\u3000M3');
      await tester.pumpAndSettle();
      expect(_option('prefix'), findsOneWidget);
      expect(_option('split'), findsOneWidget);
      expect(_option('exact'), findsNothing);
      expect(_option('contains'), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_option('contains')).dy,
        lessThan(tester.getTopLeft(_option('exact')).dy),
      );
    },
  );

  testWidgets('literal wildcard text stays literal in local option searches', (
    tester,
  ) async {
    await _open(tester, const [
      UtenDropdownItem(value: 'literal', label: '螺丝 M3_20%'),
      UtenDropdownItem(value: 'lookalike', label: '螺丝 M3X20A'),
    ]);
    await tester.enterText(find.byType(TextField), 'M3_20%');
    await tester.pumpAndSettle();
    expect(_option('literal'), findsOneWidget);
    expect(_option('lookalike'), findsNothing);
  });
}
