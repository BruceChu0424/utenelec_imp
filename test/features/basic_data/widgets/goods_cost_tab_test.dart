import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
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

    // 2026-09-05 ⓘ 约定：字段错误经 UtenInputDecoration 收进 ⓘ 披露
    //（Tooltip.message 携带全文），按消息谓词断言。
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').contains('加工费不能为负数'),
      ),
      findsOneWidget,
    );
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

    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').contains('人工比率必须在 0% 到 100%'),
      ),
      findsOneWidget,
    );
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

    expect(find.byType(TextFormField), findsNWidgets(19));
    expect(tester.takeException(), isNull);
  });

  // ADR-134: the cost save is a full goods save; it must carry the detail's
  // English name unchanged so a cost edit never clears or rewrites it.
  testWidgets('保存成本预算时原样带上英文名称', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final goods = _CostGoodsRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [goodsRepositoryProvider.overrideWithValue(goods)],
        child: const MaterialApp(
          home: Scaffold(
            body: GoodsCostTab(
              detail: GoodsDetail(
                id: 'goods-cost-name-en',
                name: '两开多功能三极插座',
                nameEn: 'DOUBLE 3 PIN SOCKET',
                nameEnSource: 'LEARNED',
                status: '使用',
                version: 3,
              ),
              canEdit: true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('保存成本预算'));
    await tester.pumpAndSettle();

    expect(goods.updatedId, 'goods-cost-name-en');
    expect(goods.updateBody, isNotNull);
    expect(goods.updateBody!.containsKey('nameEn'), isTrue);
    expect(goods.updateBody!['nameEn'], 'DOUBLE 3 PIN SOCKET');
    expect(goods.updateBody!['name'], '两开多功能三极插座');
    expect(tester.takeException(), isNull);
  });
}

class _CostGoodsRepository implements GoodsRepository {
  String? updatedId;
  Map<String, dynamic>? updateBody;

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    updatedId = id;
    updateBody = Map<String, dynamic>.of(body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
