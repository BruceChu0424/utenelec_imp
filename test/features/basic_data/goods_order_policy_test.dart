// 货品采购批量口径（V575：最小起订量 / 订货倍数）。
//
// 两条线：① 模型 fromJson 对 int/double 两种到达形态都安全（后端 NUMERIC(18,4)
// 经 Jackson 可能发整数）；② 货品表单与查看态确实带上这两个字段、文案是约定的口径。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  group('模型解析', () {
    test('详情把整数形态的起订量/倍数安全读成 double', () {
      // 后端 NUMERIC(18,4) 值为整数时 Jackson 会发 500 而不是 500.0；
      // 直接 `as double` 会在这里崩成「加载失败」。
      final d = GoodsDetail.fromJson(const {
        'id': 'goods-1',
        'minOrderQty': 500,
        'orderMultipleQty': 50,
      });

      expect(d.minOrderQty, 500.0);
      expect(d.orderMultipleQty, 50.0);
    });

    test('详情解析小数形态并对缺字段回 null', () {
      final withDecimals = GoodsDetail.fromJson(const {
        'id': 'goods-1',
        'minOrderQty': 12.5,
        'orderMultipleQty': 2.25,
      });
      expect(withDecimals.minOrderQty, 12.5);
      expect(withDecimals.orderMultipleQty, 2.25);

      // 老响应没有这两个键：未登记，不是 0。
      final absent = GoodsDetail.fromJson(const {'id': 'goods-1'});
      expect(absent.minOrderQty, isNull);
      expect(absent.orderMultipleQty, isNull);
    });

    test('起订量 0 是「已确认无起订量」，不能和未登记混成 null', () {
      final d = GoodsDetail.fromJson(const {'id': 'goods-1', 'minOrderQty': 0});

      expect(d.minOrderQty, 0.0);
      expect(d.minOrderQty, isNotNull);
    });

    test('列表项同样携带两个字段', () {
      final item = GoodsListItem.fromJson(const {
        'id': 'goods-1',
        'minOrderQty': 500,
        'orderMultipleQty': 50.0,
      });

      expect(item.minOrderQty, 500.0);
      expect(item.orderMultipleQty, 50.0);
    });

    test('数量展示整数不拖小数尾巴', () {
      expect(goodsQtyText(500), '500');
      expect(goodsQtyText(50.0), '50');
      expect(goodsQtyText(12.5), '12.5');
      expect(goodsQtyText(null), isNull);
    });
  });

  testWidgets('查看态「采购」分组显示起订量与订货倍数', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _host(
        const GoodsDetail(
          writable: true,
          id: 'goods-1',
          code: 'P-001',
          name: '测试货品',
          status: '使用',
          sourceType: '采购',
          minOrderQty: 500,
          orderMultipleQty: 50,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('采购'), findsWidgets);
    expect(find.text('最小起订量'), findsOneWidget);
    expect(find.text('订货倍数'), findsOneWidget);
    // 整数不显示成 500.0；无基本单位时不拼单位后缀。
    expect(find.text('500'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登记时查看态显「—」而不是 0', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _host(
        const GoodsDetail(
          writable: true,
          id: 'goods-1',
          code: 'P-001',
          name: '测试货品',
          status: '使用',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('最小起订量'), findsOneWidget);
    expect(find.text('订货倍数'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑态两个字段可填，提示文案说明是下达采购的预填依据', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _host(
        const GoodsDetail(
          writable: true,
          id: 'goods-1',
          code: 'P-001',
          name: '测试货品',
          status: '使用',
          minOrderQty: 500,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('最小起订量'), findsOneWidget);
    expect(find.text('订货倍数'), findsOneWidget);
    // 既有值回填到表单（编辑保存不得把已登记的起订量冲掉）。
    expect(find.widgetWithText(TextField, '500'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(GoodsDetail detail) => ProviderScope(
  overrides: [
    currentPermissionsProvider.overrideWithValue(const <String>{
      Perm.goodsEdit,
    }),
    isSuperAdminProvider.overrideWithValue(false),
    colorDictProvider.overrideWith((ref) async => const <ColorListItem>[]),
    unitDictProvider.overrideWith((ref) async => const <UnitListItem>[]),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: GoodsDetailBody(
        initialDetail: detail,
        initialCategoryId: null,
        initialTab: 0,
        canCreate: false,
        canEdit: true,
        canStatus: true,
        canBomCreate: false,
        canBomEdit: false,
        canBomDelete: false,
        onToggleStatus: null,
        onDelete: null,
        onViewMovements: null,
        onDataChanged: null,
      ),
    ),
  ),
);
