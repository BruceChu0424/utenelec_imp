import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/shared/report/report_total.dart';

void main() {
  testWidgets(
    'report timestamp remains visible while snapshot guidance is inline',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: reportTotalsBar(
                const [],
                statisticsGeneratedAt: '2026-10-28T00:00:00Z',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final timestamp = find.textContaining('统计生成于');
      const message = '翻页保留当前统计快照，刷新时重新统计。';
      expect(timestamp, findsOneWidget);
      expect(find.text(message), findsNothing);
      final textRect = tester.getRect(timestamp);
      final iconRect = tester.getRect(find.byType(UtenFieldHintIcon));
      expect((textRect.center.dy - iconRect.center.dy).abs(), lessThan(2));
      expect(iconRect.height, 24);
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(timestamp, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
