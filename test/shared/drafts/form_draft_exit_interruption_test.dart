import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

import 'form_draft_mixin_test.dart'
    show MemoryDraftStorage, TestEditor, TestEditorState, pumpEditor;

void main() {
  testWidgets(
    'hard disposal during explicit exit releases wait and retains the exact draft',
    (tester) async {
      final storage = MemoryDraftStorage();
      var env = await pumpEditor(tester, storage);
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      editor.text.text = '原草稿';
      await editor.saveFormDraftNow();
      editor.text.text = '中断前原输入 0004.';
      final gate = Completer<void>();
      storage.writeGate = gate.future;
      final permit = editor.saveFormDraftBeforeExit();
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete();
      expect(await permit, isFalse);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      final retained = env.container.read(formDraftsProvider).single;
      expect(retained.data['text'], '中断前原输入 0004.');
      env.router.dispose();
      env.container.dispose();
      storage.writeGate = null;
      env = await pumpEditor(tester, storage, initial: retained.resumeLocation);
      expect(
        tester.state<TestEditorState>(find.byType(TestEditor)).text.text,
        '中断前原输入 0004.',
      );
      expect(find.byType(UtenBusyOverlay), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );
}
