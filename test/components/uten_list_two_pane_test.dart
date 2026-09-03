// UtenListTwoPane 分栏统一测试（2026-09-03 接入可拖拽 UtenSplitView）：
// - expanded（>=840）：左右分栏走 UtenSplitView，分割把手可拖宽筛选侧栏；
// - compact/medium：回退垂直堆叠，无分栏（不出现 UtenSplitView）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_list_two_pane.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('expanded：分栏走 UtenSplitView，拖动把手可调筛选侧栏宽', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UtenListTwoPane(
            splitPersistenceKey: 'test.listTwoPane',
            filterPane: Text('筛选区'),
            tablePane: Text('表格区'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(UtenSplitView), findsOneWidget);

    double leadingWidth() => tester
        .getSize(
          find
              .ancestor(of: find.text('筛选区'), matching: find.byType(SizedBox))
              .first,
        )
        .width;

    // 初始宽 = siderWidth 默认 260。
    expect(leadingWidth(), 260);

    // 拖动分割把手向右：筛选侧栏变宽（tester.drag 会吃掉 touch slop ~20px，
    // 故只断言方向；精确钳位用大拖拽验证——上限 min(520, 1280-12-360) = 520）。
    await tester.drag(find.byTooltip('拖动调整宽度 · 双击复位'), const Offset(60, 0));
    await tester.pump();
    expect(leadingWidth(), greaterThan(260));

    await tester.drag(find.byTooltip('拖动调整宽度 · 双击复位'), const Offset(1000, 0));
    await tester.pump();
    expect(leadingWidth(), 520);
    await tester.pumpAndSettle(); // 冲刷 Tooltip 悬停定时器
  });

  testWidgets('compact：回退垂直堆叠，不出现分栏', (tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UtenListTwoPane(
            filterPane: Text('筛选区'),
            tablePane: Text('表格区'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(UtenSplitView), findsNothing);
    // 垂直堆叠：筛选区在表格区上方。
    expect(
      tester.getTopLeft(find.text('筛选区')).dy,
      lessThan(tester.getTopLeft(find.text('表格区')).dy),
    );
  });
}
