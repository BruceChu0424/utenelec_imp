import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  const info = 'This value is controlled by the current order.';
  const error = 'The current value requires review.';

  testWidgets(
    'disabled UtenInput keeps label-free help and blocks password edits',
    (tester) async {
      var enabled = false;
      late StateSetter update;
      final controller = TextEditingController(text: 'secret');
      final inputFocus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(inputFocus.dispose);
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return UtenInput(
                controller: controller,
                focusNode: inputFocus,
                enabled: enabled,
                isPassword: true,
                info: info,
              );
            },
          ),
        ),
      );

      final hint = find.byType(UtenFieldHintIcon);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(hint));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(info), findsOneWidget);
      await mouse.removePointer();
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();
      await tester.tap(hint);
      await tester.pump();
      expect(find.text(info), findsOneWidget);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isFalse);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).readOnly,
        isTrue,
      );
      inputFocus.requestFocus();
      await tester.pump();
      expect(inputFocus.hasFocus, isFalse);
      await tester.tap(
        find.byIcon(Icons.visibility_outlined),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );
      expect(controller.text, 'secret');

      update(() => enabled = true);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
      await tester.enterText(find.byType(TextFormField), 'changed');
      expect(controller.text, 'changed');
    },
  );

  for (final formField in [false, true]) {
    testWidgets(
      'disabled native field keeps error help and isolates business icons '
      '(form=$formField)',
      (tester) async {
        var enabled = false;
        var prefixActions = 0;
        var suffixActions = 0;
        late StateSetter update;
        final controller = TextEditingController(text: 'original');
        final inputFocus = FocusNode();
        final prefixFocus = FocusNode();
        final suffixFocus = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(inputFocus.dispose);
        addTearDown(prefixFocus.dispose);
        addTearDown(suffixFocus.dispose);
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                final decoration = UtenInputDecoration(
                  InputDecoration(
                    error: const UtenFieldMessage.error(error),
                    prefixIcon: IconButton(
                      focusNode: prefixFocus,
                      onPressed: () => prefixActions++,
                      icon: const Icon(Icons.add),
                    ),
                    suffixIcon: IconButton(
                      focusNode: suffixFocus,
                      onPressed: () => suffixActions++,
                      icon: const Icon(Icons.clear),
                    ),
                  ),
                  info: info,
                );
                return formField
                    ? TextFormField(
                        controller: controller,
                        focusNode: inputFocus,
                        enabled: enabled,
                        ignorePointers: false,
                        errorBuilder: utenTextFieldErrorBuilder,
                        decoration: decoration,
                      )
                    : TextField(
                        controller: controller,
                        focusNode: inputFocus,
                        enabled: enabled,
                        ignorePointers: false,
                        decoration: decoration,
                      );
              },
            ),
          ),
        );

        expect(
          tester.widget<EditableText>(find.byType(EditableText)).readOnly,
          isTrue,
        );
        inputFocus.requestFocus();
        await tester.pump();
        expect(inputFocus.hasFocus, isFalse);
        prefixFocus.requestFocus();
        suffixFocus.requestFocus();
        await tester.pump();
        expect(prefixFocus.hasFocus, isFalse);
        expect(suffixFocus.hasFocus, isFalse);
        await tester.tap(find.byIcon(Icons.add), warnIfMissed: false);
        await tester.tap(find.byIcon(Icons.clear), warnIfMissed: false);
        await tester.pump();
        expect(prefixActions, 0);
        expect(suffixActions, 0);
        expect(controller.text, 'original');
        await tester.tap(find.byType(UtenFieldHintIcon));
        await tester.pump();
        expect(find.text('$error\n\n$info'), findsOneWidget);

        update(() => enabled = true);
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.add));
        await tester.tap(find.byIcon(Icons.clear));
        expect(prefixActions, 1);
        expect(suffixActions, 1);
        await tester.enterText(find.byType(TextField), 'updated');
        expect(controller.text, 'updated');
      },
    );
  }
}

Widget _host(Widget child) => MaterialApp(
  theme: buildLightTheme(),
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);
