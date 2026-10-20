// UtenFloatingWindow 几何契约：可见卡片必须填满 _windowRect。
// 2026-10-19 用户反馈过一次回归：外壳 Column 按内容收短（mainAxisSize.min）后，
// 缩球 morph 仍从 640 的配置矩形起跳/落回——肉眼看是「卡片先变长触底、再收起，
// 展开也是先到全高再缩回去」，底部缩放手柄还悬在卡片下方的空档里。此测试把
// 「动画起止帧 == 稳态卡片矩形」钉死。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';

/// 稳态可见卡片：标题文本最近的 DecoratedBox 祖先（窗口外壳阴影盒）。
RenderBox _shellBox(WidgetTester tester) {
  final title = tester.element(find.text('浮窗标题'));
  late final RenderBox box;
  title.visitAncestorElements((ancestor) {
    if (ancestor.widget is DecoratedBox) {
      box = ancestor.findRenderObject() as RenderBox;
      return false;
    }
    return true;
  });
  return box;
}

Rect _globalRect(RenderBox box) {
  final topLeft = box.localToGlobal(Offset.zero);
  return topLeft & box.size;
}

/// morph 帧：动画期间唯一的 IgnorePointer 直包动画矩形（测试 body 里没有别的
/// IgnorePointer）。
RenderBox? _morphBox(WidgetTester tester) {
  RenderBox? found;
  void walk(Element e) {
    if (e.widget is IgnorePointer) {
      final ro = e.findRenderObject();
      if (ro is RenderBox && ro.attached) found = ro;
    }
    e.visitChildren(walk);
  }

  walk(tester.element(find.byType(UtenFloatingWindow)));
  return found;
}

void main() {
  testWidgets('缩起从当前可见大小起跳、展开落回同一矩形（外壳填满窗口矩形）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // body 只有 236 高：修复前外壳会被内容带短，morph 仍按 640 起跳。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: UtenFloatingWindow(
                  title: '浮窗标题',
                  body: const SizedBox(
                    width: 560,
                    height: 236,
                    child: ColoredBox(color: Colors.red),
                  ),
                  onClose: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final steady = _globalRect(_shellBox(tester));
    // 内容不足时卡片仍占满配置的窗口矩形（默认 560x640），缩放手柄贴卡片边缘。
    expect(steady, const Rect.fromLTWH(520, 130, 560, 640));

    // 收起动画第一帧 == 稳态卡片：不先跳到更高的隐形矩形再缩。
    await tester.tap(find.byTooltip('缩小成悬浮球'));
    await tester.pump();
    expect(_globalRect(_morphBox(tester)!), steady);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.post_add_rounded), findsOneWidget);

    // 展开落点 == 同一矩形：不在动画结束后回弹成内容高度。
    await tester.tap(find.byIcon(Icons.post_add_rounded));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_globalRect(_shellBox(tester)), steady);
  });
}
