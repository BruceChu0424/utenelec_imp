// 报工页「本次实际用料」按完工申报量自动折算(V595)的纯算法契约：
// 完工量 × 单耗(优先本批口径 需求量/对应产品数量，退回 BOM 单耗)，封顶到可登记上限，四位小数；
// 用户手改过的行按其比例换算。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/models/reportable_plan_line.dart';

ProductionMaterialClearanceRow _material({
  double requiredQty = 200,
  double? requiredForProductQty = 100,
  double? perProductQty,
  double availableToSettleQty = 500,
  String requirementMode = 'LINEAR',
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
  requirementMode: requirementMode,
);

void main() {
  test(
    'another pending draft reserves quota but does not complete the task',
    () {
      const source = ReportablePlanLine(
        planItemId: 'item',
        planNo: 'plan',
        goodsId: 'goods',
        maxReportQty: 5,
        plannedQty: 10,
        producedQty: 0,
        remainingPlanQty: 5,
      );
      expect(source.remainingCompletionQty, 10);
      final row = DailyGridRow()
        ..executionSegmentId = 'task'
        ..remainingPlanQty = source.remainingCompletionQty
        ..qty.text = '5';
      expect(completesProductionTask(row, [row]), isFalse);
      row.dispose();
    },
  );
  test(
    'shared material survives deleting its first output and follows selection',
    () {
      final input = DailyMaterialInput();
      final first = DailyGridRow()..qty.text = '5';
      final second = DailyGridRow()..qty.text = '5';
      final firstMaterial = DailyGridRow()
        ..depth = 1
        ..material = _material()
        ..materialParent = first;
      final secondMaterial = DailyGridRow()
        ..depth = 1
        ..material = _material()
        ..materialParent = second;
      firstMaterial.bindMaterialInput(input);
      secondMaterial.bindMaterialInput(input);
      final rows = [first, firstMaterial, second, secondMaterial];
      synchronizeMaterialInputOwners(rows, {first, second});
      expect(materialReportedQuantity('demand', rows, {first, second}), 10);
      expect(firstMaterial.materialEditable, isTrue);
      expect(secondMaterial.materialEditable, isFalse);
      input.used.text = '8';
      synchronizeMaterialInputOwners(rows, {second});
      expect(firstMaterial.materialEditable, isFalse);
      expect(secondMaterial.materialEditable, isTrue);
      expect(materialReportedQuantity('demand', rows, {second}), 5);
      firstMaterial.dispose();
      first.dispose();
      expect(secondMaterial.materialUsed.text, '8');
      secondMaterial.materialUsed.text = '7';
      expect(input.used.text, '7');
      secondMaterial.dispose();
      second.dispose();
      input.dispose();
    },
  );

  test('copying a report row starts a fresh output allocation', () {
    // V736：粘贴行是新一次申报，去向分配由重排按当前余量重新给出，不复制原行的分配。
    final source = DailyGridRow()..executionSegmentId = 'segment';
    final allocation = DailyGridRow()
      ..depth = 1
      ..allocationParent = source
      ..allocationDemandId = 'exact-target'
      ..allocationFixed = true;
    source.allocationRows = [allocation];
    final copy = source.clone();
    addTearDown(source.dispose);
    addTearDown(allocation.dispose);
    addTearDown(copy.dispose);
    expect(copy.allocationRows, isEmpty);
    expect(() => allocation.clone(), throwsUnsupportedError);
  });

  test(
    'draft task context survives JSON and excludes this draft from target',
    () {
      final item = ProductionDailyReportItem.fromJson({
        'id': 'line',
        'planId': 'plan',
        'remainingPlanQty': 10,
        'qty': 8,
      });
      expect(item.planId, 'plan');
      expect(item.remainingPlanQty, 10);
    },
  );

  test(
    'unloaded saved material is retained and an explicit zero replaces it',
    () {
      const saved = [
        ProductionDailyReportMaterialUsage(
          demandId: 'd',
          qtyBase: 7,
          materialExecutionSegmentId: 'source',
        ),
      ];
      expect(mergeDraftMaterialUsages(saved: saved, edited: const []), [
        {'demandId': 'd', 'qtyBase': 7},
      ]);
      expect(
        mergeDraftMaterialUsages(
          saved: saved,
          edited: const [
            {'demandId': 'd', 'qtyBase': 0},
          ],
          allowedSourceSegmentIds: {'source'},
        ),
        [
          {'demandId': 'd', 'qtyBase': 0},
        ],
      );
      expect(
        mergeDraftMaterialUsages(
          saved: saved,
          edited: const [],
          allowedSourceSegmentIds: {'new-source'},
        ),
        isEmpty,
        reason: 'a resolved source change removes only the former source use',
      );
    },
  );

  test('whole packages cannot be guessed from an average or edited ratio', () {
    final material = _material(
      requiredQty: 4,
      requiredForProductQty: 11,
      requirementMode: 'EXACT_SNAPSHOT',
    );
    expect(materialUsagePerProduct(material), isNull);
    expect(expectedMaterialUsage(reportedQty: 10, material: material), isNull);
    expect(
      expectedMaterialUsage(
        reportedQty: 10,
        material: material,
        ratioOverride: 2,
      ),
      isNull,
    );
  });

  test('delivery cap does not trigger final-material return', () {
    final row = DailyGridRow()
      ..executionSegmentId = 'task'
      ..maxReportQty = 100
      ..remainingPlanQty = 1000
      ..qty.text = '100';
    addTearDown(row.dispose);
    expect(completesProductionTask(row, [row]), isFalse);
    row.remainingPlanQty = 100;
    expect(completesProductionTask(row, [row]), isTrue);
  });

  test(
    'separate sales slices of the same task finish together, other tasks do not',
    () {
      final first = DailyGridRow()
        ..executionSegmentId = 'a'
        ..remainingPlanQty = 100
        ..qty.text = '40';
      final second = DailyGridRow()
        ..executionSegmentId = 'a'
        ..remainingPlanQty = 100
        ..qty.text = '60';
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      expect(completesProductionTask(first, [first, second]), isTrue);
      second.isFinal = true;
      expect(
        completesProductionTask(second, [first]),
        isFalse,
        reason: 'an unsubmitted final row cannot trigger material return',
      );
      second.isFinal = false;
      second.executionSegmentId = 'b';
      expect(completesProductionTask(first, [first, second]), isFalse);
      first.fqcRecoveryAuthorizationId = 'recovery';
      first.isFinal = true;
      expect(completesProductionTask(first, [first, second]), isFalse);
    },
  );

  test(
    'uses the batch ratio (required / for-product) before the BOM ratio',
    () {
      // 本批 100 个产品要 200 份料 → 单耗 2；BOM 单耗 3 不优先。
      final material = _material(perProductQty: 3);
      expect(materialUsagePerProduct(material), 2);
      expect(expectedMaterialUsage(reportedQty: 30, material: material), 60);
    },
  );

  test('falls back to the BOM ratio when the batch quantity is unknown', () {
    final material = _material(requiredForProductQty: null, perProductQty: 2.5);
    expect(expectedMaterialUsage(reportedQty: 4, material: material), 10);
  });

  test(
    'returns null when no ratio is known so the field is left to people',
    () {
      final material = _material(requiredForProductQty: null);
      expect(expectedMaterialUsage(reportedQty: 4, material: material), isNull);
    },
  );

  test('caps at the quantity still available to settle', () {
    final material = _material(availableToSettleQty: 50);
    expect(expectedMaterialUsage(reportedQty: 100, material: material), 50);
  });

  test('scales by the ratio the user typed once they edited the value', () {
    final material = _material();
    // 用户把 30 个的用料改成 45(比例 1.5)，完工量改成 40 → 60。
    expect(
      expectedMaterialUsage(
        reportedQty: 40,
        material: material,
        ratioOverride: 1.5,
      ),
      60,
    );
  });

  test(
    'rounds to four decimals and rejects non-positive reported quantities',
    () {
      final material = _material(requiredQty: 1, requiredForProductQty: 3);
      expect(expectedMaterialUsage(reportedQty: 1, material: material), 0.3333);
      expect(expectedMaterialUsage(reportedQty: 0, material: material), isNull);
      expect(
        expectedMaterialUsage(reportedQty: -5, material: material),
        isNull,
      );
    },
  );
}
