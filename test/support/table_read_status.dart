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
  // 真失败的消息尾部带匿名关联号（read_failure_diagnostics）；服务端消息
  // 始终是结尾段，其余细节保持精确。
  final reasonText = find.textContaining(
    RegExp('${RegExp.escape(reason)}(（关联号 [0-9A-Z]{6}）)?\$'),
  );
  expect(reasonText, findsOneWidget);
  final dialog = find.ancestor(
    of: reasonText,
    matching: find.byType(UtenAlertDialog),
  );
  expect(dialog, findsOneWidget);
  final close = find.descendant(
    of: dialog,
    matching: find.byTooltip(closeLabel),
  );
  expect(close, findsOneWidget);
  await tester.ensureVisible(close);
  await tester.tap(close);
  await tester.pumpAndSettle();
}
