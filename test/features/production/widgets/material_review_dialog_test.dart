import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';
import 'package:uten_imp/features/production/widgets/material_review_dialog.dart';

void main() {
  testWidgets(
    'quick confirmation uses direct materials and forces purchase request',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      MaterialReviewDecision? decision;
      final preview = _preview(
        recursiveMaterials: const [
          ProductionPlanningMaterial(
            goodsId: 'direct-buy',
            goodsCode: 'B',
            goodsName: 'Direct purchase',
            sourceType: '采购',
          ),
          ProductionPlanningMaterial(
            goodsId: 'nested-buy',
            goodsCode: 'C',
            goodsName: 'Nested purchase',
            sourceType: '采购',
          ),
        ],
        directMaterial: const ProductionExecutionMaterialPreview(
          goodsId: 'direct-buy',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 5,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 5,
          supplyRoute: 'BUY',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                decision = await showMaterialReviewDialog(
                  context,
                  preview: preview,
                  warehouseName: 'Main warehouse',
                  planBillNo: 'PP-001',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('物料需求评审'), findsOneWidget);
      expect(find.text('自动生成采购申请(必需)'), findsOneWidget);
      expect(find.textContaining('Direct purchase'), findsOneWidget);
      expect(find.textContaining('Nested purchase'), findsNothing);
      expect(find.text('查看对应详情'), findsWidgets);

      await tester.tap(find.text('采用建议方案'));
      await tester.pumpAndSettle();

      expect(decision?.type, MaterialReviewDecisionType.useSuggestedPlan);
      expect(decision?.request?.generatePurchaseRequest, isTrue);
      expect(decision?.request?.routes, hasLength(1));
      expect(decision?.request?.routes.single.goodsId, 'direct-buy');
      expect(decision?.request?.routes.single.supplyRoute, 'BUY');
      expect(
        decision?.request?.segments.single.deferUntilManualRelease,
        isFalse,
      );
      final firstAttemptKey = decision!.request!.idempotencyKey;

      decision = null;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采用建议方案'));
      await tester.pumpAndSettle();

      expect(decision?.request?.idempotencyKey, isNot(firstAttemptKey));
      expect(
        decision?.request?.idempotencyKey,
        startsWith('production-planning-'),
      );
    },
  );

  testWidgets(
    'self-made leaf without BOM is not blocking and stays schedulable',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      MaterialReviewDecision? decision;
      final preview = _preview(
        recursiveMaterials: const [
          ProductionPlanningMaterial(
            goodsId: 'make-without-bom',
            goodsCode: 'M',
            goodsName: 'Missing child BOM',
            sourceType: '自制',
          ),
        ],
        directMaterial: const ProductionExecutionMaterialPreview(
          goodsId: 'make-without-bom',
          unitId: 'unit',
          perProductQty: 1,
          requiredQty: 5,
          availableBeforeQty: 0,
          candidateAllocatedQty: 0,
          shortageQty: 5,
          supplyRoute: 'MAKE',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                decision = await showMaterialReviewDialog(
                  context,
                  preview: preview,
                  warehouseName: 'Main warehouse',
                  planBillNo: 'PP-001',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // 自制叶子件（无下层 BOM，原料走车间领料）不再阻断：归入「自制缺料」分类，
      // 「采用建议方案」按钮可用，没有「请先补齐 BOM」置灰态。
      expect(find.textContaining('自制缺料'), findsOneWidget);
      expect(find.text('采用建议方案'), findsOneWidget);
      final submitButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '采用建议方案'),
      );
      expect(submitButton.onPressed, isNotNull);

      await tester.tap(find.text('采用建议方案'));
      await tester.pumpAndSettle();

      expect(decision?.type, MaterialReviewDecisionType.useSuggestedPlan);
      // 自制件缺料走 MAKE 路线（后端派生子计划），不强制生成采购申请。
      expect(decision?.request?.generatePurchaseRequest, isFalse);

      // 仍可进入详细排产聚焦该物料。
      decision = null;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看对应详情').first);
      await tester.pumpAndSettle();

      expect(decision?.type, MaterialReviewDecisionType.openDetailedPlanning);
      expect(decision?.request, isNull);
      expect(decision?.focusMaterialIds, ['make-without-bom']);
    },
  );
}

ProductionPlanningPreview _preview({
  required List<ProductionPlanningMaterial> recursiveMaterials,
  required ProductionExecutionMaterialPreview directMaterial,
}) {
  return ProductionPlanningPreview(
    planId: 'plan-1',
    warehouseId: 'warehouse-1',
    fingerprint: 'a' * 64,
    balancedKitCoverage: false,
    executionSegmentationReady: true,
    materials: recursiveMaterials,
    executionSegments: [
      ProductionExecutionSegmentPreview(
        clientSegmentKey: 'segment-preview-1',
        sourcePlanItemId: 'plan-item-1',
        productGoodsId: 'product-1',
        plannedQty: 5,
        suggestedStatus: 'WAITING',
        bomFingerprint: 'b' * 64,
        materials: [directMaterial],
      ),
    ],
  );
}
