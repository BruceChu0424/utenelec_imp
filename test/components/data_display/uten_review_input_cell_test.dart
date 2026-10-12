import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_review_input_cell.dart';

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
}
