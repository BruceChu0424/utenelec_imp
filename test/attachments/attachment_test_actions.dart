import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_drop_target.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';

/// The visible action in the saved attachment section. Scope it to the section
/// so an unrelated page action cannot satisfy an upload permission assertion.
Finder attachmentAddFilesButton() {
  final explicit = find.descendant(
    of: find.byType(AttachmentSection),
    matching: find.widgetWithText(FilledButton, '添加文件'),
  );
  return explicit.evaluate().isNotEmpty
      ? explicit
      : find.byKey(const ValueKey('attachment-upload-dropzone'));
}

Finder pendingAttachmentAddFilesAction() {
  final button = find.byKey(const ValueKey('pending-attachment-add'));
  return button.evaluate().isNotEmpty
      ? button
      : find.byKey(const ValueKey('pending-attachment-upload-dropzone'));
}

/// Check both ways to add files: the explicit action and the drop target.
void expectAttachmentUploadAvailable(
  WidgetTester tester, {
  required bool available,
}) {
  final action = attachmentAddFilesButton();
  expect(action, available ? findsOneWidget : findsNothing);
  if (available) {
    final widget = tester.widget(action);
    expect(
      widget is FilledButton ? widget.onPressed : (widget as InkWell).onTap,
      isNotNull,
    );
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
