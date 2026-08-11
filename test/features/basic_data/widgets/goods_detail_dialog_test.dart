import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('货品只读详情隐藏生产 BOM 策略，编辑态保留治理入口', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          isSuperAdminProvider.overrideWithValue(false),
          colorDictProvider.overrideWith((ref) async => const []),
          unitDictProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showGoodsDetailDialog(
                    context: context,
                    detail: const GoodsDetail(
                      id: 'goods-1',
                      code: 'P-001',
                      name: '测试货品',
                      status: '使用',
                      sourceType: '自制',
                      productionBomPolicy: 'DIRECT_MAKE',
                    ),
                    canEdit: true,
                  ),
                  child: const Text('打开货品详情'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开货品详情'));
    await tester.pumpAndSettle();

    expect(find.text('生产 BOM 策略'), findsNothing);
    expect(_productionBomPolicyField(), findsNothing);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(_productionBomPolicyField(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Finder _productionBomPolicyField() => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == '生产 BOM 策略',
);
