import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/widgets/production_overproduction_rate_field.dart';

void main() {
  testWidgets(
    'permanent reading preserves exact percent text without an editor',
    (tester) async {
      final controller = TextEditingController(text: '12.3400');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProductionOverproductionRateField(
              controller: controller,
              enabled: false,
              readOnlyPresentation: true,
            ),
          ),
        ),
      );
      expect(find.byType(EditableText), findsNothing);
      expect(find.text('12.3400%'), findsOneWidget);
      controller.text = '0.0100';
      await tester.pump();
      expect(find.text('0.0100%'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
    },
  );

  testWidgets('transient disabling keeps the live input and exact raw value', (
    tester,
  ) async {
    final controller = TextEditingController(text: '1.2300');
    addTearDown(controller.dispose);
    Widget frame(bool enabled) => MaterialApp(
      home: Scaffold(
        body: ProductionOverproductionRateField(
          controller: controller,
          enabled: enabled,
        ),
      ),
    );
    await tester.pumpWidget(frame(true));
    final editor = tester.element(find.byType(EditableText));
    controller.value = const TextEditingValue(
      text: '1.2300',
      selection: TextSelection.collapsed(offset: 6),
    );
    await tester.pumpWidget(frame(false));
    expect(tester.element(find.byType(EditableText)), same(editor));
    expect(
      controller.value.selection,
      const TextSelection.collapsed(offset: 6),
    );
    expect(controller.text, '1.2300');
  });
}
