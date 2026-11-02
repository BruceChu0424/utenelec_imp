import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';

/// Open the actual compact search popup before entering text.
Future<Finder> showUtenTestSearchInput(WidgetTester tester, Finder bar) async {
  expect(bar, findsOneWidget);
  final input = find.descendant(of: bar, matching: find.byType(TextField));
  if (input.evaluate().isEmpty) {
    final hint = tester.widget<UtenSearchBar>(bar).hint;
    final trigger = find.descendant(
      of: bar,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            (widget.tooltip == hint ||
                widget.tooltip?.startsWith('$hint：') == true),
      ),
    );
    expect(trigger, findsOneWidget);
    await tester.ensureVisible(trigger);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
  }
  expect(input, findsOneWidget);
  await tester.ensureVisible(input);
  await tester.pumpAndSettle();
  expect(input.hitTestable(), findsOneWidget);
  return input;
}
