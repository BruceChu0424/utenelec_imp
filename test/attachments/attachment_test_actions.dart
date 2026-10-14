import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_drop_target.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';

/// The visible action in the saved attachment section. Scope it to the section
/// so an unrelated page action cannot satisfy an upload permission assertion.
Finder attachmentAddFilesButton() => find.descendant(
  of: find.byType(AttachmentSection),
  matching: find.widgetWithText(FilledButton, '添加文件'),
);

/// Check both ways to add files: the explicit action and the drop target.
void expectAttachmentUploadAvailable(
  WidgetTester tester, {
  required bool available,
}) {
  final action = attachmentAddFilesButton();
  expect(action, available ? findsOneWidget : findsNothing);
  if (available) {
    expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
  }
  final dropTargets = find.descendant(
    of: find.byType(AttachmentSection),
    matching: find.byType(UtenDropTarget),
  );
  if (available) expect(dropTargets, findsOneWidget);
  for (final target in tester.widgetList<UtenDropTarget>(dropTargets)) {
    expect(target.enabled, available);
  }
}
