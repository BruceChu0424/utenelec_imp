// 报工页「本次实际用料」按完工申报量自动折算(V595)的纯算法契约：
// 完工量 × 单耗(优先本批口径 需求量/对应产品数量，退回 BOM 单耗)，封顶到可登记上限，四位小数；
// 用户手改过的行按其比例换算。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';

ProductionMaterialClearanceRow _material({
  double requiredQty = 200,
  double? requiredForProductQty = 100,
  double? perProductQty,
  double availableToSettleQty = 500,
}) => ProductionMaterialClearanceRow(
  planId: 'plan',
  demandId: 'demand',
  goodsId: 'goods',
  requiredQty: requiredQty,
  issuedQty: 500,
  returnedQty: 0,
  consumedQty: 0,
  approvedLossQty: 0,
  legalWipQty: 0,
  maxReturnQty: 0,
  unclearedQty: 500,
  canClose: false,
  requiredForProductQty: requiredForProductQty,
  perProductQty: perProductQty,
  availableToSettleQty: availableToSettleQty,
);

void main() {
  test('uses the batch ratio (required / for-product) before the BOM ratio', () {
    // 本批 100 个产品要 200 份料 → 单耗 2；BOM 单耗 3 不优先。
    final material = _material(perProductQty: 3);
    expect(materialUsagePerProduct(material), 2);
    expect(expectedMaterialUsage(reportedQty: 30, material: material), 60);
  });

  test('falls back to the BOM ratio when the batch quantity is unknown', () {
    final material = _material(requiredForProductQty: null, perProductQty: 2.5);
    expect(expectedMaterialUsage(reportedQty: 4, material: material), 10);
  });

  test('returns null when no ratio is known so the field is left to people', () {
    final material = _material(requiredForProductQty: null);
    expect(expectedMaterialUsage(reportedQty: 4, material: material), isNull);
  });

  test('caps at the quantity still available to settle', () {
    final material = _material(availableToSettleQty: 50);
    expect(expectedMaterialUsage(reportedQty: 100, material: material), 50);
  });

  test('scales by the ratio the user typed once they edited the value', () {
    final material = _material();
    // 用户把 30 个的用料改成 45(比例 1.5)，完工量改成 40 → 60。
    expect(
      expectedMaterialUsage(reportedQty: 40, material: material, ratioOverride: 1.5),
      60,
    );
  });

  test('rounds to four decimals and rejects non-positive reported quantities', () {
    final material = _material(requiredQty: 1, requiredForProductQty: 3);
    expect(expectedMaterialUsage(reportedQty: 1, material: material), 0.3333);
    expect(expectedMaterialUsage(reportedQty: 0, material: material), isNull);
    expect(expectedMaterialUsage(reportedQty: -5, material: material), isNull);
  });
}
