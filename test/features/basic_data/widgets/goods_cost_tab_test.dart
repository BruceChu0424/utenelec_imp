import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_cost_tab.dart';

void main() {
  testWidgets('成本预算拒绝负数并在对应字段显示修复提示', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: GoodsCostTab(
              detail: GoodsDetail(
                id: 'goods-cost-negative',
                name: '安装螺钉包组件',
                status: '使用',
                machiningE: -0.095,
              ),
              canEdit: true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('保存成本预算'));
    await tester.pump();

    expect(find.text('加工费不能为负数'), findsOneWidget);
    expect(find.text('请先修正标红的成本字段后再保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('成本预算百分比限制在零到一百', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: GoodsCostTab(
              detail: GoodsDetail(
                id: 'goods-cost-rate',
                name: '测试货品',
                status: '使用',
                workRate: 100.0001,
              ),
              canEdit: true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('保存成本预算'));
    await tester.pump();

    expect(find.text('人工比率必须在 0% 到 100% 之间'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('成本预算在375宽度使用单列且不发生横向溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: GoodsCostTab(
              detail: GoodsDetail(
                id: 'goods-cost-compact',
                name: '测试货品',
                status: '使用',
              ),
              canEdit: true,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(TextFormField), findsNWidgets(18));
    expect(tester.takeException(), isNull);
  });
}
