import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';

Widget _host({String? persistenceKey}) {
  return MaterialApp(
    home: Scaffold(
      body: UtenSplitView(
        persistenceKey: persistenceKey,
        leading: Container(color: Colors.red),
        trailing: Container(color: Colors.blue),
      ),
    ),
  );
}

/// 左栏当前宽度（UtenSplitView 内第一个定宽 SizedBox）。
double _leadingWidth(WidgetTester tester) {
  final box = tester.widget<SizedBox>(
    find
        .descendant(
          of: find.byType(UtenSplitView),
          matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.width != null && w.width! > 12,
          ),
        )
        .first,
  );
  return box.width!;
}

Finder _gutter() => find.byType(Tooltip);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('初始宽度 = initialLeadingWidth（默认 300）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());
    expect(_leadingWidth(tester), 300);
  });

  testWidgets('向右拖动分割线 → 左栏变宽；向左拖到底 → 钳在 minLeadingWidth', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());

    // 拖动手势会先吃掉 touch slop（测试环境约 20px），故只断言「变宽」，
    // 精确像素由下面的钳位用例保证。
    await tester.drag(_gutter(), const Offset(100, 0));
    await tester.pump();
    expect(_leadingWidth(tester), greaterThan(300));

    await tester.drag(_gutter(), const Offset(-1000, 0));
    await tester.pump();
    expect(_leadingWidth(tester), 220); // 钳在下限
    await tester.pumpAndSettle(); // 冲刷 Tooltip 悬停定时器
  });

  testWidgets('向右拖到底 → 钳在 min(maxLeadingWidth, 总宽-手柄-右栏保底)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());

    // 测试视口 800 宽：上限取 min(520, 800-12-360=428) = 428。
    await tester.drag(_gutter(), const Offset(1000, 0));
    await tester.pump();
    expect(_leadingWidth(tester), 428);
    await tester.pumpAndSettle(); // 冲刷 Tooltip 悬停定时器
  });

  testWidgets('双击分割线复位到初始宽度', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());

    await tester.drag(_gutter(), const Offset(100, 0));
    await tester.pump();
    expect(_leadingWidth(tester), greaterThan(300));

    await tester.tap(_gutter());
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(_gutter());
    await tester.pumpAndSettle(); // 同时冲刷 Tooltip 悬停定时器
    expect(_leadingWidth(tester), 300);
  });

  testWidgets('persistenceKey：拖动结果落盘，重进页面自动恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host(persistenceKey: 'test.page'));

    await tester.drag(_gutter(), const Offset(100, 0));
    await tester.pumpAndSettle(); // 松手落盘
    final draggedWidth = _leadingWidth(tester);
    expect(draggedWidth, greaterThan(300));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('uten.splitView.test.page'), draggedWidth);

    // 卸载重挂：恢复上次拖定的宽度。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host(persistenceKey: 'test.page'));
    await tester.pumpAndSettle();
    expect(_leadingWidth(tester), draggedWidth);
  });
}
