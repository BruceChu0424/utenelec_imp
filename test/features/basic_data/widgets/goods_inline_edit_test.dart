import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_inline_edit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

Future<Map<String, MasterInlineField<GoodsListItem>>> _fields(
  WidgetTester tester, {
  bool priceEdit = false,
  bool purchaseEdit = false,
}) async {
  Map<String, MasterInlineField<GoodsListItem>> fields = {};
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsEdit,
          if (priceEdit) Perm.goodsPriceEdit,
          if (purchaseEdit) Perm.goodsPurchaseEdit,
        }),
        colorDictProvider.overrideWith(
          (ref) async => const [
            ColorListItem(id: 'color-uuid', name: '蓝色', legacyId: 4),
          ],
        ),
        unitDictProvider.overrideWith(
          (ref) async => const [
            UnitListItem(id: 'unit-uuid', name: '个', legacyId: 5),
          ],
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            fields = goodsInlineFields(context, ref);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fields;
}

void main() {
  testWidgets('fixed identity and calculated values are not editable fields', (
    tester,
  ) async {
    final fields = await _fields(tester);
    expect(fields.containsKey('name'), isTrue);
    expect(fields.containsKey('paper'), isTrue);
    for (final key in [
      'code',
      'id',
      'owningWorkshop',
      'stockQty',
      'price',
      'discount',
      'mouldCode',
      'sourceType',
      'minOrderQty',
      'orderMultipleQty',
      'nameEn',
    ]) {
      expect(fields.containsKey(key), isFalse, reason: key);
    }
  });

  testWidgets(
    'real relation choices submit UUIDs while source uses fixed options',
    (tester) async {
      final fields = await _fields(tester, purchaseEdit: true);
      expect(fields['colorLegacyId']!.key, 'colorId');
      expect(fields['colorLegacyId']!.options!.single.value, 'color-uuid');
      expect(fields['unitLegacyId']!.key, 'unitId');
      expect(fields['unitLegacyId']!.cellBuilder, isNotNull);
      expect(fields['mouldName']!.key, 'mouldId');
      expect(fields['mouldName']!.cellBuilder, isNotNull);
      expect(fields['owningWarehouse']!.key, 'owningWarehouseId');
      expect(fields['sourceType']!.type, MasterFieldType.select);
      expect(fields['sourceType']!.options!.map((o) => o.value), [
        '自制',
        '采购',
        '委外',
      ]);
    },
  );

  testWidgets(
    'price edit authority enables decimals and validates precise negative strings',
    (tester) async {
      final fields = await _fields(tester, priceEdit: true, purchaseEdit: true);
      expect(fields['price']!.type, MasterFieldType.money);
      expect(fields['price']!.validate!('-0.0001'), isNotNull);
      expect(fields['price']!.validate!('99999999999999.9999'), isNull);
      expect(fields['minOrderQty']!.validate!('-1'), isNotNull);
    },
  );

  test('list carries the actual mould UUID and explicit object capability', () {
    final row = GoodsListItem.fromJson({
      'id': 'g',
      'mouldId': 'mould-uuid',
      'mouldCode': 'M1',
      'writable': true,
    });
    expect(row.mouldId, 'mould-uuid');
    expect(row.writable, isTrue);
    expect(GoodsListItem.fromJson({'id': 'old-server'}).writable, isFalse);
  });
}
