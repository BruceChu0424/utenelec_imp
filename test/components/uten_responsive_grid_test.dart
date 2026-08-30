// UtenResponsiveGrid 瀑布流行为测试：
// - 各列独立堆叠：第三张卡片紧跟同列前一张（矮卡）之下，而不是等整行最高的卡片结束；
// - 窄容器退化为单列时占满整行宽度。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_responsive_grid.dart';

const _spacing = 8.0;

Widget _harness(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(700, 600),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  testWidgets('列内卡片紧跟前一张卡片底部，不被同行最高卡片撑出空白', (tester) async {
    // 700 宽 → 2 列，轮流分配：第 0/2 张进左列，第 1/3 张进右列。
    final keys = ['tall', 'short', 'short2', 'short3'].map(Key.new).toList();
    await tester.pumpWidget(
      _harness(
        tester,
        UtenResponsiveGrid(
          itemCount: 4,
          spacing: _spacing,
          itemBuilder: (context, index, itemWidth) => Container(
            key: keys[index],
            color: Colors.green,
            width: itemWidth,
            height: index == 0 ? 200.0 : 100.0,
          ),
        ),
      ),
    );

    const columnWidth = (700 - _spacing) / 2;
    expect(tester.getSize(find.byKey(keys[0])), const Size(columnWidth, 200));
    expect(tester.getSize(find.byKey(keys[1])), const Size(columnWidth, 100));
    // 左列：第二张紧跟高卡片之下。
    expect(
      tester.getTopLeft(find.byKey(keys[2])),
      const Offset(0, 200 + _spacing),
    );
    // 右列：第三张在矮卡片正下方（Wrap 行布局会把它压到 y=208）。
    expect(
      tester.getTopLeft(find.byKey(keys[3])),
      const Offset(columnWidth + _spacing, 100 + _spacing),
    );
  });

  testWidgets('窄容器单列占满整行', (tester) async {
    await tester.pumpWidget(
      _harness(
        tester,
        UtenResponsiveGrid(
          itemCount: 2,
          spacing: _spacing,
          itemBuilder: (context, index, itemWidth) =>
              Container(key: Key('col1-$index'), height: 80),
        ),
        size: const Size(400, 600),
      ),
    );

    expect(
      tester.getSize(find.byKey(const Key('col1-0'))),
      const Size(400, 80),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('col1-1'))),
      const Offset(0, 80 + _spacing),
    );
  });
}
