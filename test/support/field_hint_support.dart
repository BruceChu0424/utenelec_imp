import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercise the shared disclosure, rather than assuming guidance is permanent text.
Future<void> readFieldHint(WidgetTester tester, String message) async {
  final hints = find.byWidgetPredicate(
    (widget) =>
        widget is Tooltip && (widget.message?.contains(message) ?? false),
  );
  expect(hints, findsWidgets);
  await tester.ensureVisible(hints.first);
  await tester.tap(hints.first);
  await tester.pumpAndSettle();
  expect(find.textContaining(message), findsWidgets);
  Tooltip.dismissAllToolTips();
  await tester.pumpAndSettle();
}
