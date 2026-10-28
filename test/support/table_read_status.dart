import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/table_read_status_text.dart';

/// Opens the user's bounded read notice and verifies the complete server reason.
Future<void> expectTableReadFailureDetails(
  WidgetTester tester,
  String reason, {
  String keyPrefix = 'master-table-initial-read',
}) async {
  final details = find.byKey(ValueKey('$keyPrefix-details'));
  expect(details, findsOneWidget);
  final closeLabel = tableReadStatusText(tester.element(details), 'close');
  await tester.ensureVisible(details);
  await tester.tap(details);
  await tester.pumpAndSettle();
  expect(find.text(reason), findsOneWidget);
  final dialog = find.ancestor(
    of: find.text(reason),
    matching: find.byType(UtenAlertDialog),
  );
  expect(dialog, findsOneWidget);
  final close = find.descendant(of: dialog, matching: find.text(closeLabel));
  await tester.ensureVisible(close);
  await tester.tap(close);
  await tester.pumpAndSettle();
}
