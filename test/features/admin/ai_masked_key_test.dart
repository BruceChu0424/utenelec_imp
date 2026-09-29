// 密钥尾号掩码紧凑显示: 「••••k7Qp」的圆点画成紧凑小点(应用字体里「•」是全角, 连写会变成
// 「• • • •」), 读屏仍读掩码原文; 不以圆点开头的掩码原样显示。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/widgets/ai_masked_key.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('dots are drawn compactly next to the tail', (tester) async {
    const style = TextStyle(fontSize: 20);
    await _pump(tester, const AiMaskedKey('••••k7Qp', style: style));

    final dots = find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle,
    );
    expect(dots, findsNWidgets(4));
    // 4 个全角圆点要占 4 个字宽; 紧凑显示的整串圆点不到 2 个字宽。
    final first = tester.getTopLeft(dots.first).dx;
    final last = tester.getTopRight(dots.last).dx;
    expect(last - first, lessThan(2 * 20));
    // 尾号是普通文字, 圆点没有变成「•」字符。
    final rich = tester.widget<Text>(find.byType(Text)).textSpan!;
    expect(rich.toPlainText(), isNot(contains('•')));
    expect(rich.toPlainText(), endsWith('k7Qp'));
    // 读屏读掩码原文。
    expect(find.bySemanticsLabel('••••k7Qp'), findsOneWidget);
  });

  testWidgets('a mask without leading dots is shown as is', (tester) async {
    await _pump(tester, const AiMaskedKey('已配置'));
    expect(find.text('已配置'), findsOneWidget);
    expect(find.byType(DecoratedBox), findsNothing);
  });
}
