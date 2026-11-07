import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_preparation_supply_slice.dart';
import 'package:uten_imp/features/production/models/material_quantity_presentation.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

MaterialPreparationSupplySlice _slice(
  String key,
  double quantity, {
  bool adoptable = true,
  String? exact,
}) => MaterialPreparationSupplySlice(
  key: key,
  availableQty: quantity,
  availableQtyExact: exact,
  adoptable: adoptable,
);

ProductionMaterialAnalysisMaterial _row(
  String id, {
  double owned = 0,
  double shared = 0,
  double? cap,
  List<MaterialPreparationSupplySlice>? slices,
  Map<String, String> exact = const {},
}) => ProductionMaterialAnalysisMaterial(
  actionable: true,
  materialLineId: id,
  goodsId: 'goods-a',
  unitId: 'unit-a',
  requiredQty: 1000,
  preparationPoolKey: 'pool-a',
  preparationOwnedAvailableQty: owned,
  preparationSharedAvailableQty: shared,
  preparationAdoptableSharedQty: cap,
  preparationSharedSupplySlices: slices,
  quantityFactsExact: exact,
);

void main() {
  test('需求1000的已绑定120仍显示可用120，不随草稿预占变成0', () {
    final row = _row('a', owned: 120, slices: const []);
    expect(materialPreparationAvailableTotalText([row]), '120');
    expect(materialPreparationAvailableTotalText([row, row]), '120');
  });

  test('同池按可采用身份并集计数，私有量逐行相加且不重复公共供给', () {
    final a = _row(
      'a',
      owned: 20,
      shared: 300,
      cap: 100,
      slices: [_slice('x', 100), _slice('y', 200, adoptable: false)],
    );
    final b = _row(
      'b',
      owned: 30,
      shared: 300,
      cap: 200,
      slices: [_slice('x', 100, adoptable: false), _slice('y', 200)],
    );
    expect(materialPreparationAvailableTotalText([a]), '120');
    expect(materialPreparationAvailableTotalText([b]), '230');
    expect(materialPreparationAvailableTotalText([a, b, a]), '350');
  });

  test('同一公共身份或池余额冲突取保守小值', () {
    final a = _row('a', owned: 5, shared: 110, slices: [_slice('x', 100)]);
    final b = _row('b', owned: 7, shared: 80, slices: [_slice('x', 90)]);
    expect(materialPreparationAvailableTotalText([a, b]), '92');
  });

  test('无供给身份的来源cap不能相加伪造互不重叠的公共余量', () {
    expect(
      materialPreparationAvailableTotalText([
        _row('a', owned: 10, shared: 1000, cap: 500),
        _row('b', owned: 20, shared: 1000, cap: 600),
      ]),
      '630',
    );
  });

  test('不同公共池相互独立，完整原值保留24位精度', () {
    final large = _row(
      'a',
      owned: 1e20,
      slices: [_slice('x', 0, exact: '0.000000000000000000000002')],
      exact: const {
        'preparationOwnedAvailableQty':
            '100000000000000000000.000000000000000000000001',
        'preparationSharedAvailableQty': '0.000000000000000000000002',
      },
    );
    expect(
      materialPreparationAvailableTotalText([large]),
      '100000000000000000000.000000000000000000000003',
    );
    const otherPool = ProductionMaterialAnalysisMaterial(
      actionable: true,
      materialLineId: 'b',
      goodsId: 'goods-a',
      unitId: 'unit-a',
      preparationPoolKey: 'pool-b',
      preparationOwnedAvailableQty: 0,
      preparationSharedAvailableQty: 5,
    );
    expect(
      materialPreparationAvailableTotalText([_row('a', owned: 120), otherPool]),
      '125',
    );
  });

  test('旧响应完整可用概览按同一物料池只显示一次', () {
    const a = ProductionMaterialAnalysisMaterial(
      actionable: true,
      materialLineId: 'a',
      goodsId: 'goods-a',
      unitId: 'unit-a',
      preparationAvailableQty: 1350,
    );
    const b = ProductionMaterialAnalysisMaterial(
      actionable: true,
      materialLineId: 'b',
      goodsId: 'goods-a',
      unitId: 'unit-a',
      preparationAvailableQty: 1350,
    );
    expect(materialPreparationAvailableTotalText([a, b]), '1350');
    const publicOnly = ProductionMaterialAnalysisMaterial(
      actionable: true,
      materialLineId: 'old',
      mainWarehousePublicAvailableQty: 120,
      sharedFutureClaimableQty: 5,
    );
    expect(materialPreparationAvailableTotalText([publicOnly]), '125');
  });

  test('缺少完整原值、身份冲突及新旧口径混用不能伪造可用0或合计', () {
    expect(materialPreparationAvailableTotalText([]), isNull);
    expect(
      materialPreparationAvailableTotalText([_row('a', owned: 1e20)]),
      isNull,
    );
    expect(
      materialPreparationAvailableTotalText([
        _row('a', owned: 1),
        _row('a', owned: 2),
      ]),
      isNull,
    );
    expect(
      materialPreparationAvailableTotalText([
        _row('a', slices: [_slice('', 1)]),
      ]),
      isNull,
    );
    expect(
      materialPreparationAvailableTotalText([
        _row('a'),
        const ProductionMaterialAnalysisMaterial(
          actionable: true,
          materialLineId: 'legacy',
          goodsId: 'goods-a',
          unitId: 'unit-a',
          preparationAvailableQty: 120,
        ),
      ]),
      isNull,
    );
  });
}
