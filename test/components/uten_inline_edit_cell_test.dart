import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_inline_edit_cell.dart';

void main() {
  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('keyboard $key activates only the focused editor', (
      tester,
    ) async {
      final controllers = List.generate(2, (_) => TextEditingController());
      final focuses = List.generate(2, (_) => FocusNode());
      addTearDown(() {
        for (final controller in controllers) {
          controller.dispose();
        }
        for (final focus in focuses) {
          focus.dispose();
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < 2; i++)
                  SizedBox(
                    width: 240,
                    child: UtenInlineEditCell(
                      key: ValueKey(i),
                      semanticLabel: 'Edit $i',
                      preview: Text('Value $i'),
                      editorBuilder: (_) => TextField(
                        controller: controllers[i],
                        focusNode: focuses[i],
                        autofocus: true,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(focuses.first.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(focuses.first.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'preview refresh and temporary read-only state retain the mounted editor and IME',
    (tester) async {
      final revision = ValueNotifier(0);
      final enabled = ValueNotifier(true);
      final text = TextEditingController();
      final focus = FocusNode();
      addTearDown(revision.dispose);
      addTearDown(enabled.dispose);
      addTearDown(text.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              child: ListenableBuilder(
                listenable: Listenable.merge([revision, enabled]),
                builder: (_, _) => UtenInlineEditCell(
                  key: const ValueKey('same-cell'),
                  semanticLabel: 'Edit value',
                  preview: Text('Snapshot ${revision.value}'),
                  enabled: enabled.value,
                  retainFocusWhenDisabled: true,
                  editorBuilder: (_) => TextField(
                    controller: text,
                    focusNode: focus,
                    autofocus: true,
                    readOnly: !enabled.value,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Snapshot 0'));
      await tester.pump();
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      const input = TextEditingValue(
        text: '拼音 ',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 2, end: 3),
      );
      tester.testTextInput.updateEditingValue(input);
      await tester.pump();
      revision.value++;
      enabled.value = false;
      await tester.pump();
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(state),
      );
      expect(focus.hasFocus, isTrue);
      expect(text.value, input);
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      enabled.value = true;
      await tester.pump();
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(state),
      );
      expect(focus.hasFocus, isTrue);
      expect(text.value, input);
      expect(tester.takeException(), isNull);
    },
  );
}
