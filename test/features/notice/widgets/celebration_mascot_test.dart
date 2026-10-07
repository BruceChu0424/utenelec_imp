// CelebrationMascot 兜底契约（ADR-166 附带核实）：
// assets/celebration/ 的「小优」美术是占位（磁盘缺失、目录为空），widget 必须经
// Image.errorBuilder 安全回落 UtenBrandMascot(logo_ip.png)——不灰屏、不抛异常。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/brand/uten_brand_mascot.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/widgets/celebration_mascot.dart';

void main() {
  testWidgets(
    'missing celebration art falls back to the brand IP mascot without crashing',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: CelebrationMascot(type: NoticeType.birthday)),
          ),
        ),
      );
      // 异步资源加载失败 → errorBuilder 触发；等待帧稳定后无异常、回落件在树内。
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(CelebrationMascot), findsOneWidget);
      expect(find.byType(UtenBrandMascot), findsOneWidget);
    },
  );

  testWidgets('non-celebratory types render without crashing too', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CelebrationMascot(type: NoticeType.task, size: 96),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(CelebrationMascot), findsOneWidget);
  });
}
