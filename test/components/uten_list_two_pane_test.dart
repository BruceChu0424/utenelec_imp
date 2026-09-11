// UtenListTwoPane 布局测试（2026-09-10 改版）：所有断点统一「筛选在上 / 表格在下」，
// 不再有左右分栏（分栏只留给分类树主档页的 UtenSplitView）；标题与页脚操作
// 渲染成筛选区顶部一行，窄屏也不再丢掉页脚操作。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_list_two_pane.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UtenListTwoPane(
            filterPaneTitle: '筛选',
            filterPaneFooter: Text('新建'),
            filterPane: Text('筛选区'),
            tablePane: Text('表格区'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('expanded：筛选在上、表格在下，不出现左右分栏', (tester) async {
    await pump(tester, const Size(1280, 800));

    expect(find.byType(UtenSplitView), findsNothing);
    final filterTop = tester.getTopLeft(find.text('筛选区')).dy;
    final tableTop = tester.getTopLeft(find.text('表格区')).dy;
    expect(tableTop, greaterThan(filterTop), reason: '表格区必须在筛选区下方');
    // 整宽：筛选区与表格区左边界一致（不再是窄侧栏）。
    expect(
      tester.getTopLeft(find.text('筛选区')).dx,
      tester.getTopLeft(find.text('表格区')).dx,
    );
  });

  testWidgets('compact：同样上下堆叠，页脚操作仍然渲染', (tester) async {
    await pump(tester, const Size(600, 800));

    expect(find.byType(UtenSplitView), findsNothing);
    expect(find.text('新建'), findsOneWidget, reason: '窄屏不得吞掉页脚操作');
    expect(find.text('筛选'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('表格区')).dy,
      greaterThan(tester.getTopLeft(find.text('筛选区')).dy),
    );
  });

  testWidgets('不传标题与页脚时不渲染标题行', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
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

    expect(find.byType(Row), findsNothing);
    expect(find.text('筛选区'), findsOneWidget);
  });
}
