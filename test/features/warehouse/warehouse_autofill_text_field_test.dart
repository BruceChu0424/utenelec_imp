import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_autofill_text_field.dart';

void main() {
  testWidgets(
    'focus and selection retain learned warning while a text edit clears it across remount',
    (tester) async {
      final controller = UtenAutofillTextController(text: 'A-01');
      addTearDown(controller.dispose);
      Future<void> render(bool visible) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: visible
                  ? WarehouseAutofillTextField(
                      controller: controller,
                      source: '库位来自货品资料',
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      bool warning() =>
          (tester.widget<TextField>(find.byType(TextField)).decoration!
                  as UtenInputDecoration)
              .autofilled;
      await render(true);
      expect(warning(), isTrue);
      expect(find.byType(UtenFieldHintIcon), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.filled,
        isTrue,
      );
      await tester.tap(find.byType(TextField));
      controller.selection = const TextSelection.collapsed(offset: 0);
      controller.value = controller.value.copyWith(
        composing: const TextRange(start: 0, end: 1),
      );
      await tester.pump();
      expect(warning(), isTrue);
      await tester.enterText(find.byType(TextField), 'B-02');
      await tester.pump();
      expect(warning(), isFalse);
      await render(false);
      await render(true);
      expect(warning(), isFalse);
      controller.setAutomaticText('B-02');
      await tester.pump();
      expect(warning(), isTrue);
    },
  );

  testWidgets(
    'empty and saved snapshot values are never represented as learned defaults',
    (tester) async {
      for (final controller in [
        UtenAutofillTextController(),
        UtenAutofillTextController(text: 'SAVED', autofilled: false),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WarehouseAutofillTextField(
                controller: controller,
                source: '历史快照',
                enabled: false,
              ),
            ),
          ),
        );
        expect(controller.autofilled, isFalse);
        expect(find.byType(UtenFieldHintIcon), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );
}
