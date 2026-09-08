import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/required_field_decoration.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/shared/widgets/procurement_commercial_grid.dart';
import 'package:uten_imp/shared/widgets/procurement_supplier_cell.dart';

void main() {
  const message = '已自动带出上次记录或默认值，请核对后使用';

  for (final dark in [false, true]) {
    testWidgets('autofill has an in-field hint and tint in dark=$dark', (
      tester,
    ) async {
      final theme = dark ? buildDarkTheme() : buildLightTheme();
      final controller = TextEditingController(text: '1.2345');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 48,
                child: TextField(
                  controller: controller,
                  decoration: applyAutofillHint(
                    const InputDecoration(isDense: true),
                    theme,
                    autofilled: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(UtenFieldHintIcon), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      final decoration = tester
          .widget<InputDecorator>(find.byType(InputDecorator))
          .decoration;
      expect(decoration.filled, isTrue);
      expect(decoration.fillColor, isNot(theme.colorScheme.surface));
      expect(decoration.enabledBorder!.borderSide.color, UtenColors.warning);
      expect(decoration.helper, isNull);
      expect(find.text(message), findsNothing);
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pump();
      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('record switches update the controller and required state', (
    tester,
  ) async {
    final first = TextEditingController(text: 'Previous record');
    final next = TextEditingController();
    addTearDown(first.dispose);
    addTearDown(next.dispose);
    Future<void> mount(TextEditingController controller, bool autofilled) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UtenInput(
                controller: controller,
                required: true,
                autofilled: autofilled,
              ),
            ),
          ),
        );
    await mount(first, true);
    expect(find.byType(UtenFieldHintIcon), findsOneWidget);
    await mount(next, false);
    expect(find.text('Previous record'), findsNothing);
    expect(find.byType(UtenFieldHintIcon), findsNothing);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller,
      next,
    );
    await tester.enterText(find.byType(TextFormField), 'New record');
    expect(next.text, 'New record');
    expect(first.text, 'Previous record');
    await tester.pumpWidget(const SizedBox.shrink());
    // External controllers remain owned by the parent.
    first.text = 'Still usable';
    next.text = 'Still usable';
    expect(tester.takeException(), isNull);
  });

  testWidgets('commercial pickers disclose defaults without changing values', (
    tester,
  ) async {
    var picks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 220,
                child: ProcurementSupplierCell(
                  value: 'supplier',
                  entries: const {'supplier': 'Supplier'},
                  autofilled: true,
                  onPick: () async {
                    picks++;
                  },
                ),
              ),
              SizedBox(
                width: 160,
                child: ProcurementTermDropdownCell(
                  value: 'currency',
                  entries: const {'currency': 'CNY'},
                  autofilled: true,
                  onChanged: (_) {
                    picks++;
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(UtenFieldHintIcon), findsNWidgets(2));
    await tester.tap(find.byType(UtenFieldHintIcon).first);
    await tester.pump();
    expect(picks, 0);
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('errors and explicit descriptions survive wrapping and defaults', () {
    final theme = buildLightTheme();
    final decorated =
        applyAutofillHint(
              const UtenInputDecoration(
                InputDecoration(),
                info: 'Field context',
              ),
              theme,
              autofilled: true,
            )
            .copyWith(errorText: 'Invalid value')
            .applyDefaults(theme.inputDecorationTheme);
    expect(decorated, isA<UtenInputDecoration>());
    expect(decorated.enabledBorder!.borderSide.color, theme.colorScheme.error);
    final hint = decorated.suffixIcon! as UtenFieldHintIcon;
    expect(hint.autofilled, isTrue);
    expect(hint.info, 'Field context');
    expect(hint.errorMessage, 'Invalid value');
  });
}
