import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';

void main() {
  testWidgets('inline notice renders title, message and level icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UtenInlineNotice(
            level: UtenInlineNoticeLevel.error,
            title: '货品已入库，需到对应储放区域检查',
            message: '本单 2 行已先入库上架：原料仓 / A-01；原料仓 / B-02。',
          ),
        ),
      ),
    );
    expect(find.text('货品已入库，需到对应储放区域检查'), findsOneWidget);
    expect(find.textContaining('A-01'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);

    // 无标题 + info 档：只有正文与信息图标。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: UtenInlineNotice(message: '只落位置，不改库存')),
      ),
    );
    expect(find.text('只落位置，不改库存'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
  });
}
