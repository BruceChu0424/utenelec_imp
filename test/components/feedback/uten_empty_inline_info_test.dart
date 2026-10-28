import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_empty.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';

void main() {
  testWidgets(
    'empty info shares its existing narrow large-text title and leaves recovery visible',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: Size(320, 700),
                textScaler: TextScaler.linear(2),
              ),
              child: SizedBox(
                width: 280,
                child: UtenEmpty(
                  message: '当前没有可入库明细',
                  description: '任务状态已变化，请刷新。',
                  info: '此处仅说明当前可办理范围。',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前没有可入库明细'), findsOneWidget);
      expect(find.text('任务状态已变化，请刷新。'), findsOneWidget);
      expect(find.text('此处仅说明当前可办理范围。'), findsNothing);
      final hint = find.byType(UtenFieldHintIcon);
      expect(
        (tester.getCenter(hint).dy -
                tester.getCenter(find.text('当前没有可入库明细')).dy)
            .abs(),
        lessThan(1),
      );
      await tester.tap(hint);
      await tester.pumpAndSettle();
      expect(find.text('此处仅说明当前可办理范围。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'ordinary error description and retry stay directly visible without a help slot',
    (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenEmpty.error(
              message: '加载失败',
              description: '权限已变化，请重新读取。',
              actionLabel: '重试',
              onAction: () => retries++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('权限已变化，请重新读取。'), findsOneWidget);
      expect(find.byType(UtenFieldHintIcon), findsNothing);
      await tester.tap(find.text('重试'));
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
