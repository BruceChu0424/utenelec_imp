import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_confirmation_summary.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';

void main() {
  testWidgets(
    'confirmation facts disclose routine guidance inline and keep actual risks visible',
    (tester) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const help = '正常流程说明仅在提示内查看';
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: UtenConfirmationSummary(
                facts: [
                  UtenConfirmationFact(
                    label: '本次登记',
                    value: '7 行 · 2 个仓库',
                    info: help,
                  ),
                ],
                consequences: ['有 2 行未勾选，仍留待登记。'],
              ),
            ),
          ),
        ),
      );
      expect(
        find.textContaining('7 行 · 2 个仓库', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('有 2 行未勾选，仍留待登记。'), findsOneWidget);
      expect(find.text(help), findsNothing);
      expect(find.byType(UtenFieldHintIcon), findsOneWidget);
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pumpAndSettle();
      expect(find.text(help), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'plain text preserves fact help and actual consequences for frozen confirmation evidence',
    () {
      const summary = UtenConfirmationSummary(
        facts: [
          UtenConfirmationFact(
            label: '本次追加',
            value: '1.0001 公斤',
            info: '只增加额度，仓库仍须实际发料。',
          ),
        ],
        consequences: ['本次包含已隐藏的 2 行。'],
      );
      expect(
        summary.plainText,
        '本次追加 1.0001 公斤\n只增加额度，仓库仍须实际发料。\n本次包含已隐藏的 2 行。',
      );
      expect(
        const UtenConfirmationSummary(
          facts: [UtenConfirmationFact(label: '日报', value: 'RB-1')],
        ).plainText,
        '日报 RB-1',
      );
    },
  );
}
