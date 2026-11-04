import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';

Finder financeInput(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenInput && widget.label == label,
);
Finder financeTextField(String label) => find
    .descendant(of: financeInput(label), matching: find.byType(TextField))
    .first;
Future<void> tapFinanceAction(WidgetTester tester, String label) async {
  var action = find.text(label).hitTestable();
  if (action.evaluate().isEmpty) {
    final menu = find.byTooltip('表格操作').hitTestable();
    if (menu.evaluate().isNotEmpty) {
      await tester.tap(menu.first);
      await tester.pumpAndSettle();
      action = find.text(label).hitTestable();
    }
  }
  if (action.evaluate().isEmpty) {
    debugPrint(
      'Missing finance action $label; tooltips=${tester.widgetList<Tooltip>(find.byType(Tooltip)).map((widget) => widget.message).toList()}; texts=${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().take(50).toList()}',
    );
  }
  await tester.tap(action.last);
  await tester.pumpAndSettle();
}
