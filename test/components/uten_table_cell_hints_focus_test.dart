import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_hints.dart';

class _HintEditor extends StatefulWidget {
  const _HintEditor({required this.controller, required this.focusChanges});
  final TextEditingController controller;
  final List<bool> focusChanges;
  @override
  State<_HintEditor> createState() => _HintEditorState();
}

class _HintEditorState extends State<_HintEditor> {
  bool _prefilled = true;
  @override
  Widget build(BuildContext context) => UtenTableCellHints(
    child: Focus(
      onFocusChange: widget.focusChanges.add,
      child: TextField(
        controller: widget.controller,
        onChanged: (_) => setState(() => _prefilled = false),
        decoration: UtenInputDecoration(InputDecoration(
          helper: _prefilled ? const UtenFieldMessage.autofill('系统建议数量，请核对') : null,
        ), autofilled: _prefilled),
      ),
    ),
  );
}

void main() {
  testWidgets('removing the last table hint preserves the active editor and delivers blur', (tester) async {
    final controller = TextEditingController(text: '6');
    addTearDown(controller.dispose);
    final focusChanges = <bool>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
      width: 260, child: _HintEditor(controller: controller, focusChanges: focusChanges)))));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final original = tester.state<EditableTextState>(find.byType(EditableText));
    expect(original.widget.focusNode.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), '2');
    await tester.pumpAndSettle();
    expect(tester.state<EditableTextState>(find.byType(EditableText)), same(original),
      reason: 'Changing table guidance must not recreate the editable field.');
    expect(original.widget.focusNode.hasFocus, isTrue);
    expect(controller.text, '2');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(focusChanges, [true, false],
      reason: 'Allocation editing mode relies on the real blur notification.');
    expect(tester.takeException(), isNull);
  });
}
