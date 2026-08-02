// 诊断用：验证 MasterDataTableView 表体在鼠标滚轮（PointerScrollEvent，非拖拽）下
// 能否正常竖向滚动。问题 #9/#10：用户反馈仓库资料等表格只能拖动滚动条，滚轮无效。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

String _identity(String value) => value;

Widget _table() {
  final items = [for (var i = 0; i < 60; i++) 'ROW-$i'];
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        height: 400,
        child: MasterDataTableView<String>(
          columns: const [
            MasterColumnDef<String>(
              key: 'value',
              label: '值',
              width: 240,
              value: _identity,
            ),
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('mouse wheel scrolls the table body vertically', (
    tester,
  ) async {
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);
    final scrollableFinder = find.descendant(
      of: listFinder,
      matching: find.byType(Scrollable),
    );
    final scrollableState = tester.state<ScrollableState>(scrollableFinder);
    final before = scrollableState.position.pixels;

    final center = tester.getCenter(listFinder);
    // 先 hover 添加设备（PointerScrollEvent 命中测试需要一个已知位置的指针）。
    final testPointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(testPointer.hover(center));
    await tester.sendEventToBinding(
      testPointer.scroll(const Offset(0, 300)),
    );
    await tester.pump();

    final after = scrollableState.position.pixels;
    expect(
      after,
      greaterThan(before),
      reason: '鼠标滚轮事件后表体竖向 ListView 的 scroll offset 应该增加，实际未变化说明滚轮没有路由到内层竖向列表',
    );
  });
}
