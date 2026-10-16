import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_review_input_cell.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
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
