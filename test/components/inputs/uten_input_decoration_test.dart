import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/required_field_decoration.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  const info = 'Enter a positive quantity. The original unit is retained.';
  const error = 'Quantity must be greater than zero.';

  testWidgets('native validation stays invalid without a bottom error row', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    final field = GlobalKey<FormFieldState<String>>();
    await tester.pumpWidget(
      _host(
        Form(
          key: form,
          child: TextFormField(
            key: field,
            initialValue: '0',
            validator: (value) => value == '2' ? null : error,
            errorBuilder: utenTextFieldErrorBuilder,
            decoration: UtenInputDecoration(
              InputDecoration(
                label: fieldLabel('Quantity', buildLightTheme(), info: info),
                suffixIcon: const Icon(Icons.inventory_2_outlined),
              ),
            ),
          ),
        ),
      ),
    );
    final before = tester.getSize(find.byType(TextFormField));
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(field.currentState!.hasError, isTrue);
    expect(field.currentState!.errorText, error);
    expect(tester.getSize(find.byType(TextFormField)), before);
    expect(find.text(error), findsNothing);
    expect(find.byType(UtenFieldHintIcon), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    expect(find.byTooltip('$error\n\n$info'), findsOneWidget);
    final decoration = tester
        .widget<InputDecorator>(find.byType(InputDecorator))
        .decoration;
    expect(decoration.error, isNull);
    expect(
      decoration.enabledBorder!.borderSide.color,
      buildLightTheme().colorScheme.error,
    );

    await tester.enterText(find.byType(TextFormField), '2');
    expect(form.currentState!.validate(), isTrue);
    await tester.pumpAndSettle();
    expect(field.currentState!.hasError, isFalse);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byTooltip(info), findsOneWidget);
    form.currentState!.reset();
    await tester.pumpAndSettle();
    expect(field.currentState!.value, '0');
    expect(field.currentState!.hasError, isFalse);
  });

  testWidgets('short hints reveal identical text by hover tap and focus', (
    tester,
  ) async {
    Future<void> mount() => tester.pumpWidget(
      _host(const UtenInput(label: 'Quantity', info: info)),
    );
    await mount();
    expect(find.text(info), findsNothing);
    final hint = find.byType(UtenFieldHintIcon);
    final fieldRect = tester.getRect(find.byType(TextFormField));
    expect(fieldRect.contains(tester.getCenter(hint)), isTrue);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(hint));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(info), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await mount();
    await tester.tap(hint);
    await tester.pump();
    expect(find.text(info), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount();
    final button = tester.widget<IconButton>(
      find.descendant(of: hint, matching: find.byType(IconButton)),
    );
    button.focusNode!.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(find.text(info), findsOneWidget);
  });

  testWidgets(
    'warning help never opens the dropdown and selection still works',
    (tester) async {
      String? selected = 'usd';
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => UtenDropdownField(
              label: 'Currency',
              value: selected,
              autofilled: true,
              info: info,
              items: const [
                UtenDropdownItem(value: 'usd', label: 'USD'),
                UtenDropdownItem(value: 'cny', label: 'CNY'),
              ],
              onChanged: (value) => setState(() => selected = value),
            ),
          ),
        ),
      );
      const warning = '已按上次记录预填，请核对';
      expect(find.text(warning), findsNothing);
      await tester.tap(find.byIcon(Icons.warning_amber_rounded));
      await tester.pump();
      expect(find.text('$warning\n\n$info'), findsOneWidget);
      expect(find.text('CNY'), findsNothing);
      await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CNY'));
      await tester.pumpAndSettle();
      expect(selected, 'cny');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('date help remains available while editing is disabled', (
    tester,
  ) async {
    var changed = false;
    await tester.pumpWidget(
      _host(
        UtenDateField(
          label: 'Delivery date',
          value: DateTime(2026, 9, 5),
          enabled: false,
          info: info,
          onChanged: (_) => changed = true,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pump();
    expect(find.text(info), findsOneWidget);
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(changed, isFalse);
  });

  testWidgets(
    'error keeps full live semantics and password action remains usable',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const UtenInput(
            label: 'Password',
            info: info,
            errorMessage: error,
            isPassword: true,
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.liveRegion == true &&
              widget.properties.label == '$error\n\n$info',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    },
  );

  testWidgets(
    'dense detail cell keeps its value and error icon within its row',
    (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            height: 40,
            child: TextField(
              decoration: UtenInputDecoration(
                InputDecoration(
                  isDense: true,
                  hintText: '0',
                  error: UtenFieldMessage.error(error),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                ),
              ),
            ),
          ),
          width: 80,
        ),
      );
      expect(tester.takeException(), isNull);
      final bounds = tester.getRect(find.byType(TextField));
      final icon = tester.getRect(find.byType(UtenFieldHintIcon));
      expect(icon.top, greaterThanOrEqualTo(bounds.top));
      expect(icon.bottom, lessThanOrEqualTo(bounds.bottom));
      expect(icon.right, lessThanOrEqualTo(bounds.right));
      expect(find.text('0'), findsOneWidget);
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pump();
      expect(find.text(error), findsOneWidget);
    },
  );
  for (final dark in [false, true]) {
    testWidgets('narrow large-text field keeps its icon inside (dark=$dark)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          UtenDropdownField(
            label: 'Warehouse',
            info: '$info $info $info',
            errorMessage: error,
            value: 'w1',
            items: const [
              UtenDropdownItem(value: 'w1', label: 'Main warehouse'),
            ],
            onChanged: (_) {},
          ),
          width: 140,
          dark: dark,
          scale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(InputDecorator));
      expect(
        rect.contains(tester.getCenter(find.byType(UtenFieldHintIcon))),
        isTrue,
      );
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pumpAndSettle();
      expect(find.text('$error\n\n$info $info $info'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _host(
  Widget child, {
  double width = 320,
  bool dark = false,
  double scale = 1,
}) {
  return MaterialApp(
    theme: dark ? buildDarkTheme() : buildLightTheme(),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}
