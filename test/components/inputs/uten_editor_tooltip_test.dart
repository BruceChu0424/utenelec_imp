import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/widgets/production_overproduction_rate_field.dart';
import 'package:uten_imp/components/inputs/uten_editor_tooltip.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_hints.dart';

void main() {
  for (final customEditor in [false, true]) {
    testWidgets(
      'quiet table hints retain native input and focus: custom=$customEditor',
      (tester) async {
        final text = TextEditingController();
        final focus = FocusNode();
        final message = ValueNotifier('参考重量');
        final changes = <String>[];
        addTearDown(text.dispose);
        addTearDown(focus.dispose);
        addTearDown(message.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UtenTableCellHints(
                child: ValueListenableBuilder<String>(
                  valueListenable: message,
                  builder: (_, hint, _) => UtenEditorTooltip(
                    message: hint,
                    child: customEditor
                        ? ProductionOverproductionRateField(
                            key: const Key('native-editor'),
                            controller: text,
                            onChanged: changes.add,
                          )
                        : TextField(
                            key: const Key('native-editor'),
                            controller: text,
                            focusNode: focus,
                            onChanged: changes.add,
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        final editable = find.byType(EditableText);
        final fieldElement = tester.element(field);
        final inputState = tester.state<EditableTextState>(editable);
        await tester.enterText(field, '12.5');
        await tester.pumpAndSettle();
        expect(text.text, '12.5');
        expect(changes, ['12.5']);
        expect(tester.element(field), same(fieldElement));
        expect(tester.state<EditableTextState>(editable), same(inputState));
        expect(
          tester.widget<EditableText>(editable).focusNode.hasFocus,
          isTrue,
        );
        for (final hint in ['', '新的参考重量']) {
          message.value = hint;
          await tester.pumpAndSettle();
          expect(tester.element(field), same(fieldElement));
          expect(tester.state<EditableTextState>(editable), same(inputState));
          expect(
            tester.widget<EditableText>(editable).focusNode.hasFocus,
            isTrue,
          );
          expect(text.text, '12.5');
        }
        await tester.enterText(field, '850g');
        await tester.pumpAndSettle();
        expect(changes, ['12.5', '850g']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
