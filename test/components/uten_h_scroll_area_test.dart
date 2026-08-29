// UtenHScrollArea 横向滚动条位置行为回归：
// - 内容少（不超视口高）：横滚条紧贴内容底边（滑块上缘约 1px 空隙）；
// - 内容多（超视口高）：横滚条钉在视口底部，不随内容沉底。
// 与两张表格组件（UtenEditableGrid / MasterDataTableView）同款规格，三处行为一致。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_h_scroll_area.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: ListView(children: [child])),
);

void main() {
  testWidgets('内容少：横滚条在内容底边下方且隔 11（滑块上缘约 1px）', (tester) async {
    await tester.pumpWidget(
      _wrap(const UtenHScrollArea(child: SizedBox(width: 1200, height: 200))),
    );

    final bars = find.byType(Scrollbar);
    expect(bars.evaluate().length, 1, reason: '内容不超高时只有自然滚动条（钉底条 Offstage）');
    final barBox = tester.renderObject(bars) as RenderBox;
    final barBottom = barBox.localToGlobal(Offset.zero).dy + barBox.size.height;

    final contentBox =
        tester.renderObject(find.byType(UtenHScrollArea)) as RenderBox;
    final contentBottom =
        contentBox.localToGlobal(Offset.zero).dy +
        contentBox.size.height -
        11; // 减去内容底垫的 gap（含滑块厚 10）
    final gap = barBottom - contentBottom;
    debugPrint('内容少：横滚条与内容底边的间距 = $gap');
    expect(gap, closeTo(11, 0.5));
  });

  testWidgets('内容多：横滚条钉在视口底部', (tester) async {
    await tester.pumpWidget(
      _wrap(const UtenHScrollArea(child: SizedBox(width: 1200, height: 5000))),
    );
    await tester.pump(); // post-frame 重算钉底位置。

    final bars = find.byType(Scrollbar);
    debugPrint('内容多：可见 Scrollbar 数 = ${bars.evaluate().length}');
    expect(bars.evaluate().length, 2, reason: '自然条 + 钉底条（Offstage 已揭开）');

    // 钉底条：高度 11、贴视口底（600 - 11 = 589）。
    RenderBox? pinnedBox;
    for (final el in bars.evaluate()) {
      final box = el.findRenderObject() as RenderBox;
      if (box.size.height <= 20) pinnedBox = box;
    }
    expect(pinnedBox, isNotNull, reason: '应存在钉底横滚条');
    final top = pinnedBox!.localToGlobal(Offset.zero).dy;
    debugPrint('内容多：钉底条 top = $top，期望 ${600 - 11}');
    expect(top, closeTo(600 - 11, 1));
  });
}
