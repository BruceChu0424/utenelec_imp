import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_review_input_cell.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  for (final inTable in [false, true]) {
    for (final decimalValues in [true, false]) {
      for (final labeled in [false, true]) {
        testWidgets(
          '${inTable ? "table" : "form"} ${decimalValues ? "decimal" : "text"} ${labeled ? "labeled" : "compact"} review keeps the editor mounted across changes and restoration',
          (tester) async {
            final original = decimalValues ? 'AB' : '001';
            final values = decimalValues
                ? ['ABC', 'ABCD', 'AB', 'ABX']
                : ['1', '10', '001', '001 '];
            final controller = TextEditingController(text: original);
            addTearDown(controller.dispose);
            const beforeKey = ValueKey('retained-original');
            final edited = <String>[];
            Widget editor = ListenableBuilder(
              listenable: controller,
              builder: (context, _) => UtenReviewInputCell(
                before: original,
                after: controller.text,
                beforeKey: beforeKey,
                decimalValues: decimalValues,
                showValueLabels: labeled,
                child: UtenInput(controller: controller, onChanged: edited.add),
              ),
            );
            if (inTable) editor = UtenTableCellInputTheme(child: editor);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildLightTheme().copyWith(
                  platform: TargetPlatform.windows,
                ),
                home: Scaffold(body: SizedBox(width: 360, child: editor)),
              ),
            );
            await tester.tap(find.byType(TextField));
            await tester.pump();
            final inputState = tester.state(find.byType(UtenInput));
            final textFieldState = tester.state(find.byType(TextField));
            final editableState = tester.state<EditableTextState>(
              find.byType(EditableText),
            );
            final focus = editableState.widget.focusNode;
            expect(focus.hasFocus, isTrue);
            expect(find.byKey(beforeKey), findsNothing);

            for (final value in values) {
              final selection = TextSelection.collapsed(offset: value.length);
              final composing = TextRange(
                start: value.length - 1,
                end: value.length,
              );
              tester.testTextInput.updateEditingValue(
                TextEditingValue(
                  text: value,
                  selection: selection,
                  composing: composing,
                ),
              );
              await tester.pump();
              expect(controller.text, value);
              expect(controller.selection, selection);
              expect(controller.value.composing, composing);
              expect(tester.state(find.byType(UtenInput)), same(inputState));
              expect(
                tester.state(find.byType(TextField)),
                same(textFieldState),
              );
              expect(
                tester.state(find.byType(EditableText)),
                same(editableState),
              );
              expect(editableState.widget.controller, same(controller));
              expect(editableState.widget.focusNode, same(focus));
              expect(focus.hasFocus, isTrue);
              expect(tester.testTextInput.isVisible, isTrue);
              expect(
                find.byKey(beforeKey),
                value == original ? findsNothing : findsOneWidget,
              );
              if (value != original) {
                expect(
                  tester.widget<Text>(find.byKey(beforeKey)).style?.decoration,
                  TextDecoration.lineThrough,
                );
              }
              expect(tester.takeException(), isNull);
            }
            expect(edited, values);
          },
        );
      }
    }
  }

  testWidgets('text review treats missing and empty values as the same blank', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UtenReviewInputCell(
            before: null,
            after: '',
            decimalValues: false,
            beforeKey: ValueKey('empty-original'),
            child: Text('replacement'),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('empty-original')), findsNothing);
  });

  testWidgets(
    'review input keeps the original with a red strike and treats equal numeric scales as unchanged',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenReviewInputCell(
              before: '1.000',
              after: '2',
              child: Text('replacement'),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.text('1.000')).style!.decoration,
        TextDecoration.lineThrough,
      );
      expect(find.text('replacement'), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenReviewInputCell(
              before: '1.000',
              after: '1',
              child: Text('same'),
            ),
          ),
        ),
      );
      expect(find.text('1.000'), findsNothing);
      expect(find.text('same'), findsOneWidget);
    },
  );

  testWidgets(
    'amended table values keep a compact editable row and full original disclosure',
    (tester) async {
      final controller = TextEditingController(text: '2');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: UtenTableCellInputTheme(
              child: IntrinsicHeight(
                child: SizedBox(
                  width: 180,
                  child: UtenReviewInputCell(
                    key: const ValueKey('review-cell'),
                    before: '123456789.123456',
                    after: '2',
                    child: TextField(controller: controller),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('review-cell'))).height,
        32,
      );
      expect(find.byTooltip('123456789.123456'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('123456789.123456')).style!.decoration,
        TextDecoration.lineThrough,
      );
      await tester.enterText(find.byType(TextField), '3.25');
      expect(controller.text, '3.25');
      expect(tester.takeException(), isNull);
    },
  );
}
