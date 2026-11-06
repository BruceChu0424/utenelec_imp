import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';

/// Select through the project dropdown's real menu, including horizontal scroll.
Future<void> selectMaterialOrderMethod(
  WidgetTester tester,
  Finder field,
  String method, {
  bool settle = true,
}) async {
  final dropdown = tester.widget<UtenDropdownField>(field);
  final label = dropdown.items
      .singleWhere((item) => item.value == method)
      .label;
  await Scrollable.ensureVisible(tester.element(field), alignment: 0.6);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  if (settle) await tester.pumpAndSettle();
}
