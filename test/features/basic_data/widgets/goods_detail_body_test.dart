import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('货品编辑态不再出现生产 BOM 策略字段', (tester) async {
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
        child: const MaterialApp(
          home: Scaffold(
            body: GoodsDetailBody(
              initialDetail: GoodsDetail(
                writable: true,
                id: 'goods-1',
                code: 'P-001',
                name: '测试货品',
                status: '使用',
                sourceType: '自制',
              ),
              initialCategoryId: null,
              initialTab: 0,
              canCreate: false,
              canEdit: true,
              canStatus: true,
              canBomCreate: true,
              canBomEdit: true,
              canBomDelete: true,
              onToggleStatus: null,
              onDelete: null,
              onViewMovements: null,
              onDataChanged: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('生产 BOM 策略'), findsNothing);
    expect(_productionBomPolicyField(), findsNothing);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(_productionBomPolicyField(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('厚度和单重查看态优先按 UUID 显示无 legacy 的新单位', (tester) async {
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
          unitDictProvider.overrideWith(
            (ref) async => const [
              UnitListItem(id: 'unit-mm', name: 'mm'),
              UnitListItem(id: 'unit-kg', name: 'kg'),
            ],
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: GoodsDetailBody(
              initialDetail: GoodsDetail(
                writable: true,
                id: 'goods-1',
                name: '测试货品',
                status: '使用',
                thickness: 2.5,
                thicknessUnitId: 'unit-mm',
                mWeight: 1.25,
                mWeightUnitId: 'unit-kg',
              ),
              initialCategoryId: null,
              initialTab: 0,
              canCreate: false,
              canEdit: false,
              canStatus: false,
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
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2.5 mm'), findsOneWidget);
    expect(find.text('1.25 kg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('legacy-only master shadows stay unselected while editing', (
    tester,
  ) async {
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
          colorDictProvider.overrideWith(
            (ref) async => const [
              ColorListItem(
                id: 'color-uuid',
                name: 'Legacy color',
                legacyId: 11,
              ),
            ],
          ),
          unitDictProvider.overrideWith(
            (ref) async => const [
              UnitListItem(id: 'unit-uuid', name: 'Legacy unit', legacyId: 12),
            ],
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: GoodsDetailBody(
              initialDetail: GoodsDetail(
                writable: true,
                id: 'goods-legacy-only',
                name: 'Legacy-only goods',
                status: '浣跨敤',
                sourceType: '鑷埗',
                colorLegacyId: 11,
                unitLegacyId: 12,
                thicknessUnitLegacyId: 12,
                mWeightUnitLegacyId: 12,
              ),
              initialCategoryId: 'category-uuid',
              initialTab: 0,
              canCreate: false,
              canEdit: true,
              canStatus: true,
              canBomCreate: true,
              canBomEdit: true,
              canBomDelete: true,
              onToggleStatus: null,
              onDelete: null,
              onViewMovements: null,
              onDataChanged: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    final relationDropdowns = tester
        .widgetList<UtenDropdownField>(find.byType(UtenDropdownField))
        .where(
          (field) => field.items.any(
            (item) => item.value == 'color-uuid' || item.value == 'unit-uuid',
          ),
        )
        .toList();
    expect(relationDropdowns, isNotEmpty);
    expect(relationDropdowns.every((field) => field.value == null), isTrue);
    expect(tester.takeException(), isNull);
  });
}

Finder _productionBomPolicyField() => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == '生产 BOM 策略',
);
